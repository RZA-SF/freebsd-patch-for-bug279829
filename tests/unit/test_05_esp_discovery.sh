#!/bin/sh
# test_05_esp_discovery.sh - Tests for efi_discover_all_esps
#
# efi_discover_all_esps enumerates all disks via sysctl kern.disks and
# identifies EFI System Partitions on each using gpart show.
#
# GPT disks: partition type "efi"
# MBR disks: partition type "!12" (FAT32 LBA) or "!ef" (EFI System)
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
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_single_efi_bios.txt\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "GPT single disk: discovers nda0 1 GPT" "${_result}" "nda0 1 GPT"

# Test 2: GPT disk with labelled partitions -> still discovers efi partition
# Verifies awk handles [label] annotation after type field correctly
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nvd0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_gpt_labelled.txt\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "GPT labelled partitions: still discovers efi partition" "${_result}" "nvd0 1 GPT"

# Test 3: GPT mirror (two disks, each with ESP) -> both discovered
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "da0 da1" ;; *) echo "0" ;; esac'
mock_cmd gpart 'case "$*" in
    *da0*) printf "=>      40  976773168  da0  GPT  (466G)\n        40     409600     1  efi  (200M)\n    409640  976363528     2  freebsd-zfs  (466G)\n" ;;
    *da1*) printf "=>      40  976773168  da1  GPT  (466G)\n        40     409600     1  efi  (200M)\n    409640  976363528     2  freebsd-zfs  (466G)\n" ;;
esac'
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_contains "GPT mirror: da0 ESP discovered" "${_result}" "da0 1 GPT"
assert_contains "GPT mirror: da1 ESP discovered" "${_result}" "da1 1 GPT"

# ── MBR cases ─────────────────────────────────────────────────────────────────

# Test 5: MBR disk with !12 (FAT32 LBA) partition -> "mmcsd0 1 MBR"
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "mmcsd0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_mbr_fat32lba.txt\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "MBR !12 disk: discovers mmcsd0 1 MBR" "${_result}" "mmcsd0 1 MBR"

# Test 6: MBR disk with !ef (EFI System) partition -> "ada0 1 MBR"
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "ada0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_mbr_efi_type.txt\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "MBR !ef disk: discovers ada0 1 MBR" "${_result}" "ada0 1 MBR"

# Test 7: MBR disk with no EFI-typed partition -> returns empty (no ESP found)
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "ada0" ;; *) echo "0" ;; esac'
mock_cmd gpart "cat \"${FIXTURES_DIR}/gpart_show_no_efi.txt\""
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_empty "MBR disk with no ESP partition -> empty result" "${_result}"

# ── Mixed and edge cases ───────────────────────────────────────────────────────

# Test 8: mixed GPT+MBR disks -> both ESPs discovered with correct schemes
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0 mmcsd0" ;; *) echo "0" ;; esac'
mock_cmd gpart 'case "$*" in
    *nda0*)   cat "'"${FIXTURES_DIR}/gpart_show_single_efi_bios.txt"'" ;;
    *mmcsd0*) cat "'"${FIXTURES_DIR}/gpart_show_mbr_fat32lba.txt"'" ;;
esac'
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_contains "mixed GPT+MBR: GPT ESP found" "${_result}" "nda0 1 GPT"
assert_contains "mixed GPT+MBR: MBR ESP found" "${_result}" "mmcsd0 1 MBR"

# Test 10: gpart show fails on one disk -> skipped; other disk still found
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0 cd0" ;; *) echo "0" ;; esac'
mock_cmd gpart 'case "$*" in
    *nda0*) cat "'"${FIXTURES_DIR}/gpart_show_single_efi_bios.txt"'" ;;
    *cd0*)  exit 1 ;;
esac'
_result="$(efi_discover_all_esps 2>/dev/null)"
assert_eq "gpart fails on one disk: other disk still discovered" "${_result}" "nda0 1 GPT"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
