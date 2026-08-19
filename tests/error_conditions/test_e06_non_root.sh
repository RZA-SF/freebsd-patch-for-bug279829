#!/bin/sh
# test_e06_non_root.sh
#
# Error condition: script run by non-root user (id -u returns 1000).
# efi_check_prerequisites must return 1.
# update_bootloaders must return 1.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 3

setup_test_dir
mock_init

# --- Fake loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua non-root test' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- Mock: id returns 1000 (non-root user) ---
mock_cmd_output id "1000"

mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *) echo "0" ;;
esac'

# mount_msdosfs must NOT be called when not root
mock_cmd_fail mount_msdosfs 1

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# efi_check_prerequisites should return 1 (not root)
_prereq_rc=0
efi_check_prerequisites 2>/dev/null || _prereq_rc=$?

assert_eq \
    "efi_check_prerequisites returns 1 when not root (uid=1000)" \
    "${_prereq_rc}" "1"

# update_bootloaders should also return 1
_update_rc=0
update_bootloaders 2>/dev/null || _update_rc=$?

assert_eq \
    "update_bootloaders returns 1 when not root" \
    "${_update_rc}" "1"

# No mount operations
_mount_calls=0
mock_was_called mount_msdosfs && _mount_calls=1
assert_eq \
    "mount_msdosfs NOT called when not root" \
    "${_mount_calls}" "0"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
