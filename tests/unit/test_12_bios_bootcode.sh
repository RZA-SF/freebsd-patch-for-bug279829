#!/bin/sh
# test_12_bios_bootcode.sh - Tests for efi_update_bios_bootcode
#
# Verifies that efi_update_bios_bootcode selects the correct boot program
# based on the root filesystem type, validates that required files exist, and
# respects dry-run mode.

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

# Create fake boot program files so file-existence checks pass.
_tmpdir="$(mktemp -d)"
_pmbr="${_tmpdir}/pmbr"
_gptzfsboot="${_tmpdir}/gptzfsboot"
_gptboot="${_tmpdir}/gptboot"
printf 'pmbr\n'       > "${_pmbr}"
printf 'gptzfsboot\n' > "${_gptzfsboot}"
printf 'gptboot\n'    > "${_gptboot}"

EFI_BIOS_PMBR="${_pmbr}"
EFI_BIOS_ZFS_BOOT="${_gptzfsboot}"
EFI_BIOS_UFS_BOOT="${_gptboot}"
export EFI_BIOS_PMBR EFI_BIOS_ZFS_BOOT EFI_BIOS_UFS_BOOT

tap_begin 8

# Test 1: ZFS root -> gpart called with gptzfsboot
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_libxo_zfs.json\""
mock_cmd_output gpart ""
EFI_DRY_RUN=0
efi_update_bios_bootcode nda0 2 2>/dev/null
assert_true "ZFS root -> gpart was called" mock_was_called gpart
_last="$(mock_last_args gpart)"
assert_contains "ZFS root -> gpart args include gptzfsboot" \
    "${_last}" "${_gptzfsboot}"

# Test 2: UFS root -> gpart called with gptboot
# Reset call log between tests.
: > "${MOCK_CALL_LOG}"
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_libxo_ufs.json\""
mock_cmd_output gpart ""
EFI_DRY_RUN=0
efi_update_bios_bootcode ada0 2 2>/dev/null
_last="$(mock_last_args gpart)"
assert_contains "UFS root -> gpart args include gptboot" \
    "${_last}" "${_gptboot}"

# Test 3: unknown FS type -> returns 0 (skip with warning, no gpart call)
: > "${MOCK_CALL_LOG}"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"tmpfs\",\"node\":\"/\",\"fstype\":\"tmpfs\",\"options\":\"rw,size=512m\"}]}}\n"'
mock_cmd_output gpart ""
EFI_DRY_RUN=0
_rc=0
efi_update_bios_bootcode sda0 1 2>/dev/null || _rc=$?
assert_eq "unknown FS type -> returns 0" "${_rc}" "0"

# Test 4: pmbr file missing -> returns 1
: > "${MOCK_CALL_LOG}"
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_libxo_zfs.json\""
_saved_pmbr="${EFI_BIOS_PMBR}"
EFI_BIOS_PMBR="${_tmpdir}/no_such_pmbr"
_rc=0
efi_update_bios_bootcode nda0 2 2>/dev/null || _rc=$?
assert_ne "pmbr missing -> returns non-zero" "${_rc}" "0"
EFI_BIOS_PMBR="${_saved_pmbr}"

# Test 5: bootprog file missing -> returns 1
: > "${MOCK_CALL_LOG}"
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_libxo_zfs.json\""
_saved_zfsboot="${EFI_BIOS_ZFS_BOOT}"
EFI_BIOS_ZFS_BOOT="${_tmpdir}/no_such_gptzfsboot"
_rc=0
efi_update_bios_bootcode nda0 2 2>/dev/null || _rc=$?
assert_ne "bootprog missing -> returns non-zero" "${_rc}" "0"
EFI_BIOS_ZFS_BOOT="${_saved_zfsboot}"

# Test 6: gpart fails -> returns 1
: > "${MOCK_CALL_LOG}"
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_libxo_zfs.json\""
mock_cmd_fail gpart 1
_rc=0
efi_update_bios_bootcode nda0 2 2>/dev/null || _rc=$?
assert_ne "gpart fails -> returns non-zero" "${_rc}" "0"

# Test 7: dry-run mode -> gpart is NOT called
: > "${MOCK_CALL_LOG}"
mock_cmd mount "cat \"${FIXTURES_DIR}/mount_libxo_zfs.json\""
mock_cmd_output gpart ""
EFI_DRY_RUN=1
efi_update_bios_bootcode nda0 2 2>/dev/null
assert_false "dry-run -> gpart not called" mock_was_called gpart

EFI_DRY_RUN=0

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
rm -rf "${_tmpdir}"
