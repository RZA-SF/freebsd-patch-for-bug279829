#!/bin/sh
# test_e10_no_disks_found.sh
#
# Error condition: disk discovery fails completely — sysctl kern.disks
# returns an error.
# efi_discover_all_esps must return non-zero.
# update_bootloaders must return 0 (warns but is non-fatal per design).

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 4

setup_test_dir
mock_init

# --- Fake loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua no disks test' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

mock_cmd_output id "0"
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "UEFI" ;;
    *kern.disks*)           exit 1 ;;
    *) echo "0" ;;
esac'
mock_cmd_output uname "amd64"

mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\",\"noatime\"]}]}}\n"'

# zpool fails — efi_root_disks cannot determine root disks
mock_cmd_fail zpool 1

# efibootmgr not present — efi_boot_esps falls back to root_disks (which also fails)
mock_cmd_fail efibootmgr 127

# gpart must not be called (no candidate disks found)
mock_cmd_fail gpart 1

# mount_msdosfs must not be called
mock_cmd_fail mount_msdosfs 1

mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# Test efi_discover_all_esps directly — kern.disks fails
_discover_rc=0
efi_discover_all_esps 2>/dev/null || _discover_rc=$?

assert_ne \
    "efi_discover_all_esps returns non-zero when kern.disks fails" \
    "${_discover_rc}" "0"

# update_bootloaders should return 0 (non-fatal warn-and-continue)
_update_rc=99
update_bootloaders 2>/dev/null
_update_rc=$?

assert_eq \
    "update_bootloaders returns 0 when no disks found (non-fatal)" \
    "${_update_rc}" "0"

# No mount operations should have been attempted
_mount_calls=0
mock_was_called mount_msdosfs && _mount_calls=1
assert_eq \
    "mount_msdosfs NOT called when no disks found" \
    "${_mount_calls}" "0"

# No gpart operations
_gpart_calls=0
mock_was_called gpart && _gpart_calls=1
assert_eq \
    "gpart NOT called when no disks found" \
    "${_gpart_calls}" "0"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
