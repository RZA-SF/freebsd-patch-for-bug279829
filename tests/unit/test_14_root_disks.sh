#!/bin/sh
# test_14_root_disks.sh - Tests for efi_root_disks
#
# efi_root_disks returns disk names (one per line) hosting the current root
# filesystem.  Supports ZFS (parses zpool status) and UFS (parses mount output).
# Both ZFS and UFS paths resolve GEOM label aliases (gpt/, diskid/, gptid/, ufs/) via realpath.
# mount --libxo json uses "special" for the source device on all supported FreeBSD versions.
#
# 28 assertions
#
# R-16 note: diskid/ vdevs and root devices are now returned as "diskid/DISK-xxx"
# directly — no kern.disks UUID scan needed.  Tests 27-29 validate this.

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

tap_begin 28

# ── ZFS cases ─────────────────────────────────────────────────────────────────

# Test 1: ZFS single disk: nda0p4 -> result contains "nda0"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
_result="$(efi_root_disks zfs 2>/dev/null)"
assert_contains "ZFS single disk: result contains nda0" "${_result}" "nda0"

# Test 2: ZFS mirror: nda0p4 and nda1p4 -> both disks in result
# The mirror fixture uses da0/da1 but we need nda0/nda1 for this test
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
_result="$(efi_root_disks zfs 2>/dev/null)"
assert_contains "ZFS mirror: result contains nda0" "${_result}" "nda0"
assert_contains "ZFS mirror: result contains nda1" "${_result}" "nda1"

# Test 3: ZFS RAIDz: da0p3, da1p3, da2p3 -> all three disks in result
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"data/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool '
cat <<ZPS
  pool: data
 state: ONLINE
config:

	NAME        STATE     READ WRITE CKSUM
	data        ONLINE       0     0     0
	  raidz1-0  ONLINE       0     0     0
	    da0p3   ONLINE       0     0     0
	    da1p3   ONLINE       0     0     0
	    da2p3   ONLINE       0     0     0

errors: No known data errors
ZPS'
_result="$(efi_root_disks zfs 2>/dev/null)"
assert_contains "ZFS RAIDz: result contains da0" "${_result}" "da0"
assert_contains "ZFS RAIDz: result contains da1" "${_result}" "da1"
assert_contains "ZFS RAIDz: result contains da2" "${_result}" "da2"

# Test 4: ZFS pool name extraction: "zroot/ROOT/default" -> zpool called with "status zroot"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
efi_root_disks zfs >/dev/null 2>&1
_zpool_args=$(mock_last_args zpool)
assert_contains "ZFS pool name extraction: zpool called with 'status zroot'" \
    "${_zpool_args}" "zroot"

# Test 5: ZFS with cache/log: nda0p4 (data), nda1p2 (log), nda2p2 (cache)
# nda0 must be in result; log/cache devices are scanned but won't have ESPs
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_with_cache.txt\""
_result="$(efi_root_disks zfs 2>/dev/null)"
assert_contains "ZFS with cache/log: nda0 (data disk) in result" "${_result}" "nda0"

# Test 6: ZFS zpool status fails -> returns 1
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd_fail zpool 1
_rc=0
efi_root_disks zfs 2>/dev/null || _rc=$?
assert_ne "ZFS zpool status fails: returns non-zero" "${_rc}" "0"

# Test 7: ZFS mount fails (empty pool name) -> returns 1
mock_cmd_fail mount 1
_rc=0
efi_root_disks zfs 2>/dev/null || _rc=$?
assert_ne "ZFS mount fails: returns non-zero" "${_rc}" "0"

# ── UFS cases ─────────────────────────────────────────────────────────────────

# Test 8: UFS root device /dev/ada0p3 -> result is "ada0"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"/dev/ada0p3\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"rw\"]}]}}\n"'
_result="$(efi_root_disks ufs 2>/dev/null)"
assert_eq "UFS /dev/ada0p3 -> ada0" "${_result}" "ada0"

