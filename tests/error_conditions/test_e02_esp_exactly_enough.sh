#!/bin/sh
# test_e02_esp_exactly_enough.sh
#
# Edge case: ESP has exactly the minimum required free space.
# Formula: required = (src_size * 2) + 65536
# For a 1024-byte loader: required = 2048 + 65536 = 67584 bytes = 66 KB (ceil).
# df must return at least ceil(67584 / 1024) = 67 KB.
# efi_check_space must return 0.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 3

setup_test_dir
mock_init

# --- Create a loader of exactly 1024 bytes ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
dd if=/dev/zero bs=1 count=1024 2>/dev/null | tr '\0' 'A' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

FAKE_MP="${TEST_DIR}/fake_mp"
mkdir -p "${FAKE_MP}/EFI/FreeBSD"
printf 'placeholder' > "${FAKE_MP}/EFI/FreeBSD/loader.efi"

# required = 1024 * 2 + 65536 = 67584 bytes = exactly 66 KB (integer division:
# 67584 / 1024 = 66).  Provide exactly 66 KB.
_avail_kb=66

# stat: return the real file size
mock_cmd stat "echo '1024'"

# df: return exactly _avail_kb available
mock_cmd df "printf 'Filesystem 1K-blocks Used Avail\n/dev/nda0p1 100000 99934 ${_avail_kb}\n'"

mock_cmd_output id "0"
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "UEFI" ;;
    *) echo "0" ;;
esac'
mock_cmd_output uname "amd64"

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# Test efi_check_space at exact minimum
_rc=0
efi_check_space "${FAKE_MP}" || _rc=$?

assert_eq \
    "efi_check_space returns 0 at exact minimum free space (66 KB for 1024-byte loader)" \
    "${_rc}" "0"

# One KB less than required should fail
_one_less_kb=$(( _avail_kb - 1 ))
mock_cmd df "printf 'Filesystem 1K-blocks Used Avail\n/dev/nda0p1 100000 99935 ${_one_less_kb}\n'"

_rc2=0
efi_check_space "${FAKE_MP}" || _rc2=$?

assert_eq \
    "efi_check_space returns 1 when 1 KB below minimum (65 KB)" \
    "${_rc2}" "1"

# One KB more than required should also succeed
_one_more_kb=$(( _avail_kb + 1 ))
mock_cmd df "printf 'Filesystem 1K-blocks Used Avail\n/dev/nda0p1 100000 99933 ${_one_more_kb}\n'"

_rc3=0
efi_check_space "${FAKE_MP}" || _rc3=$?

assert_eq \
    "efi_check_space returns 0 when 1 KB above minimum (67 KB)" \
    "${_rc3}" "0"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
