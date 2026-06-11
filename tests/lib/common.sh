#!/bin/bash
# Shared helpers for SITU test scripts.
# Sourced by every test and by run_all.sh.

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'
CLR='\r\033[K'

running() {
    printf "${BLUE}[RUNNING]${NC} %s\r" "$1"
}

pass() {
    printf "${CLR}${GREEN}[PASSED]${NC}  %s\n" "$1"
}

fail() {
    printf "${CLR}${RED}[FAILED]${NC}  %s\n" "$1"
}

# Resolve repo root (parent of tests/) so tests work from any cwd.
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITU_TESTS_DIR="$(cd "${_COMMON_DIR}/.." && pwd)"
SITU_REPO_ROOT="$(cd "${_COMMON_DIR}/../.." && pwd)"
SITU_SCRIPT="${SITU_REPO_ROOT}/scripts/situ.sh"
SITU_TMP_DIR="${SITU_TMP_DIR:-${SITU_TESTS_DIR}/tmp}"

run_situ() {
    local timeout_cmd=()
    [ -n "${SITU_TIMEOUT:-}" ] && timeout_cmd=(timeout "${SITU_TIMEOUT}")
    if [ "${SITU_VERBOSE:-0}" != "1" ]; then
        ${timeout_cmd[@]+"${timeout_cmd[@]}"} "${SITU_SCRIPT}" "$@"
        return
    fi
    local log_dir="${SITU_VERBOSE_LOG_DIR:-${SITU_TMP_DIR}/verbose_logs}"
    mkdir -p "${log_dir}"
    _verbose_print_prompt "$@"
    ${timeout_cmd[@]+"${timeout_cmd[@]}"} "${SITU_SCRIPT}" "$@" --log "${log_dir}"
    local rc=$?
    _verbose_dump_logs "${log_dir}"
    return $rc
}

_verbose_print_prompt() {
    local args=("$@") i
    printf '\n\033[0;34m[verbose] prompt:\033[0m\n' >/dev/tty
    for (( i=0; i<${#args[@]}; i++ )); do
        if [[ "${args[$i]}" == "-p" || "${args[$i]}" == "--prompt" ]]; then
            printf '%s\n' "${args[$((i+1))]}" >/dev/tty
            return
        fi
    done
    printf '(no prompt — test mode)\n' >/dev/tty
}

_verbose_dump_logs() {
    local log_dir="$1" f found=0
    for f in "${log_dir}"/*.log; do
        [ -f "$f" ] || continue
        found=1
        printf '\n\033[0;34m[verbose] %s:\033[0m\n' "$(basename "$f")" >/dev/tty
        tr '\r' '\n' < "$f" >/dev/tty
    done
    [ "$found" -eq 0 ] && printf '\033[0;33m[verbose] no container logs found\033[0m\n' >/dev/tty
    printf '\n' >/dev/tty
}

strip_ansi() {
    printf '%s\n' "$1" | sed -E $'s/\033\\[[0-9;]*[mK]//g'
}

# Print [FAILED] line, dump remaining args to stderr, and exit 1.
# Requires DESCRIPTION to be set in the calling script.
fail_with() {
    fail "${DESCRIPTION}"
    printf '%s\n' "$@" >&2
    exit 1
}

# Per-test mount directory under tests/tmp/, named after the calling script
# (e.g. 01_compute_pi.sh -> tests/tmp/01_compute_pi/). Created if missing.
test_mount_dir() {
    local caller="${BASH_SOURCE[1]}"
    local name
    name="$(basename "${caller}" .sh)"
    local dir="${SITU_TMP_DIR}/${name}"
    mkdir -p "${dir}"
    printf '%s\n' "${dir}"
}
