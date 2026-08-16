#!/usr/bin/env bash

set -euo pipefail

readonly RELEASE_BASE_URL=https://github.com/BinaryRift/VPSChecker/releases/latest/download
readonly ARCHIVE_NAME=vpschecker.tar.gz
readonly CHECKSUM_NAME=vpschecker.tar.gz.sha256
readonly INSTALL_DIRECTORY="$PWD/vpschecker"

INSTALL_TEMP_DIRECTORY=''

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

cleanup_installation() {
    if [[ -n $INSTALL_TEMP_DIRECTORY && -d $INSTALL_TEMP_DIRECTORY ]]; then
        rm -r -- "$INSTALL_TEMP_DIRECTORY"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

download_release_asset() {
    local name=$1
    local destination=$2

    curl --proto '=https' --tlsv1.2 -fsSL \
        "$RELEASE_BASE_URL/$name" -o "$destination" \
        || fail "could not download $name"
}

verify_archive_checksum() {
    local archive_path=$1
    local checksum_path=$2
    local expected_checksum actual_checksum

    expected_checksum=$(awk 'NR == 1 { print $1 }' "$checksum_path")
    [[ $expected_checksum =~ ^[[:xdigit:]]{64}$ ]] \
        || fail 'release checksum file is invalid'
    actual_checksum=$(sha256sum "$archive_path" | awk '{ print $1 }')
    [[ $actual_checksum == "$expected_checksum" ]] \
        || fail 'release archive checksum mismatch'
}

validate_archive_layout() {
    local archive_path=$1
    local entry

    while IFS= read -r entry; do
        [[ $entry == vpschecker || $entry == vpschecker/* ]] \
            || fail "unexpected path in release archive: $entry"
        [[ $entry != /* && $entry != ../* && $entry != */../* && $entry != */.. ]] \
            || fail "unsafe path in release archive: $entry"
    done < <(tar -tzf "$archive_path")
}

validate_runtime_files() {
    local source_directory=$1
    local path
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
        lib/version.sh
        scripts/list-check-host-locations.sh
    )

    for path in "${required_files[@]}"; do
        [[ -f $source_directory/$path && ! -L $source_directory/$path ]] \
            || fail "required runtime file is missing: $path"
    done
}

main() {
    local archive_path checksum_path extract_directory source_directory
    local command_name

    (( $# == 0 )) || fail 'the installer does not accept arguments'
    for command_name in curl tar gzip sha256sum awk mktemp mkdir mv chmod rm; do
        require_command "$command_name"
    done
    [[ ! -e $INSTALL_DIRECTORY && ! -L $INSTALL_DIRECTORY ]] \
        || fail "installation directory already exists: $INSTALL_DIRECTORY"

    INSTALL_TEMP_DIRECTORY=$(mktemp -d "$PWD/.vpschecker-install.XXXXXX") \
        || fail 'could not create a temporary installation directory'
    trap cleanup_installation EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    archive_path="$INSTALL_TEMP_DIRECTORY/$ARCHIVE_NAME"
    checksum_path="$INSTALL_TEMP_DIRECTORY/$CHECKSUM_NAME"
    extract_directory="$INSTALL_TEMP_DIRECTORY/extracted"
    source_directory="$extract_directory/vpschecker"

    printf 'Downloading VPSChecker release...\n'
    download_release_asset "$ARCHIVE_NAME" "$archive_path"
    download_release_asset "$CHECKSUM_NAME" "$checksum_path"
    verify_archive_checksum "$archive_path" "$checksum_path"
    validate_archive_layout "$archive_path"

    mkdir "$extract_directory"
    tar -xzf "$archive_path" -C "$extract_directory"
    validate_runtime_files "$source_directory"
    chmod u+x "$source_directory/vps-check.sh" \
        "$source_directory/scripts/list-check-host-locations.sh"
    mv -- "$source_directory" "$INSTALL_DIRECTORY"

    printf 'VPSChecker installed in %s\n' "$INSTALL_DIRECTORY"
    printf '\033[1;32mNow you should run: ./vpschecker/vps-check.sh\033[0m\n'
}

main "$@"
