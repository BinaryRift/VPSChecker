#!/usr/bin/env bash

set -u

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)
readonly MOCK_IPQUALITY="$TEST_DIR/fixtures/ipquality/mock.sh"

# shellcheck source=../lib/ipquality.sh
. "$PROJECT_DIR/lib/ipquality.sh"

passed=0
failed=0

run_test() {
    local description=$1
    local test_function=$2

    if "$test_function"; then
        printf 'ok - %s\n' "$description"
        (( passed += 1 ))
    else
        printf 'not ok - %s\n' "$description"
        (( failed += 1 ))
    fi
}

setup_mock_ipquality() {
    IPQUALITY_TEMP_DIR=$(mktemp -d)
    IPQUALITY_SOURCE_PATH="$IPQUALITY_TEMP_DIR/ipquality.source.sh"
    IPQUALITY_SCRIPT_PATH="$IPQUALITY_TEMP_DIR/ipquality.run.sh"
    cp "$MOCK_IPQUALITY" "$IPQUALITY_SOURCE_PATH"
    cp "$MOCK_IPQUALITY" "$IPQUALITY_SCRIPT_PATH"
}

mock_jq() {
    local file

    for file in "$@"; do :; done
    grep -q '^{' "$file" && grep -q '}$' "$file"
}

test_valid_json_and_required_modes() (
    local args_log result log temp_dir

    setup_mock_ipquality
    temp_dir=$IPQUALITY_TEMP_DIR
    args_log=$(mktemp)
    trap 'rm -f -- "$args_log"; cleanup_ipquality_temp' EXIT
    jq() {
        mock_jq "$@"
    }
    export VPSCHECK_IPQUALITY_ARGS_LOG=$args_log

    run_ipquality >/dev/null || return 1
    result=$(< "$IPQUALITY_JSON_PATH")
    log=$(< "$IPQUALITY_LOG_PATH")
    [[ $(< "$args_log") == '-E -4 -f -j -n -p' ]] || return 1
    [[ $result == '{"Head":{"IP":"203.0.113.10"},"Info":{},"Score":{},"Factor":{}}' ]] || return 1
    [[ $log == *'mock diagnostic output'* ]] || return 1

    cleanup_ipquality_temp
    [[ ! -e $temp_dir ]]
)

test_nonzero_exit_is_reported() (
    local status

    setup_mock_ipquality
    trap cleanup_ipquality_temp EXIT
    jq() {
        mock_jq "$@"
    }
    export VPSCHECK_IPQUALITY_EXIT=7

    run_ipquality >/dev/null 2>&1
    status=$?
    [[ $status -eq 7 && -z $IPQUALITY_JSON_PATH && -f $IPQUALITY_LOG_PATH ]]
)

test_ipv4_exit_one_with_valid_json_is_accepted() (
    setup_mock_ipquality
    trap cleanup_ipquality_temp EXIT
    jq() {
        mock_jq "$@"
    }
    export VPSCHECK_IPQUALITY_FINAL_EXIT=1

    run_ipquality >/dev/null || return 1
    [[ -f $IPQUALITY_JSON_PATH ]]
)

test_invalid_json_is_rejected() (
    setup_mock_ipquality
    trap cleanup_ipquality_temp EXIT
    jq() {
        mock_jq "$@"
    }
    export VPSCHECK_IPQUALITY_INVALID_JSON=1

    ! run_ipquality >/dev/null 2>&1 || return 1
    [[ -z $IPQUALITY_JSON_PATH && -f $IPQUALITY_LOG_PATH ]]
)

run_test 'runs with JSON, IPv4, full-IP, no-install, and privacy flags' test_valid_json_and_required_modes
run_test 'accepts the upstream IPv4 exit status when JSON is valid' test_ipv4_exit_one_with_valid_json_is_accepted
run_test 'returns the IPQuality exit status and keeps diagnostics' test_nonzero_exit_is_reported
run_test 'rejects invalid JSON output' test_invalid_json_is_rejected

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
