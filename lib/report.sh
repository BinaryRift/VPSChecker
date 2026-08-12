REPORT_JSON_PATH=''
REPORT_TEXT_PATH=''
REPORT_TEMP_PATHS=()

cleanup_report_temp() {
    local path

    if (( ${#REPORT_TEMP_PATHS[@]} > 0 )); then
        for path in "${REPORT_TEMP_PATHS[@]}"; do
            [[ -n $path && -f $path ]] && rm -f -- "$path"
        done
    fi
    REPORT_TEMP_PATHS=()
}

build_report_json() {
    local output_path=$1
    local ip=$2
    local target_country=$3
    local vless_port=$4
    local hysteria2_port=$5
    local vless_listener=$6
    local hysteria2_listener=$7
    local generated_at=$8
    local cleanup_requested=${9:-0}
    local added_packages requested_packages updated_packages cleanup_requested_json

    cleanup_requested_json=false
    (( cleanup_requested == 1 )) && cleanup_requested_json=true

    if (( ${#DEPENDENCY_ADDED_PACKAGES[@]} > 0 )); then
        added_packages=$(jq -n '$ARGS.positional' --args "${DEPENDENCY_ADDED_PACKAGES[@]}") || return 1
    else
        added_packages='[]'
    fi
    if (( ${#DEPENDENCY_REQUESTED_PACKAGES[@]} > 0 )); then
        requested_packages=$(jq -n '$ARGS.positional' --args "${DEPENDENCY_REQUESTED_PACKAGES[@]}") || return 1
    else
        requested_packages='[]'
    fi
    if (( ${#DEPENDENCY_UPDATED_PACKAGES[@]} > 0 )); then
        updated_packages=$(jq -n '$ARGS.positional' --args "${DEPENDENCY_UPDATED_PACKAGES[@]}") || return 1
    else
        updated_packages='[]'
    fi

    jq -n \
        --arg generated_at "$generated_at" \
        --arg ip "$ip" \
        --arg target_country "$target_country" \
        --argjson vless_port "$vless_port" \
        --argjson hysteria2_port "$hysteria2_port" \
        --arg vless_listener "$vless_listener" \
        --arg hysteria2_listener "$hysteria2_listener" \
        --argjson cleanup_requested "$cleanup_requested_json" \
        --arg ipquality_version "$IPQUALITY_VERSION" \
        --arg ipquality_commit "$IPQUALITY_COMMIT" \
        --argjson added_packages "$added_packages" \
        --argjson requested_packages "$requested_packages" \
        --argjson updated_packages "$updated_packages" \
        --slurpfile raw "$IPQUALITY_JSON_PATH" \
        --slurpfile vpn "$VPN_TRUST_JSON_PATH" \
        --slurpfile network "$CHECK_HOST_JSON_PATH" '
        def listener_status($value):
            if $value == "listening" then "LISTENING"
            elif $value == "not listening" then "NOT_LISTENING"
            else "UNKNOWN"
            end;

        $raw[0] as $raw_ipquality
        | $vpn[0] as $vpn_suitability
        | $network[0] as $regional
        | ($regional.checks.vless_tcp.summary.target_region.status // "UNKNOWN") as $target_tcp
        | ($regional.checks.vless_tcp.summary.control.status // "UNKNOWN") as $control_tcp
        | ([$regional.checks.vless_tcp.results[]?
            | select(.region == "target_region" and .status == "UNREACHABLE")]
            | length) as $target_tcp_failures
        | (any($vpn_suitability.reasons[]?;
            .code == "RISK_SCORE"
            or (.code == "RISK_FACTOR"
                and any(.evidence[]?;
                    .factor as $factor | ["Tor", "Abuser", "Robot"] | index($factor) != null)))) as $material_warning
        | (any($vpn_suitability.reasons[]?;
            .code == "RISK_SCORE" or .code == "RISK_FACTOR")) as $has_reputation_signal
        | (any($vpn_suitability.reasons[]?;
            .code == "SOURCE_DISAGREEMENT" or .code == "GEOLOCATION_MISMATCH")) as $has_conflicting_data
        | (if $vpn_suitability.vpn_trust == "POOR" then
                {
                    status: "REPLACEMENT_JUSTIFIED",
                    reasons: [{
                        code: "CONFIRMED_POOR_REPUTATION",
                        message: "Strong negative reputation signals are confirmed by multiple independent sources."
                    }],
                    facts: [$vpn_suitability.reasons[]?.message]
                }
           elif listener_status($vless_listener) == "LISTENING"
                and $target_tcp == "UNREACHABLE"
                and $control_tcp == "REACHABLE"
                and $target_tcp_failures >= 2 then
                {
                    status: "REPLACEMENT_JUSTIFIED",
                    reasons: [{
                        code: "CONFIRMED_REGIONAL_TCP_FAILURE",
                        message: "VLESS TCP is listening locally and reachable from control nodes, but not from multiple target-country nodes."
                    }],
                    facts: [
                        "Local VLESS listener: LISTENING",
                        "Target-country TCP failures: \($target_tcp_failures)",
                        "Control-region TCP status: REACHABLE"
                    ]
                }
           elif $vpn_suitability.vpn_trust == "WARNING" and $material_warning then
                {
                    status: "REPLACEMENT_MAY_HELP",
                    reasons: [{
                        code: "UNCONFIRMED_REPUTATION_RISK",
                        message: "A material reputation signal exists, but independent confirmation is insufficient."
                    }],
                    facts: [$vpn_suitability.reasons[]?.message]
                }
           elif listener_status($vless_listener) == "LISTENING"
                and $target_tcp == "UNREACHABLE"
                and $control_tcp == "REACHABLE" then
                {
                    status: "REPLACEMENT_MAY_HELP",
                    reasons: [{
                        code: "LIMITED_REGIONAL_TCP_FAILURE",
                        message: "A regional TCP difference exists, but fewer than two target-country nodes confirm it."
                    }],
                    facts: ["Target-country TCP failures: \($target_tcp_failures)"]
                }
           elif $vpn_suitability.vpn_trust == "WARNING"
                and $has_conflicting_data
                and ($has_reputation_signal | not) then
                {
                    status: "INCONCLUSIVE",
                    reasons: [{
                        code: "CONFLICTING_REPUTATION_DATA",
                        message: "Reputation sources disagree without a separate material risk signal."
                    }],
                    facts: [$vpn_suitability.reasons[]?.message]
                }
           elif listener_status($vless_listener) == "NOT_LISTENING"
                and $target_tcp != "REACHABLE" then
                {
                    status: "REPLACEMENT_UNLIKELY",
                    reasons: [{
                        code: "LOCAL_SERVICE_NOT_LISTENING",
                        message: "The local VLESS service state can explain external TCP failure; replacing the IP would not fix it."
                    }],
                    facts: ["Local VLESS listener: NOT_LISTENING"]
                }
           elif $vpn_suitability.vpn_trust == "WARNING" then
                {
                    status: "REPLACEMENT_UNLIKELY",
                    reasons: [{
                        code: "EXPECTED_CLASSIFICATION",
                        message: "The warning contains only expected VPN/proxy classification."
                    }],
                    facts: [$vpn_suitability.reasons[]?.message]
                }
           elif $vpn_suitability.vpn_trust == "UNKNOWN"
                or $regional.provider_status == "UNKNOWN"
                or ($target_tcp == "UNKNOWN" or $target_tcp == "PARTIAL") then
                {
                    status: "INCONCLUSIVE",
                    reasons: [{
                        code: "INSUFFICIENT_DATA",
                        message: "Reputation or regional reachability data is incomplete."
                    }],
                    facts: []
                }
           else
                {
                    status: "REPLACEMENT_UNLIKELY",
                    reasons: [{
                        code: "NO_REPLACEMENT_EVIDENCE",
                        message: "The available checks do not provide an objective reason to replace the IP."
                    }],
                    facts: []
                }
           end) as $replacement
        | {
            schema_version: 1,
            generated_at: $generated_at,
            target: {
                ip: $ip,
                country: $target_country
            },
            reputation: {
                provider: "xykt/IPQuality",
                version: $ipquality_version,
                commit: $ipquality_commit,
                scores: ($raw_ipquality.Score // {}),
                factors: (($raw_ipquality.Factor // {}) | del(.Server)),
                geolocation: {
                    info: ($raw_ipquality.Info // {}),
                    source_country_codes: ($raw_ipquality.Factor.CountryCode // {})
                },
                ignored_signals: [
                    "mail reputation and port 25",
                    "hosting, datacenter, and server classification"
                ],
                raw_ipquality: $raw_ipquality
            },
            vpn_suitability: $vpn_suitability,
            replacement_advice: $replacement,
            regional_reachability: {
                provider: $regional.provider,
                provider_status: $regional.provider_status,
                provider_error: $regional.provider_error,
                target_country: $regional.target_country,
                nodes: $regional.nodes,
                ping: $regional.checks.ping
            },
            ports: {
                vless: {
                    transport: "tcp",
                    port: $vless_port,
                    local_listener: listener_status($vless_listener),
                    external: $regional.checks.vless_tcp
                },
                hysteria2: {
                    transport: "udp",
                    port: $hysteria2_port,
                    local_listener: listener_status($hysteria2_listener),
                    external: $regional.checks.hysteria2_udp
                }
            },
            protocol_checks: {
                vless: {
                    level: "TRANSPORT_ONLY",
                    handshake_performed: false,
                    note: "TCP reachability does not confirm a successful VLESS handshake."
                },
                hysteria2: {
                    level: "TRANSPORT_ONLY",
                    handshake_performed: false,
                    note: "OPEN_OR_FILTERED does not confirm a successful Hysteria2 handshake."
                }
            },
            cleanup: {
                temporary_files: {
                    status: "SCHEDULED_FOR_EXIT",
                    reports_preserved: true
                },
                packages: {
                    automatic_cleanup_requested: $cleanup_requested,
                    requested: $requested_packages,
                    added: $added_packages,
                    updated_existing_not_rolled_back: $updated_packages,
                    removal_status: (if ($added_packages | length) > 0
                        then (if $cleanup_requested then "SCHEDULED" else "DEFERRED" end)
                        else "NOT_REQUIRED"
                        end),
                    note: "Existing package updates are kept. Deferred packages can be removed with vps-check.sh cleanup."
                }
            }
          }
    ' > "$output_path"
}

build_text_report() {
    local json_path=$1
    local output_path=$2

    jq -r '
        "VPSChecker report",
        "=================",
        "Generated: \(.generated_at)",
        "IP: \(.target.ip)",
        "Target country: \(.target.country | ascii_upcase)",
        "",
        "VPN suitability: \(.vpn_suitability.vpn_trust)",
        "Reasons:",
        (.vpn_suitability.reasons[]? | "  - \(.message)"),
        "",
        "Replacement advice: \(.replacement_advice.status)",
        (.replacement_advice.reasons[]? | "  - \(.message)"),
        (if (.replacement_advice.facts | length) > 0 then
            "Facts:", (.replacement_advice.facts[] | "  - \(.)")
         else empty end),
        "",
        "Reputation scores:",
        (if (.reputation.scores | length) > 0 then
            (.reputation.scores | to_entries[] | "  \(.key): \(.value)")
         else "  No usable scores" end),
        (if (.vpn_suitability.manual_checks | length) > 0 then
            "Manual verification:",
            (.vpn_suitability.manual_checks[] | "  \(.service): \(.url)")
         else empty end),
        "",
        "Regional reachability (Check-Host):",
        "  Provider: \(.regional_reachability.provider_status)",
        "  Ping target/control: \(.regional_reachability.ping.summary.target_region.status) / \(.regional_reachability.ping.summary.control.status)",
        "",
        "Ports:",
        "  VLESS TCP/\(.ports.vless.port): local \(.ports.vless.local_listener), target/control \(.ports.vless.external.summary.target_region.status) / \(.ports.vless.external.summary.control.status)",
        "  Hysteria2 UDP/\(.ports.hysteria2.port): local \(.ports.hysteria2.local_listener), target/control \(.ports.hysteria2.external.summary.target_region.status) / \(.ports.hysteria2.external.summary.control.status)",
        "",
        "Protocol checks:",
        "  VLESS: TRANSPORT_ONLY; handshake not performed.",
        "  Hysteria2: TRANSPORT_ONLY; handshake not performed.",
        "",
        "Cleanup:",
        "  Temporary files: \(.cleanup.temporary_files.status)",
        "  Added package removal: \(.cleanup.packages.removal_status)"
    ' "$json_path" > "$output_path"
}

generate_reports() {
    local ip=$1
    local target_country=$2
    local vless_port=$3
    local hysteria2_port=$4
    local vless_listener=$5
    local hysteria2_listener=$6
    local cleanup_requested=${7:-0}
    local generated_at report_id json_path text_path json_temp text_temp path

    for path in "$IPQUALITY_JSON_PATH" "$VPN_TRUST_JSON_PATH" "$CHECK_HOST_JSON_PATH"; do
        [[ -f $path ]] || {
            printf 'Error: a required report input is unavailable.\n' >&2
            return 1
        }
    done

    cleanup_report_temp
    REPORT_JSON_PATH=''
    REPORT_TEXT_PATH=''
    generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
    report_id=$(date -u '+%Y%m%dT%H%M%SZ')-$$ || return 1
    json_path="$PWD/vpschecker-report-$report_id.json"
    text_path="$PWD/vpschecker-report-$report_id.txt"
    [[ ! -e $json_path && ! -e $text_path ]] || {
        printf 'Error: report output files already exist.\n' >&2
        return 1
    }

    json_temp=$(mktemp "$PWD/.vpschecker-report-json.XXXXXX") || return 1
    REPORT_TEMP_PATHS+=("$json_temp")
    text_temp=$(mktemp "$PWD/.vpschecker-report-text.XXXXXX") || return 1
    REPORT_TEMP_PATHS+=("$text_temp")

    build_report_json "$json_temp" "$ip" "$target_country" "$vless_port" \
        "$hysteria2_port" "$vless_listener" "$hysteria2_listener" "$generated_at" \
        "$cleanup_requested" || return 1
    build_text_report "$json_temp" "$text_temp" || return 1
    chmod 0600 "$json_temp" "$text_temp" || return 1
    mv -- "$json_temp" "$json_path" || return 1
    if ! mv -- "$text_temp" "$text_path"; then
        rm -f -- "$json_path"
        return 1
    fi

    REPORT_TEMP_PATHS=()
    REPORT_JSON_PATH=$json_path
    REPORT_TEXT_PATH=$text_path
}

present_reports() {
    local print_report=${1:-0}

    [[ -f ${REPORT_JSON_PATH:-} && -f ${REPORT_TEXT_PATH:-} ]] || {
        printf 'Error: final reports are unavailable.\n' >&2
        return 1
    }
    if (( print_report == 1 )); then
        printf '\n'
        cat -- "$REPORT_TEXT_PATH" || return 1
    fi
    printf '\nReports:\n'
    printf '  JSON: %s\n' "$REPORT_JSON_PATH"
    printf '  Text: %s\n' "$REPORT_TEXT_PATH"
}
