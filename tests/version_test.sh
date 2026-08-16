#!/usr/bin/env bash

set -u

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)

# shellcheck source=../lib/terminal.sh
. "$PROJECT_DIR/lib/terminal.sh"
# shellcheck source=../lib/version.sh
. "$PROJECT_DIR/lib/version.sh"

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

test_loads_semantic_version() (
    load_tool_version "$PROJECT_DIR/VERSION" >/dev/null || return 1
    [[ $VPSCHECK_VERSION == 0.1.0 ]]
)

test_rejects_missing_version_file() (
    ! load_tool_version "$PROJECT_DIR/missing-version" >/dev/null 2>&1
)

test_rejects_invalid_version() (
    local version_file

    version_file=$(mktemp) || return 1
    trap 'rm -f -- "$version_file"' EXIT
    printf 'release-one\n' > "$version_file"
    ! load_tool_version "$version_file" >/dev/null 2>&1
)

run_test 'loads the project semantic version' test_loads_semantic_version
run_test 'rejects a missing VERSION file' test_rejects_missing_version_file
run_test 'rejects an invalid semantic version' test_rejects_invalid_version

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
