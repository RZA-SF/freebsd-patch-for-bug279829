#!/bin/sh
# test_15_boot_esps.sh - Tests for efi_boot_esps
#
# efi_boot_esps identifies EFI System Partitions belonging to the current
# system via the union of BootCurrent NVRAM variable and root filesystem disks.
#
# 27 assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

FIXTURES_DIR="${TESTS_DIR}/fixtures"

mock_init

mock_cmd_output id "0"
mock_cmd_output sysctl "0"

_dummy_loader="$(mktemp)"
printf 'dummy' > "${_dummy_loader}"
EFI_LOADER_SRC="${_dummy_loader}"
export EFI_LOADER_SRC

. "${SRC_DIR}/efi_bootloader_update.sh"
# Simulate EFIRT present on Linux (where /dev/efi does not exist)
_EFI_DEV_EFI=/dev/null
export _EFI_DEV_EFI

tap_begin 27

# Helper: gpart show for nda0 (GPT, efi at index 1)
_gpart_show_nda0='
case "$*" in
    *list*nda0*) cat "'"${FIXTURES_DIR}/gpart_list_nda0.txt"'" ;;
    *list*nda1*) cat "'"${FIXTURES_DIR}/gpart_list_nda1.txt"'" ;;
    *show*nda0*)
        printf "=>       40  976773095  nda0  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640       1024     2  freebsd-boot  (512K)\n"
        printf "    8799272  967973820     4  freebsd-zfs  (462G)\n"
        ;;
    *show*nda1*)
        printf "=>       40  976773095  nda1  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640       1024     2  freebsd-boot  (512K)\n"
        printf "    8799272  967973820     4  freebsd-zfs  (462G)\n"
        ;;
    *) exit 1 ;;
esac'

# ── Test 1: BootCurrent path ───────────────────────────────────────────────────
# efibootmgr returns BootCurrent 0004 -> nda0p1 UUID -> gpart list matches -> "nda0 1 GPT"
mock_cmd efibootmgr "cat \"${FIXTURES_DIR}/efibootmgr_boot_nda0.txt\""
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart "${_gpart_show_nda0}"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
_result="$(efi_boot_esps 2>/dev/null)"
assert_eq "BootCurrent path: nda0 1 GPT found" "${_result}" "nda0 1 GPT"

# ── Test 2: BootCurrent + root_disks union deduplication ─────────────────────
# Same as test 1; both efibootmgr and zpool confirm nda0 -> deduped to single result
mock_cmd efibootmgr "cat \"${FIXTURES_DIR}/efibootmgr_boot_nda0.txt\""
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart "${_gpart_show_nda0}"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
_result="$(efi_boot_esps 2>/dev/null)"
_count=$(printf '%s\n' "${_result}" | grep -c "nda0 1 GPT" 2>/dev/null || echo 0)
assert_eq "BootCurrent+root_disks union: nda0 1 GPT deduped (appears once)" "${_count}" "1"

# ── Test 3: Mirror union: BootCurrent -> nda0; root_disks -> nda0 + nda1 ─────
# Result must contain both nda0 1 GPT and nda1 1 GPT
mock_cmd efibootmgr "cat \"${FIXTURES_DIR}/efibootmgr_boot_nda0.txt\""
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0 nda1" ;; *) echo "0" ;; esac'
mock_cmd gpart "${_gpart_show_nda0}"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME        STATE     READ WRITE CKSUM
	zroot       ONLINE       0     0     0
	  mirror-0  ONLINE       0     0     0
	    nda0p4  ONLINE       0     0     0
	    nda1p4  ONLINE       0     0     0

errors: No known data errors
ZPS'
_result="$(efi_boot_esps 2>/dev/null)"
assert_contains "Mirror: nda0 1 GPT found" "${_result}" "nda0 1 GPT"
assert_contains "Mirror: nda1 1 GPT found" "${_result}" "nda1 1 GPT"

# ── Test 4: efibootmgr not found -> fallback to root_disks ───────────────────
mock_cmd_fail efibootmgr 127
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart "${_gpart_show_nda0}"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
_result="$(efi_boot_esps 2>/dev/null)"
assert_eq "efibootmgr not found: fallback to root_disks gives nda0 1 GPT" \
    "${_result}" "nda0 1 GPT"

