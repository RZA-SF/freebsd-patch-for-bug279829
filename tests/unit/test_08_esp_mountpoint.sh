#!/bin/sh
# test_08_esp_mountpoint.sh - Tests for efi_esp_mountpoint and efi_mount_esp
#
# efi_esp_mountpoint uses mount --libxo json to check whether a device is
# already mounted.  mount --libxo json uses "special" for the source device.
#
# efi_mount_esp accepts an optional third argument (scheme: GPT or MBR) and
# constructs the device path accordingly:
#   GPT (default): /dev/<disk>p<index>
#   MBR:           /dev/<disk>s<index>

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

tap_begin 9

# Test 1: device not in mount output -> returns empty
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_no_esp.txt\""
_result="$(efi_esp_mountpoint /dev/nda0p1 2>/dev/null)"
assert_empty "device not mounted -> returns empty" "${_result}"

# Test 2: device mounted at /boot/efi -> returns /boot/efi
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_esp_at_boot_efi.txt\""
_result="$(efi_esp_mountpoint /dev/nda0p1 2>/dev/null)"
assert_eq "device mounted -> returns /boot/efi" "${_result}" "/boot/efi"

# Test 3: device specified with /dev/ prefix -> returns mountpoint
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_esp_at_boot_efi.txt\""
_result="$(efi_esp_mountpoint /dev/nda0p1 2>/dev/null)"
assert_eq "with /dev/ prefix -> returns /boot/efi" "${_result}" "/boot/efi"

# Test 4: device specified without /dev/ prefix -> same result
# efi_esp_mountpoint prepends /dev/ when the prefix is absent.
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_esp_at_boot_efi.txt\""
_result="$(efi_esp_mountpoint nda0p1 2>/dev/null)"
assert_eq "without /dev/ prefix -> returns /boot/efi" "${_result}" "/boot/efi"

# Test 5: GPT scheme (default) -> mount_msdosfs receives pN device path
# Also verifies separate -o flags (regression: "-o noexec,nosuid" was rejected
# by FreeBSD mount_msdosfs with "mount option <noexec,nosuid> is unknown").
: > "${MOCK_CALL_LOG}"
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_no_esp.txt\""
mock_cmd_output mount_msdosfs ""
hash -r 2>/dev/null || true
EFI_DRY_RUN=0
_efi_tmp_mounts=""
efi_mount_esp nda0 1 2>/dev/null
_mnt_args="$(mock_last_args mount_msdosfs)"
assert_contains \
    "GPT scheme: mount_msdosfs receives pN device path" \
    "${_mnt_args}" "nda0p1"
assert_contains \
    "mount_msdosfs: -o noexec and -o nosuid as separate flags (FreeBSD compat)" \
    "${_mnt_args}" "-o noexec -o nosuid"
efi_cleanup_mounts 2>/dev/null

# Test 7: MBR scheme -> mount_msdosfs receives sN device path
: > "${MOCK_CALL_LOG}"
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_no_esp.txt\""
mock_cmd_output mount_msdosfs ""
hash -r 2>/dev/null || true
EFI_DRY_RUN=0
_efi_tmp_mounts=""
efi_mount_esp mmcsd0 1 MBR 2>/dev/null
_mnt_args="$(mock_last_args mount_msdosfs)"
assert_contains \
    "MBR scheme: mount_msdosfs receives sN device path (not pN)" \
    "${_mnt_args}" "mmcsd0s1"
efi_cleanup_mounts 2>/dev/null

# FreeBSD 14+ "special" field regression tests
# mount --libxo json uses "special" for the source device (never "from").

# Test 8: FreeBSD 14+ "special" field: device not mounted -> returns empty
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_no_esp_freebsd14.txt\""
_result="$(efi_esp_mountpoint /dev/nda0p1 2>/dev/null)"
assert_empty "FreeBSD14+ 'special': device not mounted -> returns empty" "${_result}"

# Test 9: FreeBSD 14+ "special" field: device mounted -> returns /boot/efi
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_esp_at_boot_efi_freebsd14.txt\""
_result="$(efi_esp_mountpoint /dev/nda0p1 2>/dev/null)"
assert_eq "FreeBSD14+ 'special': device mounted -> returns /boot/efi" "${_result}" "/boot/efi"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
