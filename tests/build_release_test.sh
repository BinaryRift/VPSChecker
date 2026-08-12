#!/usr/bin/env bash

set -u

readonly TEST_DIRECTORY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIRECTORY=$(cd "$TEST_DIRECTORY/.." && pwd)
readonly BUILD_SCRIPT="$PROJECT_DIRECTORY/scripts/build-release.sh"

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

prepare_repository() {
    local repository=$1
    local version=${2:-1.2.3}
    local path
    local -a release_files=(
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
        lib/version.sh
        scripts/list-check-host-locations.sh
    )

    mkdir -p "$repository/scripts" "$repository/lib"
    cp "$BUILD_SCRIPT" "$repository/scripts/build-release.sh"
    for path in "${release_files[@]}"; do
        printf 'fixture: %s\n' "$path" > "$repository/$path"
    done
    printf '%s\n' "$version" > "$repository/VERSION"
    git -C "$repository" init -q
    git -C "$repository" config user.name 'VPSChecker Test'
    git -C "$repository" config user.email 'test@example.invalid'
    git -C "$repository" add -- .
    git -C "$repository" commit -qm 'fixture release'
}

verify_checksum() {
    local directory=$1

    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$directory" && sha256sum -c vpschecker.tar.gz.sha256) >/dev/null
    else
        local expected actual
        expected=$(awk 'NR == 1 { print $1 }' "$directory/vpschecker.tar.gz.sha256")
        actual=$(shasum -a 256 "$directory/vpschecker.tar.gz" | awk '{ print $1 }')
        [[ $actual == "$expected" ]]
    fi
}

test_builds_release_from_matching_tag() (
    local test_root repository output_directory entries

    test_root=$(mktemp -d)
    trap 'rm -rf -- "$test_root"' EXIT
    repository="$test_root/project"
    mkdir "$repository"
    prepare_repository "$repository"
    git -C "$repository" tag -a v1.2.3 -m 'v1.2.3'

    "$repository/scripts/build-release.sh" v1.2.3 >/dev/null || return 1
    output_directory="$repository/dist/v1.2.3"
    [[ -f $output_directory/vpschecker.tar.gz \
        && -f $output_directory/vpschecker.tar.gz.sha256 ]] || return 1
    verify_checksum "$output_directory" || return 1
    entries=$(tar -tzf "$output_directory/vpschecker.tar.gz") || return 1
    [[ $entries == *'vpschecker/LICENSE'* \
        && $entries == *'vpschecker/THIRD_PARTY_NOTICES.md'* \
        && $entries == *'vpschecker/vps-check.sh'* \
        && $entries != *'build-release.sh'* ]]
)

test_rejects_tag_version_mismatch() (
    local test_root repository output status

    test_root=$(mktemp -d)
    trap 'rm -rf -- "$test_root"' EXIT
    repository="$test_root/project"
    mkdir "$repository"
    prepare_repository "$repository" 1.2.2
    git -C "$repository" tag -a v1.2.3 -m 'v1.2.3'

    output=$("$repository/scripts/build-release.sh" v1.2.3 2>&1)
    status=$?
    [[ $status -eq 1 \
        && $output == *'tag v1.2.3 does not match VERSION 1.2.2'* \
        && ! -e $repository/dist/v1.2.3 ]]
)

test_refuses_existing_output() (
    local test_root repository output status

    test_root=$(mktemp -d)
    trap 'rm -rf -- "$test_root"' EXIT
    repository="$test_root/project"
    mkdir "$repository"
    prepare_repository "$repository"
    git -C "$repository" tag -a v1.2.3 -m 'v1.2.3'
    mkdir -p "$repository/dist/v1.2.3"

    output=$("$repository/scripts/build-release.sh" v1.2.3 2>&1)
    status=$?
    [[ $status -eq 1 && $output == *'release output already exists'* ]]
)

run_test 'builds a verified runtime archive from a matching tag' test_builds_release_from_matching_tag
run_test 'rejects a tag that does not match VERSION' test_rejects_tag_version_mismatch
run_test 'does not overwrite existing release assets' test_refuses_existing_output

printf '\n%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
