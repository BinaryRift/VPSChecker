usage() {
    cat <<'EOF'
Usage:
  vps-check.sh [OPTIONS]
  vps-check.sh cleanup
  vps-check.sh list-locations

Options:
  --ip IPV4              VPS IPv4 address. Omit to auto-detect it.
  --country CODE          Check-Host target country code (default: ru).
  --vless-port PORT      VLESS TCP port (default: 443).
  --hysteria2-port PORT  Hysteria2 UDP port (default: 443).
  --report-dir PATH      Report directory relative to the current directory
                         or an absolute path (default: ./reports).
  --print-report          Also print the text report to the terminal.
  --cleanup               Remove pending VPSChecker APT packages on exit.
  --version               Show the VPSChecker version.
  -h, --help             Show this help.
EOF
}

fail_usage() {
    printf 'Error: %s\n' "$1" >&2
    printf 'Run %s --help for usage.\n' "${0##*/}" >&2
    exit "$EXIT_USAGE"
}
