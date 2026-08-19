#!/bin/sh
# test_e12_safe_copy_mv_fails.sh
#
# Error condition: cp succeeds but mv fails (e.g. read-only destination
# directory after the temp file has been created).
# efi_safe_copy must return 1.
# The temp file (.new) must be cleaned up.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 4

setup_test_dir
mock_init

# --- Fake loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua safe copy mv fail test' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- Set up a destination where mv will fail ---
# Create a destination directory, then make it read-only after cp writes .new
DEST_DIR="${TEST_DIR}/ro_dir"
mkdir -p "${DEST_DIR}"
DST_FILE="${DEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua original content' > "${DST_FILE}"

# We cannot easily make a directory read-only and have cp still write .new
# in a portable way without root, so instead we mock mv to fail while letting
# cp succeed normally.  The mock_framework PATH prepend means our mock mv
# takes priority.

mock_cmd mv '
# Log the call, then fail
echo "mv $*" >> "${MOCK_CALL_LOG}"
echo "mock: mv: rename failed (simulated)" >&2
exit 1'

mock_cmd_output id "0"
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *) echo "0" ;;
esac'
mock_cmd_output sync ""

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# --- Test efi_safe_copy directly ---
_copy_rc=0
efi_safe_copy "${FAKE_LOADER}" "${DST_FILE}" 2>/dev/null || _copy_rc=$?

assert_eq \
    "efi_safe_copy returns 1 when mv fails" \
    "${_copy_rc}" "1"

# The temp file must have been cleaned up
assert_file_not_exists \
    "Temp file (.new) cleaned up after mv failure" \
    "${DST_FILE}.new"

# The original destination file must be unchanged
_dst_content=$(cat "${DST_FILE}" 2>/dev/null)
assert_contains \
    "Original destination file not corrupted after mv failure" \
    "${_dst_content}" "original content"

# mv must have been called (cp succeeded first, then mv was attempted)
assert_true \
    "mv was called (cp succeeded, then mv was attempted)" \
    mock_was_called mv

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
