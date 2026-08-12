#!/usr/bin/env bash

set -u

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)

# shellcheck source=../lib/dependencies.sh
. "$PROJECT_DIR/lib/dependencies.sh"
# shellcheck source=../lib/cleanup.sh
. "$PROJECT_DIR/lib/cleanup.sh"

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

run_cleanup_case() {
    local mode=$1
    local expected_status=$2
    local case_dir status

    case_dir=$(mktemp -d) || return 1
    PROJECT_DIR_FOR_TEST=$PROJECT_DIR CASE_DIR_FOR_TEST=$case_dir \
        bash -c '
            set -u
            . "$PROJECT_DIR_FOR_TEST/vps-check.sh"

            IPQUALITY_TEMP_DIR="$CASE_DIR_FOR_TEST/ipquality"
            IPQUALITY_SOURCE_PATH="$IPQUALITY_TEMP_DIR/ipquality.source.sh"
            IPQUALITY_SCRIPT_PATH="$IPQUALITY_TEMP_DIR/ipquality.run.sh"
            IPQUALITY_JSON_PATH="$IPQUALITY_TEMP_DIR/ipquality.raw.json"
            IPQUALITY_LOG_PATH="$IPQUALITY_TEMP_DIR/ipquality.stderr.log"
            VPN_TRUST_JSON_PATH="$IPQUALITY_TEMP_DIR/vpn-trust.json"
            CHECK_HOST_TEMP_DIR="$CASE_DIR_FOR_TEST/check-host"
            REPORT_TEMP_PATHS=("$CASE_DIR_FOR_TEST/incomplete-report")

            mkdir -p "$IPQUALITY_TEMP_DIR" "$CHECK_HOST_TEMP_DIR"
            touch "$IPQUALITY_SOURCE_PATH" "$IPQUALITY_SCRIPT_PATH" \
                "$IPQUALITY_JSON_PATH" "$IPQUALITY_LOG_PATH" \
                "$VPN_TRUST_JSON_PATH" "$CHECK_HOST_TEMP_DIR/nodes.json" \
                "${REPORT_TEMP_PATHS[0]}"

            trap cleanup_runtime EXIT
            trap "exit 130" INT
            case $1 in
                success) exit 0 ;;
                error) exit 17 ;;
                signal) kill -INT "$$" ;;
            esac
        ' cleanup-driver "$mode" >/dev/null 2>&1
    status=$?

    [[ $status -eq $expected_status ]] || {
        rm -f -- \
            "$case_dir/ipquality/ipquality.source.sh" \
            "$case_dir/ipquality/ipquality.run.sh" \
            "$case_dir/ipquality/ipquality.raw.json" \
            "$case_dir/ipquality/ipquality.stderr.log" \
            "$case_dir/ipquality/vpn-trust.json" \
            "$case_dir/check-host/nodes.json" \
            "$case_dir/incomplete-report"
        rmdir -- "$case_dir/ipquality" "$case_dir/check-host" "$case_dir" 2>/dev/null || true
        return 1
    }
    [[ ! -e $case_dir/ipquality ]] || return 1
    [[ ! -e $case_dir/check-host ]] || return 1
    [[ ! -e $case_dir/incomplete-report ]] || return 1
    rmdir -- "$case_dir"
}

test_cleanup_on_success() {
    run_cleanup_case success 0
}

test_cleanup_preserves_error_status() {
    run_cleanup_case error 17
}

test_cleanup_on_interrupt() {
    run_cleanup_case signal 130
}

test_saves_and_merges_cleanup_plan() (
    local case_dir content

    case_dir=$(mktemp -d) || return 1
    cd "$case_dir" || return 1
    set_cleanup_plan_path
    trap 'rm -f -- "$CLEANUP_PLAN_PATH"; cd "$PROJECT_DIR"; rmdir -- "$case_dir" 2>/dev/null || true' EXIT

    DEPENDENCY_ADDED_PACKAGES=(jq libjq1)
    save_dependency_cleanup_plan || return 1
    DEPENDENCY_ADDED_PACKAGES=(bc jq)
    save_dependency_cleanup_plan || return 1
    content=$(< "$CLEANUP_PLAN_PATH")

    [[ $content == $'bc\njq\nlibjq1' ]]
)

test_cleanup_command_uses_saved_plan() (
    local case_dir
    local removal_completed=0

    case_dir=$(mktemp -d) || return 1
    cd "$case_dir" || return 1
    set_cleanup_plan_path
    trap 'rm -f -- "$CLEANUP_PLAN_PATH"; cd "$PROJECT_DIR"; rmdir -- "$case_dir" 2>/dev/null || true' EXIT
    DEPENDENCY_ADDED_PACKAGES=(jq libjq1)
    save_dependency_cleanup_plan || return 1

    id() {
        printf '0\n'
    }
    dpkg-query() {
        local package=${*: -1}

        case $package in
            jq|libjq1)
                (( removal_completed == 0 )) || return 1
                printf 'install ok installed'
                ;;
            *) return 1 ;;
        esac
    }
    apt-get() {
        if [[ $1 == --simulate ]]; then
            printf '%s\n' 'Remv jq [1.0]' 'Remv libjq1 [1.0]'
        else
            removal_completed=1
        fi
    }

    run_dependency_cleanup_command <<< y >/dev/null || return 1
    [[ $DEPENDENCY_CLEANUP_STATUS == REMOVED && ! -e $CLEANUP_PLAN_PATH ]]
)

