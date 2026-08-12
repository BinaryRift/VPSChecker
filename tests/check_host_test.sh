#!/usr/bin/env bash

set -u

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)
readonly FIXTURES_DIR="$TEST_DIR/fixtures/check_host"

# shellcheck source=../lib/check_host.sh
. "$PROJECT_DIR/lib/check_host.sh"

MOCK_SCENARIO=success
POLL_CALLS=0
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

check_host_sleep() {
    :
}

check_host_api_get() {
    local output_path=$1
    local endpoint=$2
    local check_type

    case $endpoint in
        nodes/hosts)
            if [[ $MOCK_SCENARIO == provider_failure ]]; then
                return 22
            fi
            cp "$FIXTURES_DIR/nodes.json" "$output_path"
            ;;
        check-ping|check-tcp|check-udp)
            check_type=${endpoint#check-}
            jq -n --arg request_id "$check_type-request" '{
                ok: 1,
                request_id: $request_id,
                permanent_link: ("https://check-host.net/check-report/" + $request_id),
                nodes: {}
            }' > "$output_path"
            ;;
        check-result/*)
            (( POLL_CALLS += 1 ))
            if [[ $MOCK_SCENARIO == hung ]]; then
                return 28
            fi
            check_type=${endpoint#check-result/}
            check_type=${check_type%-request}
            jq --arg scenario "$MOCK_SCENARIO" --arg check_type "$check_type" \
                '.[$scenario][$check_type]' "$FIXTURES_DIR/results.json" > "$output_path"
            ;;
        *) return 1 ;;
    esac
}

setup_check() {
    IPQUALITY_TEMP_DIR=$(mktemp -d)
    CHECK_HOST_TEMP_DIR=''
    CHECK_HOST_JSON_PATH=''
    POLL_CALLS=0
}

cleanup_check() {
    cleanup_check_host_temp
    rmdir -- "$IPQUALITY_TEMP_DIR" 2>/dev/null || true
}

test_successful_results() (
    setup_check
    trap cleanup_check EXIT
    MOCK_SCENARIO=success

    run_check_host 203.0.113.10 443 8443 ru >/dev/null || return 1

    jq -e '
        .provider_status == "AVAILABLE"
        and .target_country == "ru"
        and (.nodes.target_region | length == 2)
        and (.nodes.control | map(.country_code) == ["fi", "de", "nl"])
        and .checks.ping.complete
        and .checks.ping.summary.target_region.status == "REACHABLE"
        and .checks.ping.summary.control.status == "REACHABLE"
        and .checks.vless_tcp.summary.target_region.status == "REACHABLE"
        and .checks.vless_tcp.summary.control.status == "REACHABLE"
        and .checks.hysteria2_udp.summary.target_region.status == "OPEN_OR_FILTERED"
        and .checks.hysteria2_udp.summary.control.status == "OPEN_OR_FILTERED"
        and .checks.hysteria2_udp.complete
    ' "$CHECK_HOST_JSON_PATH" >/dev/null
)

test_failed_results() (
    setup_check
    trap cleanup_check EXIT
    MOCK_SCENARIO=failure

    run_check_host 203.0.113.10 443 8443 ru >/dev/null || return 1

    jq -e '
        .checks.ping.summary.target_region.status == "UNREACHABLE"
        and .checks.ping.summary.control.status == "UNREACHABLE"
        and .checks.vless_tcp.summary.target_region.status == "UNREACHABLE"
        and .checks.vless_tcp.summary.control.status == "UNREACHABLE"
        and .checks.hysteria2_udp.summary.target_region.status == "CLOSED"
        and .checks.hysteria2_udp.summary.control.status == "CLOSED"
    ' "$CHECK_HOST_JSON_PATH" >/dev/null
)

test_requested_country_is_used() (
    setup_check
    trap cleanup_check EXIT
    MOCK_SCENARIO=success

    run_check_host 203.0.113.10 443 8443 de >/dev/null || return 1

    jq -e '
        .target_country == "de"
        and (.nodes.target_region | map(.country_code) == ["de"])
        and (.nodes.control | map(.country_code) == ["fi", "nl", "us"])
        and .checks.vless_tcp.summary.target_region.status == "REACHABLE"
        and .checks.vless_tcp.complete
    ' "$CHECK_HOST_JSON_PATH" >/dev/null
)

test_regional_difference() (
    setup_check
    trap cleanup_check EXIT
    MOCK_SCENARIO=regional

    run_check_host 203.0.113.10 443 8443 ru >/dev/null || return 1

    jq -e '
        .checks.ping.summary.regional_difference
        and .checks.vless_tcp.summary.regional_difference
        and .checks.hysteria2_udp.summary.regional_difference
        and .checks.vless_tcp.summary.target_region.status == "UNREACHABLE"
        and .checks.vless_tcp.summary.control.status == "REACHABLE"
    ' "$CHECK_HOST_JSON_PATH" >/dev/null
)

test_incomplete_results() (
    setup_check
    trap cleanup_check EXIT
    MOCK_SCENARIO=incomplete

    run_check_host 203.0.113.10 443 8443 ru >/dev/null || return 1

    [[ $POLL_CALLS -eq $(( CHECK_HOST_POLL_ATTEMPTS * 3 )) ]] || return 1
    jq -e '
        all(.checks[]; .complete == false and .summary.control.status == "PARTIAL")
        and ([.checks[] | .results[] | select(.node == "nl1.node.check-host.net") | .status]
            | all(. == "UNKNOWN"))
    ' "$CHECK_HOST_JSON_PATH" >/dev/null
)

test_poll_failures_are_bounded() (
    setup_check
    trap cleanup_check EXIT
    MOCK_SCENARIO=hung

    run_check_host 203.0.113.10 443 8443 ru >/dev/null || return 1

    [[ $POLL_CALLS -eq $(( CHECK_HOST_POLL_ATTEMPTS * 3 )) ]] || return 1
    jq -e '
        all(.checks[]; .complete == false)
        and ([.checks[] | .results[].status] | all(. == "UNKNOWN"))
    ' "$CHECK_HOST_JSON_PATH" >/dev/null
)

test_provider_failure_is_unknown() (
    setup_check
    trap cleanup_check EXIT
    MOCK_SCENARIO=provider_failure

    run_check_host 203.0.113.10 443 8443 ru >/dev/null || return 1

    [[ $POLL_CALLS -eq 0 ]] || return 1
    jq -e '
        .provider_status == "UNKNOWN"
        and .checks.ping.summary.target_region.status == "UNKNOWN"
        and .checks.vless_tcp.summary.control.status == "UNKNOWN"
        and .checks.hysteria2_udp.complete == false
    ' "$CHECK_HOST_JSON_PATH" >/dev/null
)

test_country_without_nodes_is_unknown() (
    setup_check
    trap cleanup_check EXIT
    MOCK_SCENARIO=success

    run_check_host 203.0.113.10 443 8443 zz >/dev/null || return 1

    [[ $POLL_CALLS -eq 0 ]] || return 1
    jq -e '
        .provider_status == "UNKNOWN"
        and .target_country == "zz"
        and (.provider_error | contains("country zz"))
        and .checks.ping.summary.target_region.status == "UNKNOWN"
    ' "$CHECK_HOST_JSON_PATH" >/dev/null
)

run_test 'normalizes successful regional checks' test_successful_results
run_test 'normalizes failed regional checks' test_failed_results
run_test 'uses nodes from the requested country' test_requested_country_is_used
run_test 'detects a difference between target and control regions' test_regional_difference
run_test 'keeps incomplete node results as UNKNOWN' test_incomplete_results
run_test 'bounds polling when the result API keeps failing' test_poll_failures_are_bounded
run_test 'reports UNKNOWN when Check-Host is unavailable' test_provider_failure_is_unknown
run_test 'reports UNKNOWN when the target country has no nodes' test_country_without_nodes_is_unknown

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
