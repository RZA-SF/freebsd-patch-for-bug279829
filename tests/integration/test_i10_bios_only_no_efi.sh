#!/bin/sh
# test_i10_bios_only_no_efi.sh
#
# Integration test: BIOS-only system — freebsd-boot partition present but NO
# EFI partition.  machdep.bootmethod returns "BIOS".
#
# After update:
#   - gpart bootcode called for the freebsd-boot partition
#   - No ESP mounting attempted (no EFI partition, BIOS mode)
#
# 4 assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 4

setup_test_dir
mock_init

# --- Fake loader (still required for prerequisites check) ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua bios only test' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- Fake BIOS boot files ---
FAKE_PMBR="${TEST_DIR}/pmbr"
FAKE_GPTZFSBOOT="${TEST_DIR}/gptzfsboot"
printf 'pmbr content' > "${FAKE_PMBR}"
printf 'gptzfsboot content' > "${FAKE_GPTZFSBOOT}"
export EFI_BIOS_PMBR="${FAKE_PMBR}"
export EFI_BIOS_ZFS_BOOT="${FAKE_GPTZFSBOOT}"

# --- Mocks ---
mock_cmd_output id "0"

mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "BIOS" ;;
    *kern.disks*)           echo "ada0" ;;
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
	  ada0p3    ONLINE       0     0     0

errors: No known data errors
ZPS'

# gpart show: ONLY freebsd-boot partition, NO efi partition
mock_cmd gpart '
case "$*" in
    *show*ada0*)
        printf "=>       63  976773042  ada0  GPT  (466G)\n"
        printf "         63       1985     1  freebsd-boot  (993K)\n"
        printf "       2048    4194304     2  freebsd-swap  (2.0G)\n"
        printf "    4196352  972576752     3  freebsd-zfs  (464G)\n"
        ;;
    *bootcode*)
        exit 0
        ;;
    *) exit 1 ;;
esac'

mock_cmd_output umount ""
mock_cmd_output rmdir ""
mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# mount_msdosfs should not be called; if called, fail clearly
mock_cmd_fail mount_msdosfs 1

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# --- Run ---
update_bootloaders
_rc=$?

# --- Assertions ---

assert_eq "update_bootloaders returns 0 in BIOS-only mode" "${_rc}" "0"

assert_true \
    "gpart called (bootcode update for BIOS partition)" \
    mock_was_called gpart

_gpart_bootcode_count=$(grep "gpart bootcode" "${MOCK_CALL_LOG}" 2>/dev/null | wc -l | tr -d ' ')
assert_eq \
    "gpart bootcode called exactly once" \
    "${_gpart_bootcode_count}" "1"

_mount_msdosfs_calls=0
mock_was_called mount_msdosfs && _mount_msdosfs_calls=1
assert_eq \
    "mount_msdosfs NOT called (no EFI partition, BIOS mode)" \
    "${_mount_msdosfs_calls}" "0"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