test_cancelled_cleanup_keeps_plan() (
    local case_dir

    case_dir=$(mktemp -d) || return 1
    cd "$case_dir" || return 1
    set_cleanup_plan_path
    trap 'rm -f -- "$CLEANUP_PLAN_PATH"; cd "$PROJECT_DIR"; rmdir -- "$case_dir" 2>/dev/null || true' EXIT
    DEPENDENCY_ADDED_PACKAGES=(jq)
    save_dependency_cleanup_plan || return 1

    id() {
        printf '0\n'
    }
    dpkg-query() {
        printf 'install ok installed'
    }
    apt-get() {
        printf 'Remv jq [1.0]\n'
    }

    ! run_dependency_cleanup_command <<< n >/dev/null 2>&1 || return 1
    [[ $DEPENDENCY_CLEANUP_STATUS == DEFERRED && -f $CLEANUP_PLAN_PATH ]]
)

test_cleanup_hint_uses_argument_free_command() (
    local case_dir output

    case_dir=$(mktemp -d) || return 1
    CLEANUP_PLAN_PATH="$case_dir/.vpschecker-cleanup.plan"
    printf 'jq\n' > "$CLEANUP_PLAN_PATH"
    VPSCHECK_COMMAND_PATH=./vps-check.sh

    output=$(print_cleanup_hint) || return 1
    [[ $output == *'./vps-check.sh cleanup'* ]] || return 1
    [[ $output != *'cleanup jq'* ]] || return 1
    rm -f -- "$CLEANUP_PLAN_PATH"
    rmdir -- "$case_dir"
)

test_runtime_defers_cleanup_by_default() (
    local case_dir
    local execute_called=0
    local final_status=''

    case_dir=$(mktemp -d) || return 1
    CLEANUP_PLAN_PATH="$case_dir/.vpschecker-cleanup.plan"
    CLEANUP_PLAN_TEMP_PATH=''
    AUTO_CLEANUP_REQUESTED=0
    RUNTIME_CLEANUP_DONE=0
    RUNTIME_CLEANUP_FAILED=0
    defer_added_dependencies() {
        DEPENDENCY_ADDED_PACKAGES=(jq)
        DEPENDENCY_CLEANUP_STATUS='DEFERRED'
    }
    save_dependency_cleanup_plan() {
        printf 'jq\n' > "$CLEANUP_PLAN_PATH"
    }
    execute_cleanup_plan() {
        execute_called=1
    }
    print_cleanup_hint() { :; }
    cleanup_dependency_journal() { :; }
    cleanup_reputation_temp() { :; }
    cleanup_check_host_temp() { :; }
    cleanup_ipquality_temp() { :; }
    cleanup_report_temp() { :; }
    finalize_report_cleanup() {
        final_status=$1
    }

    cleanup_runtime 0 || return 1
    [[ $execute_called -eq 0 && $final_status == DEFERRED ]] || return 1
    rm -f -- "$CLEANUP_PLAN_PATH"
    rmdir -- "$case_dir"
)

test_runtime_uses_automatic_cleanup_flag() (
    local case_dir
    local execute_called=0
    local final_status=''

    case_dir=$(mktemp -d) || return 1
    CLEANUP_PLAN_PATH="$case_dir/.vpschecker-cleanup.plan"
    CLEANUP_PLAN_TEMP_PATH=''
    AUTO_CLEANUP_REQUESTED=1
    RUNTIME_CLEANUP_DONE=0
    RUNTIME_CLEANUP_FAILED=0
    defer_added_dependencies() {
        DEPENDENCY_ADDED_PACKAGES=(jq)
        DEPENDENCY_CLEANUP_STATUS='DEFERRED'
    }
    save_dependency_cleanup_plan() {
        printf 'jq\n' > "$CLEANUP_PLAN_PATH"
    }
    execute_cleanup_plan() {
        execute_called=1
        DEPENDENCY_CLEANUP_STATUS='REMOVED'
        rm -f -- "$CLEANUP_PLAN_PATH"
    }
    cleanup_dependency_journal() { :; }
    cleanup_reputation_temp() { :; }
    cleanup_check_host_temp() { :; }
    cleanup_ipquality_temp() { :; }
    cleanup_report_temp() { :; }
    finalize_report_cleanup() {
        final_status=$1
    }

    cleanup_runtime 0 || return 1
    [[ $execute_called -eq 1 && $final_status == REMOVED ]] || return 1
    rmdir -- "$case_dir"
)

run_test 'removes runtime files after success' test_cleanup_on_success
run_test 'removes runtime files without hiding an error status' test_cleanup_preserves_error_status
run_test 'removes runtime files after SIGINT' test_cleanup_on_interrupt
run_test 'saves and merges a cleanup plan' test_saves_and_merges_cleanup_plan
run_test 'cleanup command uses the saved plan' test_cleanup_command_uses_saved_plan
run_test 'cancelled cleanup keeps the saved plan' test_cancelled_cleanup_keeps_plan
run_test 'cleanup hint uses a command without package arguments' test_cleanup_hint_uses_argument_free_command
run_test 'defers package cleanup by default' test_runtime_defers_cleanup_by_default
run_test 'uses automatic package cleanup when requested' test_runtime_uses_automatic_cleanup_flag

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