# ── Test 5: efibootmgr exits 0 but no BootCurrent line -> fallback ───────────
mock_cmd efibootmgr 'echo "Timeout: 3 seconds"'
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart "${_gpart_show_nda0}"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
_result="$(efi_boot_esps 2>/dev/null)"
assert_eq "No BootCurrent line: fallback to root_disks gives nda0 1 GPT" \
    "${_result}" "nda0 1 GPT"

# ── Test 6: BootCurrent PARTUUID doesn't match any disk -> fallback to root_disks
mock_cmd efibootmgr '
printf "BootCurrent: 0001\n"
printf "Boot0001* FreeBSD\tHD(1,GPT,99999999-ffff-ffff-ffff-000000000000,0x800,0x64000)/File(\\EFI\\FreeBSD\\loader.efi)\n"'
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart "${_gpart_show_nda0}"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
_result="$(efi_boot_esps 2>/dev/null)"
assert_eq "PARTUUID mismatch: fallback to root_disks gives nda0 1 GPT" \
    "${_result}" "nda0 1 GPT"

# ── Test 7: markmi scenario: BootCurrent -> da1 (FreeBSD); root_disks -> da1 ─
# nda0 (Windows) NOT in candidate_disks -> only "da1 1 GPT"
mock_cmd efibootmgr '
printf "BootCurrent: 0003\n"
printf "Boot0003* FreeBSD-da1\tHD(1,GPT,bbbbbbb1-0000-0000-0000-000000000001,0x800,0x64000)/File(\\EFI\\FreeBSD\\loader.efi)\n"
printf "Boot0000  Windows\tHD(1,GPT,aaaaaaaa-0000-0000-0000-000000000000,0x800,0x32000)/File(\\EFI\\MICROSOFT\\BOOT\\BOOTMGFW.EFI)\n"'
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "da1 nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart '
case "$*" in
    *list*da1*)
        printf "Geom name: da1\n"
        printf "1. Name: da1p1\n   rawuuid: bbbbbbb1-0000-0000-0000-000000000001\n   type: efi\n"
        ;;
    *list*nda0*)
        printf "Geom name: nda0\n"
        printf "1. Name: nda0p1\n   rawuuid: aaaaaaaa-0000-0000-0000-000000000000\n   type: efi\n"
        ;;
    *show*da1*)
        printf "=>       40  976773095  da1  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640  976363456     2  freebsd-zfs  (465G)\n"
        ;;
    *show*nda0*)
        printf "=>       40  976773095  nda0  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640  976363456     2  freebsd-zfs  (465G)\n"
        ;;
    *) exit 1 ;;
esac'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME      STATE     READ WRITE CKSUM
	zroot     ONLINE       0     0     0
	  da1p2   ONLINE       0     0     0

errors: No known data errors
ZPS'
_result="$(efi_boot_esps 2>/dev/null)"
assert_contains "markmi scenario: da1 ESP found" "${_result}" "da1 1 GPT"
# nda0 (Windows disk) must NOT appear
case "${_result}" in
    *"nda0"*) _nda0_found=1 ;;
    *)        _nda0_found=0 ;;
esac
assert_eq "markmi scenario: Windows disk nda0 NOT in result" "${_nda0_found}" "0"

# ── Test 8: imp scenario: BootCurrent -> usb0 (USB boot, has ESP); root -> nda0 (no ESP)
mock_cmd efibootmgr '
printf "BootCurrent: 0005\n"
printf "Boot0005* FreeBSD-USB\tHD(1,GPT,cccccccc-1111-2222-3333-444444444444,0x800,0x64000)/File(\\EFI\\FreeBSD\\loader.efi)\n"'
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "usb0 nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart '
case "$*" in
    *list*usb0*)
        printf "Geom name: usb0\n"
        printf "1. Name: usb0p1\n   rawuuid: cccccccc-1111-2222-3333-444444444444\n   type: efi\n"
        ;;
    *list*nda0*)
        printf "Geom name: nda0\n"
        printf "1. Name: nda0p1\n   rawuuid: 22223333-4444-5555-6666-777788889999\n   type: freebsd-zfs\n"
        ;;
    *show*usb0*)
        printf "=>       40  7340032  usb0  GPT  (3.5G)\n"
        printf "         40   204800     1  efi  (100M)\n"
        printf "     204840  7135192     2  freebsd-zfs  (3.4G)\n"
        ;;
    *show*nda0*)
        # NVMe pool disk - no ESP partition
        printf "=>       40  976773095  nda0  GPT  (466G)\n"
        printf "     204840  976568256     1  freebsd-zfs  (466G)\n"
        ;;
    *) exit 1 ;;
