#!/usr/bin/env bash

set -u

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)
readonly CLI="$PROJECT_DIR/vps-check.sh"
readonly FIXTURES_DIR="$TEST_DIR/fixtures"
readonly MOCK_BIN="$FIXTURES_DIR/bin"

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

test_verified_download() (
    local temp_dir

    curl() {
        local output_file=''

        while (( $# > 0 )); do
            if [[ $1 == --output ]]; then
                output_file=$2
                break
            fi
            shift
        done
        printf '#!/bin/bash\nurl="${rawgithub}main/ref/example.json"\n' > "$output_file"
    }
    sha256sum() {
        printf '%s  %s\n' "$IPQUALITY_SHA256" "$2"
    }

    prepare_ipquality >/dev/null || return 1
    [[ -f $IPQUALITY_SOURCE_PATH ]] || return 1
    [[ -f $IPQUALITY_SCRIPT_PATH ]] || return 1
    grep -qF "\${rawgithub}$IPQUALITY_COMMIT/ref/example.json" "$IPQUALITY_SCRIPT_PATH" || return 1
    ! grep -qF '${rawgithub}main/' "$IPQUALITY_SCRIPT_PATH" || return 1
    temp_dir=$IPQUALITY_TEMP_DIR
    cleanup_ipquality_temp
    [[ -z $IPQUALITY_TEMP_DIR && -z $IPQUALITY_SCRIPT_PATH && ! -e $temp_dir ]]
)

test_download_failure_cleans_temp() (
    local created_path=''

    curl() {
        while (( $# > 0 )); do
            if [[ $1 == --output ]]; then
                created_path=$2
                break
            fi
            shift
        done
        return 22
    }
    sha256sum() {
        return 1
    }

    ! prepare_ipquality >/dev/null 2>&1 || return 1
    [[ -n $created_path && ! -e ${created_path%/*} ]]
)

test_checksum_mismatch_cleans_temp() (
    local created_path=''

    curl() {
        while (( $# > 0 )); do
            if [[ $1 == --output ]]; then
                created_path=$2
                break
            fi
            shift
        done
        printf '#!/bin/bash\nurl="${rawgithub}main/ref/tampered.json"\n' > "$created_path"
    }
    sha256sum() {
        printf '%064d  %s\n' 0 "$2"
    }

    ! prepare_ipquality >/dev/null 2>&1 || return 1
    [[ -n $created_path && ! -e ${created_path%/*} ]]
)

test_cli_exit_trap_cleans_temp() {
    local path_log downloaded_path output status run_dir report

    path_log=$(mktemp)
    run_dir=$(mktemp -d) || return 1
    output=$(cd "$run_dir" && PATH="$MOCK_BIN:$PATH" VPSCHECK_MOCK_PATH_LOG="$path_log" \
        VPSCHECK_OS_RELEASE_FILE="$FIXTURES_DIR/os-release.ubuntu" \
        "$CLI" --ip 203.0.113.10 2>&1)
    status=$?
    downloaded_path=$(< "$path_log")
    rm -f "$path_log"
    for report in "$run_dir"/vpschecker-report-*; do
        [[ -e $report ]] && rm -f -- "$report"
    done
    rmdir -- "$run_dir" 2>/dev/null || true

    [[ $status -eq 0 ]] || return 1
    [[ $output == *'SHA-256: verified'* ]] || return 1
    [[ -n $downloaded_path && ! -e $downloaded_path && ! -d ${downloaded_path%/*} ]]
}

run_test 'downloads and accepts a matching checksum' test_verified_download
run_test 'cleans temporary files after a download failure' test_download_failure_cleans_temp
run_test 'rejects a checksum mismatch and cleans temporary files' test_checksum_mismatch_cleans_temp
run_test 'cleans the verified download when the CLI exits' test_cli_exit_trap_cleans_temp

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
