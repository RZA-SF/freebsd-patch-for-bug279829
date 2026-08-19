#!/bin/sh
# run_tests.sh - Test runner for the FreeBSD bootloader update project
#
# Usage:
#   sh tests/run_tests.sh [--unit] [--integration] [--errors] [PATTERN]
#
# Options:
#   --unit         Run only unit tests (tests/unit/test_*.sh)
#   --integration  Run only integration tests (tests/integration/test_*.sh)
#   --errors       Run only error condition tests (tests/error_conditions/test_*.sh)
#   PATTERN        grep pattern to filter test filenames (applied after suite filter)
#
# Exit status: 0 if all tests pass, 1 if any fail.

# Locate the project root (parent of the tests/ directory)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
TESTS_DIR="${PROJECT_ROOT}/tests"

# Parse arguments
RUN_UNIT=0
RUN_INTEGRATION=0
RUN_ERRORS=0
PATTERN=""

for _arg in "$@"; do
    case "${_arg}" in
        --unit)         RUN_UNIT=1 ;;
        --integration)  RUN_INTEGRATION=1 ;;
        --errors)       RUN_ERRORS=1 ;;
        -*)
            echo "Unknown option: ${_arg}" >&2
            echo "Usage: sh tests/run_tests.sh [--unit] [--integration] [--errors] [PATTERN]" >&2
            exit 1
            ;;
        *)              PATTERN="${_arg}" ;;
    esac
done

# If no suite flag specified, enable all
if [ "${RUN_UNIT}" -eq 0 ] && [ "${RUN_INTEGRATION}" -eq 0 ] && [ "${RUN_ERRORS}" -eq 0 ]; then
    RUN_UNIT=1
    RUN_INTEGRATION=1
    RUN_ERRORS=1
fi

# Build the list of test files to run
TEST_FILES=""

if [ "${RUN_UNIT}" -eq 1 ]; then
    for _f in "${TESTS_DIR}/unit/test_"*.sh; do
        [ -f "${_f}" ] && TEST_FILES="${TEST_FILES} ${_f}"
    done
fi

if [ "${RUN_INTEGRATION}" -eq 1 ]; then
    for _f in "${TESTS_DIR}/integration/test_"*.sh; do
        [ -f "${_f}" ] && TEST_FILES="${TEST_FILES} ${_f}"
    done
fi

if [ "${RUN_ERRORS}" -eq 1 ]; then
    for _f in "${TESTS_DIR}/error_conditions/test_"*.sh; do
        [ -f "${_f}" ] && TEST_FILES="${TEST_FILES} ${_f}"
    done
fi

# Apply PATTERN filter if given
if [ -n "${PATTERN}" ]; then
    FILTERED_FILES=""
    for _f in ${TEST_FILES}; do
        case "${_f}" in
            *${PATTERN}*) FILTERED_FILES="${FILTERED_FILES} ${_f}" ;;
        esac
    done
    TEST_FILES="${FILTERED_FILES}"
    unset FILTERED_FILES
fi

unset _arg _f

# Check that there is something to run
if [ -z "${TEST_FILES}" ]; then
    echo "No test files found matching the given criteria." >&2
    exit 1
fi

# Totals across all test files
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
TOTAL_TESTS=0
FILES_RUN=0
FILES_FAILED=0

# Run each test file in a subshell, capture output, parse TAP
for _test_file in ${TEST_FILES}; do
    FILES_RUN=$(( FILES_RUN + 1 ))

    # Print header for this test file
    _basename=$(basename "${_test_file}")
    echo ""
    echo "=== ${_basename} ==="

    # Run the test file in a subshell; capture both stdout and stderr
    _output=$(sh "${_test_file}" 2>&1)
    _file_exit=$?

    echo "${_output}"

    # Parse TAP output lines to accumulate counts
    _file_pass=0
    _file_fail=0
    _file_skip=0

    # Process output line by line using a heredoc pipe
    while IFS= read -r _line; do
        case "${_line}" in
            'ok '*)
                # Check for SKIP directive
                case "${_line}" in
                    *'# SKIP'*|*'# skip'*)
                        _file_skip=$(( _file_skip + 1 ))
                        ;;
                    *)
                        _file_pass=$(( _file_pass + 1 ))
                        ;;
                esac
                ;;
            'not ok '*)
                _file_fail=$(( _file_fail + 1 ))
                ;;
        esac
    done <<_TAP_EOF
${_output}
_TAP_EOF

    _file_total=$(( _file_pass + _file_fail + _file_skip ))

    echo "# File summary: Passed: ${_file_pass} / ${_file_total}, Failed: ${_file_fail}, Skipped: ${_file_skip}" >&2

    TOTAL_PASS=$(( TOTAL_PASS + _file_pass ))
    TOTAL_FAIL=$(( TOTAL_FAIL + _file_fail ))
    TOTAL_SKIP=$(( TOTAL_SKIP + _file_skip ))
    TOTAL_TESTS=$(( TOTAL_TESTS + _file_total ))

    if [ "${_file_fail}" -gt 0 ] || [ "${_file_exit}" -ne 0 ]; then
        FILES_FAILED=$(( FILES_FAILED + 1 ))
    fi
done

unset _test_file _basename _output _file_exit
unset _file_pass _file_fail _file_skip _file_total _line

# Final summary
echo ""
echo "=============================="
echo "  Test Run Complete"
echo "=============================="
printf "  Files run:  %d\n"  "${FILES_RUN}"
printf "  Files failed: %d\n" "${FILES_FAILED}"
printf "  Total tests: %d\n"  "${TOTAL_TESTS}"
printf "  Passed:  %d\n"      "${TOTAL_PASS}"
printf "  Failed:  %d\n"      "${TOTAL_FAIL}"
printf "  Skipped: %d\n"      "${TOTAL_SKIP}"
echo "=============================="

if [ "${TOTAL_FAIL}" -gt 0 ] || [ "${FILES_FAILED}" -gt 0 ]; then
    exit 1
fi

exit 0