# Test 9: UFS root device /dev/mmcsd0s1 -> result is "mmcsd0"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"/dev/mmcsd0s1\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"rw\"]}]}}\n"'
_result="$(efi_root_disks ufs 2>/dev/null)"
assert_eq "UFS /dev/mmcsd0s1 -> mmcsd0" "${_result}" "mmcsd0"

# Test 10: UFS root device /dev/da0 (no partition suffix) -> result is "da0"
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"/dev/da0\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"rw\"]}]}}\n"'
_result="$(efi_root_disks ufs 2>/dev/null)"
assert_eq "UFS /dev/da0 (no suffix) -> da0" "${_result}" "da0"

# ── Unknown / error cases ─────────────────────────────────────────────────────

# Test 11: Unknown root type "tmpfs" -> returns 1
_rc=0
efi_root_disks tmpfs 2>/dev/null || _rc=$?
assert_ne "Unknown root type 'tmpfs': returns non-zero" "${_rc}" "0"

# Test 12: ZFS with diskid member: realpath resolves to /dev/nda0p4
# Mock realpath to return the resolved device path
mock_cmd realpath 'echo "/dev/nda0p4"'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME                    STATE     READ WRITE CKSUM
	zroot                   ONLINE       0     0     0
	  diskid/DISK-abc123p4  ONLINE       0     0     0

errors: No known data errors
ZPS'
_result="$(efi_root_disks zfs 2>/dev/null)"
assert_contains "ZFS diskid member: realpath resolves to nda0" "${_result}" "nda0"

# ── UFS GEOM label / alias resolution (M3 regression) ────────────────────────

# Test 13: UFS root mounted via GPT label "gpt/PBaseUFS" -> realpath resolves
# to /dev/ada0p3 -> strip suffix -> "ada0"
# This is markmi's M3 bug: mount --libxo json reports "gpt/PBaseUFS" and the
# old code returned "gpt/PBaseUFS" unchanged, which gpart cannot use as a disk.
mock_cmd realpath 'echo "/dev/ada0p3"'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"/dev/gpt/PBaseUFS\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"rw\"]}]}}\n"'
_result="$(efi_root_disks ufs 2>/dev/null)"
assert_eq "UFS gpt/PBaseUFS label: realpath resolves to ada0" "${_result}" "ada0"

# Test 14: UFS root mounted via diskid alias -> realpath resolves to /dev/nda0p3
# -> strip suffix -> "nda0"
mock_cmd realpath 'echo "/dev/nda0p3"'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"/dev/diskid/DISK-abc123p3\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"rw\"]}]}}\n"'
_result="$(efi_root_disks ufs 2>/dev/null)"
assert_eq "UFS diskid alias: realpath resolves to nda0" "${_result}" "nda0"

# ── Regression: "special" field in mount --libxo json ────────────────────────
# mount --libxo json uses "special" for the source device on all FreeBSD versions
# that support libxo (13.1+).  Earlier code incorrectly used "from" (a field
# that never existed); these tests guard against that regression.

# Test 15: ZFS FreeBSD 14+ "special" field: pool name extraction works
mock_cmd realpath 'echo "/dev/nda0p4"'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"local\",\"noatime\",\"nfsv4acls\"]}]}}\n"'
mock_cmd zpool "cat \"${FIXTURES_DIR}/zpool_status_single.txt\""
_result="$(efi_root_disks zfs 2>/dev/null)"
assert_contains "ZFS FreeBSD14+ 'special' field: result contains nda0" "${_result}" "nda0"

# Test 16: UFS FreeBSD 14+ "special" field: root device extraction works
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"/dev/ada0p3\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"local\",\"soft-updates\"]}]}}\n"'
_result="$(efi_root_disks ufs 2>/dev/null)"
assert_eq "UFS FreeBSD14+ 'special' field: /dev/ada0p3 -> ada0" "${_result}" "ada0"

# Test 17: UFS FreeBSD 14+ "special" with /dev/ prefix stripped: mmcsd0s1 -> mmcsd0
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"/dev/mmcsd0s1\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"local\"]}]}}\n"'
_result="$(efi_root_disks ufs 2>/dev/null)"
assert_eq "UFS FreeBSD14+ 'special' field: /dev/mmcsd0s1 -> mmcsd0" "${_result}" "mmcsd0"

