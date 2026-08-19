#!/bin/sh
# test_08_esp_mountpoint.sh - Tests for efi_esp_mountpoint
#
# Verifies that efi_esp_mountpoint correctly reads mount(8) output and:
#   - returns empty when the device is not mounted
#   - returns the mountpoint when the device is mounted
#   - handles device names with and without the /dev/ prefix identically

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

FIXTURES_DIR="${TESTS_DIR}/fixtures"

mock_init

mock_cmd_output id "0"
mock_cmd_output sysctl "0"

_dummy_loader="$(mktemp)"
printf 'dummy' > "${_dummy_loader}"
EFI_LOADER_SRC="${_dummy_loader}"
export EFI_LOADER_SRC

. "${SRC_DIR}/efi_bootloader_update.sh"

tap_begin 5

# Test 1: device not in mount output -> returns empty
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_no_esp.txt\""
_result="$(efi_esp_mountpoint /dev/nda0p1 2>/dev/null)"
assert_empty "device not mounted -> returns empty" "${_result}"

# Test 2: device mounted at /boot/efi -> returns /boot/efi
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_esp_at_boot_efi.txt\""
_result="$(efi_esp_mountpoint /dev/nda0p1 2>/dev/null)"
assert_eq "device mounted -> returns /boot/efi" "${_result}" "/boot/efi"

# Test 3: device specified with /dev/ prefix -> returns mountpoint
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_esp_at_boot_efi.txt\""
_result="$(efi_esp_mountpoint /dev/nda0p1 2>/dev/null)"
assert_eq "with /dev/ prefix -> returns /boot/efi" "${_result}" "/boot/efi"

# Test 4: device specified without /dev/ prefix -> same result
# efi_esp_mountpoint prepends /dev/ when the prefix is absent.
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_esp_at_boot_efi.txt\""
_result="$(efi_esp_mountpoint nda0p1 2>/dev/null)"
assert_eq "without /dev/ prefix -> returns /boot/efi" "${_result}" "/boot/efi"

# Test 5: efi_mount_esp passes separate -o flags to mount_msdosfs
# Regression: "-o noexec,nosuid" was rejected by FreeBSD mount_msdosfs
# with "mount option <noexec,nosuid> is unknown: Invalid argument".
# Fix: two separate -o flags — "mount_msdosfs -o noexec -o nosuid".
: > "${MOCK_CALL_LOG}"
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_no_esp.txt\""  # ESP not already mounted
mock_cmd_output mount_msdosfs ""                            # mount succeeds
hash -r 2>/dev/null || true
EFI_DRY_RUN=0
_efi_tmp_mounts=""
efi_mount_esp nda0 1 2>/dev/null
_mnt_args="$(mock_last_args mount_msdosfs)"
assert_contains \
    "mount_msdosfs: -o noexec and -o nosuid passed as separate flags (FreeBSD compat)" \
    "${_mnt_args}" "-o noexec -o nosuid"
efi_cleanup_mounts 2>/dev/null

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
