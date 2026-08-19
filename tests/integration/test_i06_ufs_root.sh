#!/bin/sh
# test_i06_ufs_root.sh
#
# Integration test: UFS root filesystem, single disk ada0, EFI partition (p1)
# and freebsd-boot partition (p2).  amd64, UEFI boot.
#
# After update:
#   - EFI loader updated
#   - gpart bootcode called with /boot/gptboot (not gptzfsboot) — UFS root
#
# 5 assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 5

setup_test_dir
mock_init

# --- Fake loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua ufs test content' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- Fake BIOS boot files ---
FAKE_PMBR="${TEST_DIR}/pmbr"
FAKE_GPTBOOT="${TEST_DIR}/gptboot"
FAKE_GPTZFSBOOT="${TEST_DIR}/gptzfsboot"
printf 'pmbr content' > "${FAKE_PMBR}"
printf 'gptboot content' > "${FAKE_GPTBOOT}"
printf 'gptzfsboot content' > "${FAKE_GPTZFSBOOT}"
export EFI_BIOS_PMBR="${FAKE_PMBR}"
export EFI_BIOS_UFS_BOOT="${FAKE_GPTBOOT}"
export EFI_BIOS_ZFS_BOOT="${FAKE_GPTZFSBOOT}"

# --- Fake fstab for UFS root discovery ---
FAKE_FSTAB="${TEST_DIR}/fstab"
printf '/dev/ada0p3  /  ufs  rw  1  1\n' > "${FAKE_FSTAB}"

# --- ESP fixture: EFI/FreeBSD/loader.efi already present ---
mkdir -p "${TEST_ESP_DIR}/EFI/FreeBSD"
mkdir -p "${TEST_ESP_DIR}/EFI/boot"
printf 'FreeBSD loader.efi boot/lua old ufs loader' > "${TEST_ESP_DIR}/EFI/FreeBSD/loader.efi"
printf 'FreeBSD loader.efi boot/lua old ufs loader' > "${TEST_ESP_DIR}/EFI/boot/BOOTx64.efi"

# --- Fake mountpoint ---
FAKE_MP="${TEST_DIR}/fake_mp"
mkdir -p "${FAKE_MP}"

mock_cmd mktemp "echo '${FAKE_MP}'"
mock_cmd mount_msdosfs "
cp -r '${TEST_ESP_DIR}/.' '${FAKE_MP}/'
exit 0"

# --- Standard mocks ---
mock_cmd_output id "0"

mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "UEFI" ;;
    *) echo "0" ;;
esac'

mock_cmd_output uname "amd64"

# mount: root is ufs, NOT zfs
mock_cmd mount '
case "$*" in
    *msdosfs*) exit 0 ;;
    *) printf "/dev/ada0p3 on / type ufs (local, soft-updates)\n" ;;
esac'

# zfs and zpool should NOT be relied upon for UFS root; mock defensively
mock_cmd_output zfs ""
mock_cmd_output zpool ""

# awk reading /etc/fstab: redirect to our fake fstab
# We override efi_ufs_boot_disks' awk call by making awk return the right device.
# Simplest approach: mock awk to return ada0 when queried with our fake fstab.
# Instead, we patch /etc/fstab path via shell function override after sourcing.

mock_cmd gpart '
case "$*" in
    *show*ada0*)
        printf "=>       40  976773095  ada0  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640       1024     2  freebsd-boot  (512K)\n"
        printf "     410664    8388608     3  freebsd-ufs  (4.0G)\n"
        printf "    8799272  967973820     4  freebsd-ufs  (462G)\n"
        ;;
    *bootcode*)
        exit 0
        ;;
    *) exit 1 ;;
esac'

mock_cmd_output umount ""
mock_cmd_output rmdir ""
mock_cmd df 'printf "Filesystem 1K-blocks Used Avail\n/dev/ada0p1 204800 1024 203776\n"'
mock_cmd strings 'grep -a "." "$@" 2>/dev/null || true'
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

# Override efi_ufs_boot_disks to read our fake fstab instead of /etc/fstab
efi_ufs_boot_disks() {
    local root_dev
    root_dev=$(awk '$2 == "/" && $1 !~ /^#/ { print $1; exit }' "${FAKE_FSTAB}" 2>/dev/null)
    root_dev="${root_dev#/dev/}"
    root_dev=$(echo "$root_dev" | sed 's/[sp][0-9]*[a-z]*$//')
    [ -n "$root_dev" ] && echo "$root_dev"
}

# --- Run ---
update_bootloaders
_rc=$?

# --- Assertions ---

assert_eq "update_bootloaders returns 0 on UFS root" "${_rc}" "0"

assert_file_exists \
    "EFI/FreeBSD/loader.efi updated on ESP" \
    "${FAKE_MP}/EFI/FreeBSD/loader.efi"

_content=$(cat "${FAKE_MP}/EFI/FreeBSD/loader.efi" 2>/dev/null)
assert_contains \
    "EFI/FreeBSD/loader.efi has new loader content" \
    "${_content}" "ufs test content"

# gpart bootcode should have been called
assert_true \
    "gpart bootcode called for freebsd-boot partition" \
    mock_was_called gpart

# Verify gptboot (not gptzfsboot) was referenced in gpart args
_gpart_log=$(grep "gpart bootcode" "${MOCK_CALL_LOG}" 2>/dev/null || echo "")
assert_contains \
    "gpart bootcode args reference gptboot (UFS, not ZFS)" \
    "${_gpart_log}" "gptboot"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
