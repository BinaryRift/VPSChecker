#!/usr/bin/env bash

set -u

readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/version.sh
. "$SCRIPT_DIR/lib/version.sh"
# shellcheck source=lib/terminal.sh
. "$SCRIPT_DIR/lib/terminal.sh"
# shellcheck source=lib/dependencies.sh
. "$SCRIPT_DIR/lib/dependencies.sh"
# shellcheck source=lib/ipquality.sh
. "$SCRIPT_DIR/lib/ipquality.sh"
# shellcheck source=lib/reputation.sh
. "$SCRIPT_DIR/lib/reputation.sh"
# shellcheck source=lib/check_host.sh
. "$SCRIPT_DIR/lib/check_host.sh"
# shellcheck source=lib/report_path.sh
. "$SCRIPT_DIR/lib/report_path.sh"
# shellcheck source=lib/report.sh
. "$SCRIPT_DIR/lib/report.sh"
# shellcheck source=lib/cleanup.sh
. "$SCRIPT_DIR/lib/cleanup.sh"
# shellcheck source=lib/cli.sh
. "$SCRIPT_DIR/lib/cli.sh"

readonly EXIT_USAGE=2
readonly DEFAULT_VLESS_PORT=443
readonly DEFAULT_HYSTERIA2_PORT=443
readonly DEFAULT_COUNTRY=ru
readonly DEFAULT_REPORT_DIR=reports
readonly DEFAULT_OS_RELEASE_FILE=/etc/os-release
readonly IP_LOOKUP_URL=https://api.ipify.org
readonly -a CHECKED_COMMANDS=(curl sha256sum jq bc nc dig ip ss dpkg-query apt-get)
PREFLIGHT_EXTERNAL_IPV4=''
VLESS_LISTENER_STATE='unknown'
HYSTERIA2_LISTENER_STATE='unknown'
VPSCHECK_COMMAND_PATH="$SCRIPT_DIR/vps-check.sh"

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

is_country_code() {
    [[ $1 =~ ^[A-Za-z]{2}$ ]]
}

