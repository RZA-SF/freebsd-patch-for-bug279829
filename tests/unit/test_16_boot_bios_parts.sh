#!/bin/sh
# test_16_boot_bios_parts.sh - Tests for efi_boot_bios_parts
#
# efi_boot_bios_parts identifies freebsd-boot partitions scoped to the current
# system's root filesystem disks (via efi_root_disks).
#
# 13 assertions

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

tap_begin 13

# ── Test 1: ZFS single disk nda0: freebsd-boot at index 2 -> "nda0 2" ────────
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
mock_cmd gpart '
case "$*" in
    *show*nda0*)
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-boot\",\"label\":\"\",\"rawtype\":\"83bd6b9d-7f41-11dc-be0b-001560b84f0f\",\"size\":\"512K\"},{\"index\":4,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"462G\"}]}]}\n"
        ;;
    *) exit 1 ;;
esac'
_result="$(efi_boot_bios_parts 2>/dev/null)"
assert_eq "ZFS single disk nda0: freebsd-boot -> nda0 2" "${_result}" "nda0 2"

# ── Test 2: ZFS mirror (nda0 + nda1): both have freebsd-boot ─────────────────
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME        STATE     READ WRITE CKSUM
	zroot       ONLINE       0     0     0
	  mirror-0  ONLINE       0     0     0
	    nda0p4  ONLINE       0     0     0
	    nda1p4  ONLINE       0     0     0

errors: No known data errors
ZPS'
mock_cmd gpart '
case "$*" in
    *show*nda0*)
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-boot\",\"label\":\"\",\"rawtype\":\"83bd6b9d-7f41-11dc-be0b-001560b84f0f\",\"size\":\"512K\"},{\"index\":4,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"462G\"}]}]}\n"
        ;;
    *show*nda1*)
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-boot\",\"label\":\"\",\"rawtype\":\"83bd6b9d-7f41-11dc-be0b-001560b84f0f\",\"size\":\"512K\"},{\"index\":4,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"462G\"}]}]}\n"
        ;;
    *) exit 1 ;;
esac'
_result="$(efi_boot_bios_parts 2>/dev/null)"
assert_contains "ZFS mirror: nda0 2 found" "${_result}" "nda0 2"
assert_contains "ZFS mirror: nda1 2 found" "${_result}" "nda1 2"

# ── Test 3: UFS root on ada0: freebsd-boot found ─────────────────────────────
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"/dev/ada0p3\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd gpart '
case "$*" in
    *show*ada0*)
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-boot\",\"label\":\"\",\"rawtype\":\"83bd6b9d-7f41-11dc-be0b-001560b84f0f\",\"size\":\"512K\"},{\"index\":3,\"type\":\"freebsd-ufs\",\"label\":\"\",\"rawtype\":\"516e7cb6-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"465G\"}]}]}\n"
        ;;
    *) exit 1 ;;
esac'
_result="$(efi_boot_bios_parts 2>/dev/null)"
assert_eq "UFS root ada0: freebsd-boot -> ada0 2" "${_result}" "ada0 2"

# ── Test 4: root_disks fails (zpool status fails) -> returns 1 ───────────────
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd_fail zpool 1
_rc=0
efi_boot_bios_parts 2>/dev/null || _rc=$?
assert_ne "root_disks fails: returns non-zero" "${_rc}" "0"

# ── Test 5: root_disks succeeds but no freebsd-boot on root disk -> returns 1 ─
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
mock_cmd gpart '
case "$*" in
    *show*nda0*)
        # Only efi partition, no freebsd-boot
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"465G\"}]}]}\n"
        ;;
    *) exit 1 ;;
esac'
_rc=0
efi_boot_bios_parts 2>/dev/null || _rc=$?
assert_ne "No freebsd-boot on root disk: returns non-zero" "${_rc}" "0"

# ── Test 6: Disk has efi but no freebsd-boot -> returns 1 (empty output) ─────
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
mock_cmd gpart '
case "$*" in
    *show*nda0*)
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"465G\"}]}]}\n"
        ;;
    *) exit 1 ;;
esac'
_result="$(efi_boot_bios_parts 2>/dev/null)"
assert_empty "Efi-only disk: efi_boot_bios_parts returns empty" "${_result}"

# ── Test 7: Multiple freebsd-boot partitions on same disk ────────────────────
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
mock_cmd gpart '
case "$*" in
    *show*nda0*)
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-boot\",\"label\":\"\",\"rawtype\":\"83bd6b9d-7f41-11dc-be0b-001560b84f0f\",\"size\":\"512K\"},{\"index\":3,\"type\":\"freebsd-boot\",\"label\":\"\",\"rawtype\":\"83bd6b9d-7f41-11dc-be0b-001560b84f0f\",\"size\":\"512K\"},{\"index\":4,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"462G\"}]}]}\n"
        ;;
    *) exit 1 ;;
esac'
_result="$(efi_boot_bios_parts 2>/dev/null)"
assert_contains "Multiple freebsd-boot: nda0 2 found" "${_result}" "nda0 2"
assert_contains "Multiple freebsd-boot: nda0 3 found" "${_result}" "nda0 3"

# ── Test 8: gpart show fails for root disk -> skip, continue ─────────────────
# When the only root disk fails gpart, returns 1 (empty)
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
mock_cmd_fail gpart 1
_rc=0
efi_boot_bios_parts 2>/dev/null || _rc=$?
assert_ne "gpart show fails for root disk: returns non-zero" "${_rc}" "0"

# ── Test 9: ZFS RAIDz (da0, da1, da2): all have freebsd-boot ─────────────────
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"data/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool '
cat <<ZPS
  pool: data
 state: ONLINE
config:

	NAME        STATE     READ WRITE CKSUM
	data        ONLINE       0     0     0
	  raidz1-0  ONLINE       0     0     0
	    da0p3   ONLINE       0     0     0
	    da1p3   ONLINE       0     0     0
	    da2p3   ONLINE       0     0     0

errors: No known data errors
ZPS'
mock_cmd gpart '
case "$*" in
    *show*da0*)
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-boot\",\"label\":\"\",\"rawtype\":\"83bd6b9d-7f41-11dc-be0b-001560b84f0f\",\"size\":\"512K\"},{\"index\":3,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"462G\"}]}]}\n"
        ;;
    *show*da1*)
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-boot\",\"label\":\"\",\"rawtype\":\"83bd6b9d-7f41-11dc-be0b-001560b84f0f\",\"size\":\"512K\"},{\"index\":3,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"462G\"}]}]}\n"
        ;;
    *show*da2*)
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-boot\",\"label\":\"\",\"rawtype\":\"83bd6b9d-7f41-11dc-be0b-001560b84f0f\",\"size\":\"512K\"},{\"index\":3,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"462G\"}]}]}\n"
        ;;
    *) exit 1 ;;
esac'
_result="$(efi_boot_bios_parts 2>/dev/null)"
assert_contains "RAIDz 3 disks: da0 2 found" "${_result}" "da0 2"
assert_contains "RAIDz 3 disks: da1 2 found" "${_result}" "da1 2"
assert_contains "RAIDz 3 disks: da2 2 found" "${_result}" "da2 2"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
