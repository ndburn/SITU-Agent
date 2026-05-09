#!/bin/bash
# Self-test that runs INSIDE the situ container during `situ.sh --test`.
# Reads LM_SERVER_BASE_URL, MODEL, LMS_READY_TIMEOUT from the env passed in
# via -e flags. Loaded on the host with `cat` and forwarded to `bash -c`.

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { printf "${GREEN}[PASSED]${NC} %s\n" "$1"; }
fail() { printf "${RED}[FAILED]${NC} %s\n" "$1"; }
info() { printf "${CYAN}[INFO]  ${NC} %s\n" "$1"; }

check() {
    local label="$1" expect_pass="$2"; shift 2
    if "$@" >/dev/null 2>&1; then
        [ "$expect_pass" = "1" ] && pass "$label" || fail "$label"
    else
        [ "$expect_pass" = "0" ] && pass "$label" || fail "$label"
    fi
}

if ! curl -sf --max-time 2 "${LM_SERVER_BASE_URL}/models" -o /dev/null 2>/dev/null; then
    printf "Waiting for LM server"
    elapsed=0
    while ! curl -sf --max-time 2 "${LM_SERVER_BASE_URL}/models" -o /dev/null 2>/dev/null; do
        sleep 1; elapsed=$((elapsed + 1))
        printf "."
        if [ "${elapsed}" -ge "${LMS_READY_TIMEOUT}" ]; then
            printf " (timeout)\n"
            break
        fi
    done
    printf "\n\n"
fi

check "LM server is reachable     ${LM_SERVER_BASE_URL}/models" 1 \
    curl -sf --max-time 10 "${LM_SERVER_BASE_URL}/models" -o /dev/null

ACTIVE_MODEL="${MODEL}"
MODEL_SUFFIX=""
if [ -z "${ACTIVE_MODEL}" ]; then
    ACTIVE_MODEL=$(curl -sf --max-time 5 "${LM_SERVER_BASE_URL}/models" 2>/dev/null \
        | grep -o "\"id\":\"[^\"]*\"" | head -1 | sed 's/"id":"//;s/"//')
    MODEL_SUFFIX=" (defaulted)"
fi
[ -n "${ACTIVE_MODEL}" ] && info "Model in use               ${ACTIVE_MODEL}${MODEL_SUFFIX}"

check "External HTTP is blocked   http://example.com"   0 curl -sf --max-time 5 http://example.com  -o /dev/null
check "External HTTPS is blocked  https://example.com"  0 curl -sf --max-time 5 https://example.com -o /dev/null
check "External DNS is blocked    example.com"          0 getent hosts example.com
check "External TCP is blocked    8.8.8.8:53"           0 bash -c "true < /dev/tcp/8.8.8.8/53"

echo ""
