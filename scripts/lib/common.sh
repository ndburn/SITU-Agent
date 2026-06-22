#! /bin/bash
# Shared helpers for scripts/situ.sh and scripts/llamaservice.sh.
# Source from a script that has already set SCRIPT_DIR.

VERSION="0.12.0"

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
    CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
    CE="${CONTAINER_ENGINE}"
    CE_USERNS_ARGS=()
    [ "${CE}" = "podman" ] && CE_USERNS_ARGS=(--userns=keep-id)

    LM_PORT="${LM_PORT:-8080}"
    LLAMA_IMAGE="${LLAMA_IMAGE:-ghcr.io/ggml-org/llama.cpp:server}"
    LMSTUDIO_MODELS="${LMSTUDIO_MODELS:-$HOME/.situ/models}"
    CTX_SIZE="${CTX_SIZE:-0}"
    TEMPERATURE="${TEMPERATURE:-0.1}"
    PARALLEL="${PARALLEL:-1}"
    MODEL="${MODEL:-}"
}

# Returns 0 if the named container exists, 1 otherwise.
ce_container_exists() {
    if [ "${CE}" = "podman" ]; then
        podman container exists "$1" 2>/dev/null
    else
        docker inspect --type container "$1" > /dev/null 2>&1
    fi
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

# Computes llama.cpp runtime args from LLAMA_IMAGE and SITU_LLAMA_EXTRA_ARGS.
# Sets: LLAMA_GPU_ARGS, LLAMA_GPU_LAYERS, LLAMA_EXTRA_ARGS.
# SITU_LLAMA_EXTRA_ARGS: space-separated extra flags appended verbatim to the llama.cpp CLI
#   (e.g. "--spec-type draft-mtp --spec-draft-model /models/foo.gguf --spec-draft-n-max 4").
build_llama_runtime_args() {
    LLAMA_GPU_ARGS=()
    LLAMA_GPU_LAYERS=()
    LLAMA_EXTRA_ARGS=()
    if [[ "${LLAMA_IMAGE}" == *cuda* ]]; then
        if [ "${CE}" = "podman" ]; then
            LLAMA_GPU_ARGS=(--device nvidia.com/gpu=all --security-opt=label=disable)
        else
            LLAMA_GPU_ARGS=(--gpus all --security-opt=label=disable)
        fi
        LLAMA_GPU_LAYERS=(--n-gpu-layers 999)
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        # mlock prevents macOS from paging KV cache to disk
        LLAMA_GPU_LAYERS=(--n-gpu-layers 99 \
            -b 2048 -ub 2048 \
            --mlock)
    else
        # Pin to physical cores; hyperthreads thrash L3 on decode.
        # flash-attn left to llama.cpp's auto (CPU flash-attn has historical perf quirks)
        # Q8_0 KV cache: ~47% memory reduction, negligible quality loss on CPU.
        local phys_cores
        phys_cores=$(grep -m1 "cpu cores" /proc/cpuinfo 2>/dev/null | awk '{print $4}')
        phys_cores=${phys_cores:-$(nproc 2>/dev/null || echo 4)}
        LLAMA_GPU_LAYERS=(-t "${phys_cores}" --cache-type-k q8_0 --cache-type-v q8_0)
    fi
    if [ -n "${MMPROJ:-}" ]; then
        LLAMA_EXTRA_ARGS+=(--mmproj "/models/${MMPROJ}")
    fi
    if [ -n "${SITU_LLAMA_EXTRA_ARGS:-}" ]; then
        # shellcheck disable=SC2206
        LLAMA_EXTRA_ARGS+=(${SITU_LLAMA_EXTRA_ARGS})
    fi
}

# Kills every PID in LOG_PIDS, ignoring failures.
kill_tracked_pids() {
    for pid in "${LOG_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}

# Backgrounds `<CE> logs -f <container> > <logfile>` and tracks its PID in LOG_PIDS.
tail_container_to_file() {
    local container="$1" logfile="$2"
    ${CE} logs -f "${container}" > "${logfile}" 2>&1 &
    LOG_PIDS+=($!)
}

# Returns a unique name with PID and timestamp.
generate_unique_name() {
    local prefix="$1"
    echo "${prefix}-$$-$(date +%s)"
}

# Cleans up stale resources and resets failed systemd scopes (Podman only).
# This prevents "File exists" OCI errors from previous interrupted runs.
# $1: (optional) Pod or container name to remove.
reset_stale_resources() {
    local target="$1"
    if [ -n "$target" ]; then
        ${CE} network rm "$target" > /dev/null 2>&1 || true
    fi
    # Kill any leftover situ containers/networks from interrupted previous runs.
    # Stale llama containers can hold port 8080 in the VM and cause lm_ready
    # to return true before the current run's sidecar has started.
    ${CE} ps -a --format '{{.Names}}' 2>/dev/null \
        | grep -E '^situ-(agent|llama)-' \
        | xargs -r ${CE} rm -f > /dev/null 2>&1 || true
    ${CE} network ls --format '{{.Name}}' 2>/dev/null \
        | grep -E '^situ-net-' \
        | xargs -r ${CE} network rm > /dev/null 2>&1 || true
    if [ "${CE}" = "podman" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl --user reset-failed "libpod-*.scope" >/dev/null 2>&1 || true
    fi
}
