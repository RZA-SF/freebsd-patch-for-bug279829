#!/bin/sh
# test_e04_loader_empty.sh
#
# Error condition: EFI_LOADER_SRC exists but is 0 bytes (empty file).
# efi_check_prerequisites must return 1.
# update_bootloaders must return 1.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 3

setup_test_dir
mock_init

# --- Create an empty loader file (0 bytes) ---
FAKE_LOADER="${TEST_DIR}/loader_empty.efi"
: > "${FAKE_LOADER}"   # creates a 0-byte file
export EFI_LOADER_SRC="${FAKE_LOADER}"

mock_cmd_output id "0"
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *) echo "0" ;;
esac'

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# Verify the file is indeed empty (test setup sanity)
_size=$(wc -c < "${FAKE_LOADER}" 2>/dev/null | tr -d ' ')
assert_eq "Test setup: loader file is 0 bytes" "${_size}" "0"

# efi_check_prerequisites must return 1 for empty file
_prereq_rc=0
efi_check_prerequisites 2>/dev/null || _prereq_rc=$?

assert_eq \
    "efi_check_prerequisites returns 1 when loader file is empty" \
    "${_prereq_rc}" "1"

# update_bootloaders must also fail
_update_rc=0
update_bootloaders 2>/dev/null || _update_rc=$?

assert_eq \
    "update_bootloaders returns 1 when loader file is empty" \
    "${_update_rc}" "1"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
