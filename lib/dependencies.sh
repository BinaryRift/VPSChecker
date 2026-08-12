readonly -a CHECKED_PACKAGES=(jq curl bc netcat-openbsd dnsutils iproute2)

DEPENDENCY_JOURNAL_DIR=''
DEPENDENCY_JOURNAL_PATH=''
DEPENDENCY_BEFORE_PACKAGES_PATH=''
DEPENDENCY_PLANNED_PACKAGES_PATH=''
DEPENDENCY_ADDED_PACKAGES=()
DEPENDENCY_UPDATED_PACKAGES=()
DEPENDENCY_REQUESTED_PACKAGES=()
DEPENDENCY_CLEANUP_STATUS='NOT_REQUIRED'

cleanup_dependency_journal() {
    local path

    for path in \
        "${DEPENDENCY_JOURNAL_PATH:-}" \
        "${DEPENDENCY_BEFORE_PACKAGES_PATH:-}" \
        "${DEPENDENCY_PLANNED_PACKAGES_PATH:-}"; do
        [[ -n $path && -f $path ]] && rm -f -- "$path"
    done
    if [[ -n ${DEPENDENCY_JOURNAL_DIR:-} && -d $DEPENDENCY_JOURNAL_DIR ]]; then
        rmdir -- "$DEPENDENCY_JOURNAL_DIR" 2>/dev/null || true
    fi

    DEPENDENCY_JOURNAL_PATH=''
    DEPENDENCY_JOURNAL_DIR=''
    DEPENDENCY_BEFORE_PACKAGES_PATH=''
    DEPENDENCY_PLANNED_PACKAGES_PATH=''
    DEPENDENCY_ADDED_PACKAGES=()
    DEPENDENCY_UPDATED_PACKAGES=()
    DEPENDENCY_REQUESTED_PACKAGES=()
    DEPENDENCY_CLEANUP_STATUS='NOT_REQUIRED'
}

package_installed() {
    local status

    status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1
    [[ $status == 'install ok installed' ]]
}

collect_missing_dependencies() {
    local package

    DEPENDENCY_REQUESTED_PACKAGES=()
    for package in "${CHECKED_PACKAGES[@]}"; do
        if ! package_installed "$package"; then
            DEPENDENCY_REQUESTED_PACKAGES+=("$package")
        fi
    done
}

installed_package_names() {
    local packages

    packages=$(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null) || return 1
    printf '%s\n' "$packages" | LC_ALL=C sort -u
}

installed_package_versions() {
    local packages

    packages=$(dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null) || return 1
    printf '%s\n' "$packages" | LC_ALL=C sort -u
}

create_dependency_journal() {
    local before_snapshot=$1
    local package

    DEPENDENCY_JOURNAL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vpschecker-deps.XXXXXX") || return 1
    DEPENDENCY_JOURNAL_PATH="$DEPENDENCY_JOURNAL_DIR/changes.tsv"
    DEPENDENCY_BEFORE_PACKAGES_PATH="$DEPENDENCY_JOURNAL_DIR/before-packages.txt"
    DEPENDENCY_PLANNED_PACKAGES_PATH="$DEPENDENCY_JOURNAL_DIR/planned-packages.txt"
    printf '%s\n' "$before_snapshot" > "$DEPENDENCY_BEFORE_PACKAGES_PATH" || return 1
    : > "$DEPENDENCY_PLANNED_PACKAGES_PATH" || return 1
    for package in "${DEPENDENCY_REQUESTED_PACKAGES[@]}"; do
        printf 'requested\t%s\n' "$package"
    done > "$DEPENDENCY_JOURNAL_PATH"
}

calculate_planned_additions() {
    local current_snapshot

    [[ -f ${DEPENDENCY_BEFORE_PACKAGES_PATH:-} ]] || return 1
    [[ -f ${DEPENDENCY_PLANNED_PACKAGES_PATH:-} ]] || return 1
    current_snapshot=$(installed_package_names) || return 1
    comm -13 \
        <(LC_ALL=C sort -u "$DEPENDENCY_BEFORE_PACKAGES_PATH") \
        <(printf '%s\n' "$current_snapshot" | LC_ALL=C sort -u) \
        | comm -12 - <(LC_ALL=C sort -u "$DEPENDENCY_PLANNED_PACKAGES_PATH")
}