normalize_country_code() {
    printf '%s\n' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
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

collect_listener_states() {
    local vless_port=$1
    local hysteria2_port=$2

    VLESS_LISTENER_STATE=$(listener_state tcp "$vless_port")
    HYSTERIA2_LISTENER_STATE=$(listener_state udp "$hysteria2_port")
}

run_preflight() {
    local requested_ip=$1
    local vless_port=$2
    local hysteria2_port=$3
    local os_release_file=${VPSCHECK_OS_RELEASE_FILE:-$DEFAULT_OS_RELEASE_FILE}
    local os_info os_id os_version os_name external_ip command package
    local failed=0

    PREFLIGHT_EXTERNAL_IPV4=''
    printf '\n'
    terminal_heading_printf 1 'Preflight:'
    printf '\n'

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
        PREFLIGHT_EXTERNAL_IPV4=$external_ip
        printf '  External IPv4: %s (provided)\n' "$external_ip"
    elif external_ip=$(detect_external_ipv4); then
        PREFLIGHT_EXTERNAL_IPV4=$external_ip
        printf '  External IPv4: %s (detected)\n' "$external_ip"
    else
        printf '  External IPv4: unavailable (will retry after dependency setup)\n'
    fi

    printf '  '
    terminal_heading_printf 1 'Commands:'
    printf '\n'
    for command in "${CHECKED_COMMANDS[@]}"; do
        printf '    %s: %s\n' "$command" "$(command_state "$command")"
    done

    printf '  '
    terminal_heading_printf 1 'APT packages:'
    printf '\n'
    for package in "${CHECKED_PACKAGES[@]}"; do
        printf '    %s: %s\n' "$package" "$(package_state "$package")"
    done

    collect_listener_states "$vless_port" "$hysteria2_port"
    printf '  '
    terminal_heading_printf 1 'Local listeners:'
    printf '\n'
    printf '    VLESS TCP/%s: %s\n' "$vless_port" "$VLESS_LISTENER_STATE"
    printf '    Hysteria2 UDP/%s: %s\n' "$hysteria2_port" "$HYSTERIA2_LISTENER_STATE"

    (( failed == 0 ))
}

main() {
    local ip=''
    local country=$DEFAULT_COUNTRY
    local vless_port=$DEFAULT_VLESS_PORT
    local hysteria2_port=$DEFAULT_HYSTERIA2_PORT
    local ip_seen=0
    local country_seen=0
    local vless_port_seen=0
    local hysteria2_port_seen=0
    local print_report=0
    local print_report_seen=0
    local cleanup_requested=0
    local cleanup_seen=0
    local report_dir=$DEFAULT_REPORT_DIR
    local report_dir_seen=0

    load_tool_version "$SCRIPT_DIR/VERSION" || return 1
    set_cleanup_plan_path
    if [[ ${1:-} == cleanup ]]; then
        shift
        if [[ ${1:-} == -h || ${1:-} == --help ]]; then
            (( $# == 1 )) || fail_usage 'The cleanup help command does not accept additional arguments.'
            cleanup_usage
            return 0
        fi
        run_dependency_cleanup_command "$@"
        return
    fi
    if [[ ${1:-} == list-locations ]]; then
        shift
        VPSCHECK_LOCATIONS_COMMAND="${0##*/} list-locations" \
            "$SCRIPT_DIR/scripts/list-check-host-locations.sh" "$@"
        return
    fi

    while (( $# > 0 )); do
        case $1 in
            --ip)
                (( ip_seen == 0 )) || fail_usage 'Option --ip was provided more than once.'
                (( $# >= 2 )) || fail_usage 'Option --ip requires a value.'
                ip=$2
                ip_seen=1
                shift 2
                ;;
            --country)
                (( country_seen == 0 )) || fail_usage 'Option --country was provided more than once.'
                (( $# >= 2 )) || fail_usage 'Option --country requires a value.'
                country=$2
                country_seen=1
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
            --print-report)
                (( print_report_seen == 0 )) || fail_usage 'Option --print-report was provided more than once.'
                print_report=1
                print_report_seen=1
                shift
                ;;
            --report-dir)
                (( report_dir_seen == 0 )) || fail_usage 'Option --report-dir was provided more than once.'
                (( $# >= 2 )) || fail_usage 'Option --report-dir requires a value.'
                report_dir=$2
                report_dir_seen=1
                shift 2
                ;;
            --cleanup)
                (( cleanup_seen == 0 )) || fail_usage 'Option --cleanup was provided more than once.'
                cleanup_requested=1
                cleanup_seen=1
                shift
                ;;
            --version)
                printf 'VPSChecker %s\n' "$VPSCHECK_VERSION"
                return 0
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
    is_country_code "$country" || fail_usage "Invalid country code: $country"
    country=$(normalize_country_code "$country")
    is_port "$vless_port" || fail_usage "Invalid VLESS port: $vless_port"
    is_port "$hysteria2_port" || fail_usage "Invalid Hysteria2 port: $hysteria2_port"
    [[ -n $report_dir ]] || fail_usage 'Report directory cannot be empty.'

    printf 'Input valid.\n'
    if (( ip_seen == 1 )); then
        printf 'IP: %s\n' "$ip"
    else
        printf 'IP: auto-detect\n'
    fi
    printf 'Target country: %s\n' "$country"
    printf 'VLESS TCP port: %s\n' "$vless_port"
    printf 'Hysteria2 UDP port: %s\n' "$hysteria2_port"
    printf 'Report directory: %s\n' "$report_dir"
    if (( cleanup_requested == 1 )); then
        printf 'Automatic package cleanup: enabled\n'
    else
        printf 'Automatic package cleanup: disabled\n'
    fi

    AUTO_CLEANUP_REQUESTED=$cleanup_requested
    trap cleanup_runtime EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    run_preflight "$ip" "$vless_port" "$hysteria2_port" || return 1
    ensure_dependencies || return 1
    collect_listener_states "$vless_port" "$hysteria2_port"
    if [[ -z $ip ]]; then
        if [[ -n $PREFLIGHT_EXTERNAL_IPV4 ]]; then
            ip=$PREFLIGHT_EXTERNAL_IPV4
        elif ip=$(detect_external_ipv4); then
            printf '\nExternal IPv4 after dependency setup: %s\n' "$ip"
        else
            terminal_error 'external IPv4 is unavailable after dependency setup.'
            return 1
        fi
    fi
    prepare_ipquality || return 1
    run_ipquality || return 1
    evaluate_vpn_trust "$IPQUALITY_JSON_PATH" || return 1
    run_check_host "$ip" "$vless_port" "$hysteria2_port" "$country" || return 1
    generate_reports "$ip" "$country" "$vless_port" "$hysteria2_port" \
        "$VLESS_LISTENER_STATE" "$HYSTERIA2_LISTENER_STATE" "$cleanup_requested" \
        "$report_dir" || return 1
    cleanup_runtime 0
    present_reports "$print_report" || return 1
    (( RUNTIME_CLEANUP_FAILED == 0 ))
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
