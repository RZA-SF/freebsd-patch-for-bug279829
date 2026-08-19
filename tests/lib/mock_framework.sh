#!/bin/sh
# mock_framework.sh - Mock command framework using PATH injection
#
# Usage:
#   . tests/lib/mock_framework.sh
#   mock_init
#   mock_cmd_output mount ""
#   mock_cmd_fail umount 1
#   mock_was_called mount && echo "mount was called"
#   mock_cleanup

# mock_init: Creates temp bin dir, prepends to PATH, sets MOCK_CALL_LOG
mock_init() {
    MOCK_BIN=$(mktemp -d)
    MOCK_CALL_LOG=$(mktemp)
    export MOCK_BIN
    export MOCK_CALL_LOG
    PATH="${MOCK_BIN}:${PATH}"
    export PATH
    # Prevent environment variable inheritance from contaminating tests
    unset EFI_DRY_RUN EFI_VERBOSE EFI_NVRAM_UPDATE
    # Clear FreeBSD sh command hash table so new mocks are found immediately
    hash -r 2>/dev/null || true
}

# mock_cleanup: Removes mock bin dir and call log
mock_cleanup() {
    if [ -n "${MOCK_BIN}" ]; then
        rm -rf "${MOCK_BIN}"
    fi
    if [ -n "${MOCK_CALL_LOG}" ]; then
        rm -f "${MOCK_CALL_LOG}"
    fi
    unset MOCK_BIN
    unset MOCK_CALL_LOG
}

# mock_cmd NAME SCRIPT: Creates a mock command that logs invocations then runs SCRIPT
mock_cmd() {
    _mock_name="$1"
    _mock_script="$2"
    cat > "${MOCK_BIN}/${_mock_name}" <<MOCK_EOF
#!/bin/sh
echo "${_mock_name} \$*" >> "\${MOCK_CALL_LOG}"
${_mock_script}
MOCK_EOF
    chmod +x "${MOCK_BIN}/${_mock_name}"
    hash -r 2>/dev/null || true
    unset _mock_name _mock_script
}

# mock_cmd_output NAME OUTPUT [EXIT_CODE]: Creates a mock that echoes OUTPUT and exits with EXIT_CODE (default 0)
mock_cmd_output() {
    _mock_name="$1"
    _mock_output="$2"
    _mock_exit="${3:-0}"
    cat > "${MOCK_BIN}/${_mock_name}" <<MOCK_EOF
#!/bin/sh
echo "${_mock_name} \$*" >> "\${MOCK_CALL_LOG}"
echo "${_mock_output}"
exit ${_mock_exit}
MOCK_EOF
    chmod +x "${MOCK_BIN}/${_mock_name}"
    hash -r 2>/dev/null || true
    unset _mock_name _mock_output _mock_exit
}

# mock_cmd_fail NAME [EXIT_CODE]: Creates a mock that exits with EXIT_CODE (default 1) and prints to stderr
mock_cmd_fail() {
    _mock_name="$1"
    _mock_exit="${2:-1}"
    cat > "${MOCK_BIN}/${_mock_name}" <<MOCK_EOF
#!/bin/sh
echo "${_mock_name} \$*" >> "\${MOCK_CALL_LOG}"
echo "mock: ${_mock_name}: command failed" >&2
exit ${_mock_exit}
MOCK_EOF
    chmod +x "${MOCK_BIN}/${_mock_name}"
    hash -r 2>/dev/null || true
    unset _mock_name _mock_exit
}

# mock_was_called NAME: Returns 0 if NAME appears in MOCK_CALL_LOG, 1 otherwise
mock_was_called() {
    _mock_name="$1"
    grep -q "^${_mock_name} \|^${_mock_name}$" "${MOCK_CALL_LOG}" 2>/dev/null
    _mock_rc=$?
    unset _mock_name
    return ${_mock_rc}
}

# mock_call_count NAME: Outputs the number of times NAME was called
mock_call_count() {
    _mock_name="$1"
    _mock_count=$(grep -c "^${_mock_name} \|^${_mock_name}$" "${MOCK_CALL_LOG}" 2>/dev/null || echo 0)
    echo "${_mock_count}"
    unset _mock_name _mock_count
}

# mock_last_args NAME: Outputs the last argument string passed to NAME (from MOCK_CALL_LOG)
mock_last_args() {
    _mock_name="$1"
    _mock_last=$(grep "^${_mock_name} \|^${_mock_name}$" "${MOCK_CALL_LOG}" 2>/dev/null | tail -n 1)
    # Strip the command name prefix, leaving only the args
    _mock_args="${_mock_last#${_mock_name}}"
    # Strip leading space if present
    case "${_mock_args}" in
        ' '*) _mock_args="${_mock_args# }" ;;
    esac
    echo "${_mock_args}"
    unset _mock_name _mock_last _mock_args
}
