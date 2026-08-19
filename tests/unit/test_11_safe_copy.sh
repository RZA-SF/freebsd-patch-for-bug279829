#!/bin/sh
# test_11_safe_copy.sh - Tests for efi_safe_copy
#
# Verifies the atomic copy-via-temp-rename behaviour, error handling, and
# dry-run mode.  Uses real temp directories and files — no mocking needed
# for the happy path.

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

tap_begin 10

# Test 1: normal copy -> dst matches src content
_src="${_tmpdir}/src.efi"
_dst="${_tmpdir}/dst.efi"
printf 'loader content v2\n' > "${_src}"
EFI_DRY_RUN=0
efi_safe_copy "${_src}" "${_dst}" 2>/dev/null
assert_true "normal copy -> dst exists" test -f "${_dst}"

# Test 2: normal copy -> dst content matches src
_actual="$(cat "${_dst}")"
_expected="$(cat "${_src}")"
assert_eq "normal copy -> dst content matches src" "${_actual}" "${_expected}"

# Test 3: temp file (.new) must not remain after successful copy
assert_false "temp file .new does not remain after copy" test -f "${_dst}.new"

# Test 4: dst directory is read-only -> returns 1
_rodir="${_tmpdir}/ro"
mkdir -p "${_rodir}"
_ro_dst="${_rodir}/loader.efi"
# Make the directory read-only so cp cannot create the temp file there.
chmod 555 "${_rodir}"
_rc=0
efi_safe_copy "${_src}" "${_ro_dst}" 2>/dev/null || _rc=$?
assert_ne "read-only dst dir -> returns non-zero" "${_rc}" "0"
chmod 755 "${_rodir}"

# Test 5: src does not exist -> returns 1
_rc=0
efi_safe_copy "${_tmpdir}/nonexistent.efi" "${_dst}" 2>/dev/null || _rc=$?
assert_ne "src does not exist -> returns non-zero" "${_rc}" "0"

# Test 6: dry-run mode -> returns 0 (no copy actually performed)
_dr_src="${_tmpdir}/dry_src.efi"
_dr_dst="${_tmpdir}/dry_dst.efi"
printf 'dry run source\n' > "${_dr_src}"
EFI_DRY_RUN=1
_rc=0
efi_safe_copy "${_dr_src}" "${_dr_dst}" 2>/dev/null || _rc=$?
assert_eq "dry-run -> returns 0" "${_rc}" "0"

# Test 7: dry-run mode -> dst is NOT created
EFI_DRY_RUN=1
assert_false "dry-run -> dst file is not created" test -f "${_dr_dst}"

# Restore dry-run to off.
EFI_DRY_RUN=0

# Test 8: identical src and dst -> copy is skipped, returns 0
# Probe: mock cp to fail.  With the idempotency fix, cmp -s detects
# identical files and returns 0 without calling cp.
_src8="${_tmpdir}/src8.efi"
_dst8="${_tmpdir}/dst8.efi"
printf 'identical content\n' > "${_src8}"
printf 'identical content\n' > "${_dst8}"
mock_cmd_fail cp
hash -r 2>/dev/null || true
EFI_DRY_RUN=0
_rc=0
efi_safe_copy "${_src8}" "${_dst8}" 2>/dev/null || _rc=$?
assert_eq "identical src/dst -> copy skipped, returns 0" "${_rc}" "0"
rm -f "${MOCK_BIN}/cp"
hash -r 2>/dev/null || true

# Test 9: identical src and dst -> _efi_copy_wrote is 0 (not counted as a write)
assert_eq "identical src/dst -> _efi_copy_wrote=0" "${_efi_copy_wrote}" "0"

# Test 10: different src and dst -> _efi_copy_wrote is 1 (counted as a write)
_src10="${_tmpdir}/src10.efi"
_dst10="${_tmpdir}/dst10.efi"
printf 'version A\n' > "${_src10}"
printf 'version B\n' > "${_dst10}"
EFI_DRY_RUN=0
efi_safe_copy "${_src10}" "${_dst10}" 2>/dev/null
assert_eq "different src/dst -> _efi_copy_wrote=1" "${_efi_copy_wrote}" "1"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
rm -rf "${_tmpdir}"
