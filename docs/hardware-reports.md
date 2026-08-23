# Hardware Reports and Community Contributions

This document records hardware test results and debug traces contributed by
community members during development of the freebsd-update EFI patch (D58990).
Each entry notes the platform, FreeBSD version, storage configuration, boot
method, and any bugs surfaced or confirmed by the run.

---

## marklmi

Phabricator reviewer on D58990. Provided debug traces and notes from six
hardware platforms across eight rounds of testing, surfacing important bugs and
firmware behavior differences.

**Notes on marklmi's test environment:**

- All testing was on FreeBSD `main` (16-CURRENT) unless noted otherwise
- All platforms other than amd64 use UFS root; only amd64 is ZFS
- All disks were single-disk configurations; multiple boot media present across systems

### Round 1 — pre-revision-2 (initial submission D58990)

Debug traces collected from running the patch directly. Led to R-06.

| Platform | Arch | FreeBSD | Firmware | Root FS | Disk | ESP | Outcome |
|----------|------|---------|----------|---------|------|-----|---------|
| amd64 workstation | amd64 | main | UEFI/ACPI | ZFS | NVMe | GPT | ✓ Successful. Confirmed `efibootmgr -v` dp:-line format: PARTUUID appears on a sub-line prefixed `dp:`, not inline with the `HD(GPT,...)` entry. Drove R-06 fix. |

**R-06 detail:** Early code extracted PARTUUID from the same line as `HD(GPT,...)`
marklmi's trace showed the actual format has the PARTUUID on a following `dp:` line.
Fix: scan for `dp:` sub-line when the `HD(GPT,...)` line itself contains no UUID.

---

### Round 2 — revision-2 development (post-R-06)

Five platforms tested after the boot-scoped discovery rewrite. Three surfaced
new bugs (R-07, R-08); two confirmed the happy path or graceful fallback.

| Platform | Arch | FreeBSD | Firmware | Root FS | Disk/Scheme | Outcome |
|----------|------|---------|----------|---------|-------------|---------|
| amd64 workstation | amd64 | main | UEFI/ACPI | ZFS | NVMe / GPT | ✓ Successful. dp:-line PARTUUID extraction confirmed working with revised code. |
| WDK23 (ARM dev board) | arm64 | main | UEFI/ACPI | UFS | USB3 Optane / GPT | ✓ Successful via fallback path. Boot entries present but none contain `HD(GPT,...)` device path — BootCurrent PARTUUID lookup yields nothing; script correctly fell back to root-disk-only discovery. |
| Raspberry Pi 4B | arm64 | main | UEFI/DeviceTree via U-Boot FreeBSD port | UFS | USB3 Optane / GPT | ✓ Successful via fallback path. Bare BootCurrent (no NVRAM entries with device paths); root-disk-only fallback triggered correctly. Note: U-Boot presents GPT to firmware even though RPi4B typically uses non-standard partition layouts. |
| Raspberry Pi 5 | arm64 | main | draft EDK2 UEFI/ACPI | UFS | NVMe / GPT with GEOM labels | ✗ Two bugs exposed — see R-07 and R-08 below. (Firmware on microSD; root on NVMe.) |
| Raspberry Pi 5 (USB3 boot) | arm64 | main | draft EDK2 UEFI/ACPI | UFS | USB3 / GPT with GEOM labels | ✗ Same R-08 scenario — `gpt/PkgBRPi5UFS` label unresolvable pre-fix. Expected to be resolved by R-08 glabel fallback. |

**R-07 detail (ZFS GEOM-labelled vdev names):**
The zpool vdev awk filter `$1 ~ /[0-9]/` was intended to skip non-device lines
but excluded GEOM-labelled vdevs that contain no digit (e.g. `gpt/OptBzfs`).
Fix: replaced digit filter with an `in_config` flag that activates only after
the `config:` section header; added `$1 != pool` guard to skip the pool name line.

**R-08 detail (UFS GEOM label — device node vs. symlink):**
On newer FreeBSD kernels, GEOM creates `/dev/gpt/X` as a character device node
rather than a symlink. `realpath` on a device node returns the path unchanged
(no symlink to follow), so the old code could not resolve the underlying disk.
Example: `gpt/PkgBRPi5UFS` on RPi5 UFS. Fix: `glabel status` fallback applied
to both `efi_root_disks zfs` and `efi_root_disks ufs` — when `realpath` returns
the path unchanged, parse `glabel status` output to resolve the label to a disk name.

