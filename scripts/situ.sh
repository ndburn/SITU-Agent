#! /bin/bash

VERSION="0.4.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat >&2 <<EOF
Usage: situ [options]

Options:
  -q, --query '<prompt>'   Run a single query non-interactively and exit.
  -s, --silent             Suppress status messages (useful when piping output).
  -c, --config <file>      Use a specific config file (default: situ.conf).
  -t, --test               Run network connectivity tests and exit.
  -h, --help               Show this help message and exit.

Examples:
  situ.sh                                        Start an interactive session.
  situ.sh -c situ2.conf                          Use situ2.conf as the config.
  situ.sh -q 'Who was Albert Einstein?'          Run a single query and exit.
  situ.sh -s -q 'Who was Albert Einstein?'       Run query and suppress status messages.
  situ.sh --test                                 Verify configuration and network isolation.
EOF
}

QUERY=""
RUN_TEST=0
SILENT=0
CONFIG_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            shift
            if [[ $# -gt 0 ]]; then
                CONFIG_FILE="$1"
                shift
            else
                echo "Error: --config requires an argument" >&2
                exit 1
            fi
            ;;
        -s|--silent)
            SILENT=1
            shift
            ;;
        -q|--query)
            shift
            if [[ $# -gt 0 ]]; then
                QUERY="$1"
                shift
            else
                echo "Error: --query requires an argument" >&2
                exit 1
            fi
            ;;
        -t|--test)
            RUN_TEST=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/../situ.conf}"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: config file not found: $CONFIG_FILE" >&2
    exit 1
fi
source "$CONFIG_FILE"

MOUNTPOINT="${MOUNTPOINT:-$(pwd)}"
MODE="${MODE:-RESTRICTED}"
LM_PORT="${LM_PORT:-8080}"
LLAMA_IMAGE="${LLAMA_IMAGE:-ghcr.io/ggml-org/llama.cpp:server}"
LMSTUDIO_MODELS="${LMSTUDIO_MODELS:-$HOME/.situ/models}"
CTX_SIZE="${CTX_SIZE:-64000}"
LMS_READY_TIMEOUT="${LMS_READY_TIMEOUT:-300}"
MODEL="${MODEL:-}"

if [ -n "${LM_HOST:-}" ] && [ "${MODE}" = "RESTRICTED" ]; then
    echo "Error: LM_HOST is set but MODE=RESTRICTED. Set MODE=NETWORK in situ.conf to allow external access." >&2
    exit 1
fi

if [ "${SILENT}" = "0" ]; then
    echo "SITU v${VERSION}"
    echo ""
    echo "Config    : ${CONFIG_FILE}"
    if [ -z "${LM_HOST:-}" ]; then
        echo "LM server : POD  (llama.cpp official image)"
    else
        echo "LM server : http://${LM_HOST}:${LM_PORT}/v1"
    fi
    echo "Model     : ${MODEL:-<none>}"
    echo "Ctx size  : ${CTX_SIZE}"
    echo "Mountpoint: ${MOUNTPOINT}"
    echo "Mode      : ${MODE}"
    echo ""
fi

POD_NAME="situ-$$"

cleanup() { podman pod rm -f "${POD_NAME}" > /dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

if [ "${MODE}" = "RESTRICTED" ]; then
    podman pod create --name "${POD_NAME}" --network=none > /dev/null
else
    podman pod create --name "${POD_NAME}" > /dev/null
fi

if [ -z "${LM_HOST:-}" ]; then
    LM_SERVER_BASE_URL="http://127.0.0.1:${LM_PORT}/v1"
    mkdir -p "${LMSTUDIO_MODELS}"
    if [ -z "${MODEL}" ]; then
        echo "Error: MODEL is not set in situ.conf." >&2
        exit 1
    fi
    if [ ! -f "${LMSTUDIO_MODELS}/${MODEL}" ]; then
        echo "Error: model file not found: ${LMSTUDIO_MODELS}/${MODEL}" >&2
        exit 1
    fi
    podman run --pod "${POD_NAME}" -d \
        --name "${POD_NAME}-llama" \
        --volume "${LMSTUDIO_MODELS}:/models:ro" \
        "${LLAMA_IMAGE}" \
        --model "/models/${MODEL}" \
        --port "${LM_PORT}" \
        --host 0.0.0.0 \
        --ctx-size "${CTX_SIZE}" > /dev/null
else
    LM_SERVER_BASE_URL="http://${LM_HOST}:${LM_PORT}/v1"
fi

SITU_ENV=(
    -e LM_SERVER_BASE_URL="${LM_SERVER_BASE_URL}"
    -e MODEL="${MODEL}"
    -e LMS_READY_TIMEOUT="${LMS_READY_TIMEOUT}"
    -e MODE="${MODE}"
    -e CTX_SIZE="${CTX_SIZE}"
    -e LM_HOST="${LM_HOST:-}"
    -e SILENT="${SILENT}"
)

if [ "${RUN_TEST}" = "1" ]; then
    TESTSCRIPT='
GREEN='"'"'\033[0;32m'"'"'; RED='"'"'\033[0;31m'"'"'; CYAN='"'"'\033[0;36m'"'"'; NC='"'"'\033[0m'"'"'
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
    ACTIVE_MODEL=$(curl -sf --max-time 5 "${LM_SERVER_BASE_URL}/models" 2>/dev/null | \
        grep -o "\"id\":\"[^\"]*\"" | head -1 | sed "s/\"id\":\"//;s/\"//")
    MODEL_SUFFIX=" (defaulted)"
fi
[ -n "${ACTIVE_MODEL}" ] && info "Model in use               ${ACTIVE_MODEL}${MODEL_SUFFIX}"
check "External HTTP is blocked   http://example.com"   0 curl -sf --max-time 5 http://example.com  -o /dev/null
check "External HTTPS is blocked  https://example.com"  0 curl -sf --max-time 5 https://example.com -o /dev/null
check "External DNS is blocked    example.com"          0 getent hosts example.com
check "External TCP is blocked    8.8.8.8:53"           0 bash -c "true < /dev/tcp/8.8.8.8/53"

echo ""
'
    podman run --rm -it \
        --pod "${POD_NAME}" \
        "${SITU_ENV[@]}" \
        situ:latest \
        bash -c "$TESTSCRIPT"
    exit $?
fi

if [[ -n "$QUERY" ]]; then
    podman run --rm \
        --pod "${POD_NAME}" \
        --volume "${MOUNTPOINT}:/workspace" \
        "${SITU_ENV[@]}" \
        situ:latest \
        pi "$QUERY"
else
    podman run --rm -it \
        --pod "${POD_NAME}" \
        --volume "${MOUNTPOINT}:/workspace" \
        "${SITU_ENV[@]}" \
        situ:latest \
        pi
fi
