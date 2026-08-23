#!/bin/sh
# test_i03_zfs_mirror_two_disk.sh
#
# Integration test: two-disk ZFS mirror (da0, da1), each with EFI partition
# (p1) and freebsd-boot (p2).  amd64, UEFI boot.
#
# After update:
#   - Both ESPs updated (EFI/FreeBSD/loader.efi created on each)
#   - gpart bootcode called twice (once per disk)
#   - NVRAM entry attempted (at least once)
#
# 10 assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 10

setup_test_dir
mock_init

# --- Fake loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua mirror test content' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- Fake BIOS files ---
FAKE_PMBR="${TEST_DIR}/pmbr"
FAKE_GPTZFSBOOT="${TEST_DIR}/gptzfsboot"
printf 'pmbr' > "${FAKE_PMBR}"
printf 'gptzfsboot' > "${FAKE_GPTZFSBOOT}"
export EFI_BIOS_PMBR="${FAKE_PMBR}"
export EFI_BIOS_ZFS_BOOT="${FAKE_GPTZFSBOOT}"

# --- Create two fake ESP fixtures ---
ESP_DA0="${TEST_DIR}/esp_da0"
ESP_DA1="${TEST_DIR}/esp_da1"
mkdir -p "${ESP_DA0}/EFI/boot"
mkdir -p "${ESP_DA1}/EFI/boot"
printf 'FreeBSD loader.efi boot/lua old content' > "${ESP_DA0}/EFI/boot/BOOTx64.efi"
printf 'FreeBSD loader.efi boot/lua old content' > "${ESP_DA1}/EFI/boot/BOOTx64.efi"

# --- Fake mountpoints ---
MOUNT_DA0="${TEST_DIR}/mp_da0"
MOUNT_DA1="${TEST_DIR}/mp_da1"
mkdir -p "${MOUNT_DA0}"
mkdir -p "${MOUNT_DA1}"

# mktemp is called twice; use a file counter to alternate between mountpoints
_mktemp_counter_file="${TEST_DIR}/mktemp_count"
printf '0' > "${_mktemp_counter_file}"
mock_cmd mktemp "
_cnt=\$(cat '${_mktemp_counter_file}' 2>/dev/null || echo 0)
_cnt=\$(( _cnt + 1 ))
printf '%s' \"\${_cnt}\" > '${_mktemp_counter_file}'
if [ \"\${_cnt}\" = '1' ]; then
    echo '${MOUNT_DA0}'
else
    echo '${MOUNT_DA1}'
fi"

# --- Mock: mount_msdosfs: copy correct ESP tree based on device ---
mock_cmd mount_msdosfs "
case \"\$*\" in
    */da0p1*)
        cp -r '${ESP_DA0}/.' '${MOUNT_DA0}/'
        ;;
    */da1p1*)
        cp -r '${ESP_DA1}/.' '${MOUNT_DA1}/'
        ;;
esac
exit 0"

# --- Mock: id, sysctl, uname ---
mock_cmd_output id "0"
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "UEFI" ;;
    *kern.disks*)           echo "da0 da1" ;;
    *) echo "0" ;;
esac'
mock_cmd_output uname "amd64"

# --- Mock: mount ---
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\",\"noatime\"]}]}}\n"'

# --- Mock: zfs ---
mock_cmd_output zfs "zroot"

# --- Mock: zpool status — two-disk mirror (da0, da1) ---
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME        STATE     READ WRITE CKSUM
	zroot       ONLINE       0     0     0
	  mirror-0  ONLINE       0     0     0
	    da0p4   ONLINE       0     0     0
	    da1p4   ONLINE       0     0     0

errors: No known data errors
ZPS'

# --- Mock: gpart show for da0 and da1 ---
mock_cmd gpart '
case "$*" in
    *show*da0*)
        printf "=>       40  976773095  da0  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640       1024     2  freebsd-boot  (512K)\n"
        printf "     410664  976362432     3  freebsd-zfs  (465G)\n"
        ;;
    *show*da1*)
        printf "=>       40  976773095  da1  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640       1024     2  freebsd-boot  (512K)\n"
        printf "     410664  976362432     3  freebsd-zfs  (465G)\n"
        ;;
    *bootcode*)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac'

mock_cmd_output umount ""
mock_cmd_output rmdir ""

mock_cmd df '
case "$*" in
    *mp_da0*) printf "Filesystem 1K-blocks Used Avail\n/dev/da0p1 204800 1024 203776\n" ;;
    *mp_da1*) printf "Filesystem 1K-blocks Used Avail\n/dev/da1p1 204800 1024 203776\n" ;;
    *) printf "Filesystem 1K-blocks Used Avail\n/dev/da0p1 204800 1024 203776\n" ;;
esac'

mock_cmd strings 'grep -a "." "$@" 2>/dev/null || true'
mock_cmd efibootmgr '
case "$*" in
    *-v*) echo "" ;;
    *-a*-c*) exit 0 ;;
    *) exit 0 ;;
esac'
mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"
# Simulate EFIRT present on Linux (where /dev/efi does not exist)
_EFI_DEV_EFI=/dev/null
export _EFI_DEV_EFI

# --- Run ---
update_bootloaders
_rc=$?

# --- Assertions ---

assert_eq "update_bootloaders returns 0 for mirror pool" "${_rc}" "0"

assert_file_exists \
    "EFI/FreeBSD/loader.efi created on da0 ESP" \
    "${MOUNT_DA0}/EFI/FreeBSD/loader.efi"

assert_file_exists \
    "EFI/FreeBSD/loader.efi created on da1 ESP" \
    "${MOUNT_DA1}/EFI/FreeBSD/loader.efi"

_content0=$(cat "${MOUNT_DA0}/EFI/FreeBSD/loader.efi" 2>/dev/null)
assert_contains \
    "da0 EFI/FreeBSD/loader.efi has updated content" \
    "${_content0}" "mirror test content"

_content1=$(cat "${MOUNT_DA1}/EFI/FreeBSD/loader.efi" 2>/dev/null)
assert_contains \
    "da1 EFI/FreeBSD/loader.efi has updated content" \
    "${_content1}" "mirror test content"

assert_file_exists \
    "EFI/boot/BOOTx64.efi updated on da0 ESP" \
    "${MOUNT_DA0}/EFI/boot/BOOTx64.efi"

assert_file_exists \
    "EFI/boot/BOOTx64.efi updated on da1 ESP" \
    "${MOUNT_DA1}/EFI/boot/BOOTx64.efi"

# gpart bootcode called exactly twice (once per disk)
_gpart_bootcode_count=$(grep "gpart bootcode" "${MOCK_CALL_LOG}" 2>/dev/null | wc -l | tr -d ' ')
assert_eq \
    "gpart bootcode called twice (one per disk)" \
    "${_gpart_bootcode_count}" "2"

# mount_msdosfs called twice
_mount_count=$(grep "^mount_msdosfs " "${MOCK_CALL_LOG}" 2>/dev/null | wc -l | tr -d ' ')
assert_eq \
    "mount_msdosfs called twice (one per EFI partition)" \
    "${_mount_count}" "2"

assert_true \
    "efibootmgr was called for NVRAM entry" \
    mock_was_called efibootmgr

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
