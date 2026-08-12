#!/usr/bin/env bash

set -u

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)
readonly REPUTATION_FIXTURE="$TEST_DIR/fixtures/reputation/ok.json"
readonly REPORT_FIXTURES="$TEST_DIR/fixtures/report"

IPQUALITY_VERSION=v2026-08-09
IPQUALITY_COMMIT=0ee5f192fed70c04615852efba0e4b8bd43546c7
DEPENDENCY_ADDED_PACKAGES=()
DEPENDENCY_UPDATED_PACKAGES=()
DEPENDENCY_REQUESTED_PACKAGES=()

# shellcheck source=../lib/report.sh
. "$PROJECT_DIR/lib/report.sh"

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

write_vpn_fixture() {
    local kind=$1
    local output_path=$2

    case $kind in
        ok)
            jq -n '{
                vpn_trust: "OK",
                reasons: [{code: "NO_MATERIAL_ISSUES", message: "No material issues.", evidence: []}],
                manual_checks: []
            }' > "$output_path"
            ;;
        poor)
            jq -n '{
                vpn_trust: "POOR",
                reasons: [{
                    code: "RISK_FACTOR",
                    message: "Abuse is confirmed by two sources.",
                    evidence: [
                        {factor: "Abuser", source: "IPQS"},
                        {factor: "Abuser", source: "ipapi"}
                    ]
                }],
                manual_checks: []
            }' > "$output_path"
            ;;
        warning_material)
            jq -n '{
                vpn_trust: "WARNING",
                reasons: [{
                    code: "RISK_SCORE",
                    message: "One risk score is elevated.",
                    evidence: [{source: "SCAMALYTICS", value: 45}]
                }],
                manual_checks: [{service: "Scamalytics", url: "https://scamalytics.com/ip/203.0.113.10"}]
            }' > "$output_path"
            ;;
        warning_soft)
            jq -n '{
                vpn_trust: "WARNING",
                reasons: [{
                    code: "RISK_FACTOR",
                    message: "One source classifies the IP as VPN.",
                    evidence: [{factor: "VPN", source: "IPinfo"}]
                }],
                manual_checks: []
            }' > "$output_path"
            ;;
        warning_conflict)
            jq -n '{
                vpn_trust: "WARNING",
                reasons: [{
                    code: "SOURCE_DISAGREEMENT",
                    message: "Reputation sources disagree.",
                    evidence: [{source: "IPQS"}, {source: "ipapi"}]
                }],
                manual_checks: []
            }' > "$output_path"
            ;;
        unknown)
            jq -n '{
                vpn_trust: "UNKNOWN",
                reasons: [{code: "INSUFFICIENT_DATA", message: "Insufficient reputation data.", evidence: []}],
                manual_checks: []
            }' > "$output_path"
            ;;
        *) return 1 ;;
    esac
}

setup_report() {
    local vpn_kind=$1
    local network_fixture=$2

    REPORT_TEST_DIR=$(mktemp -d)
    IPQUALITY_JSON_PATH=$REPUTATION_FIXTURE
    VPN_TRUST_JSON_PATH="$REPORT_TEST_DIR/vpn.json"
    CHECK_HOST_JSON_PATH="$REPORT_FIXTURES/$network_fixture"
    REPORT_JSON_PATH=''
    REPORT_TEXT_PATH=''
    REPORT_TEMP_PATHS=()
    DEPENDENCY_ADDED_PACKAGES=()
    DEPENDENCY_UPDATED_PACKAGES=()
    DEPENDENCY_REQUESTED_PACKAGES=()
    write_vpn_fixture "$vpn_kind" "$VPN_TRUST_JSON_PATH"
    cd "$REPORT_TEST_DIR" || return 1
}

cleanup_report_test() {
    cleanup_report_temp
    [[ -n ${REPORT_JSON_PATH:-} ]] && rm -f -- "$REPORT_JSON_PATH"
    [[ -n ${REPORT_TEXT_PATH:-} ]] && rm -f -- "$REPORT_TEXT_PATH"
    [[ -n ${VPN_TRUST_JSON_PATH:-} ]] && rm -f -- "$VPN_TRUST_JSON_PATH"
    cd "$PROJECT_DIR" || true
    rmdir -- "$REPORT_TEST_DIR" 2>/dev/null || true
}

