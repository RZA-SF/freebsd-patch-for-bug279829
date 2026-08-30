#!/bin/sh
# test_i12_split_media_guard.sh
#
# Integration test: R-14 split-media guard.
#
# BootCurrent identifies nda0 (UUID aaaabbbb-...) as the boot disk.
# The ZFS root pool lives on ada0, a completely different disk.
# nda0 is NOT in the root disk list (no overlap).
#
# Expected behavior (R-14 guard):
#   - Only nda0's ESP is updated
#   - ada0's ESP is never mounted or written
#
# 7 assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 7

setup_test_dir
mock_init

# --- Fake loader source ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua split-media test content' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- Fake ESP for nda0 (boot disk, BootCurrent points here) ---
ESP_NDA0="${TEST_DIR}/esp_nda0"
mkdir -p "${ESP_NDA0}/EFI/boot"
printf 'FreeBSD loader.efi boot/lua old content' > "${ESP_NDA0}/EFI/boot/BOOTx64.efi"

# --- Fake mountpoint for nda0 ---
MOUNT_NDA0="${TEST_DIR}/mp_nda0"
mkdir -p "${MOUNT_NDA0}"

# --- Fake ESP directory for ada0 (root disk, should NOT be touched) ---
# We create a directory to detect if it gets written, but it is never mounted.
ESP_ADA0="${TEST_DIR}/esp_ada0"
mkdir -p "${ESP_ADA0}"

mock_cmd mktemp "echo '${MOUNT_NDA0}'"

# --- Mock: mount_msdosfs copies nda0 fixture into the mountpoint ---
mock_cmd mount_msdosfs "
case \"\$*\" in
    */nda0p1*)
        cp -r '${ESP_NDA0}/.' '${MOUNT_NDA0}/'
        ;;
    *)
        # Any mount of ada0 or unknown device is unexpected
        exit 1
        ;;
esac
exit 0"

# --- Mock: id, sysctl, uname ---
mock_cmd_output id "0"
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "UEFI" ;;
    *kern.disks*)           echo "nda0 ada0" ;;
    *) echo "0" ;;
esac'
mock_cmd_output uname "amd64"

# --- Mock: efibootmgr returns BootCurrent 0004 -> nda0p1 UUID ---
mock_cmd efibootmgr "cat \"${TESTS_DIR}/fixtures/efibootmgr_boot_nda0.txt\""

# --- Mock: gpart list for UUID matching ---
mock_cmd gpart '
case "$*" in
    *list*nda0*) cat "'"${TESTS_DIR}/fixtures/gpart_list_nda0.txt"'" ;;
    *list*ada0*)
        # ada0 has a different UUID — not the BootCurrent disk
        printf "Geom name: ada0\n"
        printf "1. Name: ada0p1\n"
        printf "   rawuuid: bbbbcccc-0000-0000-0000-000000000000\n"
        printf "   type: efi\n"
        ;;
    *show*nda0*)
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":4,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"465G\"}]}]}\n"
        ;;
    *show*ada0*)
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":4,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"465G\"}]}]}\n"
        ;;
    *) exit 1 ;;
esac'

# --- Mock: mount (root is ZFS on ada0) ---
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'

# --- Mock: zpool (root pool on ada0, not nda0) ---
mock_cmd zpool '
printf "  pool: zroot\n"
printf " state: ONLINE\n"
printf "config:\n"
printf "\tNAME\tSTATE\tREAD WRITE CKSUM\n"
printf "\tzroot\tONLINE\t0 0 0\n"
printf "\t  ada0p4\tONLINE\t0 0 0\n"
printf "\nerrors: No known data errors\n"'

mock_cmd_output umount ""
mock_cmd_output rmdir ""
mock_cmd df 'printf "Filesystem 1K-blocks Used Avail\n/dev/nda0p1 204800 1024 203776\n"'
mock_cmd strings 'grep -a "." "$@" 2>/dev/null || true'
mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# efibootmgr for NVRAM: no existing FreeBSD entry, so create one
mock_cmd efibootmgr '
case "$*" in
    *-v*) printf "BootCurrent: 0004\n" ;;
    *-a*-c*) exit 0 ;;
    *) exit 0 ;;
esac'

# Re-register efibootmgr to serve both the BootCurrent lookup and NVRAM check.
# The BootCurrent lookup uses -v; the NVRAM check also uses -v then -a -c.
mock_cmd efibootmgr '
case "$*" in
    *-v*) cat "'"${TESTS_DIR}/fixtures/efibootmgr_boot_nda0.txt"'" ;;
    *-a*-c*) exit 0 ;;
    *) exit 0 ;;
esac'

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

assert_eq "update_bootloaders returns 0" "${_rc}" "0"

assert_file_exists \
    "EFI/FreeBSD/loader.efi created on nda0 (boot disk) ESP" \
    "${MOUNT_NDA0}/EFI/FreeBSD/loader.efi"

_content=$(cat "${MOUNT_NDA0}/EFI/FreeBSD/loader.efi" 2>/dev/null)
assert_contains \
    "nda0 EFI/FreeBSD/loader.efi has updated content" \
    "${_content}" "split-media test content"

assert_file_exists \
    "EFI/BOOT/BOOTx64.efi updated on nda0 ESP" \
    "${MOUNT_NDA0}/EFI/boot/BOOTx64.efi"

# mount_msdosfs must have been called exactly once (nda0 only, never ada0)
_mount_count=$(grep "^mount_msdosfs " "${MOCK_CALL_LOG}" 2>/dev/null | wc -l | tr -d ' ')
assert_eq \
    "mount_msdosfs called exactly once (nda0 only, not ada0)" \
    "${_mount_count}" "1"

# Verify the one mount was for nda0, not ada0
_ada0_mount=$(grep "^mount_msdosfs.*ada0" "${MOCK_CALL_LOG}" 2>/dev/null | wc -l | tr -d ' ')
assert_eq \
    "ada0 ESP never mounted (split-media guard held)" \
    "${_ada0_mount}" "0"

# ada0 ESP directory must be empty — nothing was written there
_ada0_files=$(find "${ESP_ADA0}" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq \
    "ada0 ESP directory untouched (no files written)" \
    "${_ada0_files}" "0"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
