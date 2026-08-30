#!/bin/sh
# test_i07_esp_already_mounted.sh
#
# Integration test: ESP is already mounted at /boot/efi when the script runs.
#
# update_bootloaders must:
#   - Reuse the existing mountpoint (/boot/efi), NOT call mount_msdosfs again
#   - NOT call umount when done (it did not mount it)
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
printf 'FreeBSD loader.efi boot/lua already-mounted test' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- Simulate /boot/efi as the pre-existing mountpoint ---
# We use TEST_ESP_DIR to stand in for /boot/efi content
EXISTING_MP="${TEST_ESP_DIR}"
mkdir -p "${EXISTING_MP}/EFI/FreeBSD"
printf 'FreeBSD loader.efi boot/lua old loader' > "${EXISTING_MP}/EFI/FreeBSD/loader.efi"

# --- Mocks ---
mock_cmd_output id "0"

mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "UEFI" ;;
    *kern.disks*)           echo "nda0" ;;
    *) echo "0" ;;
esac'

mock_cmd_output uname "amd64"

# mount --libxo json: show /dev/nda0p1 already mounted at our EXISTING_MP
# Uses double quotes so ${EXISTING_MP} expands at mock-definition time.
mock_cmd mount "printf '{\"mount\":{\"mounted\":[{\"special\":\"/dev/nda0p1\",\"node\":\"${EXISTING_MP}\",\"fstype\":\"msdosfs\",\"opts\":[\"rw\"]},{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\",\"noatime\"]}]}}\n'"
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

mock_cmd gpart '
case "$*" in
    *show*nda0*)
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"465G\"}]}]}\n"
        ;;
    *) exit 1 ;;
esac'

# mount_msdosfs mock that fails with diagnostic if called (it should not be)
mock_cmd_fail mount_msdosfs 1

mock_cmd_output umount ""
mock_cmd_output rmdir ""

mock_cmd df "printf 'Filesystem 1K-blocks Used Avail\n/dev/nda0p1 204800 1024 203776\n'"

mock_cmd strings 'grep -a "." "$@" 2>/dev/null || true'
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

# --- Run ---
update_bootloaders
_rc=$?

# --- Assertions ---

assert_eq "update_bootloaders returns 0 with pre-mounted ESP" "${_rc}" "0"

# mount_msdosfs must NOT have been called
_mount_calls=0
mock_was_called mount_msdosfs && _mount_calls=1
assert_eq \
    "mount_msdosfs NOT called (ESP was already mounted)" \
    "${_mount_calls}" "0"

# The pre-existing mountpoint should have had its loader updated
assert_file_exists \
    "EFI/FreeBSD/loader.efi exists at pre-existing mountpoint" \
    "${EXISTING_MP}/EFI/FreeBSD/loader.efi"

_content=$(cat "${EXISTING_MP}/EFI/FreeBSD/loader.efi" 2>/dev/null)
assert_contains \
    "EFI/FreeBSD/loader.efi content updated" \
    "${_content}" "already-mounted test"

# umount must NOT have been called (we did not mount it)
_umount_calls=0
mock_was_called umount && _umount_calls=1
assert_eq \
    "umount NOT called (we did not mount the ESP)" \
    "${_umount_calls}" "0"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
