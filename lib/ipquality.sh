readonly IPQUALITY_COMMIT=0ee5f192fed70c04615852efba0e4b8bd43546c7
readonly IPQUALITY_VERSION=v2026-08-09
readonly IPQUALITY_SHA256=9823c560e0d19769eb627329a31cb47da655d087166d86e40d9b6c77bc7f32fb
readonly IPQUALITY_URL="https://raw.githubusercontent.com/xykt/IPQuality/$IPQUALITY_COMMIT/ip.sh"

IPQUALITY_TEMP_DIR=''
IPQUALITY_SCRIPT_PATH=''

cleanup_ipquality_temp() {
    if [[ -n ${IPQUALITY_SCRIPT_PATH:-} && -f $IPQUALITY_SCRIPT_PATH ]]; then
        rm -f -- "$IPQUALITY_SCRIPT_PATH"
    fi
    if [[ -n ${IPQUALITY_TEMP_DIR:-} && -d $IPQUALITY_TEMP_DIR ]]; then
        rmdir -- "$IPQUALITY_TEMP_DIR" 2>/dev/null || true
    fi

    IPQUALITY_SCRIPT_PATH=''
    IPQUALITY_TEMP_DIR=''
}

verify_ipquality_checksum() {
    local script_path=$1
    local expected_checksum=$2
    local checksum_output actual_checksum

    checksum_output=$(sha256sum -- "$script_path" 2>/dev/null) || return 1
    actual_checksum=${checksum_output%%[[:space:]]*}
    [[ $actual_checksum == "$expected_checksum" ]]
}

prepare_ipquality() {
    command -v curl >/dev/null 2>&1 || {
        printf 'Error: curl is required to download IPQuality.\n' >&2
        return 1
    }
    command -v sha256sum >/dev/null 2>&1 || {
        printf 'Error: sha256sum is required to verify IPQuality.\n' >&2
        return 1
    }

    IPQUALITY_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vpschecker.XXXXXX") || {
        printf 'Error: could not create a temporary directory.\n' >&2
        return 1
    }
    IPQUALITY_SCRIPT_PATH="$IPQUALITY_TEMP_DIR/ipquality.sh"

    if ! curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
        --retry 2 --retry-delay 1 --output "$IPQUALITY_SCRIPT_PATH" \
        "$IPQUALITY_URL"; then
        printf 'Error: could not download pinned IPQuality source.\n' >&2
        cleanup_ipquality_temp
        return 1
    fi

    if ! verify_ipquality_checksum "$IPQUALITY_SCRIPT_PATH" "$IPQUALITY_SHA256"; then
        printf 'Error: IPQuality checksum mismatch; the file will not be used.\n' >&2
        cleanup_ipquality_temp
        return 1
    fi

    printf '\nIPQuality source:\n'
    printf '  Version: %s\n' "$IPQUALITY_VERSION"
    printf '  Commit: %s\n' "$IPQUALITY_COMMIT"
    printf '  SHA-256: verified\n'
}
