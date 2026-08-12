REPORT_OUTPUT_DIR=''

prepare_report_directory() {
    local requested_path=$1

    [[ -n $requested_path ]] || {
        printf 'Error: report directory cannot be empty.\n' >&2
        return 1
    }
    if [[ -e $requested_path && ! -d $requested_path ]]; then
        printf 'Error: report path exists but is not a directory: %s\n' "$requested_path" >&2
        return 1
    fi
    if [[ ! -d $requested_path ]]; then
        mkdir -p -- "$requested_path" || {
            printf 'Error: could not create report directory: %s\n' "$requested_path" >&2
            return 1
        }
    fi
    [[ -w $requested_path ]] || {
        printf 'Error: report directory is not writable: %s\n' "$requested_path" >&2
        return 1
    }
    REPORT_OUTPUT_DIR=$(cd -- "$requested_path" && pwd -P) || {
        printf 'Error: could not resolve report directory: %s\n' "$requested_path" >&2
        return 1
    }
}
