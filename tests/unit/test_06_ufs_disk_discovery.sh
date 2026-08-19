#!/bin/sh
# test_06_ufs_disk_discovery.sh - Tests for efi_ufs_boot_disks
#
# Verifies that the root device is correctly extracted from /etc/fstab and
# that partition/slice suffixes are stripped to yield a bare disk name.
#
# Strategy: the function calls `awk PROGRAM /etc/fstab`.  We intercept by
# writing a mock `awk` that forwards the awk program ($1) to the real awk but
# reads from a per-test temp fstab file whose path is baked into the mock
# script at creation time.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

mock_init

mock_cmd_output id "0"
mock_cmd_output sysctl "0"

_dummy_loader="$(mktemp)"
printf 'dummy' > "${_dummy_loader}"
EFI_LOADER_SRC="${_dummy_loader}"
export EFI_LOADER_SRC

. "${SRC_DIR}/efi_bootloader_update.sh"

# Locate the real awk binary before we shadow it in PATH.
_REAL_AWK="$(command -v awk)"

# Create a temporary directory to hold test fstab files.
_tmpdir="$(mktemp -d)"

# Helper: install an awk mock that forwards the program argument ($1) to the
# real awk but reads from FSTAB_PATH instead of any file argument.
# The path is expanded at mock-creation time so it survives subshell calls.
_install_awk_mock() {
    _fstab_path="$1"
    cat > "${MOCK_BIN}/awk" << MOCK_EOF
#!/bin/sh
echo "awk \$*" >> "\${MOCK_CALL_LOG}"
${_REAL_AWK} "\$1" "${_fstab_path}"
MOCK_EOF
    chmod +x "${MOCK_BIN}/awk"
    hash -r 2>/dev/null || true
}

tap_begin 3

# Test 1: /dev/ada0p2 as root -> returns "ada0"
_fstab1="${_tmpdir}/fstab1"
printf '/dev/ada0p2\t/\tufs\trw\t1\t1\n' > "${_fstab1}"
printf '/dev/ada0p3\tnone\tswap\tsw\t0\t0\n' >> "${_fstab1}"
_install_awk_mock "${_fstab1}"
_result="$(efi_ufs_boot_disks 2>/dev/null)"
assert_eq "/dev/ada0p2 root -> disk is ada0" "${_result}" "ada0"

# Test 2: /dev/nda0s1a as root -> returns "nda0"
_fstab2="${_tmpdir}/fstab2"
printf '/dev/nda0s1a\t/\tufs\trw\t1\t1\n' > "${_fstab2}"
printf '/dev/nda0s2\tnone\tswap\tsw\t0\t0\n' >> "${_fstab2}"
_install_awk_mock "${_fstab2}"
_result="$(efi_ufs_boot_disks 2>/dev/null)"
assert_eq "/dev/nda0s1a root -> disk is nda0" "${_result}" "nda0"

# Test 3: no root entry in fstab -> output is empty
_fstab3="${_tmpdir}/fstab3"
printf '/dev/ada0p3\tnone\tswap\tsw\t0\t0\n' > "${_fstab3}"
printf '/dev/ada0p4\t/usr\tufs\trw\t1\t2\n' >> "${_fstab3}"
_install_awk_mock "${_fstab3}"
_result="$(efi_ufs_boot_disks 2>/dev/null)"
assert_empty "no root entry -> output is empty" "${_result}"

tap_end

mock_cleanup
rm -f "${_dummy_loader}"
rm -rf "${_tmpdir}"
