#!/bin/sh
# test_i02_single_disk_efi_only.sh
#
# Integration test: single disk (nvd0), EFI partition only (no freebsd-boot),
# ZFS root, amd64 UEFI.  The ESP already has EFI/FreeBSD/loader.efi.
#
# After update:
#   - EFI/FreeBSD/loader.efi updated to match source loader
#   - gpart bootcode NOT called (no freebsd-boot partition)
#
# 5 assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 5

setup_test_dir
mock_init

# --- Fake source loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua UPDATED content v2' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- ESP already has EFI/FreeBSD/loader.efi with older content ---
mkdir -p "${TEST_ESP_DIR}/EFI/FreeBSD"
mkdir -p "${TEST_ESP_DIR}/EFI/boot"
printf 'FreeBSD loader.efi boot/lua OLD content v1' > "${TEST_ESP_DIR}/EFI/FreeBSD/loader.efi"
printf 'FreeBSD loader.efi boot/lua OLD content v1' > "${TEST_ESP_DIR}/EFI/boot/BOOTx64.efi"

# --- Mock: id -u returns 0 ---
mock_cmd_output id "0"

# --- Mock: sysctl ---
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "UEFI" ;;
    *kern.disks*)           echo "nvd0" ;;
    *) echo "0" ;;
esac'

# --- Mock: uname returns amd64 ---
mock_cmd_output uname "amd64"

# --- Mock: mount ---
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\",\"noatime\"]}]}}\n"'

# --- Mock: zfs ---
mock_cmd_output zfs "zroot"

# --- Mock: zpool status shows nvd0p2 as vdev leaf ---
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME        STATE     READ WRITE CKSUM
	zroot       ONLINE       0     0     0
	  nvd0p2    ONLINE       0     0     0

errors: No known data errors
ZPS'

# --- Mock: gpart show for nvd0 (EFI partition only, no freebsd-boot) ---
mock_cmd gpart '
case "$*" in
    *show*nvd0*)
        printf "=>       40  976773095  nvd0  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640  976363456     2  freebsd-zfs  (465G)\n"
        ;;
    *bootcode*)
        # Should not be reached in this test
        exit 1
        ;;
    *)
        exit 1
        ;;
esac'

# --- Mock: mktemp ---
FAKE_MOUNT_MP="${TEST_DIR}/fake_esp_mount"
mkdir -p "${FAKE_MOUNT_MP}"
mock_cmd mktemp "echo '${FAKE_MOUNT_MP}'"

# --- Mock: mount_msdosfs: populate fake mountpoint from ESP fixture ---
mock_cmd mount_msdosfs "
cp -r '${TEST_ESP_DIR}/.' '${FAKE_MOUNT_MP}/'
exit 0"

mock_cmd_output umount ""
mock_cmd_output rmdir ""

# --- Mock: df returns ample free space ---
mock_cmd df 'printf "Filesystem 1K-blocks Used Avail Capacity Mounted\n/dev/nvd0p1 204800 1024 203776 1%% /tmp/fake_esp_mount\n"'

# --- Mock: strings ---
mock_cmd strings 'grep -a "." "$@" 2>/dev/null || true'

# --- Mock: efibootmgr: existing FreeBSD entry present, no new entry needed ---
mock_cmd efibootmgr '
case "$*" in
    *-v*) printf "Boot0001* FreeBSD\t\\EFI\\FreeBSD\\loader.efi\n" ;;
    *) exit 0 ;;
esac'

mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# --- Run ---
update_bootloaders
_rc=$?

assert_eq "update_bootloaders returns 0" "${_rc}" "0"

assert_file_exists \
    "EFI/FreeBSD/loader.efi exists after update" \
    "${FAKE_MOUNT_MP}/EFI/FreeBSD/loader.efi"

_content=$(cat "${FAKE_MOUNT_MP}/EFI/FreeBSD/loader.efi" 2>/dev/null)
assert_contains \
    "EFI/FreeBSD/loader.efi has updated content" \
    "${_content}" "UPDATED content v2"

# gpart bootcode must NOT have been called (no freebsd-boot partition on nvd0)
_gpart_bootcode_called=0
if grep -q "gpart bootcode" "${MOCK_CALL_LOG}" 2>/dev/null; then
    _gpart_bootcode_called=1
fi
assert_eq \
    "gpart bootcode was NOT called" \
    "${_gpart_bootcode_called}" "0"

# mount_msdosfs should have been called once (for the EFI partition)
assert_true \
    "mount_msdosfs was called to mount the ESP" \
    mock_was_called mount_msdosfs

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