test_stable_report_structure() (
    local before after text_report

    setup_report ok network-ok.json
    trap cleanup_report_test EXIT
    DEPENDENCY_REQUESTED_PACKAGES=(jq)
    DEPENDENCY_ADDED_PACKAGES=(jq libjq1)
    DEPENDENCY_UPDATED_PACKAGES=(curl)
    before=$(sha256sum "$IPQUALITY_JSON_PATH") || return 1

    generate_reports 203.0.113.10 ru 443 8443 listening listening >/dev/null || return 1
    after=$(sha256sum "$IPQUALITY_JSON_PATH") || return 1
    text_report=$(< "$REPORT_TEXT_PATH")

    [[ $before == "$after" && -f $REPORT_JSON_PATH && -f $REPORT_TEXT_PATH ]] || return 1
    [[ $text_report == *'VPN suitability: OK'* ]] || return 1
    [[ $text_report == *'VLESS: TRANSPORT_ONLY'* ]] || return 1
    jq -e --slurpfile raw "$IPQUALITY_JSON_PATH" '
        .schema_version == 1
        and (.reputation.raw_ipquality == $raw[0])
        and (.reputation.factors | has("Server") | not)
        and .vpn_suitability.vpn_trust == "OK"
        and .replacement_advice.status == "REPLACEMENT_UNLIKELY"
        and .regional_reachability.target_country == "ru"
        and .ports.vless.local_listener == "LISTENING"
        and .ports.hysteria2.port == 8443
        and .protocol_checks.vless.handshake_performed == false
        and .cleanup.packages.added == ["jq", "libjq1"]
        and .cleanup.packages.updated_existing_not_rolled_back == ["curl"]
        and .cleanup.packages.removal_status == "NOT_PERFORMED"
    ' "$REPORT_JSON_PATH" >/dev/null
)

test_poor_reputation_justifies_replacement() (
    setup_report poor network-ok.json
    trap cleanup_report_test EXIT

    generate_reports 203.0.113.10 ru 443 8443 listening listening >/dev/null || return 1
    jq -e '
        .replacement_advice.status == "REPLACEMENT_JUSTIFIED"
        and (.replacement_advice.reasons | map(.code) | index("CONFIRMED_POOR_REPUTATION") != null)
    ' "$REPORT_JSON_PATH" >/dev/null
)

test_confirmed_regional_failure_justifies_replacement() (
    setup_report ok network-regional.json
    trap cleanup_report_test EXIT

    generate_reports 203.0.113.10 ru 443 8443 listening listening >/dev/null || return 1
    jq -e '
        .replacement_advice.status == "REPLACEMENT_JUSTIFIED"
        and (.replacement_advice.reasons | map(.code) | index("CONFIRMED_REGIONAL_TCP_FAILURE") != null)
    ' "$REPORT_JSON_PATH" >/dev/null
)

test_material_warning_may_benefit_from_replacement() (
    setup_report warning_material network-ok.json
    trap cleanup_report_test EXIT

    generate_reports 203.0.113.10 ru 443 8443 listening listening >/dev/null || return 1
    jq -e '.replacement_advice.status == "REPLACEMENT_MAY_HELP"' "$REPORT_JSON_PATH" >/dev/null
)

test_expected_vpn_classification_does_not_justify_replacement() (
    setup_report warning_soft network-ok.json
    trap cleanup_report_test EXIT

    generate_reports 203.0.113.10 ru 443 8443 listening listening >/dev/null || return 1
    jq -e '.replacement_advice.status == "REPLACEMENT_UNLIKELY"' "$REPORT_JSON_PATH" >/dev/null
)

test_local_service_failure_does_not_justify_replacement() (
    setup_report ok network-regional.json
    trap cleanup_report_test EXIT

    generate_reports 203.0.113.10 ru 443 8443 'not listening' listening >/dev/null || return 1
    jq -e '
        .replacement_advice.status == "REPLACEMENT_UNLIKELY"
        and (.replacement_advice.reasons | map(.code) | index("LOCAL_SERVICE_NOT_LISTENING") != null)
    ' "$REPORT_JSON_PATH" >/dev/null
)

test_missing_data_is_inconclusive() (
    setup_report unknown network-unknown.json
    trap cleanup_report_test EXIT

    generate_reports 203.0.113.10 ru 443 8443 unknown unknown >/dev/null || return 1
    jq -e '.replacement_advice.status == "INCONCLUSIVE"' "$REPORT_JSON_PATH" >/dev/null
)

test_conflicting_data_is_inconclusive() (
    setup_report warning_conflict network-ok.json
    trap cleanup_report_test EXIT

    generate_reports 203.0.113.10 ru 443 8443 listening listening >/dev/null || return 1
    jq -e '
        .replacement_advice.status == "INCONCLUSIVE"
        and (.replacement_advice.reasons | map(.code) | index("CONFLICTING_REPUTATION_DATA") != null)
    ' "$REPORT_JSON_PATH" >/dev/null
)

run_test 'creates stable JSON and text reports without changing raw IPQuality data' test_stable_report_structure
run_test 'justifies replacement for independently confirmed poor reputation' test_poor_reputation_justifies_replacement
run_test 'justifies replacement for a confirmed regional TCP failure' test_confirmed_regional_failure_justifies_replacement
run_test 'marks a material but unconfirmed reputation warning as MAY_HELP' test_material_warning_may_benefit_from_replacement
run_test 'does not justify replacement for VPN classification alone' test_expected_vpn_classification_does_not_justify_replacement
run_test 'does not justify replacement when the local service is not listening' test_local_service_failure_does_not_justify_replacement
run_test 'returns INCONCLUSIVE when required data is unavailable' test_missing_data_is_inconclusive
run_test 'returns INCONCLUSIVE when reputation sources only conflict' test_conflicting_data_is_inconclusive

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
