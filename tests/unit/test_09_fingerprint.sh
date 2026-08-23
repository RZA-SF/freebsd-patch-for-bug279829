#!/bin/sh
# test_09_fingerprint.sh - Tests for efi_is_freebsd_loader
#
# Verifies the FreeBSD loader fingerprinting logic.  The function calls the
# real `strings` binary on actual temp files written for each test case,
# so no mocking of strings is needed.
#
# Primary check: bootprog_info pattern "FreeBSD/<arch> EFI," (since FreeBSD 11).
# Fallback: 2-of-3 heuristic ("FreeBSD", "loader.efi", "boot/lua").

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

mock_init

mock_cmd_output id "0"
mock_cmd_output sysctl "0"

_dummy_loader="$(mktemp)"
printf 'dummy' > "${_dummy_loader}"
EFI_LOADER_SRC="${_dummy_loader}"
export EFI_LOADER_SRC

. "${SRC_DIR}/efi_bootloader_update.sh"

_tmpdir="$(mktemp -d)"

tap_begin 8

# Test 1: all three markers present -> returns 0 (is FreeBSD loader)
_f1="${_tmpdir}/all_three.bin"
printf 'FreeBSD\0loader.efi\0boot/lua\0some_padding_data_here\n' > "${_f1}"
assert_true "all 3 markers present -> returns 0" efi_is_freebsd_loader "${_f1}"

# Test 2: only "FreeBSD" present (1 marker) -> returns 1 (below threshold)
_f2="${_tmpdir}/one_marker.bin"
printf 'FreeBSD\0unrelated_string_one\0unrelated_string_two\n' > "${_f2}"
assert_false "only 1 marker present -> returns 1" efi_is_freebsd_loader "${_f2}"

# Test 3: "FreeBSD" + "loader.efi" (2 markers) -> returns 0 (meets threshold)
_f3="${_tmpdir}/two_markers.bin"
printf 'FreeBSD\0loader.efi\0unrelated_string_here\n' > "${_f3}"
assert_true "2 markers present -> returns 0" efi_is_freebsd_loader "${_f3}"

# Test 4: Windows-style binary content -> returns 1
_f4="${_tmpdir}/windows.bin"
printf 'Windows Boot Manager Microsoft bootmgfw\0EFI\0Microsoft\n' > "${_f4}"
assert_false "Windows binary -> returns 1" efi_is_freebsd_loader "${_f4}"

# Test 5: empty file -> returns 1
_f5="${_tmpdir}/empty.bin"
: > "${_f5}"
assert_false "empty file -> returns 1" efi_is_freebsd_loader "${_f5}"

# Test 6: non-existent file -> returns 1
assert_false "non-existent file -> returns 1" \
    efi_is_freebsd_loader "${_tmpdir}/does_not_exist.bin"

# ── bootprog_info primary check ───────────────────────────────────────────────

# Test 7: bootprog_info string present -> returns 0 via primary check.
# newvers.sh embeds "FreeBSD/<arch> EFI, Revision N.N" in all loaders since
# FreeBSD 11.  This must match even without the heuristic markers.
_f7="${_tmpdir}/bootprog_info.bin"
printf 'FreeBSD/amd64 EFI, Revision 1.1\0some_other_content\n' > "${_f7}"
assert_true "bootprog_info 'FreeBSD/amd64 EFI,' -> returns 0" \
    efi_is_freebsd_loader "${_f7}"

# Test 8: bootprog_info matches arm64 variant -> returns 0.
# Pattern must cover all architectures, not just amd64.
_f8="${_tmpdir}/bootprog_info_arm64.bin"
printf 'FreeBSD/arm64 EFI, Revision 1.1\0unrelated\n' > "${_f8}"
assert_true "bootprog_info 'FreeBSD/arm64 EFI,' -> returns 0" \
    efi_is_freebsd_loader "${_f8}"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
rm -rf "${_tmpdir}"
