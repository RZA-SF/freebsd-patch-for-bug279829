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
echo "--> freebsd-update.conf: adding UpdateBootloader option"
cat >> "${TARGET}/freebsd-update.conf" << 'EOF'

# Automatically update the EFI bootloader on the ESP and BIOS bootcode on
# freebsd-boot partitions when installing updates.  Disable only if you manage
# bootloaders manually or use a custom boot configuration.
# UpdateBootloader yes
EOF

# ── 3. freebsd-update.sh — CONFIGOPTIONS ─────────────────────────────────────
echo "--> freebsd-update.sh: adding UPDATEBOOTLOADER to CONFIGOPTIONS"
awk '
/IDSIGNOREPATHS BACKUPKERNEL BACKUPKERNELDIR BACKUPKERNELSYMBOLFILES"/ {
    sub(/"$/, " \\")
    print
    print "    UPDATEBOOTLOADER\""
    next
}
{ print }
' "${TARGET}/freebsd-update.sh" > "${TARGET}/freebsd-update.sh.new"
mv "${TARGET}/freebsd-update.sh.new" "${TARGET}/freebsd-update.sh"

# ── 4. freebsd-update.sh — config_UpdateBootloader() ─────────────────────────
echo "--> freebsd-update.sh: adding config_UpdateBootloader function"
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
echo "--> freebsd-update.sh: adding default config_UpdateBootloader yes"
awk '
/^\tconfig_CreateBootEnv yes$/ && !done {
    print
    print "\tconfig_UpdateBootloader yes"
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
    print "# Controlled by UpdateBootloader in freebsd-update.conf (default: yes)."
    print "update_bootloaders_after_install () {"
    print "\tif [ \"${UPDATEBOOTLOADER}\" = \"no\" ]; then"
    print "\t\treturn 0"
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
    print "\tunset _efi_lib"
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
echo "--> freebsd-update.8: adding install command description"
awk '
/^\.It Cm rollback$/ && !done {
    print ".Pp"
    print "After installing updates,"
    print ".Nm"
    print "automatically updates the EFI bootloader on the EFI System Partition (ESP)"
    print "and the BIOS bootcode on"
    print ".Xr gpart 8"
    print ".Dq freebsd-boot"
    print "partitions."
    print "This ensures the firmware-facing bootloader is consistent with the newly"
    print "installed"
    print ".Pa /boot/loader.efi"
    print "and Lua scripts, preventing boot failures after major version upgrades."
    print "To disable, set"
    print ".Cm UpdateBootloader no"
    print "in"
    print ".Xr freebsd-update.conf 5 ."
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
