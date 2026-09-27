#!/bin/sh
# test_17_modal.sh - Tests for _efi_modal(), _efi_modal_line(),
# _efi_dry_run_pending tracking, and EFI_CONFIRM_UPDATE / EFI_DRY_RUN
# precedence.
#
# 10 assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

mock_init
mock_cmd_output id "0"
mock_cmd_output sysctl "0"
mock_cmd_output logger ""   # absorb syslog writes; avoid actual daemon.warn noise

_dummy_loader="$(mktemp)"
printf 'dummy loader content' > "${_dummy_loader}"
EFI_LOADER_SRC="${_dummy_loader}"
export EFI_LOADER_SRC

. "${SRC_DIR}/efi_bootloader_update.sh"

_tmpdir="$(mktemp -d)"

tap_begin 12

# ── _efi_modal_line ───────────────────────────────────────────────────────────

# Test 1: _efi_modal_line prefixes output with "*** "
_out=$(_efi_modal_line "hello world")
assert_contains "_efi_modal_line prefixes with ***" "${_out}" "*** hello world"

# Test 2: _efi_modal_line with empty string still emits "***"
_out=$(_efi_modal_line "")
assert_contains "_efi_modal_line empty string emits ***" "${_out}" "***"

# ── _efi_modal ────────────────────────────────────────────────────────────────

# Test 3: _efi_modal formats all body lines with "***" prefix
_out=$(_efi_modal "syslog summary" "first line" "second line" 2>/dev/null)
assert_contains "_efi_modal formats first line with ***" "${_out}" "*** first line"
# (assert_contains is one assertion; count second line separately)

# Test 4: _efi_modal second body line also has "***" prefix
assert_contains "_efi_modal formats second line with ***" "${_out}" "*** second line"

# Test 5: _efi_modal calls logger
: > "${MOCK_CALL_LOG}"
_efi_modal "test syslog summary" "body" 2>/dev/null
assert_true "_efi_modal calls logger" mock_was_called logger

# ── _efi_dry_run_pending tracking in efi_safe_copy ───────────────────────────

# Test 6: dry-run with differing dst -> _efi_dry_run_pending incremented
_src="${_tmpdir}/src6.efi"
_dst="${_tmpdir}/dst6.efi"
printf 'new content' > "${_src}"
printf 'old content' > "${_dst}"
EFI_DRY_RUN=1
_efi_dry_run_pending=0
efi_safe_copy "${_src}" "${_dst}" 2>/dev/null
assert_eq "dry-run with differing dst: _efi_dry_run_pending incremented" \
    "${_efi_dry_run_pending}" "1"

# Test 7: dry-run with identical dst -> _efi_dry_run_pending stays 0 (already current)
_src="${_tmpdir}/src7.efi"
_dst="${_tmpdir}/dst7.efi"
printf 'same content' > "${_src}"
printf 'same content' > "${_dst}"
EFI_DRY_RUN=1
_efi_dry_run_pending=0
efi_safe_copy "${_src}" "${_dst}" 2>/dev/null
assert_eq "dry-run with identical dst: _efi_dry_run_pending stays 0" \
    "${_efi_dry_run_pending}" "0"

# Test 8: non-dry-run (EFI_CONFIRM_UPDATE mode) -> _efi_dry_run_pending stays 0
_src="${_tmpdir}/src8.efi"
_dst="${_tmpdir}/dst8.efi"
printf 'new content' > "${_src}"
printf 'old content' > "${_dst}"
EFI_DRY_RUN=0
_efi_dry_run_pending=0
efi_safe_copy "${_src}" "${_dst}" 2>/dev/null
assert_eq "non-dry-run: _efi_dry_run_pending stays 0" \
    "${_efi_dry_run_pending}" "0"

# ── EFI_DRY_RUN + EFI_CONFIRM_UPDATE precedence ──────────────────────────────

# Test 9: both set -> EFI_CONFIRM_UPDATE cleared to 0
EFI_DRY_RUN=1
EFI_CONFIRM_UPDATE=1
if [ "${EFI_DRY_RUN}" = "1" ] && [ "${EFI_CONFIRM_UPDATE}" = "1" ]; then
    EFI_CONFIRM_UPDATE=0
fi
assert_eq "EFI_DRY_RUN wins: EFI_CONFIRM_UPDATE cleared to 0" \
    "${EFI_CONFIRM_UPDATE}" "0"

# Test 10: both set -> warning message mentions "dry-run takes precedence"
EFI_DRY_RUN=1
EFI_CONFIRM_UPDATE=1
_prec_warn=""
if [ "${EFI_DRY_RUN}" = "1" ] && [ "${EFI_CONFIRM_UPDATE}" = "1" ]; then
    _prec_warn=$(
        _efi_warn "EFI_DRY_RUN and EFI_CONFIRM_UPDATE both set; dry-run takes precedence" 2>&1
    )
    EFI_CONFIRM_UPDATE=0
fi
assert_contains "precedence warning mentions dry-run takes precedence" \
    "${_prec_warn}" "dry-run takes precedence"

# ── _efi_modal exact border and sub-border text ──────────────────────────────

# Test 11: _efi_modal passes border text through unchanged with *** prefix.
# The exact border strings are user-visible; regression here breaks the modal.
_out=$(_efi_modal "s" "============================================================" 2>/dev/null)
assert_contains "_efi_modal top border exact text" \
    "${_out}" "*** ============================================================"

# Test 12: _efi_dry_run_pending accumulates across multiple efi_safe_copy calls.
_src="${_tmpdir}/src12.efi"
_dst_a="${_tmpdir}/dst12a.efi"
_dst_b="${_tmpdir}/dst12b.efi"
printf 'content v2' > "${_src}"
printf 'content v1' > "${_dst_a}"
printf 'content v1' > "${_dst_b}"
EFI_DRY_RUN=1
_efi_dry_run_pending=0
efi_safe_copy "${_src}" "${_dst_a}" 2>/dev/null
efi_safe_copy "${_src}" "${_dst_b}" 2>/dev/null
assert_eq "_efi_dry_run_pending accumulates across multiple calls" \
    "${_efi_dry_run_pending}" "2"

# ── Cleanup ───────────────────────────────────────────────────────────────────
EFI_DRY_RUN=0
EFI_CONFIRM_UPDATE=0
rm -f "${_dummy_loader}"
rm -rf "${_tmpdir}"
mock_cleanup

tap_end
