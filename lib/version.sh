VPSCHECK_VERSION=''

load_tool_version() {
    local version_file=$1
    local version

    [[ -r $version_file ]] || {
        printf 'Error: VERSION file is unavailable.\n' >&2
        return 1
    }
    IFS= read -r version < "$version_file" || {
        printf 'Error: VERSION file is empty.\n' >&2
        return 1
    }
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] || {
        printf 'Error: VERSION does not contain a valid semantic version.\n' >&2
        return 1
    }
    VPSCHECK_VERSION=$version
}
