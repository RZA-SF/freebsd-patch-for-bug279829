#!/bin/sh
# test_e05_in_jail.sh
#
# Error condition: running inside a FreeBSD jail.
# sysctl security.jail.jailed returns "1".
# efi_check_prerequisites must return 2 (jail = skip, not error).
# update_bootloaders must return 0 (jail = graceful skip).

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 4

setup_test_dir
mock_init

# --- Fake loader (must exist so we get past the file-not-found check,
#     but jail detection happens before the file check in the function) ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua jail test' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- Mock: id returns 0 (root), sysctl jail check returns 1 ---
mock_cmd_output id "0"
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "1" ;;
    *machdep.bootmethod*)   echo "UEFI" ;;
    *) echo "0" ;;
esac'

# mount_msdosfs must NOT be called inside a jail
mock_cmd_fail mount_msdosfs 1

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# efi_check_prerequisites should return 2 (jail)
_prereq_rc=0
efi_check_prerequisites 2>/dev/null || _prereq_rc=$?

assert_eq \
    "efi_check_prerequisites returns 2 when running in jail" \
    "${_prereq_rc}" "2"

# update_bootloaders should return 0 (jail = skip gracefully)
_update_rc=99
update_bootloaders 2>/dev/null
_update_rc=$?

assert_eq \
    "update_bootloaders returns 0 when running in jail (graceful skip)" \
    "${_update_rc}" "0"

# No disk operations should have been performed
_mount_calls=0
mock_was_called mount_msdosfs && _mount_calls=1
assert_eq \
    "mount_msdosfs NOT called inside jail" \
    "${_mount_calls}" "0"

_gpart_calls=0
mock_was_called gpart && _gpart_calls=1
assert_eq \
    "gpart NOT called inside jail" \
    "${_gpart_calls}" "0"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