# ── glabel status fallback when realpath returns unchanged (R-08 regression) ──
# On newer FreeBSD kernels, /dev/gpt/X and /dev/diskid/X are GEOM device nodes,
# not symlinks.  realpath(1) returns the path unchanged.  glabel status is used
# to find the backing partition in that case.

# Test 22: UFS gpt/PBaseUFS — realpath returns unchanged → glabel resolves to
# mmcsd0p2 → strip suffix → mmcsd0  (WDK23 arm64 failure mode)
mock_cmd realpath 'echo "/dev/gpt/PBaseUFS"'
mock_cmd glabel 'printf "                 Name  Status  Components\ngpt/PBaseUFS     N/A  mmcsd0p2\n"'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"/dev/gpt/PBaseUFS\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"rw\"]}]}}\n"'
_result="$(efi_root_disks ufs 2>/dev/null)"
assert_eq "UFS gpt/PBaseUFS: realpath unchanged, glabel resolves to mmcsd0" "${_result}" "mmcsd0"

# ── ZFS gpt/ label vdev (R-07 regression) ────────────────────────────────────
# markmi's amd64: zpool zoptb has sole vdev gpt/OptBzfs (GPT label, no digit).
# Old awk filter "$1 ~ /[0-9]/" excluded it; fixed by comparing $1 != pool.

# Test 23: ZFS gpt/LABEL vdev: realpath resolves gpt/OptBzfs -> /dev/nda2p3 -> nda2
mock_cmd realpath 'echo "/dev/nda2p3"'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zoptb/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool '
cat <<ZPS
  pool: zoptb
 state: ONLINE
config:

	NAME           STATE     READ WRITE CKSUM
	zoptb          ONLINE       0     0     0
	  gpt/OptBzfs  ONLINE       0     0     0

errors: No known data errors
ZPS'
_result="$(efi_root_disks zfs 2>/dev/null)"
assert_eq "ZFS gpt/OptBzfs vdev: realpath resolves to nda2" "${_result}" "nda2"

# Test 24: ZFS gpt/LABEL vdev — realpath returns unchanged → glabel resolves
# to nda2p3 → strip suffix → nda2  (same root cause as WDK23 UFS failure)
mock_cmd realpath 'echo "/dev/gpt/OptBzfs"'
mock_cmd glabel 'printf "                 Name  Status  Components\ngpt/OptBzfs     N/A  nda2p3\n"'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zoptb/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool '
cat <<ZPS
  pool: zoptb
 state: ONLINE
config:

	NAME           STATE     READ WRITE CKSUM
	zoptb          ONLINE       0     0     0
	  gpt/OptBzfs  ONLINE       0     0     0

errors: No known data errors
ZPS'
_result="$(efi_root_disks zfs 2>/dev/null)"
assert_eq "ZFS gpt/OptBzfs: realpath unchanged, glabel resolves to nda2" "${_result}" "nda2"

# ── ufs/ GEOM label resolution (R-09 regression) ─────────────────────────────
# On MBR systems the root UFS filesystem is commonly mounted via a ufs/ GEOM
# label (e.g. /dev/ufs/rootfs -> da0s2a).  The ufs/ prefix must be handled the
# same way as gpt/ so that realpath + glabel fallback are applied.  The partition
# suffix sed must also strip the MBR BSD-label letter (s2a -> da0, not da0s2a).

# Test 25: UFS ufs/rootfs — realpath returns unchanged (device node) ->
# glabel resolves to da0s2a -> MBR BSD suffix stripped -> da0
# This is the RPi4B MBR failure mode (R-09).
mock_cmd realpath 'echo "/dev/ufs/rootfs"'
mock_cmd glabel 'printf "                 Name  Status  Components\nufs/rootfs     N/A  da0s2a\n"'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"/dev/ufs/rootfs\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"rw\"]}]}}\n"'
_result="$(efi_root_disks ufs 2>/dev/null)"
assert_eq "UFS ufs/rootfs: realpath unchanged, glabel resolves to da0" "${_result}" "da0"