---

### Round 3 — post-R-07/R-08 (commit post-5d2173a)

Sixth platform added: Honeycomb LX2160A. Traces also re-collected on amd64,
WDK23, RPi4B, and RPi5 after R-07/R-08 fixes; results for those platforms
consistent with Round 2 confirmed paths.

| Platform | Arch | FreeBSD | Firmware | Root FS | Boot media | Outcome |
|----------|------|---------|----------|---------|------------|---------|
| Honeycomb LX2160A | arm64 | main | official EDK2 UEFI/ACPI (not updated in years) | UFS | USB3 (JMicron) / GPT with GEOM label | ✗ "No EFI System Partitions found" — R-08 scenario; see detail below. |

**Honeycomb LX2160A detail:**
- `efibootmgr --esp` returns "Can't convert to unix path"
- BootCurrent = `000b` (hexadecimal — Boot entry 11) → Boot000B device path is `VenHw(...)/USB(...)` — no `HD(GPT,...)` → PARTUUID lookup yields nothing; falls back to root-disk path
- UFS root = `/dev/gpt/PkgBaseUFS`; `realpath` returns path unchanged (device node, not symlink) → `gpart show gpt/PkgBaseUFS` fails → no ESP found
- This is the R-08 scenario. The R-08 `glabel status` fallback is expected to resolve `gpt/PkgBaseUFS` to the underlying disk and find the ESP
- Also present in NVRAM: a Fedora entry (`HD(1,MBR,...)`) and two Intel NVMe entries — neither is the active boot entry; the active entry (Boot000B, USB3) has no `HD()` path

**`efibootmgr --esp` behavior observed across all marklmi platforms:**

| Platform | Firmware | `efibootmgr --esp` result |
|----------|----------|-----------------------------|
| amd64 workstation | UEFI/ACPI | `/dev/gpt/OptBefi` (success) |
| WDK23 | UEFI/ACPI | `Can't get BootCurrent: Function not implemented` |
| RPi4B | UEFI/DeviceTree via U-Boot | `Can't get BootCurrent: No such file or directory` |
| RPi5 | draft EDK2 UEFI/ACPI | `Can't convert to unix path` |
| Honeycomb LX2160A | official EDK2 UEFI/ACPI (old) | `Can't convert to unix path` |

Embedded platforms (RPi, WDK23, Honeycomb) typically carry firmware blobs with
their own upstream (U-Boot, RPi firmware, DTBs, EDK2 builds) that are not part
of the FreeBSD base system. Updating those blobs is out of scope for
`freebsd-update`. Platforms where `efibootmgr --esp` cannot produce a path may
warrant documenting as a known limitation rather than attempting a potentially
incorrect update.

---

### Round 4 — post-R-07/R-08, MBR coverage (14.5-BETA2 RPi4B fresh install)

Fresh install of FreeBSD-14.5-BETA2-arm64-aarch64-RPI.img specifically to
provide MBR partition scheme coverage. All prior rounds were GPT.

| Platform | Arch | FreeBSD | Firmware | Root FS | Boot media | Outcome |
|----------|------|---------|----------|---------|------------|---------|
| Raspberry Pi 4B | arm64 | 14.5-BETA2 | U-Boot UEFI | UFS (ufs/rootfs GEOM label) | USB3 / MBR | ✗ "No EFI System Partitions found" — three R-09 bugs; see detail below. |

**Partition layout:**
```
=>      63  61439937    da0  MBR  (29G)
      2048    102400  da0s1  fat32lba  [active]  (50M)
    104448  61335552  da0s2  freebsd  (29G)

=>       0  61335552   da0s2  BSD  (29G)
       128  55183232  da0s2a  freebsd-ufs  (26G)
  55183360   6152192  da0s2b  freebsd-swap  (2.9G)
```

**R-09 detail (three bugs, all required for MBR support):**

- **R-09a** (`ufs/*` label not in case): root device `/dev/ufs/rootfs` did not
  match `gpt/*|diskid/*|gptid/*`, so fell through to the sed strip with the
  full label name.
