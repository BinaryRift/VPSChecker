#!/usr/bin/env bash

set -u

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)
readonly REPUTATION_FIXTURE="$TEST_DIR/fixtures/reputation/ok.json"
readonly REPORT_FIXTURES="$TEST_DIR/fixtures/report"

VPSCHECK_VERSION=0.1.0
IPQUALITY_VERSION=v2026-08-09
IPQUALITY_COMMIT=0ee5f192fed70c04615852efba0e4b8bd43546c7
DEPENDENCY_ADDED_PACKAGES=()
DEPENDENCY_UPDATED_PACKAGES=()
DEPENDENCY_REQUESTED_PACKAGES=()

# shellcheck source=../lib/terminal.sh
. "$PROJECT_DIR/lib/terminal.sh"
# shellcheck source=../lib/report_path.sh
. "$PROJECT_DIR/lib/report_path.sh"
# shellcheck source=../lib/report.sh
. "$PROJECT_DIR/lib/report.sh"
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
    REPORT_TEST_DIR=$(cd "$REPORT_TEST_DIR" && pwd -P) || return 1
    IPQUALITY_JSON_PATH=$REPUTATION_FIXTURE
    VPN_TRUST_JSON_PATH="$REPORT_TEST_DIR/vpn.json"
    CHECK_HOST_JSON_PATH="$REPORT_FIXTURES/$network_fixture"
    REPORT_JSON_PATH=''
    REPORT_TEXT_PATH=''
    REPORT_OUTPUT_DIR=''
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
    [[ -n ${REPORT_OUTPUT_DIR:-} && -d $REPORT_OUTPUT_DIR ]] \
        && rmdir -- "$REPORT_OUTPUT_DIR" 2>/dev/null || true
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
    [[ ${REPORT_JSON_PATH%/*} == "$REPORT_TEST_DIR/reports" ]] || return 1
    [[ $text_report == *'Version: 0.1.0'* ]] || return 1
    [[ $text_report == *'VPN suitability: OK'* ]] || return 1
    [[ $text_report == *'VLESS: TRANSPORT_ONLY'* ]] || return 1
    ! grep -q $'\033' "$REPORT_JSON_PATH" || return 1
    ! grep -q $'\033' "$REPORT_TEXT_PATH" || return 1
    jq -e --slurpfile raw "$IPQUALITY_JSON_PATH" '
        .schema_version == 1
        and .tool == {name: "VPSChecker", version: "0.1.0"}
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
        and .cleanup.packages.automatic_cleanup_requested == false
        and .cleanup.packages.removal_status == "DEFERRED"
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

test_console_output_is_compact_by_default() (
    local output

    setup_report ok network-ok.json
    trap cleanup_report_test EXIT

    generate_reports 203.0.113.10 ru 443 8443 listening listening || return 1
    output=$(present_reports) || return 1
    [[ $output == *'Result:'* \
        && $output == *'VPN suitability: OK'* \
        && $output == *'Replacement advice: REPLACEMENT_UNLIKELY'* \
        && $output != *'VPSChecker report'* \
        && $output != *'Manual verification:'* ]]
)

test_console_output_includes_manual_checks_when_needed() (
    local output

    setup_report warning_material network-ok.json
    trap cleanup_report_test EXIT

    generate_reports 203.0.113.10 ru 443 8443 listening listening || return 1
    output=$(present_reports) || return 1
    [[ $output == *'VPN suitability: WARNING'* \
        && $output == *'Replacement advice: REPLACEMENT_MAY_HELP'* \
        && $output == *'Manual verification:'* \
        && $output == *'Scamalytics: https://scamalytics.com/ip/203.0.113.10'* ]]
)

test_console_output_colors_only_result_statuses() (
    local output output_path

    setup_report ok network-ok.json
    trap cleanup_report_test EXIT
    output_path="$REPORT_TEST_DIR/output.txt"
    generate_reports 203.0.113.10 ru 443 8443 listening listening || return 1
    terminal_stream_is_tty() {
        return 0
    }
    TERM=xterm
    unset NO_COLOR

    present_reports > "$output_path" || return 1
    output=$(< "$output_path")
    rm -f -- "$output_path"
    [[ $output == *$'VPN suitability: \033[32mOK\033[0m'* \
        && $output == *$'Replacement advice: \033[32mREPLACEMENT_UNLIKELY\033[0m'* ]]
)

test_console_output_can_be_enabled() (
    local output output_path

    setup_report ok network-ok.json
    trap cleanup_report_test EXIT

    generate_reports 203.0.113.10 ru 443 8443 listening listening || return 1
    output_path="$REPORT_TEST_DIR/output.txt"
    terminal_stream_is_tty() {
        return 0
    }
    TERM=xterm
    unset NO_COLOR

    present_reports 1 > "$output_path" || return 1
    output=$(< "$output_path")
    rm -f -- "$output_path"
    [[ $output == *'VPSChecker report'* \
        && $output == *'VPN suitability: OK'* \
        && $output != *$'\033['* ]]
)

test_redirected_console_output_stays_plain() (
    local output

    setup_report ok network-ok.json
    trap cleanup_report_test EXIT
    generate_reports 203.0.113.10 ru 443 8443 listening listening || return 1
    TERM=xterm
    unset NO_COLOR

    output=$(present_reports) || return 1
    [[ $output == *'VPN suitability: OK'* && $output != *$'\033['* ]]
)

test_urls_and_paths_stay_plain_in_terminal() (
    local output output_path line url_line='' json_line=''

    setup_report warning_material network-ok.json
    trap cleanup_report_test EXIT
    generate_reports 203.0.113.10 ru 443 8443 listening listening || return 1
    output_path="$REPORT_TEST_DIR/output.txt"
    terminal_stream_is_tty() {
        return 0
    }
    TERM=xterm
    unset NO_COLOR

    present_reports > "$output_path" || return 1
    output=$(< "$output_path")
    rm -f -- "$output_path"
    while IFS= read -r line; do
        case $line in
            *'Scamalytics: https://'*) url_line=$line ;;
            '  JSON: '*) json_line=$line ;;
        esac
    done <<< "$output"
    [[ -n $url_line && -n $json_line \
        && $url_line != *$'\033['* \
        && $json_line != *$'\033['* ]]
)

test_finalizes_cleanup_status() (
    local text_report

    setup_report ok network-ok.json
    trap cleanup_report_test EXIT
    DEPENDENCY_ADDED_PACKAGES=(jq libjq1)

    generate_reports 203.0.113.10 ru 443 8443 listening listening || return 1
    finalize_report_cleanup REMOVED || return 1
    text_report=$(< "$REPORT_TEXT_PATH")
    [[ $text_report == *'Temporary files: REMOVED'* ]] || return 1
    [[ $text_report == *'Added package removal: REMOVED'* ]] || return 1
    jq -e '
        .cleanup.temporary_files.status == "REMOVED"
        and .cleanup.packages.removal_status == "REMOVED"
    ' "$REPORT_JSON_PATH" >/dev/null
)

test_marks_automatic_cleanup_as_scheduled() (
    setup_report ok network-ok.json
    trap cleanup_report_test EXIT
    DEPENDENCY_ADDED_PACKAGES=(jq)

    generate_reports 203.0.113.10 ru 443 8443 listening listening 1 || return 1
    jq -e '
        .cleanup.packages.automatic_cleanup_requested == true
        and .cleanup.packages.removal_status == "SCHEDULED"
    ' "$REPORT_JSON_PATH" >/dev/null
)

test_uses_custom_report_directory() (
    setup_report ok network-ok.json
    trap cleanup_report_test EXIT

    generate_reports 203.0.113.10 ru 443 8443 listening listening 0 custom-reports || return 1
    [[ ${REPORT_JSON_PATH%/*} == "$REPORT_TEST_DIR/custom-reports" ]] || return 1
    [[ ${REPORT_TEXT_PATH%/*} == "$REPORT_TEST_DIR/custom-reports" ]]
)

test_uses_absolute_report_directory() (
    local absolute_dir

    setup_report ok network-ok.json
    trap cleanup_report_test EXIT
    absolute_dir="$REPORT_TEST_DIR/absolute-reports"

    generate_reports 203.0.113.10 ru 443 8443 listening listening 0 "$absolute_dir" || return 1
    [[ ${REPORT_JSON_PATH%/*} == "$absolute_dir" ]]
)

test_rejects_report_path_that_is_a_file() (
    local report_file

    setup_report ok network-ok.json
    trap cleanup_report_test EXIT
    report_file="$REPORT_TEST_DIR/report-file"
    touch "$report_file" || return 1
    if generate_reports 203.0.113.10 ru 443 8443 listening listening 0 "$report_file" \
        >/dev/null 2>&1; then
        rm -f -- "$report_file"
        return 1
    fi
    rm -f -- "$report_file"
)

run_test 'creates stable JSON and text reports without changing raw IPQuality data' test_stable_report_structure
run_test 'justifies replacement for independently confirmed poor reputation' test_poor_reputation_justifies_replacement
run_test 'justifies replacement for a confirmed regional TCP failure' test_confirmed_regional_failure_justifies_replacement
run_test 'marks a material but unconfirmed reputation warning as MAY_HELP' test_material_warning_may_benefit_from_replacement
run_test 'does not justify replacement for VPN classification alone' test_expected_vpn_classification_does_not_justify_replacement
run_test 'does not justify replacement when the local service is not listening' test_local_service_failure_does_not_justify_replacement
run_test 'returns INCONCLUSIVE when required data is unavailable' test_missing_data_is_inconclusive
run_test 'returns INCONCLUSIVE when reputation sources only conflict' test_conflicting_data_is_inconclusive
run_test 'prints a compact result by default' test_console_output_is_compact_by_default
run_test 'includes manual verification links in a compact result when needed' test_console_output_includes_manual_checks_when_needed
run_test 'colors only compact result statuses in a terminal' test_console_output_colors_only_result_statuses
run_test 'prints the text report when requested' test_console_output_can_be_enabled
run_test 'keeps redirected console output plain' test_redirected_console_output_stays_plain
run_test 'keeps URLs and report paths plain in a terminal' test_urls_and_paths_stay_plain_in_terminal
run_test 'finalizes cleanup status in both reports' test_finalizes_cleanup_status
run_test 'marks requested automatic cleanup as scheduled' test_marks_automatic_cleanup_as_scheduled
run_test 'uses a custom report directory' test_uses_custom_report_directory
run_test 'uses an absolute report directory' test_uses_absolute_report_directory
run_test 'rejects a report path that is a file' test_rejects_report_path_that_is_a_file

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
