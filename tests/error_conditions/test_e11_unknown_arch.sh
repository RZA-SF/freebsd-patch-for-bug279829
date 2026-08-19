#!/bin/sh
# test_e11_unknown_arch.sh
#
# Error condition: uname -m returns an unsupported architecture ("mips64").
# efi_fallback_binary must return 1.
# EFI update is skipped (no fallback binary name known).
# update_bootloaders returns 0 if no other errors (BIOS path still proceeds
# if freebsd-boot partitions exist, or is a no-op if none do).

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 4

setup_test_dir
mock_init

# --- Fake loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua unknown arch test' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

mock_cmd_output id "0"
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "UEFI" ;;
    *) echo "0" ;;
esac'

# uname returns mips64 (unsupported for EFI)
mock_cmd_output uname "mips64"

mock_cmd mount '
case "$*" in
    *msdosfs*) exit 0 ;;
    *) printf "zroot on / type zfs (local)\n" ;;
esac'
mock_cmd_output zfs "zroot"
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME        STATE     READ WRITE CKSUM
	zroot       ONLINE       0     0     0
	  da0p2     ONLINE       0     0     0

errors: No known data errors
ZPS'

# Disk has only an EFI partition (no freebsd-boot) so BIOS path is a no-op
mock_cmd gpart '
case "$*" in
    *show*da0*)
        printf "=>       40  976773095  da0  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640  976363456     2  freebsd-zfs  (465G)\n"
        ;;
    *) exit 1 ;;
esac'

# mount_msdosfs must NOT be called (EFI update skipped for unknown arch)
mock_cmd_fail mount_msdosfs 1

mock_cmd_output umount ""
mock_cmd_output rmdir ""
mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# Test efi_fallback_binary directly
_fallback_rc=0
_fallback_name=$(efi_fallback_binary 2>/dev/null) || _fallback_rc=$?

assert_eq \
    "efi_fallback_binary returns 1 for mips64 architecture" \
    "${_fallback_rc}" "1"

assert_empty \
    "efi_fallback_binary output is empty for unknown arch" \
    "${_fallback_name}"

# update_bootloaders should return 0 (unknown arch is a warning, not fatal)
_update_rc=99
update_bootloaders 2>/dev/null
_update_rc=$?

assert_eq \
    "update_bootloaders returns 0 for unknown arch (non-fatal)" \
    "${_update_rc}" "0"

# mount_msdosfs must NOT have been called (EFI update was skipped)
_mount_calls=0
mock_was_called mount_msdosfs && _mount_calls=1
assert_eq \
    "mount_msdosfs NOT called for unknown architecture" \
    "${_mount_calls}" "0"

# --- Cleanup ---
mock_cleanup
teardown_test_dir

tap_end
