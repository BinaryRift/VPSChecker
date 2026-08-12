#!/usr/bin/env bash

set -u

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)
readonly CLI="$PROJECT_DIR/vps-check.sh"
readonly FIXTURES_DIR="$TEST_DIR/fixtures"

# Sourcing exposes the preflight functions without running main.
# shellcheck source=../vps-check.sh
. "$CLI"

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

test_ubuntu_is_supported() {
    local info id version name

    info=$(read_os_info "$FIXTURES_DIR/os-release.ubuntu") || return 1
    IFS=$'\t' read -r id version name <<< "$info"
    [[ $id == ubuntu && $version == 24.04 && $name == 'Ubuntu 24.04 LTS' ]] || return 1
    is_supported_os "$id"
}

test_debian_is_supported() {
    local info id version name

    info=$(read_os_info "$FIXTURES_DIR/os-release.debian") || return 1
    IFS=$'\t' read -r id version name <<< "$info"
    [[ $id == debian && $version == 12 && $name == 'Debian GNU/Linux 12 (bookworm)' ]] || return 1
    is_supported_os "$id"
}

test_unsupported_os_fails_preflight() {
    local output status

    output=$(VPSCHECK_OS_RELEASE_FILE="$FIXTURES_DIR/os-release.alpine" \
        "$CLI" --ip 203.0.113.10 2>&1)
    status=$?
    [[ $status -eq 1 && $output == *'unsupported'* ]]
}

test_external_ipv4_detection() (
    curl() {
        printf '198.51.100.24\n'
    }

    [[ $(detect_external_ipv4) == 198.51.100.24 ]]
)

test_invalid_detected_ipv4_is_rejected() (
    curl() {
        printf 'not-an-ip\n'
    }

    ! detect_external_ipv4 >/dev/null
)

test_privilege_detection_does_not_call_sudo() (
    local marker output status

    marker=$(mktemp)
    rm -f "$marker"
    id() {
        printf '1000\n'
    }
    sudo() {
        printf 'called\n' > "$marker"
    }

    output=$(privilege_state)
    if [[ $output == 'non-root; sudo command available (not invoked)' && ! -e $marker ]]; then
        status=0
    else
        status=1
    fi
    rm -f "$marker"
    return "$status"
)

test_package_states() (
    dpkg-query() {
        if [[ $* == *' jq' ]]; then
            printf 'install ok installed'
            return 0
        fi
        return 1
    }

    [[ $(package_state jq) == installed ]] || return 1
    [[ $(package_state curl) == 'not installed' ]]
)

test_listener_states() (
    ss() {
        if [[ $* == *'-ltn'* ]]; then
            printf 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:*\n'
        fi
    }

    [[ $(listener_state tcp 443) == listening ]] || return 1
    [[ $(listener_state udp 443) == 'not listening' ]]
)

run_test 'recognizes Ubuntu as supported' test_ubuntu_is_supported
run_test 'recognizes Debian as supported' test_debian_is_supported
run_test 'rejects an unsupported distribution' test_unsupported_os_fails_preflight
run_test 'detects a valid external IPv4 address' test_external_ipv4_detection
run_test 'rejects an invalid detected IPv4 address' test_invalid_detected_ipv4_is_rejected
run_test 'reports sudo without invoking it' test_privilege_detection_does_not_call_sudo
run_test 'detects installed and missing APT packages' test_package_states
run_test 'detects TCP and UDP listener states' test_listener_states

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
