#!/bin/sh
#
# apply-to-freebsd-src.sh — Apply the freebsd-update EFI patch to a freebsd-src clone
#                            and regenerate freebsd-update-efi.patch via git diff.
#
# Usage:
#   sh tools/apply-to-freebsd-src.sh /path/to/freebsd-src [patch-basename]
#
# patch-basename: base name for the output patch (default: freebsd-update-efi).
#   Example: "freebsd-update-efi-stable14" → freebsd-update-efi-stable14.patch
#
# The script makes all changes programmatically so git diff produces a correct
# unified diff that can replace freebsd-update-efi.patch.
#
# Run from the root of the freebsd-patch-for-bug279829 repository.

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FREEBSD_SRC="${1:-}"
PATCH_BASE="${2:-freebsd-update-efi}"

if [ -z "${FREEBSD_SRC}" ]; then
    echo "Usage: $0 /path/to/freebsd-src [patch-basename]" >&2
    exit 1
fi

if ! git -C "${FREEBSD_SRC}" rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: ${FREEBSD_SRC} does not appear to be a git repository" >&2
    exit 1
fi

TARGET="${FREEBSD_SRC}/usr.sbin/freebsd-update"

if [ ! -f "${TARGET}/freebsd-update.sh" ]; then
    echo "Error: ${TARGET}/freebsd-update.sh not found" >&2
    exit 1
fi

echo "==> Applying changes to ${TARGET}"

# ── 1. Makefile ──────────────────────────────────────────────────────────────
echo "--> Makefile: adding FILESGROUPS entry for efi_bootloader_update.sh"
awk '
/^\.include/ && !done {
    print "FILESGROUPS+=\tLIBEXEC"
    print "LIBEXEC=\tefi_bootloader_update.sh"
    print "LIBEXECDIR=\t/usr/libexec"
    print "LIBEXECMODE=\t0755"
    print ""
    done=1
}
{ print }
' "${TARGET}/Makefile" > "${TARGET}/Makefile.new"
mv "${TARGET}/Makefile.new" "${TARGET}/Makefile"

# ── 2. freebsd-update.conf ───────────────────────────────────────────────────
echo "--> freebsd-update.conf: adding UpdateBootloader and UpdateBootloaderNVRAM options"
cat >> "${TARGET}/freebsd-update.conf" << 'EOF'

# Automatically update the EFI bootloader on the ESP and BIOS bootcode on
# freebsd-boot partitions when installing updates.
#
# dry-run  Evaluate and report what would be updated; no writes made.
#          A prominent notice is printed if an update is recommended,
#          with instructions to apply it before the next reboot.
# yes      Perform the update automatically.
# no       Disable bootloader updates entirely.
#
# UpdateBootloader dry-run

# Set to no to skip NVRAM boot entry management while still updating ESP files.
# Use when NVRAM entries are managed externally (BMC, Ansible, iDRAC, etc.) or
# when the firmware's SetVariable implementation is unreliable.
# UpdateBootloaderNVRAM yes
EOF

# ── 3. freebsd-update.sh — CONFIGOPTIONS ─────────────────────────────────────
echo "--> freebsd-update.sh: adding UPDATEBOOTLOADER and UPDATEBOOTLOADERNVRAM to CONFIGOPTIONS"
awk '
/IDSIGNOREPATHS BACKUPKERNEL BACKUPKERNELDIR BACKUPKERNELSYMBOLFILES"/ {
    sub(/"$/, " \\")
    print
    print "    UPDATEBOOTLOADER UPDATEBOOTLOADERNVRAM\""
    next
}
{ print }
' "${TARGET}/freebsd-update.sh" > "${TARGET}/freebsd-update.sh.new"
mv "${TARGET}/freebsd-update.sh.new" "${TARGET}/freebsd-update.sh"

# ── 4. freebsd-update.sh — config_UpdateBootloader() + config_UpdateBootloaderNVRAM() ──
echo "--> freebsd-update.sh: adding config_UpdateBootloader and config_UpdateBootloaderNVRAM functions"
awk '
/^# Handle one line of configuration$/ && !done {
    print "config_UpdateBootloader () {"
    print "\tif [ -z ${UPDATEBOOTLOADER} ]; then"
    print "\t\tcase $1 in"
    print "\t\t[Yy][Ee][Ss])"
    print "\t\t\tUPDATEBOOTLOADER=yes"
    print "\t\t\t;;"
    print "\t\t[Nn][Oo])"
    print "\t\t\tUPDATEBOOTLOADER=no"
    print "\t\t\t;;"
    print "\t\t[Dd][Rr][Yy]-[Rr][Uu][Nn])"
    print "\t\t\tUPDATEBOOTLOADER=dry-run"
    print "\t\t\t;;"
    print "\t\t*)"
    print "\t\t\treturn 1"
    print "\t\t\t;;"
    print "\t\tesac"
    print "\telse"
    print "\t\treturn 1"
    print "\tfi"
    print "}"
    print ""
    print "config_UpdateBootloaderNVRAM () {"
    print "\tif [ -z ${UPDATEBOOTLOADERNVRAM} ]; then"
    print "\t\tcase $1 in"
    print "\t\t[Yy][Ee][Ss])"
    print "\t\t\tUPDATEBOOTLOADERNVRAM=yes"
    print "\t\t\t;;"
    print "\t\t[Nn][Oo])"
    print "\t\t\tUPDATEBOOTLOADERNVRAM=no"
    print "\t\t\t;;"
    print "\t\t*)"
    print "\t\t\treturn 1"
    print "\t\t\t;;"
    print "\t\tesac"
    print "\telse"
    print "\t\treturn 1"
    print "\tfi"
    print "}"
    print ""
    done=1
}
{ print }
' "${TARGET}/freebsd-update.sh" > "${TARGET}/freebsd-update.sh.new"
mv "${TARGET}/freebsd-update.sh.new" "${TARGET}/freebsd-update.sh"

