readonly CHECK_HOST_API_BASE=https://check-host.net
readonly CHECK_HOST_POLL_ATTEMPTS=4
readonly CHECK_HOST_POLL_INTERVAL=2

CHECK_HOST_TEMP_DIR=''
CHECK_HOST_JSON_PATH=''

cleanup_check_host_temp() {
    local filename
    if [[ -n ${CHECK_HOST_TEMP_DIR:-} && -d $CHECK_HOST_TEMP_DIR ]]; then
        for filename in \
            nodes.json selected-nodes.json result.json result.json.tmp \
            ping-start.json ping-raw.json ping-poll.json ping.json \
            tcp-start.json tcp-raw.json tcp-poll.json tcp.json \
            udp-start.json udp-raw.json udp-poll.json udp.json; do
            rm -f -- "$CHECK_HOST_TEMP_DIR/$filename"
        done
        rmdir -- "$CHECK_HOST_TEMP_DIR" 2>/dev/null || true
    fi
    CHECK_HOST_JSON_PATH=''
    CHECK_HOST_TEMP_DIR=''
}

check_host_sleep() {
    sleep "$CHECK_HOST_POLL_INTERVAL"
}

check_host_api_get() {
    local output_path=$1
    local endpoint=$2
    shift 2
    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 5 \
        --header 'Accept: application/json' --output "$output_path" --get \
        "$CHECK_HOST_API_BASE/$endpoint" "$@"
}

