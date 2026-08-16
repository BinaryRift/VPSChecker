REPORT_OUTPUT_DIR=''

prepare_report_directory() {
    local requested_path=$1

    [[ -n $requested_path ]] || {
        terminal_error 'report directory cannot be empty.'
        return 1
    }
    if [[ -e $requested_path && ! -d $requested_path ]]; then
        terminal_error 'report path exists but is not a directory: %s' "$requested_path"
        return 1
    fi
    if [[ ! -d $requested_path ]]; then
        mkdir -p -- "$requested_path" || {
            terminal_error 'could not create report directory: %s' "$requested_path"
            return 1
        }
    fi
    [[ -w $requested_path ]] || {
        terminal_error 'report directory is not writable: %s' "$requested_path"
        return 1
    }
    REPORT_OUTPUT_DIR=$(cd -- "$requested_path" && pwd -P) || {
        terminal_error 'could not resolve report directory: %s' "$requested_path"
        return 1
    }
}
