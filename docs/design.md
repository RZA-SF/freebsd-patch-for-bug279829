# Design Document: FreeBSD EFI/BIOS Bootloader Updater

**File:** `src/efi_bootloader_update.sh`
**Addresses:** FreeBSD bug [279829](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=279829)
**SPDX-License-Identifier:** BSD-2-Clause

---

## 1. Problem Statement

### 1.1 The ESP Gap in freebsd-update

`freebsd-update` reliably updates the kernel, base system binaries, and
libraries on FreeBSD installs, but it has never updated the EFI System
Partition (ESP).  The ESP is a FAT32 partition, separate from the UFS or ZFS
root filesystem.  Files on it — principally `/EFI/FreeBSD/loader.efi` and the
architecture-specific fallback `/EFI/BOOT/BOOTx64.efi` — persist across
`freebsd-update` runs untouched.

The practical consequence is that after a major version upgrade (e.g. 13 → 14
or 14 → 15), the system boots a new kernel with an old bootloader.

### 1.2 The Lua Crash in FreeBSD 14.1

FreeBSD 14.1 introduced a revised Lua-based boot menu.  When an outdated
loader.efi (e.g. from FreeBSD 13.x) attempts to run the new 14.1 boot scripts,
it crashes at the Lua runtime step and drops to an emergency loader prompt.
The system still boots — if the operator knows to type `boot` — but routine
maintenance windows see unexpected breakage, and unattended headless systems
may hang waiting for console input that never arrives.

This is the canonical scenario reported in bug 279829.

### 1.3 ZFS Forward-Compatibility Risk

The ZFS pool feature set advances with each FreeBSD major release.  If the
bootloader predates the feature flags enabled on the root pool, it may be
unable to read the pool at all, resulting in a "pool not found" failure during
boot.  This failure mode is silent and difficult to recover from without
physical access or a rescue medium.

### 1.4 Scope of This Fix

This script is designed to run from within `freebsd-update`'s post-install
hook (or standalone) on the **target** system (the one being upgraded),
updating the ESP from the freshly installed `/boot/loader.efi` before the
system reboots into the new version.

**pkgbase is out of scope.**  Systems that manage the base system via `pkg(8)`
(pkgbase) do not use `freebsd-update` for upgrades.  The same ESP gap exists
on pkgbase systems, but the correct fix there is a post-install hook in the
`FreeBSD-loader` package — a separate contribution to the pkgbase packaging
infrastructure.

---

## 2. Design Goals

### 2.1 Safety

The script must not blindly overwrite EFI binaries that belong to another
operating system.  On dual-boot or multi-OS machines, the fallback path
`/EFI/BOOT/BOOTx64.efi` is conventionally owned by whichever OS installed
last.  Overwriting a Windows Boot Manager with FreeBSD's loader.efi would
render Windows unbootable without any EFI firmware intervention.

Fingerprinting (section 4.3) is the mechanism that enforces this invariant.

### 2.2 Completeness

The script must handle all configurations that FreeBSD officially supports:

- UEFI and BIOS (legacy) boot.
- amd64, arm64, i386, riscv64 (each uses a different fallback binary name).
- ZFS root (single disk, mirror, raidz), UFS root.
- gmirror members expanded to physical disks.
- ESPs that are already mounted (`/boot/efi`) reused without double-mount.
- Fresh ESPs with no FreeBSD files (promote: create directories and NVRAM entry).

### 2.3 Idempotency

Running the script multiple times on an already-current system must produce
only informational output and no file mutations.  This matters because
`freebsd-update` may invoke the hook multiple times in a single session, and
because operators may run the script manually as a verification step.

The content-comparison implicit in the atomic copy (write `.new`, rename)
means that repeated runs do write the file each time, but the result is always
correct.  Future work could add an explicit content-hash comparison to make
repeated runs a true no-op.

### 2.4 Atomicity

FAT32 does not have journaling.  A power interruption mid-write leaves a
partial file.  A partial loader.efi renders the partition unbootable.

The mitigation is to write to a temp file (`loader.efi.new`) and then rename
it over the target.  On a FAT32 filesystem, `mv` of a file within the same
volume is effectively an atomic directory-entry swap (the old entry is replaced
in one step), so the window during which the partition is in an inconsistent
state is as narrow as the FAT driver's atomic rename operation.

A `sync` call before the rename flushes the data to disk, reducing the risk
that a power failure between the OS write and the FAT driver's directory update
leaves the new file's data blocks unwritten.

### 2.5 Promote

When the ESP has never had a `/EFI/FreeBSD/` directory (e.g. a machine that
was installed as BIOS-only and later had UEFI added, or a fresh install that
only used the fallback path), the script creates the directory and installs
loader.efi there.  It also creates an NVRAM boot entry pointing to the
OS-specific path.

This "promote" behavior ensures that future invocations have a stable,
FreeBSD-owned path to update, and that the firmware's boot order list
explicitly names FreeBSD rather than relying solely on the fallback path that
any other OS might overwrite.

---

## 3. Architecture

### 3.1 Module Structure

The script is a single POSIX sh file that can be:

1. **Executed directly:** `sh efi_bootloader_update.sh [--dry-run] [--verbose]`
2. **Sourced by freebsd-update:** `. /usr/libexec/efi_bootloader_update.sh && update_bootloaders`

The guard `[ -n "${_EFI_BOOTLOADER_UPDATE_SH:-}" ] && return 0` at the top
prevents double-sourcing (important when freebsd-update sources it in a loop).

The standalone entry point (bottom of file) detects invocation via
`$0` matching the script name, parses flags, and calls `update_bootloaders`.

### 3.2 Function Categories

#### Detection functions