esac'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME      STATE     READ WRITE CKSUM
	zroot     ONLINE       0     0     0
	  nda0p1  ONLINE       0     0     0

errors: No known data errors
ZPS'
_result="$(efi_boot_esps 2>/dev/null)"
assert_contains "imp scenario: usb0 ESP found" "${_result}" "usb0 1 GPT"

# ── Test 9: MBR disk: root_disks -> mmcsd0; gpart show shows !12 type ─────────
mock_cmd_fail efibootmgr 127
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "0" ;; *) echo "0" ;; esac'
mock_cmd gpart '
case "$*" in
    *show*mmcsd0*)
        printf "=>       1  62333951  mmcsd0  MBR  (30G)\n"
        printf "          1      2048     1  !12  (1.0M)\n"
        printf "       2049  62331904     2  freebsd-ufs  (30G)\n"
        ;;
    *) exit 1 ;;
esac'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"/dev/mmcsd0s2\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"rw\"]}]}}\n"'
_result="$(efi_boot_esps 2>/dev/null)"
assert_eq "MBR disk: mmcsd0 1 MBR found" "${_result}" "mmcsd0 1 MBR"

# ── Test 10: No ESPs on any candidate disk -> returns 1 ───────────────────────
mock_cmd_fail efibootmgr 127
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "0" ;; *) echo "0" ;; esac'
mock_cmd gpart '
case "$*" in
    *show*nda0*)
        printf "=>       40  976773095  nda0  GPT  (466G)\n"
        printf "     204840  976568256     1  freebsd-zfs  (466G)\n"
        ;;
    *) exit 1 ;;
esac'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
_rc=0
efi_boot_esps 2>/dev/null || _rc=$?
assert_ne "No ESPs on candidate disks: returns non-zero" "${_rc}" "0"

# ── Test 11: root_disks fails AND BootCurrent fails -> returns 1 ──────────────
mock_cmd_fail efibootmgr 127
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "0" ;; *) echo "0" ;; esac'
mock_cmd_fail zpool 1
mock_cmd_fail mount 1
_rc=0
efi_boot_esps 2>/dev/null || _rc=$?
assert_ne "root_disks fails AND BootCurrent fails: returns non-zero" "${_rc}" "0"

# ── Test 12: sysctl kern.disks fails in BootCurrent PARTUUID loop ─────────────
# Falls back to root_disks which succeeds
mock_cmd efibootmgr "cat \"${FIXTURES_DIR}/efibootmgr_boot_nda0.txt\""
mock_cmd sysctl '
case "$*" in
    *kern.disks*) exit 1 ;;
    *) echo "0" ;;
esac'
mock_cmd gpart "${_gpart_show_nda0}"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
_result="$(efi_boot_esps 2>/dev/null)"
assert_eq "kern.disks fails in UUID loop: fallback to root_disks gives nda0 1 GPT" \
    "${_result}" "nda0 1 GPT"

# ── Test 13: gpart list fails for a disk -> skip that disk ────────────────────
mock_cmd efibootmgr "cat \"${FIXTURES_DIR}/efibootmgr_boot_nda0.txt\""
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0 cd0" ;; *) echo "0" ;; esac'
mock_cmd gpart '
case "$*" in
    *list*nda0*) cat "'"${FIXTURES_DIR}/gpart_list_nda0.txt"'" ;;
    *list*cd0*)  exit 1 ;;
    *show*nda0*)
        printf "=>       40  976773095  nda0  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640  976363456     2  freebsd-zfs  (465G)\n"
        ;;
    *) exit 1 ;;
esac'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
_result="$(efi_boot_esps 2>/dev/null)"
assert_eq "gpart list fails for cd0: nda0 still found" "${_result}" "nda0 1 GPT"

# ── Test 14: UFS root_disks -> ada0; ESP on ada0p1 -> "ada0 1 GPT" ───────────
mock_cmd_fail efibootmgr 127
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "0" ;; *) echo "0" ;; esac'
mock_cmd gpart '
case "$*" in
    *show*ada0*)
        printf "=>       40  976773095  ada0  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640       1024     2  freebsd-boot  (512K)\n"
        printf "     410664  976363456     3  freebsd-ufs  (465G)\n"
        ;;
    *) exit 1 ;;
