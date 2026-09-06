# FreeBSD EFI Bootloader Auto-Update Patch

This repository contains a patch for `freebsd-update` that automatically updates the EFI bootloader on the ESP (EFI System Partition) during `freebsd-update install`. Without this fix, upgrading FreeBSD across major versions can silently leave a stale bootloader on the ESP — one that cannot boot the newly installed system.

The patch is developed here ahead of submission to the FreeBSD project via Phabricator. It has been tested on real FreeBSD hardware across multiple versions with a 312-test suite covering unit, integration, and error conditions across a broad range of configurations.

**Addresses:** [FreeBSD bug 279829](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=279829)
**Upstream status:** Closed "Not a bug" — but the underlying hazard is real and ongoing

---

## Current Status

| | |
|---|---|
| Test suite | 312 / 312 passing |
| Live run | ✓ Complete — FreeBSD 14.0-RELEASE-p11, amd64, UEFI, ZFS, NVMe |
| Phabricator submission | ✓ [D58990](https://reviews.freebsd.org/D58990) — revision-3 uploaded (D58990?id=185468); revision-4 in preparation |
| Backport targets | `main` (15-CURRENT), `stable/14`, `stable/13` |

### Test Suite Run History

312/312 tests passing. Validated across:
- **Architectures:** amd64, aarch64
- **FreeBSD versions:** 13.5, 14.0, 14.3, 14.4, 15.1 (RELEASE and CURRENT)
- **Root filesystems:** ZFS, UFS
- **Boot:** EFI-only, EFI+BIOS (gptboot/gptzfsboot), 32-bit UEFI (amd64 with 32-bit EFI firmware)
- **Platforms:** physical workstation, AWS EC2, AWS Graviton

Full run log and per-environment detail: [docs/hardware-reports.md](docs/hardware-reports.md#coverage-matrix).

---

## Am I Affected?

You are at risk if **all three** of the following are true:

1. Your system boots via UEFI (check: `sysctl machdep.bootmethod` returns `UEFI`; on aarch64/armv7/riscv64 UEFI is assumed if this OID is absent)
2. You have upgraded across a FreeBSD major version using `freebsd-update` (e.g., 13 → 14, or 14 → 15)
3. You have not manually copied `/boot/loader.efi` to your ESP after the upgrade

If you have run `zpool upgrade` since a major-version upgrade without updating the ESP loader first, **your system may be unbootable after the next reboot** without external media. The old loader cannot read new ZFS pool feature flags.

To check whether your ESP loader is current:

```sh
# Find your ESP device
gpart show | grep efi

# Mount it (adjust device as needed)
mount -t msdosfs /dev/nda0p1 /mnt

# Compare sizes and dates — they should be close
ls -la /mnt/EFI/FreeBSD/loader.efi /mnt/EFI/BOOT/BOOTx64.efi /boot/loader.efi
```

If the ESP files are significantly older than `/boot/loader.efi`, run this patch's standalone script (see Quick Start below) or copy manually.

---

## The Problem

When `freebsd-update upgrade` installs a new FreeBSD major version, it updates files on the root filesystem — including `/boot/loader.efi` and `/boot/lua/core.lua`. However, the UEFI firmware does not read from `/boot/`. It reads from the **EFI System Partition (ESP)**, a separate FAT32 partition that `freebsd-update` never touches.

The result: the new Lua scripts are installed expecting a current bootloader, but the firmware boots the old `loader.efi` from the ESP. In FreeBSD 14.1, the `lua_path == nil` compatibility shim was removed from `core.lua`, making this mismatch a hard crash:

```
LUA ERROR: /boot/lua/core.lua:68: attempt to concatenate a nil value (field 'lua_path')
```

The system cannot boot automatically. Manual intervention (typing `boot` at the loader prompt) works around it, but most users never discover this until they are staring at a broken machine.

**The ZFS risk is worse.** If the user runs `zpool upgrade` after a FreeBSD upgrade without first updating the ESP loader, the system becomes **completely unbootable**: the old loader cannot read new ZFS pool feature flags, and there is no manual recovery path without external media.

### Why It Was Closed "Not a Bug"

Updating the ESP has been a documented requirement for multiple FreeBSD versions. `freebsd-update` intentionally limits itself to the root filesystem. The specific failure in 14.1 simply made a pre-existing omission visible as a hard error.

Warner Losh, one of FreeBSD's primary boot maintainers, acknowledged the issue as *"a huge big rock sticking out for people to trip over"* and called for tooling to automate the update. This patch provides that tooling.

---

## This Patch

This patch adds `efi_bootloader_update.sh` to the FreeBSD source tree and hooks it into `freebsd-update install` so that EFI and BIOS bootloaders are updated automatically as part of every install run.

### What It Does

The script identifies the ESP(s) belonging to the **currently running system** using a two-step approach:

1. **EFI BootCurrent** (when available): reads the `BootCurrent` NVRAM variable via `efibootmgr`, extracts the GPT partition UUID from the active boot entry's device path, and matches it against `gpart list` output to identify the exact disk and partition the firmware booted from. Skipped gracefully if `efibootmgr` is unavailable or EFI Runtime Services (`/dev/efi`) are absent.

2. **Root filesystem disks** (always): determines which physical disk(s) host the root filesystem — via `zpool status` for ZFS (handles mirrors, RAIDz, diskid aliases) or `mount --libxo json` for UFS — and includes their ESP partitions.

The **union** of both sets is used as candidates. This ensures:
- Mirror members all get their ESP updated (BootCurrent finds one disk; root-disk heuristic finds all mirror members)
- ESPs on unrelated disks are never touched (Windows ESPs, other FreeBSD installations on separate drives)
- Split-media configurations are handled correctly: BootCurrent (when available) identifies the ESP disk even when it differs from the root pool disk

**For each candidate EFI System Partition:**
1. Mounts it (or reuses an existing mount)
2. Updates `/EFI/FreeBSD/loader.efi` — creating the directory if absent (**promote**)
3. Updates `/EFI/BOOT/BOOTx64.efi` (or arch equivalent) **only if** it fingerprints as a FreeBSD loader — protecting other OSes on a shared ESP
4. Creates an NVRAM boot entry pointing to `/EFI/FreeBSD/loader.efi` if none exists — requires `efibootmgr` and EFI Runtime Services (`/dev/efi`); skipped gracefully when either is unavailable
5. Unmounts the ESP

**For BIOS freebsd-boot partitions** (scoped to root filesystem disks only):
1. Finds `freebsd-boot` typed partitions on root pool disks via `gpart show`
2. Writes the correct bootcode: `gptzfsboot` for ZFS roots, `gptboot` for UFS

### What "Promote" Means

Many older FreeBSD installations (including systems upgraded through multiple major versions) only have the fallback EFI path (`/EFI/BOOT/BOOTx64.efi`) and no OS-specific `/EFI/FreeBSD/` directory. This patch creates the OS-specific directory and installs the loader there. On systems where NVRAM management is available (`efibootmgr` + `/dev/efi`), an explicit boot entry is also created pointing to the new path — giving the firmware a direct, unambiguous FreeBSD boot target.

After the first run, the system has a clean, stable FreeBSD-specific EFI path. All future upgrades update `/EFI/FreeBSD/loader.efi` directly, with no ambiguity about which OS owns which file.

---

## Supported Configurations

| Configuration | Supported |
|---|---|
| Single disk, EFI + freebsd-boot (UEFI + BIOS capable) | ✓ |
| Single disk, EFI only | ✓ |
| Single disk, freebsd-boot only (BIOS-only system) | ✓ |
| ZFS mirror (2+ disks, each with ESP) | ✓ all members updated |
| ZFS raidz (3+ disks) | ✓ |
| gmirror root | ✓ |
| UFS root filesystem | ✓ |
| ZFS root filesystem | ✓ |
| ZFS pool with diskid/gptid/gpt-label vdev names | ✓ resolved via `realpath`; `glabel status` fallback if path is a device node |
| UFS root via GPT label (e.g. `/dev/gpt/PBaseUFS`) | ✓ resolved via `realpath`; `glabel status` fallback if path is a device node |
| UFS root via UFS GEOM label (e.g. `/dev/ufs/rootfs`) | ✓ resolved via `realpath`; `glabel status` fallback if path is a device node |
| ESP not in `/etc/fstab` (auto-detected) | ✓ |
| ESP already mounted at any path | ✓ reused |
| ESP on different disk than ZFS pool | ✓ via BootCurrent |
| FreeBSD-only disk | ✓ |
| Multi-OS, shared ESP (FreeBSD + Windows/Linux) | ✓ safe |
| Multi-OS, separate disks (e.g. Windows on nda0, FreeBSD on da1) | ✓ only FreeBSD disk updated |
| Multiple FreeBSD installations on separate disks | ✓ only booted system updated |
| Split-media: boot disk (BootCurrent) differs from root filesystem disk | ✓ R-14 guard — only boot disk ESP updated; root disk excluded |
| `/EFI/FreeBSD/loader.efi` already exists | ✓ updated |
| Only fallback `/EFI/BOOT/BOOTx64.efi` exists | ✓ updated + promoted |
| Neither path exists (blank ESP) | ✓ both created |
| amd64 / x86_64 | ✓ |
| arm64 / aarch64 | ✓ |
| armv7 (32-bit ARM EFI) | ✓ |
| amd64 with 32-bit UEFI firmware | ✓ |
| RISC-V (riscv64) | ✓ |
| `machdep.bootmethod` OID absent (aarch64/armv7/riscv64) | ✓ assumes UEFI |
| Running inside a jail | ✓ skipped gracefully |
| Without EFIRT (`/dev/efi` absent — i386, armv7, riscv64, custom kernels) | ✓ NVRAM management skipped gracefully; ESP files still updated |
| `efibootmgr` not installed | ✓ NVRAM management skipped with warning; ESP files still updated |
| Hardware RAID (disks not visible) | Warns, instructs manual update |
| Encrypted ESP | Not supported (extremely rare) |
| MBR disks with FAT32 ESP (`fat32lba`/`fat32`/`efi` gpart types) | ✓ supported — MBR ≠ BIOS-only; common on ARM SBCs (RPi, etc.) booting UEFI via U-Boot |

### Multi-OS Safety

The fallback path (`/EFI/BOOT/BOOTx64.efi`) is only updated if the existing file is identified as a FreeBSD loader. The fingerprint check uses two tiers:

1. **Primary**: match the `bootprog_info` string embedded by `newvers.sh` in all FreeBSD loaders since FreeBSD 11 — pattern `FreeBSD/[^ ]+ EFI[ ,]`. This covers the pre-14.0 format (`FreeBSD/amd64 EFI, Revision 1.1`) and the 14.0+ format (`FreeBSD/amd64 EFI loader, Revision 1.1`), as well as the ia32 variant (`FreeBSD/amd64-ia32 EFI loader, Revision 3.0`). Specific enough to eliminate false positives from other EFI binaries.
2. **Fallback**: multi-string heuristic requiring 2 of 3 markers: `"FreeBSD"`, `"loader.efi"`, `"boot/lua"`. Covers older binaries that predate the `bootprog_info` format.

If the fallback binary is owned by another OS (e.g., Windows Boot Manager), it matches neither check and is left entirely untouched. FreeBSD boots via the OS-specific `/EFI/FreeBSD/loader.efi` path — through its NVRAM entry where NVRAM management is available, or via firmware fallback scanning on platforms without EFI Runtime Services.

---

## Repository Structure

```
freebsd-patch-for-bug279829/
├── README.md                            ← You are here
├── freebsd-update-efi.patch            ← Patch for main (15-CURRENT)
├── freebsd-update-efi-stable14.patch  ← Backport for stable/14
├── freebsd-update-efi-stable13.patch  ← Backport for stable/13
├── src/
│   └── efi_bootloader_update.sh        ← The bootloader update library (source of truth)
├── tests/
│   ├── README.md                        ← Test suite documentation
│   ├── run_tests.sh                     ← TAP test runner
│   ├── lib/
│   │   ├── mock_framework.sh            ← Command mock/stub system
│   │   └── test_helpers.sh             ← TAP assertions and ESP fixtures
│   ├── fixtures/                        ← Sample command output files
│   ├── unit/                            ← Unit tests (16 files)
│   ├── integration/                     ← Integration tests (16 files, includes R-14 split-media guard, ia32 scenarios)
│   ├── error_conditions/               ← Error/boundary/negative tests (15 files)
│   └── regression/                      ← Regression index (R-01 through R-14)
├── contrib/
│   ├── howto-ia32-uefi-nvram-windows.md ← HOWTO: adding FreeBSD NVRAM entry on 32-bit UEFI with Windows
│   └── upgrade-guide.md                 ← Safe vs. hazardous upgrade paths; recovery procedures
└── docs/
    ├── design.md                        ← Technical design and rationale
    ├── backport-guide.md                ← Per-version submission instructions
    ├── testing-guide.md                 ← How to run tests on Linux and FreeBSD
    └── hardware-reports.md              ← Community hardware test reports and contributor findings
```

---

## Quick Start

### Running Standalone on FreeBSD

```sh
# Dry run — shows what would be done without making changes
sh src/efi_bootloader_update.sh --dry-run --verbose

# Live run (requires root)
sudo sh src/efi_bootloader_update.sh --verbose
```

### Running the Test Suite

Tests run on Linux (development) and FreeBSD (full validation). No root access or real disks are needed — all commands are mocked.

```sh
# Run all tests
sh tests/run_tests.sh

# Run only unit tests
sh tests/run_tests.sh --unit

# Run only integration tests
sh tests/run_tests.sh --integration

# Run only error condition tests
sh tests/run_tests.sh --errors

# Filter by name pattern
sh tests/run_tests.sh mirror
```

### Applying the Patch to FreeBSD Source

See [freebsd-update-efi.patch](freebsd-update-efi.patch) for the full diff and step-by-step application instructions.

---

## How `freebsd-update` Integration Works

The patch adds a call to `update_bootloaders_after_install()` inside `install_run()` in `freebsd-update.sh`. This function sources `/usr/libexec/efi_bootloader_update.sh` and calls `update_bootloaders`.

The hook runs **after the new world is installed but before the user is told to reboot**, so the updated bootloader is on the ESP before the firmware ever attempts to boot the new system.

The call is deliberately non-blocking: if the bootloader update fails (hardware RAID, unusual topology, read-only ESP), a warning is printed but `freebsd-update install` still succeeds. The user is given clear instructions for manual remediation.

```
freebsd-update: [bootloader] INFO:  Boot method detected: UEFI
freebsd-update: [bootloader] INFO:  Processing EFI partition: nda0 partition 1 (GPT)
freebsd-update: [bootloader] INFO:  Creating /tmp/tmp.XXXXXX/EFI/FreeBSD/ and installing loader
freebsd-update: [bootloader] INFO:  Updated: /tmp/tmp.XXXXXX/EFI/FreeBSD/loader.efi
freebsd-update: [bootloader] INFO:  Updated: /tmp/tmp.XXXXXX/EFI/boot/BOOTx64.efi
freebsd-update: [bootloader] INFO:  Adding NVRAM boot entry: FreeBSD → \EFI\FreeBSD\loader.efi
freebsd-update: [bootloader] INFO:  Updated 2 EFI loader file(s) on /dev/nda0p1
freebsd-update: [bootloader] INFO:  Updating BIOS bootcode on nda0p2 (zfs)
freebsd-update: [bootloader] INFO:  Bootloader update complete
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `EFI_LOADER_SRC` | `/boot/loader.efi` | Source loader to copy to ESP |
| `EFI_DRY_RUN` | `0` | Set to `1` to show actions without executing |
| `EFI_VERBOSE` | `0` | Set to `1` for debug output |
| `EFI_NVRAM_UPDATE` | `1` | Set to `0` to skip NVRAM boot entry management |
| `EFI_BIOS_PMBR` | `/boot/pmbr` | PMBR boot record for BIOS boot |
| `EFI_BIOS_ZFS_BOOT` | `/boot/gptzfsboot` | GPT ZFS boot program |
| `EFI_BIOS_UFS_BOOT` | `/boot/gptboot` | GPT UFS boot program |
| `_EFI_LOADER_IA32_SRC` | `/boot/loader_ia32.efi` | Source binary for the 32-bit EFI fallback loader (amd64 14.3+ only; absent on 13.x and 14.0–14.2; skip if not present). Leading underscore denotes an override variable — not part of the primary public interface. |

The hook as a whole can be disabled via `UpdateBootloader no` in `freebsd-update.conf`.

---

## Relationship to Warner Losh's D45890

Warner Losh proposed a complementary fix (Phabricator review D45890, targeted for FreeBSD 14.3) that adds version-check logic to the Lua loader: if the ESP loader version does not match the installed system, a warning is displayed at boot.

These two patches are complementary, not competing:

- **D45890** — *defensive*: warns the user at boot time that the loader is stale
- **This patch** — *proactive*: fixes the staleness automatically during `freebsd-update install`

The ideal outcome is both patches in the tree. D45890 catches any edge cases this patch misses (hardware RAID, unusual configs); this patch prevents the problem from occurring in the common case.

---

## Backport Targets

| Branch | Priority | Rationale |
|---|---|---|
| `main` (15-CURRENT) | Primary | Submit here first (standard FreeBSD practice) |
| `stable/14` | High | Most affected users; 14→15 upgraders need this in 14's script |
| `stable/13` | Medium | Still active; 13→14 upgraders |
| `stable/12` | Skip | EOL December 2023 |

See [docs/backport-guide.md](docs/backport-guide.md) for submission instructions.

---

## pkgbase Scope

This patch is scoped to `freebsd-update`. Systems using [FreeBSD pkgbase](https://wiki.freebsd.org/PkgBase) — where the base system is managed via `pkg(8)` packages rather than `freebsd-update` — are **not covered** by this patch.

On a pkgbase system, `/boot/loader.efi` is owned by the `FreeBSD-loader` package (or equivalent). Updates arrive via `pkg upgrade`, not `freebsd-update`. The same ESP gap exists but requires a different solution: a post-install hook in the `FreeBSD-loader` package that runs the equivalent of `efi_bootloader_update.sh` after the package is installed.

That hook is out of scope for this patch and would be a separate pkgbase contribution.

---

## Known Limitations

- **Hardware RAID**: Physical disk devices are not visible through the RAID controller. The script prints a warning and instructs manual update.
- **Encrypted ESP**: Extremely rare; not supported. The mount fails with a generic error and the partition is skipped.
- **MBR (non-GPT) disks**: Supported. ESP detected by gpart type names `fat32lba` (0x0C), `fat32` (0x0B), and `efi` (0xEF). MBR device paths use the `s` suffix (e.g. `/dev/da0s1`). Safety: the MBR FAT32 partition is only written if `efi_is_freebsd_loader` confirms a FreeBSD loader signature is present (fingerprint-gated, prevents overwriting U-Boot or other bootloaders on embedded systems).
- **FAT32 atomicity**: `mv` on FAT32 is not truly atomic. A power failure between the `cp` and `mv` could leave the ESP in an inconsistent state. The temp-file approach minimises the window but cannot eliminate the risk entirely. This is inherent to any ESP update operation.
- **BootCurrent unavailable**: Some firmware (notably certain ARM platforms) does not expose full NVRAM boot entries via `efibootmgr`. The script falls back to the root-filesystem-disk heuristic automatically.
- **Split kernel and world media**: BootCurrent identifies where the loader/ESP is — not where the kernel is. The FreeBSD loader uses UEFI file-access protocols to find and load the kernel, so the kernel can be anywhere the UEFI can reach. BootCurrent discovery correctly finds the ESP regardless of where the kernel or root filesystem lives. When BootCurrent is available and identifies a boot disk that is not a root filesystem member (split-media configuration), the R-14 guard restricts ESP updates to the boot disk only — the root disk's ESP is excluded. If BootCurrent is unavailable (some U-Boot configurations), only the root-filesystem disk is scanned: the ESP on separate boot media will be missed, and if the root disk itself has a shared ESP that passes the fingerprint check it may be updated instead. Manual ESP update is required in that case. See [docs/design.md](docs/design.md) §6.4 for full detail.
- **Loader-before-kernel dependency (rare)**: If release notes for the version being installed indicate that the new kernel must have been started by the new FreeBSD loader, update the ESP before rebooting into the new kernel. This script updates the ESP on the world pass (not the kernel pass) and cannot detect this dependency automatically.
- **EFIRT unavailable**: Platforms without EFI Runtime Services kernel support (`options EFIRT`, `/dev/efi`) — i386, armv7, riscv64, and custom kernels — cannot use `efibootmgr` for NVRAM management. The NVRAM step is skipped gracefully; ESP file updates still complete normally.
- **32-bit EFI fallback (`BOOTia32.efi`)**: On amd64 systems with 32-bit UEFI firmware, the script detects `/boot/loader_ia32.efi` (present on FreeBSD 14.3+ amd64; absent on 13.x and 14.0–14.2) and updates `/EFI/BOOT/BOOTia32.efi` on the ESP using the same fingerprint-gated safe-copy logic applied to the 64-bit fallback. If `BOOTia32.efi` is owned by another OS (e.g. Windows Boot Manager), it is left untouched and a warning is printed. NVRAM management is skipped on 32-bit UEFI — FreeBSD's `efirt(4)` driver cannot attach to 32-bit UEFI runtime services, so `/dev/efi` is never created and `efibootmgr` is unavailable. One-time manual NVRAM setup is required; see [contrib/howto-ia32-uefi-nvram-windows.md](contrib/howto-ia32-uefi-nvram-windows.md) for the procedure. See [docs/design.md](docs/design.md) §6.8.
- **`--dry-run` mode**: When the ESP is *not* already mounted, two things are skipped: (1) the free-space check (which would otherwise measure the root filesystem rather than the ESP and report a misleading number); (2) existing file and directory detection on the ESP — output reflects what would happen on a blank ESP. A notice is printed per partition to make this clear. When the ESP *is* already mounted (e.g. via `/etc/fstab`), dry-run operates on the real ESP: the space check runs against the actual ESP, existing files are detected, and the fingerprint guard on the fallback binary is exercised — producing fully accurate output.

---

## Feedback and Contributions

This patch is being developed in the open before upstream submission. If you:

- Have a configuration that is not covered (unusual disk topology, firmware, architecture)
- Find a bug or incorrect behavior in the script or test suite
- Have run the dry-run or live-run on hardware not listed here

...opening an issue or PR is welcome. The goal is to arrive at Phabricator with broad hardware coverage and a clean review history.

Hardware test reports and contributor findings are recorded in [docs/hardware-reports.md](docs/hardware-reports.md).

For FreeBSD-specific discussion, the relevant forum is the [freebsd-update mailing list](https://lists.freebsd.org/subscription/freebsd-stable) and the [bug report](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=279829).

---

## Reference

- [FreeBSD bug 279829](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=279829)
- [FreeBSD Phabricator review D58990](https://reviews.freebsd.org/D58990) — this patch, under review
- [FreeBSD Phabricator review D45890](https://reviews.freebsd.org/D45890) — Warner Losh's complementary loader version-check patch
- [sysutils/loaders-update port](https://freshports.org/sysutils/loaders-update) — Community tool with similar goals (standalone port; not integrated into freebsd-update or pkgbase)
- [FreeBSD Handbook: Updating FreeBSD](https://docs.freebsd.org/en/books/handbook/cutting-edge/)
- [loader.efi(8) man page](https://man.freebsd.org/cgi/man.cgi?query=loader.efi&sektion=8)