select_check_host_nodes() {
    local source_path=$1
    local output_path=$2
    local target_country=$3
    jq -e --arg target_country "$target_country" '
        def normalized_node:
            {
                id: .key,
                country_code: (.value.location[0] // ""),
                country: (.value.location[1] // ""),
                city: (.value.location[2] // ""),
                ip: (.value.ip // ""),
                asn: (.value.asn // "")
            };

        [.nodes | to_entries[] | normalized_node] | sort_by(.id) as $nodes
        | [$nodes[] | select(.country_code == $target_country)][0:3] as $target_region
        | [
            ["fi", "de", "nl", "us"][] as $country_code
            | select($country_code != $target_country)
            | first($nodes[] | select(.country_code == $country_code))
          ][0:3] as $control
        | {target_country: $target_country, target_region: $target_region, control: $control}
        | select((.target_region | length) > 0 and (.control | length) > 0)
    ' "$source_path" > "$output_path"
}

start_check_host_check() {
    local check_type=$1
    local target=$2
    local nodes_path=$3
    local output_path=$4
    local node
    local -a request_arguments=(--data-urlencode "host=$target")
    while IFS= read -r node; do
        [[ -n $node ]] || continue
        request_arguments+=(--data-urlencode "node=$node")
    done < <(jq -r '.target_region[].id, .control[].id' "$nodes_path")
    check_host_api_get "$output_path" "check-$check_type" "${request_arguments[@]}" || return 1
    jq -e '
        .ok == 1
        and (.request_id | type == "string" and length > 0)
        and (.nodes | type == "object")
    ' "$output_path" >/dev/null
}

check_host_result_complete() {
    local result_path=$1
    local nodes_path=$2
    jq -e --slurpfile selected "$nodes_path" '
        . as $result
        | (($selected[0].target_region + $selected[0].control)
            | all(.[]; .id as $id | ($result | has($id) and .[$id] != null)))
    ' "$result_path" >/dev/null
}

wait_check_host_result() {
    local request_id=$1
    local nodes_path=$2
    local output_path=$3
    local poll_path=$4
    local attempt
    local received=0
    for (( attempt = 1; attempt <= CHECK_HOST_POLL_ATTEMPTS; attempt += 1 )); do
        if check_host_api_get "$poll_path" "check-result/$request_id" \
            && jq -e 'type == "object"' "$poll_path" >/dev/null 2>&1; then
            mv -- "$poll_path" "$output_path" || return 1
            received=1
            if check_host_result_complete "$output_path" "$nodes_path"; then
                return 0
            fi
        else
            rm -f -- "$poll_path"
        fi
        if (( attempt < CHECK_HOST_POLL_ATTEMPTS )); then
            check_host_sleep
        fi
    done
    if (( received == 0 )); then
        printf '{}\n' > "$output_path"
    fi
    return 1
}

write_failed_check_start() {
    local check_type=$1
    local output_path=$2
    jq -n --arg check_type "$check_type" '{
        ok: 0,
        request_id: null,
        permanent_link: null,
        nodes: {},
        error: ("Could not start the Check-Host " + $check_type + " check.")
    }' > "$output_path"
}

normalize_check_host_result() {
    local check_type=$1
    local target=$2
    local complete=$3
    local nodes_path=$4
    local start_path=$5
    local raw_path=$6
    local output_path=$7
    jq -n \
        --arg check_type "$check_type" \
        --arg target "$target" \
        --argjson complete "$complete" \
        --slurpfile selected "$nodes_path" \
        --slurpfile started "$start_path" \
        --slurpfile raw "$raw_path" '
        def ping_result($value):
            if $value == null then
                {status: "UNKNOWN", detail: "Result was not returned."}
            else
                [$value[]?[]? | select(type == "array" and (.[0] | type) == "string")] as $probes
                | [$probes[] | select(.[0] == "OK")] as $replies
                | if ($probes | length) == 0 then
                    {status: "UNKNOWN", detail: "No valid ping probes were returned."}
                  elif ($replies | length) > 0 then
                    {
                        status: "REACHABLE",
                        detail: "\($replies | length)/\($probes | length) replies"
                    }
                  else
                    {status: "UNREACHABLE", detail: "0/\($probes | length) replies"}
                  end
            end;

        def tcp_result($value):
            if $value == null or ($value | type) != "array" or ($value | length) == 0 then
                {status: "UNKNOWN", detail: "Result was not returned."}
            elif ($value[0] | type) != "object" then
                {status: "UNKNOWN", detail: "Unexpected TCP result format."}
            elif ($value[0].error? | type) == "string" then
                {status: "UNREACHABLE", detail: $value[0].error}
            elif ($value[0].time? | type) == "number" then
                {
                    status: "REACHABLE",
                    detail: "TCP connection succeeded.",
                    latency_ms: ($value[0].time * 1000)
                }
            else
                {status: "UNKNOWN", detail: "Unexpected TCP result format."}
            end;

        def udp_result($value):
            if $value == null or ($value | type) != "array" or ($value | length) == 0 then
                {status: "UNKNOWN", detail: "Result was not returned."}
            elif ($value[0] | type) != "object" then
                {status: "UNKNOWN", detail: "Unexpected UDP result format."}
            elif ($value[0].error? | type) == "string" then
                {status: "CLOSED", detail: $value[0].error}
            else
                {
                    status: "OPEN_OR_FILTERED",
                    detail: "No UDP port-closed error was received; protocol operation is not confirmed."
                }
            end;

        def region_summary($results; $region):
            [$results[] | select(.region == $region)] as $region_results
            | ($region_results | group_by(.status)
                | map({key: .[0].status, value: length}) | from_entries) as $counts
            | {
                total: ($region_results | length),
                counts: $counts,
                status: (
                    if ($region_results | length) == 0 then "UNKNOWN"
                    elif ($counts.UNKNOWN // 0) == ($region_results | length) then "UNKNOWN"
                    elif ($counts | keys | length) == 1 then ($counts | keys[0])
                    else "PARTIAL"
                    end
                )
              };

        $selected[0] as $nodes
        | $started[0] as $start
        | $raw[0] as $raw_results
        | [
            ({region: "target_region", nodes: $nodes.target_region}, {region: "control", nodes: $nodes.control})
            | .region as $region
            | .nodes[]
            | . as $node
            | ($raw_results[$node.id] // null) as $node_result
            | ({
                node: $node.id,
                region: $region,
                country_code: $node.country_code,
                country: $node.country,
                city: $node.city,
                asn: $node.asn,
                raw_result: $node_result
              } + (
                if $check_type == "ping" then ping_result($node_result)
                elif $check_type == "tcp" then tcp_result($node_result)
                else udp_result($node_result)
                end
              ))
          ] as $results
        | region_summary($results; "target_region") as $target_summary
        | region_summary($results; "control") as $control_summary
        | {
            target: $target,
            request_id: ($start.request_id // null),
            permanent_link: ($start.permanent_link // null),
            complete: $complete,
            error: ($start.error // null),
            results: $results,
            summary: {
                target_region: $target_summary,
                control: $control_summary,
                regional_difference: (
                    ($target_summary.status != "UNKNOWN")
                    and ($control_summary.status != "UNKNOWN")
                    and ($target_summary.status != "PARTIAL")
                    and ($control_summary.status != "PARTIAL")
                    and ($target_summary.status != $control_summary.status)
                )
            }
          }
    ' > "$output_path"
}

run_check_host_check() {
    local check_type=$1
    local target=$2
    local nodes_path=$3
    local start_path="$CHECK_HOST_TEMP_DIR/$check_type-start.json"
    local raw_path="$CHECK_HOST_TEMP_DIR/$check_type-raw.json"
    local poll_path="$CHECK_HOST_TEMP_DIR/$check_type-poll.json"
    local output_path="$CHECK_HOST_TEMP_DIR/$check_type.json"
    local request_id
    local complete=false
    if start_check_host_check "$check_type" "$target" "$nodes_path" "$start_path"; then
        request_id=$(jq -r '.request_id' "$start_path")
        if wait_check_host_result "$request_id" "$nodes_path" "$raw_path" "$poll_path"; then
            complete=true
        fi
    else
        write_failed_check_start "$check_type" "$start_path" || return 1
        printf '{}\n' > "$raw_path"
    fi
    normalize_check_host_result "$check_type" "$target" "$complete" \
        "$nodes_path" "$start_path" "$raw_path" "$output_path"
}

write_unknown_check_host_result() {
    local ip=$1
    local vless_port=$2
    local hysteria2_port=$3
    local target_country=$4
    local error_message=$5
    local output_path=$6
    jq -n \
        --arg ip "$ip" \
        --arg vless_target "$ip:$vless_port" \
        --arg hysteria2_target "$ip:$hysteria2_port" \
        --arg target_country "$target_country" \
        --arg error "$error_message" '
        def unknown_check($target): {
            target: $target,
            request_id: null,
            permanent_link: null,
            complete: false,
            error: $error,
            results: [],
            summary: {
                target_region: {total: 0, counts: {}, status: "UNKNOWN"},
                control: {total: 0, counts: {}, status: "UNKNOWN"},
                regional_difference: false
            }
        };
        {
            provider: "Check-Host",
            provider_status: "UNKNOWN",
            provider_error: $error,
            target_country: $target_country,
            nodes: {target_region: [], control: []},
            checks: {
                ping: unknown_check($ip),
                vless_tcp: unknown_check($vless_target),
                hysteria2_udp: unknown_check($hysteria2_target)
            }
        }
    ' > "$output_path"
}

print_check_host_summary() {
    local result_path=$1
    printf '\nCheck-Host regional checks:\n'
    jq -r '
        if .provider_status == "UNKNOWN" then
            "  Provider: UNKNOWN (\(.provider_error))"
        else
            "  Nodes: target \(.target_country | ascii_upcase) \(.nodes.target_region | length), control \(.nodes.control | length)",
            "  Ping: target \(.checks.ping.summary.target_region.status), control \(.checks.ping.summary.control.status)",
            "  VLESS TCP: target \(.checks.vless_tcp.summary.target_region.status), control \(.checks.vless_tcp.summary.control.status)",
            "  Hysteria2 UDP: target \(.checks.hysteria2_udp.summary.target_region.status), control \(.checks.hysteria2_udp.summary.control.status)"
        end
    ' "$result_path"
}

run_check_host() {
    local ip=$1
    local vless_port=$2
    local hysteria2_port=$3
    local target_country=$4
    local nodes_path selected_nodes_path temporary_result_path error_message
    cleanup_check_host_temp
    CHECK_HOST_TEMP_DIR="$IPQUALITY_TEMP_DIR/check-host"
    mkdir -m 0700 -- "$CHECK_HOST_TEMP_DIR" || {
        printf 'Error: could not create the Check-Host temporary directory.\n' >&2
        CHECK_HOST_TEMP_DIR=''
        return 1
    }
    nodes_path="$CHECK_HOST_TEMP_DIR/nodes.json"
    selected_nodes_path="$CHECK_HOST_TEMP_DIR/selected-nodes.json"
    CHECK_HOST_JSON_PATH="$CHECK_HOST_TEMP_DIR/result.json"
    temporary_result_path="$CHECK_HOST_JSON_PATH.tmp"
    if ! check_host_api_get "$nodes_path" nodes/hosts \
        || ! jq -e '.nodes | type == "object"' "$nodes_path" >/dev/null 2>&1 \
        || ! select_check_host_nodes "$nodes_path" "$selected_nodes_path" "$target_country"; then
        error_message="Could not obtain Check-Host nodes for country $target_country and control nodes."
        write_unknown_check_host_result "$ip" "$vless_port" "$hysteria2_port" \
            "$target_country" "$error_message" "$CHECK_HOST_JSON_PATH" || return 1
        chmod 0600 "$CHECK_HOST_JSON_PATH" 2>/dev/null || true
        print_check_host_summary "$CHECK_HOST_JSON_PATH"
        return 0
    fi
    run_check_host_check ping "$ip" "$selected_nodes_path" || return 1
    run_check_host_check tcp "$ip:$vless_port" "$selected_nodes_path" || return 1
    run_check_host_check udp "$ip:$hysteria2_port" "$selected_nodes_path" || return 1
    if ! jq -n \
        --slurpfile nodes "$selected_nodes_path" \
        --slurpfile ping "$CHECK_HOST_TEMP_DIR/ping.json" \
        --slurpfile tcp "$CHECK_HOST_TEMP_DIR/tcp.json" \
        --slurpfile udp "$CHECK_HOST_TEMP_DIR/udp.json" '{
            provider: "Check-Host",
            provider_status: "AVAILABLE",
            provider_error: null,
            target_country: $nodes[0].target_country,
            nodes: {
                target_region: $nodes[0].target_region,
                control: $nodes[0].control
            },
            checks: {
                ping: $ping[0],
                vless_tcp: $tcp[0],
                hysteria2_udp: $udp[0]
            }
        }' > "$temporary_result_path"; then
        rm -f -- "$temporary_result_path"
        return 1
    fi
    chmod 0600 "$temporary_result_path" 2>/dev/null || {
        rm -f -- "$temporary_result_path"
        return 1
    }
    mv -- "$temporary_result_path" "$CHECK_HOST_JSON_PATH" || return 1
    print_check_host_summary "$CHECK_HOST_JSON_PATH"
}
