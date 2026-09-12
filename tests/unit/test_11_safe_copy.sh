#!/bin/sh
# test_11_safe_copy.sh - Tests for efi_safe_copy
#
# Verifies the atomic copy-via-temp-rename behavior, error handling, and
# dry-run mode.  Uses real temp directories and files — no mocking needed
# for the happy path.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

mock_init

mock_cmd_output id "0"
mock_cmd_output sysctl "0"
# Default: uefisign confirms not signed (exit 1 + "file not signed" output).
# efi_is_signed parses output to distinguish "not signed" from error conditions.
# Overridden per-test for signed (exit 0) and absent (exit 127) cases.
mock_cmd_output uefisign "uefisign: file not signed" 1

_dummy_loader="$(mktemp)"
printf 'dummy' > "${_dummy_loader}"
EFI_LOADER_SRC="${_dummy_loader}"
export EFI_LOADER_SRC

. "${SRC_DIR}/efi_bootloader_update.sh"

_tmpdir="$(mktemp -d)"

tap_begin 21

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
# FreeBSD (the target platform) runs this test as root, and root bypasses
# chmod-based permission checks.  Use chflags schg (system-immutable) when
# available — even root cannot create files in a schg directory without first
# clearing the flag.  Fall back to chmod 555 on systems without chflags.
_rodir="${_tmpdir}/ro"
mkdir -p "${_rodir}"
_ro_dst="${_rodir}/loader.efi"
if command -v chflags >/dev/null 2>&1; then
    chflags schg "${_rodir}"
    _rc=0
    efi_safe_copy "${_src}" "${_ro_dst}" 2>/dev/null || _rc=$?
    assert_ne "read-only dst dir -> returns non-zero" "${_rc}" "0"
    chflags noschg "${_rodir}"
else
    chmod 555 "${_rodir}"
    _rc=0
    efi_safe_copy "${_src}" "${_ro_dst}" 2>/dev/null || _rc=$?
    assert_ne "read-only dst dir -> returns non-zero" "${_rc}" "0"
    chmod 755 "${_rodir}"
fi

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

# Test 11: signed dst -> returns 0 (skip without error)
# Simulate a signed destination by mocking uefisign -V to succeed (exit 0).
_src11="${_tmpdir}/src11.efi"
_dst11="${_tmpdir}/dst11.efi"
printf 'new loader content\n' > "${_src11}"
printf 'signed loader content\n' > "${_dst11}"
mock_cmd_output uefisign "" 0
EFI_DRY_RUN=0
_rc=0
efi_safe_copy "${_src11}" "${_dst11}" 2>/dev/null || _rc=$?
assert_eq "signed dst -> returns 0 (no error)" "${_rc}" "0"

# Test 12: signed dst -> _efi_copy_wrote is 0 (no write)
assert_eq "signed dst -> _efi_copy_wrote=0" "${_efi_copy_wrote}" "0"

# Test 13: signed dst -> dst content is unchanged (original binary preserved)
_actual11="$(cat "${_dst11}")"
assert_eq "signed dst -> dst content unchanged" "${_actual11}" "signed loader content"

# Restore uefisign to default (not signed).
mock_cmd_output uefisign "uefisign: file not signed" 1

# Test 14: no existing dst (new file install) -> uefisign not called, copy proceeds
# efi_is_signed returns 1 immediately when the file is absent, so the signed
# guard is bypassed entirely.  Probe: mock uefisign to exit 0 (signed) so any
# call on the destination would block the copy.
_src14="${_tmpdir}/src14.efi"
_dst14="${_tmpdir}/dst14.efi"
printf 'fresh install content\n' > "${_src14}"
mock_cmd_output uefisign "" 0   # would block copy if called on a non-existent dst
EFI_DRY_RUN=0
efi_safe_copy "${_src14}" "${_dst14}" 2>/dev/null
assert_eq "new file install -> copy proceeds despite uefisign mock (_efi_copy_wrote=1)" \
    "${_efi_copy_wrote}" "1"

# Switch uefisign mock to simulate absent (exit 127 = shell "command not found").
mock_cmd_output uefisign "" 127

# Test 15: uefisign absent (exit 127) + existing dst -> returns 0 (fail-safe: skip)
_src15="${_tmpdir}/src15.efi"
_dst15="${_tmpdir}/dst15.efi"
printf 'new content\n' > "${_src15}"
printf 'existing content\n' > "${_dst15}"
EFI_DRY_RUN=0
_rc=0
efi_safe_copy "${_src15}" "${_dst15}" 2>/dev/null || _rc=$?
assert_eq "uefisign absent -> returns 0 (skip, fail-safe)" "${_rc}" "0"

# Test 16: uefisign absent + existing dst -> _efi_copy_wrote=0 (no write)
assert_eq "uefisign absent -> _efi_copy_wrote=0" "${_efi_copy_wrote}" "0"

# Test 17: uefisign absent + existing dst -> dst content unchanged
_actual15="$(cat "${_dst15}")"
assert_eq "uefisign absent -> dst content unchanged" "${_actual15}" "existing content"

# Switch uefisign mock to simulate an error condition: exits 1 but with output
# that is NOT "file not signed" (e.g. "MZ header not found" from a non-PE file).
# efi_is_signed treats this as indeterminate (return 2) — fail-safe.
mock_cmd_output uefisign "uefisign: MZ header not found" 1

# Test 18: uefisign error output (not "file not signed") + existing dst -> returns 0 (fail-safe: skip)
_src18="${_tmpdir}/src18.efi"
_dst18="${_tmpdir}/dst18.efi"
printf 'new content\n' > "${_src18}"
printf 'existing content\n' > "${_dst18}"
EFI_DRY_RUN=0
_rc=0
efi_safe_copy "${_src18}" "${_dst18}" 2>/dev/null || _rc=$?
assert_eq "uefisign error output -> returns 0 (skip, fail-safe)" "${_rc}" "0"

# Test 19: uefisign error output + existing dst -> _efi_copy_wrote=0 (no write)
assert_eq "uefisign error output -> _efi_copy_wrote=0" "${_efi_copy_wrote}" "0"

# Test 20: uefisign error output + existing dst -> dst content unchanged
_actual18="$(cat "${_dst18}")"
assert_eq "uefisign error output -> dst content unchanged" "${_actual18}" "existing content"

# Test 21: uefisign error output -> diagnostic warning emitted to stderr
# Confirms that unexpected output is not silently swallowed; admins are
# notified if the "file not signed" pattern no longer matches.
_src21="${_tmpdir}/src21.efi"
_dst21="${_tmpdir}/dst21.efi"
printf 'new content\n' > "${_src21}"
printf 'existing content\n' > "${_dst21}"
EFI_DRY_RUN=0
_warn21=$(efi_safe_copy "${_src21}" "${_dst21}" 2>&1)
assert_contains "uefisign error output -> diagnostic warning emitted" \
    "${_warn21}" "unexpected uefisign output"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
rm -rf "${_tmpdir}"
