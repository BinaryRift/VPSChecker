#!/usr/bin/env bash

set -u

readonly EXIT_USAGE=2
readonly DEFAULT_VLESS_PORT=443
readonly DEFAULT_HYSTERIA2_PORT=443
readonly DEFAULT_OS_RELEASE_FILE=/etc/os-release
readonly IP_LOOKUP_URL=https://api.ipify.org
readonly -a CHECKED_COMMANDS=(curl jq bc nc dig ip ss dpkg-query apt-get)
readonly -a CHECKED_PACKAGES=(jq curl bc netcat-openbsd dnsutils iproute2)

usage() {
    cat <<'EOF'
Usage:
  vps-check.sh [--ip IPV4] [--vless-port PORT] [--hysteria2-port PORT]

Options:
  --ip IPV4              VPS IPv4 address. Omit to auto-detect it.
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

read_os_info() (
    local os_release_file=$1
    local ID='unknown'
    local VERSION_ID='unknown'
    local PRETTY_NAME='Unknown Linux'

    [[ -r $os_release_file ]] || return 1

    # /etc/os-release is specified as shell-compatible variable assignments.
    # shellcheck disable=SC1090
    . "$os_release_file"
    printf '%s\t%s\t%s\n' "$ID" "$VERSION_ID" "$PRETTY_NAME"
)

is_supported_os() {
    case $1 in
        ubuntu|debian) return 0 ;;
        *) return 1 ;;
    esac
}

privilege_state() {
    local uid

    uid=$(id -u 2>/dev/null) || uid=unknown
    if [[ $uid == 0 ]]; then
        printf 'root\n'
    elif command -v sudo >/dev/null 2>&1; then
        printf 'non-root; sudo command available (not invoked)\n'
    else
        printf 'non-root; sudo command missing\n'
    fi
}

detect_external_ipv4() {
    local ip

    command -v curl >/dev/null 2>&1 || return 1
    ip=$(curl --ipv4 --fail --silent --show-error --max-time 10 "$IP_LOOKUP_URL" 2>/dev/null) || return 1
    is_ipv4 "$ip" || return 1
    printf '%s\n' "$ip"
}

command_state() {
    if command -v "$1" >/dev/null 2>&1; then
        printf 'available\n'
    else
        printf 'missing\n'
    fi
}

package_state() {
    local status

    command -v dpkg-query >/dev/null 2>&1 || {
        printf 'unknown\n'
        return
    }

    status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || {
        printf 'not installed\n'
        return
    }
    if [[ $status == 'install ok installed' ]]; then
        printf 'installed\n'
    else
        printf 'not installed\n'
    fi
}

listener_state() {
    local protocol=$1
    local port=$2
    local output

    command -v ss >/dev/null 2>&1 || {
        printf 'unknown (ss missing)\n'
        return
    }

    case $protocol in
        tcp) output=$(ss -H -ltn "sport = :$port" 2>/dev/null) || {
            printf 'unknown (ss failed)\n'
            return
        } ;;
        udp) output=$(ss -H -lun "sport = :$port" 2>/dev/null) || {
            printf 'unknown (ss failed)\n'
            return
        } ;;
        *) return 1 ;;
    esac

    if [[ -n $output ]]; then
        printf 'listening\n'
    else
        printf 'not listening\n'
    fi
}

run_preflight() {
    local requested_ip=$1
    local vless_port=$2
    local hysteria2_port=$3
    local os_release_file=${VPSCHECK_OS_RELEASE_FILE:-$DEFAULT_OS_RELEASE_FILE}
    local os_info os_id os_version os_name external_ip command package
    local failed=0

    printf '\nPreflight:\n'

    if os_info=$(read_os_info "$os_release_file"); then
        IFS=$'\t' read -r os_id os_version os_name <<< "$os_info"
        if is_supported_os "$os_id"; then
            printf '  OS: %s (%s %s; supported)\n' "$os_name" "$os_id" "$os_version"
        else
            printf '  OS: %s (%s %s; unsupported)\n' "$os_name" "$os_id" "$os_version"
            failed=1
        fi
    else
        printf '  OS: unknown (/etc/os-release is unavailable)\n'
        failed=1
    fi

    printf '  Bash: %s\n' "$BASH_VERSION"
    printf '  Privileges: %s\n' "$(privilege_state)"

    if [[ -n $requested_ip ]]; then
        external_ip=$requested_ip
        printf '  External IPv4: %s (provided)\n' "$external_ip"
    elif external_ip=$(detect_external_ipv4); then
        printf '  External IPv4: %s (detected)\n' "$external_ip"
    else
        printf '  External IPv4: unavailable\n'
        failed=1
    fi

    printf '  Commands:\n'
    for command in "${CHECKED_COMMANDS[@]}"; do
        printf '    %s: %s\n' "$command" "$(command_state "$command")"
    done

    printf '  APT packages:\n'
    for package in "${CHECKED_PACKAGES[@]}"; do
        printf '    %s: %s\n' "$package" "$(package_state "$package")"
    done

    printf '  Local listeners:\n'
    printf '    VLESS TCP/%s: %s\n' "$vless_port" "$(listener_state tcp "$vless_port")"
    printf '    Hysteria2 UDP/%s: %s\n' "$hysteria2_port" "$(listener_state udp "$hysteria2_port")"

    (( failed == 0 ))
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

    run_preflight "$ip" "$vless_port" "$hysteria2_port"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
