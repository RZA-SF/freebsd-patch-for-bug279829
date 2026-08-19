#!/bin/sh
# test_02_boot_method.sh - Tests for efi_boot_method
#
# Verifies that efi_boot_method correctly reads machdep.bootmethod from
# sysctl and handles failure by returning "unknown".

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

mock_init

# Provide a non-empty dummy loader so the prerequisite check passes sourcing.
_dummy_loader="$(mktemp)"
printf 'dummy' > "${_dummy_loader}"
EFI_LOADER_SRC="${_dummy_loader}"
export EFI_LOADER_SRC

# Initial sysctl mock: report not-jailed (0) so sourcing does not abort.
mock_cmd_output sysctl "0"
mock_cmd_output id "0"

. "${SRC_DIR}/efi_bootloader_update.sh"

tap_begin 3

# Test 1: sysctl returns "UEFI"
mock_cmd_output sysctl "UEFI"
assert_eq "sysctl returns UEFI -> function returns UEFI" \
    "$(efi_boot_method)" "UEFI"

# Test 2: sysctl returns "BIOS"
mock_cmd_output sysctl "BIOS"
assert_eq "sysctl returns BIOS -> function returns BIOS" \
    "$(efi_boot_method)" "BIOS"

# Test 3: sysctl fails -> function returns "unknown"
mock_cmd_fail sysctl 1
assert_eq "sysctl fails -> function returns unknown" \
    "$(efi_boot_method)" "unknown"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
