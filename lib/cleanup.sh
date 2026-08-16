RUNTIME_CLEANUP_DONE=0
RUNTIME_CLEANUP_FAILED=0
AUTO_CLEANUP_REQUESTED=0
CLEANUP_PLAN_PATH=''
CLEANUP_PLAN_TEMP_PATH=''
PENDING_CLEANUP_PACKAGES=()

cleanup_usage() {
    terminal_heading_printf 1 'Usage:'
    cat <<'EOF'

  vps-check.sh cleanup

Safely remove packages recorded in .vpschecker-cleanup.plan in the current
directory. APT simulates the operation and asks for confirmation first.
EOF
}

set_cleanup_plan_path() {
    CLEANUP_PLAN_PATH="$PWD/.vpschecker-cleanup.plan"
}

load_cleanup_plan() {
    local package existing

    PENDING_CLEANUP_PACKAGES=()
    [[ -n ${CLEANUP_PLAN_PATH:-} && -f $CLEANUP_PLAN_PATH && ! -L $CLEANUP_PLAN_PATH ]] || return 1
    while IFS= read -r package || [[ -n $package ]]; do
        [[ -n $package ]] || continue
        is_valid_package_name "$package" || return 1
        if (( ${#PENDING_CLEANUP_PACKAGES[@]} > 0 )); then
            for existing in "${PENDING_CLEANUP_PACKAGES[@]}"; do
                [[ $existing != "$package" ]] || continue 2
            done
        fi
        PENDING_CLEANUP_PACKAGES+=("$package")
    done < "$CLEANUP_PLAN_PATH"
    (( ${#PENDING_CLEANUP_PACKAGES[@]} > 0 ))
}

save_dependency_cleanup_plan() {
    local package

    (( ${#DEPENDENCY_ADDED_PACKAGES[@]} > 0 )) || return 0
    [[ -n ${CLEANUP_PLAN_PATH:-} ]] || set_cleanup_plan_path
    [[ ! -L $CLEANUP_PLAN_PATH ]] || {
        terminal_warning 'refusing to replace a symbolic-link cleanup plan.'
        return 1
    }

    CLEANUP_PLAN_TEMP_PATH=$(mktemp "$PWD/.vpschecker-cleanup-plan.XXXXXX") || return 1
    if [[ -f $CLEANUP_PLAN_PATH ]]; then
        while IFS= read -r package || [[ -n $package ]]; do
            [[ -n $package ]] || continue
            is_valid_package_name "$package" || return 1
            printf '%s\n' "$package"
        done < "$CLEANUP_PLAN_PATH" > "$CLEANUP_PLAN_TEMP_PATH" || return 1
    fi
    for package in "${DEPENDENCY_ADDED_PACKAGES[@]}"; do
        is_valid_package_name "$package" || return 1
        printf '%s\n' "$package" >> "$CLEANUP_PLAN_TEMP_PATH" || return 1
    done
    LC_ALL=C sort -u "$CLEANUP_PLAN_TEMP_PATH" -o "$CLEANUP_PLAN_TEMP_PATH" || return 1
    chmod 0600 "$CLEANUP_PLAN_TEMP_PATH" || return 1
    mv -- "$CLEANUP_PLAN_TEMP_PATH" "$CLEANUP_PLAN_PATH" || return 1
    CLEANUP_PLAN_TEMP_PATH=''
}

print_cleanup_hint() {
    local command_path=${VPSCHECK_COMMAND_PATH:-${SCRIPT_DIR:-.}/vps-check.sh}

    [[ -f ${CLEANUP_PLAN_PATH:-} ]] || return 0
    printf '\nAPT packages added by VPSChecker were kept.\n'
    printf 'To remove them safely from this directory, run:\n  '
    terminal_printf 1 "$TERMINAL_STYLE_BOLD$TERMINAL_COLOR_BRIGHT_GREEN" \
        '%q cleanup' "$command_path"
    printf '\n'
}

remove_cleanup_plan() {
    if [[ -n ${CLEANUP_PLAN_PATH:-} && -e $CLEANUP_PLAN_PATH ]]; then
        rm -f -- "$CLEANUP_PLAN_PATH"
    fi
    PENDING_CLEANUP_PACKAGES=()
}

check_cleanup_requirements() {
    command -v dpkg-query >/dev/null 2>&1 || {
        terminal_error 'dpkg-query is required for package cleanup.'
        return 1
    }
    command -v apt-get >/dev/null 2>&1 || {
        terminal_error 'apt-get is required for package cleanup.'
        return 1
    }
    can_install_packages || {
        terminal_error 'package cleanup requires root or the sudo command.'
        return 1
    }
}

execute_cleanup_plan() {
    local ask_confirmation=$1

    load_cleanup_plan || {
        terminal_error 'no valid cleanup plan exists in the current directory.'
        return 1
    }
    check_cleanup_requirements || return 1
    cleanup_package_list "$ask_confirmation" "${PENDING_CLEANUP_PACKAGES[@]}" || return 1
    case $DEPENDENCY_CLEANUP_STATUS in
        REMOVED|NOT_REQUIRED) remove_cleanup_plan ;;
    esac
}

run_dependency_cleanup_command() {
    (( $# == 0 )) || {
        terminal_error 'the cleanup command does not accept arguments.'
        return 2
    }
    [[ -n ${CLEANUP_PLAN_PATH:-} ]] || set_cleanup_plan_path
    execute_cleanup_plan 1
}

finalize_report_cleanup() {
    local package_status=$1
    local json_temp text_temp report_dir

    [[ -n ${REPORT_JSON_PATH:-} || -n ${REPORT_TEXT_PATH:-} ]] || return 0
    [[ -f ${REPORT_JSON_PATH:-} && -f ${REPORT_TEXT_PATH:-} ]] || return 1
    case $package_status in
        NOT_REQUIRED|DEFERRED|REMOVED|SKIPPED_UNSAFE|FAILED) ;;
        *) return 1 ;;
    esac

    report_dir=${REPORT_JSON_PATH%/*}
    json_temp=$(mktemp "$report_dir/.vpschecker-report-json.XXXXXX") || return 1
    REPORT_TEMP_PATHS+=("$json_temp")
    text_temp=$(mktemp "$report_dir/.vpschecker-report-text.XXXXXX") || return 1
    REPORT_TEMP_PATHS+=("$text_temp")

    sed \
        -e 's/"status": "SCHEDULED_FOR_EXIT"/"status": "REMOVED"/' \
        -e "s/\"removal_status\": \"[A-Z_]*\"/\"removal_status\": \"$package_status\"/" \
        "$REPORT_JSON_PATH" > "$json_temp" || return 1
    sed \
        -e 's/Temporary files: SCHEDULED_FOR_EXIT/Temporary files: REMOVED/' \
        -e "s/Added package removal: [A-Z_]*/Added package removal: $package_status/" \
        "$REPORT_TEXT_PATH" > "$text_temp" || return 1
    grep -qF "\"removal_status\": \"$package_status\"" "$json_temp" || return 1

    chmod 0600 "$json_temp" "$text_temp" || return 1
    mv -- "$json_temp" "$REPORT_JSON_PATH" || return 1
    mv -- "$text_temp" "$REPORT_TEXT_PATH" || return 1
    REPORT_TEMP_PATHS=()
}

cleanup_runtime() {
    local exit_status=$?
    local package_status
    local plan_ready=1

    (( $# == 0 )) || exit_status=$1
    (( RUNTIME_CLEANUP_DONE == 0 )) || return "$exit_status"
    RUNTIME_CLEANUP_DONE=1
    trap - EXIT HUP INT TERM

    if ! defer_added_dependencies || ! save_dependency_cleanup_plan; then
        DEPENDENCY_CLEANUP_STATUS='FAILED'
        RUNTIME_CLEANUP_FAILED=1
        plan_ready=0
    fi
    if (( AUTO_CLEANUP_REQUESTED == 1 && plan_ready == 1 )) \
        && [[ -f ${CLEANUP_PLAN_PATH:-} ]]; then
        if ! execute_cleanup_plan 0; then
            RUNTIME_CLEANUP_FAILED=1
        fi
    fi
    package_status=$DEPENDENCY_CLEANUP_STATUS
    if [[ -f ${CLEANUP_PLAN_PATH:-} ]]; then
        print_cleanup_hint
    fi

    cleanup_dependency_journal
    cleanup_reputation_temp
    cleanup_check_host_temp
    cleanup_ipquality_temp
    if ! finalize_report_cleanup "$package_status"; then
        RUNTIME_CLEANUP_FAILED=1
        terminal_warning 'could not finalize cleanup status in the reports.'
    fi
    cleanup_report_temp
    if [[ -n ${CLEANUP_PLAN_TEMP_PATH:-} && -f $CLEANUP_PLAN_TEMP_PATH ]]; then
        rm -f -- "$CLEANUP_PLAN_TEMP_PATH"
    fi
    CLEANUP_PLAN_TEMP_PATH=''

    return "$exit_status"
}
