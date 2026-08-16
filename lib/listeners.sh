readonly TEMPORARY_LISTENER_START_ATTEMPTS=20
readonly TEMPORARY_LISTENER_MAX_LIFETIME_SECONDS=180

PREPARED_LISTENER_SOURCE='NONE'
PREPARED_LISTENER_PID=''
PREPARED_LISTENER_PRIVILEGED=0
VLESS_LISTENER_SOURCE='NONE'
HYSTERIA2_LISTENER_SOURCE='NONE'
TEMPORARY_LISTENER_PIDS=()
TEMPORARY_LISTENER_PRIVILEGES=()
TEMPORARY_LISTENER_PROTOCOLS=()
TEMPORARY_LISTENER_PORTS=()

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

listener_current_uid() {
    id -u
}

listener_sudo_available() {
    command -v sudo >/dev/null 2>&1
}

listener_authorize_sudo() {
    sudo -v
}

listener_run_privileged() {
    sudo -- "$@"
}

temporary_listener_wait() {
    sleep 0.1
}

listener_process_running() {
    local pid=$1
    local privileged=$2

    if (( privileged == 1 )); then
        listener_run_privileged kill -0 "$pid" >/dev/null 2>&1
    else
        kill -0 "$pid" >/dev/null 2>&1
    fi
}

stop_temporary_listener() {
    local pid=$1
    local privileged=$2
    local status=0

    [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )) || return 1
    if listener_process_running "$pid" "$privileged"; then
        if (( privileged == 1 )); then
            listener_run_privileged kill -TERM "$pid" >/dev/null 2>&1 || status=1
        else
            kill -TERM "$pid" >/dev/null 2>&1 || status=1
        fi
    fi
    wait "$pid" 2>/dev/null || true
    return "$status"
}

register_temporary_listener() {
    local pid=$1
    local privileged=$2
    local protocol=$3
    local port=$4

    [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )) || return 1
    [[ $privileged == 0 || $privileged == 1 ]] || return 1
    [[ $protocol == tcp || $protocol == udp ]] || return 1
    [[ $port =~ ^[0-9]+$ ]] || return 1

    TEMPORARY_LISTENER_PIDS+=("$pid")
    TEMPORARY_LISTENER_PRIVILEGES+=("$privileged")
    TEMPORARY_LISTENER_PROTOCOLS+=("$protocol")
    TEMPORARY_LISTENER_PORTS+=("$port")
}

