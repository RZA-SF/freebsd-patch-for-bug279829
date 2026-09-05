#!/bin/sh
# test_i14_ia32_install_fresh.sh
#
# Integration test: ia32 source present, no existing BOOTia32.efi on ESP.
#
# ESP contains BOOTx64.efi (FreeBSD) and EFI/FreeBSD/loader.efi.
# No BOOTia32.efi present.  After update:
#   - BOOTia32.efi created with ia32 loader content
#   - BOOTx64.efi updated (normal)
#   - EFI/FreeBSD/loader.efi updated (normal)
#
# 5 assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 5

setup_test_dir
mock_init

# --- Fake 64-bit loader source ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD/amd64 EFI loader, Revision 3.0 boot/lua UPDATED-v2' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- Fake ia32 loader source ---
FAKE_IA32="${TEST_DIR}/loader_ia32.efi"
printf 'FreeBSD/amd64-ia32 EFI loader, Revision 3.0 boot/lua ia32-UPDATED-v2' > "${FAKE_IA32}"
export _EFI_LOADER_IA32_SRC="${FAKE_IA32}"

# --- Build ESP: BOOTx64.efi + FreeBSD dir; no BOOTia32.efi ---
mkdir -p "${TEST_ESP_DIR}/EFI/BOOT"
mkdir -p "${TEST_ESP_DIR}/EFI/FreeBSD"
printf 'FreeBSD/amd64 EFI loader, Revision 3.0 boot/lua OLD-v1' \
    > "${TEST_ESP_DIR}/EFI/BOOT/BOOTx64.efi"
printf 'FreeBSD/amd64 EFI loader, Revision 3.0 boot/lua OLD-v1' \
    > "${TEST_ESP_DIR}/EFI/FreeBSD/loader.efi"

# --- Fake mountpoint ---
FAKE_MP="${TEST_DIR}/fake_mp"
mkdir -p "${FAKE_MP}"

mock_cmd mktemp "echo '${FAKE_MP}'"
mock_cmd mount_msdosfs "
cp -r '${TEST_ESP_DIR}/.' '${FAKE_MP}/'
exit 0"

mock_cmd_output id "0"
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "UEFI" ;;
    *kern.disks*)           echo "ada0" ;;
    *) echo "0" ;;
esac'
mock_cmd_output uname "amd64"

mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'

mock_cmd_output zfs "zroot"
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME        STATE     READ WRITE CKSUM
	zroot       ONLINE       0     0     0
	  ada0p2    ONLINE       0     0     0

errors: No known data errors
ZPS'

mock_cmd gpart '
case "$*" in
    *show*ada0*)
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\"},{\"index\":2,\"type\":\"freebsd-zfs\"}]}]}\n"
        ;;
    *) exit 1 ;;
esac'

mock_cmd_output umount ""
mock_cmd_output rmdir ""
mock_cmd df 'printf "Filesystem 1K-blocks Used Avail\n/dev/ada0p1 204800 1024 203776\n"'
mock_cmd strings 'cat "$@" 2>/dev/null || true'
mock_cmd efibootmgr '
case "$*" in
    *-v*) printf "Boot0001* FreeBSD\t\\EFI\\FreeBSD\\loader.efi\n" ;;
    *) exit 0 ;;
esac'
mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"
_EFI_DEV_EFI=/dev/null
export _EFI_DEV_EFI

update_bootloaders
_rc=$?

assert_eq "update_bootloaders returns 0" "${_rc}" "0"

assert_file_exists \
    "BOOTia32.efi created (fresh install)" \
    "${FAKE_MP}/EFI/BOOT/BOOTia32.efi"

_ia32=$(cat "${FAKE_MP}/EFI/BOOT/BOOTia32.efi" 2>/dev/null)
assert_contains \
    "BOOTia32.efi has ia32 loader content" \
    "${_ia32}" "ia32-UPDATED-v2"

_x64=$(cat "${FAKE_MP}/EFI/BOOT/BOOTx64.efi" 2>/dev/null)
assert_contains \
    "BOOTx64.efi also updated (normal operation)" \
    "${_x64}" "UPDATED-v2"

_fbsd=$(cat "${FAKE_MP}/EFI/FreeBSD/loader.efi" 2>/dev/null)
assert_contains \
    "EFI/FreeBSD/loader.efi also updated (normal operation)" \
    "${_fbsd}" "UPDATED-v2"

mock_cleanup
teardown_test_dir

tap_end
