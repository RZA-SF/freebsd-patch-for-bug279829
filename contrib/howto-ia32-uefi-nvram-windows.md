# HOWTO: Adding a FreeBSD Boot Entry on 32-bit UEFI Systems with Windows

## Who this is for

This guide is for users running FreeBSD alongside Windows on **amd64 hardware
with 32-bit UEFI firmware** — typically Intel Bay Trail or Braswell-based
systems such as:

- Intel Compute Stick (STK1AW32SC, STK1A32SC) — Atom Z3735F
- Generic "Intel Pocket PC" / mini-PCs — Atom Z3735F, Z3736F, Z3740
- Intel NUC5CPYH / NUC5PPYH — Celeron N3050 / Pentium N3700
- GPD Pocket 1 — Atom x7-Z8750
- Various Bay Trail tablets (Z3735F, Z3740D, etc.)

**How to confirm you have 32-bit UEFI:** from FreeBSD, run:

```sh
sysctl machdep.bootmethod          # should print: UEFI
ls /dev/efi                        # should NOT exist
efibootmgr -v                      # should fail: "efi variables not supported"
ls /boot/efi/EFI/Boot/             # should contain bootia32.efi, NOT bootx64.efi
```

If `/dev/efi` is absent and `efibootmgr` fails, you have 32-bit UEFI firmware
running a 64-bit kernel — the normal scenario on this hardware class.

## The problem

On 64-bit UEFI systems, `efi_bootloader_update.sh` (and `bsdinstall`) can
create a NVRAM boot entry pointing to `EFI/FreeBSD/loader.efi` via
`efibootmgr`. On 32-bit UEFI, this is not possible: FreeBSD's EFIRT driver
cannot attach to 32-bit UEFI runtime services, so `/dev/efi` is never created
and NVRAM is inaccessible from within FreeBSD.

The script installs `loader_ia32.efi` to `EFI/BOOT/BOOTia32.efi` as the
fallback binary (the UEFI spec path that firmware tries when no explicit NVRAM
entry matches). On many systems, this is sufficient: the firmware finds
`BOOTia32.efi` and boots it. However, on systems where Windows is also
installed, the firmware's existing NVRAM entry for Windows Boot Manager takes
priority, and the fallback path is never reached.

You need to add a FreeBSD NVRAM entry manually. The tool for this from Windows
is `bcdedit`.

## Background: what bcdedit sees

`bcdedit /enum firmware` shows the UEFI firmware's NVRAM boot entries through
a Windows lens. Key identifiers:

- `{fwbootmgr}` — the firmware boot manager itself; its `displayorder` is the
  UEFI `BootOrder` variable
- `{bootmgr}` — the Windows Boot Manager application entry (loads
  `EFI\MICROSOFT\BOOT\BOOTMGFW.EFI`)
- `{GUID}` — individual firmware boot applications (e.g. CD/DVD, network)

The `displayorder` under `{fwbootmgr}` is the UEFI `BootOrder` — the sequence
the firmware tries when deciding what to boot.

## Method 1: Standard — add a FreeBSD entry to the boot order

This works on most hardware where the firmware respects `BootOrder`.

Boot into **Windows Recovery Environment (WinRE)**:

1. If Windows is functional: Settings → Update & Security → Recovery → Advanced
   startup → Restart now → Troubleshoot → Advanced options → Command Prompt
2. If Windows is broken (e.g. first boot after FreeBSD install): let the
   "Preparing Automatic Repair" screen run, then: Troubleshoot → Advanced
   options → Command Prompt
3. From BIOS/UEFI setup: look for a "Launch EFI Shell" option (not available
   on all OEM firmware)

From the WinRE command prompt, first check the current state:

```cmd
bcdedit /enum firmware
```

Note the existing entries. Then create a FreeBSD entry:

```cmd
bcdedit /copy {bootmgr} /d "FreeBSD"
```

This prints a new GUID, e.g. `{a1b2c3d4-...}`. Use that GUID in the next
commands (type the full GUID including braces):

```cmd
bcdedit /set {a1b2c3d4-...} path \EFI\freebsd\loader_ia32.efi
bcdedit /set {fwbootmgr} displayorder {a1b2c3d4-...} /addfirst
```

**Note:** The path must use backslashes and match the actual file location on
the ESP. If `efi_bootloader_update.sh` was used, the ia32 loader is at
`\EFI\BOOT\BOOTia32.efi`. If you placed it manually at
`\EFI\freebsd\loader_ia32.efi`, use that path instead.

Reboot. The firmware should now try the FreeBSD entry first.

Verify with `bcdedit /enum firmware` from WinRE after reboot to confirm the
entry persists.

### Notes on `{bootmgr}` vs `{fwbootmgr}`

- `{bootmgr}` and `{fwbootmgr}` are **verbatim well-known identifiers** — type
  them exactly as shown, including the braces.
- `{fwbootmgr}` controls the UEFI `BootOrder`; modifying its `displayorder`
  changes which entry the firmware tries first.
- Only the newly returned `{GUID}` varies per system; everything else is
  literal.
