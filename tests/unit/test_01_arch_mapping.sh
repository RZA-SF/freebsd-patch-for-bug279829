#!/bin/sh
# test_01_arch_mapping.sh - Tests for efi_fallback_binary_for_arch
#
# Verifies the architecture-to-EFI-binary mapping table, including
# known aliases and rejection of unrecognised architecture strings.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

mock_init

# Provide enough mocks so the script can be sourced without side-effects.
# id(1) must return 0 (root) so efi_check_prerequisites is non-fatal on load.
mock_cmd_output id "0"
mock_cmd_output sysctl "0"
mock_cmd_fail uname 1

# Provide a non-empty dummy loader so the prerequisite check passes sourcing.
_dummy_loader="$(mktemp)"
printf 'dummy' > "${_dummy_loader}"
EFI_LOADER_SRC="${_dummy_loader}"
export EFI_LOADER_SRC

. "${SRC_DIR}/efi_bootloader_update.sh"

tap_begin 8

# amd64 -> BOOTx64.efi
assert_eq "amd64 maps to BOOTx64.efi" \
    "$(efi_fallback_binary_for_arch amd64)" "BOOTx64.efi"

# x86_64 (Linux alias for amd64) -> BOOTx64.efi
assert_eq "x86_64 maps to BOOTx64.efi" \
    "$(efi_fallback_binary_for_arch x86_64)" "BOOTx64.efi"

# arm64 -> BOOTaa64.efi
assert_eq "arm64 maps to BOOTaa64.efi" \
    "$(efi_fallback_binary_for_arch arm64)" "BOOTaa64.efi"

# aarch64 (Linux alias for arm64) -> BOOTaa64.efi
assert_eq "aarch64 maps to BOOTaa64.efi" \
    "$(efi_fallback_binary_for_arch aarch64)" "BOOTaa64.efi"

# i386 -> BOOTia32.efi
assert_eq "i386 maps to BOOTia32.efi" \
    "$(efi_fallback_binary_for_arch i386)" "BOOTia32.efi"

# riscv64 -> BOOTriscv64.efi
assert_eq "riscv64 maps to BOOTriscv64.efi" \
    "$(efi_fallback_binary_for_arch riscv64)" "BOOTriscv64.efi"

# unknown_arch -> returns 1
assert_false "unknown_arch returns failure" \
    efi_fallback_binary_for_arch "unknown_arch"

# empty string -> returns 1
assert_false "empty string returns failure" \
    efi_fallback_binary_for_arch ""

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
