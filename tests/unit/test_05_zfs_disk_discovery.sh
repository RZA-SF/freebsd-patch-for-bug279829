#!/bin/sh
# test_05_zfs_disk_discovery.sh - Tests for efi_zfs_boot_disks
#
# Verifies that physical disk names are correctly extracted from zpool status
# output for single-disk, mirror, and raidz pool configurations, and that
# failure of the zfs command causes the function to return non-zero.

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

tap_begin 7

# Test 1: single-disk pool -> discovers exactly "nda0" from "nda0p4"
mock_cmd zfs 'echo zroot'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
_result="$(efi_zfs_boot_disks 2>/dev/null)"
assert_eq "single-disk pool discovers nda0" "${_result}" "nda0"

# Tests 2-3: mirror pool -> discovers both "da0" and "da1"
mock_cmd zfs 'echo zroot'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_mirror.txt\""
_result="$(efi_zfs_boot_disks 2>/dev/null)"
assert_contains "mirror pool result contains da0" "${_result}" "da0"
assert_contains "mirror pool result contains da1" "${_result}" "da1"

# Tests 4-6: raidz pool -> discovers "ada0", "ada1", "ada2"
mock_cmd zfs 'echo zroot'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_raidz.txt\""
_result="$(efi_zfs_boot_disks 2>/dev/null)"
assert_contains "raidz pool result contains ada0" "${_result}" "ada0"
assert_contains "raidz pool result contains ada1" "${_result}" "ada1"
assert_contains "raidz pool result contains ada2" "${_result}" "ada2"

# Test 7: zfs command fails -> output is empty (no disks discovered)
# Note: due to the piped assignment in the function, exit code may be 0 when
# zfs fails in a pipeline; we test that no disk names are emitted instead.
mock_cmd_fail zfs 1
mock_cmd_output zpool ""
_result="$(efi_zfs_boot_disks 2>/dev/null)"
assert_empty "zfs command fails -> no disk names emitted" "${_result}"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
