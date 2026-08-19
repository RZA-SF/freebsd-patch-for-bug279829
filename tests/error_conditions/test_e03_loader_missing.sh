#!/bin/sh
# test_e03_loader_missing.sh
#
# Error condition: EFI_LOADER_SRC points to a non-existent file.
# efi_check_prerequisites must return 1.
# update_bootloaders must return 1.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 3

setup_test_dir
mock_init

# --- Point EFI_LOADER_SRC at a path that does not exist ---
export EFI_LOADER_SRC="/nonexistent/path/loader.efi"

mock_cmd_output id "0"
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *) echo "0" ;;
esac'

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# Test efi_check_prerequisites directly
_prereq_rc=0
efi_check_prerequisites 2>/dev/null || _prereq_rc=$?

assert_eq \
    "efi_check_prerequisites returns 1 when loader file is missing" \
    "${_prereq_rc}" "1"

# update_bootloaders must also fail
_update_rc=0
update_bootloaders 2>/dev/null || _update_rc=$?

assert_eq \
    "update_bootloaders returns 1 when loader file is missing" \
    "${_update_rc}" "1"

# Verify that no msdosfs mount was attempted
_mount_calls=0
mock_was_called mount_msdosfs && _mount_calls=1
assert_eq \
    "mount_msdosfs NOT called when prerequisites fail" \
    "${_mount_calls}" "0"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
