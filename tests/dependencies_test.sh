#!/usr/bin/env bash

set -u

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)

# shellcheck source=../lib/dependencies.sh
. "$PROJECT_DIR/lib/dependencies.sh"

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

test_skips_install_when_dependencies_exist() (
    apt_called=0
    dpkg-query() {
        printf 'install ok installed'
    }
    apt-get() {
        apt_called=1
    }

    ensure_dependencies >/dev/null || return 1
    (( apt_called == 0 ))
)

test_installs_only_missing_packages_and_journals_changes() (
    local test_temp journal apt_log
    local install_completed=0

    test_temp=$(mktemp -d)
    TMPDIR=$test_temp
    apt_log="$test_temp/apt.log"
    trap 'cleanup_dependency_journal; rm -f -- "$apt_log"; rmdir -- "$test_temp" 2>/dev/null || true' EXIT

    id() {
        printf '0\n'
    }
    dpkg-query() {
        local package

        if [[ $* == *'${Version}'* ]]; then
            printf '%s\n' $'base-system\t1.0' \
                $'netcat-openbsd\t1.0' $'dnsutils\t1.0' $'iproute2\t1.0'
            if (( install_completed == 1 )); then
                printf '%s\n' $'curl\t2.0' $'jq\t1.0' $'bc\t1.0' $'libjq1\t1.0'
            else
                printf '%s\n' $'curl\t1.0'
            fi
            return 0
        fi
        if [[ $* == *'${binary:Package}'* ]]; then
            printf '%s\n' base-system curl netcat-openbsd dnsutils iproute2
            if (( install_completed == 1 )); then
                printf '%s\n' jq bc libjq1
            fi
            return 0
        fi

        for package in "$@"; do :; done
        case $package in
            jq|bc)
                (( install_completed == 1 )) || return 1
                printf 'install ok installed'
                ;;
            *) printf 'install ok installed' ;;
        esac
    }
    apt-get() {
        printf '%s\n' "$*" >> "$apt_log"
        if [[ $1 == install ]]; then
            install_completed=1
        fi
    }

    ensure_dependencies <<< y >/dev/null || return 1
    journal=$(< "$DEPENDENCY_JOURNAL_PATH")
    [[ $(< "$apt_log") == $'update\ninstall -y --no-install-recommends jq bc' ]] || return 1
    [[ $journal == *$'requested\tjq'* && $journal == *$'requested\tbc'* ]] || return 1
    [[ $journal == *$'added\tjq'* && $journal == *$'added\tbc'* ]] || return 1
    [[ $journal == *$'added\tlibjq1'* ]] || return 1
    [[ $journal == *$'updated\tcurl\t1.0\t2.0'* ]] || return 1

    cleanup_dependency_journal
    ensure_dependencies >/dev/null || return 1
    [[ $(< "$apt_log") == $'update\ninstall -y --no-install-recommends jq bc' ]]
)

test_decline_makes_no_changes() (
    apt_called=0
    dpkg-query() {
        return 1
    }
    apt-get() {
        apt_called=1
    }

    ! ensure_dependencies <<< n >/dev/null 2>&1 || return 1
    (( apt_called == 0 ))
)

run_test 'skips APT when every dependency is installed' test_skips_install_when_dependencies_exist
run_test 'installs only missing packages and records all package changes' test_installs_only_missing_packages_and_journals_changes
run_test 'does not invoke APT when installation is declined' test_decline_makes_no_changes

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
