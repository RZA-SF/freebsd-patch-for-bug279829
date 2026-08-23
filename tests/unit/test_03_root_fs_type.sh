#!/bin/sh
# test_03_root_fs_type.sh - Tests for efi_root_fs_type
#
# efi_root_fs_type uses mount --libxo json (FreeBSD 10.1+) to identify the
# root filesystem type.  Tests verify correct extraction from the JSON output
# for ZFS and UFS roots, with root at various positions in the mount list.

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

tap_begin 5

# Test 1: ZFS root — standard JSON output
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_libxo_zfs.json\""
assert_eq "libxo json: zfs root -> returns zfs" \
    "$(efi_root_fs_type)" "zfs"

# Test 2: UFS root — standard JSON output
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_libxo_ufs.json\""
assert_eq "libxo json: ufs root -> returns ufs" \
    "$(efi_root_fs_type)" "ufs"

# Test 3: root is not the first mount entry
mock_cmd mount 'printf '"'"'{"mount":{"mounted":[{"special":"devfs","node":"/dev","fstype":"devfs","opts":["rw"]},{"special":"zroot/ROOT/default","node":"/","fstype":"zfs","opts":["local","noatime"]}]}}'"'"''
assert_eq "libxo json: / not first entry -> still finds correct type" \
    "$(efi_root_fs_type)" "zfs"

# Test 4: ESP is also mounted — root type still correct
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_libxo_esp_mounted.json\""
assert_eq "libxo json: ESP mounted alongside / -> root type still zfs" \
    "$(efi_root_fs_type)" "zfs"

# Test 5: mount --libxo json fails -> returns empty string
mock_cmd_fail mount 1
_result="$(efi_root_fs_type 2>/dev/null)"
assert_empty "mount --libxo json fails -> returns empty" "${_result}"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
