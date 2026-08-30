#!/bin/sh
# test_05_esp_discovery.sh - Tests for efi_discover_all_esps
#
# efi_discover_all_esps enumerates all disks via sysctl kern.disks and
# identifies EFI System Partitions on each using gpart show -p --libxo json.
#
# GPT disks: partition type "efi"
# MBR disks: partition type "fat32lba", "fat32", "efi", "!12", or "!ef"
#
# Output format: one "disk part_index scheme" tuple per line.

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

# ── GPT cases ─────────────────────────────────────────────────────────────────

# Test 1: single GPT disk with efi partition -> "nda0 1 GPT"
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_single_efi_bios.json\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "GPT single disk: discovers nda0 1 GPT" "${_result}" "nda0 1 GPT"

# Test 2: GPT disk with labelled partitions -> still discovers efi partition
# With --libxo json, label is a separate named field; type is unaffected.
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nvd0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_gpt_labelled.json\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "GPT labelled partitions: still discovers efi partition" "${_result}" "nvd0 1 GPT"

# Test 3: GPT mirror (two disks, each with ESP) -> both discovered
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "da0 da1" ;; *) echo "0" ;; esac'
mock_cmd gpart 'case "$*" in
    *da0*) printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"466G\"}]}]}\n" ;;
    *da1*) printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"466G\"}]}]}\n" ;;
esac'
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_contains "GPT mirror: da0 ESP discovered" "${_result}" "da0 1 GPT"
assert_contains "GPT mirror: da1 ESP discovered" "${_result}" "da1 1 GPT"

# ── MBR cases ─────────────────────────────────────────────────────────────────

# Test 5: MBR disk with !12 (FAT32 LBA) partition -> "mmcsd0 1 MBR"
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "mmcsd0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_mbr_fat32lba.json\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "MBR !12 disk: discovers mmcsd0 1 MBR" "${_result}" "mmcsd0 1 MBR"

# Test 6: MBR disk with !ef (EFI System) partition -> "ada0 1 MBR"
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "ada0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_mbr_efi_type.json\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "MBR !ef disk: discovers ada0 1 MBR" "${_result}" "ada0 1 MBR"

# Test 7: MBR disk with no EFI-typed partition -> returns empty (no ESP found)
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "ada0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_no_efi.json\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_empty "MBR disk with no ESP partition -> empty result" "${_result}"

# ── Mixed and edge cases ───────────────────────────────────────────────────────

# Test 8: mixed GPT+MBR disks -> both ESPs discovered with correct schemes
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0 mmcsd0" ;; *) echo "0" ;; esac'
mock_cmd gpart 'case "$*" in
    *nda0*)   cat "'"${FIXTURES_DIR}/gpart_show_single_efi_bios.json"'" ;;
    *mmcsd0*) cat "'"${FIXTURES_DIR}/gpart_show_mbr_fat32lba.json"'" ;;
esac'
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_contains "mixed GPT+MBR: GPT ESP found" "${_result}" "nda0 1 GPT"
assert_contains "mixed GPT+MBR: MBR ESP found" "${_result}" "mmcsd0 1 MBR"

# Test 10: gpart show fails on one disk -> skipped; other disk still found
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0 cd0" ;; *) echo "0" ;; esac'
mock_cmd gpart 'case "$*" in
    *nda0*) cat "'"${FIXTURES_DIR}/gpart_show_single_efi_bios.json"'" ;;
    *cd0*)  exit 1 ;;
esac'
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "gpart fails on one disk: other disk still discovered" "${_result}" "nda0 1 GPT"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
