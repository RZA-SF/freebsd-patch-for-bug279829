#!/bin/sh
# test_07_partition_discovery.sh - Partition type detection via efi_discover_all_esps
#
# Verifies that GPT and MBR partition types are correctly identified and that
# the output scheme field is set appropriately.  Edge cases include labelled
# GPT partitions (where gpart show inserts a [label] field) and disks with
# only BIOS or no boot partitions.

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

tap_begin 9

# Test 1: GPT disk, efi partition at index 1 -> "nda0 1 GPT"
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_single_efi_bios.txt\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "GPT efi at index 1 -> nda0 1 GPT" "${_result}" "nda0 1 GPT"

# Test 2: GPT disk, efi partition only (no freebsd-boot) -> still found
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nvd0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_single_efi_only.txt\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "GPT efi-only disk -> nvd0 1 GPT" "${_result}" "nvd0 1 GPT"

# Test 3: GPT with labelled partitions -> [label] annotation does not break awk
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nvd0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_gpt_labelled.txt\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "GPT labelled: [efi0] label does not break field parsing" "${_result}" "nvd0 1 GPT"

# Test 4: MBR disk with !12 (FAT32 LBA) -> "mmcsd0 1 MBR"
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "mmcsd0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_mbr_fat32lba.txt\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "MBR !12 partition -> mmcsd0 1 MBR" "${_result}" "mmcsd0 1 MBR"

# Test 5: MBR disk with !ef (EFI System type) -> "ada0 1 MBR"
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "ada0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_mbr_efi_type.txt\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "MBR !ef partition -> ada0 1 MBR" "${_result}" "ada0 1 MBR"

# Test 6: MBR disk with no EFI-typed partition -> empty (freebsd type not an ESP)
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "ada0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_no_efi.txt\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_empty "MBR disk without !12/!ef partition -> empty" "${_result}"

# Test 7: GPT disk with only freebsd-boot (no efi partition) -> empty
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart 'printf "=>      40  976773168  nda0  GPT  (466G)\n    409640  976363528     1  freebsd-boot  (512K)\n    410152  976363376     2  freebsd-zfs  (466G)\n"'
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_empty "GPT freebsd-boot only (no efi) -> empty" "${_result}"

# Test 8: gpart show fails -> disk skipped, function returns 1
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "ada0" ;; *) echo "0" ;; esac'
mock_cmd_fail gpart 1
_rc=0
efi_discover_all_esps 2>/dev/null || _rc=$?
assert_ne "gpart fails on all disks -> returns non-zero" "${_rc}" "0"

# Test 9: kern.disks fails -> function returns non-zero
mock_cmd sysctl 'case "$*" in *kern.disks*) exit 1 ;; *) echo "0" ;; esac'
_rc=0
efi_discover_all_esps 2>/dev/null || _rc=$?
assert_ne "kern.disks fails -> returns non-zero" "${_rc}" "0"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
