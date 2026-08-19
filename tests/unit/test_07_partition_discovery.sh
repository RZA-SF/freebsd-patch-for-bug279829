#!/bin/sh
# test_07_partition_discovery.sh - Tests for efi_efi_partitions and efi_bios_partitions
#
# Verifies that the correct partition indices are returned when gpart output
# contains efi and/or freebsd-boot entries, and that an empty result is
# returned when neither type is present or when gpart fails.

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

tap_begin 8

# Test 1: disk with efi + freebsd-boot -> efi_efi_partitions returns "1"
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_single_efi_bios.txt\""
_result="$(efi_efi_partitions nda0 2>/dev/null)"
assert_eq "efi+bios disk: efi_efi_partitions returns 1" "${_result}" "1"

# Test 2: disk with efi + freebsd-boot -> efi_bios_partitions returns "2"
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_single_efi_bios.txt\""
_result="$(efi_bios_partitions nda0 2>/dev/null)"
assert_eq "efi+bios disk: efi_bios_partitions returns 2" "${_result}" "2"

# Test 3: disk with only efi -> efi_efi_partitions returns "1"
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_single_efi_only.txt\""
_result="$(efi_efi_partitions nvd0 2>/dev/null)"
assert_eq "efi-only disk: efi_efi_partitions returns 1" "${_result}" "1"

# Test 4: disk with only efi -> efi_bios_partitions returns empty
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_single_efi_only.txt\""
_result="$(efi_bios_partitions nvd0 2>/dev/null)"
assert_empty "efi-only disk: efi_bios_partitions returns empty" "${_result}"

# Test 5: disk with no efi (MBR layout) -> efi_efi_partitions returns empty
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_no_efi.txt\""
_result="$(efi_efi_partitions ada0 2>/dev/null)"
assert_empty "no-efi disk: efi_efi_partitions returns empty" "${_result}"

# Test 6: disk with no efi (MBR layout) -> efi_bios_partitions returns empty
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_no_efi.txt\""
_result="$(efi_bios_partitions ada0 2>/dev/null)"
assert_empty "no-efi disk: efi_bios_partitions returns empty" "${_result}"

# Test 7: gpart fails -> efi_efi_partitions returns empty
mock_cmd_fail gpart 1
_result="$(efi_efi_partitions ada0 2>/dev/null)"
assert_empty "gpart fails: efi_efi_partitions returns empty" "${_result}"

# Test 8: gpart fails -> efi_bios_partitions returns empty
mock_cmd_fail gpart 1
_result="$(efi_bios_partitions ada0 2>/dev/null)"
assert_empty "gpart fails: efi_bios_partitions returns empty" "${_result}"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
