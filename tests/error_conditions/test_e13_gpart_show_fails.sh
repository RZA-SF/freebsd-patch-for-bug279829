#!/bin/sh
# test_e13_gpart_show_fails.sh
#
# Error condition: gpart show returns non-zero for all disks.
# efi_discover_all_esps and efi_discover_all_bios_parts must return non-zero.
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
    *kern.disks*)           echo "nda0" ;;
    *) echo "0" ;;
esac'
mock_cmd_output uname "amd64"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\",\"noatime\"]}]}}\n"'

# zpool: returns nda0p4 so root_disks succeeds -> efi_boot_esps finds nda0 as candidate
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

# efibootmgr not found — efi_boot_esps falls back to root_disks only
mock_cmd_fail efibootmgr 127

# gpart show (and list) fails for all disks
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

# Test efi_discover_all_esps directly — gpart show fails
_esp_rc=0
efi_discover_all_esps 2>/dev/null || _esp_rc=$?

assert_ne \
    "efi_discover_all_esps returns non-zero when gpart show fails" \
    "${_esp_rc}" "0"

# Also test efi_discover_all_bios_parts — must also return non-zero
_bios_rc=0
efi_discover_all_bios_parts 2>/dev/null || _bios_rc=$?

assert_ne \
    "efi_discover_all_bios_parts returns non-zero when gpart show fails" \
    "${_bios_rc}" "0"

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
