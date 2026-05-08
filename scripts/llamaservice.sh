#! /bin/bash

VERSION="0.4.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat >&2 <<EOF
Usage: llamaservice.sh [options] [-- <llama.cpp args>...]

Options:
  -c, --config <file>           Use a specific config file (default: situ.conf).
  -h, --help                    Show this help message and exit.
      --llama-config <file>     Inject a llama.cpp JSON config file into the server.
  -l, --log <directory>         Write logs to <directory>/llama_<ts>.log.
  -s, --silent                  Suppress status messages (useful when piping output).
  --                            End of options. Everything after is forwarded verbatim
                                to the llama.cpp server (overrides script defaults
                                and --llama-config JSON config; last value wins).

Examples:
  llama.sh                                       Start the llama.cpp server, port published on 0.0.0.0.
  llama.sh -c situserver.conf                    Use a different config file.
  llama.sh --llama-config mycfg.json             Inject a custom llama.cpp JSON config.
  llama.sh -l ./logs                             Write llama.cpp logs to ./logs/llama_<ts>.log.
  llama.sh -- --temp 0.2 --top-p 0.95            Pass extra args directly to llama.cpp.
EOF
}

SILENT=0
CONFIG_FILE=""
LLAMA_CONFIG_FILE=""
LOG_DIR=""
LLAMA_PASSTHROUGH=()

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
        --llama-config)
            shift
            if [[ $# -gt 0 ]]; then
                LLAMA_CONFIG_FILE="$1"
                shift
            else
                echo "Error: --llama-config requires an argument" >&2
                exit 1
            fi
            ;;
        -l|--log)
            shift
            if [[ $# -gt 0 ]]; then
                LOG_DIR="$1"
                shift
            else
                echo "Error: --log requires an argument" >&2
                exit 1
            fi
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            LLAMA_PASSTHROUGH=("$@")
            break
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

LM_PORT="${LM_PORT:-8080}"
LLAMA_IMAGE="${LLAMA_IMAGE:-ghcr.io/ggml-org/llama.cpp:server}"
LMSTUDIO_MODELS="${LMSTUDIO_MODELS:-$HOME/.situ/models}"
CTX_SIZE="${CTX_SIZE:-64000}"
TEMPERATURE="${TEMPERATURE:-0.1}"
MODEL="${MODEL:-}"

if [ -z "${MODEL}" ]; then
    echo "Error: MODEL is not set in ${CONFIG_FILE}." >&2
    exit 1
fi

mkdir -p "${LMSTUDIO_MODELS}"
if [ ! -f "${LMSTUDIO_MODELS}/${MODEL}" ]; then
    echo "Error: model file not found: ${LMSTUDIO_MODELS}/${MODEL}" >&2
    exit 1
fi

if [ -n "${LOG_DIR}" ]; then
    if ! mkdir -p "${LOG_DIR}" 2>/dev/null; then
        echo "Error: cannot create log directory: ${LOG_DIR}" >&2
        exit 1
    fi
    LOG_DIR="$(cd "${LOG_DIR}" && pwd)"
    LOG_TS="$(date +%Y%m%d_%H%M%S)"
fi

LLAMA_EXTRA_ARGS=()
LLAMA_EXTRA_VOLUMES=()
LLAMA_GPU_ARGS=()
LLAMA_GPU_LAYERS=()
if [[ "${LLAMA_IMAGE}" == *cuda* ]]; then
    LLAMA_GPU_ARGS=(--device nvidia.com/gpu=all --security-opt=label=disable)
    LLAMA_GPU_LAYERS=(--n-gpu-layers 999)
fi
if [ -n "${LLAMA_CONFIG_FILE}" ]; then
    if [ ! -f "${LLAMA_CONFIG_FILE}" ]; then
        echo "Error: llama config file not found: ${LLAMA_CONFIG_FILE}" >&2
        exit 1
    fi
    LLAMA_EXTRA_VOLUMES=(--volume "$(realpath "${LLAMA_CONFIG_FILE}"):/llama.cfg:ro")
    LLAMA_EXTRA_ARGS=(--config /llama.cfg)
fi

if [ "${SILENT}" = "0" ]; then
    echo "llama.sh v${VERSION}"
    echo ""
    echo "Config    : ${CONFIG_FILE}"
    echo "Image     : ${LLAMA_IMAGE}"
    echo "Model     : ${MODEL}"
    echo "Ctx size  : ${CTX_SIZE}"
    echo "Port      : ${LM_PORT} (published on 0.0.0.0)"
    [ -n "${LOG_DIR}" ] && echo "Logs      : ${LOG_DIR}"
    echo ""
fi

CONTAINER_NAME="llama-$$"
LOG_PIDS=()

cleanup() {
    for pid in "${LOG_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    podman rm -f "${CONTAINER_NAME}" > /dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

podman run -d \
    --name "${CONTAINER_NAME}" \
    --publish "0.0.0.0:${LM_PORT}:${LM_PORT}" \
    "${LLAMA_GPU_ARGS[@]}" \
    --volume "${LMSTUDIO_MODELS}:/models:ro" \
    "${LLAMA_EXTRA_VOLUMES[@]}" \
    "${LLAMA_IMAGE}" \
    "${LLAMA_EXTRA_ARGS[@]}" \
    --model "/models/${MODEL}" \
    --port "${LM_PORT}" \
    --host 0.0.0.0 \
    --ctx-size "${CTX_SIZE}" \
    --temp "${TEMPERATURE}" \
    "${LLAMA_GPU_LAYERS[@]}" \
    "${LLAMA_PASSTHROUGH[@]}" > /dev/null

if [ -n "${LOG_DIR}" ]; then
    podman logs -f "${CONTAINER_NAME}" > "${LOG_DIR}/llama_${LOG_TS}.log" 2>&1 &
    LOG_PIDS+=($!)
fi

if [ "${SILENT}" = "1" ]; then
    podman wait "${CONTAINER_NAME}" > /dev/null
else
    podman logs -f "${CONTAINER_NAME}"
fi
