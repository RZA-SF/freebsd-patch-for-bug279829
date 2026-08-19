# Test Suite — FreeBSD Bootloader Update (Bug 279829)

This directory contains the test suite for the FreeBSD EFI bootloader update
script. Tests are written in POSIX sh and produce TAP (Test Anything Protocol)
output.

---

## Directory Structure

```
tests/
  run_tests.sh              # Top-level test runner
  lib/
    mock_framework.sh       # Mock command infrastructure (PATH injection)
    test_helpers.sh         # TAP assertion helpers and ESP fixture builders
  unit/
    test_*.sh               # Unit tests (mocked commands, no real disks)
  integration/
    test_*.sh               # Integration tests (real ESP directory structures)
  error_conditions/
    test_*.sh               # Tests that inject specific failure modes
  fixtures/                 # Static fixture files used by tests
```

### Suite Descriptions

- **unit/** — Tests for individual shell functions and logic branches. All
  external commands (`mount`, `umount`, `cp`, `efibootmgr`, etc.) are replaced
  with mocks. No root privileges, no real disks required.

- **integration/** — Tests that exercise the full update script flow against
  simulated ESP directory trees created in a temp directory. No real block
  devices are used, but the test verifies that files land in the right places
  with correct content.

- **error_conditions/** — Tests that deliberately inject failures (e.g. a
  `mount` mock that always fails, a read-only filesystem, missing source
  files) to verify that the update script handles errors gracefully and exits
  with appropriate status codes.

---

## Running the Tests

### On Linux (development)

Run the full suite:

```sh
sh tests/run_tests.sh
```

Run only unit tests:

```sh
sh tests/run_tests.sh --unit
```

Run only integration tests:

```sh
sh tests/run_tests.sh --integration
```

Run only error-condition tests:

```sh
sh tests/run_tests.sh --errors
```

Filter by filename pattern:

```sh
sh tests/run_tests.sh --unit detect
```

The runner exits 0 when all tests pass, 1 when any fail.

### On FreeBSD (full validation)

The same commands work on FreeBSD. Integration tests that require real EFI
variables or block devices are skipped automatically when running without root
or when the required devices are absent. To run with elevated privileges:

```sh
sudo sh tests/run_tests.sh --integration
```

---

## Mock Framework (PATH Injection)

`tests/lib/mock_framework.sh` provides a lightweight mock command system. It
works by creating a temporary `bin/` directory and prepending it to `$PATH`,
so that mock scripts shadow real system commands for the duration of a test.

Key functions:

| Function | Purpose |
|---|---|
| `mock_init` | Creates `MOCK_BIN` and `MOCK_CALL_LOG`, prepends `MOCK_BIN` to `PATH` |
| `mock_cleanup` | Removes `MOCK_BIN` and `MOCK_CALL_LOG` |
| `mock_cmd NAME SCRIPT` | Creates a mock that logs its invocation then runs SCRIPT |
| `mock_cmd_output NAME OUTPUT [EXIT]` | Mock that echoes OUTPUT and exits with EXIT (default 0) |
| `mock_cmd_fail NAME [EXIT]` | Mock that prints an error to stderr and exits with EXIT (default 1) |
| `mock_was_called NAME` | Returns 0 if NAME was called at least once |
| `mock_call_count NAME` | Prints the number of times NAME was called |
| `mock_last_args NAME` | Prints the arguments from the most recent call to NAME |

Every call to a mock appends a line to `MOCK_CALL_LOG` in the format:

```
CMDNAME ARG1 ARG2 ...
```

---

## TAP Assertion Helpers

`tests/lib/test_helpers.sh` provides TAP-compliant assertion functions and
ESP fixture builders.

### TAP Lifecycle

```sh
tap_begin 5      # Print "1..5" and reset counters
# ... assertions ...
tap_end          # Print summary to stderr
```

### Assertions

| Function | Description |
|---|---|
| `assert_eq DESC ACTUAL EXPECTED` | Pass if ACTUAL = EXPECTED |
| `assert_ne DESC ACTUAL UNEXPECTED` | Pass if ACTUAL != UNEXPECTED |
| `assert_true DESC CMD [ARGS...]` | Pass if CMD exits 0 |
| `assert_false DESC CMD [ARGS...]` | Pass if CMD exits non-zero |
| `assert_contains DESC HAYSTACK NEEDLE` | Pass if NEEDLE is a substring of HAYSTACK |
| `assert_file_exists DESC PATH` | Pass if PATH is a regular file |
| `assert_file_not_exists DESC PATH` | Pass if PATH does not exist |
| `assert_empty DESC VALUE` | Pass if VALUE is the empty string |
| `assert_not_empty DESC VALUE` | Pass if VALUE is non-empty |
| `skip DESC` | Record a skipped test |

### ESP Fixture Builders

These create fake EFI System Partition directory trees inside `TEST_ESP_DIR`
for use by integration and unit tests.

| Function | Creates |
|---|---|
| `setup_test_dir` | `TEST_DIR=$(mktemp -d)`, `TEST_ESP_DIR=${TEST_DIR}/esp` |
| `teardown_test_dir` | Removes `TEST_DIR` recursively |
| `make_esp_freebsd_only ARCH` | `EFI/boot/<fallback>.efi` + `EFI/FreeBSD/loader.efi` (FreeBSD content) |
| `make_esp_fallback_only ARCH` | Only `EFI/boot/<fallback>.efi` (no `EFI/FreeBSD/`) |
| `make_esp_other_os` | Windows-style ESP: `EFI/BOOT/BOOTx64.efi` + `EFI/Microsoft/` |
| `make_esp_empty` | Just the `EFI/` directory, nothing inside |

ARCH values: `amd64` (produces `BOOTx64.efi`) or `arm64` (produces `BOOTaa64.efi`).

---

## Adding a New Test

1. Choose the appropriate suite directory (`unit/`, `integration/`, or
   `error_conditions/`).

2. Create a file named `test_<topic>.sh` in that directory.

3. Use this template:

```sh
#!/bin/sh
# test_<topic>.sh - Brief description of what is being tested

TESTS_LIB=$(cd "$(dirname "$0")/../lib" && pwd)
. "${TESTS_LIB}/test_helpers.sh"
. "${TESTS_LIB}/mock_framework.sh"

tap_begin 3

mock_init

# --- setup ---
setup_test_dir
make_esp_freebsd_only amd64

# --- test 1 ---
assert_file_exists "fallback efi present" \
    "${TEST_ESP_DIR}/EFI/boot/BOOTx64.efi"

# --- test 2 ---
mock_cmd_output cp "" 0
# ... invoke the script under test ...
assert_true "cp was called" mock_was_called cp

# --- test 3 ---
assert_eq "call count" "$(mock_call_count cp)" "1"

# --- teardown ---
teardown_test_dir
mock_cleanup

tap_end
```

4. Make the file executable:

```sh
chmod +x tests/<suite>/test_<topic>.sh
```

5. Run the new test in isolation to verify:

```sh
sh tests/<suite>/test_<topic>.sh
```

---

## Notes

- All test scripts use **pure POSIX sh** (`#!/bin/sh`). Bash-specific features
  (`[[`, `(( ))`, arrays, `local`, etc.) are not used.

- Unit tests use **mocked commands** and require no root privileges or real
  disk devices. They are safe to run on any POSIX system including Linux CI
  runners.

- Integration tests simulate complete ESP directory structures in a temporary
  directory. They verify file placement and content without touching real block
  devices. Root is not required.

- Error condition tests inject specific failure modes by creating mock commands
  that return controlled exit codes, enabling verification that the update
  script reports errors and exits cleanly rather than silently corrupting state.

- The TAP output produced by each test file is compatible with standard TAP
  consumers such as `prove` (Perl), `tap-parser` (Node.js), and the built-in
  `run_tests.sh` runner.
