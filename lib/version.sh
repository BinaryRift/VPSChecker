VPSCHECK_VERSION=''

load_tool_version() {
    local version_file=$1
    local version

    [[ -r $version_file ]] || {
        terminal_error 'VERSION file is unavailable.'
        return 1
    }
    IFS= read -r version < "$version_file" || {
        terminal_error 'VERSION file is empty.'
        return 1
    }
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] || {
        terminal_error 'VERSION does not contain a valid semantic version.'
        return 1
    }
    VPSCHECK_VERSION=$version
}
