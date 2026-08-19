#!/bin/sh
# test_03_root_fs_type.sh - Tests for efi_root_fs_type
#
# Verifies that efi_root_fs_type correctly extracts the filesystem type of the
# root filesystem from mount(8) output for both formats:
#
#   FreeBSD: "device on mountpoint (fstype, opts)"
#     field 3 = mountpoint, field 4 = "(fstype," -> strip parens/comma
#
#   Linux:   "device on mountpoint type fstype (opts)"
#     field 3 = mountpoint, field 4 = "type", field 5 = fstype

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

mock_init

_dummy_loader="$(mktemp)"
printf 'dummy' > "${_dummy_loader}"
EFI_LOADER_SRC="${_dummy_loader}"
export EFI_LOADER_SRC

mock_cmd_output sysctl "0"
mock_cmd_output id "0"

. "${SRC_DIR}/efi_bootloader_update.sh"

tap_begin 8

# ── FreeBSD mount(8) format ────────────────────────────────────────────────────

# Test 1: FreeBSD ZFS root
mock_cmd mount 'printf "zroot/ROOT/default on / (zfs, local, noatime, nfsv4acls)\ndevfs on /dev (devfs, multilabel)\n"'
assert_eq "FreeBSD format: zfs at / -> returns zfs" \
    "$(efi_root_fs_type)" "zfs"

# Test 2: FreeBSD UFS root
mock_cmd mount 'printf "/dev/ada0p2 on / (ufs, local, noatime)\ndevfs on /dev (devfs, multilabel)\n"'
assert_eq "FreeBSD format: ufs at / -> returns ufs" \
    "$(efi_root_fs_type)" "ufs"

# Test 3: FreeBSD — / is not the first entry
mock_cmd mount 'printf "devfs on /dev (devfs, multilabel)\nzroot/ROOT/default on / (zfs, local, noatime)\nzroot/tmp on /tmp (zfs, local)\n"'
assert_eq "FreeBSD format: / not first entry -> still finds correct type" \
    "$(efi_root_fs_type)" "zfs"

# Test 4: FreeBSD — FS type with no trailing comma (single option)
mock_cmd mount 'printf "zroot/ROOT/default on / (zfs)\ndevfs on /dev (devfs)\n"'
assert_eq "FreeBSD format: fstype with no trailing comma -> returns zfs" \
    "$(efi_root_fs_type)" "zfs"

# ── Linux mount format ─────────────────────────────────────────────────────────

# Test 5: Linux ZFS root
mock_cmd mount 'printf "zroot/ROOT/default on / type zfs (rw,relatime)\ndevtmpfs on /dev type devtmpfs (rw)\n"'
assert_eq "Linux format: zfs at / -> returns zfs" \
    "$(efi_root_fs_type)" "zfs"

# Test 6: Linux UFS root
mock_cmd mount 'printf "/dev/ada0p2 on / type ufs (rw,noatime)\ndevtmpfs on /dev type devtmpfs (rw)\n"'
assert_eq "Linux format: ufs at / -> returns ufs" \
    "$(efi_root_fs_type)" "ufs"

# Test 7: Linux tmpfs root (edge case)
mock_cmd mount 'printf "tmpfs on / type tmpfs (rw,size=512m)\ndevtmpfs on /dev type devtmpfs (rw)\n"'
assert_eq "Linux format: tmpfs at / -> returns tmpfs" \
    "$(efi_root_fs_type)" "tmpfs"

# Test 8: Linux — / is not the first entry
mock_cmd mount 'printf "devtmpfs on /dev type devtmpfs (rw)\nprocfs on /proc type proc (rw)\nzroot/ROOT/default on / type zfs (rw,relatime)\nnullfs on /compat type nullfs (rw)\n"'
assert_eq "Linux format: / not first entry -> still finds correct type" \
    "$(efi_root_fs_type)" "zfs"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
