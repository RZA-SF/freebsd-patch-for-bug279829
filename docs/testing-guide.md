# Testing Guide: FreeBSD Bootloader Update Test Suite

---

## 1. Overview

The test suite uses [TAP (Test Anything Protocol)](https://testanything.org/)
output so that results can be consumed by standard TAP harnesses (prove,
atf-check, Kyua).  Each test file is a standalone POSIX sh script that
sources two libraries from `tests/lib/`:

- `test_helpers.sh` — TAP output helpers (`tap_begin`, `assert_eq`, etc.) and
  ESP fixture builders (`setup_test_dir`, `make_esp_freebsd_only`, etc.)
- `mock_framework.sh` — PATH-injection mock framework (`mock_init`,
  `mock_cmd`, `mock_was_called`, `mock_call_count`, etc.)

Tests are organised into three suites:

| Suite | Directory | Purpose |
|---|---|---|
| Unit | `tests/unit/` | Individual functions in isolation |
| Integration | `tests/integration/` | Full `update_bootloaders` runs with fake ESPs |
| Error conditions | `tests/error_conditions/` | Failure paths and edge cases |

---

## 2. Running Tests on Linux (Development)

Linux is the recommended development platform because the test suite is
designed to run without FreeBSD-specific kernel modules or device nodes.

### 2.1 Prerequisites

```sh
# Required: POSIX sh (dash or bash in posix mode both work)
# Required: standard POSIX utilities (awk, grep, sed, sort, mktemp, etc.)
# Optional but recommended: shellcheck
apt-get install dash shellcheck   # Debian/Ubuntu
# or
dnf install dash ShellCheck        # Fedora/RHEL
```

The `strings` utility must be available (from `binutils` on Linux):
```sh
apt-get install binutils
```

### 2.2 Running the Full Suite

```sh
cd /path/to/freebsd-patch-for-bug279829
sh tests/run_tests.sh
```

Expected output format:
```
=== test_i01_single_disk_efi_bios.sh ===
1..8
ok 1 - update_bootloaders returns 0
ok 2 - EFI/FreeBSD/loader.efi created in fake mountpoint
...
# Passed: 8 / 8, Failed: 0, Skipped: 0

==============================
  Test Run Complete
==============================
  Files run:  25
  Files failed: 0
  Total tests: 130
  Passed:  130
  Failed:  0
  Skipped: 0
==============================
```

Exit code 0 means all tests passed.  Exit code 1 means at least one test
file failed or at least one test assertion failed.

### 2.3 Limitations on Linux

The following areas behave differently on Linux:

- **`mount_msdosfs`**: Not available on Linux.  All integration tests mock it
  via the PATH-injection mechanism.  Tests verify that the mock was or was not
  called, and manually copy ESP fixture data into the fake mountpoint.

- **`gpart`**: Not available on Linux.  All tests mock it to return fixture
  data from `tests/fixtures/`.

- **`efibootmgr`**: The Linux `efibootmgr` is a different tool from FreeBSD's.
  Tests mock it entirely to avoid calling the real tool.

- **`sysctl`**: The Linux `sysctl` exists but does not have
  `machdep.bootmethod` or `security.jail.jailed`.  All tests mock it.

- **`strings`** from GNU binutils behaves identically to FreeBSD's `strings`
  for the purposes of these tests.

In practice, the mock framework completely replaces these tools via PATH
injection, so the Linux equivalents are never called.

### 2.4 Running with a Specific Shell

To verify POSIX compliance with a strict shell:
```sh
# Run with dash (strictly POSIX)
sh tests/run_tests.sh    # uses /bin/sh which on Debian/Ubuntu is dash

# Run with bash in POSIX mode (catches some bash-isms)
bash --posix tests/run_tests.sh
```

### 2.5 Static Analysis with shellcheck

```sh
# Check the main script
shellcheck -s sh src/efi_bootloader_update.sh

# Check all test files
for f in tests/{unit,integration,error_conditions}/test_*.sh; do
    shellcheck -s sh "$f"
done

# Check test libraries
shellcheck -s sh tests/lib/test_helpers.sh tests/lib/mock_framework.sh
```

Treat all shellcheck warnings as errors before submission.  Use inline
`# shellcheck disable=SCNNNN` directives only when the warning is a known
false positive, and document why.

---

## 3. Running Tests on FreeBSD

FreeBSD is required for full validation, including real disk integration tests.
The automated test suite runs on FreeBSD without modification; the difference
is that real kernel facilities are available for manual validation.

### 3.1 Prerequisites

```sh
pkg install shellcheck
# strings is part of the base system on FreeBSD
# All other tools (gpart, mount_msdosfs, efibootmgr) are base system
```

### 3.2 Running the Automated Suite

Identical to Linux:
```sh
sh tests/run_tests.sh
```

The mock framework intercepts all system calls, so the automated tests do not
touch real disks even on FreeBSD.

### 3.3 Real-Disk Integration (Manual)

These tests require a FreeBSD test system (VM or spare hardware) and should
**never** be run on a production system without a tested backup.

#### Test 1: Dry-run on the current system

```sh
EFI_DRY_RUN=1 EFI_VERBOSE=1 sh src/efi_bootloader_update.sh
```

Expected: output shows `[DRY RUN]` for all actions; no files modified.
Verify by checking the mtime of files on the ESP:

```sh
mount_msdosfs /dev/nda0p1 /mnt/esp
ls -la /mnt/esp/EFI/FreeBSD/loader.efi
umount /mnt/esp
```

The mtime should not have changed.

#### Test 2: Real update on a test VM

1. Create a FreeBSD 14.1 VM with a ZFS root.
2. Note the current loader version: `efibootmgr -v` and `strings /boot/loader.efi | grep FreeBSD`.
3. Replace `/boot/loader.efi` with a different version (simulate an upgrade):
   ```sh
   # On a 14.2 host, scp the new loader to the 14.1 VM
   scp /boot/loader.efi testvm:/boot/loader.efi.new
   mv /boot/loader.efi.new /boot/loader.efi
   ```
4. Run the script:
   ```sh
   sh src/efi_bootloader_update.sh --verbose
   ```
5. Verify the ESP was updated:
   ```sh
   mount_msdosfs /dev/nda0p1 /mnt/esp
   strings /mnt/esp/EFI/FreeBSD/loader.efi | grep FreeBSD
   umount /mnt/esp
   ```
   The version string should match the new loader.

#### Test 3: Mirror pool — both disks updated

On a two-disk ZFS mirror VM:
```sh
sh src/efi_bootloader_update.sh --verbose 2>&1 | grep "Processing disk"
```
Expected: two "Processing disk:" lines, one for each disk.

Verify both ESPs:
```sh
for dev in nda0p1 nda1p1; do
    mount_msdosfs /dev/${dev} /mnt/esp
    md5 /mnt/esp/EFI/FreeBSD/loader.efi
    umount /mnt/esp
done
```
The MD5 checksums should match and match `/boot/loader.efi`.

#### Test 4: Shared ESP (dual-boot)

On a VM with both FreeBSD and a simulated Windows ESP (place a fake
`Windows Boot Manager Microsoft` binary at `/EFI/BOOT/BOOTx64.efi`):

```sh
sh src/efi_bootloader_update.sh --verbose 2>&1
```

Expected output includes a warning: "does not fingerprint as FreeBSD —
skipping."  Verify the fake Windows binary is unmodified.

---

## 4. Running Specific Test Subsets

The `run_tests.sh` runner supports three suite flags and an optional filter
pattern:

```sh
# Run only unit tests
sh tests/run_tests.sh --unit

# Run only integration tests
sh tests/run_tests.sh --integration

# Run only error condition tests
sh tests/run_tests.sh --errors

# Combine flags
sh tests/run_tests.sh --unit --errors

# Filter by test name pattern (applied after suite filter)
sh tests/run_tests.sh --integration i03

# Run a single test file directly
sh tests/integration/test_i03_zfs_mirror_two_disk.sh

# Run with verbose output from TAP harness
sh tests/run_tests.sh --integration 2>&1 | grep -E "^(ok|not ok|#)"
```

### 4.1 Running with `prove` (Perl TAP harness)

If `prove` is available (it is on most systems with Perl):

```sh
# Run all test files
prove -s tests/unit/test_*.sh tests/integration/test_*.sh \
         tests/error_conditions/test_*.sh

# Run a specific suite
prove -s tests/integration/test_*.sh

# Verbose mode
prove -vs tests/unit/test_*.sh
```

`prove` provides coloured output, timing information, and a concise summary.

---

## 5. Adding New Tests

### 5.1 Naming Convention

Test files follow a strict naming scheme:

| Suite | Prefix | Example |
|---|---|---|
| Unit | `test_u` + two-digit number + `_` + descriptive name | `test_u01_fallback_binary.sh` |
| Integration | `test_i` + two-digit number + `_` + descriptive name | `test_i11_raidz_three_disk.sh` |
| Error conditions | `test_e` + two-digit number + `_` + descriptive name | `test_e16_corrupt_esp.sh` |

Always use the next available number in the sequence to avoid gaps.

### 5.2 Test File Template

```sh
#!/bin/sh
# test_iNN_description.sh
#
# One-line description of what this test verifies.
#
# Detailed scenario:
#   - Setup conditions
#   - What the test does
#   - Expected outcomes
#
# N assertions

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${TESTS_DIR}/lib/test_helpers.sh"
. "${TESTS_DIR}/lib/mock_framework.sh"
SRC_DIR="$(cd "${TESTS_DIR}/../src" && pwd)"

tap_begin N   # Replace N with the actual number of assertions

setup_test_dir   # Creates TEST_DIR and TEST_ESP_DIR
mock_init        # Creates MOCK_BIN, prepends to PATH, creates MOCK_CALL_LOG

# --- Test-specific setup ---

# Create a fake loader with FreeBSD fingerprint strings
FAKE_LOADER="${TEST_DIR}/loader.efi"
printf 'FreeBSD loader.efi boot/lua test content' > "${FAKE_LOADER}"
export EFI_LOADER_SRC="${FAKE_LOADER}"

# Set up the fake ESP filesystem in TEST_ESP_DIR
# (use helpers from test_helpers.sh or build manually)
make_esp_freebsd_only amd64   # or make_esp_fallback_only, make_esp_other_os, make_esp_empty

# Create a fake mountpoint that mount_msdosfs will populate
FAKE_MP="${TEST_DIR}/fake_mp"
mkdir -p "${FAKE_MP}"

# Mock mktemp to return our known directory
mock_cmd mktemp "echo '${FAKE_MP}'"

# Mock mount_msdosfs to copy the ESP fixture into the fake mountpoint
mock_cmd mount_msdosfs "
cp -r '${TEST_ESP_DIR}/.' '${FAKE_MP}/'
exit 0"

# --- Standard system mocks (copy/adapt from existing tests) ---
mock_cmd_output id "0"
mock_cmd sysctl '
case "$*" in
    *security.jail.jailed*) echo "0" ;;
    *machdep.bootmethod*)   echo "UEFI" ;;
    *) echo "0" ;;
esac'
mock_cmd_output uname "amd64"
mock_cmd mount '
case "$*" in
    *msdosfs*) exit 0 ;;
    *) echo "zroot on / (zfs, local)" ;;
esac'
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
mock_cmd efibootmgr '
case "$*" in
    *-v*) echo "" ;;
    *-a*-c*) exit 0 ;;
    *) exit 0 ;;
esac'
mock_cmd_output sync ""
mock_cmd stat 'echo "512"'

# --- Source the script under test ---
# Always unset the guard variable first to allow re-sourcing
unset _EFI_BOOTLOADER_UPDATE_SH
. "${SRC_DIR}/efi_bootloader_update.sh"

# --- Run the function under test ---
update_bootloaders
_rc=$?

# --- Assertions ---
assert_eq "description of this assertion" "${_rc}" "0"
# ... more assertions ...

# --- Cleanup (always do this) ---
mock_cleanup
teardown_test_dir

tap_end
```

### 5.3 Using the Mock Framework

#### `mock_cmd NAME SCRIPT`

Creates an executable at `${MOCK_BIN}/NAME` that logs all invocations to
`MOCK_CALL_LOG` and then runs `SCRIPT`.  `SCRIPT` has access to `$*` for the
arguments passed to the command.

```sh
mock_cmd gpart '
case "$*" in
    *show*nda0*) cat /path/to/fixture ;;
    *bootcode*)  exit 0 ;;
    *)           exit 1 ;;
esac'
```

#### `mock_cmd_output NAME OUTPUT [EXIT_CODE]`

Shorthand: echoes `OUTPUT` and exits with `EXIT_CODE` (default 0).

```sh
mock_cmd_output id "0"          # simulates `id -u` returning 0
mock_cmd_output uname "amd64"   # simulates `uname -m`
```

#### `mock_cmd_fail NAME [EXIT_CODE]`

Shorthand: prints an error to stderr and exits with `EXIT_CODE` (default 1).
Use for commands that should fail in the scenario under test.

```sh
mock_cmd_fail mount_msdosfs 1   # mount always fails in this test
```

#### `mock_was_called NAME`

Returns 0 if `NAME` appears at least once in `MOCK_CALL_LOG`.

```sh
assert_true "mount_msdosfs was called" mock_was_called mount_msdosfs
```

#### `mock_call_count NAME`

Outputs the number of times `NAME` was called.

```sh
_count=$(mock_call_count gpart)
assert_eq "gpart called twice" "${_count}" "2"
```

#### `mock_last_args NAME`

Outputs the argument string from the last invocation of `NAME`.

```sh
_args=$(mock_last_args gpart)
assert_contains "gpart args include bootcode" "${_args}" "bootcode"
```

### 5.4 Variable Isolation

Each test file is run in a separate subshell by `run_tests.sh` (via
`sh "${_test_file}" 2>&1`).  Environment variables set in one test file do
not affect another.

Within a single test file, if you call `update_bootloaders` more than once
(unusual but allowed), be aware that:

- `_EFI_BOOTLOADER_UPDATE_SH` must be unset before re-sourcing the script.
- Mock state in `MOCK_CALL_LOG` accumulates across calls.  Use
  `mock_cleanup && mock_init` to reset between calls.
- `EFI_DRY_RUN`, `EFI_LOADER_SRC`, and other env vars must be explicitly
  reset between calls if the test changes them.

### 5.5 ESP Fixture Helpers

`test_helpers.sh` provides four ready-made ESP layouts:

| Helper | Creates |
|---|---|
| `make_esp_freebsd_only ARCH` | `EFI/boot/<fallback>.efi` + `EFI/FreeBSD/loader.efi` (both with FreeBSD fingerprint strings) |
| `make_esp_fallback_only ARCH` | `EFI/boot/<fallback>.efi` only (FreeBSD fingerprint strings) |
| `make_esp_other_os` | `EFI/BOOT/BOOTx64.efi` with Windows content; `EFI/Microsoft/Boot/bootmgfw.efi` |
| `make_esp_empty` | `EFI/` directory only, nothing inside |

For more complex scenarios (e.g. arm64 with a pre-existing arm64 fallback),
build the ESP structure manually in `TEST_ESP_DIR`:

```sh
mkdir -p "${TEST_ESP_DIR}/EFI/boot"
printf 'FreeBSD loader.efi boot/lua arm64 loader' \
    > "${TEST_ESP_DIR}/EFI/boot/BOOTaa64.efi"
```

---

## 6. CI/CD Considerations

### 6.1 FreeBSD's CI Infrastructure

FreeBSD uses [Jenkins](https://ci.FreeBSD.org/) for continuous integration and
[Kyua](https://github.com/freebsd/kyua) with ATF (Automated Testing Framework)
as the test framework for the base system.

For integration into the FreeBSD source tree, the tests need an ATF wrapper.

#### ATF/Kyua wrapper structure

ATF test programs for shell scripts use the `atf-sh` library.  A wrapper
`Kyuafile` and `Makefile` are needed alongside the test files:

**`tests/usr.sbin/freebsd-update/Kyuafile`:**
```
syntax(2)
test_suite("freebsd")

atf_test_program{name="efi_bootloader_update_test", timeout=60}
```

**ATF test program wrapper (shell):**
```sh
#!/usr/bin/atf-sh

atf_test_case i01_single_disk_efi_bios
i01_single_disk_efi_bios_head() {
    atf_set "descr" "Single disk EFI+BIOS, ZFS root, UEFI boot"
    atf_set "require.user" "root"
}
i01_single_disk_efi_bios_body() {
    sh "$(atf_get_srcdir)/test_i01_single_disk_efi_bios.sh" || atf_fail "test failed"
}

atf_init_test_cases() {
    atf_add_test_case i01_single_disk_efi_bios
    # ... remaining test cases
}
```

#### Running with Kyua

```sh
kyua test -k tests/usr.sbin/freebsd-update/Kyuafile
kyua report
```

### 6.2 Integrating with GitHub Actions (for Development)

During development (before the patch lands in the FreeBSD tree), a GitHub
Actions workflow can run the test suite on Linux:

```yaml
name: Test Suite
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install dependencies
        run: sudo apt-get install -y dash shellcheck binutils
      - name: Run shellcheck
        run: |
          shellcheck -s sh src/efi_bootloader_update.sh
          for f in tests/{unit,integration,error_conditions}/test_*.sh; do
            shellcheck -s sh "$f"
          done
      - name: Run test suite with dash
        run: dash tests/run_tests.sh
      - name: Run test suite with bash --posix
        run: bash --posix tests/run_tests.sh
```

### 6.3 Test Timeout Considerations

Most tests complete in under 1 second.  The `mktemp`, `cp`, and `cat`
operations on small files dominate the runtime.

If adding tests that involve larger file operations (e.g. testing a
multi-megabyte loader), consider that the test suite should complete in under
60 seconds total on any platform.  The Kyua `timeout` attribute should be set
to at least 60 seconds for the full test program.

### 6.4 Parallelism

`run_tests.sh` currently runs test files sequentially.  The tests are designed
to be independent (each creates its own `TEST_DIR` via `setup_test_dir`) and
can be run in parallel if needed.

With `prove`:
```sh
prove -j4 tests/integration/test_*.sh
```

With GNU parallel:
```sh
parallel sh ::: tests/integration/test_*.sh
```

Each test's `MOCK_BIN` and `TEST_DIR` are separate mktemp directories, so
parallel execution does not cause interference.