- **R-09b** (sed strips trailing `s`): `[0-9]*` allows zero digits, so
  `s/[sp][0-9]*$//` stripped the trailing `s` from `rootfs` → `rootf`.
  Then `gpart show ufs/rootf` failed. Also: the pattern fails to strip MBR
  BSD-label suffixes like `s2a` (would need to produce `da0`, not `da0s2`).
  Fix: `[sp][0-9]\{1,\}[a-z]\{0,1\}$`.
- **R-09c** (MBR type name): `efi_boot_esps` checked `$4 == "!12" || "!ef"`
  but gpart uses the symbolic name `fat32lba` for type 0x0C; `!12` never
  matched any real MBR install. Fix: add `fat32lba`, `fat32`, `efi`.

**Notes:**
- `efibootmgr --esp` not available on this image
- Boot0000 device path is `VenHw(...)/USB(...)` with no `HD(GPT,...)` — no PARTUUID; falls back to root-disk path
- ESP at `da0s1` (`fat32lba`) was already mounted at `/boot/efi` as `/dev/msdosfs/EFI`

---

### Round 5 — dry-run validation, post-R-09

`--dry-run --verbose` runs across four platforms. All ESPs were correctly
identified. Exposed R-10: free-space reporting showed root filesystem available
space rather than ESP free space (the ESP is not mounted in dry-run mode, so
`df` measured `/tmp`). Also noted: "Creating /EFI/FreeBSD/" and "Installing
fallback loader" appear unconditionally in dry-run because the unmounted tmpdir
is empty — not necessarily reflecting actual ESP contents.

| Platform | Arch | FreeBSD | Firmware | Root FS | Boot media | Outcome |
|----------|------|---------|----------|---------|------------|---------|
| amd64 workstation | amd64 | main | UEFI/ACPI | ZFS | NVMe / GPT | ✓ ESP identified (nda2p1). R-10: reported 753 GB available (root ZFS pool free space, not the 260 MB ESP). |
| WDK23 (ARM dev board) | arm64 | main | UEFI/ACPI | UFS | USB3 Optane / GPT | ✓ ESP identified (da0p1). R-10: reported 813 GB available (root UFS free space, not the 245 MB ESP). |
| Raspberry Pi 5 | arm64 | main | draft EDK2 UEFI/ACPI | UFS | NVMe / GPT | ✓ ESP identified (nda0p1). R-10: reported 476 GB available (root UFS free space, not the 245 MB ESP). |
| Honeycomb LX2160A | arm64 | main | official EDK2 UEFI/ACPI (old) | UFS | USB3 / GPT | ✓ ESP identified (da0p1). R-10: reported 326 GB available (root UFS free space, not the 245 MB ESP). |

**R-10 detail (two dry-run output bugs, fixed in 82471a4):**

- **R-10a** (space check): `efi_check_space` ran `df -k` on the empty tmpdir
  in `/tmp` rather than a mounted ESP, so it reported root filesystem free space
  (hundreds of GB) instead of ESP free space (typically 50–260 MB). Fix: skip
  the `df` call when `EFI_DRY_RUN=1`; emit `[DRY RUN] Space check skipped (ESP
  not mounted)`. (Refined in R-12: this condition is suppressed when the ESP is
  already mounted via fstab, so the real space check runs in that case.)

- **R-10b** (blank ESP output): "Creating /EFI/FreeBSD/ and installing loader"
  and "Installing fallback loader" always appeared in dry-run because the unmounted
  tmpdir is empty — not because those paths are absent on the real ESP. Fix: emit
  `[DRY RUN] ESP not mounted — existing file/directory detection skipped; output
  reflects a blank ESP` once per partition before the file-operation lines.
  (Refined in R-12: this notice is suppressed when the ESP is already mounted
  via fstab.)

---

### Round 6 — live run, post-R-10 (RPi3B MBR, 14.5-BETA2)

