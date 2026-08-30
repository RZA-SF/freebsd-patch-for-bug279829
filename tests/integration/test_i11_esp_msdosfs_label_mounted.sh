#!/bin/sh
# test_i11_esp_msdosfs_label_mounted.sh
#
# Integration test: ESP is already mounted but mount(8) reports it with a
# GEOM msdosfs volume-label path (/dev/msdosfs/EFI) rather than the raw
# device node (/dev/da0s1).  This occurs on MBR systems (e.g. RPi4B with
# a dd'd 14.5-BETA2 image) when the FAT ESP has a volume label.
#
# R-11 regression: efi_esp_mountpoint matched only on the raw device path,
# so the existing mount was not detected; mount_msdosfs was then called on
# the already-mounted device and failed with "Device busy".
#
# update_bootloaders must:
#   - Detect the existing /boot/efi mountpoint via glabel resolution
#   - Reuse it; NOT call mount_msdosfs again
#   - NOT call umount when done
#   - Update EFI/FreeBSD/loader.efi at the existing mountpoint
#
# 4 assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 5

setup_test_dir
mock_init

# --- Fake loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua msdosfs-label test' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- Pre-existing ESP mountpoint with content ---
EXISTING_MP="${TEST_ESP_DIR}"
mkdir -p "${EXISTING_MP}/EFI/FreeBSD"
printf 'FreeBSD loader.efi boot/lua old loader' > "${EXISTING_MP}/EFI/FreeBSD/loader.efi"

# --- Mocks ---
mock_cmd_output id "0"

mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *kern.disks*)           echo "da0" ;;
    *) echo "" ;;
esac'

mock_cmd_output uname "arm64"

# mount --libxo json: ESP mounted at EXISTING_MP with special=/dev/msdosfs/EFI
# (GEOM msdosfs label, not raw /dev/da0s1).  UFS root via ufs/rootfs label.
mock_cmd mount "printf '{\"mount\":{\"mounted\":[
  {\"special\":\"/dev/msdosfs/EFI\",\"node\":\"${EXISTING_MP}\",\"fstype\":\"msdosfs\",\"opts\":[\"rw\"]},
  {\"special\":\"/dev/ufs/rootfs\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"rw\"]}
]}}\n'"

# glabel status: msdosfs/EFI -> da0s1; ufs/rootfs -> da0s2a
mock_cmd glabel 'printf "              Name  Status  Components\n msdosfs/EFI  N/A  da0s1\n  ufs/rootfs  N/A  da0s2a\n"'

mock_cmd realpath 'echo "/dev/${1#/dev/}"'

mock_cmd gpart '
case "$*" in
    *show*da0*)
        printf "{\"PART\":[{\"scheme\":\"MBR\",\"partitions\":[{\"index\":1,\"type\":\"fat32lba\",\"label\":\"\",\"rawtype\":\"!0c\",\"size\":\"50M\"},{\"index\":2,\"type\":\"freebsd\",\"label\":\"\",\"rawtype\":\"!a5\",\"size\":\"29G\"}]}]}\n"
        ;;
    *) exit 1 ;;
esac'

mock_cmd_fail efibootmgr 127

# mount_msdosfs must NOT be called — fail loudly if it is
mock_cmd_fail mount_msdosfs 1

mock_cmd_output umount ""
mock_cmd_output rmdir ""
mock_cmd df "printf 'Filesystem 1K-blocks Used Avail\n/dev/msdosfs/EFI 51200 25600 25600\n'"
mock_cmd strings 'grep -a "." "$@" 2>/dev/null || true'
mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# --- Source and run ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

_output=$(update_bootloaders 2>&1)
_rc=$?

# --- Assertions ---

assert_eq "update_bootloaders returns 0 (msdosfs label mount reused)" "${_rc}" "0"

_mount_calls=0
mock_was_called mount_msdosfs && _mount_calls=1
assert_eq \
    "mount_msdosfs NOT called (ESP detected via msdosfs/EFI glabel)" \
    "${_mount_calls}" "0"

assert_file_exists \
    "EFI/FreeBSD/loader.efi exists at pre-existing mountpoint" \
    "${EXISTING_MP}/EFI/FreeBSD/loader.efi"

_content=$(cat "${EXISTING_MP}/EFI/FreeBSD/loader.efi" 2>/dev/null)
assert_contains \
    "EFI/FreeBSD/loader.efi content updated" \
    "${_content}" "msdosfs-label test"

# R-13: MBR summary uses 's' suffix (da0s1), not 'p' suffix (da0p1)
assert_contains \
    "MBR summary line uses correct sN suffix (not pN)" \
    "${_output}" "da0s1"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
