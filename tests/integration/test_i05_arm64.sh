#!/bin/sh
# test_i05_arm64.sh
#
# Integration test: arm64 system (uname -m returns "arm64"), single disk,
# EFI partition only.  ESP starts with EFI/boot/BOOTaa64.efi only.
#
# After update:
#   - EFI/FreeBSD/loader.efi created
#   - EFI/boot/BOOTaa64.efi updated
#   - BOOTx64.efi NOT created (architecture-specific binary is BOOTaa64.efi)
#
# 5 assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 5

setup_test_dir
mock_init

# --- Fake loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua arm64 test content' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- ESP: only EFI/boot/BOOTaa64.efi (no EFI/FreeBSD/) ---
mkdir -p "${TEST_ESP_DIR}/EFI/boot"
printf 'FreeBSD loader.efi boot/lua arm64 old loader' > "${TEST_ESP_DIR}/EFI/boot/BOOTaa64.efi"

# --- Fake mountpoint ---
FAKE_MP="${TEST_DIR}/fake_mp"
mkdir -p "${FAKE_MP}"

mock_cmd mktemp "echo '${FAKE_MP}'"
mock_cmd mount_msdosfs "
cp -r '${TEST_ESP_DIR}/.' '${FAKE_MP}/'
exit 0"

# --- Mocks ---
mock_cmd_output id "0"

mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "UEFI" ;;
    *kern.disks*)           echo "mmcsd0" ;;
    *) echo "0" ;;
esac'

# uname returns arm64
mock_cmd_output uname "arm64"

mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\",\"noatime\"]}]}}\n"'

mock_cmd_output zfs "zroot"
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME        STATE     READ WRITE CKSUM
	zroot       ONLINE       0     0     0
	  mmcsd0p2  ONLINE       0     0     0

errors: No known data errors
ZPS'

mock_cmd gpart '
case "$*" in
    *show*mmcsd0*)
        printf "=>       40  62333952  mmcsd0  GPT  (30G)\n"
        printf "         40    204800     1  efi  (100M)\n"
        printf "     204840  62129152     2  freebsd-zfs  (30G)\n"
        ;;
    *) exit 1 ;;
esac'

mock_cmd_output umount ""
mock_cmd_output rmdir ""

mock_cmd df 'printf "Filesystem 1K-blocks Used Avail\n/dev/mmcsd0p1 102400 1024 101376\n"'

mock_cmd strings 'grep -a "." "$@" 2>/dev/null || true'
mock_cmd efibootmgr '
case "$*" in
    *-v*) echo "" ;;
    *-a*-c*) exit 0 ;;
    *) exit 0 ;;
esac'
mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# --- Run ---
update_bootloaders
_rc=$?

# --- Assertions ---

assert_eq "update_bootloaders returns 0 on arm64" "${_rc}" "0"

assert_file_exists \
    "EFI/FreeBSD/loader.efi created on arm64 ESP" \
    "${FAKE_MP}/EFI/FreeBSD/loader.efi"

assert_file_exists \
    "EFI/boot/BOOTaa64.efi exists after update" \
    "${FAKE_MP}/EFI/boot/BOOTaa64.efi"

_aa64_content=$(cat "${FAKE_MP}/EFI/boot/BOOTaa64.efi" 2>/dev/null)
assert_contains \
    "EFI/boot/BOOTaa64.efi updated with new loader content" \
    "${_aa64_content}" "arm64 test content"

# BOOTx64.efi must NOT have been created
assert_file_not_exists \
    "EFI/boot/BOOTx64.efi was NOT created (wrong arch)" \
    "${FAKE_MP}/EFI/boot/BOOTx64.efi"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