| Function | Purpose |
|---|---|
| `efi_boot_method` | Returns "UEFI", "BIOS", or "unknown" via `sysctl machdep.bootmethod` |
| `efi_root_fs_type` | Returns "zfs", "ufs", or empty string via `mount --libxo json` (FreeBSD 10.1+) |
| `efi_fallback_binary` | Returns architecture-specific fallback binary name |
| `efi_fallback_binary_for_arch` | Pure arch→filename mapping, no syscalls |

#### Discovery functions

| Function | Purpose |
|---|---|
| `efi_root_disks(root_type)` | Returns disk names hosting the root filesystem: ZFS via `zpool status` (mirrors, RAIDz, diskid aliases), UFS via `mount --libxo json` (resolves GPT/diskid label aliases via `realpath`) |
| `efi_boot_esps()` | Boot-scoped ESP discovery: union of BootCurrent NVRAM PARTUUID match + `efi_root_disks`; returns `disk index scheme` tuples only for disks that boot the current system |
| `efi_boot_bios_parts()` | Boot-scoped freebsd-boot discovery: scans only root filesystem disks; returns `disk index` tuples |
| `efi_discover_all_esps` | Scan-all primitive: iterates `sysctl kern.disks`; returns `disk index scheme` tuples for every ESP on the system (used in tests and as a fallback utility) |
| `efi_discover_all_bios_parts` | Scan-all primitive: iterates `sysctl kern.disks`; returns `disk index` tuples for every `freebsd-boot` partition (used in tests) |

#### Mounting functions

| Function | Purpose |
|---|---|
| `efi_mount_esp` | Mounts ESP at mktemp dir; reuses existing mount if present |
| `efi_unmount_esp` | Unmounts ESP if this script mounted it |
| `efi_cleanup_mounts` | EXIT/signal trap: unmounts all temp mounts |
| `efi_esp_mountpoint` | Queries `mount --libxo json` for the current mountpoint of a device; two-phase: direct path match first, then `glabel status` resolution for GEOM label paths (e.g. `/dev/msdosfs/EFI`) |

#### Fingerprinting

| Function | Purpose |
|---|---|
| `efi_is_freebsd_loader` | Returns 0 if file is a FreeBSD EFI loader: primary check via `bootprog_info` pattern; 2-of-3 string heuristic fallback for pre-FreeBSD 11 binaries |

#### File operations

| Function | Purpose |
|---|---|
| `efi_safe_copy` | Atomic copy via temp file + rename |
| `efi_check_space` | Verifies ESP has ≥ 2× loader size + 64 KiB free; skipped in dry-run when ESP is not genuinely accessible (`EFI_DRY_RUN=1 AND _efi_esp_is_real=0`) |

#### EFI path management

| Function | Purpose |
|---|---|
| `efi_update_esp` | Updates /EFI/FreeBSD/ and /EFI/BOOT/ on a mounted ESP |
| `efi_ensure_nvram_entry` | Creates NVRAM boot entry if none points to /EFI/FreeBSD/loader.efi |

#### BIOS bootcode

| Function | Purpose |
|---|---|
| `efi_update_bios_bootcode` | Runs `gpart bootcode` for a freebsd-boot partition |

#### Orchestration

| Function | Purpose |
|---|---|
| `efi_check_prerequisites` | Root check, jail check, loader file existence/size check |
| `update_bootloaders` | Main entry point: prerequisites → detection → discovery → per-disk loop |

### 3.3 State Variables

Four module-level variables track the current ESP mount operation:

- `_efi_esp_mp` — current mountpoint path
- `_efi_esp_did_mount` — 1 if the script mounted it (must unmount)
- `_efi_esp_is_real` — 1 if `_efi_esp_mp` points to a real, accessible ESP
  (pre-mounted via fstab, or actually mounted by the script); 0 in dry-run
  when the "mountpoint" is an empty tmpdir. Used to suppress dry-run notices
  that are only appropriate when the ESP is not accessible.
- `_efi_tmp_mounts` — space-separated list of all temp mounts (for EXIT trap)

---

## 4. Key Algorithms

### 4.1 Disk Discovery

#### Boot-scoped discovery (primary path)

`efi_boot_esps` and `efi_boot_bios_parts` use a two-source union approach to
identify candidate disks, then scan only those disks for ESP and freebsd-boot
partitions.

**Source 1 — BootCurrent NVRAM:**
The UEFI specification requires firmware to write the index of the boot entry
used for the current boot into the `BootCurrent` NVRAM variable.  `efibootmgr -v`
exposes this.  The corresponding `Boot<XXXX>` entry contains a device path in
`HD(part,GPT,PARTUUID,...)` format.  The PARTUUID is matched against `gpart list
<disk>` output for every disk in `kern.disks` to identify the disk that hosts
the actual boot ESP.

Two `efibootmgr -v` output formats exist in practice:
- **Inline** (common): `+Boot0004* Description<TAB>HD(1,GPT,UUID,...)/File(...)`
- **dp:-line** (some firmware): `+Boot0004* Description\n       dp: HD(1,GPT,UUID,...)`

Both are handled; the PARTUUID extractor scans forward from the `Boot<XXXX>` line
until it finds `HD([0-9]*,GPT,...)` or reaches the next boot entry.

This path catches ESPs on disks that are not members of the root zpool (e.g.
an NVMe drive that holds only the ESP while the root pool is on SATA).

**Source 2 — Root filesystem disks (`efi_root_disks`):**
The root filesystem disk(s) are determined from the running system:

