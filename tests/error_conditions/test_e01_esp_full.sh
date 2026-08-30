#!/bin/sh
# test_e01_esp_full.sh
#
# Error condition: ESP has 0 KB available.
# efi_check_space must return 1.
# update_bootloaders must return 1.
# No files must be modified on the ESP.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 4

setup_test_dir
mock_init

# --- Fake loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua full esp test content' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- ESP: has EFI/FreeBSD/loader.efi already ---
mkdir -p "${TEST_ESP_DIR}/EFI/FreeBSD"
printf 'FreeBSD loader.efi boot/lua old content' > "${TEST_ESP_DIR}/EFI/FreeBSD/loader.efi"

FAKE_MP="${TEST_DIR}/fake_mp"
mkdir -p "${FAKE_MP}"
cp -r "${TEST_ESP_DIR}/." "${FAKE_MP}/"

mock_cmd mktemp "echo '${FAKE_MP}'"
mock_cmd mount_msdosfs "exit 0"

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
mock_cmd_output sync ""
mock_cmd stat 'echo "102400"'

# df returns 0 available KB — full disk
mock_cmd df 'printf "Filesystem 1K-blocks Used Avail\n/dev/nda0p1 204800 204800 0\n"'

mock_cmd strings 'grep -a "." "$@" 2>/dev/null || true'

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# Test efi_check_space directly with the full ESP
_space_rc=0
efi_check_space "${FAKE_MP}" || _space_rc=$?

assert_eq \
    "efi_check_space returns 1 when ESP is full" \
    "${_space_rc}" "1"

# Record content before update attempt
_content_before=$(cat "${FAKE_MP}/EFI/FreeBSD/loader.efi" 2>/dev/null)

# Run update_bootloaders — it should fail
_update_rc=0
update_bootloaders || _update_rc=$?

assert_eq \
    "update_bootloaders returns 1 when ESP is full" \
    "${_update_rc}" "1"

# Content should not have changed
_content_after=$(cat "${FAKE_MP}/EFI/FreeBSD/loader.efi" 2>/dev/null)
assert_eq \
    "EFI/FreeBSD/loader.efi not modified when ESP full" \
    "${_content_after}" "${_content_before}"

# efi_safe_copy should not have been invoked (space check aborts early)
_copy_count=0
if grep -q "^cp " "${MOCK_CALL_LOG}" 2>/dev/null; then
    _copy_count=1
fi
assert_eq \
    "cp (copy) not called when ESP is full" \
    "${_copy_count}" "0"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
