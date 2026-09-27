#!/bin/sh
# test_i18_dry_run_current.sh
#
# Integration test: dry-run mode when the ESP is already current.
#
# When every loader file on the ESP matches the source (cmp -s passes),
# _efi_dry_run_pending stays 0 and the modal must NOT fire.  This prevents
# false-alarm notifications on systems that have already been updated.
#
# Setup: fake ESP pre-populated with loader files whose content matches
# FAKE_LOADER exactly.  BOOTx64.efi also fingerprints as FreeBSD (primary
# bootprog_info pattern) so the fallback-update path is exercised too.
#
# 6 assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 6

setup_test_dir
mock_init

# --- Fake loader: content that passes the FreeBSD primary fingerprint ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD/amd64 EFI loader, Revision 1.1\nloader content current' \
    > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"
export EFI_DRY_RUN=1

# --- Fake BIOS files ---
FAKE_PMBR="${TEST_DIR}/pmbr"
FAKE_GPTZFSBOOT="${TEST_DIR}/gptzfsboot"
printf 'pmbr' > "${FAKE_PMBR}"
printf 'gptzfsboot' > "${FAKE_GPTZFSBOOT}"
export EFI_BIOS_PMBR="${FAKE_PMBR}"
export EFI_BIOS_ZFS_BOOT="${FAKE_GPTZFSBOOT}"

# --- Fake mount point pre-populated with up-to-date loader files ---
FAKE_MP="${TEST_DIR}/fake_mp"
mkdir -p "${FAKE_MP}/EFI/FreeBSD"
mkdir -p "${FAKE_MP}/EFI/BOOT"
# loader.efi matches source exactly -> cmp -s will pass -> no pending write
cp "${FAKE_LOADER}" "${FAKE_MP}/EFI/FreeBSD/loader.efi"
# BOOTx64.efi: same content (passes fingerprint + cmp -s) -> no pending write
cp "${FAKE_LOADER}" "${FAKE_MP}/EFI/BOOT/BOOTx64.efi"

mock_cmd mktemp "echo '${FAKE_MP}'"
mock_cmd_fail mount_msdosfs 1
mock_cmd_output logger ""   # absorb any unexpected syslog calls

mock_cmd_output id "0"

mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "UEFI" ;;
    *kern.disks*)           echo "nda0" ;;
    *) echo "0" ;;
esac'

mock_cmd_output uname "amd64"

mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\",\"noatime\"]}]}}\n"'

mock_cmd_output zfs "zroot"
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME        STATE     READ WRITE CKSUM
	zroot       ONLINE       0     0     0
	  nda0p4    ONLINE       0     0     0

errors: No known data errors
ZPS'

mock_cmd gpart '
case "$*" in
    *show*nda0*)
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-boot\",\"label\":\"\",\"rawtype\":\"83bd6b9d-7f41-11dc-be0b-001560b84f0f\",\"size\":\"512K\"},{\"index\":4,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"465G\"}]}]}\n"
        ;;
    *bootcode*) exit 1 ;;
    *) exit 1 ;;
esac'

mock_cmd_output umount ""
mock_cmd_output rmdir ""
mock_cmd df 'printf "Filesystem 1K-blocks Used Avail\n/dev/nda0p1 204800 1024 203776\n"'
mock_cmd strings 'grep -a "." "$@" 2>/dev/null || true'
mock_cmd efibootmgr '
case "$*" in
    *-v*) echo "" ;;
    *) exit 0 ;;
esac'
mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# --- Run and capture ---
_output=$(update_bootloaders 2>&1)
_rc=$?

# --- Assertions ---

assert_eq "returns 0 when already current" "${_rc}" "0"

# Silent: no modal NOTICE header (no pending writes detected)
_has_notice=0
echo "${_output}" | grep -qF "*** NOTICE:" && _has_notice=1
assert_eq "no modal NOTICE when ESP already current" "${_has_notice}" "0"

# Silent: no WARNING block
_has_warning=0
echo "${_output}" | grep -qF "*** WARNING:" && _has_warning=1
assert_eq "no modal WARNING when ESP already current" "${_has_warning}" "0"

# Silent: no --confirm-update instruction in output
_has_instruction=0
echo "${_output}" | grep -qF "confirm-update" && _has_instruction=1
assert_eq "no --confirm-update instruction when ESP already current" "${_has_instruction}" "0"

# Correct completion message for dry-run with nothing to do
assert_contains \
    "output contains 'no changes needed' completion message" \
    "${_output}" "[DRY RUN] Bootloader update complete (no changes needed)"

# logger NOT called (no syslog warn when nothing to notify)
_logger_called=0
mock_was_called logger && _logger_called=1
assert_eq "logger NOT called when ESP already current" "${_logger_called}" "0"

# --- Cleanup ---
EFI_DRY_RUN=0
mock_cleanup
teardown_test_dir

tap_end
