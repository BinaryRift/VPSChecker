#!/usr/bin/env bash

set -u

readonly EXIT_USAGE=2
readonly DEFAULT_VLESS_PORT=443
readonly DEFAULT_HYSTERIA2_PORT=443

usage() {
    cat <<'EOF'
Usage:
  vps-check.sh [--ip IPV4] [--vless-port PORT] [--hysteria2-port PORT]

Options:
  --ip IPV4              VPS IPv4 address. Omit to auto-detect it later.
  --vless-port PORT      VLESS TCP port (default: 443).
  --hysteria2-port PORT  Hysteria2 UDP port (default: 443).
  -h, --help             Show this help.
EOF
}

fail_usage() {
    printf 'Error: %s\n' "$1" >&2
    printf 'Run %s --help for usage.\n' "${0##*/}" >&2
    exit "$EXIT_USAGE"
}

is_ipv4() {
    local value=$1
    local first second third fourth octet

    [[ $value =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1

    IFS=. read -r first second third fourth <<< "$value"
    for octet in "$first" "$second" "$third" "$fourth"; do
        [[ $octet == 0 || $octet != 0* ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

is_port() {
    local value=$1

    [[ $value =~ ^[0-9]{1,5}$ ]] || return 1
    [[ $value == 0 || $value != 0* ]] || return 1
    (( value >= 1 && value <= 65535 ))
}

main() {
    local ip=''
    local vless_port=$DEFAULT_VLESS_PORT
    local hysteria2_port=$DEFAULT_HYSTERIA2_PORT
    local ip_seen=0
    local vless_port_seen=0
    local hysteria2_port_seen=0

    while (( $# > 0 )); do
        case $1 in
            --ip)
                (( ip_seen == 0 )) || fail_usage 'Option --ip was provided more than once.'
                (( $# >= 2 )) || fail_usage 'Option --ip requires a value.'
                ip=$2
                ip_seen=1
                shift 2
                ;;
            --vless-port)
                (( vless_port_seen == 0 )) || fail_usage 'Option --vless-port was provided more than once.'
                (( $# >= 2 )) || fail_usage 'Option --vless-port requires a value.'
                vless_port=$2
                vless_port_seen=1
                shift 2
                ;;
            --hysteria2-port)
                (( hysteria2_port_seen == 0 )) || fail_usage 'Option --hysteria2-port was provided more than once.'
                (( $# >= 2 )) || fail_usage 'Option --hysteria2-port requires a value.'
                hysteria2_port=$2
                hysteria2_port_seen=1
                shift 2
                ;;
            -h|--help)
                usage
                return 0
                ;;
            --*)
                fail_usage "Unknown option: $1"
                ;;
            *)
                fail_usage "Unexpected argument: $1"
                ;;
        esac
    done

    if (( ip_seen == 1 )) && ! is_ipv4 "$ip"; then
        fail_usage "Invalid IPv4 address: $ip"
    fi
    is_port "$vless_port" || fail_usage "Invalid VLESS port: $vless_port"
    is_port "$hysteria2_port" || fail_usage "Invalid Hysteria2 port: $hysteria2_port"

    printf 'Input valid.\n'
    if (( ip_seen == 1 )); then
        printf 'IP: %s\n' "$ip"
    else
        printf 'IP: auto-detect\n'
    fi
    printf 'VLESS TCP port: %s\n' "$vless_port"
    printf 'Hysteria2 UDP port: %s\n' "$hysteria2_port"
}

main "$@"
