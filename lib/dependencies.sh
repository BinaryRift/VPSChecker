readonly -a CHECKED_PACKAGES=(jq curl bc netcat-openbsd dnsutils iproute2)

DEPENDENCY_JOURNAL_DIR=''
DEPENDENCY_JOURNAL_PATH=''
DEPENDENCY_ADDED_PACKAGES=()
DEPENDENCY_UPDATED_PACKAGES=()
DEPENDENCY_REQUESTED_PACKAGES=()

cleanup_dependency_journal() {
    if [[ -n ${DEPENDENCY_JOURNAL_PATH:-} && -f $DEPENDENCY_JOURNAL_PATH ]]; then
        rm -f -- "$DEPENDENCY_JOURNAL_PATH"
    fi
    if [[ -n ${DEPENDENCY_JOURNAL_DIR:-} && -d $DEPENDENCY_JOURNAL_DIR ]]; then
        rmdir -- "$DEPENDENCY_JOURNAL_DIR" 2>/dev/null || true
    fi

    DEPENDENCY_JOURNAL_PATH=''
    DEPENDENCY_JOURNAL_DIR=''
    DEPENDENCY_ADDED_PACKAGES=()
    DEPENDENCY_UPDATED_PACKAGES=()
    DEPENDENCY_REQUESTED_PACKAGES=()
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
    local package

    DEPENDENCY_JOURNAL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vpschecker-deps.XXXXXX") || return 1
    DEPENDENCY_JOURNAL_PATH="$DEPENDENCY_JOURNAL_DIR/changes.tsv"
    for package in "${DEPENDENCY_REQUESTED_PACKAGES[@]}"; do
        printf 'requested\t%s\n' "$package"
    done > "$DEPENDENCY_JOURNAL_PATH"
}

record_package_changes() {
    local before_snapshot=$1
    local before_versions=$2
    local after_snapshot after_versions added updated package old_version new_version

    after_snapshot=$(installed_package_names) || return 1
    added=$(comm -13 \
        <(printf '%s\n' "$before_snapshot" | LC_ALL=C sort -u) \
        <(printf '%s\n' "$after_snapshot" | LC_ALL=C sort -u)) || return 1

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
        DEBIAN_FRONTEND=noninteractive apt-get "$@"
    else
        sudo env DEBIAN_FRONTEND=noninteractive apt-get "$@"
    fi
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
    create_dependency_journal || {
        printf 'Error: could not create the dependency change journal.\n' >&2
        return 1
    }

    printf 'Updating APT package indexes...\n'
    run_apt_get update || {
        printf 'Error: apt-get update failed.\n' >&2
        return 1
    }

    printf 'Installing missing packages...\n'
    install_status=0
    run_apt_get install -y --no-install-recommends \
        "${DEPENDENCY_REQUESTED_PACKAGES[@]}" || install_status=$?

    record_package_changes "$before_snapshot" "$before_versions" || {
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