- **ZFS:** `mount --libxo json` identifies the root pool name; `zpool status
  <pool>` lists all vdev members.  Mirror and RAIDz members are all included.
  Vdev names that are GEOM aliases (`gpt/OptBzfs`, `diskid/...`, `gptid/...`)
  are resolved to real device paths.  `realpath /dev/<alias>` is tried first;
  if the path is unchanged (GEOM device node rather than a devfs symlink, as on
  newer kernels), a class-specific fallback resolves the backing device:
  `gpt/` and `gptid/` labels are managed by `geom_label(4)` and resolved via
  `glabel status`; `diskid/` labels are managed by `geom_diskid(4)` (a separate
  GEOM class, not enumerated by `glabel status`) and resolved by comparing
  rawuuids: `gpart list diskid/DISK-xxx` retrieves a partition UUID, then
  all rawuuids of each `sysctl -n kern.disks` entry are scanned with
  `gpart list $d` until a case-insensitive match is found.
- **UFS:** `mount --libxo json` returns the root device.  GEOM label paths
  (`gpt/PBaseUFS`, `diskid/DISK-xxx-partN`) are resolved before stripping the
  partition suffix.  `realpath` is tried first; the same class-specific fallback
  applies: `glabel status` for `gpt/`/`gptid/`/`ufs/` labels; rawuuid
  cross-reference (`gpart list diskid/DISK-xxx` → `kern.disks` scan) for
  `diskid/` labels (partition suffix stripped before the lookup).

**Split-media guard (overlap check):**
When BootCurrent identifies one or more boot disks, `efi_boot_esps` checks
whether any boot disk also appears in the root filesystem disk list.  Two
outcomes:

- **Overlap (normal or mirror):** At least one BootCurrent disk is a root
  filesystem member.  This is the common case — the same physical disk holds
  both the ESP and the root data.  All root filesystem disks are added to the
  candidate set so that every mirror member's ESP is kept in sync.

- **No overlap (split-media or dedicated boot disk):** The BootCurrent disk
  is not a root filesystem member.  Adding root disks would risk updating an
  ESP on shared media — media that may be used by multiple systems, each with
  its own boot dependencies.  Candidate disks are restricted to the BootCurrent
  disk only, and a verbose-level notice is emitted.

When BootCurrent is unavailable the overlap check does not apply: only root
filesystem disks are scanned (the pre-existing fallback behavior, documented
as a known limitation in §6.4).

**Mirror safety:**
ZFS mirror/RAIDz members are all returned by `efi_root_disks`.  When the
overlap check passes (at least one mirror member matches the BootCurrent disk),
all member disks are included so every mirror's ESP is kept in sync — critical
for survivable single-disk failures.

**Candidate deduplication:**
After the overlap check, candidate disks are deduplicated via `sort -u`.
Only ESPs on the deduplicated set are updated.  ESPs belonging to Windows,
other FreeBSD installations, or unrelated operating systems on other disks are
never touched.

**BootCurrent unavailable or non-GPT device path:**
On some firmware, `efibootmgr -v` returns only `BootCurrent: XXXX` with no
`Boot<XXXX>` entry body (observed on WDK2023 and RPi4B).  On others, full
entries are present but the active entry uses a non-GPT device path with no
extractable PARTUUID — for example `NVMe(...)` on the RPi5 (draft EDK2), or
`VenHw(...)/SD(...)` for an SD-card boot.  In all such cases the BootCurrent
path contributes nothing and the root-disk heuristic alone is used.  This
covers the common case (root filesystem on the same disk as the ESP) and is
the primary discovery path on embedded and SBC aarch64 systems.

#### sysctl kern.disks enumeration (scan-all primitive)

`efi_discover_all_esps` and `efi_discover_all_bios_parts` iterate `sysctl -n
kern.disks` and call `gpart show` on every visible disk.  These functions are
retained as utility primitives (used in the test suite and available for
diagnostic use) but are not called by `update_bootloaders` in production.

#### Partition type detection

The internal helper `_efi_gpart_show_norm` is used for partition discovery.
On FreeBSD 14.x+ it calls `gpart show -p --libxo json <disk>`; on FreeBSD
13.x (which does not support `--libxo`) it falls back to `gpart show -p`
text parsing, synthesising the same line-per-field output.  The `-p` flag
causes the partition index to appear as a JSON integer (`"index":N`) rather
than a provider name (`"name":"nda0p1"`).  JSON output is split on structural
characters via `tr ',{}[]' '\n'` so each field lands on its own line for
plain awk extraction.  See §6.9 for full details.

- **GPT** disks: ESP identified by `"scheme":"GPT"` and `"type":"efi"`.
- **MBR** disks: ESP identified by `"scheme":"MBR"` and type one of
  `fat32lba` (0x0C), `fat32` (0x0B), `efi` (0xEF), or the legacy hex
  forms `!12`/`!ef`.

Device paths are constructed accordingly:
- GPT: `/dev/<disk>p<index>` (e.g. `/dev/nda0p1`)
- MBR: `/dev/<disk>s<index>` (e.g. `/dev/mmcsd0s1`)

For `freebsd-boot` partitions (BIOS bootcode), only GPT is considered because
the `freebsd-boot` type is a GPT-specific FreeBSD invention.

#### GPT label annotations

When a GPT label is set, `gpart show -p --libxo json` emits the label as a
separate `"label":"efi0"` field.  Because named JSON fields are extracted
independently (not by column position), the label field does not affect
scheme or type parsing.

### 4.2 Loader Fingerprinting

`efi_is_freebsd_loader` uses a two-stage approach:

#### Primary check — bootprog_info pattern

Since FreeBSD 11, `newvers.sh` embeds a `bootprog_info` string in every EFI
loader binary of the form:

```
FreeBSD/<arch> EFI, Revision N.N
```

