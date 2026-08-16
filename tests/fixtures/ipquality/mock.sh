#!/usr/bin/env bash

set -u

if [[ -n ${VPSCHECK_IPQUALITY_ARGS_LOG:-} ]]; then
    printf '%s\n' "$*" > "$VPSCHECK_IPQUALITY_ARGS_LOG"
fi

if [[ $* != '-E -4 -f -j -n -p' ]]; then
    printf 'unexpected arguments: %s\n' "$*" >&2
    exit 64
fi
if [[ ${VPSCHECK_IPQUALITY_EXIT:-0} != 0 ]]; then
    printf 'simulated IPQuality failure\n' >&2
    exit "$VPSCHECK_IPQUALITY_EXIT"
fi

printf 'mock diagnostic output\n' >&2
if [[ ${VPSCHECK_IPQUALITY_INVALID_JSON:-0} == 1 ]]; then
    printf 'not-json\n'
else
    printf '{"Head":{"IP":"203.0.113.10"},"Info":{},"Score":{},"Factor":{}}\n'
fi

exit "${VPSCHECK_IPQUALITY_FINAL_EXIT:-0}"
