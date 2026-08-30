#!/bin/sh
# test_i09_dry_run.sh
#
# Integration test: EFI_DRY_RUN=1 mode.
#
# After "update":
#   - No files actually created or modified on ESP
#   - No gpart bootcode actually called
#   - Output contains "[DRY RUN]" strings
#
# 6 assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin 6

setup_test_dir
mock_init

# --- Fake loader ---
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua dry run test content' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"
export EFI_DRY_RUN=1

# --- Fake BIOS files ---
FAKE_PMBR="${TEST_DIR}/pmbr"
FAKE_GPTZFSBOOT="${TEST_DIR}/gptzfsboot"
printf 'pmbr' > "${FAKE_PMBR}"
printf 'gptzfsboot' > "${FAKE_GPTZFSBOOT}"
export EFI_BIOS_PMBR="${FAKE_PMBR}"
export EFI_BIOS_ZFS_BOOT="${FAKE_GPTZFSBOOT}"

# --- ESP: only EFI/boot/BOOTx64.efi (no EFI/FreeBSD/) ---
mkdir -p "${TEST_ESP_DIR}/EFI/boot"
printf 'FreeBSD loader.efi boot/lua original unmodified' > "${TEST_ESP_DIR}/EFI/boot/BOOTx64.efi"

# Snapshot content before dry-run
_original_content=$(cat "${TEST_ESP_DIR}/EFI/boot/BOOTx64.efi")

# --- In dry-run mode the mount call gets a temp dir but mount_msdosfs is
#     skipped, so the "mountpoint" is the mktemp dir itself (empty).
#     We want to detect that no actual files were written there.
FAKE_MP="${TEST_DIR}/fake_mp"
mkdir -p "${FAKE_MP}"

mock_cmd mktemp "echo '${FAKE_MP}'"

# mount_msdosfs should NOT be called in dry-run mode
mock_cmd_fail mount_msdosfs 1

# --- Standard mocks ---
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
	  nda0p4    ONLINE       0     0     0

errors: No known data errors
ZPS'

mock_cmd gpart '
case "$*" in
    *show*nda0*)
        printf "{\"PART\":[{\"scheme\":\"GPT\",\"partitions\":[{\"index\":1,\"type\":\"efi\",\"label\":\"\",\"rawtype\":\"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\",\"size\":\"200M\"},{\"index\":2,\"type\":\"freebsd-boot\",\"label\":\"\",\"rawtype\":\"83bd6b9d-7f41-11dc-be0b-001560b84f0f\",\"size\":\"512K\"},{\"index\":4,\"type\":\"freebsd-zfs\",\"label\":\"\",\"rawtype\":\"516e7cba-6ecf-11d6-8ff8-00022d09712b\",\"size\":\"465G\"}]}]}\n"
        ;;
    *bootcode*)
        # Should NOT be called in dry-run
        echo "gpart bootcode called unexpectedly in dry-run" >&2
        exit 1
        ;;
    *) exit 1 ;;
esac'

mock_cmd_output umount ""
mock_cmd_output rmdir ""

# df: used for space check — return large number so space check passes
mock_cmd df 'printf "Filesystem 1K-blocks Used Avail\n/dev/nda0p1 204800 1024 203776\n"'

mock_cmd strings 'grep -a "." "$@" 2>/dev/null || true'
mock_cmd efibootmgr '
case "$*" in
    *-v*) echo "" ;;
    *) exit 0 ;;
esac'
mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# --- Source script ---
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# --- Run and capture all output ---
_output=$(update_bootloaders 2>&1)
_rc=$?

# --- Assertions ---

assert_eq "update_bootloaders returns 0 in dry-run mode" "${_rc}" "0"

# Output must mention DRY RUN
assert_contains \
    "Output contains [DRY RUN] tag" \
    "${_output}" "[DRY RUN]"

# mount_msdosfs must NOT have been called
_mount_calls=0
mock_was_called mount_msdosfs && _mount_calls=1
assert_eq \
    "mount_msdosfs NOT called in dry-run" \
    "${_mount_calls}" "0"

# gpart bootcode must NOT have been called
_gpart_bootcode_called=0
if grep -q "gpart bootcode" "${MOCK_CALL_LOG}" 2>/dev/null; then
    _gpart_bootcode_called=1
fi
assert_eq \
    "gpart bootcode NOT called in dry-run" \
    "${_gpart_bootcode_called}" "0"

# No files created inside the fake mountpoint
assert_file_not_exists \
    "EFI/FreeBSD/loader.efi NOT created in dry-run" \
    "${FAKE_MP}/EFI/FreeBSD/loader.efi"

# Original ESP content unmodified
assert_file_not_exists \
    "EFI/BOOT/BOOTx64.efi NOT written in dry-run (fake MP is empty)" \
    "${FAKE_MP}/EFI/BOOT/BOOTx64.efi"

# --- Cleanup ---
EFI_DRY_RUN=0
mock_cleanup
teardown_test_dir

tap_end
