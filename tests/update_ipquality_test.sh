#!/usr/bin/env bash

set -u

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)
readonly UPDATE_SCRIPT="$PROJECT_DIR/scripts/update-ipquality.sh"
readonly MOCK_BIN="$TEST_DIR/fixtures/update-bin"
readonly CANDIDATE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
readonly CANDIDATE_VERSION=v2099-01-02
readonly CANDIDATE_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

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

prepare_project() {
    local test_project=$1

    mkdir -p "$test_project/scripts" "$test_project/lib"
    cp "$UPDATE_SCRIPT" "$test_project/scripts/update-ipquality.sh"
    cp "$PROJECT_DIR/lib/ipquality.sh" "$test_project/lib/ipquality.sh"
}

cleanup_project() {
    local test_project=$1

    rm -f -- "$test_project/curl-count"
    rm -f -- "$test_project/scripts/update-ipquality.sh" "$test_project/lib/ipquality.sh"
    rmdir -- "$test_project/scripts" "$test_project/lib" "$test_project" 2>/dev/null || true
}

run_updater() {
    local test_project=$1
    local answer=$2
    local count_file=$3

    PATH="$MOCK_BIN:$PATH" \
        VPSCHECK_MOCK_CURL_COUNT="$count_file" \
        VPSCHECK_MOCK_CURRENT_VERSION="$IPQUALITY_VERSION" \
        VPSCHECK_MOCK_CANDIDATE_VERSION="$CANDIDATE_VERSION" \
        VPSCHECK_MOCK_CURRENT_SHA256="$IPQUALITY_SHA256" \
        VPSCHECK_MOCK_CANDIDATE_SHA256="$CANDIDATE_SHA256" \
        "$test_project/scripts/update-ipquality.sh" "$CANDIDATE_COMMIT" <<< "$answer"
}

test_declined_update_changes_nothing() (
    local test_project before count_file output status

    test_project=$(mktemp -d)
    trap 'cleanup_project "$test_project"' EXIT
    prepare_project "$test_project"
    before=$(< "$test_project/lib/ipquality.sh")
    count_file="$test_project/curl-count"

    output=$(run_updater "$test_project" n "$count_file" 2>&1)
    status=$?
    [[ $status -eq 0 && $output == *'Update cancelled; no files were changed.'* ]] || return 1
    [[ $(< "$test_project/lib/ipquality.sh") == "$before" ]]
)

test_confirmed_update_changes_pin() (
    local test_project count_file output status updated

    test_project=$(mktemp -d)
    trap 'cleanup_project "$test_project"' EXIT
    prepare_project "$test_project"
    count_file="$test_project/curl-count"

    output=$(run_updater "$test_project" y "$count_file" 2>&1)
    status=$?
    updated=$(< "$test_project/lib/ipquality.sh")
    [[ $status -eq 0 && $output == *'Updated IPQuality pin'* ]] || return 1
    [[ $updated == *"readonly IPQUALITY_COMMIT=$CANDIDATE_COMMIT"* ]] || return 1
    [[ $updated == *"readonly IPQUALITY_VERSION=$CANDIDATE_VERSION"* ]] || return 1
    [[ $updated == *"readonly IPQUALITY_SHA256=$CANDIDATE_SHA256"* ]]
)

test_bad_current_checksum_stops_update() (
    local test_project before count_file output status

    test_project=$(mktemp -d)
    trap 'cleanup_project "$test_project"' EXIT
    prepare_project "$test_project"
    before=$(< "$test_project/lib/ipquality.sh")
    count_file="$test_project/curl-count"

    output=$(PATH="$MOCK_BIN:$PATH" \
        VPSCHECK_MOCK_CURL_COUNT="$count_file" \
        VPSCHECK_MOCK_CURRENT_VERSION="$IPQUALITY_VERSION" \
        VPSCHECK_MOCK_CANDIDATE_VERSION="$CANDIDATE_VERSION" \
        VPSCHECK_MOCK_CURRENT_SHA256="$IPQUALITY_SHA256" \
        VPSCHECK_MOCK_CANDIDATE_SHA256="$CANDIDATE_SHA256" \
        VPSCHECK_MOCK_CORRUPT_CURRENT=1 \
        "$test_project/scripts/update-ipquality.sh" "$CANDIDATE_COMMIT" <<< y 2>&1)
    status=$?
    [[ $status -eq 1 && $output == *'does not match its recorded checksum'* ]] || return 1
    [[ $(< "$test_project/lib/ipquality.sh") == "$before" ]]
)

# Sourcing supplies the current pin to test helpers without running VPSChecker.
# shellcheck source=../lib/ipquality.sh
. "$PROJECT_DIR/lib/ipquality.sh"

run_test 'does not modify the pin when confirmation is declined' test_declined_update_changes_nothing
run_test 'updates all pin values after confirmation' test_confirmed_update_changes_pin
run_test 'stops when the current source checksum is invalid' test_bad_current_checksum_stops_update

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
