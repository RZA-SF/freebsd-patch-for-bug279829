# FreeBSD EFI Loader Upgrade Guide

This guide covers which FreeBSD upgrade paths are affected by the EFI loader
staleness problem, what failure looks like, how to upgrade safely using the
standalone `efi_bootloader_update.sh` script, and how to recover if a system
has already failed.

**The patch** ([D58990](https://reviews.freebsd.org/D58990)) integrates this
fix into `freebsd-update` so it runs automatically.  Until the patch is
accepted upstream, the standalone script in this repository can be used
out-of-band on any FreeBSD 13.5+ system.

---

## Background: Why the ESP Is Never Updated

`freebsd-update` updates the kernel, base system, and `/boot/` tree on the
root filesystem — but it has never touched the EFI System Partition (ESP).
The ESP is a separate FAT32 partition.  Files on it — principally
`/EFI/FreeBSD/loader.efi` and the fallback `/EFI/BOOT/BOOTx64.efi` — persist
across every `freebsd-update` run, unchanged.

A system installed in 2019 on FreeBSD 12.x and upgraded through 13.x and into
14.x will still have the 2019-era loader on its ESP — unless someone updated
it manually.  Most operators never did.

---

## Which Upgrade Paths Are Affected

### Safe paths (no ESP update needed)

| From | To | Safe? | Notes |
|------|-----|-------|-------|
| 12.x | 12.x (patch update) | ✓ Safe | Within-branch; boot scripts do not change incompatibly |
| 13.x | 13.x (patch update) | ✓ Safe | Within-branch |
| 14.x | 14.x (patch update) | ✓ Safe | Within-branch |
| 12.x | 13.x | ✓ Safe | Lua scripts backward-compatible through 13.x |
| 12.x | 14.0 | ✓ Safe | Lua scripts backward-compatible through 14.0 |
| 13.x | 14.0 | ✓ Safe | Lua scripts backward-compatible through 14.0 |

Confirmed by real-world data: a system installed on FreeBSD 12.x in late 2019
completed approximately 40 `freebsd-update` runs through 12.x → 13.x → 14.0
with zero ESP updates and booted correctly throughout.

### Hazardous paths

| From | To | Risk | Mode |
|------|-----|------|------|
| Any ≤ 14.0 | 14.1 | **HIGH** | A — Lua crash at boot menu |
| Any ≤ 14.0 | 14.2, 14.3, 14.4 | **HIGH** | A — same Lua incompatibility |
| Any ≤ 14.x | 15.x | **HIGH** (assumed) | A — same systemic gap |
| Any | (after `zpool upgrade`) | **HIGH** | B — pool not found if loader predates new features |

FreeBSD 14.1 introduced a revised Lua-based boot menu.  Any loader older than
14.1 may crash when it tries to run the new Lua scripts — even if the system
otherwise upgraded successfully.

The ZFS risk (Mode B) is a secondary hazard: it only applies if the operator
manually runs `zpool upgrade` after a `freebsd-update` upgrade, and only if
the pool then uses features that the stale ESP loader cannot read.  This does
not happen automatically.

---

## What Failure Looks Like

### Mode A — Lua crash (most common)

After rebooting into the upgraded system, the EFI firmware loads the old
`loader.efi` from the ESP.  The loader tries to run the new Lua boot scripts
on the freshly upgraded root filesystem.  The Lua runtime crashes.

**What you see:** The screen drops to a loader prompt:

```
Type 'boot' to proceed.
```

If you type `boot` at the prompt, the system boots normally into the upgraded
OS.  The loader crash was non-fatal — the kernel itself is fine.

**Headless systems:** If there is no one at the console to type `boot`, the
system hangs waiting for input that never arrives.  For a remote system, this
is a hard outage.

**The catch:** Typing `boot` gets you into the upgraded OS for that boot, but
the ESP loader is still stale.  Every subsequent reboot will hit the same
prompt until the ESP is updated.

### Mode B — ZFS pool not found (rare)

If `zpool upgrade` has been run and new ZFS feature flags are in use, a loader
that predates those features cannot read the pool.  The system halts with:

```
ZFS: pool not found
```

This is a hard failure.  The system does not boot.  Recovery requires a rescue
medium.

---

## Safe Upgrade Procedure

Run `efi_bootloader_update.sh` **after** `freebsd-update install` and
**before** rebooting.  The script copies the freshly installed
`/boot/loader.efi` to the ESP so that the first reboot after an upgrade uses
the correct loader.

### With the integrated patch (post-acceptance)

The patch integrates this step into `freebsd-update` as a post-install hook.
No manual action is required.

### Without the patch (out-of-band, any FreeBSD 13.5+ system)

```sh
# Fetch the script
fetch -o /tmp/efi_bootloader_update.sh \
    https://raw.githubusercontent.com/RZA-SF/freebsd-patch-for-bug279829/main/src/efi_bootloader_update.sh

# Dry-run first to confirm what will be updated
sh /tmp/efi_bootloader_update.sh --dry-run --verbose

# Apply
sh /tmp/efi_bootloader_update.sh

# Then reboot
reboot
```

Run this **after** `freebsd-update install` and **before** rebooting.

The script automatically discovers the ESP on the boot disk, verifies it
contains a FreeBSD loader (it will not touch Windows or other OS ESP files),
and copies the current `/boot/loader.efi` to both `/EFI/FreeBSD/loader.efi`
and the architecture-specific fallback path (`/EFI/BOOT/BOOTx64.efi` on
amd64).

---

## Recovery Procedure

### Scenario 1 — You see the loader prompt (Mode A, loader accessible)

This is the recoverable case.  The system reached the loader prompt; it did
not hard-hang.

**At the loader prompt**, type:

```
boot
```

The system boots into the upgraded OS.  Log in as root.

**Once booted**, fetch and run the script to fix the ESP:

```sh
fetch -o /tmp/efi_bootloader_update.sh \
    https://raw.githubusercontent.com/RZA-SF/freebsd-patch-for-bug279829/main/src/efi_bootloader_update.sh
sh /tmp/efi_bootloader_update.sh
reboot
```

The next reboot will load the correct loader.efi from the ESP and the prompt
will not appear again.

---

### Scenario 2 — The system is unreachable (headless / no console access)

If the system is hanging at the loader prompt with no way to reach it:

1. Boot from a FreeBSD USB installer (same major version or newer is fine).
2. At the installer menu, drop to a shell.
3. Import the root ZFS pool and mount the ESP manually:

   ```sh
   # Import the root pool at /mnt
   zpool import -fR /mnt zroot

   # Mount the root dataset (adjust dataset name if your layout differs)
   mount -t zfs zroot/ROOT/default /mnt

   # Identify and mount the ESP
   gpart show da0                               # adjust disk name; find the efi partition
   mkdir -p /tmp/esp
   mount -t msdosfs /dev/da0p1 /tmp/esp        # adjust partition number
   ```

4. Copy the upgraded loader directly to the ESP paths:

   ```sh
   # The source loader is the one freebsd-update installed on the root FS:
   src=/mnt/boot/loader.efi

   # Update the FreeBSD-specific path (case matches your existing ESP layout):
   cp "$src" /tmp/esp/EFI/FreeBSD/loader.efi   # adjust case if needed (efi/ vs EFI/)

   # Update the architecture fallback:
   cp "$src" /tmp/esp/EFI/BOOT/BOOTx64.efi     # amd64; use BOOTaa64.efi for aarch64
   ```

   To confirm the correct path names, list the ESP first:
   ```sh
   find /tmp/esp -name '*.efi'
   ```

5. Unmount and reboot:

   ```sh
   umount /tmp/esp
   umount /mnt
   zpool export zroot
   reboot
   ```

> **Note:** The `efi_bootloader_update.sh` script auto-discovers the ESP using
> the running system's boot state.  In a USB rescue environment the running
> system is the installer, not the internal disk, so auto-discovery is not
> reliable.  Direct copy (as above) is the correct rescue method.

---

### Scenario 3 — ZFS rollback (Mode A with a clean rollback path)

`freebsd-update upgrade` automatically creates a ZFS snapshot before applying
the upgrade.  If you have not yet committed to the new release and want to
return to the previous state:

1. Boot from a FreeBSD USB installer.
2. Import the pool:

   ```sh
   zpool import -fR /mnt zroot
   ```

3. List the pre-upgrade snapshot:

   ```sh
   zfs list -t snapshot -r zroot
   ```

   Look for a snapshot created by `freebsd-update` immediately before the
   upgrade was applied — typically named with a timestamp.

4. Roll back:

   ```sh
   zfs rollback zroot/ROOT/default@<snapshot-name>
   ```

5. Reboot.  The system returns to the pre-upgrade state.

After rolling back, run the ESP update script **before** attempting the
upgrade again so the ESP is current before the next reboot.

---

## ZFS Mode B Advisory

`freebsd-update` does **not** run `zpool upgrade` automatically.  The ZFS
pool feature set does not advance unless the operator explicitly runs
`zpool upgrade`.

Mode B is only a risk if:

1. You run `zpool upgrade` after a major version upgrade, AND
2. The ESP still has a stale loader that predates the newly enabled features,
   AND
3. The pool writes data using a new feature that the old loader cannot read.

**Recommendation:** Update the ESP loader (using the script above) before or
at the same time as any `zpool upgrade` run.  Do not run `zpool upgrade` on a
system with a stale ESP loader.

---

## Case Study — A System Stuck at 14.0-RELEASE-p11

This is a real system, described here with the operator's permission.

**History:**
- Installed FreeBSD 12.x in late 2019 on an NVMe workstation
- Upgraded through 12.x → 13.x → 14.0 via `freebsd-update`, approximately
  40 patch runs — zero ESP updates throughout the entire history
- All upgrades through 14.0 succeeded: the Lua boot scripts were compatible
  with the old loader through that point

**Attempted upgrade past 14.0 — twice:**
- `freebsd-update upgrade` → `freebsd-update install` → `reboot`
- Reboot hit the loader prompt (Mode A): typed `boot`, system came up
- Both times: used `freebsd-update rollback` + ZFS snapshot to return to 14.0
- Third attempt (January 2025): `freebsd-update fetch` staged but
  `freebsd-update install` deliberately not run — burned twice, not willing to
  try again without a fix

**Current state (September 2026):**
- Stuck at 14.0-RELEASE-p11, which reached end-of-life in November 2024
- The staged update from January 2025 is still sitting there, uninstalled
- Cannot safely upgrade until the ESP is updated

**Resolution:**

```sh
# First: update the ESP to the current 14.0 loader
# (already done on this system via a previous live run of the script)

# Then: install the staged update and run the script before rebooting
freebsd-update install
fetch -o /tmp/efi_bootloader_update.sh \
    https://raw.githubusercontent.com/RZA-SF/freebsd-patch-for-bug279829/main/src/efi_bootloader_update.sh
sh /tmp/efi_bootloader_update.sh
reboot
```

This system is the canonical motivation for this patch.  The trip hazard
prevented two upgrade attempts, left the system at an EOL release, and cost
the operator time and recovery effort each time it occurred.

---

## EOL 13.x Users

FreeBSD 13.0–13.3 are past end-of-life.  If you are on an EOL 13.x release,
the recommended path is:

1. Upgrade within-13 to 13.5 (the last 13.x release): `freebsd-update upgrade`
   — this is safe; the Lua boot scripts are backward-compatible within 13.x.
2. After `freebsd-update install` and before rebooting, run the ESP update
   script to prepare the ESP for future major-version upgrades.
3. From 13.5, upgrade to 14.x as normal — with the script in place, the ESP
   will be updated before each reboot.

The standalone script works on FreeBSD 13.5+.

---

## See Also

- [Design document](../docs/design.md) — full technical description of the ESP
  gap and the script's implementation
- [Hardware validation reports](../docs/hardware-reports.md) — tested
  configurations and environments
- [HOWTO: ia32 NVRAM via bcdedit](howto-ia32-uefi-nvram-windows.md) — for
  systems with 32-bit EFI firmware and a dual-boot Windows installation
- [FreeBSD bug 279829](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=279829)
- [Phabricator D58990](https://reviews.freebsd.org/D58990) — upstream patch
  submission
