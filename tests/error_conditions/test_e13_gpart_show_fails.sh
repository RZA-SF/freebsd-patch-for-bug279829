#!/bin/sh
# test_e13_gpart_show_fails.sh
#
# Error condition: gpart show returns non-zero for all disks.
# efi_efi_partitions must return empty output.
# No ESP processing must be attempted.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 4

setup_test_dir
mock_init

# --- Fake loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua gpart show fail test' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

mock_cmd_output id "0"
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "UEFI" ;;
    *) echo "0" ;;
esac'
mock_cmd_output uname "amd64"
mock_cmd mount '
case "$*" in
    *msdosfs*) exit 0 ;;
    *) printf "zroot on / type zfs (local)\n" ;;
esac'
mock_cmd_output zfs "zroot"
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME        STATE     READ WRITE CKSUM
	zroot       ONLINE       0     0     0
	  nda0p4    ONLINE       0     0     0

errors: No known data errors
ZPS'

# gpart show fails for all disks
mock_cmd_fail gpart 1

# mount_msdosfs must NOT be called (no EFI partition discovered)
mock_cmd_fail mount_msdosfs 1

mock_cmd_output umount ""
mock_cmd_output rmdir ""
mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# Test efi_efi_partitions directly — must return empty
_efi_parts=$(efi_efi_partitions nda0 2>/dev/null)

assert_empty \
    "efi_efi_partitions returns empty when gpart show fails" \
    "${_efi_parts}"

# Also test efi_bios_partitions — must also return empty
_bios_parts=$(efi_bios_partitions nda0 2>/dev/null)

assert_empty \
    "efi_bios_partitions returns empty when gpart show fails" \
    "${_bios_parts}"

# update_bootloaders should still return 0 (no partitions = nothing to do)
_update_rc=99
update_bootloaders 2>/dev/null
_update_rc=$?

assert_eq \
    "update_bootloaders returns 0 when gpart show fails (nothing to process)" \
    "${_update_rc}" "0"

# mount_msdosfs must NOT have been called
_mount_calls=0
mock_was_called mount_msdosfs && _mount_calls=1
assert_eq \
    "mount_msdosfs NOT called when gpart show fails" \
    "${_mount_calls}" "0"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
