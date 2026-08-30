#!/bin/sh
# test_07_partition_discovery.sh - Partition type detection via efi_discover_all_esps
#
# Verifies that GPT and MBR partition types are correctly identified and that
# the output scheme field is set appropriately.  Edge cases include labelled
# GPT partitions (where --libxo json emits label as a separate named field,
# not a column annotation) and disks with only BIOS or no boot partitions.

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

tap_begin 10

# Test 1: GPT disk, efi partition at index 1 -> "nda0 1 GPT"
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_single_efi_bios.json\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "GPT efi at index 1 -> nda0 1 GPT" "${_result}" "nda0 1 GPT"

# Test 2: GPT disk, efi partition only (no freebsd-boot) -> still found
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nvd0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_single_efi_only.json\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "GPT efi-only disk -> nvd0 1 GPT" "${_result}" "nvd0 1 GPT"

# Test 3: GPT with labelled partitions -> label as separate JSON field, type unaffected
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nvd0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_gpt_labelled.json\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "GPT labelled: label is separate JSON field, type still parsed correctly" "${_result}" "nvd0 1 GPT"

# Test 4: MBR disk with !12 (FAT32 LBA) -> "mmcsd0 1 MBR"
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "mmcsd0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_mbr_fat32lba.json\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "MBR !12 partition -> mmcsd0 1 MBR" "${_result}" "mmcsd0 1 MBR"

# Test 5: MBR disk with !ef (EFI System type) -> "ada0 1 MBR"
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "ada0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_mbr_efi_type.json\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "MBR !ef partition -> ada0 1 MBR" "${_result}" "ada0 1 MBR"

# Test 6: MBR disk with no EFI-typed partition -> empty (freebsd type not an ESP)
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "ada0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_no_efi.json\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_empty "MBR disk without !12/!ef partition -> empty" "${_result}"

# Test 7: GPT disk with only freebsd-boot (no efi partition) -> empty
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart 'printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"freebsd-boot\",\"label\":\"\",\"rawtype\":\"83bd6b9d-7f41-11dc-be0b-001560b84f0f\",\"size\":\"512K\"},{\"index\":2,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"466G\"}]}]}\n"'
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

# Test 10: FreeBSD 13.x text-mode fallback (gpart --libxo unsupported)
# When "gpart show -p --libxo json" exits non-zero, _efi_gpart_show_norm falls
# back to "gpart show -p" text parsing.  Mirrors the EC2 Graviton 13.5 layout.
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart 'case "$*" in
    *--libxo*) exit 1 ;;
    *show*)    printf "=>       3  20971509  nda0  GPT  (10G)\n         3     66584  nda0p1  efi  (33M)\n     66587  20904925  nda0p2  freebsd-ufs  (10G)\n" ;;
esac'
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "FreeBSD 13.x text fallback: GPT efi partition discovered" "${_result}" "nda0 1 GPT"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
