#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

DESCRIPTION='Check network isolation (LM reachable, external HTTP/HTTPS/DNS/TCP blocked)'
COMMAND=(-q -t)
EXPECTED=(
    'LM server is reachable'
    'External HTTP is blocked'
    'External HTTPS is blocked'
    'External DNS is blocked'
    'External TCP is blocked'
)

run_agent() {
    SITU_OUTPUT="$(run_situ "${COMMAND[@]}")"
    SITU_RC=$?
    if [ "${SITU_RC}" -ne 0 ]; then
        fail_with "situ exited with status ${SITU_RC}" "${SITU_OUTPUT}"
    fi
}

verify() {
    local clean
    clean="$(strip_ansi "${SITU_OUTPUT}")"
    if printf '%s\n' "${clean}" | grep -Fq '[FAILED]'; then
        fail_with "${SITU_OUTPUT}"
    fi
    for label in "${EXPECTED[@]}"; do
        printf '%s\n' "${clean}" | grep -Fq "[PASSED] ${label}" \
            || fail_with "missing expected check: ${label}" "${SITU_OUTPUT}"
    done
    pass "${DESCRIPTION}"
    exit 0
}

main() {
    running "${DESCRIPTION}"
    run_agent
    verify
}

main "$@"
