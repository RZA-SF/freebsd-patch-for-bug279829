#!/bin/sh
# test_10_space_check.sh - Tests for efi_check_space
#
# Verifies that efi_check_space correctly computes the required space
# (2 * loader_size + 64 KiB) from mocked stat and df outputs and returns
# the right exit code.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

mock_init

mock_cmd_output id "0"
mock_cmd_output sysctl "0"

_dummy_loader="$(mktemp)"
printf 'dummy' > "${_dummy_loader}"
EFI_LOADER_SRC="${_dummy_loader}"
export EFI_LOADER_SRC

. "${SRC_DIR}/efi_bootloader_update.sh"

# efi_check_space uses:
#   stat -f '%z' ${EFI_LOADER_SRC}  -> loader size in bytes
#   df -k ESP_MOUNT                 -> available KB in field $4 of second line
#
# Formula: required = (loader_size * 2) + 65536
# With loader_size = 524288 bytes (512 KiB):
#   required = 1048576 + 65536 = 1114112 bytes = 1088 KiB

_LOADER_SIZE=524288   # 512 KiB
_REQUIRED_KB=1088     # (512*2 + 64) KiB

tap_begin 6

# Test 1: plenty of space -> returns 0
# avail = 10240 KiB = 10 MiB, well above required 1088 KiB
mock_cmd stat "echo ${_LOADER_SIZE}"
mock_cmd df "printf 'Filesystem  1K-blocks  Used  Avail  Capacity  Mounted on\n/dev/nda0p1  204800  10240  10240  5%%  /boot/efi\n'"
assert_true "plenty of space -> returns 0" efi_check_space "/boot/efi"

# Test 2: exactly enough space (available == required) -> returns 0
mock_cmd stat "echo ${_LOADER_SIZE}"
mock_cmd df "printf 'Filesystem  1K-blocks  Used  Avail  Capacity  Mounted on\n/dev/nda0p1  2048  960  ${_REQUIRED_KB}  47%%  /boot/efi\n'"
assert_true "exactly required space available -> returns 0" efi_check_space "/boot/efi"

# Test 3: one byte short -> returns 1
# avail = (required_KB - 1) KiB * 1024 gives (required - 1024) bytes < required bytes
# Use required_KB - 1 KiB available so avail_bytes = (1088-1)*1024 = 1113088, required = 1114112
_SHORT_KB=$(( _REQUIRED_KB - 1 ))
mock_cmd stat "echo ${_LOADER_SIZE}"
mock_cmd df "printf 'Filesystem  1K-blocks  Used  Avail  Capacity  Mounted on\n/dev/nda0p1  2048  961  ${_SHORT_KB}  47%%  /boot/efi\n'"
assert_false "one KiB short -> returns 1" efi_check_space "/boot/efi"

# Test 4: stat fails -> returns 1
mock_cmd_fail stat 1
mock_cmd df "printf 'Filesystem  1K-blocks  Used  Avail  Capacity  Mounted on\n/dev/nda0p1  204800  10240  10240  5%%  /boot/efi\n'"
assert_false "stat fails -> returns 1" efi_check_space "/boot/efi"

# Test 5: df fails -> returns 1
mock_cmd stat "echo ${_LOADER_SIZE}"
mock_cmd_fail df 1
assert_false "df fails -> returns 1" efi_check_space "/boot/efi"

# Test 6: dry-run mode -> always returns 0; df is never consulted
EFI_DRY_RUN=1
mock_cmd stat "echo ${_LOADER_SIZE}"
mock_cmd_fail df 1   # df would fail if called, confirming it is skipped
assert_true "dry-run: space check skipped, returns 0" efi_check_space "/boot/efi"
EFI_DRY_RUN=0

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