First live (non-dry-run) run on the MBR platform after R-09/R-10 fixes.
Same 14.5-BETA2 USB media as Round 4/5 but booted on a Raspberry Pi 3B (USB2
ports) rather than RPi4B — marklmi had swapped boards for unrelated Cortex-A53
testing. No behavioral difference expected for this script's purposes.
Exposed R-11: ESP already mounted at `/boot/efi` as `/dev/msdosfs/EFI` (GEOM
msdosfs volume-label device) — `efi_esp_mountpoint` matched only on the raw
device path (`/dev/da0s1`) and did not detect the existing mount, causing
`mount_msdosfs` to fail with "Device busy".

| Platform | Arch | FreeBSD | Firmware | Root FS | Boot media | Outcome |
|----------|------|---------|----------|---------|------------|---------|
| Raspberry Pi 3B | arm64 | 14.5-BETA2 | U-Boot 2025.10 UEFI/DeviceTree | UFS (`ufs/rootfs`) | USB2 / MBR | ✗ "Failed to mount ESP /dev/da0s1" — R-11; see detail below. |

**R-11 detail (`/dev/msdosfs/EFI` GEOM label not recognized in `efi_esp_mountpoint`):**

When a FAT filesystem is mounted with a volume label, FreeBSD creates a GEOM
msdosfs label device (e.g. `/dev/msdosfs/EFI`) and `mount --libxo json` reports
this as the `special` field rather than the underlying raw device (`/dev/da0s1`).
`efi_esp_mountpoint` performed only an exact match on the raw device path, so it
returned empty and `efi_mount_esp` called `mount_msdosfs` on an already-mounted
device → "Failed to mount ESP". Fix: second-pass GEOM label resolution in
`efi_esp_mountpoint` using `glabel status` (same approach as R-08 for root disk
labels). Test added: `test_i11_esp_msdosfs_label_mounted.sh`.

**System details:**
- U-Boot version: 2025.10 (Aug 14 2026)
- ESP: `da0s1` (`fat32lba`, 50M, already mounted at `/boot/efi` as `/dev/msdosfs/EFI`)
- Root: `/dev/ufs/rootfs` → `glabel status` → `da0s2a` → `da0`
- BootCurrent: `0000` → `VenHw(...)/USB(...)` — no `HD(GPT,...)`, falls back to root-disk path

**Note:** The msdosfs GEOM label behavior that triggered R-11 is not specific to
SBCs, MBR disks, or ARM platforms. Any system — including amd64 servers — whose
`/etc/fstab` mounts the ESP using a label-based path (e.g. `/dev/msdosfs/EFI`)
rather than the raw device node will exhibit the same behavior. The R-11 fix
handles this universally.

---

### Round 7 — dry-run, post-R-11 (amd64, ESP pre-mounted via fstab)

`--dry-run --verbose` run on the amd64 workstation after the R-10/R-11 fixes.
The ESP (`/dev/nda2p1`) is listed in `/etc/fstab` and mounted at `/boot/efi`
before the script runs. `efi_mount_esp` correctly detected the existing mount
(via R-11 two-phase glabel lookup) and reused it. However, the R-10 space-skip
and blank-ESP notice both fired unconditionally on `EFI_DRY_RUN=1` — even though
the script was already operating on the real mounted ESP. This produced
contradictory output:

```
DEBUG: ESP /dev/nda2p1 already mounted at /boot/efi
DEBUG: [DRY RUN] Space check skipped (ESP not mounted)   ← wrong: it IS mounted
INFO:  [DRY RUN] ESP not mounted — existing file/directory detection skipped;
       output reflects a blank ESP                        ← wrong: real ESP is accessible
INFO:  [DRY RUN] Would update: /boot/efi/EFI/FREEBSD/loader.efi
DEBUG: Fingerprint '/boot/efi/EFI/BOOT/bootx64.efi': 2/2 heuristic match(es)
```

Exposed R-12. Reported by marklmi (amd64 workstation, main, NVMe/GPT).

| Platform | Arch | FreeBSD | Firmware | Root FS | Boot media | Outcome |
|----------|------|---------|----------|---------|------------|---------|
| amd64 workstation | amd64 | main | UEFI/ACPI | ZFS | NVMe / GPT | ✗ Contradictory dry-run output — R-12; see detail above and below. |

**R-12 detail (`_efi_esp_is_real` flag — pre-mounted dry-run shows wrong notices):**

