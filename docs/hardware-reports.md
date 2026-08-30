# Hardware Reports and Community Contributions

This document records hardware test results contributed by community members
and the patch author during development of the freebsd-update EFI patch
(D58990). The [Coverage Matrix](#coverage-matrix) provides a quick overview of
what has been tested and what each environment surfaced. Detailed per-environment
notes and bug narratives follow in the [contributor sections](#contributor-detail-reports).

---

## Coverage Matrix

Each row is one test environment. **Suite** = `./tests/run_tests.sh` pass
count on that FreeBSD version. **Run** = live or dry-run execution on real
hardware/cloud. **Bugs** = fix revisions first surfaced by this environment
(full narratives in the detail sections). All listed environments pass the
current 291-test suite.

| Who | Platform | Arch | FreeBSD | Root FS | Scheme | Boot | Suite | Run | Bugs surfaced |
|-----|----------|------|---------|---------|--------|------|-------|-----|---------------|
| marklmi | amd64 workstation | amd64 | main (16-CURRENT) | ZFS | GPT | EFI | — | ✓ live | R-06, R-10, R-12, R-13 |
| marklmi | WDK23 (ARM dev board) | arm64 | main | UFS | GPT | EFI | — | ✓ live | — |
| marklmi | Raspberry Pi 4B | arm64 | main / 14.5-BETA2 | UFS | GPT + MBR | EFI | — | ✓ live | R-09a–c, R-11, R-13 |
| marklmi | Raspberry Pi 5 | arm64 | main | UFS | GPT | EFI | — | ✓ live | R-07, R-08 |
| marklmi | Raspberry Pi 3B | arm64 | 14.5-BETA2 | UFS | MBR | EFI (U-Boot) | — | ✓ live | R-11 |
| marklmi | Honeycomb LX2160A | arm64 | main | UFS | GPT | EFI | — | ✓ live | R-08 |
| Stefan | amd64 workstation (3-disk, diskid/ vdevs) | amd64 | CURRENT | ZFS | GPT | EFI | — | ✓ live | R-15, R-16 |
| RZA-SF | Physical workstation | amd64 | 14.0-RELEASE-p11 | ZFS | GPT | EFI+BIOS | 291/291 | ✓ live | R-01, R-02 |
| RZA-SF | Physical workstation | amd64 | 15.1-RELEASE-p2 | ZFS | GPT | EFI+BIOS | 291/291 | — | — |
| RZA-SF | AWS Graviton EC2 | aarch64 | 13.5-RELEASE | UFS | GPT | EFI | 291/291 | dry-run | R-17 |
| RZA-SF | AWS Graviton EC2 | aarch64 | 14.4-RELEASE-p9 | UFS | GPT | EFI | 291/291 | dry-run | — |
| RZA-SF | AWS Graviton EC2 | aarch64 | 14.4-RELEASE-p9 | ZFS | GPT | EFI | 291/291 | dry-run | — |
| RZA-SF | AWS Graviton EC2 | aarch64 | 15.1-RELEASE-p3 | ZFS | GPT | EFI | 291/291 | dry-run | — |
| RZA-SF | AWS Graviton EC2 | aarch64 | 15.1-RELEASE-p3 | UFS | GPT | EFI | 291/291 | dry-run | — |
| RZA-SF | AWS EC2 | amd64 | 13.5-RELEASE-p13 | UFS | GPT | EFI+BIOS | 291/291 | dry-run | R-17 |
| RZA-SF | AWS EC2 | amd64 | 14.4-RELEASE-p9 | ZFS | GPT | EFI+BIOS | 291/291 | dry-run | — |
| RZA-SF | AWS EC2 | amd64 | 14.4-RELEASE-p9 | UFS | GPT | EFI+BIOS | 291/291 | dry-run | — |
| RZA-SF | AWS EC2 | amd64 | 15.1-RELEASE-p3 | UFS | GPT | EFI+BIOS | 291/291 | dry-run | — |
| RZA-SF | AWS EC2 | amd64 | 15.1-RELEASE-p3 | ZFS | GPT | EFI+BIOS | 291/291 | dry-run | — |

**Boot column:** EFI = EFI loader only (no freebsd-boot partition present).
EFI+BIOS = both EFI loader and BIOS bootcode (`gptboot`/`gptzfsboot`) updated.
EFI (U-Boot) = EFI loader on MBR disk via U-Boot; no GPT freebsd-boot partition.

---

## Contributor Detail Reports

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

Embedded platforms (RPi, WDK23, Honeycomb) carry firmware components with their
own upstream sources. U-Boot and EDK2 builds are not part of the FreeBSD base
system; updating those is out of scope for `freebsd-update`. DTBs are a more
nuanced case: most non-RPi DTBs are built from FreeBSD source
(`/usr/src/sys/contrib/device-tree/`) and distributed as the `FreeBSD-dtb`
package via freebsd-update, while RPi DTBs come from the `sysutils/rpi-firmware`
port. In both cases, copying DTBs to the ESP is a manual step outside
freebsd-update and outside the scope of this patch, which updates only EFI
loader binaries. Platforms where `efibootmgr --esp` cannot produce a path may
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

## se@freebsd.org (Stefan Esser)

D58990 reviewer. Provided a full `sh -x` debug trace from a FreeBSD-CURRENT
amd64 system running commit `a60e69d` (revision-3, R-15). The trace diagnosed
two related failures in `efi_root_disks` and `efi_boot_esps` that together
caused a complete no-op on his system (no ESP found, no update attempted).

**Notes on configuration:**

The failures are not specific to Stefan's hardware. They are triggered by two
configuration facts independent of the physical machine:

1. **FreeBSD-CURRENT behavior:** `gpart list <shortname>` (e.g. `gpart list nda0`,
   `gpart list ada0`) returns empty output for all disk names on this FreeBSD-CURRENT
   build. `gpart list diskid/DISK-xxx` works correctly on the same system.
2. **ZFS pool with `diskid/` vdev:** The `zroot` pool's single vdev is referenced as
   `diskid/DISK-<nvme-serial>p2`, not as a raw partition name (`nda0p2`).

Any amd64 system running FreeBSD-CURRENT with a `diskid/`-labelled ZFS vdev
would reproduce these failures identically.

| Platform | Arch | FreeBSD | Firmware | Root FS | Disk/Scheme | Outcome |
|----------|------|---------|----------|---------|-------------|---------|
| amd64 workstation (3 physical disks) | amd64 | CURRENT | UEFI/ACPI | ZFS (`zroot`) | NVMe + 2× SATA / GPT | ✗ "cannot determine boot/root disks" + "No EFI System Partitions found" — R-15 + R-16; see detail below. |

**Storage topology:**

- NVMe boot disk: `diskid/DISK-<nvme-serial>` (vdev `diskid/DISK-<nvme-serial>p2`;
  ESP at `diskid/DISK-<nvme-serial>p1`)
- Two additional SATA disks (`diskid/DISK-<sata1-serial>`, `diskid/DISK-<sata2-serial>`),
  each with their own ESP registered in NVRAM
- CD drive (`cd0`)
- `kern.disks` on this system: `ada0 ada1 cd0 nda0`
- BootCurrent: `0019` ("UEFI OS" → `BOOTx64.EFI` on `diskid/DISK-<nvme-serial>p1`,
  PARTUUID `<partuuid>`)

Three ESPs are present in NVRAM (one per physical disk). The R-14 split-media
guard exists precisely to avoid updating the other two disks' ESPs in a
configuration like this.

**R-15 failure detail (`efi_root_disks` scan-all broken):**

Commit `a60e69d` (R-15) resolved the diskid vdev by calling `gpart list
diskid/DISK-xxx` to obtain the partition RAWUUID, then scanning all `kern.disks`
entries with `gpart list $d` until a UUID match was found. On Stefan's system,
`gpart list ada0`, `gpart list ada1`, `gpart list cd0`, and `gpart list nda0` all
returned empty — new behavior in FreeBSD-CURRENT. The UUID match loop exhausted
all disk names without a hit; `candidate` was never set; `root_disk_list` remained
empty. `efi_boot_bios_parts` then emitted `WARN: root disk list is empty`.

**R-16 failure detail (`efi_boot_esps` Step 3 same scan-all):**

`efi_boot_esps` Step 3 performs the same `kern.disks` scan to locate the boot
disk from the BootCurrent PARTUUID. The same empty-return behavior caused
`_boot_disks` to remain empty here too, bypassing the R-14 split-media guard
entirely. The function returned early with `WARN: cannot determine boot/root disks`.

**R-16 fixes (in commit `2f6fc32`):**

- **`efi_root_disks`:** Drop the scan-all entirely. Strip the partition suffix from
  the diskid label (`diskid/DISK-<nvme-serial>p2` → `diskid/DISK-<nvme-serial>`)
  and return the diskid provider name directly. `gpart show/list` and partition
  device paths (`/dev/diskid/DISK-xxx p1`) accept diskid provider names on all
  FreeBSD versions — no `kern.disks` iteration needed.

- **`efi_boot_esps` Step 3:** After the `kern.disks` scan yields nothing, fall back
  to scanning `_EFI_DISKID_DEV` (`/dev/diskid` by default) for diskid provider
  names and calling `gpart list diskid/DISK-xxx` for each. This restores R-14
  guard coverage for diskid-configured systems.

**R-16 validation (commit `2f6fc32`, 2026-08-25):**

Stefan re-tested with the R-16 fix. Both dry-run and live run succeeded:

```
# sh efi_bootloader_update.sh --dry-run
Boot method detected: UEFI
Processing EFI partition: diskid/DISK-<nvme-serial> partition 1 (GPT)
[DRY RUN] Would mount /dev/diskid/DISK-<nvme-serial>p1 at /tmp/tmp.HHzP23Rg1i
...
[DRY RUN] Bootloader update complete (no changes made)

# sh efi_bootloader_update.sh
Boot method detected: UEFI
Processing EFI partition: diskid/DISK-<nvme-serial> partition 1 (GPT)
Bootloader update complete
```

The script correctly identified `diskid/DISK-<nvme-serial> partition 1 (GPT)` as the boot ESP
and updated only that partition, leaving the other two disks' ESPs untouched (R-14 guard).
Stefan noted he would like an option to update all FreeBSD-fingerprinted ESPs on a
multi-disk system; logged as a potential future enhancement, out of scope for this patch.

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

### Test suite runs — revision-3 (commit 2f6fc32: gpart --libxo json + R-16)

| Date | Platform | Arch | FreeBSD | Result | Notes |
|------|----------|------|---------|--------|-------|
| 2026-08-25 | Physical workstation | amd64 | 14.0-RELEASE-p11 | ✓ 290/290 | R-16 diskid fixes and gpart --libxo json confirmed; all 43 files pass; no regressions |
| 2026-08-25 | Physical workstation | amd64 | 15.1-RELEASE-p2 | ✓ 290/290 | Clean pass on 15.x; no regressions |

### AWS Graviton EC2 — FreeBSD 13.5 aarch64 (R-17)

**Platform:** AWS EC2 Graviton instance (aarch64).
**FreeBSD:** 13.5-RELEASE, UFS root, NVMe (`nda0`), GPT, UEFI.
**Storage layout:**

```
=>       3  20971509  nda0  GPT  (10G)
         3     66584     1  efi  (33M)   [gpt/efiesp → /boot/efi]
     66587  20904925     2  freebsd-ufs  (10G)
```

**R-17 discovery:** `gpart show -p --libxo json` is not supported on FreeBSD
13.x — `gpart` exits non-zero with a usage error (`gpart: illegal option -- -`).
The `--libxo` flag for `gpart` was introduced in FreeBSD 14.x; `libxo` itself
being in base since 10.1 is not sufficient.

This caused the script to report "No EFI System Partitions found" on FreeBSD
13.x even when an EFI partition existed.  R-17 introduced `_efi_gpart_show_norm`,
a helper that tries `--libxo json` first and falls back to text-mode
`gpart show -p` parsing, synthesising the same line-per-field output the awk
parsers expect.

With `--verbose`, the fallback is visible:

```
freebsd-update: [bootloader] DEBUG: gpart --libxo unavailable for nda0; using text-mode fallback (FreeBSD 13.x)
```

**NVRAM note:** On EC2, `/dev/efi` is present and `efibootmgr` runs
successfully.  A dry-run shows the script would create a FreeBSD NVRAM boot
entry.  However, EC2 boot order is controlled by the hypervisor (the
`NVMe(0x1,...)` entry in `BootOrder`); guest NVRAM modifications have no
effect on which image the instance boots.  The NVRAM update is non-fatal by
design — if it fails or succeeds, bootloader file updates proceed normally.

**BootCurrent path:** The EC2 NVRAM entry for the boot disk uses
`PciRoot(0x0)/Pci(0x4,0x0)/NVMe(0x1,00-00-00-00-00-00-00-00)` — no
`HD(GPT,...)` component — so `boot_partuuid` is empty and the script correctly
falls back to root-disk-based ESP selection.

**14.x JSON format note:** On FreeBSD 14.x the `gpart show -p --libxo json`
output includes an additional top-level `"__version": "1"` field not present
in 13.x (which doesn't support `--libxo` at all).  After `tr ',{}[]' '\n'`
this appears as an extra line `"__version": "1"` which does not match any of
the three awk patterns (`"scheme":`, `"index":`, `"type":`) and is silently
ignored.  No code change required.

### AWS Graviton EC2 — FreeBSD 15.1-RELEASE-p3 aarch64, ZFS root

**Platform:** AWS EC2 Graviton instance (aarch64).
**FreeBSD:** 15.1-RELEASE-p3, ZFS root (`zroot`), NVMe (`nda0`), GPT, UEFI.
**Storage layout:**

```
=>       3  20971509  nda0  GPT  (10G)
         3     66584     1  efi  (33M)   [gpt/efiboot0 → /boot/efi]
     66587  20904925     2  freebsd-zfs  (10G)
```

**ZFS root path:** `efi_root_fs_type` detects `zfs`; `efi_root_disks` takes the
ZFS path: `mount --libxo json` → pool `zroot/ROOT/default` → pool name `zroot`
→ `zpool status zroot` → vdev `nda0p2` → strip partition suffix → disk `nda0`.

**ESP discovery:** `_efi_gpart_show_norm nda0` takes the JSON path (rc=0; 15.x
supports `--libxo`); `parts='nda0 1 GPT'` ✓.  `/dev/nda0p1` is not in the
mount table by device path; glabel fallback finds `gpt/efiboot0` → component
`nda0p1` → `/boot/efi` already mounted (msdosfs).

**Dry-run result:** The FreeBSD 15.1 AMI ships with `EFI/BOOT/bootaa64.efi`
(FreeBSD-fingerprinted, 2/2 heuristic matches) but without an `EFI/FreeBSD/`
directory.  The script would CREATE `EFI/FreeBSD/` and install `loader.efi`
there (new file), and UPDATE `EFI/BOOT/bootaa64.efi` (existing); would add
NVRAM entry.  No `freebsd-boot` partition (EFI-only, correct).

**NVRAM / BootCurrent:** Same EC2 topology as 13.5 and 14.4 instances —
`PciRoot(0x0)/Pci(0x4,0x0)/NVMe(0x1,00-00-00-00-00-00-00-00)`, no
`HD(GPT,...)` component → `boot_partuuid=''` → root-disk-based ESP fallback.
Guest NVRAM modifications have no effect on EC2 boot order.
`machdep.bootmethod` is absent on EC2 (sysctl OID not present); script logs
DEBUG and assumes UEFI — confirmed correct.

**New topology:** First ZFS-root EC2 Graviton test.  Confirms the
`efi_root_disks zfs` path (pool → vdev → disk) works correctly alongside the
UFS path tested on 13.5 and 14.4.

### AWS Graviton EC2 — FreeBSD 15.1-RELEASE-p3 aarch64, UFS root

**Platform:** AWS EC2 Graviton instance (aarch64).
**FreeBSD:** 15.1-RELEASE-p3, UFS root, NVMe (`nda0`), GPT, UEFI.
**Storage layout:**

```
=>       3  20971509  nda0  GPT  (10G)
         3     66584     1  efi  (33M)   [gpt/efiboot0 → /boot/efi]
     66587  20904925     2  freebsd-ufs  (10G)   [gpt/rootfs → /]
```

**UFS root path:** `efi_root_fs_type` detects `ufs`; `efi_root_disks` takes the
UFS path: `mount --libxo json` → `special=/dev/gpt/rootfs`; strip `/dev/`
prefix → `gpt/rootfs`; `realpath /dev/gpt/rootfs` returns `/dev/gpt/rootfs`
unchanged (symlink not resolved on EC2 AMI); `glabel status` → `gpt/rootfs` →
component `nda0p2`; `real=/dev/nda0p2`; strip suffix → `nda0`.

**ESP discovery:** `_efi_gpart_show_norm nda0` → JSON path (rc=0; 15.x
supports `--libxo`); `parts='nda0 1 GPT'` ✓.

**ESP mount — glabel iteration:** `efi_esp_mountpoint /dev/nda0p1` first
checks the mount table by device path → empty (ESP mounted via label, not
device).  Glabel loop: first entry `gpt/rootfs` → component `nda0p2` ≠
`nda0p1` (no match); second entry `gpt/efiboot0` → component `nda0p1` =
`nda0p1` → looks up `/dev/gpt/efiboot0` in mount table → `/boot/efi` ✓.

**Dry-run result:** Same as 15.1 ZFS instance — FreeBSD 15.1 AMI ships with
`EFI/BOOT/bootaa64.efi` (FreeBSD-fingerprinted, 2/2 matches) but without an
`EFI/FreeBSD/` directory.  Would CREATE `EFI/FreeBSD/` and install `loader.efi`
(new file), UPDATE `EFI/BOOT/bootaa64.efi` (existing); would add NVRAM entry.
No `freebsd-boot` partition (EFI-only, correct).

**NVRAM / BootCurrent:** Same EC2 NVMe topology — no `HD(GPT,...)` component
→ `boot_partuuid=''` → root-disk-based ESP fallback.  `machdep.bootmethod`
absent; script assumes UEFI.

**Relationship to other EC2 entries:** Disk topology (`nda0`, GPT, two
partitions with `gpt/` labels) is identical to the 13.5 and 14.4 UFS
instances.  This run validates the UFS root path (`gpt/` label → glabel →
component → strip suffix → disk) and the two-entry glabel loop in
`efi_esp_mountpoint` on 15.x specifically.

### AWS EC2 — FreeBSD 13.5-RELEASE-p13 amd64, UFS root

**Platform:** AWS EC2 instance (amd64).
**FreeBSD:** 13.5-RELEASE-p13, UFS root, NVMe (`nda0`), GPT, UEFI.
**Storage layout:**

```
=>       3  20971509  nda0  GPT  (10G)
         3      2048     1  freebsd-boot  (1.0M)   [gpt/bootfs, gptid/c3d1b20c-...]
      2051     66536     2  efi  (33M)              [gpt/efiesp → /boot/efi]
     68587  20902925     3  freebsd-ufs  (10G)      [gpt/rootfs → /]
```

**`machdep.bootmethod` = UEFI:** Present on amd64 (confirmed via sysctl); the OID is
arch-specific and absent on aarch64 EC2.  This is the first amd64 EC2 test.

**R-17 text fallback on amd64:** `gpart show -p --libxo json` is not supported on
FreeBSD 13.x regardless of architecture.  The `_efi_gpart_show_norm` fallback fires
for both the ESP discovery scan and the BIOS parts scan:

```
freebsd-update: [bootloader] DEBUG: gpart --libxo unavailable for nda0; using text-mode fallback (FreeBSD 13.x)
```

Confirms R-17 is not aarch64-specific — it is a FreeBSD 13.x version constraint.

**UFS root path:** `mount --libxo json` → `special=/dev/gpt/rootfs`; strip `/dev/`
→ `gpt/rootfs`; `realpath` returns unchanged (device node); `glabel status` →
component `nda0p3`; strip suffix → `nda0`.

**ESP discovery:** `_efi_gpart_show_norm nda0` text fallback → `parts='nda0 2 GPT'`
✓ (p2 = efi type).  BIOS parts scan → `parts='nda0 1 GPT'` ✓ (p1 = freebsd-boot).

**ESP mount — two-entry mount-table loop:** `efi_esp_mountpoint /dev/nda0p2` first
checks the mount table by device path → empty (ESP mounted via label).  The glabel
fallback iterates over mount table entries whose `special` field starts with `/dev/`.
On this UFS-root system, two entries match: first `special=/dev/gpt/rootfs` →
`lbl=gpt/rootfs` → glabel component `nda0p3` ≠ `nda0p2` (miss); then
`special=/dev/gpt/efiesp` → `lbl=gpt/efiesp` → glabel component `nda0p2` =
`nda0p2` → `node=/boot/efi` ✓.  (UFS root appears as `/dev/gpt/rootfs` in the mount
table, adding one extra iteration vs. ZFS root which uses a pool path.)

**Label name difference:** This amd64 AMI uses the label `gpt/efiesp` for the ESP
(vs. `gpt/efiboot0` on the Graviton aarch64 AMIs).  Different AMI builders use
different label names; the script resolves whichever label is present via glabel.

**Dry-run result:** Three-pronged update — EFI, fallback, and BIOS:
- Would CREATE `EFI/FreeBSD/` and install `loader.efi` (new file)
- Would UPDATE `EFI/BOOT/bootx64.efi` (FreeBSD-fingerprinted, 2/2 heuristic matches)
- Would add NVRAM boot entry
- Would update BIOS bootcode on `nda0p1` (freebsd-boot, UFS root → `/boot/gptboot`)

First EC2 test combining EFI and BIOS bootcode update paths.

**NVRAM / BootCurrent:** Same EC2 NVMe topology as all other EC2 instances —
`PciRoot(0x0)/Pci(0x4,0x0)/NVMe(0x1,00-00-00-00-00-00-00-00)`, no `HD(GPT,...)`
component → `boot_partuuid=''` → root-disk-based ESP fallback.  Guest NVRAM
modifications have no effect on EC2 boot order.

### AWS EC2 — FreeBSD 14.4-RELEASE-p9 amd64, ZFS root

**Platform:** AWS EC2 instance (amd64).
**FreeBSD:** 14.4-RELEASE-p9, ZFS root (`zroot`), NVMe (`nda0`), GPT, UEFI.
**Storage layout:**

```
=>       3  20971446  nda0  GPT  (10G)
         3       345     1  freebsd-boot  (173K)  [gpt/bootfs, gptid/5a7c26e6-...]
       379     66584     2  efi  (32M)             [gpt/efiesp → /boot/efi]
     66963  20904517     3  freebsd-zfs  (10G)     [label:"rootfs" in gpart; no /dev/gpt/ node]
```

**Identical partition structure to 13.5 amd64 EC2:** same p1=freebsd-boot /
p2=efi / p3=data layout with the same gpart label names.  The key difference:
p3 is `freebsd-zfs` on this instance vs. `freebsd-ufs` on the 13.5 instance.

**JSON path taken:** `gpart show -p --libxo json nda0` → rc=0; 14.x supports
`--libxo`.  No R-17 fallback.

**ZFS root path:** pool `zroot`, vdev `nda0p3` → strip suffix → `nda0`.

**glabel output (3 entries; no label for p3):**
```
gpt/bootfs     N/A  nda0p1
gptid/5a7c26e6-195b-11f1-067b-ff9d86f8dced     N/A  nda0p1
gpt/efiesp     N/A  nda0p2
```
FreeBSD does not create a `/dev/gpt/` label device for ZFS partitions — ZFS
manages the disk directly.  Compare with the 13.5 UFS instance where
`/dev/gpt/rootfs` does appear in `glabel status`.

**ESP mount — one-entry mount-table loop:** `efi_esp_mountpoint /dev/nda0p2`
direct device lookup → empty.  The glabel fallback iterates over mount table
entries with `special ~ "^/dev/"`.  On this ZFS-root system, the only such
entry is `special=/dev/gpt/efiesp node=/boot/efi`; first (and only) iteration:
`lbl=gpt/efiesp` → glabel component `nda0p2` = `nda0p2` → `/boot/efi` ✓.
(Contrast with 13.5 amd64 UFS: two iterations because `/dev/gpt/rootfs` also
appears in the mount table and must be skipped first.)

**ESP already mounted:** `/boot/efi` pre-mounted via `/etc/fstab` on the AMI.
`_efi_esp_is_real=1` → real space check runs: 32885760 B available, 1390592 B
needed → OK.

**Dry-run result:**
- Would CREATE `EFI/FreeBSD/` and install `loader.efi` (directory absent on AMI)
- Would UPDATE `EFI/BOOT/bootx64.efi` (FreeBSD-fingerprinted, 2/2 heuristic matches)
- Would add NVRAM entry
- Would update BIOS bootcode on `nda0p1` (ZFS root → `/boot/gptzfsboot`):
  `gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 nda0`

**NVRAM / BootCurrent:** Same EC2 NVMe topology:
`PciRoot(0x0)/Pci(0x4,0x0)/NVMe(0x1,00-00-00-00-00-00-00-00)`, no
`HD(GPT,...)` → `boot_partuuid=''` → root-disk-based ESP fallback.

**Summary:** First ZFS-root amd64 EC2 test.  JSON path (14.x).  Same
three-partition layout as 13.5 amd64 AMI.  One-entry mount-table loop (ZFS).
Combined EFI + BIOS update.

### AWS EC2 — FreeBSD 14.4-RELEASE-p9 amd64, UFS root

**Platform:** AWS EC2 instance (amd64).
**FreeBSD:** 14.4-RELEASE-p9, UFS root, NVMe (`nda0`), GPT, UEFI.
**Storage layout:**

```
=>       3  20971446  nda0  GPT  (10G)
         3       122     1  freebsd-boot  (61K)   [gpt/bootfs, gptid/70d8b396-...]
       156     66584     2  efi  (32M)             [gpt/efiesp → /boot/efi]
     66740  20904740     3  freebsd-ufs  (10G)     [gpt/rootfs → /]
```

**Same three-partition structure as the ZFS 14.4 amd64 instance** (p1=freebsd-boot,
p2=efi, p3=data) with one notable difference: p1 is **61KB** (122 sectors) vs
**173KB** (345 sectors) on the ZFS instance.  The AMI builder sized the
freebsd-boot partition for the expected bootcode: `gptboot` (UFS, ~30KB) fits in
61KB; `gptzfsboot` (ZFS, ~120KB) requires the larger allocation.

**JSON path taken:** `gpart show -p --libxo json nda0` → rc=0 (14.x).  No R-17
fallback.

**UFS root path:** `mount --libxo json` → `special=/dev/gpt/rootfs`; strip
`/dev/` → `gpt/rootfs`; `realpath` returns unchanged (device node on 14.x);
`glabel status` → component `nda0p3`; strip suffix → `nda0`.

**glabel output (4 entries; includes gpt/rootfs):**
```
gpt/bootfs     N/A  nda0p1
gptid/70d8b396-195b-11f1-067b-ff9d86f8dced     N/A  nda0p1
gpt/efiesp     N/A  nda0p2
gpt/rootfs     N/A  nda0p3
```
FreeBSD creates a `/dev/gpt/rootfs` label device for UFS partitions (unlike ZFS,
which manages the disk directly).  This gives the mount table a `/dev/gpt/rootfs`
entry, requiring an extra iteration in `efi_esp_mountpoint`.

**ESP mount — two-entry mount-table loop:** `efi_esp_mountpoint /dev/nda0p2`
direct device lookup → empty.  Glabel fallback iterates mount table `/dev/`
entries: iteration 1: `special=/dev/gpt/rootfs` → `lbl=gpt/rootfs` → glabel
component `nda0p3` ≠ `nda0p2` (miss); iteration 2: `special=/dev/gpt/efiesp`
→ `lbl=gpt/efiesp` → glabel component `nda0p2` = `nda0p2` → `node=/boot/efi` ✓.
(Contrast with the ZFS 14.4 instance: one iteration, because ZFS root doesn't
appear as `/dev/...` in the mount table.)

**ESP already mounted:** `/boot/efi` pre-mounted via `/etc/fstab`.
`_efi_esp_is_real=1` → real space check: 32885760 B available, 1390592 B needed
→ OK (identical to ZFS instance — same ESP size).

**Dry-run result:**
- Would CREATE `EFI/FreeBSD/` and install `loader.efi` (directory absent on AMI)
- Would UPDATE `EFI/BOOT/bootx64.efi` (FreeBSD-fingerprinted, 2/2 heuristic matches)
- Would add NVRAM entry
- Would update BIOS bootcode on `nda0p1` (UFS root → `/boot/gptboot`):
  `gpart bootcode -b /boot/pmbr -p /boot/gptboot -i 1 nda0`

**NVRAM / BootCurrent:** Same EC2 NVMe topology as all other EC2 instances —
`PciRoot(0x0)/Pci(0x4,0x0)/NVMe(0x1,00-00-00-00-00-00-00-00)`, no `HD(GPT,...)`
→ `boot_partuuid=''` → root-disk-based ESP fallback.

**Summary:** UFS counterpart to the ZFS 14.4 amd64 instance.  Same disk
topology, different root FS.  Key difference: UFS creates a `gpt/rootfs`
glabel device → 4 glabel entries (vs 3 on ZFS) → two-entry mount-table loop
(vs one).  BIOS uses `gptboot` (vs `gptzfsboot`).  Freebsd-boot partition
sized accordingly (61KB vs 173KB).

### AWS EC2 — FreeBSD 15.1-RELEASE-p3 amd64, ZFS root

**Platform:** AWS EC2 instance (amd64).
**FreeBSD:** 15.1-RELEASE-p3, ZFS root (`zroot`), NVMe (`nda0`), GPT, UEFI.
**Storage layout:**

```
=>       3  20971446  nda0  GPT  (10G)
         3       347     1  freebsd-boot  (177K)  [gpt/bootfs, gptid/e25c9452-...]
       381     66584     2  efi  (32M)             [gpt/efiboot0 → /boot/efi]
     66965  20904515     3  freebsd-zfs  (10G)     [label:"rootfs" in gpart]
```

**Label change from earlier amd64 AMIs:** This 15.x AMI uses `gpt/efiboot0`
for the ESP (vs. `gpt/efiesp` on 13.5 and 14.4 amd64 AMIs).  The script
resolves whichever label is present via glabel — no code difference.  The
`gpt/efiboot0` label matches what the Graviton (aarch64) AMIs use for all
versions.

**ZFS root path:** pool `zroot`, single vdev `nda0p3`; strip partition suffix
→ `nda0`.

**JSON path taken:** `gpart show -p --libxo json nda0` → rc=0 (15.x supports
`--libxo`).  No R-17 fallback.

**ESP mount — one-entry glabel loop:** `efi_esp_mountpoint /dev/nda0p2`
direct device lookup → empty (ESP mounted via label).  Glabel loop iterates
mount table entries whose `special` starts with `/dev/`.  On this ZFS-root
system only one such entry exists: `special=/dev/gpt/efiboot0
node=/boot/efi`; first (and only) iteration: `lbl=gpt/efiboot0` → glabel
component `nda0p2` = `nda0p2` → `/boot/efi` ✓.  (ZFS root does not produce
a `/dev/...` mount table entry, so one iteration suffices — same as the ZFS
14.4 amd64 instance.)

**`machdep.bootmethod`:** Present on amd64 EC2 (returns `UEFI`).  Contrast
with aarch64 EC2 where the OID is absent.

**glabel output (3 entries; no label for p3):**
```
gpt/bootfs     N/A  nda0p1
gptid/e25c9452-6653-11f1-067b-ff9d86f8dced     N/A  nda0p1
gpt/efiboot0   N/A  nda0p2
```
FreeBSD does not create a `/dev/gpt/` label device for ZFS partitions — ZFS
manages the disk directly.  Only the ESP label appears in the mount table.

**BootCurrent:** `0001` → `PciRoot(0x0)/Pci(0x4,0x0)/NVMe(0x1,00-00-00-00-00-00-00-00)`,
no `HD(GPT,...)` component → `boot_partuuid=''` → root-disk-based ESP fallback.

**Space check:** `_efi_esp_is_real=1` (ESP pre-mounted); real check runs:
32,882,688 B available, 1,396,736 B needed → OK.

**Dry-run result:**
- Would CREATE `EFI/FreeBSD/` and install `loader.efi` (directory absent on AMI)
- Would UPDATE `EFI/BOOT/bootx64.efi` (FreeBSD-fingerprinted, 2/2 heuristic matches)
- Would add NVRAM entry (`efibootmgr -a -c -l '/boot/efi/EFI/FreeBSD/loader.efi' -L FreeBSD`)
- Would update BIOS bootcode on `nda0p1` (ZFS root → `/boot/gptzfsboot`):
  `gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 nda0`

**freebsd-boot partition sizing:** p1 is 177KB (347 sectors) — sized for
`gptzfsboot` (~120KB).  Contrast with the 15.1 UFS instance where p1 is
sized for `gptboot` (~30KB).

**NVRAM / BootCurrent:** Same EC2 NVMe topology as all other EC2 instances —
no `HD(GPT,...)` → `boot_partuuid=''` → root-disk-based ESP fallback.  Guest
NVRAM modifications have no effect on EC2 boot order.

**Summary:** ZFS counterpart to the 15.1 amd64 UFS instance.  Both share the
same 3-partition layout with `gpt/efiboot0` label (new in 15.x amd64 AMI;
earlier versions used `gpt/efiesp`).  ZFS root → one-entry glabel loop.
JSON path (15.x).  Combined EFI + BIOS update.  freebsd-boot partition sized
for `gptzfsboot` (177KB vs 61KB for `gptboot` on the UFS instance).

### Test suite runs — R-17 (FreeBSD 13.x gpart text fallback)

| Date | Platform | Arch | FreeBSD | Result | Notes |
|------|----------|------|---------|--------|-------|
| 2026-08-27 | AWS Graviton EC2 | aarch64 | 13.5-RELEASE | ✓ 291/291 | R-17: gpart --libxo absent on 13.x confirmed; text-mode fallback working; run as root |
| 2026-08-27 | AWS Graviton EC2 | aarch64 | 14.4-RELEASE-p9 | ✓ 291/291 | JSON path taken (--libxo works on 14.x); no fallback; same NVRAM topology as 13.5 instance |
| 2026-08-27 | AWS Graviton EC2 | aarch64 | 15.1-RELEASE-p3 | ✓ 291/291 | ZFS root: pool→vdev→disk path confirmed; JSON path (15.x); first ZFS-root EC2 result |
| 2026-08-27 | AWS Graviton EC2 | aarch64 | 15.1-RELEASE-p3 | ✓ 291/291 | UFS root: gpt/rootfs label→glabel→nda0; two-entry glabel loop in esp_mountpoint confirmed |
| 2026-08-27 | AWS EC2 | amd64 | 13.5-RELEASE-p13 | ✓ 291/291 | R-17 text fallback confirmed on amd64 13.x; combined EFI+BIOS update path; gpt/efiesp label; two-entry mount-table loop (UFS root) |
| 2026-08-28 | AWS EC2 | amd64 | 14.4-RELEASE-p9 | ✓ 291/291 | JSON path (14.x); ZFS root; combined EFI+BIOS update path; same three-partition AMI layout as 13.5; one-entry mount-table loop (ZFS) |
| 2026-08-28 | AWS EC2 | amd64 | 14.4-RELEASE-p9 | ✓ 291/291 | JSON path (14.x); UFS root; combined EFI+BIOS update path; two-entry mount-table loop (UFS gpt/rootfs adds iteration); gptboot |
| 2026-08-28 | AWS EC2 | amd64 | 15.1-RELEASE-p3 | ✓ 291/291 | JSON path (15.x); ZFS root; combined EFI+BIOS update path; gpt/efiboot0 label (new in 15.x AMI); one-entry mount-table loop (ZFS); gptzfsboot |

---

## Test Suite Run Log

Chronological record of all test suite runs across the development of this patch. Each row represents one invocation of `./tests/run_tests.sh`. Environments with multiple rows reflect re-runs as fixes were applied across revisions. This log was previously maintained in the README; it is preserved here for reference.

| Date | Arch | FreeBSD | Platform | FS | Boot | Result | Notes |
|------|------|---------|----------|----|------|--------|-------|
| 2026-08-21 | amd64 | 14.0-RELEASE-p11 | Physical | ZFS | EFI+BIOS | ✓ 266/266 | First FreeBSD run; chflags schg fix (test_11) and PATH tightening (test_e09) confirmed; stray nda0 stdout in test_14 test 7 noted |
| 2026-08-21 | amd64 | 15.1-RELEASE-p2 | Physical | ZFS | EFI+BIOS | ✓ 266/266 | Pre-rollup: efibootmgr PATH restriction confirmed on 15.x; stray nda0 stdout noted |
| 2026-08-21 | amd64 | 15.1-RELEASE-p2 | Physical | ZFS | EFI+BIOS | ✓ 266/266 | Post-rollup (4cc8d91): stdout fix confirmed clean; no regressions |
| 2026-08-21 | amd64 | 14.0-RELEASE-p11 | Physical | ZFS | EFI+BIOS | ✓ 266/266 | Post-rollup (4cc8d91): stdout fix confirmed on 14.0 |
| 2026-08-21 | amd64 | 14.0-RELEASE-p11 | Physical | ZFS | EFI+BIOS | ✓ 269/269 | Post-R-09 (2ddc59e): new tests 25–26 (test_14) and test 23 (test_15) all pass |
| 2026-08-21 | amd64 | 15.1-RELEASE-p2 | Physical | ZFS | EFI+BIOS | ✓ 269/269 | Post-R-09 (3ace096): clean pass on 15.x; no regressions |
| 2026-08-23 | amd64 | 14.0-RELEASE-p11 | Physical | ZFS | EFI+BIOS | ✓ 286/286 | Post-R-14: split-media guard + loader compat docs; all new tests pass |
| 2026-08-23 | amd64 | 15.1-RELEASE-p2 | Physical | ZFS | EFI+BIOS | ✓ 286/286 | Post-R-14: clean pass on 15.x; no regressions |
| 2026-08-25 | amd64 | 14.0-RELEASE-p11 | Physical | ZFS | EFI+BIOS | ✓ 290/290 | revision-3 (2f6fc32): gpart --libxo json + R-16 diskid fix; all 43 test files pass |
| 2026-08-25 | amd64 | 15.1-RELEASE-p2 | Physical | ZFS | EFI+BIOS | ✓ 290/290 | revision-3 (2f6fc32): clean pass on 15.x; no regressions |
| 2026-08-27 | aarch64 | 13.5-RELEASE | AWS Graviton EC2 | UFS | EFI | ✓ 291/291 | R-17: gpart --libxo absent on 13.x; text-mode fallback confirmed working |
| 2026-08-27 | aarch64 | 14.4-RELEASE-p9 | AWS Graviton EC2 | UFS | EFI | ✓ 291/291 | JSON path taken on 14.x; clean pass; no regressions |
| 2026-08-27 | aarch64 | 15.1-RELEASE-p3 | AWS Graviton EC2 | ZFS | EFI | ✓ 291/291 | ZFS root: pool→vdev→disk path confirmed; first ZFS-root EC2 result |
| 2026-08-27 | aarch64 | 15.1-RELEASE-p3 | AWS Graviton EC2 | UFS | EFI | ✓ 291/291 | UFS root: gpt/rootfs label→glabel→disk; glabel loop in esp_mountpoint confirmed |
| 2026-08-27 | amd64 | 13.5-RELEASE-p13 | AWS EC2 | UFS | EFI+BIOS | ✓ 291/291 | R-17 text fallback on amd64 13.x confirmed; two-entry mount-table loop |
| 2026-08-28 | amd64 | 14.4-RELEASE-p9 | AWS EC2 | ZFS | EFI+BIOS | ✓ 291/291 | JSON path on 14.x; ZFS root; same three-partition AMI layout as 13.5 |
| 2026-08-28 | amd64 | 14.4-RELEASE-p9 | AWS EC2 | UFS | EFI+BIOS | ✓ 291/291 | JSON path on 14.x; UFS root; two-entry mount-table loop; gptboot |
| 2026-08-28 | aarch64 | 14.4-RELEASE-p9 | AWS Graviton EC2 | ZFS | EFI | ✓ 291/291 | ZFS root; machdep.bootmethod absent → UEFI assumed; gpt/efiesp glabel; 2-partition GPT; no BIOS partition; dry-run clean |
| 2026-08-28 | amd64 | 15.1-RELEASE-p3 | AWS EC2 | UFS | EFI+BIOS | ✓ 291/291 | First amd64 15.x EC2 result; same 3-partition AMI layout as 13.5/14.4 UFS; gpt/efiboot0 label; gptboot on p1; two-entry glabel loop; dry-run clean |
| 2026-08-28 | amd64 | 15.1-RELEASE-p3 | AWS EC2 | ZFS | EFI+BIOS | ✓ 291/291 | ZFS counterpart to 15.1 UFS; gpt/efiboot0 label; one-entry glabel loop (ZFS); gptzfsboot on p1 (177KB); dry-run clean |

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
