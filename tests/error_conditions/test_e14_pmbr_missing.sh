#!/bin/sh
# test_e14_pmbr_missing.sh
#
# Error condition: EFI_BIOS_PMBR file does not exist.
# efi_update_bios_bootcode must return 1 with an error message.
# update_bootloaders must return 1.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 4

setup_test_dir
mock_init

# --- Fake loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua pmbr missing test' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- Point PMBR at a path that does not exist ---
export EFI_BIOS_PMBR="/nonexistent/path/pmbr"

# gptzfsboot does exist
FAKE_GPTZFSBOOT="${TEST_DIR}/gptzfsboot"
printf 'gptzfsboot' > "${FAKE_GPTZFSBOOT}"
export EFI_BIOS_ZFS_BOOT="${FAKE_GPTZFSBOOT}"

mock_cmd_output id "0"
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "BIOS" ;;
    *kern.disks*)           echo "ada0" ;;
    *) echo "0" ;;
esac'
mock_cmd_output uname "amd64"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\",\"noatime\"]}]}}\n"'
mock_cmd_output zfs "zroot"
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME        STATE     READ WRITE CKSUM
	zroot       ONLINE       0     0     0
	  ada0p3    ONLINE       0     0     0

errors: No known data errors
ZPS'
mock_cmd gpart '
case "$*" in
    *show*ada0*)
        printf "=>       63  976773042  ada0  GPT  (466G)\n"
        printf "         63       1985     1  freebsd-boot  (993K)\n"
        printf "    4196352  972576752     3  freebsd-zfs  (464G)\n"
        ;;
    *bootcode*)
        # Should not be reached: prerequisite check should fail first
        exit 1
        ;;
    *) exit 1 ;;
esac'
mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# Test efi_update_bios_bootcode directly
_bios_rc=0
_stderr=$(efi_update_bios_bootcode ada0 1 2>&1 >/dev/null) || _bios_rc=$?

assert_eq \
    "efi_update_bios_bootcode returns 1 when PMBR file is missing" \
    "${_bios_rc}" "1"

assert_contains \
    "Error message references the missing PMBR file" \
    "${_stderr}" "pmbr"

# update_bootloaders must fail
_update_rc=0
update_bootloaders 2>/dev/null || _update_rc=$?

assert_eq \
    "update_bootloaders returns 1 when PMBR missing" \
    "${_update_rc}" "1"

# gpart bootcode must NOT have been called (prerequisite check aborted)
_gpart_bootcode_called=0
if grep -q "gpart bootcode" "${MOCK_CALL_LOG}" 2>/dev/null; then
    _gpart_bootcode_called=1
fi
assert_eq \
    "gpart bootcode NOT called when PMBR file is missing" \
    "${_gpart_bootcode_called}" "0"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
