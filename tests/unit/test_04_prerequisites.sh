#!/bin/sh
# test_04_prerequisites.sh - Tests for efi_check_prerequisites
#
# Verifies the prerequisite checks: must be root, must not be in a jail,
# and the source loader file must exist and be non-empty.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

mock_init

# Bootstrap mocks used during sourcing.
mock_cmd_output id "0"
mock_cmd_output sysctl "0"

# Provide a non-empty dummy loader so the initial source-time check passes.
_dummy_loader="$(mktemp)"
printf 'dummy' > "${_dummy_loader}"
EFI_LOADER_SRC="${_dummy_loader}"
export EFI_LOADER_SRC

. "${SRC_DIR}/efi_bootloader_update.sh"

tap_begin 5

# Helper: run efi_check_prerequisites and capture its exit code.
_rc() {
    efi_check_prerequisites 2>/dev/null
    echo $?
}

# Test 1: root user (id returns 0), not in jail, loader exists -> returns 0
mock_cmd_output id "0"
mock_cmd_output sysctl "0"
EFI_LOADER_SRC="${_dummy_loader}"
assert_eq "root, not jailed, loader exists -> returns 0" "$(_rc)" "0"

# Test 2: non-root (id returns 1000) -> returns 1
mock_cmd_output id "1000"
mock_cmd_output sysctl "0"
EFI_LOADER_SRC="${_dummy_loader}"
assert_eq "non-root user -> returns 1" "$(_rc)" "1"

# Test 3: in jail (sysctl security.jail.jailed returns 1) -> returns 2
mock_cmd_output id "0"
mock_cmd_output sysctl "1"
EFI_LOADER_SRC="${_dummy_loader}"
assert_eq "running inside jail -> returns 2" "$(_rc)" "2"

# Test 4: loader file missing -> returns 1
mock_cmd_output id "0"
mock_cmd_output sysctl "0"
EFI_LOADER_SRC="/tmp/does_not_exist_$$.efi"
assert_eq "loader file missing -> returns 1" "$(_rc)" "1"

# Test 5: loader file empty -> returns 1
_empty_loader="$(mktemp)"
mock_cmd_output id "0"
mock_cmd_output sysctl "0"
EFI_LOADER_SRC="${_empty_loader}"
assert_eq "loader file empty -> returns 1" "$(_rc)" "1"
rm -f "${_empty_loader}"

# Restore a valid loader path so teardown is clean.
EFI_LOADER_SRC="${_dummy_loader}"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
