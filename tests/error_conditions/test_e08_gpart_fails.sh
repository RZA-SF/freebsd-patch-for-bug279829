#!/bin/sh
# test_e08_gpart_fails.sh
#
# Error condition: gpart exits 1 when called with the "bootcode" subcommand.
# efi_update_bios_bootcode must return 1.
# update_bootloaders must return 1 (total_errors > 0).

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 3

setup_test_dir
mock_init

# --- Fake loader and BIOS boot files ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua gpart fail test' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

FAKE_PMBR="${TEST_DIR}/pmbr"
FAKE_GPTZFSBOOT="${TEST_DIR}/gptzfsboot"
printf 'pmbr' > "${FAKE_PMBR}"
printf 'gptzfsboot' > "${FAKE_GPTZFSBOOT}"
export EFI_BIOS_PMBR="${FAKE_PMBR}"
export EFI_BIOS_ZFS_BOOT="${FAKE_GPTZFSBOOT}"

mock_cmd_output id "0"
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "BIOS" ;;
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
	  ada0p3    ONLINE       0     0     0

errors: No known data errors
ZPS'

# gpart show succeeds, but gpart bootcode FAILS
mock_cmd gpart '
case "$*" in
    *show*ada0*)
        printf "=>       63  976773042  ada0  GPT  (466G)\n"
        printf "         63       1985     1  freebsd-boot  (993K)\n"
        printf "    4196352  972576752     3  freebsd-zfs  (464G)\n"
        ;;
    *bootcode*)
        echo "gpart: bootcode: write failed" >&2
        exit 1
        ;;
    *) exit 1 ;;
esac'

mock_cmd_output umount ""
mock_cmd_output rmdir ""
mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# Test efi_update_bios_bootcode directly
_bios_rc=0
efi_update_bios_bootcode ada0 1 2>/dev/null || _bios_rc=$?

assert_eq \
    "efi_update_bios_bootcode returns 1 when gpart bootcode fails" \
    "${_bios_rc}" "1"

# update_bootloaders should propagate the error
_update_rc=0
update_bootloaders 2>/dev/null || _update_rc=$?

assert_eq \
    "update_bootloaders returns 1 when gpart bootcode fails" \
    "${_update_rc}" "1"

# gpart bootcode was indeed called (it just failed)
_gpart_bootcode_called=0
if grep -q "gpart bootcode" "${MOCK_CALL_LOG}" 2>/dev/null; then
    _gpart_bootcode_called=1
fi
assert_eq \
    "gpart bootcode was attempted (but failed)" \
    "${_gpart_bootcode_called}" "1"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