- There is no shorthand for the GUID — enter the full string including braces.

## Method 2: OEM firmware that ignores BootOrder

Some cheap Bay Trail OEM firmware hardcodes the Windows Boot Manager entry and
ignores changes to `BootOrder` entirely. Symptoms:

- After Method 1, `bcdedit /enum firmware` shows the FreeBSD entry first in
  `displayorder`, but the system still boots Windows.
- The BIOS setup has no "Boot Override" or "Add Boot Entry" option.

**Verify this is your situation:** boot into WinRE, check that the FreeBSD
entry is present and first in `{fwbootmgr} displayorder`. If yes, and the
system still boots Windows, proceed with Method 2.

### Option A: Redirect the Windows Boot Manager path

The firmware always loads `{bootmgr}`, so we change what it points to:

```cmd
bcdedit /set {bootmgr} path \EFI\BOOT\BOOTia32.efi
```

On reboot the firmware loads `{bootmgr}`, which now points to
`BOOTia32.efi` (FreeBSD `loader_ia32.efi`). FreeBSD boots.

**Limitation:** Windows can no longer boot via its NVRAM entry (it points to
the FreeBSD loader). Windows remains accessible via its own `EFI/Microsoft/`
path if a separate NVRAM entry or boot override exists. If you need to restore
Windows boot, see the Restoring Windows section below.

**Test first:** if this approach works on your firmware, it is cleaner than
Option B.

### Option B: Replace BOOTMGFW.EFI with the FreeBSD loader

If Option A also fails (the firmware has the path hardcoded in ROM):

From WinRE, first mount the ESP:

```cmd
diskpart
list disk
select disk 0
list partition
select partition 1
assign letter=S
exit
```

Then back up and replace:

```cmd
copy S:\EFI\MICROSOFT\BOOT\BOOTMGFW.EFI S:\EFI\MICROSOFT\BOOT\BOOTMGFW.EFI.windows
copy S:\EFI\BOOT\BOOTia32.efi S:\EFI\MICROSOFT\BOOT\BOOTMGFW.EFI
```

The firmware loads `BOOTMGFW.EFI` from its hardcoded path. It is now
`loader_ia32.efi`, and FreeBSD boots.

**Note:** The ESP partition number (here `1`) may differ on your system — use
`list partition` output to identify it (look for the ~100 MB partition of type
`System`).

## Restoring the Windows Boot Manager path

If you used Method 2, Option A:

```cmd
bcdedit /set {bootmgr} path \EFI\MICROSOFT\BOOT\BOOTMGFW.EFI
```

If you used Method 2, Option B, boot the FreeBSD USB stick, mount the ESP,
and copy the backup back:

```sh
mount -t msdosfs /dev/mmcsd0p1 /mnt
cp /mnt/EFI/MICROSOFT/BOOT/BOOTMGFW.EFI.windows \
   /mnt/EFI/MICROSOFT/BOOT/BOOTMGFW.EFI
umount /mnt
```

Adjust the device path (`mmcsd0p1`) to match your ESP partition.

## Cleaner long-term layout (recommended)

Rather than overwriting `EFI/BOOT/BOOTia32.efi` (which Windows owns on a
pre-installed system), the preferred layout is:

```
EFI/
  BOOT/
    bootia32.efi       <- Windows; leave untouched
    bootx64.efi        <- FreeBSD (installed by bsdinstall/freebsd-update)
  freebsd/
    loader_ia32.efi    <- FreeBSD ia32 loader (place here manually)
    loader.efi         <- FreeBSD 64-bit loader
  Microsoft/           <- Windows; leave untouched
```

Point the NVRAM entry to `\EFI\freebsd\loader_ia32.efi`. This preserves
Windows's fallback binary and keeps the FreeBSD files in their own directory.

`efi_bootloader_update.sh` handles the `EFI/freebsd/` and `EFI/BOOT/` updates
automatically on each upgrade; only the initial NVRAM entry needs manual setup.

## Why this is necessary

FreeBSD's `efirt(4)` driver cannot attach to 32-bit UEFI runtime services from
a 64-bit kernel. This is a fundamental architectural constraint: the 64-bit
kernel cannot call 32-bit UEFI runtime functions. As a result, `/dev/efi` is
never created, and neither `efibootmgr` nor `freebsd-update` can manage NVRAM
on this class of hardware.

This limitation is documented in the FreeBSD manual and is not specific to this
patch. The manual NVRAM setup described here is a one-time operation; subsequent
upgrades via `freebsd-update` will update the loader binary on the ESP
automatically without requiring any NVRAM changes.

## References

- FreeBSD `efirt(4)` — EFI runtime services driver
- `efibootmgr(8)` — EFI boot manager interface
- `bcdedit` documentation: `bcdedit /?` from Windows command prompt
- UEFI Specification §3.1 — Boot Manager and fallback path (`EFI/BOOT/BOOTia32.efi`)
- FreeBSD-EN-25:12.efi — bsdinstall ia32 loader errata (fixed in 14.3-RELEASE-p2)
