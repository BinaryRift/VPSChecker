#!/usr/bin/env bash

set -u

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)
readonly CLI="$PROJECT_DIR/vps-check.sh"
readonly OS_RELEASE_FIXTURE="$TEST_DIR/fixtures/os-release.ubuntu"
readonly MOCK_BIN="$TEST_DIR/fixtures/bin"

passed=0
failed=0

run_case() {
    local description=$1
    local expected_status=$2
    local expected_text=$3
    local output status
    shift 3

    output=$(PATH="$MOCK_BIN:$PATH" VPSCHECK_OS_RELEASE_FILE="$OS_RELEASE_FIXTURE" \
        "$CLI" "$@" 2>&1)
    status=$?

    if [[ $status -eq $expected_status && $output == *"$expected_text"* ]]; then
        printf 'ok - %s\n' "$description"
        (( passed += 1 ))
        return
    fi

    printf 'not ok - %s\n' "$description"
    printf '  expected status: %s\n' "$expected_status"
    printf '  actual status:   %s\n' "$status"
    printf '  expected output: %s\n' "$expected_text"
    printf '  actual output:   %s\n' "$output"
    (( failed += 1 ))
}

run_case 'uses default ports' 0 $'VLESS TCP port: 443\nHysteria2 UDP port: 443' \
    --ip 203.0.113.10
run_case 'accepts explicit IPv4 and boundary ports' 0 'IP: 203.0.113.10' \
    --ip 203.0.113.10 --vless-port 1 --hysteria2-port 65535
run_case 'accepts only a VLESS port override' 0 'Hysteria2 UDP port: 443' \
    --ip 203.0.113.10 --vless-port 2053
run_case 'accepts only a Hysteria2 port override' 0 'VLESS TCP port: 443' \
    --ip 203.0.113.10 --hysteria2-port 8443
run_case 'uses Russia as the default target country' 0 'Target country: ru' \
    --ip 203.0.113.10
run_case 'accepts and normalizes a target country' 0 'Target country: de' \
    --ip 203.0.113.10 --country DE
run_case 'shows help' 0 'Usage:' --help

run_case 'rejects an IPv4 octet above 255' 2 'Invalid IPv4 address' \
    --ip 203.0.113.256 --vless-port 443 --hysteria2-port 8443
run_case 'rejects an incomplete IPv4 address' 2 'Invalid IPv4 address' \
    --ip 203.0.113 --vless-port 443 --hysteria2-port 8443
run_case 'rejects IPv6 in the first stage' 2 'Invalid IPv4 address' \
    --ip 2001:db8::1 --vless-port 443 --hysteria2-port 8443
run_case 'rejects ambiguous IPv4 leading zeroes' 2 'Invalid IPv4 address' \
    --ip 203.0.113.010 --vless-port 443 --hysteria2-port 8443
run_case 'rejects port zero' 2 'Invalid VLESS port' \
    --vless-port 0 --hysteria2-port 8443
run_case 'rejects a port above 65535' 2 'Invalid Hysteria2 port' \
    --vless-port 443 --hysteria2-port 65536
run_case 'rejects a non-numeric port' 2 'Invalid VLESS port' \
    --vless-port https --hysteria2-port 8443
run_case 'rejects a country name' 2 'Invalid country code' --country Germany
run_case 'rejects a malformed country code' 2 'Invalid country code' --country r1
run_case 'rejects a missing option value' 2 'Option --ip requires a value' --ip
run_case 'rejects a missing country value' 2 'Option --country requires a value' --country
run_case 'rejects duplicate options' 2 'Option --vless-port was provided more than once' \
    --vless-port 443 --vless-port 8443 --hysteria2-port 8443
run_case 'rejects a duplicate country option' 2 'Option --country was provided more than once' \
    --country ru --country de
run_case 'rejects unknown options' 2 'Unknown option' \
    --vless-port 443 --hysteria2-port 8443 --unknown
run_case 'rejects positional arguments' 2 'Unexpected argument' \
    --vless-port 443 --hysteria2-port 8443 extra

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
