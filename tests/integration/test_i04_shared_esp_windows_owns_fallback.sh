#!/bin/sh
# test_i04_shared_esp_windows_owns_fallback.sh
#
# Integration test: shared ESP where Windows owns the fallback path.
#
# ESP contains:
#   EFI/BOOT/BOOTx64.efi  — "Windows Boot Manager Microsoft" content
#   EFI/FreeBSD/loader.efi — existing FreeBSD loader (older version)
#
# After update:
#   - EFI/FreeBSD/loader.efi updated
#   - EFI/BOOT/BOOTx64.efi NOT updated (not a FreeBSD loader)
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
printf 'FreeBSD loader.efi boot/lua new content v2' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- Build ESP: Windows owns fallback, FreeBSD has its own dir ---
mkdir -p "${TEST_ESP_DIR}/EFI/BOOT"
mkdir -p "${TEST_ESP_DIR}/EFI/FreeBSD"
printf 'Windows Boot Manager Microsoft' > "${TEST_ESP_DIR}/EFI/BOOT/BOOTx64.efi"
printf 'FreeBSD loader.efi boot/lua old content v1' > "${TEST_ESP_DIR}/EFI/FreeBSD/loader.efi"

# Snapshot original Windows binary content for comparison later
_windows_content_before=$(cat "${TEST_ESP_DIR}/EFI/BOOT/BOOTx64.efi")

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
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"465G\"}]}]}\n"
        ;;
    *) exit 1 ;;
esac'

mock_cmd_output umount ""
mock_cmd_output rmdir ""

mock_cmd df 'printf "Filesystem 1K-blocks Used Avail\n/dev/ada0p1 204800 1024 203776\n"'

# strings mock: must correctly NOT report FreeBSD strings for the Windows file
# We fake strings to just output the file content literally (which is "Windows Boot Manager Microsoft")
mock_cmd strings 'cat "$@" 2>/dev/null || true'

mock_cmd efibootmgr '
case "$*" in
    *-v*) printf "Boot0001* FreeBSD\t\\EFI\\FreeBSD\\loader.efi\n" ;;
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

assert_eq "update_bootloaders returns 0" "${_rc}" "0"

# FreeBSD loader must be updated
_freebsd_content=$(cat "${FAKE_MP}/EFI/FreeBSD/loader.efi" 2>/dev/null)
assert_contains \
    "EFI/FreeBSD/loader.efi updated to new version" \
    "${_freebsd_content}" "new content v2"

# Windows fallback must NOT have been overwritten
_windows_content_after=$(cat "${FAKE_MP}/EFI/BOOT/BOOTx64.efi" 2>/dev/null)
assert_eq \
    "EFI/BOOT/BOOTx64.efi content unchanged (Windows loader preserved)" \
    "${_windows_content_after}" "${_windows_content_before}"

assert_contains \
    "EFI/BOOT/BOOTx64.efi still reads as Windows Boot Manager" \
    "${_windows_content_after}" "Windows Boot Manager"

# efibootmgr should have been consulted (existing entry found, no new one needed)
assert_true \
    "efibootmgr consulted for NVRAM entry check" \
    mock_was_called efibootmgr

# gpart bootcode must NOT have been called (no freebsd-boot partition)
_gpart_bootcode_called=0
if grep -q "gpart bootcode" "${MOCK_CALL_LOG}" 2>/dev/null; then
    _gpart_bootcode_called=1
fi
assert_eq \
    "gpart bootcode NOT called (no freebsd-boot partition)" \
    "${_gpart_bootcode_called}" "0"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