esac'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"/dev/ada0p3\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"rw\"]}]}}\n"'
_result="$(efi_boot_esps 2>/dev/null)"
assert_eq "UFS root ada0: ESP ada0 1 GPT found" "${_result}" "ada0 1 GPT"

# ── Test 15: BootCurrent with MBR HD() path (no GPT keyword) -> no PARTUUID ──
# Falls back to root_disks
mock_cmd efibootmgr '
printf "BootCurrent: 0001\n"
printf "Boot0001* FreeBSD\tHD(1,MBR,0x00000800,0x800,0x64000)/File(\\EFI\\FreeBSD\\loader.efi)\n"'
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart "${_gpart_show_nda0}"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
_result="$(efi_boot_esps 2>/dev/null)"
assert_eq "MBR HD() BootCurrent: fallback to root_disks gives nda0 1 GPT" \
    "${_result}" "nda0 1 GPT"

# ── Test 16: ESP on both root disks in mirror -> both output (deduped) ────────
mock_cmd_fail efibootmgr 127
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "0" ;; *) echo "0" ;; esac'
mock_cmd gpart '
case "$*" in
    *show*nda0*)
        printf "=>       40  976773095  nda0  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640  976363456     4  freebsd-zfs  (465G)\n"
        ;;
    *show*nda1*)
        printf "=>       40  976773095  nda1  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "     409640  976363456     4  freebsd-zfs  (465G)\n"
        ;;
    *) exit 1 ;;
esac'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME        STATE     READ WRITE CKSUM
	zroot       ONLINE       0     0     0
	  mirror-0  ONLINE       0     0     0
	    nda0p4  ONLINE       0     0     0
	    nda1p4  ONLINE       0     0     0

errors: No known data errors
ZPS'
_result="$(efi_boot_esps 2>/dev/null)"
assert_contains "Mirror both root disks: nda0 1 GPT found" "${_result}" "nda0 1 GPT"
assert_contains "Mirror both root disks: nda1 1 GPT found" "${_result}" "nda1 1 GPT"

# ── Test 17: efibootmgr -v with +Boot prefix on BootCurrent entry ─────────────
# Real efibootmgr prefixes the currently-booted entry with '+' and other active
# entries with a leading space.  The grep must match without a '^' anchor.
mock_cmd efibootmgr '
printf "BootCurrent: 0004\n"
printf " Boot0001  Windows Boot Manager\tHD(1,GPT,99990000-1234-5678-abcd-ef0123456789,0x800,0x32000)/File(\\EFI\\MICROSOFT\\BOOT\\BOOTMGFW.EFI)\n"
printf "+Boot0004* FreeBSD\tHD(1,GPT,aaaabbbb-1111-2222-3333-444455556666,0x800,0x64000)/File(\\EFI\\FreeBSD\\loader.efi)\n"'
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart "${_gpart_show_nda0}"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
_result="$(efi_boot_esps 2>/dev/null)"
assert_eq "+Boot prefix: PARTUUID extracted; nda0 1 GPT found" "${_result}" "nda0 1 GPT"

# ── Test 18: efibootmgr -v output with no HD() device paths -> fallback ────────
# Matches markmi's amd64: all Boot entries are bare descriptions ("UEFI OS")
# with no HD(N,GPT,...) device path.  PARTUUID extraction produces empty;
# falls through to root_disks heuristic.
mock_cmd efibootmgr '
printf "Boot to FW : false\n"
printf "BootCurrent: 0004\n"
printf "Timeout    : 1 seconds\n"
printf "BootOrder  : 0000, 0002, 0004\n"
printf " Boot0000* Windows Boot Manager\n"
printf " Boot0002* UEFI OS\n"
printf "+Boot0004* UEFI OS\n"'
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart "${_gpart_show_nda0}"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
_result="$(efi_boot_esps 2>/dev/null)"
assert_eq "No HD() paths in entries: fallback to root_disks gives nda0 1 GPT" \
    "${_result}" "nda0 1 GPT"

# ── Test 22: efibootmgr -v dp:-line format (markmi amd64) ─────────────────────
# Some systems emit the EFI device path on a separate "dp:" sub-line below the
# boot entry description, rather than inline on the same line.  PARTUUID must
# still be extracted correctly.
mock_cmd efibootmgr "cat \"${FIXTURES_DIR}/efibootmgr_boot_nda0_dpline.txt\""
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd gpart "${_gpart_show_nda0}"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
_result="$(efi_boot_esps 2>/dev/null)"
assert_eq "dp:-line format: PARTUUID extracted from sub-line; nda0 1 GPT found" \
    "${_result}" "nda0 1 GPT"

