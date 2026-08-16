#!/usr/bin/env bash

set -u

readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
readonly DIST_DIRECTORY="$PROJECT_DIR/dist"

BUILD_TEMP_DIRECTORY=''

usage() {
    cat <<'EOF'
Usage:
  build-release.sh [TAG]

Build the release archive and SHA-256 file from an existing Git tag. When TAG
is omitted, v<VERSION> from the current working tree is used. Generated files
are written to dist/TAG without modifying the tagged source.
EOF
}

fail() {
    printf 'Error: %s\n' "$1" >&2
    return 1
}

cleanup_build_temp() {
    if [[ -n $BUILD_TEMP_DIRECTORY && -d $BUILD_TEMP_DIRECTORY ]]; then
        rm -r -- "$BUILD_TEMP_DIRECTORY"
    fi
    BUILD_TEMP_DIRECTORY=''
}

sha256_file() {
    local output checksum

    if command -v sha256sum >/dev/null 2>&1; then
        output=$(sha256sum -- "$1") || return 1
    elif command -v shasum >/dev/null 2>&1; then
        output=$(shasum -a 256 -- "$1") || return 1
    else
        return 1
    fi
    checksum=${output%%[[:space:]]*}
    [[ $checksum =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    printf '%s\n' "$checksum" | tr '[:upper:]' '[:lower:]'
}

main() {
    local tag tagged_version output_directory archive_path checksum_path checksum
    local command_name
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
        lib/terminal.sh
        lib/version.sh
        scripts/list-check-host-locations.sh
    )

    if [[ ${1:-} == -h || ${1:-} == --help ]]; then
        (( $# == 1 )) || fail 'the help command does not accept additional arguments.' || return 2
        usage
        return 0
    fi
    (( $# <= 1 )) || fail 'the release builder accepts at most one tag.' || return 2

    for command_name in git tar awk mktemp mkdir mv rm tr; do
        command -v "$command_name" >/dev/null 2>&1 \
            || fail "required command is unavailable: $command_name" || return 1
    done
    if (( $# == 1 )); then
        tag=$1
    else
        [[ -f $PROJECT_DIR/VERSION ]] || fail 'VERSION file is unavailable.' || return 1
        tag="v$(< "$PROJECT_DIR/VERSION")"
    fi
    [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fail 'TAG must use the vMAJOR.MINOR.PATCH format.' || return 2

    git -C "$PROJECT_DIR" rev-parse --verify --quiet "refs/tags/$tag^{commit}" >/dev/null \
        || fail "Git tag does not exist: $tag" || return 1
    tagged_version=$(git -C "$PROJECT_DIR" show "$tag:VERSION" 2>/dev/null) \
        || fail "VERSION is unavailable in tag $tag." || return 1
    [[ $tag == "v$tagged_version" ]] \
        || fail "tag $tag does not match VERSION $tagged_version." || return 1

    output_directory="$DIST_DIRECTORY/$tag"
    [[ ! -e $output_directory && ! -L $output_directory ]] \
        || fail "release output already exists: $output_directory" || return 1
    mkdir -p "$DIST_DIRECTORY" || fail 'could not create the dist directory.' || return 1
    BUILD_TEMP_DIRECTORY=$(mktemp -d "$DIST_DIRECTORY/.build-$tag.XXXXXX") \
        || fail 'could not create a temporary build directory.' || return 1
    trap cleanup_build_temp EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    archive_path="$BUILD_TEMP_DIRECTORY/vpschecker.tar.gz"
    checksum_path="$BUILD_TEMP_DIRECTORY/vpschecker.tar.gz.sha256"
    git -C "$PROJECT_DIR" archive \
        --format=tar.gz \
        --prefix=vpschecker/ \
        --output="$archive_path" \
        "$tag" -- "${release_files[@]}" \
        || fail 'could not build the release archive.' || return 1
    tar -tzf "$archive_path" >/dev/null \
        || fail 'the generated release archive is invalid.' || return 1
    checksum=$(sha256_file "$archive_path") \
        || fail 'could not calculate the release SHA-256.' || return 1
    printf '%s  vpschecker.tar.gz\n' "$checksum" > "$checksum_path" \
        || fail 'could not write the checksum file.' || return 1
    mkdir "$output_directory" || fail 'could not create the release output directory.' || return 1
    mv -- "$archive_path" "$checksum_path" "$output_directory/" \
        || fail 'could not save the release files.' || return 1

    printf 'Release assets created in %s\n' "$output_directory"
    printf '  %s\n' "$output_directory/vpschecker.tar.gz"
    printf '  %s\n' "$output_directory/vpschecker.tar.gz.sha256"
}

main "$@"