where `<arch>` is the architecture name (`amd64`, `arm64`, `arm`, `i386`,
`riscv`).  The pattern `FreeBSD/[^ ]+ EFI,` matches this string for all
architectures.  If `strings <file> | grep -E 'FreeBSD/[^ ]+ EFI,'` succeeds,
the file is immediately classified as a FreeBSD loader without consulting the
heuristic fallback.

This is a strong, unambiguous marker: no non-FreeBSD binary is expected to
contain this exact phrase.

#### Fallback — multi-string heuristic

For pre-FreeBSD 11 loaders (which predate `bootprog_info`), the function falls
back to a threshold check.  A file is classified as a FreeBSD EFI loader if at
least `_EFI_FINGERPRINT_THRESHOLD` (currently 2) of the following strings are
found in its `strings` output:

- `"FreeBSD"` — present in virtually all FreeBSD EFI binaries
- `"loader.efi"` — the canonical filename, typically present as a path string
- `"boot/lua"` — the Lua loader path, present since FreeBSD 12.0

#### Threshold rationale

Using a single string like `"FreeBSD"` creates false-positive risk: a
Windows recovery partition could contain binaries that reference "FreeBSD" in
error messages or driver metadata.  Requiring two or more strings from a set
of strings that together represent FreeBSD's specific implementation reduces
this risk substantially.

The threshold of 2 was chosen as a balance:
- It rules out casual false positives.
- It still succeeds on older FreeBSD loaders that may lack the `boot/lua`
  string (they will match on `"FreeBSD"` + `"loader.efi"`).
- Raising it to 3 would misclassify pre-12.0 loaders that predate Lua.

#### False positive risk analysis

The remaining false-positive risk is a binary that:
1. Is not a FreeBSD loader, AND
2. Contains at least two of the three fingerprint strings as printable ASCII
   sequences.

The probability is low in practice.  Windows Boot Manager does not reference
`"loader.efi"` or `"boot/lua"`.  GRUB binaries may reference `"FreeBSD"` in
their partition-type tables but do not reference `"loader.efi"`.

If a false positive were to occur, the consequence would be overwriting the
other OS's fallback binary with FreeBSD's loader.  This is why the threshold
is set conservatively, and why any future changes to the fingerprint logic
should be accompanied by testing against a corpus of known non-FreeBSD EFI
binaries.

### 4.3 Atomic Copy — FAT32 Temp-File Rename Strategy

```
src ──cp──▶ dst.new ──sync──▶ mv dst.new dst
```

1. `cp -f src dst.new` — write data to a temp name in the same directory.
2. `sync` — flush page cache to disk.
3. `mv -f dst.new dst` — rename (atomic directory-entry update on same volume).
4. `sync` — flush the updated directory entry.

The vulnerability window is the time between step 3 completing in the OS
and the directory entry reaching stable storage (step 4).  Modern drives with
write cache enabled narrow this further; on drives with power-loss protection,
the window is effectively zero.

If `mv` fails (e.g. read-only filesystem), the `.new` temp file is removed and
the function returns 1.  The original file is never touched.

### 4.4 Create and Promote

If `/EFI/FreeBSD/` does not exist on the ESP, the script:

1. Creates the directory with `mkdir -p`.
2. Installs loader.efi via `efi_safe_copy`.
3. Calls `efi_ensure_nvram_entry` to add an NVRAM boot entry pointing to
   `\EFI\FreeBSD\loader.efi`.

The rationale for always creating this path:

- The UEFI specification's fallback path (`/EFI/BOOT/BOOTx64.efi`) is shared
  and can be overwritten by any OS installer.  A dedicated OS-specific path is
  stable across multi-OS lifecycles.
- Many UEFI firmware implementations prefer explicit NVRAM entries over the
  fallback path.  Without an NVRAM entry, some firmware will boot into the
  firmware setup UI rather than the fallback path.
- After promotion, all future upgrades use the stable path, avoiding the
  fingerprinting step for that file entirely.

### 4.5 NVRAM Entry Management and EFIRT Guard

`efi_ensure_nvram_entry` manages the UEFI NVRAM boot entry.  Before attempting
any NVRAM operation it applies two precondition checks, both non-fatal:

**1. `efibootmgr` availability:**
```sh
command -v efibootmgr >/dev/null 2>&1 || {
    _efi_warn "efibootmgr not found — cannot verify NVRAM boot entry"
    return 0
}
```
`efibootmgr` is not part of the FreeBSD base system; it is a separate package
(`sysutils/efibootmgr`).  When it is absent, a warning is printed but the
function returns 0 — the fallback EFI path still allows booting.

**2. EFIRT (EFI Runtime Services) availability:**
```sh
[ -c "${_EFI_DEV_EFI}" ] || {
    _efi_verb "EFIRT (/dev/efi) unavailable — skipping NVRAM boot entry management"
    return 0
}
```
`efibootmgr` requires kernel EFI Runtime Services support (`options EFIRT`,
`device efidev`) to read and write NVRAM variables.  This manifests as the
character device `/dev/efi`.  EFIRT is present in GENERIC kernels on **amd64**
and **arm64** only; it is absent on i386, armv7, and riscv64.

When EFIRT is unavailable the function returns 0 silently (verbose-level log
only).  The ESP file updates (/EFI/FreeBSD/loader.efi, /EFI/BOOT/BOOTx64.efi)
complete normally — NVRAM management is a convenience, not a boot requirement,
because the fallback path and any pre-existing NVRAM entries remain functional.

The same EFIRT guard is applied in `efi_boot_esps` before calling
`efibootmgr -v` for the BootCurrent lookup, ensuring that BootCurrent
discovery also degrades gracefully on platforms without EFIRT.

