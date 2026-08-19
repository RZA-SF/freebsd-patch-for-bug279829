#!/bin/sh
# test_13_nvram_entry.sh - Tests for efi_ensure_nvram_entry
#
# Verifies that efi_ensure_nvram_entry handles the absence of efibootmgr
# gracefully, skips creating an entry when one already exists, creates a new
# entry when none exists, handles efibootmgr failures non-fatally, and
# respects dry-run mode.
#
# Note: after removing or (re-)creating the efibootmgr mock, `hash -r` is
# called to clear the POSIX sh command hash table.  Without this, dash caches
# the real /usr/bin/efibootmgr path and continues to use it even after the
# mock is installed in ${MOCK_BIN}.

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

# Common arguments used in every call to efi_ensure_nvram_entry.
_ESP_MOUNT="/tmp/esp_test"
_LOADER_ABS="${_ESP_MOUNT}/EFI/FreeBSD/loader.efi"

tap_begin 6

# Test 1: efibootmgr not available -> returns 0 (non-fatal)
# Remove efibootmgr from MOCK_BIN so `command -v efibootmgr` fails.
rm -f "${MOCK_BIN}/efibootmgr"
hash -r 2>/dev/null || true
_rc=0
efi_ensure_nvram_entry "${_ESP_MOUNT}" "${_LOADER_ABS}" 2>/dev/null || _rc=$?
assert_eq "efibootmgr absent -> returns 0 (non-fatal)" "${_rc}" "0"

# Test 2: existing FreeBSD/loader.efi entry -> efibootmgr -c NOT called
# Expectations: efibootmgr called exactly once (the -v query); the create
# path is skipped because the query returns a FreeBSD loader.efi entry.
: > "${MOCK_CALL_LOG}"
mock_cmd efibootmgr "cat \"${FIXTURES_DIR}/efibootmgr_freebsd_only.txt\""
hash -r 2>/dev/null || true
EFI_DRY_RUN=0
efi_ensure_nvram_entry "${_ESP_MOUNT}" "${_LOADER_ABS}" 2>/dev/null
_count="$(mock_call_count efibootmgr)"
assert_eq "existing FreeBSD entry -> efibootmgr called exactly once (query only)" \
    "${_count}" "1"

# Test 3: no FreeBSD entry -> efibootmgr -a -c called (count > 1)
: > "${MOCK_CALL_LOG}"
mock_cmd efibootmgr "cat \"${FIXTURES_DIR}/efibootmgr_no_freebsd.txt\""
hash -r 2>/dev/null || true
EFI_DRY_RUN=0
efi_ensure_nvram_entry "${_ESP_MOUNT}" "${_LOADER_ABS}" 2>/dev/null
_count="$(mock_call_count efibootmgr)"
assert_ne "no FreeBSD entry -> efibootmgr called more than once" "${_count}" "1"

# Test 4: efibootmgr -a -c fails -> returns 0 (non-fatal)
# First call (query) returns no FreeBSD entry; second call (-a -c) exits 1.
: > "${MOCK_CALL_LOG}"
cat > "${MOCK_BIN}/efibootmgr" << MOCK_EOF
#!/bin/sh
echo "efibootmgr \$*" >> "\${MOCK_CALL_LOG}"
_n=\$(grep -c "^efibootmgr" "\${MOCK_CALL_LOG}" 2>/dev/null || echo 0)
if [ "\${_n}" = "1" ]; then
    cat "${FIXTURES_DIR}/efibootmgr_no_freebsd.txt"
    exit 0
fi
exit 1
MOCK_EOF
chmod +x "${MOCK_BIN}/efibootmgr"
hash -r 2>/dev/null || true
EFI_DRY_RUN=0
_rc=0
efi_ensure_nvram_entry "${_ESP_MOUNT}" "${_LOADER_ABS}" 2>/dev/null || _rc=$?
assert_eq "efibootmgr -a -c fails -> returns 0 (non-fatal)" "${_rc}" "0"

# Test 5: dry-run mode -> efibootmgr -a -c NOT executed
# In dry-run mode only the query (-v) is performed; no real create call is made.
: > "${MOCK_CALL_LOG}"
mock_cmd efibootmgr "cat \"${FIXTURES_DIR}/efibootmgr_no_freebsd.txt\""
hash -r 2>/dev/null || true
EFI_DRY_RUN=1
efi_ensure_nvram_entry "${_ESP_MOUNT}" "${_LOADER_ABS}" 2>/dev/null
_count="$(mock_call_count efibootmgr)"
# Only the initial -v query should have run; the -a -c create is dry-run-skipped.
assert_eq "dry-run -> efibootmgr called only once (query, not create)" \
    "${_count}" "1"

EFI_DRY_RUN=0

# Test 6: efibootmgr -l receives Unix path, not EFI backslash path
# Regression: script was deriving '\EFI\FreeBSD\loader.efi' and passing it
# to efibootmgr -l.  FreeBSD efibootmgr expects a Unix path on the mounted
# ESP and translates it to a UEFI device path itself.  Passing a backslash
# path caused: "Cannot translate unix loader path: No such file or directory".
: > "${MOCK_CALL_LOG}"
mock_cmd efibootmgr "cat \"${FIXTURES_DIR}/efibootmgr_no_freebsd.txt\""
hash -r 2>/dev/null || true
EFI_DRY_RUN=0
efi_ensure_nvram_entry "${_ESP_MOUNT}" "${_LOADER_ABS}" 2>/dev/null
_create_args="$(mock_last_args efibootmgr)"
assert_contains \
    "efibootmgr -l: Unix path passed (not EFI backslash path)" \
    "${_create_args}" "${_LOADER_ABS}"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
