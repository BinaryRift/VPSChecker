readonly TEMPORARY_LISTENER_START_ATTEMPTS=20

PREPARED_LISTENER_SOURCE='NONE'
PREPARED_LISTENER_PID=''
PREPARED_LISTENER_PRIVILEGED=0

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

prepare_listener() {
    local protocol=$1
    local port=$2
    local state uid pid attempt
    local privileged=0
    local -a listener_command=(nc -4 -d -k)

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