stop_temporary_listeners() {
    local index pid privileged protocol port
    local status=0
    local -a remaining_pids=()
    local -a remaining_privileges=()
    local -a remaining_protocols=()
    local -a remaining_ports=()

    for (( index = ${#TEMPORARY_LISTENER_PIDS[@]} - 1; index >= 0; index -= 1 )); do
        pid=${TEMPORARY_LISTENER_PIDS[$index]}
        privileged=${TEMPORARY_LISTENER_PRIVILEGES[$index]}
        protocol=${TEMPORARY_LISTENER_PROTOCOLS[$index]}
        port=${TEMPORARY_LISTENER_PORTS[$index]}
        if ! stop_temporary_listener "$pid" "$privileged"; then
            status=1
            remaining_pids+=("$pid")
            remaining_privileges+=("$privileged")
            remaining_protocols+=("$protocol")
            remaining_ports+=("$port")
            terminal_warning 'could not stop temporary %s/%s listener process %s.' \
                "$protocol" "$port" "$pid"
        fi
    done

    TEMPORARY_LISTENER_PIDS=("${remaining_pids[@]}")
    TEMPORARY_LISTENER_PRIVILEGES=("${remaining_privileges[@]}")
    TEMPORARY_LISTENER_PROTOCOLS=("${remaining_protocols[@]}")
    TEMPORARY_LISTENER_PORTS=("${remaining_ports[@]}")
    return "$status"
}

prepare_check_listeners() {
    local temporary_listeners_enabled=$1
    local vless_port=$2
    local hysteria2_port=$3

    [[ $temporary_listeners_enabled == 0 || $temporary_listeners_enabled == 1 ]] || return 1
    VLESS_LISTENER_SOURCE='NONE'
    HYSTERIA2_LISTENER_SOURCE='NONE'

    if (( temporary_listeners_enabled == 1 )); then
        prepare_listener tcp "$vless_port" || return 1
        VLESS_LISTENER_SOURCE=$PREPARED_LISTENER_SOURCE
        prepare_listener udp "$hysteria2_port" || return 1
        HYSTERIA2_LISTENER_SOURCE=$PREPARED_LISTENER_SOURCE
    fi

    collect_listener_states "$vless_port" "$hysteria2_port"
    if (( temporary_listeners_enabled == 0 )); then
        [[ $VLESS_LISTENER_STATE == listening ]] && VLESS_LISTENER_SOURCE='EXISTING'
        [[ $HYSTERIA2_LISTENER_STATE == listening ]] && HYSTERIA2_LISTENER_SOURCE='EXISTING'
    fi

    printf '\n'
    terminal_heading_printf 1 'Listener sources:'
    printf '\n'
    printf '  VLESS TCP/%s: %s\n' "$vless_port" "$VLESS_LISTENER_SOURCE"
    printf '  Hysteria2 UDP/%s: %s\n' "$hysteria2_port" "$HYSTERIA2_LISTENER_SOURCE"
}

prepare_listener() {
    local protocol=$1
    local port=$2
    local state uid pid attempt
    local privileged=0
    local -a listener_command=(
        timeout --signal=TERM --kill-after=2s
        "${TEMPORARY_LISTENER_MAX_LIFETIME_SECONDS}s"
        nc -4 -d -k
    )

    PREPARED_LISTENER_SOURCE='NONE'
    PREPARED_LISTENER_PID=''
    PREPARED_LISTENER_PRIVILEGED=0

    state=$(listener_state "$protocol" "$port") || {
        terminal_error 'unsupported temporary listener protocol: %s' "$protocol"
        return 1
    }
    case $state in
        listening)
            PREPARED_LISTENER_SOURCE='EXISTING'
            return 0
            ;;
        'not listening') ;;
        *)
            terminal_error 'could not determine the %s/%s listener state: %s' \
                "$protocol" "$port" "$state"
            return 1
            ;;
    esac

    command -v timeout >/dev/null 2>&1 || {
        terminal_error 'timeout is required for bounded temporary listeners.'
        return 1
    }

    if [[ $protocol == udp ]]; then
        listener_command+=(-u)
    fi
    listener_command+=(-l "$port")

    uid=$(listener_current_uid) || {
        terminal_error 'could not determine privileges for temporary listener setup.'
        return 1
    }
    if (( port < 1024 )) && [[ $uid != 0 ]]; then
        listener_sudo_available || {
            terminal_error 'temporary %s/%s listener requires root privileges or sudo.' \
                "$protocol" "$port"
            return 1
        }
        printf 'Temporary %s/%s listener requires sudo (port below 1024).\n' \
            "$protocol" "$port"
        printf 'Authorizing temporary %s/%s listener...\n' "$protocol" "$port"
        listener_authorize_sudo || {
            terminal_error 'could not authorize temporary %s/%s listener.' "$protocol" "$port"
            return 1
        }
        privileged=1
    fi

    if (( privileged == 1 )); then
        listener_run_privileged "${listener_command[@]}" </dev/null >/dev/null 2>&1 &
    else
        "${listener_command[@]}" </dev/null >/dev/null 2>&1 &
    fi
    pid=$!

    for (( attempt = 1; attempt <= TEMPORARY_LISTENER_START_ATTEMPTS; attempt += 1 )); do
        state=$(listener_state "$protocol" "$port") || state='unknown'
        if [[ $state == listening ]] && listener_process_running "$pid" "$privileged"; then
            if ! register_temporary_listener "$pid" "$privileged" "$protocol" "$port"; then
                stop_temporary_listener "$pid" "$privileged" || true
                terminal_error 'could not record temporary %s/%s listener.' "$protocol" "$port"
                return 1
            fi
            PREPARED_LISTENER_SOURCE='TEMPORARY'
            PREPARED_LISTENER_PID=$pid
            PREPARED_LISTENER_PRIVILEGED=$privileged
            return 0
        fi
        listener_process_running "$pid" "$privileged" || break
        temporary_listener_wait
    done

    stop_temporary_listener "$pid" "$privileged" || true
    terminal_error 'could not start temporary %s/%s listener.' "$protocol" "$port"
    return 1
}
