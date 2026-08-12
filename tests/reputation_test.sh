#!/usr/bin/env bash

set -u

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)
readonly FIXTURES_DIR="$TEST_DIR/fixtures/reputation"

# shellcheck source=../lib/reputation.sh
. "$PROJECT_DIR/lib/reputation.sh"

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

setup_result_dir() {
    IPQUALITY_TEMP_DIR=$(mktemp -d)
    VPN_TRUST_JSON_PATH=''
    VPN_TRUST_STATUS=''
}

cleanup_result_dir() {
    cleanup_reputation_temp
    rmdir -- "$IPQUALITY_TEMP_DIR" 2>/dev/null || true
}

test_ok_ignores_hosting_and_mail() (
    local before after

    setup_result_dir
    trap cleanup_result_dir EXIT
    before=$(sha256sum "$FIXTURES_DIR/ok.json") || return 1

    evaluate_vpn_trust "$FIXTURES_DIR/ok.json" >/dev/null || return 1
    after=$(sha256sum "$FIXTURES_DIR/ok.json") || return 1

    [[ $VPN_TRUST_STATUS == OK ]] || return 1
    [[ $before == "$after" ]] || return 1
    jq -e '
        .vpn_trust == "OK"
        and (.reasons | map(.code) == ["NO_MATERIAL_ISSUES"])
        and (.manual_checks == [])
    ' "$VPN_TRUST_JSON_PATH" >/dev/null
)

test_warning_has_concrete_reasons_and_links() (
    setup_result_dir
    trap cleanup_result_dir EXIT

    evaluate_vpn_trust "$FIXTURES_DIR/warning.json" >/dev/null || return 1

    [[ $VPN_TRUST_STATUS == WARNING ]] || return 1
    jq -e '
        (.reasons | map(.code) | index("RISK_SCORE") != null)
        and (.reasons | map(.code) | index("RISK_FACTOR") != null)
        and (.reasons | map(.code) | index("SOURCE_DISAGREEMENT") != null)
        and (.manual_checks | length == 5)
        and (.manual_checks[] | .url | contains("203.0.113.20"))
    ' "$VPN_TRUST_JSON_PATH" >/dev/null
)

test_poor_requires_independent_strong_sources() (
    setup_result_dir
    trap cleanup_result_dir EXIT

    evaluate_vpn_trust "$FIXTURES_DIR/poor.json" >/dev/null || return 1

    [[ $VPN_TRUST_STATUS == POOR ]] || return 1
    jq -e '
        .vpn_trust == "POOR"
        and (.reasons[] | select(.code == "RISK_FACTOR")
            | (.evidence | map(.source) | unique | length) == 2)
        and (.manual_checks | length == 5)
    ' "$VPN_TRUST_JSON_PATH" >/dev/null
)

test_poor_for_independent_severe_scores() (
    local fixture

    setup_result_dir
    fixture=$(mktemp)
    trap 'rm -f -- "$fixture"; cleanup_result_dir' EXIT
    jq '
        .Score.IP2LOCATION = "70"
        | .Score.SCAMALYTICS = "65"
        | .Factor.Proxy.SCAMALYTICS = false
    ' "$FIXTURES_DIR/warning.json" > "$fixture" || return 1

    evaluate_vpn_trust "$fixture" >/dev/null || return 1

    [[ $VPN_TRUST_STATUS == POOR ]] || return 1
    jq -e '
        .reasons[] | select(.code == "RISK_SCORE")
        | [.evidence[] | select(.severity == "severe") | .source]
        | unique | length == 2
    ' "$VPN_TRUST_JSON_PATH" >/dev/null
)

test_unknown_for_insufficient_data() (
    setup_result_dir
    trap cleanup_result_dir EXIT

    evaluate_vpn_trust "$FIXTURES_DIR/unknown.json" >/dev/null || return 1

    [[ $VPN_TRUST_STATUS == UNKNOWN ]] || return 1
    jq -e '
        .vpn_trust == "UNKNOWN"
        and (.reasons | map(.code) == ["INSUFFICIENT_DATA"])
        and (.manual_checks == [])
    ' "$VPN_TRUST_JSON_PATH" >/dev/null
)

test_geolocation_mismatch_is_warning() (
    local fixture

    setup_result_dir
    fixture=$(mktemp)
    trap 'rm -f -- "$fixture"; cleanup_result_dir' EXIT
    jq '.Factor.CountryCode.IPinfo = "DE"' "$FIXTURES_DIR/ok.json" > "$fixture" || return 1

    evaluate_vpn_trust "$fixture" >/dev/null || return 1

    [[ $VPN_TRUST_STATUS == WARNING ]] || return 1
    jq -e '.reasons | map(.code) | index("GEOLOCATION_MISMATCH") != null' \
        "$VPN_TRUST_JSON_PATH" >/dev/null
)

run_test 'returns OK while ignoring hosting and mail-only signals' test_ok_ignores_hosting_and_mail
run_test 'returns WARNING with concrete reasons and manual links' test_warning_has_concrete_reasons_and_links
run_test 'returns POOR for strong signals from independent sources' test_poor_requires_independent_strong_sources
run_test 'returns POOR for severe scores from independent sources' test_poor_for_independent_severe_scores
run_test 'returns UNKNOWN when reputation data is insufficient' test_unknown_for_insufficient_data
run_test 'returns WARNING when country results disagree' test_geolocation_mismatch_is_warning

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
