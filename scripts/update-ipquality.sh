#!/usr/bin/env bash

set -u

readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
readonly IPQUALITY_LIB="$PROJECT_DIR/lib/ipquality.sh"
readonly IPQUALITY_REPOSITORY=https://github.com/xykt/IPQuality.git
readonly IPQUALITY_RAW_BASE=https://raw.githubusercontent.com/xykt/IPQuality

# shellcheck source=../lib/ipquality.sh
. "$IPQUALITY_LIB"

UPDATE_TEMP_DIR=''

usage() {
    cat <<'EOF'
Usage:
  update-ipquality.sh [COMMIT_SHA]

Without COMMIT_SHA, the latest commit from the IPQuality main branch is used.
The script shows the candidate version, checksum, and source diff before asking
for confirmation. It does not update the pinned version unless explicitly
confirmed.
EOF
}

cleanup_update_temp() {
    if [[ -n ${UPDATE_TEMP_DIR:-} && -d $UPDATE_TEMP_DIR ]]; then
        rm -f -- "$UPDATE_TEMP_DIR/current-ip.sh" "$UPDATE_TEMP_DIR/candidate-ip.sh"
        rmdir -- "$UPDATE_TEMP_DIR" 2>/dev/null || true
    fi
    UPDATE_TEMP_DIR=''
}

fail() {
    printf 'Error: %s\n' "$1" >&2
    return 1
}

is_commit_sha() {
    [[ $1 =~ ^[0-9a-fA-F]{40}$ ]]
}

latest_commit() {
    local output commit

    command -v git >/dev/null 2>&1 || return 1
    output=$(git ls-remote --exit-code --refs "$IPQUALITY_REPOSITORY" refs/heads/main 2>/dev/null) || return 1
    commit=${output%%[[:space:]]*}
    is_commit_sha "$commit" || return 1
    printf '%s\n' "$commit" | tr '[:upper:]' '[:lower:]'
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

download_source() {
    local commit=$1
    local output_file=$2

    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
        --retry 2 --retry-delay 1 --output "$output_file" \
        "$IPQUALITY_RAW_BASE/$commit/ip.sh"
}

source_version() {
    local version

    version=$(sed -n 's/^script_version="\([^"]*\)"$/\1/p' "$1" | head -n 1)
    [[ $version =~ ^v[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    printf '%s\n' "$version"
}

update_pin() {
    local commit=$1
    local version=$2
    local checksum=$3
    local updated_file

    updated_file=$(mktemp "$PROJECT_DIR/lib/ipquality.sh.XXXXXX") || return 1
    if ! awk -v commit="$commit" -v version="$version" -v checksum="$checksum" '
        /^readonly IPQUALITY_COMMIT=/ {
            print "readonly IPQUALITY_COMMIT=" commit
            commit_updated = 1
            next
        }
        /^readonly IPQUALITY_VERSION=/ {
            print "readonly IPQUALITY_VERSION=" version
            version_updated = 1
            next
        }
        /^readonly IPQUALITY_SHA256=/ {
            print "readonly IPQUALITY_SHA256=" checksum
            checksum_updated = 1
            next
        }
        { print }
        END {
            if (!commit_updated || !version_updated || !checksum_updated) exit 1
        }
    ' "$IPQUALITY_LIB" > "$updated_file"; then
        rm -f -- "$updated_file"
        return 1
    fi

    chmod 0644 "$updated_file" || {
        rm -f -- "$updated_file"
        return 1
    }
    if ! mv -f -- "$updated_file" "$IPQUALITY_LIB"; then
        rm -f -- "$updated_file"
        return 1
    fi
}

main() {
    local candidate_commit current_file candidate_file
    local current_checksum candidate_checksum candidate_version
    local diff_status answer

    if (( $# > 1 )); then
        usage >&2
        return 2
    fi
    if [[ ${1:-} == -h || ${1:-} == --help ]]; then
        usage
        return 0
    fi

    command -v curl >/dev/null 2>&1 || fail 'curl is required.' || return 1
    command -v diff >/dev/null 2>&1 || fail 'diff is required.' || return 1
    command -v awk >/dev/null 2>&1 || fail 'awk is required.' || return 1

    if (( $# == 1 )); then
        is_commit_sha "$1" || fail 'COMMIT_SHA must contain exactly 40 hexadecimal characters.' || return 2
        candidate_commit=$(printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]')
    else
        candidate_commit=$(latest_commit) || fail 'could not determine the latest IPQuality commit.' || return 1
    fi

    if [[ $candidate_commit == "$IPQUALITY_COMMIT" ]]; then
        printf 'IPQuality is already pinned to commit %s.\n' "$IPQUALITY_COMMIT"
        return 0
    fi

    UPDATE_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vpschecker-update.XXXXXX") || \
        fail 'could not create a temporary directory.' || return 1
    current_file="$UPDATE_TEMP_DIR/current-ip.sh"
    candidate_file="$UPDATE_TEMP_DIR/candidate-ip.sh"

    download_source "$IPQUALITY_COMMIT" "$current_file" || \
        fail 'could not download the currently pinned IPQuality source.' || return 1
    current_checksum=$(sha256_file "$current_file") || fail 'could not calculate SHA-256.' || return 1
    if [[ $current_checksum != "$IPQUALITY_SHA256" ]]; then
        fail 'the currently pinned IPQuality source does not match its recorded checksum.'
        return 1
    fi

    download_source "$candidate_commit" "$candidate_file" || \
        fail 'could not download the candidate IPQuality source.' || return 1
    candidate_checksum=$(sha256_file "$candidate_file") || fail 'could not calculate SHA-256.' || return 1
    candidate_version=$(source_version "$candidate_file") || \
        fail 'the candidate has an unsupported or missing script_version.' || return 1

    if [[ $candidate_checksum == "$IPQUALITY_SHA256" ]]; then
        printf 'Candidate commit %s contains the same ip.sh; no update is needed.\n' "$candidate_commit"
        return 0
    fi

    printf 'Current:   %s  %s  %s\n' "$IPQUALITY_VERSION" "$IPQUALITY_COMMIT" "$IPQUALITY_SHA256"
    printf 'Candidate: %s  %s  %s\n\n' "$candidate_version" "$candidate_commit" "$candidate_checksum"
    printf 'Source diff:\n'
    diff_status=0
    diff -u --label "IPQuality $IPQUALITY_VERSION" --label "IPQuality $candidate_version" \
        "$current_file" "$candidate_file" || diff_status=$?
    (( diff_status <= 1 )) || fail 'could not generate the source diff.' || return 1

    printf '\nUpdate the pinned IPQuality version? [y/N] '
    if ! read -r answer; then
        answer=''
    fi
    case $answer in
        y|Y|yes|YES|Yes) ;;
        *)
            printf 'Update cancelled; no files were changed.\n'
            return 0
            ;;
    esac

    update_pin "$candidate_commit" "$candidate_version" "$candidate_checksum" || \
        fail 'could not update lib/ipquality.sh.' || return 1
    printf 'Updated IPQuality pin to %s (%s).\n' "$candidate_version" "$candidate_commit"
}

trap cleanup_update_temp EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"
