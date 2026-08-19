#!/bin/sh
# test_e07_mount_fails.sh
#
# Error condition: mount_msdosfs exits 1 (e.g., corrupt FAT, missing device).
# update_bootloaders must return 1.
# No files must be created or modified on the ESP.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 4

setup_test_dir
mock_init

# --- Fake loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua mount fail test' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

FAKE_MP="${TEST_DIR}/fake_mp"
mkdir -p "${FAKE_MP}"

mock_cmd mktemp "echo '${FAKE_MP}'"

# mount_msdosfs FAILS
mock_cmd_fail mount_msdosfs 1

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
    *msdosfs*) exit 1 ;;
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
	  nda0p2    ONLINE       0     0     0

errors: No known data errors
ZPS'
mock_cmd gpart '
case "$*" in
    *show*nda0*)
        printf "=>       40  976773095  nda0  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640  976363456     2  freebsd-zfs  (465G)\n"
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

# --- Run ---
_update_rc=0
update_bootloaders 2>/dev/null || _update_rc=$?

# --- Assertions ---

assert_eq \
    "update_bootloaders returns 1 when mount_msdosfs fails" \
    "${_update_rc}" "1"

# mount_msdosfs was called (at least once — the attempt)
assert_true \
    "mount_msdosfs was called (attempt was made)" \
    mock_was_called mount_msdosfs

# No EFI files should have been written to the fake mountpoint
assert_file_not_exists \
    "EFI/FreeBSD/loader.efi NOT created after mount failure" \
    "${FAKE_MP}/EFI/FreeBSD/loader.efi"

assert_file_not_exists \
    "EFI/BOOT/BOOTx64.efi NOT created after mount failure" \
    "${FAKE_MP}/EFI/BOOT/BOOTx64.efi"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
