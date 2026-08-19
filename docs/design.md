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

This "promote" behaviour ensures that future invocations have a stable,
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
| `efi_root_fs_type` | Returns "zfs", "ufs", or raw type string via `mount` output |
| `efi_fallback_binary` | Returns architecture-specific fallback binary name |
| `efi_fallback_binary_for_arch` | Pure arch→filename mapping, no syscalls |

#### Discovery functions

| Function | Purpose |
|---|---|
| `efi_discover_boot_disks` | Top-level dispatcher: ZFS or UFS or fallback |
| `efi_zfs_boot_disks` | Parses `zpool status` config section for physical vdev leaves |
| `efi_ufs_boot_disks` | Reads `/etc/fstab` for root device, strips partition suffix |
| `efi_gmirror_members` | Expands a gmirror device to physical member disk names |
| `efi_efi_partitions` | Returns partition indices of type "efi" on a disk |
| `efi_bios_partitions` | Returns partition indices of type "freebsd-boot" on a disk |

#### Mounting functions

| Function | Purpose |
|---|---|
| `efi_mount_esp` | Mounts ESP at mktemp dir; reuses existing mount if present |
| `efi_unmount_esp` | Unmounts ESP if this script mounted it |
| `efi_cleanup_mounts` | EXIT/signal trap: unmounts all temp mounts |
| `efi_esp_mountpoint` | Queries `mount` output for the current mountpoint of a device |

#### Fingerprinting

| Function | Purpose |
|---|---|
| `efi_is_freebsd_loader` | Multi-string heuristic: returns 0 if file looks like FreeBSD loader |

#### File operations

| Function | Purpose |
|---|---|
| `efi_safe_copy` | Atomic copy via temp file + rename |
| `efi_check_space` | Verifies ESP has ≥ 2× loader size + 64 KiB free |

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

Three module-level variables track the current ESP mount operation:

- `_efi_esp_mp` — current mountpoint path
- `_efi_esp_did_mount` — 1 if the script mounted it (must unmount)
- `_efi_tmp_mounts` — space-separated list of all temp mounts (for EXIT trap)

---

## 4. Key Algorithms

### 4.1 Disk Discovery

#### ZFS pool parsing

1. `zfs get -H -o value name /` returns the root dataset path (e.g.
   `zroot/ROOT/default`).  The pool name is the first path component
   (`cut -d/ -f1`).

2. `zpool status <pool>` output is parsed by an `awk` program that:
   - Activates on the `config:` section header.
   - Deactivates on the `errors:` section header.
   - Skips virtual vdev names: `mirror`, `raidz*`, `spare`, `cache`, `log`,
     `replacing`, `removing`, and the `NAME` column header.
   - Emits the first field of remaining lines after stripping slice/partition
     suffixes (`/[sp][0-9]+[a-z]?$/`).
   - Filters to known device prefixes: `da`, `ada`, `nda`, `nvd`, `vtblk`,
     `xbd`, `mmcsd`, `cd`, `md`.

3. Disk names matching `gm[0-9]*` are gmirror virtual devices; these are
   expanded by `efi_gmirror_members` via `gmirror status` output parsing.

4. The final list is sorted and deduplicated with `sort -u`.

#### UFS root discovery

1. `/etc/fstab` is scanned for the line with mount point `/`, skipping
   comment lines.
2. The device field is taken, `/dev/` prefix stripped, and partition suffix
   (`/[sp][0-9]*[a-z]*$/`) stripped to yield the base disk name.

#### Why ZFS parsing is preferred over UFS

ZFS pools may span multiple disks.  The fstab approach yields at most one
device and cannot represent a mirror or raidz.  For a two-disk ZFS mirror,
both disks must be updated for the system to be resilient against losing either
disk.

### 4.2 Loader Fingerprinting

A file is classified as a FreeBSD EFI loader if at least
`_EFI_FINGERPRINT_THRESHOLD` (currently 2) of the following strings are found
in its `strings` output:

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

---

## 5. Handled Configurations

| Scenario | Boot | Root FS | Disks | Notes |
|---|---|---|---|---|
| Single disk, EFI + BIOS | UEFI | ZFS | 1 (nda0, ada0, da0, nvd0, ...) | Both ESP and freebsd-boot updated |
| Single disk, EFI only | UEFI | ZFS or UFS | 1 | No gpart bootcode call |
| Two-disk ZFS mirror | UEFI | ZFS | 2 | Both ESPs and both BIOS partitions updated |
| raidz2 (N disks) | UEFI | ZFS | N | Each disk processed independently |
| gmirror members | UEFI or BIOS | UFS | 2+ | gmirror device expanded to physical disks |
| Shared ESP, Windows fallback | UEFI | ZFS | 1 | Fallback not updated (fingerprint fails); FreeBSD path updated |
| arm64 / aarch64 | UEFI | ZFS or UFS | 1+ | BOOTaa64.efi used instead of BOOTx64.efi |
| i386 | UEFI | ZFS or UFS | 1+ | BOOTia32.efi |
| riscv64 | UEFI | ZFS or UFS | 1+ | BOOTriscv64.efi |
| BIOS-only (no EFI partition) | BIOS | ZFS or UFS | 1+ | Only gpart bootcode; no ESP processing |
| ESP already mounted at /boot/efi | UEFI | ZFS or UFS | 1+ | Existing mountpoint reused; no umount |
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

`gpart show` on an MBR-partitioned disk returns `MBR` as the scheme and uses
`freebsd` as the partition type name, not `efi` or `freebsd-boot`.
`efi_efi_partitions` and `efi_bios_partitions` will return empty, and the
script will log a verbose message that no partitions were found.  No updates
will be performed.

MBR-partitioned FreeBSD installs are uncommon on modern hardware and are
expected to be BIOS-only.  The BIOS bootcode path requires GPT partitioning.

### 6.4 Non-Standard ESP Locations

The script discovers ESPs via `gpart show` on the boot disks.  An ESP
on a non-boot disk (e.g. a USB stick used as the boot device while the root
pool lives on separate disks) will not be found.

### 6.5 UEFI Capsule Updates

This script does not update UEFI firmware itself.  Firmware updates use a
different mechanism (UEFI Capsule Update) and are out of scope.

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