The device path is overridable via `_EFI_DEV_EFI` (defaults to `/dev/efi`),
which allows tests to inject `/dev/null` (always a character device) to
exercise the NVRAM code paths on non-FreeBSD test hosts.

### 4.6 ESP Mountpoint Detection and GEOM Label Resolution

`efi_esp_mountpoint` determines whether a given ESP device is already mounted,
so that `efi_mount_esp` can reuse the existing mountpoint rather than calling
`mount_msdosfs` again (which would fail with "Device busy").

The lookup is two-phase:

**Phase 1 — direct path match:** scan `mount --libxo json` output for an entry
whose `special` field equals the raw device path (e.g. `/dev/da0s1` or
`/dev/nda0p1`).  This covers the common case where the fstab entry uses the
raw device.

**Phase 2 — GEOM label resolution:** when Phase 1 finds nothing, scan the
mount table for entries whose `special` field is a GEOM label path
(`/dev/msdosfs/*`, `/dev/gpt/*`, etc.) and resolve each label to its backing
component via `glabel status`.  If the resolved component matches the requested
device, that entry's mountpoint is returned.

Phase 2 is needed because `mount --libxo json` reports the `special` field as
whatever device was used to mount the filesystem.  If `/etc/fstab` references
the ESP by its FAT volume label — e.g. `/dev/msdosfs/EFI` — then that is what
`special` contains, not the underlying `/dev/da0s1`.  This is not specific to
any architecture, partition scheme, or board type: any system (amd64 server,
arm64 SBC, etc.) whose fstab uses a label-based ESP path will exhibit this
behavior.  The FAT volume label itself is arbitrary; "EFI" is conventional but
not required, and the resolution works for any label value.

---

## 5. Handled Configurations

| Scenario | Boot | Root FS | Disks | Notes |
|---|---|---|---|---|
| Single disk, EFI + BIOS | UEFI | ZFS | 1 (nda0, ada0, da0, nvd0, ...) | Both ESP and freebsd-boot updated |
| Single disk, EFI only | UEFI | ZFS or UFS | 1 | No gpart bootcode call |
| Two-disk ZFS mirror | UEFI | ZFS | 2 | Both ESPs and both BIOS partitions updated |
| raidz2 (N disks) | UEFI | ZFS | N | Each disk processed independently |
| gmirror members | UEFI or BIOS | UFS | 2+ | Physical disks returned by `efi_root_disks`; each member's ESP updated |
| MBR disk with FAT32 ESP (`fat32lba`/`fat32`/`efi`) | UEFI | any | 1+ | MBR device path uses `s` suffix; fingerprint-gated |
| Shared ESP, Windows fallback | UEFI | ZFS | 1 | Fallback not updated (fingerprint fails); FreeBSD path updated |
| Two FreeBSD installs, separate disks | UEFI | ZFS | 2 | Only current system's ESPs updated (BootCurrent + root-disk union) |
| ESP on different disk than zpool | UEFI | ZFS | 2 | BootCurrent PARTUUID match identifies ESP disk independently of pool members |
| Split-media/dedicated boot disk (BootCurrent disk ∉ root disks) | UEFI | ZFS or UFS | 2 | R-14 guard: only BootCurrent disk updated; root disks excluded from candidates |
| diskid/gptid/gpt-label vdev names in zpool | UEFI | ZFS | 1+ | `realpath /dev/<alias>` tried first; `glabel status` for `gpt/`/`gptid/` device nodes; rawuuid cross-reference via `gpart list` + `kern.disks` for `diskid/` |
| UFS root via GPT label (`gpt/PBaseUFS`) | UEFI | UFS | 1+ | `mount --libxo json` returns geom provider name; `realpath` then `glabel status` fallback |
| UFS root via diskid label (`diskid/DISK-xxx-partN`) | UEFI | UFS | 1+ | `realpath` returns path unchanged (device node); rawuuid cross-reference via `gpart list diskid/DISK-xxx` + `kern.disks` scan |
| machdep.bootmethod OID absent | UEFI | any | 1+ | aarch64/armv7/riscv64 may lack this sysctl; script assumes UEFI when OID missing |
| BootCurrent unavailable (limited firmware) | UEFI | any | 1+ | PARTUUID lookup falls through; root-disk heuristic used as sole source |
| EFIRT absent (i386, armv7, riscv64, custom kernel) | UEFI | any | 1+ | NVRAM management skipped (graceful); ESP file updates proceed normally |
| `efibootmgr` not installed | UEFI | amd64/arm64 | 1+ | Warning printed; NVRAM management skipped; ESP file updates proceed |
| arm64 / aarch64 | UEFI | ZFS or UFS | 1+ | BOOTaa64.efi used instead of BOOTx64.efi |
| i386 | UEFI | ZFS or UFS | 1+ | BOOTia32.efi |
| riscv64 | UEFI | ZFS or UFS | 1+ | BOOTriscv64.efi |
| BIOS-only (no EFI partition) | BIOS | ZFS or UFS | 1+ | Only gpart bootcode; no ESP processing |
| ESP already mounted at /boot/efi | UEFI | ZFS or UFS | 1+ | Existing mountpoint reused; no umount; handles GEOM msdosfs label paths (e.g. `/dev/msdosfs/EFI`) via `glabel status` |
| Fresh/empty ESP | UEFI | ZFS or UFS | 1+ | Directories created; NVRAM entry added |
| Running in jail | any | any | — | Returns 0 immediately (graceful skip) |
| Non-root user | any | any | — | Returns 1 with error |
| Dry-run mode | any | any | — | All actions logged; no disk changes |

---

## 6. Known Limitations

### 6.1 Hardware RAID Controllers

