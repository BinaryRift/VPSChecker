readonly TERMINAL_STYLE_RESET=$'\033[0m'
readonly TERMINAL_STYLE_BOLD=$'\033[1m'
readonly TERMINAL_COLOR_RED=$'\033[31m'
readonly TERMINAL_COLOR_GREEN=$'\033[32m'
readonly TERMINAL_COLOR_YELLOW=$'\033[33m'
readonly TERMINAL_COLOR_CYAN=$'\033[36m'
readonly TERMINAL_COLOR_GRAY=$'\033[90m'
readonly TERMINAL_COLOR_BRIGHT_GREEN=$'\033[92m'

terminal_stream_is_tty() {
    [[ -t $1 ]]
}

terminal_colors_enabled() {
    local fd=$1

    [[ $fd == 1 || $fd == 2 ]] || return 1
    [[ ! -v NO_COLOR && ${TERM:-} != dumb ]] || return 1
    terminal_stream_is_tty "$fd"
}

terminal_status_style() {
    case $1 in
        OK|REACHABLE|AVAILABLE|REPLACEMENT_UNLIKELY)
            printf '%s' "$TERMINAL_COLOR_GREEN"
            ;;
        WARNING|PARTIAL|INCONCLUSIVE|REPLACEMENT_MAY_HELP)
            printf '%s' "$TERMINAL_COLOR_YELLOW"
            ;;
        POOR|UNREACHABLE|CLOSED|REPLACEMENT_JUSTIFIED)
            printf '%s' "$TERMINAL_COLOR_RED"
            ;;
        UNKNOWN)
            printf '%s' "$TERMINAL_COLOR_GRAY"
            ;;
        OPEN_OR_FILTERED)
            printf '%s' "$TERMINAL_COLOR_CYAN"
            ;;
        *) return 1 ;;
    esac
}

terminal_status_printf() {
    local fd=$1
    local status=$2
    local style

    style=$(terminal_status_style "$status") || return 1
    terminal_printf "$fd" "$style" '%s' "$status"
}

terminal_message() {
    local fd=$1
    local style=$2
    local label=$3
    local format=$4
    local status=0
    shift 4

    terminal_printf "$fd" "$style" '%s:' "$label" || status=$?
    printf ' ' >&"$fd" || status=$?
    printf "$format" "$@" >&"$fd" || status=$?
    printf '\n' >&"$fd" || status=$?
    return "$status"
}

terminal_error() {
    terminal_message 2 "$TERMINAL_COLOR_RED" Error "$@"
}

terminal_warning() {
    terminal_message 2 "$TERMINAL_COLOR_YELLOW" Warning "$@"
}

terminal_heading_printf() {
    local fd=$1
    shift

    terminal_printf "$fd" "$TERMINAL_STYLE_BOLD" "$@"
}

terminal_printf() {
    local fd=$1
    local style=$2
    local format=$3
    local status=0
    shift 3

    [[ $fd == 1 || $fd == 2 ]] || return 2
    if terminal_colors_enabled "$fd"; then
        printf '%s' "$style" >&"$fd" || status=$?
        printf "$format" "$@" >&"$fd" || status=$?
        printf '%s' "$TERMINAL_STYLE_RESET" >&"$fd" || status=$?
    else
        printf "$format" "$@" >&"$fd" || status=$?
    fi
    return "$status"
}
