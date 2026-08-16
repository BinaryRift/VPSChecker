#!/usr/bin/env bash

set -u

readonly TEST_DIRECTORY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIRECTORY=$(cd "$TEST_DIRECTORY/.." && pwd)
readonly FIXTURE_BIN="$TEST_DIRECTORY/fixtures/install/bin"

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

create_release_assets() {
    local root_directory=$1
    local archive_root="$root_directory/package/vpschecker"
    local archive_path="$root_directory/assets/vpschecker.tar.gz"
    local path checksum
    local -a required_files=(
        LICENSE
        THIRD_PARTY_NOTICES.md
        VERSION
        vps-check.sh
        lib/check_host.sh
        lib/cleanup.sh
        lib/cli.sh
        lib/dependencies.sh
        lib/ipquality.sh
        lib/report.sh
        lib/report_path.sh
        lib/reputation.sh
        lib/terminal.sh
        lib/version.sh
        scripts/list-check-host-locations.sh
    )

    mkdir -p "$archive_root/lib" "$archive_root/scripts" "$root_directory/assets"
    for path in "${required_files[@]}"; do
        printf 'fixture: %s\n' "$path" > "$archive_root/$path"
    done
    tar -czf "$archive_path" -C "$root_directory/package" vpschecker
    checksum=$(sha256sum "$archive_path" | awk '{ print $1 }')
    printf '%s  vpschecker.tar.gz\n' "$checksum" \
        > "$root_directory/assets/vpschecker.tar.gz.sha256"
}

test_installs_verified_release() (
    local test_root output

    test_root=$(mktemp -d)
    trap 'rm -rf -- "$test_root"' EXIT
    mkdir "$test_root/work"
    create_release_assets "$test_root"

    output=$(cd "$test_root/work" && \
        PATH="$FIXTURE_BIN:$PATH" \
        INSTALL_TEST_ASSET_DIRECTORY="$test_root/assets" \
        bash "$PROJECT_DIRECTORY/install.sh") || return 1

    [[ -f $test_root/work/vpschecker/vps-check.sh \
        && -x $test_root/work/vpschecker/vps-check.sh \
        && -f $test_root/work/vpschecker/lib/report.sh \
        && -f $test_root/work/vpschecker/lib/terminal.sh \
        && $output == *'VPSChecker installed in'* \
        && $output == *$'\033[1;32mNow you should run: ./vpschecker/vps-check.sh\033[0m'* ]]
)

test_rejects_checksum_mismatch() (
    local test_root

    test_root=$(mktemp -d)
    trap 'rm -rf -- "$test_root"' EXIT
    mkdir "$test_root/work"
    create_release_assets "$test_root"
    printf '%064d  vpschecker.tar.gz\n' 0 \
        > "$test_root/assets/vpschecker.tar.gz.sha256"

    if (cd "$test_root/work" && \
        PATH="$FIXTURE_BIN:$PATH" \
        INSTALL_TEST_ASSET_DIRECTORY="$test_root/assets" \
        bash "$PROJECT_DIRECTORY/install.sh") >/dev/null 2>&1; then
        return 1
    fi
    [[ ! -e $test_root/work/vpschecker ]] \
        && [[ -z $(find "$test_root/work" -maxdepth 1 -name '.vpschecker-install.*' -print -quit) ]]
)

test_refuses_existing_installation() (
    local test_root output status

    test_root=$(mktemp -d)
    trap 'rm -rf -- "$test_root"' EXIT
    mkdir -p "$test_root/work/vpschecker"

    output=$(cd "$test_root/work" && bash "$PROJECT_DIRECTORY/install.sh" 2>&1)
    status=$?
    [[ $status -ne 0 \
        && $output == *'installation directory already exists'* \
        && -d $test_root/work/vpschecker ]]
)

test_reports_missing_gzip() (
    local test_root output status

    test_root=$(mktemp -d)
    trap 'rm -rf -- "$test_root"' EXIT
    mkdir -p "$test_root/work" "$test_root/bin"
    ln -s "$FIXTURE_BIN/curl" "$test_root/bin/curl"
    ln -s "$(command -v tar)" "$test_root/bin/tar"

    output=$(cd "$test_root/work" && \
        PATH="$test_root/bin" /bin/bash "$PROJECT_DIRECTORY/install.sh" 2>&1)
    status=$?
    [[ $status -ne 0 && $output == *'required command is unavailable: gzip'* ]]
)

run_test 'installs a checksum-verified release' test_installs_verified_release
run_test 'rejects a release with a mismatched checksum' test_rejects_checksum_mismatch
run_test 'does not overwrite an existing installation' test_refuses_existing_installation
run_test 'reports when gzip is unavailable' test_reports_missing_gzip

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
