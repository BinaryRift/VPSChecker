#!/usr/bin/env bash

set -u

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)
readonly HELPER="$PROJECT_DIR/scripts/list-check-host-locations.sh"
readonly CLI="$PROJECT_DIR/vps-check.sh"
readonly MOCK_BIN="$TEST_DIR/fixtures/check_host/bin"

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

test_lists_grouped_locations() {
    local output

    output=$(PATH="$MOCK_BIN:$PATH" "$HELPER") || return 1
    [[ $output == *$'CODE\tCOUNTRY\tNODES\tCITIES'* ]] || return 1
    [[ $output == *$'RU\tRussia\t2\tMoscow, Saint Petersburg'* ]] || return 1
    [[ $output == *$'DE\tGermany\t1\tFrankfurt'* ]]
}

test_help() {
    local output

    output=$($HELPER --help) || return 1
    [[ $output == *'--country'* ]]
}

test_cli_subcommand_lists_locations() {
    local output

    output=$(PATH="$MOCK_BIN:$PATH" "$CLI" list-locations) || return 1
    [[ $output == *$'RU\tRussia\t2\tMoscow, Saint Petersburg'* ]]
}

test_cli_subcommand_help() {
    local output

    output=$($CLI list-locations --help) || return 1
    [[ $output == *'vps-check.sh list-locations'* ]]
}

test_rejects_arguments() {
    local output status

    output=$($HELPER ru 2>&1)
    status=$?
    [[ $status -eq 2 && $output == *'does not accept arguments'* ]]
}

test_api_failure() {
    local output status

    output=$(PATH="$MOCK_BIN:$PATH" VPSCHECK_CHECK_HOST_FAILURE=1 "$HELPER" 2>&1)
    status=$?
    [[ $status -eq 1 && $output == *'could not obtain'* ]]
}

test_invalid_response() {
    local output status

    output=$(PATH="$MOCK_BIN:$PATH" VPSCHECK_CHECK_HOST_INVALID_JSON=1 "$HELPER" 2>&1)
    status=$?
    [[ $status -eq 1 && $output == *'invalid or empty'* ]]
}

run_test 'lists countries, node counts, and cities' test_lists_grouped_locations
run_test 'shows help without querying the API' test_help
run_test 'lists locations through the main CLI' test_cli_subcommand_lists_locations
run_test 'shows wrapper usage through the main CLI' test_cli_subcommand_help
run_test 'rejects unsupported arguments' test_rejects_arguments
run_test 'reports a Check-Host API failure' test_api_failure
run_test 'rejects an invalid Check-Host response' test_invalid_response

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