# Test 26: UFS ufs/rootfs — realpath resolves symlink to /dev/da0s2a ->
# sed strips MBR BSD suffix s2a -> da0
# Tests the sed fix (require >=1 digit) on the already-resolved path.
mock_cmd realpath 'echo "/dev/da0s2a"'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"/dev/ufs/rootfs\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"rw\"]}]}}\n"'
_result="$(efi_root_disks ufs 2>/dev/null)"
assert_eq "UFS ufs/rootfs: realpath resolves to da0s2a, sed strips s2a -> da0" "${_result}" "da0"

# ── R-16: diskid vdev/device — use diskid provider name directly ─────────────
# geom_diskid(4) labels do not appear in glabel(8) status.  When realpath(1)
# returns a /dev/diskid/* path unchanged (device node on newer kernels), the
# code strips the partition suffix and returns the diskid provider base name
# directly (e.g. "diskid/DISK-abc123").  gpart list/show and partition device
# paths (/dev/diskid/DISK-abc123p1) accept diskid names on all FreeBSD versions.
# No kern.disks UUID scan is needed.

# Test 27: ZFS diskid vdev without partition suffix — realpath unchanged →
# returns diskid provider name "diskid/DISK-abc123" directly.
mock_cmd realpath 'echo "/dev/diskid/DISK-abc123"'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME                   STATE     READ WRITE CKSUM
	zroot                  ONLINE       0     0     0
	  diskid/DISK-abc123   ONLINE       0     0     0

errors: No known data errors
ZPS'
_result="$(efi_root_disks zfs 2>/dev/null)"
assert_eq "ZFS diskid: realpath unchanged, returns diskid/DISK-abc123 directly" "${_result}" "diskid/DISK-abc123"

# Test 28: UFS diskid root device — realpath unchanged, partition suffix
# stripped from p3.  Returns "diskid/DISK-abc123".
mock_cmd realpath 'echo "/dev/diskid/DISK-abc123p3"'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"/dev/diskid/DISK-abc123p3\",\"node\":\"/\",\"fstype\":\"ufs\",\"opts\":[\"rw\"]}]}}\n"'
_result="$(efi_root_disks ufs 2>/dev/null)"
assert_eq "UFS diskid: realpath unchanged, partition suffix stripped → diskid/DISK-abc123" "${_result}" "diskid/DISK-abc123"

# Test 29: ZFS diskid vdev WITH partition suffix (Stefan's FreeBSD-CURRENT
# topology: vdev = diskid/DISK-8ESKFxxxp2).  gpart list of short disk name
# (nda0) returns empty — R-16 must not call it.  Returns "diskid/DISK-abc123".
mock_cmd realpath 'echo "/dev/diskid/DISK-abc123p2"'
mock_cmd gpart 'case "$*" in
    *"list nda0"*) : ;;   # empty — simulates FreeBSD-CURRENT behaviour
esac'
mock_cmd sysctl 'case "$*" in *kern.disks*) echo "nda0" ;; *) echo "0" ;; esac'
mock_cmd mount 'printf "{\"mount\":{\"mounted\":[{\"special\":\"zroot/ROOT/default\",\"node\":\"/\",\"fstype\":\"zfs\",\"opts\":[\"rw\"]}]}}\n"'
mock_cmd zpool '
cat <<ZPS
  pool: zroot
 state: ONLINE
config:

	NAME                     STATE     READ WRITE CKSUM
	zroot                    ONLINE       0     0     0
	  diskid/DISK-abc123p2   ONLINE       0     0     0

errors: No known data errors
ZPS'
_result="$(efi_root_disks zfs 2>/dev/null)"
assert_eq "ZFS diskid p2 suffix (Stefan topology): R-16 returns diskid/DISK-abc123 without gpart list" "${_result}" "diskid/DISK-abc123"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
