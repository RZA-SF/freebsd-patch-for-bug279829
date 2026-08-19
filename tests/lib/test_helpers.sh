#!/bin/sh
# test_helpers.sh - TAP (Test Anything Protocol) output helpers
#
# Usage:
#   . tests/lib/test_helpers.sh
#   tap_begin 5
#   assert_eq "two plus two" "$(expr 2 + 2)" "4"
#   tap_end

# TAP state counters (initialized by tap_begin)
TAP_COUNT=0
TAP_PASS=0
TAP_FAIL=0
TAP_SKIP=0

# tap_begin TOTAL: Prints TAP plan and initializes counters
tap_begin() {
    _tap_total="$1"
    echo "1..${_tap_total}"
    TAP_COUNT=0
    TAP_PASS=0
    TAP_FAIL=0
    TAP_SKIP=0
    unset _tap_total
}

# _tap_ok DESC: Internal helper — records a passing test
_tap_ok() {
    TAP_COUNT=$(( TAP_COUNT + 1 ))
    TAP_PASS=$(( TAP_PASS + 1 ))
    echo "ok ${TAP_COUNT} - $1"
}

# _tap_not_ok DESC: Internal helper — records a failing test
_tap_not_ok() {
    TAP_COUNT=$(( TAP_COUNT + 1 ))
    TAP_FAIL=$(( TAP_FAIL + 1 ))
    echo "not ok ${TAP_COUNT} - $1"
}

# assert_eq DESC ACTUAL EXPECTED: Passes if ACTUAL = EXPECTED
assert_eq() {
    _desc="$1"
    _actual="$2"
    _expected="$3"
    if [ "${_actual}" = "${_expected}" ]; then
        _tap_ok "${_desc}"
    else
        _tap_not_ok "${_desc}"
        echo "# Expected: ${_expected}"
        echo "# Got:      ${_actual}"
    fi
    unset _desc _actual _expected
}

# assert_ne DESC ACTUAL UNEXPECTED: Passes if ACTUAL != UNEXPECTED
assert_ne() {
    _desc="$1"
    _actual="$2"
    _unexpected="$3"
    if [ "${_actual}" != "${_unexpected}" ]; then
        _tap_ok "${_desc}"
    else
        _tap_not_ok "${_desc}"
        echo "# Expected value to differ from: ${_unexpected}"
        echo "# Got:                           ${_actual}"
    fi
    unset _desc _actual _unexpected
}

# assert_true DESC COMMAND [ARGS...]: Passes if COMMAND exits 0
assert_true() {
    _desc="$1"
    shift
    if "$@"; then
        _tap_ok "${_desc}"
    else
        _tap_not_ok "${_desc}"
        echo "# Expected command to succeed: $*"
    fi
    unset _desc
}

# assert_false DESC COMMAND [ARGS...]: Passes if COMMAND exits non-zero
assert_false() {
    _desc="$1"
    shift
    if "$@"; then
        _tap_not_ok "${_desc}"
        echo "# Expected command to fail: $*"
    else
        _tap_ok "${_desc}"
    fi
    unset _desc
}

# assert_contains DESC HAYSTACK NEEDLE: Passes if NEEDLE is a substring of HAYSTACK
assert_contains() {
    _desc="$1"
    _haystack="$2"
    _needle="$3"
    case "${_haystack}" in
        *"${_needle}"*)
            _tap_ok "${_desc}"
            ;;
        *)
            _tap_not_ok "${_desc}"
            echo "# Expected to find: ${_needle}"
            echo "# In:               ${_haystack}"
            ;;
    esac
    unset _desc _haystack _needle
}

# assert_file_exists DESC PATH: Passes if PATH exists as a file
assert_file_exists() {
    _desc="$1"
    _path="$2"
    if [ -f "${_path}" ]; then
        _tap_ok "${_desc}"
    else
        _tap_not_ok "${_desc}"
        echo "# Expected file to exist: ${_path}"
    fi
    unset _desc _path
}

# assert_file_not_exists DESC PATH: Passes if PATH does not exist
assert_file_not_exists() {
    _desc="$1"
    _path="$2"
    if [ ! -e "${_path}" ]; then
        _tap_ok "${_desc}"
    else
        _tap_not_ok "${_desc}"
        echo "# Expected file to not exist: ${_path}"
    fi
    unset _desc _path
}

