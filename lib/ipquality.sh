readonly IPQUALITY_COMMIT=0ee5f192fed70c04615852efba0e4b8bd43546c7
readonly IPQUALITY_VERSION=v2026-08-09
readonly IPQUALITY_SHA256=9823c560e0d19769eb627329a31cb47da655d087166d86e40d9b6c77bc7f32fb
readonly IPQUALITY_URL="https://raw.githubusercontent.com/xykt/IPQuality/$IPQUALITY_COMMIT/ip.sh"

IPQUALITY_TEMP_DIR=''
IPQUALITY_SOURCE_PATH=''
IPQUALITY_SCRIPT_PATH=''
IPQUALITY_JSON_PATH=''
IPQUALITY_LOG_PATH=''

cleanup_ipquality_temp() {
    if [[ -n ${IPQUALITY_JSON_PATH:-} && -f $IPQUALITY_JSON_PATH ]]; then
        rm -f -- "$IPQUALITY_JSON_PATH"
    fi
    if [[ -n ${IPQUALITY_LOG_PATH:-} && -f $IPQUALITY_LOG_PATH ]]; then
        rm -f -- "$IPQUALITY_LOG_PATH"
    fi
    if [[ -n ${IPQUALITY_SCRIPT_PATH:-} && -f $IPQUALITY_SCRIPT_PATH ]]; then
        rm -f -- "$IPQUALITY_SCRIPT_PATH"
    fi
    if [[ -n ${IPQUALITY_SOURCE_PATH:-} && -f $IPQUALITY_SOURCE_PATH ]]; then
        rm -f -- "$IPQUALITY_SOURCE_PATH"
    fi
    if [[ -n ${IPQUALITY_TEMP_DIR:-} && -d $IPQUALITY_TEMP_DIR ]]; then
        rmdir -- "$IPQUALITY_TEMP_DIR" 2>/dev/null || true
    fi

    IPQUALITY_JSON_PATH=''
    IPQUALITY_LOG_PATH=''
    IPQUALITY_SCRIPT_PATH=''
    IPQUALITY_SOURCE_PATH=''
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

pin_ipquality_resources() {
    local source_path=$1
    local run_path=$2

    grep -qF '${rawgithub}main/' "$source_path" || return 1
    awk -v commit="$IPQUALITY_COMMIT" '
        { gsub(/\$\{rawgithub\}main\//, "${rawgithub}" commit "/"); print }
    ' "$source_path" > "$run_path" || return 1
    ! grep -qF '${rawgithub}main/' "$run_path"
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
    IPQUALITY_SOURCE_PATH="$IPQUALITY_TEMP_DIR/ipquality.source.sh"
    IPQUALITY_SCRIPT_PATH="$IPQUALITY_TEMP_DIR/ipquality.run.sh"

    if ! curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
        --retry 2 --retry-delay 1 --output "$IPQUALITY_SOURCE_PATH" \
        "$IPQUALITY_URL"; then
        printf 'Error: could not download pinned IPQuality source.\n' >&2
        cleanup_ipquality_temp
        return 1
    fi

    if ! verify_ipquality_checksum "$IPQUALITY_SOURCE_PATH" "$IPQUALITY_SHA256"; then
        printf 'Error: IPQuality checksum mismatch; the file will not be used.\n' >&2
        cleanup_ipquality_temp
        return 1
    fi

    if ! pin_ipquality_resources "$IPQUALITY_SOURCE_PATH" "$IPQUALITY_SCRIPT_PATH"; then
        printf 'Error: could not pin IPQuality runtime resources.\n' >&2
        cleanup_ipquality_temp
        return 1
    fi
    chmod 0600 "$IPQUALITY_SOURCE_PATH" "$IPQUALITY_SCRIPT_PATH" || {
        printf 'Error: could not restrict permissions on IPQuality files.\n' >&2
        cleanup_ipquality_temp
        return 1
    }

    printf '\nIPQuality source:\n'
    printf '  Version: %s\n' "$IPQUALITY_VERSION"
    printf '  Commit: %s\n' "$IPQUALITY_COMMIT"
    printf '  SHA-256: verified\n'
    printf '  Runtime resources: pinned to the same commit\n'
}

run_ipquality() {
    local status=0
    local valid_json=0

    [[ -f $IPQUALITY_SCRIPT_PATH ]] || {
        printf 'Error: verified IPQuality runtime source is unavailable.\n' >&2
        return 1
    }
    command -v jq >/dev/null 2>&1 || {
        printf 'Error: jq is required to validate the IPQuality result.\n' >&2
        return 1
    }

    IPQUALITY_JSON_PATH="$IPQUALITY_TEMP_DIR/ipquality.raw.json"
    IPQUALITY_LOG_PATH="$IPQUALITY_TEMP_DIR/ipquality.stderr.log"

    printf '\nRunning IPQuality in JSON/privacy mode...\n'
    TERM=dumb bash "$IPQUALITY_SCRIPT_PATH" -E -4 -f -j -n -p \
        > "$IPQUALITY_JSON_PATH" 2> "$IPQUALITY_LOG_PATH" || status=$?
    chmod 0600 "$IPQUALITY_JSON_PATH" "$IPQUALITY_LOG_PATH" 2>/dev/null || true

    if jq -e 'type == "object"' "$IPQUALITY_JSON_PATH" >/dev/null 2>&1; then
        valid_json=1
    fi
    if (( status != 0 && (status != 1 || valid_json == 0) )); then
        rm -f -- "$IPQUALITY_JSON_PATH"
        IPQUALITY_JSON_PATH=''
        printf 'Error: IPQuality exited with status %s.\n' "$status" >&2
        return "$status"
    fi
    if (( valid_json == 0 )); then
        rm -f -- "$IPQUALITY_JSON_PATH"
        IPQUALITY_JSON_PATH=''
        printf 'Error: IPQuality did not produce a valid JSON object.\n' >&2
        return 1
    fi

    printf 'IPQuality result: valid JSON received.\n'
}
