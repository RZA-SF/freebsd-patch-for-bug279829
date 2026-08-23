#!/bin/sh
# test_e09_efibootmgr_missing.sh
#
# Error condition: efibootmgr is not in PATH.
# update_bootloaders must still return 0 (NVRAM update is non-fatal).
# A warning must be printed to stderr.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 4

setup_test_dir
mock_init

# --- Fake loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua efibootmgr missing test' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# --- ESP: empty ---
mkdir -p "${TEST_ESP_DIR}/EFI"

FAKE_MP="${TEST_DIR}/fake_mp"
mkdir -p "${FAKE_MP}"
cp -r "${TEST_ESP_DIR}/." "${FAKE_MP}/"

mock_cmd mktemp "echo '${FAKE_MP}'"
mock_cmd mount_msdosfs "exit 0"

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
	  nda0p2    ONLINE       0     0     0

errors: No known data errors
ZPS'
mock_cmd gpart '
case "$*" in
    *show*nda0*)
        printf "=>       40  976773095  nda0  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640  976363456     2  freebsd-zfs  (465G)\n"
        ;;
    *) exit 1 ;;
esac'
mock_cmd_output umount ""
mock_cmd_output rmdir ""
mock_cmd df 'printf "Filesystem 1K-blocks Used Avail\n/dev/nda0p1 204800 1024 203776\n"'
mock_cmd strings 'grep -a "." "$@" 2>/dev/null || true'
mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# Restrict PATH so efibootmgr is not found.  On FreeBSD 14+ efibootmgr is a
# base system binary at /usr/sbin/efibootmgr; on older systems or when
# installed via pkg it lives at /usr/local/sbin/efibootmgr.  Restricting to
# /bin and /usr/bin excludes both locations.  All FreeBSD system commands used
# by the real code paths (gpart, sysctl, mount, zfs, zpool, etc.) are mocked
# in MOCK_BIN; POSIX utilities (find, awk, sed, tr, sort, cp, mv, rm, etc.)
# are in /bin or /usr/bin on FreeBSD.
_saved_path="${PATH}"
PATH="${MOCK_BIN}:/bin:/usr/bin"
hash -r 2>/dev/null || true

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"
# Simulate EFIRT present so the EFIRT check does not short-circuit before
# the efibootmgr availability check.
_EFI_DEV_EFI=/dev/null
export _EFI_DEV_EFI

# --- Run and capture stderr ---
_stderr=$(update_bootloaders 2>&1 >/dev/null)
_rc=$?

# --- Assertions ---

assert_eq \
    "update_bootloaders returns 0 even when efibootmgr is missing" \
    "${_rc}" "0"

assert_contains \
    "Warning about missing efibootmgr printed to stderr" \
    "${_stderr}" "efibootmgr"

# EFI/FreeBSD/loader.efi should still have been created (NVRAM skip is non-fatal)
assert_file_exists \
    "EFI/FreeBSD/loader.efi created despite missing efibootmgr" \
    "${FAKE_MP}/EFI/FreeBSD/loader.efi"

# efibootmgr must NOT have been called (it wasn't in PATH)
_efibm_calls=0
mock_was_called efibootmgr && _efibm_calls=1
assert_eq \
    "efibootmgr was NOT called (not in PATH)" \
    "${_efibm_calls}" "0"

# --- Cleanup ---
PATH="${_saved_path}"
hash -r 2>/dev/null || true
mock_cleanup
teardown_test_dir

tap_end
