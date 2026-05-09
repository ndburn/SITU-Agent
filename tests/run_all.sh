#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<EOF
Usage: run_all.sh [-k|--keep]

Runs every test under tests/nonfunctional/ then tests/functional/.
By default, deletes everything inside tests/tmp/ (except .gitkeep) when done.

Options:
  -k, --keep, -keep   Preserve files in tests/tmp/ after the run (useful for inspecting failures).
EOF
}

parse_args() {
    KEEP=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -k|--keep|-keep)
                KEEP=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done
}

cleanup() {
    if [ -d "${SITU_TMP_DIR}" ]; then
        find "${SITU_TMP_DIR}" -mindepth 1 -maxdepth 1 ! -name '.gitkeep' -exec rm -rf {} +
    fi
}

discover_tests() {
    shopt -s nullglob
    TESTS=( "${SCRIPT_DIR}"/nonfunctional/*.sh "${SCRIPT_DIR}"/functional/*.sh )
}

run_tests() {
    PASSED=0
    FAILED=0
    FAILED_TESTS=()

    for test in "${TESTS[@]}"; do
        bash "${test}"
        if [ $? -eq 0 ]; then
            PASSED=$((PASSED + 1))
        else
            FAILED=$((FAILED + 1))
            FAILED_TESTS+=("$(basename "${test}")")
        fi
    done
}

report() {
    echo ""
    echo "------------------------------------"
    local total=$((PASSED + FAILED))
    if [ "${total}" -eq 0 ]; then
        echo "No tests found."
        exit 1
    fi
    if [ "${FAILED}" -eq 0 ]; then
        printf "${GREEN}All %d tests passed successfully.${NC}\n" "${total}"
        exit 0
    fi
    printf "${RED}%d/%d tests failed:${NC}\n" "${FAILED}" "${total}"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - ${t}"
    done
    exit 1
}

parse_args "$@"
mkdir -p "${SITU_TMP_DIR}"
cleanup
discover_tests
run_tests
if [ "${KEEP}" -eq 0 ]; then
    cleanup
fi
report
