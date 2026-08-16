#!/usr/bin/env bash

set -u

readonly TEST_DIRECTORY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIRECTORY=$(cd "$TEST_DIRECTORY/.." && pwd)

# shellcheck source=../lib/terminal.sh
. "$PROJECT_DIRECTORY/lib/terminal.sh"
# shellcheck source=../lib/listeners.sh
. "$PROJECT_DIRECTORY/lib/listeners.sh"

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

configure_mock_listener() {
    local state_path=$1
    local arguments_path=$2

    listener_state() {
        if [[ -f $state_path ]]; then
            printf 'listening\n'
        else
            printf 'not listening\n'
        fi
    }
    timeout() {
        printf 'timeout %s\n' "$*" > "$arguments_path"
        shift 3
        "$@"
    }
    nc() {
        : > "$state_path"
        while :; do
            sleep 1
        done
    }
    temporary_listener_wait() {
        sleep 0.01
    }
}

test_reuses_existing_listener() (
    local called_path

    called_path=$(mktemp) || return 1
    rm -f -- "$called_path"
    trap 'rm -f -- "$called_path"' EXIT
    listener_state() {
        printf 'listening\n'
    }
    nc() {
        : > "$called_path"
    }

    prepare_listener tcp 443 || return 1
    [[ $PREPARED_LISTENER_SOURCE == EXISTING \
        && -z $PREPARED_LISTENER_PID \
        && $PREPARED_LISTENER_PRIVILEGED -eq 0 \
        && ${#TEMPORARY_LISTENER_PIDS[@]} -eq 0 \
        && ! -e $called_path ]]
)

test_starts_tcp_listener_on_free_port() (
    local test_root state_path arguments_path pid

    test_root=$(mktemp -d) || return 1
    trap 'rm -rf -- "$test_root"' EXIT
    state_path="$test_root/state"
    arguments_path="$test_root/arguments"
    configure_mock_listener "$state_path" "$arguments_path"

    prepare_listener tcp 8443 || return 1
    pid=$PREPARED_LISTENER_PID
    [[ $PREPARED_LISTENER_SOURCE == TEMPORARY \
        && $PREPARED_LISTENER_PRIVILEGED -eq 0 \
        && $pid =~ ^[0-9]+$ \
        && ${#TEMPORARY_LISTENER_PIDS[@]} -eq 1 \
        && $(< "$arguments_path") == \
            'timeout --signal=TERM --kill-after=2s 180s nc -4 -d -k -l 8443' ]] || return 1
    stop_temporary_listeners || return 1
    [[ ${#TEMPORARY_LISTENER_PIDS[@]} -eq 0 ]] || return 1
    ! kill -0 "$pid" 2>/dev/null
)

test_starts_udp_listener_on_free_port() (
    local test_root state_path arguments_path pid

    test_root=$(mktemp -d) || return 1
    trap 'rm -rf -- "$test_root"' EXIT
    state_path="$test_root/state"
    arguments_path="$test_root/arguments"
    configure_mock_listener "$state_path" "$arguments_path"

    prepare_listener udp 8443 || return 1
    pid=$PREPARED_LISTENER_PID
    [[ $PREPARED_LISTENER_SOURCE == TEMPORARY \
        && $(< "$arguments_path") == \
            'timeout --signal=TERM --kill-after=2s 180s nc -4 -d -k -u -l 8443' ]] || return 1
    stop_temporary_listeners || return 1
    ! kill -0 "$pid" 2>/dev/null
)

test_authorizes_privileged_port() (
    local test_root state_path arguments_path authorized_path privileged_path pid

    test_root=$(mktemp -d) || return 1
    trap 'rm -rf -- "$test_root"' EXIT
    state_path="$test_root/state"
    arguments_path="$test_root/arguments"
    authorized_path="$test_root/authorized"
    privileged_path="$test_root/privileged"
    configure_mock_listener "$state_path" "$arguments_path"
    listener_current_uid() {
        printf '1000\n'
    }
    listener_sudo_available() {
        return 0
    }
    listener_authorize_sudo() {
        : > "$authorized_path"
    }
    listener_run_privileged() {
        printf '%s\n' "$*" >> "$privileged_path"
        "$@"
    }

    prepare_listener tcp 443 >/dev/null || return 1
    pid=$PREPARED_LISTENER_PID
    [[ $PREPARED_LISTENER_SOURCE == TEMPORARY \
        && $PREPARED_LISTENER_PRIVILEGED -eq 1 \
        && -f $authorized_path \
        && $(sed -n '1p' "$privileged_path") == \
            'timeout --signal=TERM --kill-after=2s 180s nc -4 -d -k -l 443' ]] || return 1
    stop_temporary_listeners || return 1
    ! kill -0 "$pid" 2>/dev/null
)

test_rejects_privileged_port_without_sudo() (
    local output status

    listener_state() {
        printf 'not listening\n'
    }
    listener_current_uid() {
        printf '1000\n'
    }
    listener_sudo_available() {
        return 1
    }
    timeout() {
        return 0
    }

    output=$(prepare_listener tcp 443 2>&1)
    status=$?
    [[ $status -eq 1 && $output == *'requires root privileges or sudo'* ]]
)

test_rejects_unverified_listener_start() (
    local output status

    listener_state() {
        printf 'not listening\n'
    }
    nc() {
        return 1
    }
    timeout() {
        shift 3
        "$@"
    }
    temporary_listener_wait() {
        return 0
    }

    output=$(prepare_listener tcp 8443 2>&1)
    status=$?
    [[ $status -eq 1 \
        && $PREPARED_LISTENER_SOURCE == NONE \
        && $output == *'could not start temporary tcp/8443 listener'* ]]
)

test_retains_listener_when_cleanup_fails() (
    register_temporary_listener 12345 0 tcp 8443 || return 1
    stop_temporary_listener() {
        return 1
    }

    ! stop_temporary_listeners >/dev/null 2>&1 || return 1
    [[ ${#TEMPORARY_LISTENER_PIDS[@]} -eq 1 \
        && ${TEMPORARY_LISTENER_PIDS[0]} == 12345 \
        && ${TEMPORARY_LISTENER_PROTOCOLS[0]} == tcp \
        && ${TEMPORARY_LISTENER_PORTS[0]} == 8443 ]]
)

run_test 'reuses an existing listener without starting a process' test_reuses_existing_listener
run_test 'starts and verifies a temporary TCP listener' test_starts_tcp_listener_on_free_port
run_test 'starts and verifies a temporary UDP listener' test_starts_udp_listener_on_free_port
run_test 'authorizes a temporary listener on a privileged port' test_authorizes_privileged_port
run_test 'rejects a privileged port when sudo is unavailable' test_rejects_privileged_port_without_sudo
run_test 'rejects a listener that cannot be verified with ss' test_rejects_unverified_listener_start
run_test 'retains listener metadata when cleanup fails' test_retains_listener_when_cleanup_fails

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