# ── Test 23: MBR disk with fat32lba type (R-09 regression) ───────────────────
# gpart uses the symbolic name "fat32lba" for MBR type 0x0C; the earlier check
# for "!12" never matched any real install.  Verify fat32lba is recognised.
mock_cmd_fail efibootmgr 127
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "0" ;; *) echo "0" ;; esac'
mock_cmd gpart '
case "$*" in
    *show*da0*)
        printf "=>      63  61439937  da0  MBR  (29G)\n"
        printf "      2048    102400    1  fat32lba  [active]  (50M)\n"
        printf "    104448  61335552    2  freebsd  (29G)\n"
        ;;
    *) exit 1 ;;
esac'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"/dev/ufs/rootfs\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd realpath 'echo "/dev/ufs/rootfs"'
mock_cmd glabel 'printf "                 Name  Status  Components\nufs/rootfs     N/A  da0s2a\n"'
_result="$(efi_boot_esps 2>/dev/null)"
assert_eq "MBR fat32lba type: da0 1 MBR found" "${_result}" "da0 1 MBR"

# ── Test 24: Split-media — BootCurrent disk (nda0) NOT in root disks (ada0) ──
# When BootCurrent identifies nda0 as the boot disk but the root filesystem
# is on a different disk (ada0), nda0 is NOT a root disk member.  Only nda0's
# ESP should be returned; ada0's ESP must not appear (it may belong to another
# system on the shared root media).
mock_cmd efibootmgr "cat \"${FIXTURES_DIR}/efibootmgr_boot_nda0.txt\""
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0 ada0" ;; *) echo "0" ;; esac'
mock_cmd gpart '
case "$*" in
    *list*nda0*) cat "'"${FIXTURES_DIR}/gpart_list_nda0.txt"'" ;;
    *list*ada0*)
        # ada0 has a different UUID — not the boot disk
        printf "   nda0p1:\n"
        printf "      Name: ada0p1\n"
        printf "      Mediasize: 209715200 (200M)\n"
        printf "      rawuuid: bbbbbbbb-0000-0000-0000-000000000000\n"
        printf "      type: efi\n"
        ;;
    *show*nda0*)
        printf "=>       40  976773095  nda0  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "    8799272  967973820     4  freebsd-zfs  (462G)\n"
        ;;
    *show*ada0*)
        printf "=>       40  976773095  ada0  GPT  (466G)\n"
        printf "         40     409600     1  efi  (200M)\n"
        printf "    8799272  967973820     4  freebsd-zfs  (462G)\n"
        ;;
    *) exit 1 ;;
esac'
# Root FS is ada0 (different from BootCurrent boot disk nda0)
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool '
printf "  pool: zroot\n state: ONLINE\nconfig:\n\tNAME\tSTATE\n\tzroot\tONLINE\n\t  ada0p4\tONLINE\n"'
_result="$(efi_boot_esps 2>/dev/null)"
assert_eq "Split-media: only boot disk nda0 ESP found" "${_result}" "nda0 1 GPT"
_ada0_count=$(printf '%s\n' "${_result}" | grep -c "ada0")
assert_eq "Split-media: root disk ada0 ESP NOT included" "${_ada0_count}" "0"

# ── Test 25: Mirror — BootCurrent disk (nda0) IS in root disks (nda0+nda1) ──
# When BootCurrent identifies nda0 and nda0 is also a ZFS mirror member,
# the overlap check passes and both mirror members' ESPs are returned.
# (Validates that the split-media guard does not break mirror behavior.)
mock_cmd efibootmgr "cat \"${FIXTURES_DIR}/efibootmgr_boot_nda0.txt\""
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0 nda1" ;; *) echo "0" ;; esac'
mock_cmd gpart "${_gpart_show_nda0}"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool '
printf "  pool: zroot\n state: ONLINE\nconfig:\n\tNAME\tSTATE\n\tzroot\tONLINE\n\t  nda0p4\tONLINE\n\t  nda1p4\tONLINE\n"'
_result="$(efi_boot_esps 2>/dev/null)"
assert_contains "Mirror+overlap: nda0 1 GPT found" "${_result}" "nda0 1 GPT"
assert_contains "Mirror+overlap: nda1 1 GPT also found" "${_result}" "nda1 1 GPT"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
