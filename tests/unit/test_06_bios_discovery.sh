#!/bin/sh
# test_06_bios_discovery.sh - Tests for efi_discover_all_bios_parts
#
# efi_discover_all_bios_parts scans all disks via sysctl kern.disks and
# identifies freebsd-boot partitions using gpart show.
# Output format: one "disk part_index" tuple per line.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

FIXTURES_DIR="${TESTS_DIR}/fixtures"

mock_init

mock_cmd_output id "0"

_dummy_loader="$(mktemp)"
printf 'dummy' > "${_dummy_loader}"
EFI_LOADER_SRC="${_dummy_loader}"
export EFI_LOADER_SRC

. "${SRC_DIR}/efi_bootloader_update.sh"

tap_begin 4

# Test 1: disk with freebsd-boot partition -> "nda0 2"
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_single_efi_bios.txt\""
_result="$(efi_discover_all_bios_parts 2>/dev/null)"
assert_eq "disk with freebsd-boot -> nda0 2" "${_result}" "nda0 2"

# Test 2: disk with no freebsd-boot partition -> returns 1 (empty)
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nvd0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_single_efi_only.txt\""
_result="$(efi_discover_all_bios_parts 2>/dev/null)"
assert_empty "disk with no freebsd-boot -> empty result" "${_result}"

# Test 3: mirror — both disks have freebsd-boot -> both discovered
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "da0 da1" ;; *) echo "0" ;; esac'
mock_cmd gpart 'case "$*" in
    *da0*) printf "=>      40  976773168  da0  GPT  (466G)\n        40     409600     1  efi  (200M)\n    409640  976363528     2  freebsd-boot  (512K)\n    410152  976363376     3  freebsd-zfs  (466G)\n" ;;
    *da1*) printf "=>      40  976773168  da1  GPT  (466G)\n        40     409600     1  efi  (200M)\n    409640  976363528     2  freebsd-boot  (512K)\n    410152  976363376     3  freebsd-zfs  (466G)\n" ;;
esac'
_result="$(efi_discover_all_bios_parts 2>/dev/null)"
assert_contains "mirror: da0 freebsd-boot discovered" "${_result}" "da0 2"
assert_contains "mirror: da1 freebsd-boot discovered" "${_result}" "da1 2"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
