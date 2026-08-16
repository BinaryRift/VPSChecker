#!/usr/bin/env bash

set -u

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)

# shellcheck source=../lib/terminal.sh
. "$PROJECT_DIR/lib/terminal.sh"

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

test_uses_plain_output_without_tty() (
    local output

    TERM=xterm
    unset NO_COLOR
    output=$(terminal_printf 1 "$TERMINAL_COLOR_GREEN" 'Status: %s' OK) || return 1
    [[ $output == 'Status: OK' ]]
)

test_colors_and_resets_tty_output() (
    local output

    terminal_stream_is_tty() {
        return 0
    }
    TERM=xterm
    unset NO_COLOR
    output=$(terminal_printf 1 "$TERMINAL_COLOR_GREEN" 'Status: %s' OK) || return 1
    [[ $output == $'\033[32mStatus: OK\033[0m' ]]
)

test_no_color_disables_tty_colors() (
    local output

    terminal_stream_is_tty() {
        return 0
    }
    TERM=xterm
    NO_COLOR=''
    output=$(terminal_printf 1 "$TERMINAL_COLOR_GREEN" 'Status: %s' OK) || return 1
    [[ $output == 'Status: OK' ]]
)

test_supports_stderr_styles() (
    local output

    terminal_stream_is_tty() {
        return 0
    }
    TERM=xterm
    unset NO_COLOR
    output=$(terminal_printf 2 "$TERMINAL_COLOR_RED" 'Error: %s' failed 2>&1) || return 1
    [[ $output == $'\033[31mError: failed\033[0m' ]]
)

run_test 'uses plain output when stdout is not a TTY' test_uses_plain_output_without_tty
run_test 'adds color and reset codes for TTY output' test_colors_and_resets_tty_output
run_test 'honors NO_COLOR for TTY output' test_no_color_disables_tty_colors
run_test 'supports styled stderr output' test_supports_stderr_styles

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