# assert_empty DESC VALUE: Passes if VALUE is the empty string
assert_empty() {
    _desc="$1"
    _value="$2"
    if [ -z "${_value}" ]; then
        _tap_ok "${_desc}"
    else
        _tap_not_ok "${_desc}"
        echo "# Expected empty string"
        echo "# Got: ${_value}"
    fi
    unset _desc _value
}

# assert_not_empty DESC VALUE: Passes if VALUE is non-empty
assert_not_empty() {
    _desc="$1"
    _value="$2"
    if [ -n "${_value}" ]; then
        _tap_ok "${_desc}"
    else
        _tap_not_ok "${_desc}"
        echo "# Expected non-empty string, got empty"
    fi
    unset _desc _value
}

# skip DESC: Records a skipped test
skip() {
    _desc="$1"
    TAP_COUNT=$(( TAP_COUNT + 1 ))
    TAP_SKIP=$(( TAP_SKIP + 1 ))
    echo "ok ${TAP_COUNT} # SKIP ${_desc}"
    unset _desc
}

# tap_end: Prints final summary to stderr
tap_end() {
    echo "# Passed: ${TAP_PASS} / ${TAP_COUNT}, Failed: ${TAP_FAIL}, Skipped: ${TAP_SKIP}" >&2
}

# setup_test_dir: Creates a temp directory and an esp subdirectory
setup_test_dir() {
    TEST_DIR=$(mktemp -d)
    TEST_ESP_DIR="${TEST_DIR}/esp"
    mkdir -p "${TEST_ESP_DIR}"
    export TEST_DIR
    export TEST_ESP_DIR
}

# teardown_test_dir: Removes the temp directory created by setup_test_dir
teardown_test_dir() {
    if [ -n "${TEST_DIR}" ]; then
        rm -rf "${TEST_DIR}"
    fi
    unset TEST_DIR
    unset TEST_ESP_DIR
}

# _fallback_for_arch ARCH: Outputs the fallback EFI filename for the given arch
_fallback_for_arch() {
    case "$1" in
        amd64)  echo "BOOTx64.efi" ;;
        arm64)  echo "BOOTaa64.efi" ;;
        *)      echo "BOOTx64.efi" ;;
    esac
}

# make_esp_freebsd_only ARCH: Creates EFI/boot/<fallback>.efi and EFI/FreeBSD/loader.efi
make_esp_freebsd_only() {
    _arch="$1"
    _fallback=$(_fallback_for_arch "${_arch}")
    _content="FreeBSD loader.efi boot/lua fake content"

    mkdir -p "${TEST_ESP_DIR}/EFI/boot"
    mkdir -p "${TEST_ESP_DIR}/EFI/FreeBSD"

    printf '%s' "${_content}" | dd bs=1 count=64 > "${TEST_ESP_DIR}/EFI/boot/${_fallback}" 2>/dev/null
    printf '%s' "${_content}" | dd bs=1 count=64 > "${TEST_ESP_DIR}/EFI/FreeBSD/loader.efi" 2>/dev/null

    unset _arch _fallback _content
}

# make_esp_fallback_only ARCH: Creates only EFI/boot/<fallback>.efi (no EFI/FreeBSD/)
make_esp_fallback_only() {
    _arch="$1"
    _fallback=$(_fallback_for_arch "${_arch}")
    _content="FreeBSD loader.efi boot/lua fake content"

    mkdir -p "${TEST_ESP_DIR}/EFI/boot"

    printf '%s' "${_content}" | dd bs=1 count=64 > "${TEST_ESP_DIR}/EFI/boot/${_fallback}" 2>/dev/null

    unset _arch _fallback _content
}

# make_esp_other_os: Creates a Windows-style ESP (not a FreeBSD loader)
make_esp_other_os() {
    mkdir -p "${TEST_ESP_DIR}/EFI/BOOT"
    mkdir -p "${TEST_ESP_DIR}/EFI/Microsoft/Boot"

    printf '%s' "Windows Boot Manager Microsoft" \
        > "${TEST_ESP_DIR}/EFI/BOOT/BOOTx64.efi"
    printf '%s' "Windows Boot Manager Microsoft bootmgfw" \
        > "${TEST_ESP_DIR}/EFI/Microsoft/Boot/bootmgfw.efi"
}

# make_esp_empty: Creates just the EFI/ directory with nothing inside
make_esp_empty() {
    mkdir -p "${TEST_ESP_DIR}/EFI"
}
