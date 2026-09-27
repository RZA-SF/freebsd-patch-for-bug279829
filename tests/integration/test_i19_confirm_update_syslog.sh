#!/bin/sh
# test_i19_confirm_update_syslog.sh
#
# Integration test: --confirm-update (EFI_CONFIRM_UPDATE=1) mode.
#
# When a write actually occurs:
#   - No *** modal on stdout (update succeeded, no advisory needed)
#   - logger called with daemon.notice (persistent syslog record of the update)
#   - Output contains "Bootloader update complete"
#   - Loader file on ESP is written with new content
#
# 6 assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 6

setup_test_dir
mock_init

# --- Fake loader: content distinct from what's on the ESP ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD/amd64 EFI loader, Revision 1.1\nnew loader content v2' \
    > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"
export EFI_DRY_RUN=0
export EFI_CONFIRM_UPDATE=1
export EFI_NVRAM_UPDATE=0   # skip NVRAM for simplicity

# --- Fake BIOS files ---
FAKE_PMBR="${TEST_DIR}/pmbr"
FAKE_GPTZFSBOOT="${TEST_DIR}/gptzfsboot"
printf 'pmbr' > "${FAKE_PMBR}"
printf 'gptzfsboot' > "${FAKE_GPTZFSBOOT}"
export EFI_BIOS_PMBR="${FAKE_PMBR}"
export EFI_BIOS_ZFS_BOOT="${FAKE_GPTZFSBOOT}"

# --- Fake mount point: ESP with stale loader (differs from FAKE_LOADER) ---
FAKE_MP="${TEST_DIR}/fake_mp"
mkdir -p "${FAKE_MP}/EFI/FreeBSD"
mkdir -p "${FAKE_MP}/EFI/BOOT"
printf 'old loader content v1' > "${FAKE_MP}/EFI/FreeBSD/loader.efi"
# BOOTx64.efi: stale + fingerprints as FreeBSD -> will be updated
printf 'FreeBSD/amd64 EFI loader, Revision 1.1\nold loader content v1' \
    > "${FAKE_MP}/EFI/BOOT/BOOTx64.efi"

mock_cmd_output logger ""   # capture syslog calls without writing to daemon log
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
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":4,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"465G\"}]}]}\n"
        ;;
    *) exit 1 ;;
esac'

# Mount succeeds: script will use FAKE_MP as the real ESP mount
mock_cmd mount_msdosfs "exit 0"
mock_cmd mktemp "echo '${FAKE_MP}'"

mock_cmd_output umount ""
mock_cmd_output rmdir ""
mock_cmd df 'printf "Filesystem 1K-blocks Used Avail\n/dev/nda0p1 204800 1024 203776\n"'
mock_cmd strings 'grep -a "." "$@" 2>/dev/null || true'
mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# --- Run and capture stdout + stderr ---
_output=$(update_bootloaders 2>&1)
_rc=$?

# --- Assertions ---

assert_eq "confirm-update returns 0 on success" "${_rc}" "0"

# No *** modal on stdout: update succeeded, no advisory notification needed
_has_modal=0
echo "${_output}" | grep -qF "*** NOTICE:" && _has_modal=1
assert_eq "no stdout modal on successful update" "${_has_modal}" "0"

# Completion message present
assert_contains \
    "output contains 'Bootloader update complete'" \
    "${_output}" "Bootloader update complete"

# logger called for daemon.notice syslog record
assert_true \
    "logger called for daemon.notice syslog record" \
    mock_was_called logger

# Loader file on ESP updated: content now matches source
_esp_content=$(cat "${FAKE_MP}/EFI/FreeBSD/loader.efi" 2>/dev/null)
_src_content=$(cat "${FAKE_LOADER}")
assert_eq "ESP loader.efi updated to match source" \
    "${_esp_content}" "${_src_content}"

# No *** WARNING in output (no warning-level modal for clean update)
_has_warning=0
echo "${_output}" | grep -qF "*** WARNING:" && _has_warning=1
assert_eq "no *** WARNING in output for clean update" "${_has_warning}" "0"

# --- Cleanup ---
EFI_DRY_RUN=0
EFI_CONFIRM_UPDATE=0
EFI_NVRAM_UPDATE=1
mock_cleanup
teardown_test_dir

tap_end
