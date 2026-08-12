VPN_TRUST_JSON_PATH=''
VPN_TRUST_TEMP_PATH=''
VPN_TRUST_STATUS=''

cleanup_reputation_temp() {
    if [[ -n ${VPN_TRUST_TEMP_PATH:-} && -f $VPN_TRUST_TEMP_PATH ]]; then
        rm -f -- "$VPN_TRUST_TEMP_PATH"
    fi
    if [[ -n ${VPN_TRUST_JSON_PATH:-} && -f $VPN_TRUST_JSON_PATH ]]; then
        rm -f -- "$VPN_TRUST_JSON_PATH"
    fi

    VPN_TRUST_TEMP_PATH=''
    VPN_TRUST_JSON_PATH=''
    VPN_TRUST_STATUS=''
}

evaluate_vpn_trust() {
    local raw_json_path=$1
    local output_path temporary_path

    [[ -f $raw_json_path ]] || {
        printf 'Error: IPQuality JSON is unavailable for reputation evaluation.\n' >&2
        return 1
    }
    [[ -n ${IPQUALITY_TEMP_DIR:-} && -d $IPQUALITY_TEMP_DIR ]] || {
        printf 'Error: the temporary result directory is unavailable.\n' >&2
        return 1
    }
    command -v jq >/dev/null 2>&1 || {
        printf 'Error: jq is required to evaluate IP reputation.\n' >&2
        return 1
    }

    cleanup_reputation_temp
    output_path="$IPQUALITY_TEMP_DIR/vpn-trust.json"
    temporary_path="$output_path.tmp"
    VPN_TRUST_TEMP_PATH=$temporary_path

    # Score thresholds mirror the risk bands in the pinned IPQuality source.
    if ! jq '
        def numeric_value:
            if type == "number" then .
            elif type == "string" then
                gsub("%"; "") as $value
                | if ($value | test("^[0-9]+([.][0-9]+)?$"))
                  then ($value | tonumber)
                  else null
                  end
            else null
            end;

        def score_data:
            (.Score // {}) as $score
            | [
                {source: "IP2LOCATION", value: ($score.IP2LOCATION | numeric_value), warning: 33, severe: 66},
                {source: "SCAMALYTICS", value: ($score.SCAMALYTICS | numeric_value), warning: 20, severe: 60},
                {source: "ipapi", value: ($score.ipapi | numeric_value), warning: 0.85, severe: 3},
                {source: "AbuseIPDB", value: ($score.AbuseIPDB | numeric_value), warning: 25, severe: 75},
                {source: "IPQS", value: ($score.IPQS | numeric_value), warning: 75, severe: 85},
                {source: "DBIP", value: ($score.DBIP | numeric_value), warning: 50, severe: 100}
              ]
            | map(select(.value != null));

        def factor_data:
            [
                ((.Factor // {}) | to_entries[]) as $factor
                | $factor.key as $factor_name
                | select(["Proxy", "VPN", "Tor", "Server", "Abuser", "Robot"] | index($factor_name))
                | (($factor.value // {}) | to_entries[])
                | select(.value == true or .value == false)
                | {factor: $factor_name, source: .key, value: .value}
            ];

        def country_data:
            [
                ((.Factor.CountryCode // {}) | to_entries[])
                | .value as $country
                | select(($country | type) == "string")
                | select($country | test("^[A-Za-z]{2}$"))
                | {source: .key, country: ($country | ascii_upcase)}
            ];

        score_data as $scores
        | factor_data as $factors
        | country_data as $countries
        | ($factors | map(select(.factor != "Server"))) as $evaluated_factors
        | ($scores
            | map(select(.value >= .warning)
                | . + {severity: (if .value >= .severe then "severe" else "elevated" end)}
                | del(.warning, .severe))) as $risky_scores
        | ($evaluated_factors
            | map(select(.value == true)
                | .factor as $factor_name
                | select(["Tor", "Abuser", "Robot"] | index($factor_name)))) as $strong_factors
        | ($evaluated_factors
            | map(select(.value == true)
                | .factor as $factor_name
                | select(["Proxy", "VPN"] | index($factor_name)))) as $soft_factors
        | ($evaluated_factors
            | group_by(.factor)
            | map(select((map(.value) | unique | length) > 1)
                | {
                    factor: .[0].factor,
                    positive_sources: [ .[] | select(.value == true) | .source ],
                    negative_sources: [ .[] | select(.value == false) | .source ]
                  })) as $factor_conflicts
        | ($countries | map(.country) | unique) as $country_codes
        | (([$scores[].source] + [$evaluated_factors[].source] + [$countries[].source]) | unique) as $known_sources
        | (([$risky_scores[] | select(.severity == "severe") | .source]
            + [$strong_factors[].source]) | unique) as $confirmed_negative_sources
        | (($risky_scores | length) > 0
            or ($strong_factors | length) > 0
            or ($soft_factors | length) > 0
            or ($factor_conflicts | length) > 0
            or ($country_codes | length) > 1) as $has_problem
        | (if ($confirmed_negative_sources | length) >= 2 then "POOR"
           elif $has_problem then "WARNING"
           elif ($known_sources | length) < 2 then "UNKNOWN"
           else "OK"
           end) as $status
        | ((if ($risky_scores | length) > 0 then
                [{
                    code: "RISK_SCORE",
                    message: "Risk or fraud scores exceed source-specific thresholds.",
                    evidence: $risky_scores
                }]
            else [] end)
            + (if (($strong_factors + $soft_factors) | length) > 0 then
                [{
                    code: "RISK_FACTOR",
                    message: "Reputation sources report VPN-relevant risk factors.",
                    evidence: (($strong_factors + $soft_factors) | map(del(.value)))
                }]
            else [] end)
            + (if ($factor_conflicts | length) > 0 then
                [{
                    code: "SOURCE_DISAGREEMENT",
                    message: "Reputation sources disagree about one or more risk factors.",
                    evidence: $factor_conflicts
                }]
            else [] end)
            + (if ($country_codes | length) > 1 then
                [{
                    code: "GEOLOCATION_MISMATCH",
                    message: "Reputation sources report different countries for the IP.",
                    evidence: $countries
                }]
            else [] end)) as $problem_reasons
        | (if $status == "UNKNOWN" then
                [{
                    code: "INSUFFICIENT_DATA",
                    message: "Fewer than two independent reputation sources returned usable data.",
                    evidence: $known_sources
                }]
           elif $status == "OK" then
                [{
                    code: "NO_MATERIAL_ISSUES",
                    message: "No material VPN trust issues were found in the available reputation data.",
                    evidence: $known_sources
                }]
           else $problem_reasons
           end) as $reasons
        | {
            vpn_trust: $status,
            reasons: $reasons,
            manual_checks: (if $status == "WARNING" or $status == "POOR" then
                (.Head.IP // "") as $ip
                | [
                    {service: "AbuseIPDB", url: "https://www.abuseipdb.com/check/\($ip)"},
                    {service: "Scamalytics", url: "https://scamalytics.com/ip/\($ip)"},
                    {service: "IPQualityScore", url: "https://www.ipqualityscore.com/free-ip-lookup-proxy-vpn-test/lookup/\($ip)"},
                    {service: "VirusTotal", url: "https://www.virustotal.com/gui/ip-address/\($ip)"},
                    {service: "Cisco Talos", url: "https://talosintelligence.com/reputation_center/lookup?search=\($ip)"}
                  ]
              else []
              end)
          }
    ' "$raw_json_path" > "$temporary_path"; then
        rm -f -- "$temporary_path"
        printf 'Error: could not evaluate IPQuality reputation data.\n' >&2
        return 1
    fi

    chmod 0600 "$temporary_path" 2>/dev/null || {
        rm -f -- "$temporary_path"
        printf 'Error: could not restrict permissions on the reputation result.\n' >&2
        return 1
    }
    mv -- "$temporary_path" "$output_path" || {
        rm -f -- "$temporary_path"
        printf 'Error: could not save the reputation result.\n' >&2
        return 1
    }
    VPN_TRUST_TEMP_PATH=''

    VPN_TRUST_STATUS=$(jq -er '.vpn_trust | select(. == "OK" or . == "WARNING" or . == "POOR" or . == "UNKNOWN")' \
        "$output_path") || {
        rm -f -- "$output_path"
        printf 'Error: the reputation evaluator produced an invalid result.\n' >&2
        return 1
    }
    VPN_TRUST_JSON_PATH=$output_path

    printf 'VPN trust: %s\n' "$VPN_TRUST_STATUS"
}