record_package_changes() {
    local before_versions=$1
    local after_versions added updated package old_version new_version

    added=$(calculate_planned_additions) || return 1

    DEPENDENCY_ADDED_PACKAGES=()
    while IFS= read -r package; do
        [[ -n $package ]] || continue
        DEPENDENCY_ADDED_PACKAGES+=("$package")
        printf 'added\t%s\n' "$package" >> "$DEPENDENCY_JOURNAL_PATH"
    done <<< "$added"

    after_versions=$(installed_package_versions) || return 1
    updated=$(awk -F '\t' '
        NR == FNR { before[$1] = $2; next }
        ($1 in before) && before[$1] != $2 {
            print $1 "\t" before[$1] "\t" $2
        }
    ' <(printf '%s\n' "$before_versions") <(printf '%s\n' "$after_versions")) || return 1

    DEPENDENCY_UPDATED_PACKAGES=()
    while IFS=$'\t' read -r package old_version new_version; do
        [[ -n $package ]] || continue
        DEPENDENCY_UPDATED_PACKAGES+=("$package")
        printf 'updated\t%s\t%s\t%s\n' \
            "$package" "$old_version" "$new_version" >> "$DEPENDENCY_JOURNAL_PATH"
    done <<< "$updated"
}

can_install_packages() {
    local uid

    uid=$(id -u 2>/dev/null) || return 1
    [[ $uid == 0 ]] || command -v sudo >/dev/null 2>&1
}

run_apt_get() {
    local uid

    uid=$(id -u 2>/dev/null) || return 1
    if [[ $uid == 0 ]]; then
        LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get "$@"
    else
        sudo env LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get "$@"
    fi
}

plan_dependency_installation() {
    local simulation

    simulation=$(run_apt_get --simulate --no-remove install -y --no-install-recommends \
        "${DEPENDENCY_REQUESTED_PACKAGES[@]}") || return 1
    if printf '%s\n' "$simulation" | awk '$1 == "Remv" { found = 1 } END { exit !found }'; then
        return 1
    fi
    printf '%s\n' "$simulation" | awk '$1 == "Inst" { print $2 }' \
        | LC_ALL=C sort -u > "$DEPENDENCY_PLANNED_PACKAGES_PATH"
}

install_missing_dependencies() {
    local before_snapshot before_versions install_status package

    can_install_packages || {
        printf 'Error: installing dependencies requires root or the sudo command.\n' >&2
        return 1
    }
    command -v apt-get >/dev/null 2>&1 || {
        printf 'Error: apt-get is required to install dependencies.\n' >&2
        return 1
    }

    before_snapshot=$(installed_package_names) || {
        printf 'Error: could not snapshot installed packages.\n' >&2
        return 1
    }
    before_versions=$(installed_package_versions) || {
        printf 'Error: could not snapshot installed package versions.\n' >&2
        return 1
    }
    create_dependency_journal "$before_snapshot" || {
        printf 'Error: could not create the dependency change journal.\n' >&2
        return 1
    }

    printf 'Updating APT package indexes...\n'
    run_apt_get update || {
        printf 'Error: apt-get update failed.\n' >&2
        return 1
    }

    plan_dependency_installation || {
        printf 'Error: could not determine the dependency installation plan.\n' >&2
        return 1
    }

    printf 'Installing missing packages...\n'
    install_status=0
    run_apt_get --no-remove install -y --no-install-recommends \
        "${DEPENDENCY_REQUESTED_PACKAGES[@]}" || install_status=$?

    record_package_changes "$before_versions" || {
        printf 'Error: could not record dependency changes.\n' >&2
        return 1
    }
    (( install_status == 0 )) || {
        printf 'Error: apt-get install failed.\n' >&2
        return "$install_status"
    }

    for package in "${DEPENDENCY_REQUESTED_PACKAGES[@]}"; do
        package_installed "$package" || {
            printf 'Error: package was not installed: %s\n' "$package" >&2
            return 1
        }
    done

    printf 'Dependency changes recorded for cleanup.\n'
    if (( ${#DEPENDENCY_ADDED_PACKAGES[@]} > 0 )); then
        printf 'New packages: %s\n' "${DEPENDENCY_ADDED_PACKAGES[*]}"
    fi
    if (( ${#DEPENDENCY_UPDATED_PACKAGES[@]} > 0 )); then
        printf 'Updated existing packages (not scheduled for rollback): %s\n' \
            "${DEPENDENCY_UPDATED_PACKAGES[*]}"
    fi
}

refresh_added_dependencies() {
    local added package

    added=$(calculate_planned_additions) || return 1
    DEPENDENCY_ADDED_PACKAGES=()
    while IFS= read -r package; do
        [[ -n $package ]] && DEPENDENCY_ADDED_PACKAGES+=("$package")
    done <<< "$added"
}

defer_added_dependencies() {
    DEPENDENCY_CLEANUP_STATUS='NOT_REQUIRED'
    [[ -n ${DEPENDENCY_JOURNAL_DIR:-} ]] || return 0
    refresh_added_dependencies || {
        DEPENDENCY_CLEANUP_STATUS='FAILED'
        printf 'Warning: could not determine which packages were added; automatic cleanup remains disabled.\n' >&2
        return 1
    }
    (( ${#DEPENDENCY_ADDED_PACKAGES[@]} > 0 )) || return 0
    DEPENDENCY_CLEANUP_STATUS='DEFERRED'
}

is_valid_package_name() {
    [[ $1 =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$ ]]
}

cleanup_package_list() {
    local ask_confirmation=$1
    local package existing answer simulation removals expected
    local -a cleanup_packages=()
    shift

    for package in "$@"; do
        is_valid_package_name "$package" || {
            DEPENDENCY_CLEANUP_STATUS='FAILED'
            printf 'Warning: invalid package name in the cleanup plan: %s\n' "$package" >&2
            return 1
        }
        package_installed "$package" || continue
        if (( ${#cleanup_packages[@]} > 0 )); then
            for existing in "${cleanup_packages[@]}"; do
                [[ $existing != "$package" ]] || continue 2
            done
        fi
        cleanup_packages+=("$package")
    done

    if (( ${#cleanup_packages[@]} == 0 )); then
        DEPENDENCY_CLEANUP_STATUS='NOT_REQUIRED'
        printf '\nCleanup: none of the listed APT packages are installed.\n'
        return 0
    fi

    simulation=$(run_apt_get --simulate -o APT::Get::AutomaticRemove=false \
        remove -y "${cleanup_packages[@]}" 2>&1) || {
        DEPENDENCY_CLEANUP_STATUS='FAILED'
        printf 'Warning: APT could not simulate dependency cleanup; no packages were removed.\n' >&2
        return 1
    }
    removals=$(printf '%s\n' "$simulation" | awk '$1 == "Remv" { print $2 }' | LC_ALL=C sort -u)
    expected=$(printf '%s\n' "${cleanup_packages[@]}" | LC_ALL=C sort -u)
    if [[ $removals != "$expected" ]] \
        || printf '%s\n' "$simulation" | awk '$1 == "Inst" || $1 == "Conf" { found = 1 } END { exit !found }'; then
        DEPENDENCY_CLEANUP_STATUS='SKIPPED_UNSAFE'
        printf 'Warning: the APT cleanup plan is not limited to the recorded removal set; cleanup was skipped.\n' >&2
        return 1
    fi

    if (( ask_confirmation == 1 )); then
        printf 'Packages selected for removal: %s\n' "${cleanup_packages[*]}"
        printf 'Remove exactly these packages? [y/N] '
        if ! read -r answer; then
            answer=''
        fi
        case $answer in
            y|Y|yes|YES|Yes) ;;
            *)
                DEPENDENCY_CLEANUP_STATUS='DEFERRED'
                printf 'Package cleanup cancelled.\n' >&2
                return 1
                ;;
        esac
    fi

    printf '\nCleanup: removing packages added by this run: %s\n' "${cleanup_packages[*]}"
    run_apt_get -o APT::Get::AutomaticRemove=false remove -y \
        "${cleanup_packages[@]}" || {
        DEPENDENCY_CLEANUP_STATUS='FAILED'
        printf 'Warning: APT could not remove all packages added by this run.\n' >&2
        return 1
    }
    for package in "${cleanup_packages[@]}"; do
        if package_installed "$package"; then
            DEPENDENCY_CLEANUP_STATUS='FAILED'
            printf 'Warning: package remains installed after cleanup: %s\n' "$package" >&2
            return 1
        fi
    done

    DEPENDENCY_CLEANUP_STATUS='REMOVED'
    printf 'Dependency cleanup completed; existing package updates were kept.\n'
}

ensure_dependencies() {
    local answer

    command -v dpkg-query >/dev/null 2>&1 || {
        printf 'Error: dpkg-query is required to inspect APT packages.\n' >&2
        return 1
    }

    collect_missing_dependencies
    if (( ${#DEPENDENCY_REQUESTED_PACKAGES[@]} == 0 )); then
        printf '\nDependencies: all required APT packages are already installed.\n'
        return 0
    fi

    printf '\nMissing APT packages: %s\n' "${DEPENDENCY_REQUESTED_PACKAGES[*]}"
    printf 'Run apt-get update and install only these packages? [y/N] '
    if ! read -r answer; then
        answer=''
    fi
    case $answer in
        y|Y|yes|YES|Yes) ;;
        *)
            printf 'Dependency installation cancelled.\n' >&2
            return 1
            ;;
    esac

    install_missing_dependencies
}
