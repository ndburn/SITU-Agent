#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

MOUNT_DIR="$(test_mount_dir)"
GENERATED_SCRIPT="${MOUNT_DIR}/compute_pi.sh"

DESCRIPTION='Implement a shell script to computes PI using the Gregory-Leibniz series.'
COMMAND=(-q --mountpoint "${MOUNT_DIR}" -p 'Implement a shell script compute_pi.sh that implements the Gregory-Leibniz series to compute PI with a precision of three decimal places. The script should output the value of PI with three decimals only (e.g. 3.141), no other text. Use awk or bc for floating-point arithmetic. Make sure it is computed 100% correctly. Make it executable. Do not run it.')
EXPECTED=('3.141' '3.142')

run_agent() {
    SITU_OUTPUT="$(run_situ "${COMMAND[@]}" 2>&1)"
    SITU_RC=$?
    if [ "${SITU_RC}" -ne 0 ]; then
        fail_with "situ exited with status ${SITU_RC}" "${SITU_OUTPUT}"
    fi
    if [ ! -f "${GENERATED_SCRIPT}" ]; then
        fail_with "expected file not created: ${GENERATED_SCRIPT}" "${SITU_OUTPUT}"
    fi
}

verify() {
    local output rc exp
    output="$(bash "${GENERATED_SCRIPT}" 2>&1)"
    rc=$?
    if [ "${rc}" -eq 0 ]; then
        for exp in "${EXPECTED[@]}"; do
            if printf '%s\n' "${output}" | grep -Fxq "${exp}"; then
                pass "${DESCRIPTION}"
                exit 0
            fi
        done
    fi
    fail_with "generated script exit=${rc}, output:" "${output}"
}

main() {
    running "${DESCRIPTION}"
    run_agent
    verify
}

main "$@"