R-10 conditions `efi_check_space` and `efi_update_esp`'s blank-ESP notice on
`EFI_DRY_RUN=1` only. But when the ESP is already mounted (reused mountpoint),
`_efi_esp_mp` points to the real filesystem — not an empty tmpdir. Skipping the
space check and emitting the blank-ESP notice is wrong in this case.

Fix: add `_efi_esp_is_real` (0/1) module-level state variable, set in
`efi_mount_esp`:
- pre-mounted reuse → `_efi_esp_is_real=1`
- actual `mount_msdosfs` call → `_efi_esp_is_real=1`
- dry-run, ESP not mounted → `_efi_esp_is_real=0` (empty tmpdir)

Both conditions now guard on `EFI_DRY_RUN=1 AND _efi_esp_is_real=0`. When the
ESP is pre-mounted in dry-run, the real space check runs, the real ESP contents
are visible, and no misleading notices appear. Reset to 0 in `efi_unmount_esp`.

---

### Round 8 — live runs, post-R-12 (5 platforms)

Live (non-dry-run) runs across five platforms after R-09 through R-12 fixes.
All platforms had ESPs pre-mounted at `/boot/efi` via `/etc/fstab`. marklmi's
normal media are historically kept up to date, so most showed "Already up to
date". The RPi4B (14.5-BETA2) did not have `EFI/FREEBSD/` at all — script
created it and installed `loader.efi` successfully.

| Platform | Arch | FreeBSD | Firmware | Root FS | Boot media | Outcome |
|----------|------|---------|----------|---------|------------|---------|
| amd64 workstation | amd64 | main | UEFI/ACPI | ZFS | NVMe (Optane/PCIe) / GPT | ✓ Files up to date; NVRAM entry created on 1st run, detected existing on 2nd. UEFI UI confirmed selectable. Exposed R-13. |
| Honeycomb LX2160A | arm64 | main | UEFI/ACPI (Solidrun EDK2) | UFS | USB3 / GPT | ✓ `loader.efi` and `bootaa64.efi` updated on 1st run; NVRAM entry created. UEFI UI confirmed selectable. 2nd run: all up to date. |
| Windows Dev Kit 2023 | arm64 | main | UEFI/ACPI | UFS | USB3 / GPT | ✓ Files updated. NVRAM creation failed (`efi_set_variable: Function not implemented`). Graceful WARN with corrected command. |
| Raspberry Pi 4B | arm64 | 14.5-BETA2 | U-Boot UEFI/DeviceTree | UFS | USB3 / MBR | ✓ `EFI/FreeBSD/` created, `loader.efi` installed. NVRAM creation failed (same as WDK23). Exposed R-13 device suffix bug. |
| Raspberry Pi 5 | arm64 | main | draft EDK2 UEFI/ACPI | UFS | NVMe / GPT | ✓ Files up to date. NVRAM "created" but silently not persisted — draft EDK2 bug (no error returned). Not our issue; see note. |

**R-13 detail (MBR summary uses wrong device suffix):**

`efi_update_esp` summary line hardcoded `p${part_index}`:
```
Updated 1 EFI loader file(s) on /dev/da0p1   ← wrong for MBR
```
should be `/dev/da0s1` (MBR slice notation). Root cause: `efi_update_esp`
received `disk` and `part_index` but not `scheme`. Fix: add `scheme` as 5th
parameter; derive device string as `sN` for MBR, `pN` for GPT.

**WARN message improvement:**

The `efibootmgr` failure warning previously showed a template path:
```
Mount ESP and run: efibootmgr -a -c -l '<esp>/EFI/FreeBSD/loader.efi' -L FreeBSD
```
Now shows the actual path (already available as `freebsd_loader_abs`):
```
Run as root: efibootmgr -a -c -l '/boot/efi/EFI/FreeBSD/loader.efi' -L FreeBSD
```

**RPi5 EDK2 NVRAM note:**

The draft EDK2 for RPi5 does not have access to dedicated NVRAM storage —
the RPi5 firmware reserves hardware NVRAM for its own use. The EDK2 silently
accepts `efi_set_variable` calls without returning `EFI_UNSUPPORTED`, but
the variable does not persist across a reboot. On each fresh boot the NVRAM
entry is absent; running the script re-creates it (again silently futile). This
is a draft EDK2 limitation, not a script bug. The script is idempotent in this
scenario — each run correctly reports "NVRAM boot entry created".

