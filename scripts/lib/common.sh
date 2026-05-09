#! /bin/bash
# Shared helpers for scripts/situ.sh and scripts/llamaservice.sh.
# Source from a script that has already set SCRIPT_DIR.

die() {
    echo "Error: $*" >&2
    exit 1
}

# Resolves CONFIG_FILE (defaulting to ../situ.conf relative to SCRIPT_DIR) and sources it.
# Args: $1 = explicit config path or empty, $2 = SCRIPT_DIR
load_config_file() {
    local explicit="$1" script_dir="$2"
    CONFIG_FILE="${explicit:-$script_dir/../situ.conf}"
    [ -f "$CONFIG_FILE" ] || die "config file not found: $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

# Fills in defaults for variables shared by both scripts.
apply_llama_defaults() {
    LM_PORT="${LM_PORT:-8080}"
    LLAMA_IMAGE="${LLAMA_IMAGE:-ghcr.io/ggml-org/llama.cpp:server}"
    LMSTUDIO_MODELS="${LMSTUDIO_MODELS:-$HOME/.situ/models}"
    CTX_SIZE="${CTX_SIZE:-64000}"
    TEMPERATURE="${TEMPERATURE:-0.1}"
    MODEL="${MODEL:-}"
}

# Ensures MODEL is set and the GGUF file is present in LMSTUDIO_MODELS.
require_model_file() {
    mkdir -p "${LMSTUDIO_MODELS}"
    [ -n "${MODEL}" ] || die "MODEL is not set in ${CONFIG_FILE}."
    [ -f "${LMSTUDIO_MODELS}/${MODEL}" ] || die "model file not found: ${LMSTUDIO_MODELS}/${MODEL}"
}

# When LOG_DIR is non-empty, creates it, resolves to an absolute path,
# and sets LOG_TS to a per-run timestamp.
prepare_log_dir() {
    [ -z "${LOG_DIR}" ] && return 0
    mkdir -p "${LOG_DIR}" 2>/dev/null || die "cannot create log directory: ${LOG_DIR}"
    LOG_DIR="$(cd "${LOG_DIR}" && pwd)"
    LOG_TS="$(date +%Y%m%d_%H%M%S)"
}

# Computes llama.cpp runtime args from LLAMA_IMAGE and LLAMA_CONFIG_FILE.
# Sets: LLAMA_GPU_ARGS, LLAMA_GPU_LAYERS, LLAMA_EXTRA_VOLUMES, LLAMA_EXTRA_ARGS.
build_llama_runtime_args() {
    LLAMA_GPU_ARGS=()
    LLAMA_GPU_LAYERS=()
    LLAMA_EXTRA_VOLUMES=()
    LLAMA_EXTRA_ARGS=()
    if [[ "${LLAMA_IMAGE}" == *cuda* ]]; then
        LLAMA_GPU_ARGS=(--device nvidia.com/gpu=all --security-opt=label=disable)
        LLAMA_GPU_LAYERS=(--n-gpu-layers 999)
    fi
    if [ -n "${LLAMA_CONFIG_FILE:-}" ]; then
        [ -f "${LLAMA_CONFIG_FILE}" ] || die "llama config file not found: ${LLAMA_CONFIG_FILE}"
        LLAMA_EXTRA_VOLUMES=(--volume "$(realpath "${LLAMA_CONFIG_FILE}"):/llama.cfg:ro")
        LLAMA_EXTRA_ARGS=(--config /llama.cfg)
    fi
}

# Kills every PID in LOG_PIDS, ignoring failures.
kill_tracked_pids() {
    for pid in "${LOG_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}

# Backgrounds `podman logs -f <container> > <logfile>` and tracks its PID in LOG_PIDS.
tail_container_to_file() {
    local container="$1" logfile="$2"
    podman logs -f "${container}" > "${logfile}" 2>&1 &
    LOG_PIDS+=($!)
}
