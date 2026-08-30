#!/bin/sh
# test_i08_fresh_esp_no_freebsd_files.sh
#
# Integration test: completely empty ESP (only EFI/ directory, nothing inside).
# Simulates a fresh install or a BIOS-to-UEFI migration where the ESP was
# partitioned but never populated.
#
# After update:
#   - EFI/FreeBSD/loader.efi created
#   - EFI/BOOT/BOOTx64.efi created (no existing file at all, so always create)
#   - NVRAM entry creation attempted via efibootmgr
#
# 6 assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 6

setup_test_dir
mock_init

# --- Fake loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua fresh esp content' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- Completely empty ESP: only EFI/ directory ---
mkdir -p "${TEST_ESP_DIR}/EFI"

# --- Fake mountpoint ---
FAKE_MP="${TEST_DIR}/fake_mp"
mkdir -p "${FAKE_MP}"

mock_cmd mktemp "echo '${FAKE_MP}'"
mock_cmd mount_msdosfs "
cp -r '${TEST_ESP_DIR}/.' '${FAKE_MP}/'
exit 0"

# --- Standard mocks ---
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
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"465G\"}]}]}\n"
        ;;
    *) exit 1 ;;
esac'

mock_cmd_output umount ""
mock_cmd_output rmdir ""
mock_cmd df 'printf "Filesystem 1K-blocks Used Avail\n/dev/nda0p1 204800 1024 203776\n"'
mock_cmd strings 'grep -a "." "$@" 2>/dev/null || true'

# efibootmgr: no existing FreeBSD entry, creation attempt succeeds
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
# Simulate EFIRT present on Linux (where /dev/efi does not exist)
_EFI_DEV_EFI=/dev/null
export _EFI_DEV_EFI

# --- Run ---
update_bootloaders
_rc=$?

# --- Assertions ---

assert_eq "update_bootloaders returns 0 on fresh/empty ESP" "${_rc}" "0"

assert_file_exists \
    "EFI/FreeBSD/loader.efi created from scratch" \
    "${FAKE_MP}/EFI/FreeBSD/loader.efi"

assert_file_exists \
    "EFI/BOOT/BOOTx64.efi created from scratch" \
    "${FAKE_MP}/EFI/BOOT/BOOTx64.efi"

_freebsd_content=$(cat "${FAKE_MP}/EFI/FreeBSD/loader.efi" 2>/dev/null)
assert_contains \
    "EFI/FreeBSD/loader.efi has correct content" \
    "${_freebsd_content}" "fresh esp content"

_boot_content=$(cat "${FAKE_MP}/EFI/BOOT/BOOTx64.efi" 2>/dev/null)
assert_contains \
    "EFI/BOOT/BOOTx64.efi has correct content" \
    "${_boot_content}" "fresh esp content"

# efibootmgr must have been called to attempt NVRAM entry creation
assert_true \
    "efibootmgr called for new NVRAM entry" \
    mock_was_called efibootmgr

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
