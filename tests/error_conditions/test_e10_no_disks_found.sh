#!/bin/sh
# test_e10_no_disks_found.sh
#
# Error condition: disk discovery fails completely — zfs command fails and
# /etc/fstab cannot be read (or has no usable root entry).
# efi_discover_boot_disks must return 1.
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
    *) echo "0" ;;
esac'
mock_cmd_output uname "amd64"

# mount: root is zfs (so efi_zfs_boot_disks path is taken)
mock_cmd mount '
case "$*" in
    *msdosfs*) exit 0 ;;
    *) printf "zroot on / type zfs (local)\n" ;;
esac'

# zfs fails to determine the pool name
mock_cmd_fail zfs 1

# zpool also fails
mock_cmd_fail zpool 1

# mount_msdosfs must not be called
mock_cmd_fail mount_msdosfs 1

mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# Override efi_ufs_boot_disks to also fail (no fstab available)
efi_ufs_boot_disks() {
    return 1
}

# Test efi_discover_boot_disks directly
_discover_rc=0
efi_discover_boot_disks 2>/dev/null || _discover_rc=$?

assert_eq \
    "efi_discover_boot_disks returns 1 when no disks found" \
    "${_discover_rc}" "1"

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
