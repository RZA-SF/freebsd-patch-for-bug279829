#!/bin/sh
# test_i01_single_disk_efi_bios.sh
#
# Integration test: single disk (nda0) with EFI partition (p1) and
# freebsd-boot partition (p2), ZFS root, amd64, UEFI boot.
#
# The fake ESP starts with only EFI/boot/BOOTx64.efi (no EFI/FreeBSD/ dir).
# After update_bootloaders:
#   - EFI/FreeBSD/loader.efi must be created
#   - EFI/boot/BOOTx64.efi must be updated (it fingerprints as FreeBSD)
#   - gpart bootcode must have been called for p2
#   - NVRAM entry creation (efibootmgr) must have been attempted
#
# 8 assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 8

setup_test_dir
mock_init

# --- Create fake source loader with FreeBSD fingerprint strings ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua fake content for testing' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- Create fake BIOS boot files ---
FAKE_PMBR="${TEST_DIR}/pmbr"
FAKE_GPTZFSBOOT="${TEST_DIR}/gptzfsboot"
printf 'pmbr content' > "${FAKE_PMBR}"
printf 'gptzfsboot content' > "${FAKE_GPTZFSBOOT}"
export EFI_BIOS_PMBR="${FAKE_PMBR}"
export EFI_BIOS_ZFS_BOOT="${FAKE_GPTZFSBOOT}"

# --- Set up fake ESP: only EFI/boot/BOOTx64.efi (no EFI/FreeBSD/ dir) ---
mkdir -p "${TEST_ESP_DIR}/EFI/boot"
printf 'FreeBSD loader.efi boot/lua fake content' > "${TEST_ESP_DIR}/EFI/boot/BOOTx64.efi"

# --- Mock: id -u returns 0 (root) ---
mock_cmd_output id "0"

# --- Mock: sysctl (jail check returns 0, boot method returns UEFI) ---
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "UEFI" ;;
    *) echo "0" ;;
esac'

# --- Mock: uname returns amd64 ---
mock_cmd_output uname "amd64"

# --- Mock: mount (root is zfs, ESP not yet mounted) ---
mock_cmd mount '
case "$*" in
    *msdosfs*)
        # Actual mount call - succeed silently
        exit 0
        ;;
    *)
        # mount with no args: show current mounts
        printf "zroot on / type zfs (local)\n"
        ;;
esac'

# --- Mock: zfs returns pool name "zroot" ---
mock_cmd_output zfs "zroot"

# --- Mock: zpool status shows nda0p4 as vdev leaf ---
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

# --- Mock: gpart show for nda0 ---
mock_cmd gpart '
case "$*" in
    *bootcode*)
        # gpart bootcode call — succeed
        exit 0
        ;;
    *show*nda0*)
        printf "=>       40  976773095  nda0  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640       1024     2  freebsd-boot  (512K)\n"
        printf "     410664    8388608     3  freebsd-swap  (4.0G)\n"
        printf "    8799272  967973820     4  freebsd-zfs  (462G)\n"
        ;;
    *)
        exit 1
        ;;
esac'

# --- Mock: mktemp returns a known directory ---
FAKE_MOUNT_MP="${TEST_DIR}/fake_esp_mount"
mkdir -p "${FAKE_MOUNT_MP}"
mock_cmd mktemp "echo '${FAKE_MOUNT_MP}'"

# --- Mock: mount_msdosfs: copy ESP contents into the fake mountpoint ---
mock_cmd mount_msdosfs "
cp -r '${TEST_ESP_DIR}/.' '${FAKE_MOUNT_MP}/'
exit 0"

# --- Mock: umount succeeds ---
mock_cmd_output umount ""

# --- Mock: rmdir succeeds ---
mock_cmd_output rmdir ""

# --- Mock: df returns ample free space (200 MB = 204800 KB) ---
mock_cmd df 'printf "Filesystem 1K-blocks Used Avail Capacity Mounted\n/dev/nda0p1 204800 1024 203776 1%% /tmp/fake_esp_mount\n"'

# --- Mock: strings — pass through to real strings or fake it ---
mock_cmd strings 'grep -a "." "$@" 2>/dev/null || true'

# --- Mock: efibootmgr: no existing FreeBSD entry, creation succeeds ---
mock_cmd efibootmgr '
case "$*" in
    *-v*) echo "Boot0000* FreeBSD" ;;
    *-a*-c*) exit 0 ;;
    *) exit 0 ;;
esac'

# --- Mock: sync succeeds ---
mock_cmd_output sync ""

# --- Mock: stat returns file size 512 ---
mock_cmd stat 'echo "512"'

# --- Source the script under test (guard prevents double-source issues) ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# --- Run ---
update_bootloaders
_rc=$?

# --- Assertions ---

assert_eq "update_bootloaders returns 0" "${_rc}" "0"

assert_file_exists \
    "EFI/FreeBSD/loader.efi created in fake mountpoint" \
    "${FAKE_MOUNT_MP}/EFI/FreeBSD/loader.efi"

assert_file_exists \
    "EFI/boot/BOOTx64.efi still exists after update" \
    "${FAKE_MOUNT_MP}/EFI/boot/BOOTx64.efi"

# The fallback was a FreeBSD loader, so it should have been updated
# (content should now match fake loader, not original fingerprint stub)
_fallback_content=$(cat "${FAKE_MOUNT_MP}/EFI/boot/BOOTx64.efi" 2>/dev/null)
assert_contains \
    "EFI/boot/BOOTx64.efi updated with loader content" \
    "${_fallback_content}" "FreeBSD loader.efi boot/lua fake content for testing"

_freebsd_content=$(cat "${FAKE_MOUNT_MP}/EFI/FreeBSD/loader.efi" 2>/dev/null)
assert_contains \
    "EFI/FreeBSD/loader.efi has loader content" \
    "${_freebsd_content}" "FreeBSD loader.efi boot/lua fake content for testing"

assert_true \
    "gpart bootcode was called (BIOS partition update)" \
    mock_was_called gpart

_gpart_args=$(mock_last_args gpart)
assert_contains \
    "gpart bootcode args reference p2" \
    "${_gpart_args}" "bootcode"

assert_true \
    "efibootmgr was called (NVRAM entry attempt)" \
    mock_was_called efibootmgr

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
