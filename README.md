# FreeBSD EFI Bootloader Auto-Update Patch

This repository contains a patch for `freebsd-update` that automatically updates the EFI bootloader on the ESP (EFI System Partition) during `freebsd-update install`. Without this fix, upgrading FreeBSD across major versions can silently leave a stale bootloader on the ESP — one that cannot boot the newly installed system.

The patch is developed here ahead of submission to the FreeBSD project via Phabricator. It has been tested on real FreeBSD hardware (14.0-RELEASE-p11, amd64, ZFS, NVMe) with a 197-test suite covering unit, integration, and error conditions across all supported configurations.

**Addresses:** [FreeBSD bug 279829](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=279829)
**Upstream status:** Closed "Not a bug" — but the underlying hazard is real and ongoing

---

## Current Status

| | |
|---|---|
| Test suite | 197 / 197 passing on FreeBSD 14.0-RELEASE-p11 |
| Live run | ✓ Complete — FreeBSD 14.0-RELEASE-p11, amd64, UEFI, ZFS, NVMe |
| Phabricator submission | ✓ [D58990](https://reviews.freebsd.org/D58990) — under review |
| Backport targets | `main` (15-CURRENT), `stable/14`, `stable/13` |

---

## Am I Affected?

You are at risk if **all three** of the following are true:

1. Your system boots via UEFI (check: `sysctl machdep.bootmethod` returns `UEFI`)
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
ls -la /mnt/EFI/FreeBSD/loader.efi /mnt/EFI/boot/BOOTx64.efi /boot/loader.efi
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

For every disk that participates in the root filesystem:

**EFI System Partition:**
1. Finds the ESP (`gpart show`, type `efi`)
2. Mounts it (or reuses an existing mount)
3. Updates `/EFI/FreeBSD/loader.efi` — creating the directory if absent (**promote**)
4. Updates `/EFI/BOOT/BOOTx64.efi` (or arch equivalent) **only if** it fingerprints as a FreeBSD loader — protecting other OSes on a shared ESP
5. Creates an NVRAM boot entry pointing to `/EFI/FreeBSD/loader.efi` if none exists
6. Unmounts the ESP

**BIOS boot partition:**
1. Finds `freebsd-boot` typed partitions (`gpart show`)
2. Writes the correct bootcode: `gptzfsboot` for ZFS roots, `gptboot` for UFS

### What "Promote" Means

Many older FreeBSD installations (including systems upgraded through multiple major versions) only have the fallback EFI path (`/EFI/BOOT/BOOTx64.efi`) and no OS-specific `/EFI/FreeBSD/` directory. This patch creates the OS-specific directory and installs the loader there, then adds an NVRAM entry pointing to it.

After the first run, the system has a clean, stable FreeBSD-specific EFI path. All future upgrades update `/EFI/FreeBSD/loader.efi` directly, with no ambiguity about which OS owns which file.

---

## Supported Configurations

| Configuration | Supported |
|---|---|
| Single disk, EFI + freebsd-boot (UEFI + BIOS capable) | ✓ |
| Single disk, EFI only | ✓ |
| Single disk, freebsd-boot only (BIOS-only system) | ✓ |
| ZFS mirror (2+ disks, each with ESP) | ✓ |
| ZFS raidz (3+ disks) | ✓ |
| gmirror root | ✓ |
| UFS root filesystem | ✓ |
| ZFS root filesystem | ✓ |
| ESP not in `/etc/fstab` (auto-detected) | ✓ |
| ESP already mounted at any path | ✓ |
| FreeBSD-only disk | ✓ |
| Multi-OS, shared ESP (FreeBSD + Windows/Linux) | ✓ safe |
| Multi-OS, separate disks | ✓ |
| `/EFI/FreeBSD/loader.efi` already exists | ✓ updated |
| Only fallback `/EFI/BOOT/BOOTx64.efi` exists | ✓ updated + promoted |
| Neither path exists (blank ESP) | ✓ both created |
| amd64 / x86_64 | ✓ |
| arm64 / aarch64 | ✓ |
| i386 (32-bit EFI) | ✓ |
| RISC-V (riscv64) | ✓ |
| Running inside a jail | ✓ skipped gracefully |
| Hardware RAID (disks not visible) | Warns, instructs manual update |
| Encrypted ESP | Not supported (extremely rare) |
| MBR (non-GPT) disks | Not supported (BIOS-only, legacy) |

### Multi-OS Safety

The fallback path (`/EFI/BOOT/BOOTx64.efi`) is only updated if the existing file is identified as a FreeBSD loader using a multi-string fingerprint check (requires 2 of 3: `"FreeBSD"`, `"loader.efi"`, `"boot/lua"`). A single string match is not used to reduce false-positive risk.

If the fallback is owned by another OS (e.g., Windows Boot Manager), it is left entirely untouched. FreeBSD boots correctly via the OS-specific `/EFI/FreeBSD/loader.efi` path through its NVRAM entry.

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
│   ├── unit/                            ← Unit tests (13 files, ~80 assertions)
│   ├── integration/                     ← Integration tests (10 files, ~63 assertions)
│   └── error_conditions/               ← Error/boundary/negative tests (15 files, ~55 assertions)
└── docs/
    ├── design.md                        ← Technical design and rationale
    ├── backport-guide.md                ← Per-version submission instructions
    └── testing-guide.md                ← How to run tests on Linux and FreeBSD
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
freebsd-update: [bootloader] INFO:  Boot disk(s): nda0
freebsd-update: [bootloader] INFO:  Processing EFI partition: nda0p1
freebsd-update: [bootloader] INFO:  Creating /tmp/tmp.XXXXXX/EFI/FreeBSD/ and installing loader
freebsd-update: [bootloader] INFO:  Updating fallback loader: .../EFI/boot/BOOTx64.efi
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

## Known Limitations

- **Hardware RAID**: Physical disk devices are not visible through the RAID controller. The script prints a warning and instructs manual update.
- **Encrypted ESP**: Extremely rare; not supported. A warning is printed.
- **MBR (non-GPT) disks**: Very old installations. Not supported; a warning is printed.
- **FAT32 atomicity**: `mv` on FAT32 is not truly atomic. A power failure between the `cp` and `mv` could leave the ESP in an inconsistent state. The temp-file approach minimises the window but cannot eliminate the risk entirely. This is inherent to any ESP update operation.

---

## Feedback and Contributions

This patch is being developed in the open before upstream submission. If you:

- Have a configuration that is not covered (unusual disk topology, firmware, architecture)
- Find a bug or incorrect behavior in the script or test suite
- Have run the dry-run or live-run on hardware not listed here

...opening an issue or PR is welcome. The goal is to arrive at Phabricator with broad hardware coverage and a clean review history.

For FreeBSD-specific discussion, the relevant forum is the [freebsd-update mailing list](https://lists.freebsd.org/subscription/freebsd-stable) and the [bug report](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=279829).

---

## Reference

- [FreeBSD bug 279829](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=279829)
- [FreeBSD Phabricator review D58990](https://reviews.freebsd.org/D58990) — this patch, under review
- [FreeBSD Phabricator review D45890](https://reviews.freebsd.org/D45890) — Warner Losh's complementary loader version-check patch
- [sysutils/loaders-update port](https://freshports.org/sysutils/loaders-update) — Community tool with similar goals (AMD64/GPT only, standalone)
- [FreeBSD Handbook: Updating FreeBSD](https://docs.freebsd.org/en/books/handbook/cutting-edge/)
- [loader.efi(8) man page](https://man.freebsd.org/cgi/man.cgi?query=loader.efi&sektion=8)