If the root pool resides on a hardware RAID volume (e.g. an LSI MegaRAID
logical drive presented as a single `/dev/da0`), `zpool status` will show only
the logical device.  The script updates the ESP on that device.  If the RAID
controller presents the EFI System Partition from a specific physical member
that fails, the remaining members may not be individually accessible for
bootloader updates.

Workaround: use software RAID (ZFS mirror or gmirror) instead of hardware
RAID for the boot disks.

### 6.2 Encrypted ESPs

Some configurations encrypt the EFI System Partition (non-standard; UEFI
firmware cannot decrypt it).  Such configurations are not handled because
`mount_msdosfs` cannot decrypt the partition, and the UEFI firmware itself
must be able to read the ESP without software intervention.  In practice,
encrypted ESPs on FreeBSD are rare.

### 6.3 MBR-Partitioned Disks

**MBR ≠ BIOS-only.**  MBR partition tables are common on UEFI systems,
particularly ARM single-board computers.  The official 64-bit Raspberry Pi
FreeBSD releases use MBR-partitioned SD cards with UEFI boot via U-Boot;
the same is true for many other aarch64 and armv7 embedded platforms.
`machdep.bootmethod` will return `UEFI` on these systems even though the
disk uses MBR.

MBR EFI System Partitions are detected by the gpart symbolic type names
`fat32lba` (0x0C), `fat32` (0x0B), and `efi` (0xEF) — the names gpart uses
for known MBR partition types on FreeBSD.  The legacy hex forms `!12`/`!ef`
are also accepted as a fallback.  These cover all FAT32 partition types used
on MBR disks intended as an ESP (common on ARM single-board computers such as
Raspberry Pi).

UFS root filesystems mounted via a `ufs/` GEOM label (e.g. `/dev/ufs/rootfs`)
are resolved to the underlying disk using the same `realpath`/`glabel status`
fallback as `gpt/` and `diskid/` labels.  MBR BSD-label partition suffixes
(e.g. `s2a`) are stripped correctly to recover the disk name (`da0`).

MBR device paths use the `s` suffix: `/dev/<disk>s<index>` (e.g.
`/dev/mmcsd0s1`).

**Safety gate for MBR FAT32:** Many embedded boards (e.g. Raspberry Pi) use a
FAT32 MBR partition as a firmware configuration area containing U-Boot, config
files, and non-EFI binaries.  Before writing to any MBR FAT32 partition, the
script runs `efi_is_freebsd_loader` on the existing file (if any).  If the
file does not pass the FreeBSD fingerprint check, the partition is skipped with
a warning.  This prevents overwriting U-Boot or vendor firmware.

**BIOS bootcode on MBR disks:** Not applicable.  The `freebsd-boot` partition
type is GPT-specific.  MBR systems that use BIOS boot are not handled by the
BIOS bootcode path.

### 6.4 Non-Standard ESP Locations

The script discovers ESPs via `gpart show` on the candidate disks (BootCurrent
disk union root filesystem disks).  An ESP on a disk that is neither the
BootCurrent disk nor a root filesystem member will not be found.

The BootCurrent path handles the common case where the ESP lives on a disk
that holds no root filesystem data (e.g. a dedicated boot disk or a USB stick
used as the boot medium while the root pool lives on separate NVMe drives).
If BootCurrent is unavailable (see §4.1), only root-disk members are scanned.

**Split kernel and world media:**

Some configurations place the FreeBSD kernel (and loader) on one storage
device and the root filesystem ("world") on another.  This was historically
necessary on platforms where the early-boot firmware (U-Boot or similar)
could not access a faster storage bus — the loader and kernel had to live on
media the firmware could read (e.g. SD card), while the root filesystem lived
on faster media only the kernel could access (e.g. USB3 or NVMe once the
driver was loaded).

Clarification on what BootCurrent identifies: BootCurrent points to the ESP
from which the *loader* was loaded — not necessarily the disk that holds the
kernel.  The FreeBSD loader uses UEFI file-access protocols to find and load
the kernel, so the kernel can reside anywhere the UEFI can reach via those
protocols (not limited to the ESP itself, and not limited to the same device).
The root filesystem is then mounted by the *kernel* after it takes control.
For the purposes of ESP discovery, what matters is where the loader lives
(the ESP), and that is exactly what BootCurrent captures.

In this configuration the two discovery sources behave differently:

- **BootCurrent NVRAM (when available):** The NVRAM entry for the current boot
  identifies the partition from which the firmware loaded the bootloader (the
  ESP on the boot media).  The ESP on that disk is correctly found regardless
  of where the kernel or root filesystem lives. ✓

- **Root-disk fallback (when BootCurrent is unavailable):** Only the disk
  hosting the root filesystem is scanned.  If the boot ESP is on a separate
  disk (SD card) that is not a root filesystem member, it will not be found —
  the SD card's ESP is missed.  Additionally, if the root disk (e.g. USB3)
  itself has an ESP used by other systems, the fallback will find and
  potentially update that ESP instead — which may or may not be the intended
  target.  The fingerprint gate (§4.2) prevents updating non-FreeBSD ESPs,
  but a shared FreeBSD ESP on the root disk would pass the check.

**Consequence:** On platforms where BootCurrent does not provide usable
device-path information (some ARM U-Boot configurations — see §4.1), a
split kernel/world configuration will not be handled reliably.  The
ESP must be updated manually after a `freebsd-update install` that changes
`/boot/loader.efi`.  The warning message provides guidance.

Note: marklmi observed this historically with a Rock64 board where U-Boot
did not support USB3; the loader and kernel lived on SD while the world lived
on a USB3 device shared with other aarch64 systems (which had their own ESP
on that USB3 device).  Once U-Boot gained USB3 support, the configuration
was consolidated to a single device and the limitation no longer applied.