Note also that U-Boot on RPi4B has historically avoided using hardware NVRAM
entirely (hence `efi_set_variable: Function not implemented` on RPi4B, the
honest behavior). An EDK2 port for RPi4B also exists; the RPi3B EDK2 is
reportedly Windows-specific.

---

## RZA-SF (repository author)

### Live run — revision-1

| Date | Platform | Arch | FreeBSD | Root FS | Disk | ESP | Outcome |
|------|----------|------|---------|---------|------|-----|---------|
| 2026-08 | Physical workstation | amd64 | 14.0-RELEASE-p11 | ZFS | NVMe (nda0) | GPT | ✓ Two reboots clean. Boot0004 FreeBSD NVRAM entry active. Surfaced R-01 and R-02 (see below). |

**R-01 detail:** `mount_msdosfs -o noexec,nosuid` (comma-separated) rejected by
FreeBSD — flags must be passed as separate `-o` arguments.

**R-02 detail:** `efibootmgr -l` requires a Unix-style path (`/EFI/FreeBSD/loader.efi`),
not a Windows-style backslash path (`\EFI\FreeBSD\loader.efi`). Early code
passed the backslash form.

### Test suite runs — revision-2 rollup (4cc8d91)

| Date | Platform | Arch | FreeBSD | Result | Notes |
|------|----------|------|---------|--------|-------|
| 2026-08-21 | Physical workstation | amd64 | 14.0-RELEASE-p11 | ✓ 266/266 | First FreeBSD run of revision-2; confirmed chflags schg fix (test_11) and PATH tightening for test_e09 |
| 2026-08-21 | Physical workstation | amd64 | 14.0-RELEASE-p11 | ✓ 266/266 | Post-rollup; confirmed stdout fix in test_14 test 7 |
| 2026-08-21 | Physical workstation | amd64 | 15.1-RELEASE-p2 | ✓ 266/266 | Pre-rollup; confirmed efibootmgr PATH restriction works on 15.x base system |
| 2026-08-21 | Physical workstation | amd64 | 15.1-RELEASE-p2 | ✓ 266/266 | Post-rollup (4cc8d91); stdout fix confirmed clean, no regressions |

### Test suite runs — post-R-09 (3ace096)

| Date | Platform | Arch | FreeBSD | Result | Notes |
|------|----------|------|---------|--------|-------|
| 2026-08-21 | Physical workstation | amd64 | 14.0-RELEASE-p11 | ✓ 269/269 | R-09 fixes confirmed; new ufs/ label and fat32lba tests pass |
| 2026-08-21 | Physical workstation | amd64 | 15.1-RELEASE-p2 | ✓ 269/269 | Clean pass; no regressions on 15.x |

### Test suite runs — post-R-14 (revision-2 final)

| Date | Platform | Arch | FreeBSD | Result | Notes |
|------|----------|------|---------|--------|-------|
| 2026-08-23 | Physical workstation | amd64 | 14.0-RELEASE-p11 | ✓ 286/286 | R-14 split-media guard confirmed; test_i12 (7/7) and test_15 tests 24–27 all pass |
| 2026-08-23 | Physical workstation | amd64 | 15.1-RELEASE-p2 | ✓ 286/286 | Clean pass on 15.x; no regressions |

---

## Contributing a Report

If you have run the test suite or the patch on hardware not listed above,
please open an issue or PR at
[github.com/RZA-SF/freebsd-patch-for-bug279829](https://github.com/RZA-SF/freebsd-patch-for-bug279829)
with the following:

- `uname -a` output
- Root filesystem type (ZFS / UFS) and disk topology (single, mirror, RAIDz)
- Partition scheme (GPT / MBR) and storage device type (NVMe, SATA, eMMC, SD, USB3)
- Boot method (`sysctl machdep.bootmethod` output, or "assumed UEFI" on aarch64)
- Test suite result (`./tests/run_tests.sh` output summary)
- Live run result if performed (dry-run or actual install)
- Any unexpected output or failures

Broad hardware coverage before upstream submission strengthens the case for
inclusion and helps catch platform-specific edge cases early.
