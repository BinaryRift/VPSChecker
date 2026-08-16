#!/usr/bin/env bash

set -u

readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly CHECK_HOST_NODES_URL=https://check-host.net/nodes/hosts

# shellcheck source=../lib/terminal.sh
. "$SCRIPT_DIR/../lib/terminal.sh"

usage() {
    local command_name=${VPSCHECK_LOCATIONS_COMMAND:-list-check-host-locations.sh}

    terminal_heading_printf 1 'Usage:'
    printf '\n  %s\n\n' "$command_name"
    cat <<'EOF'
Lists the countries currently represented by Check-Host nodes. Country codes
can be passed to vps-check.sh with --country.
EOF
}

fail() {
    terminal_error '%s' "$1"
    return 1
}

list_locations() {
    local response locations

    command -v curl >/dev/null 2>&1 || {
        fail 'curl is required.'
        return 1
    }
    command -v jq >/dev/null 2>&1 || {
        fail 'jq is required.'
        return 1
    }

    response=$(curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 5 \
        --header 'Accept: application/json' "$CHECK_HOST_NODES_URL") || {
        fail 'could not obtain the Check-Host node list.'
        return 1
    }

    locations=$(printf '%s\n' "$response" | jq -er '
        [
            .nodes | to_entries[]
            | select((.value.location | type) == "array")
            | {
                code: (.value.location[0] // ""),
                country: (.value.location[1] // ""),
                city: (.value.location[2] // "")
              }
            | select(.code | test("^[a-z]{2}$"))
          ]
        | sort_by(.code, .city)
        | group_by(.code) as $countries
        | select(($countries | length) > 0)
        | (["CODE", "COUNTRY", "NODES", "CITIES"],
           ($countries[] | [
                (.[0].code | ascii_upcase),
                .[0].country,
                (length | tostring),
                (map(.city) | map(select(length > 0)) | unique | join(", "))
            ]))
        | @tsv
    ') || {
        fail 'Check-Host returned an invalid or empty node list.'
        return 1
    }

    printf '%s\n' "$locations"
}

main() {
    if (( $# == 1 )) && [[ $1 == -h || $1 == --help ]]; then
        usage
        return 0
    fi
    if (( $# > 0 )); then
        terminal_error 'this command does not accept arguments.'
        usage >&2
        return 2
    fi

    list_locations
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