# ── 5. freebsd-update.sh — default config ────────────────────────────────────
echo "--> freebsd-update.sh: adding default config_UpdateBootloader dry-run and config_UpdateBootloaderNVRAM yes"
awk '
/^\tconfig_CreateBootEnv yes$/ && !done {
    print
    print "\tconfig_UpdateBootloader dry-run"
    print "\tconfig_UpdateBootloaderNVRAM yes"
    done=1
    next
}
{ print }
' "${TARGET}/freebsd-update.sh" > "${TARGET}/freebsd-update.sh.new"
mv "${TARGET}/freebsd-update.sh.new" "${TARGET}/freebsd-update.sh"

# ── 6. freebsd-update.sh — update_bootloaders_after_install() + hook ─────────
echo "--> freebsd-update.sh: adding update_bootloaders_after_install function and hook"
awk '
/^install_run \(\) \{$/ && !fn_done {
    print "# Update EFI and BIOS bootloaders after the new world/kernel is installed."
    print "# Sources /usr/libexec/efi_bootloader_update.sh to allow independent testing."
    print "# Controlled by UpdateBootloader in freebsd-update.conf (default: dry-run)."
    print "update_bootloaders_after_install () {"
    print "\tif [ \"${UPDATEBOOTLOADER}\" = \"no\" ]; then"
    print "\t\treturn 0"
    print "\tfi"
    print ""
    print "\tif [ \"${UPDATEBOOTLOADERNVRAM}\" = \"no\" ]; then"
    print "\t\tEFI_NVRAM_UPDATE=0"
    print "\t\texport EFI_NVRAM_UPDATE"
    print "\tfi"
    print ""
    print "\t# Translate conf value to env var for efi_bootloader_update.sh."
    print "\t# dry-run: evaluate only; yes: perform write."
    print "\tif [ \"${UPDATEBOOTLOADER}\" = \"dry-run\" ]; then"
    print "\t\tEFI_DRY_RUN=1"
    print "\t\texport EFI_DRY_RUN"
    print "\telse"
    print "\t\t# UpdateBootloader yes"
    print "\t\tEFI_CONFIRM_UPDATE=1"
    print "\t\texport EFI_CONFIRM_UPDATE"
    print "\tfi"
    print ""
    print "\t_efi_lib=\"${BASEDIR}/usr/libexec/efi_bootloader_update.sh\""
    print ""
    print "\tif [ ! -f \"${_efi_lib}\" ]; then"
    print "\t\techo \"freebsd-update: WARNING: ${_efi_lib} not found\" \\"
    print "\t\t    \"-- bootloader not automatically updated\" >&2"
    print "\t\treturn 0"
    print "\tfi"
    print ""
    print "\t# shellcheck source=/usr/libexec/efi_bootloader_update.sh"
    print "\t. \"${_efi_lib}\""
    print "\tupdate_bootloaders || true   # warnings already printed; never block install"
    print "\tunset _efi_lib EFI_DRY_RUN EFI_CONFIRM_UPDATE"
    print "}"
    print ""
    fn_done=1
}
/^\techo " done\."$/ && !hook_done {
    print
    print ""
    print "\t# Update EFI and BIOS bootloaders now that new world/kernel is in place."
    print "\t# Runs after install_files so /boot/loader.efi is already updated."
    print "\tupdate_bootloaders_after_install"
    hook_done=1
    next
}
{ print }
' "${TARGET}/freebsd-update.sh" > "${TARGET}/freebsd-update.sh.new"
mv "${TARGET}/freebsd-update.sh.new" "${TARGET}/freebsd-update.sh"

# ── 7. freebsd-update.8 — install command description ────────────────────────
echo "--> freebsd-update.8: adding install command description (revision-8: three-value UpdateBootloader)"
awk '
/^\.It Cm rollback$/ && !done {
    print ".Pp"
    print "After installing updates,"
    print ".Nm"
    print "evaluates whether the EFI bootloader on the EFI System Partition (ESP)"
    print "and the BIOS bootcode on"
    print ".Xr gpart 8"
    print ".Dq freebsd-boot"
    print "partitions need to be updated."
    print "This ensures the firmware-facing bootloader is consistent with the newly"
    print "installed"
    print ".Pa /boot/loader.efi"
    print "and Lua scripts, preventing boot failures after major version upgrades."
    print "EFI binaries that carry a Secure Boot signature are not overwritten;"
    print "a warning is emitted and the signed binary is left unchanged."
    print ".Pp"
    print "The"
    print ".Cm UpdateBootloader"
    print "option in"
    print ".Xr freebsd-update.conf 5"
    print "controls bootloader update behavior and accepts three values:"
    print ".Bl -tag -width \"dry-run\""
    print ".It Cm dry-run"
    print "Evaluate what would be updated and report the result; no writes are made."
    print "If an update is recommended, a prominent notice is printed to the console"
    print "and recorded via"
    print ".Xr syslog 3"
    print "at"
    print ".Dv daemon.warn ,"
    print "with instructions to apply the update before rebooting."
    print "This is the default."
    print ".It Cm yes"
    print "Perform the bootloader update automatically."
    print "A"
    print ".Dv daemon.notice"
    print "syslog entry is written on success."
    print ".It Cm no"
    print "Disable bootloader updates entirely."
    print ".El"
    print ".Pp"
    print "To apply a pending bootloader update immediately (as root):"
    print ".Pp"
    print ".Dl sh /usr/libexec/efi_bootloader_update.sh --confirm-update"
    print ".Pp"
    print "To skip only NVRAM boot entry management while still updating ESP files,"
    print "set"
    print ".Cm UpdateBootloaderNVRAM no"
    print "in"
    print ".Xr freebsd-update.conf 5 ."
    print "This is appropriate when NVRAM entries are managed externally"
    print "(for example, via a BMC or configuration management system)"
    print "or when the firmware\\(aqs"
    print ".Dv SetVariable"
    print "implementation is unreliable."
    done=1
}
{ print }
' "${TARGET}/freebsd-update.8" > "${TARGET}/freebsd-update.8.new"
mv "${TARGET}/freebsd-update.8.new" "${TARGET}/freebsd-update.8"

# ── 8. freebsd-update.8 — FILES section ──────────────────────────────────────
echo "--> freebsd-update.8: adding FILES entry for efi_bootloader_update.sh"
awk '
/^\.El$/ && files_done && !lib_done {
    print ".It Pa /usr/libexec/efi_bootloader_update.sh"
    print "EFI and BIOS bootloader update library, sourced by"
    print ".Nm"
    print "during"
    print ".Cm install"
    print "to update bootloaders on the ESP and"
    print ".Dq freebsd-boot"
    print "partitions."
    print "The script may also be invoked directly."
    print "With no arguments or"
    print ".Fl -dry-run ,"
    print "it evaluates what would be updated without making any changes."
    print "With"
    print ".Fl -confirm-update ,"
    print "it performs the update."
    print "The"
    print ".Ev EFI_DRY_RUN"
    print "and"
    print ".Ev EFI_CONFIRM_UPDATE"
    print "environment variables are equivalent to the respective flags and are"
    print "suitable for scripted callers that cannot pass flags directly."
    print ".El"
    lib_done=1
    next
}
/^\.Sh FILES$/ { files_done=1 }
{ print }
' "${TARGET}/freebsd-update.8" > "${TARGET}/freebsd-update.8.new"
mv "${TARGET}/freebsd-update.8.new" "${TARGET}/freebsd-update.8"

# ── 9. Copy efi_bootloader_update.sh ─────────────────────────────────────────
echo "--> Copying efi_bootloader_update.sh to ${TARGET}/"
cp "${REPO_ROOT}/src/efi_bootloader_update.sh" "${TARGET}/efi_bootloader_update.sh"
chmod 755 "${TARGET}/efi_bootloader_update.sh"

# ── 10. Generate authoritative patch via git diff ─────────────────────────────
echo ""
echo "==> Generating authoritative patch via git diff"
PATCH_OUT="${REPO_ROOT}/${PATCH_BASE}.patch"

(
    cd "${FREEBSD_SRC}"

    # Preserve the cover letter from the existing patch file (if any)
    COVER=""
    if [ -f "${PATCH_OUT}" ]; then
        COVER=$(awk '/^diff --git/{exit} {print}' "${PATCH_OUT}")
    fi

    # Stage the new file so it appears in git diff HEAD
    git add usr.sbin/freebsd-update/efi_bootloader_update.sh

    git diff HEAD -- \
        usr.sbin/freebsd-update/Makefile \
        usr.sbin/freebsd-update/freebsd-update.conf \
        usr.sbin/freebsd-update/freebsd-update.sh \
        usr.sbin/freebsd-update/freebsd-update.8 \
        usr.sbin/freebsd-update/efi_bootloader_update.sh > /tmp/efi_diff.patch

    if [ -n "${COVER}" ]; then
        printf '%s\n\n' "${COVER}" > "${PATCH_OUT}"
        cat /tmp/efi_diff.patch >> "${PATCH_OUT}"
    else
        mv /tmp/efi_diff.patch "${PATCH_OUT}"
    fi
)

echo ""
echo "==> Done. Patch written to:"
echo "    ${PATCH_OUT}"
echo ""
echo "Verify with:"
echo "    cd ${FREEBSD_SRC} && git diff --stat"