### 6.5 UEFI Capsule Updates

This script does not update UEFI firmware itself.  Firmware updates use a
different mechanism (UEFI Capsule Update) and are out of scope.

### 6.6 freebsd-update Two-Pass Install Sequencing

A major FreeBSD version upgrade via `freebsd-update` uses two separate
`freebsd-update install` invocations, with a reboot in between:

```
freebsd-update install   ← kernel pass: installs /boot/kernel/
reboot
freebsd-update install   ← world pass: installs /boot/loader.efi, /boot/*.lua, etc.
reboot
```

`/boot/loader.efi` and the Lua boot scripts (`/boot/*.lua`) are part of the
**base/world** distribution, not the kernel set.  They are only updated on the
*world* pass (second invocation).

The script uses `cmp -s` to skip writes when the ESP destination already
matches the source (`/boot/loader.efi`).  This makes the two-pass sequence
work correctly without any special casing:

| Pass | `/boot/loader.efi` on root FS | ESP action |
|------|-------------------------------|------------|
| Kernel | Unchanged (still old version) | `cmp -s` matches → "Already up to date" → no write |
| World | Updated to new version | `cmp -s` differs → new loader copied to ESP |

**The reboot between passes is typically safe.**  At that point the old ESP
loader and old Lua scripts are still in sync with each other — neither has
been updated yet.  The new kernel is running with the old loader.

**Loader-before-kernel dependency (rare):** If release notes for the version
being installed indicate that the new kernel must have been started by the new
FreeBSD loader, update the ESP before rebooting into the new kernel.  This
script does not detect that dependency automatically — it updates the ESP on
the world pass, not the kernel pass.

The script is safe and correct when called on every `freebsd-update install`
invocation for the common case.  The source-matches-destination check provides
automatic correct sequencing for the loader/Lua compatibility concern that
motivates this patch.

### 6.7 Loader Backward Compatibility

A newer FreeBSD EFI loader can boot an older FreeBSD kernel.  This was
confirmed by inspection of the FreeBSD source tree (main branch, August 2026)
and is relevant to two design decisions: the split-media guard (§4.1) and the
two-pass install notice (§6.6).

#### Evidence from source inspection

**Metadata structures (`sys/sys/linker.h`):** The `MODINFOMD_*` constants
define the data the loader passes to the kernel at boot time.  Older kernels
iterate the metadata list and skip any type codes they do not recognize.  No
unknown field causes a boot failure; new fields are simply ignored.

**EFI loader metadata (`stand/efi/loader/bootinfo.c`):** Optional metadata
fields (such as `MODINFOMD_FW_HANDLE`) are added conditionally.  Kernels that
predate a given field receive the data they expect and ignore the rest.

**Lua boot scripts (`stand/lua/core.lua`):** The `core.loaderTooOld()` check
(`loader.version < 3000`) tests whether the *loader itself* is too old to run
the current Lua scripts — not whether the kernel is compatible with the loader.
The check fires when an old loader attempts to run new Lua scripts (the
scenario this patch addresses).  A current loader running against an old kernel
triggers no such warning: the Lua scripts execute entirely within the loader
environment and contain no kernel version checks.

**No kernel-side loader version validation:** The kernel does not read
`loader.version` at boot.  There is no handshake protocol between loader and
kernel that could cause a boot failure from a version mismatch in either
direction.

#### Practical conclusion

A loader from a current FreeBSD release (15.x or 16-CURRENT) can boot kernels
from significantly earlier releases (14.x, 13.x).  The loader-to-kernel
metadata interface is additive and has been kept stable across major versions.

#### Implications for this patch

**Split-media guard (§4.1 / R-14):** When the overlap check prevents updating
a shared portable ESP, the loader version on that ESP is left unchanged.  When
the check allows an update (the common case), any newer loader placed on a
shared ESP remains backward compatible with older FreeBSD kernels on the other
systems that boot from it — the update does not harm those systems.

**Two-pass install sequencing (§6.6):** Because a newer loader is backward
compatible with any recent kernel, the inter-pass reboot (new kernel, old ESP
loader) is safe in the common case.  The "loader-before-kernel" notice in §6.6
applies only to the rare event where a specific release changes the
loader-to-kernel interface in a backward-incompatible way.

#### Testing feedback sought

The backward compatibility conclusion above is based on source inspection and
is consistent with FreeBSD's historically stable boot interface.  It has not
been verified empirically across the full span of 13.x through 16-CURRENT.

Feedback is especially welcome from operators who run configurations where the
loader and kernel span more than two major versions — whether intentionally
(split-media, shared portable ESP, dedicated boot disk) or as a result of a
long-deferred upgrade.  Reports of any loader/kernel mismatch that caused a
boot failure would affect the wording of the §6.4 and §6.6 notices.

If you have tested this script in such a configuration, please open an issue at
the project repository or add a note to [docs/hardware-reports.md](hardware-reports.md).

### 6.8 32-Bit EFI Fallback Binary (`BOOTia32.efi`)

On amd64 systems, some firmware configurations load a 32-bit EFI binary
(`/EFI/BOOT/BOOTia32.efi`) in addition to the 64-bit binary
(`/EFI/BOOT/BOOTx64.efi`).  The 32-bit EFI loader for FreeBSD is
`/boot/loader_ia32.efi`.

This script does not update `BOOTia32.efi` because the source file is not
reliably present:

- `/boot/loader_ia32.efi` is only included in the amd64 base distribution on
  FreeBSD 14.x and later.  It is absent on 13.x and on non-amd64 architectures.
- There is no equivalent source binary named `bootia32.efi` in the FreeBSD
  base system; the name `BOOTia32.efi` is the UEFI fallback convention.

The consequence is that on an amd64 system with a 32-bit EFI entry on the ESP,
`BOOTia32.efi` will not be updated by this script even when
`/boot/loader_ia32.efi` is available.  The system continues to boot via the
64-bit path (`BOOTx64.efi` or the NVRAM `EFI/FreeBSD/loader.efi` entry).

**Possible resolution:** Detect `/boot/loader_ia32.efi` and, when present,
update `BOOTia32.efi` using the same fingerprint-gated safe-copy logic applied
to the 64-bit fallback.  This requires handling the absent-source case
gracefully on 13.x and non-amd64 hosts.

This is tracked as open review item #2 (imp, D58990).

### 6.9 `gpart show` parsing — `_efi_gpart_show_norm` (Implemented)

All four `gpart show` parsing sites (`efi_discover_all_esps`,
`efi_discover_all_bios_parts`, `efi_boot_esps` Step 5, `efi_boot_bios_parts`)
call the internal helper `_efi_gpart_show_norm` rather than invoking
`gpart show -p --libxo json` directly.

**Why the helper exists (R-17):** `gpart --libxo` is only available on FreeBSD
14.x and later.  FreeBSD 13.x `gpart` does not recognise `--libxo` at all and
exits non-zero with a usage error.  This was discovered on an AWS Graviton EC2
instance running FreeBSD 13.5-RELEASE aarch64.

`_efi_gpart_show_norm` tries `gpart show -p --libxo json` first.  If that
exits non-zero or returns empty output, it falls back to `gpart show -p`
(text-mode) and synthesises the identical line-per-field output that the
callers' awk scripts expect:

```
"scheme":"GPT"
"index":1
"type":"efi"
"scheme":"GPT"
"index":2
"type":"freebsd-ufs"
```

This means the four awk parsers are unchanged; only the data source differs.
When `EFI_VERBOSE=1`, the fallback emits a `DEBUG:` line identifying the disk
and the reason.

**FreeBSD 14.x+ (JSON path):**

```sh
gpart show -p --libxo json "$disk" 2>/dev/null | tr ',{}[]' '\n'
```

The `-p` flag is required to emit the partition index as `"index":N`
(integer); without it, only `"name":"nda0p1"` appears.

**FreeBSD 13.x text fallback:**

```sh
gpart show -p "$disk" 2>/dev/null | awk '
    { for (i=1;i<=NF;i++) if ($i=="GPT"||$i=="MBR") scheme=$i }
    scheme!="" && NF>=4 && $3~/[ps][0-9]+$/ {
        name=$3; type=$4
        sub(/^.*[ps]/,"",name); idx=name+0
        if (idx>0) {
            print "\"scheme\":\"" scheme "\""
            print "\"index\":" idx
            print "\"type\":\"" type "\""
        }
    }
'
```

With `-p`, the third field of each partition row is the full device name
(e.g. `nda0p1`); stripping the disk prefix and `p`/`s` separator yields the
numeric index.

**Callers' awk pattern (unchanged):**

```sh
_efi_gpart_show_norm "$disk" | \
    awk -v d="$disk" '
        /^"scheme":/ { gsub(/^"scheme":"/, ""); gsub(/"$/, ""); scheme = $0 }
        /^"index":/  { gsub(/^"index":/,  ""); idx = $0 + 0; type = "" }
        /^"type":/   { gsub(/^"type":"/, "");  gsub(/"$/, ""); type = $0
                       if (idx > 0 && ...) print d, idx, scheme }
    '
```

`type = ""` on each new `"index":` line ensures per-partition isolation.
`idx > 0` guards against the degenerate `"index":0` case (not emitted by
gpart in practice).

---

## 7. Security Considerations

### 7.1 Why Fingerprinting Is Critical

Blindly overwriting `/EFI/BOOT/BOOTx64.efi` with FreeBSD's loader.efi on a
dual-boot machine is a silent denial-of-service attack against the other OS.
The user's Windows, Linux, or recovery environment becomes unbootable from the
UEFI fallback path.  They may still be accessible via UEFI NVRAM entries, but
many users do not know how to navigate UEFI boot menus.

Fingerprinting ensures that only binaries that already identify themselves as
FreeBSD loaders are replaced.  The OS-specific path (`/EFI/FreeBSD/`) is
always safe to update because no other OS places files there.

### 7.2 Root Requirement

The script requires root (`id -u == 0`) because:
- Mounting a FAT32 partition (`mount_msdosfs`) requires root.
- Writing UEFI NVRAM entries (`efibootmgr`) requires root.
- Running `gpart bootcode` requires root.

This is consistent with `freebsd-update`'s own root requirement.

### 7.3 Jail Detection

Inside a FreeBSD jail, device access and raw disk operations are prohibited.
The script detects this via `sysctl security.jail.jailed` and exits 0
(graceful skip) rather than 1 (error).  This prevents `freebsd-update` from
treating jail-hosted systems as failed updates.

### 7.4 Temp File Permissions

`efi_safe_copy` writes to `dst.new` in the same directory as the destination
file.  On a FAT32 ESP, there are no POSIX permissions; all files are
world-readable by default in the filesystem driver.  The EFI loader binary
is not a secret, so this is not a concern.  The temp file's existence is
transient; any failure causes it to be removed.

### 7.5 No Signature Verification

This script does not verify GPG or UEFI Secure Boot signatures on the source
loader.  It trusts that `/boot/loader.efi` (or `EFI_LOADER_SRC`) was
installed by `freebsd-update` via the signed base distribution, and that
the overall system integrity is enforced at the `freebsd-update` level.

If Secure Boot is active, the firmware will reject an unsigned loader
regardless of what this script writes.  The Secure Boot signing infrastructure
is outside the scope of this script.
