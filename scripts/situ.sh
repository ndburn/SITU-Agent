#! /bin/bash

VERSION="0.4.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat >&2 <<EOF
Usage: situ [options]

Options:
  -c, --config <file>           Use a specific config file (default: situ.conf).
      --ctx-size <tokens>       Override CTX_SIZE (context window in tokens).
  -h, --help                    Show this help message.
      --llama-config <file>     Inject a llama.cpp JSON config file into the server.
      --llama-image <image>     Override LLAMA_IMAGE (llama.cpp container image).
  -l, --log <directory>         Write logs to <directory>/llama_<ts>.log and <directory>/situ_<ts>.log.
      --mode <RESTRICTED|NETWORK>  Override MODE from the config file.
      --model <gguf>            Override MODEL (GGUF filename in LMSTUDIO_MODELS).
      --mountpoint <dir>        Override MOUNTPOINT (directory mounted as /workspace).
  -q, --query '<prompt>'        Run a single query non-interactively and exit.
  -s, --silent                  Suppress status messages (useful when piping output).
  -T, --temperature <value>     Sampling temperature for the llama.cpp sidecar (default: 0.1, local sidecar only).
  -t, --test                    Verify configuration and network isolation.

Examples:
  situ.sh                                        Start an interactive session.
  situ.sh -c situ2.conf                          Use situ2.conf as the config.
  situ.sh -q 'Who was Albert Einstein?'          Run a single query and exit.
  situ.sh -s -q 'Who was Albert Einstein?'       Run query and suppress status messages.
  situ.sh --model gemma-4-E4B-it-Q4_K_M.gguf --ctx-size 32000
                                                 Override config values for one run.
  situ.sh --test                                 Verify configuration and network isolation.
EOF
}

parse_cli_args() {
    QUERY=""
    RUN_TEST=0
    SILENT=0
    CONFIG_FILE_ARG=""
    LLAMA_CONFIG_FILE=""
    LOG_DIR=""
    _CLI_TEMPERATURE=""
    _CLI_MODE=""
    _CLI_MOUNTPOINT=""
    _CLI_LLAMA_IMAGE=""
    _CLI_MODEL=""
    _CLI_CTX_SIZE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                [ $# -ge 2 ] || die "--config requires an argument"
                CONFIG_FILE_ARG="$2"; shift 2 ;;
            -s|--silent)
                SILENT=1; shift ;;
            -q|--query)
                [ $# -ge 2 ] || die "--query requires an argument"
                QUERY="$2"; shift 2 ;;
            --llama-config)
                [ $# -ge 2 ] || die "--llama-config requires an argument"
                LLAMA_CONFIG_FILE="$2"; shift 2 ;;
            -l|--log)
                [ $# -ge 2 ] || die "--log requires an argument"
                LOG_DIR="$2"; shift 2 ;;
            -T|--temperature)
                [ $# -ge 2 ] || die "--temperature requires an argument"
                _CLI_TEMPERATURE="$2"; shift 2 ;;
            --mode)
                [ $# -ge 2 ] || die "--mode requires an argument"
                [[ "$2" == "RESTRICTED" || "$2" == "NETWORK" ]] \
                    || die "--mode must be RESTRICTED or NETWORK (got: $2)"
                _CLI_MODE="$2"; shift 2 ;;
            --mountpoint)
                [ $# -ge 2 ] || die "--mountpoint requires an argument"
                _CLI_MOUNTPOINT="$2"; shift 2 ;;
            --llama-image)
                [ $# -ge 2 ] || die "--llama-image requires an argument"
                _CLI_LLAMA_IMAGE="$2"; shift 2 ;;
            --model)
                [ $# -ge 2 ] || die "--model requires an argument"
                _CLI_MODEL="$2"; shift 2 ;;
            --ctx-size)
                [ $# -ge 2 ] || die "--ctx-size requires an argument"
                _CLI_CTX_SIZE="$2"; shift 2 ;;
            -t|--test)
                RUN_TEST=1; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                exit 1 ;;
        esac
    done
}

# Layers CLI overrides on top of config-loaded values, then fills situ-specific defaults.
apply_situ_overrides() {
    MOUNTPOINT="${_CLI_MOUNTPOINT:-${MOUNTPOINT:-$(pwd)}}"
    MODE="${_CLI_MODE:-${MODE:-RESTRICTED}}"
    LLAMA_IMAGE="${_CLI_LLAMA_IMAGE:-${LLAMA_IMAGE}}"
    CTX_SIZE="${_CLI_CTX_SIZE:-${CTX_SIZE}}"
    TEMPERATURE="${_CLI_TEMPERATURE:-${TEMPERATURE}}"
    MODEL="${_CLI_MODEL:-${MODEL}}"
    LMS_READY_TIMEOUT="${LMS_READY_TIMEOUT:-300}"
}

validate_situ_config() {
    if [ -n "${LM_HOST:-}" ] && [ "${MODE}" = "RESTRICTED" ]; then
        die "LM_HOST is set but MODE=RESTRICTED. Set MODE=NETWORK in situ.conf to allow external access."
    fi
    if [ -n "${LLAMA_CONFIG_FILE}" ] && [ -n "${LM_HOST:-}" ]; then
        echo "Warning: --llama-config is ignored when connecting to an external LM server (LM_HOST is set)." >&2
    fi
}

print_banner() {
    [ "${SILENT}" = "1" ] && return 0
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
    [ -n "${LOG_DIR}" ] && echo "Logs      : ${LOG_DIR}"
    echo ""
}

cleanup() {
    kill_tracked_pids
    podman pod rm -f "${POD_NAME}" > /dev/null 2>&1 || true
}

start_situ_log_tail() {
    [ -z "${LOG_DIR}" ] && return 0
    (
        while ! podman container exists "${POD_NAME}" 2>/dev/null; do sleep 0.2; done
        podman logs -f "${POD_NAME}" > "${LOG_DIR}/situ_${LOG_TS}.log" 2>&1
    ) &
    LOG_PIDS+=($!)
}

watch_llama_sidecar() {
    (
        while ! podman container exists "${POD_NAME}-llama" 2>/dev/null; do
            sleep 0.2
        done
        while :; do
            STATE=$(podman inspect --format '{{.State.Status}}' "${POD_NAME}-llama" 2>/dev/null) || return
            if [ "$STATE" != "running" ] && [ "$STATE" != "created" ]; then
                CODE=$(podman inspect --format '{{.State.ExitCode}}' "${POD_NAME}-llama" 2>/dev/null)
                {
                    echo ""
                    echo "Error: llama.cpp sidecar exited (status=${STATE}, exit=${CODE})."
                    echo "--- llama.cpp last 30 log lines ---"
                    podman logs --tail 30 "${POD_NAME}-llama" 2>&1
                    echo "------------------------------------"
                } | awk '{printf "%s\r\n", $0}' >&2
                podman stop -t 0 "${POD_NAME}" >/dev/null 2>&1 || true
                return
            fi
            sleep 1
        done
    ) &
    LOG_PIDS+=($!)
}

create_pod() {
    if [ "${MODE}" = "RESTRICTED" ]; then
        podman pod create --name "${POD_NAME}" --network=none > /dev/null
    else
        podman pod create --name "${POD_NAME}" > /dev/null
    fi
}

start_llama_sidecar() {
    require_model_file
    build_llama_runtime_args
    podman run --pod "${POD_NAME}" -d \
        --name "${POD_NAME}-llama" \
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
        "${LLAMA_GPU_LAYERS[@]}" > /dev/null
    if [ -n "${LOG_DIR}" ]; then
        tail_container_to_file "${POD_NAME}-llama" "${LOG_DIR}/llama_${LOG_TS}.log"
    fi
    watch_llama_sidecar
}

resolve_lm_server_base_url() {
    if [ -z "${LM_HOST:-}" ]; then
        LM_SERVER_BASE_URL="http://127.0.0.1:${LM_PORT}/v1"
        start_llama_sidecar
    else
        LM_SERVER_BASE_URL="http://${LM_HOST}:${LM_PORT}/v1"
    fi
}

build_situ_env() {
    SITU_ENV=(
        -e LM_SERVER_BASE_URL="${LM_SERVER_BASE_URL}"
        -e MODEL="${MODEL}"
        -e LMS_READY_TIMEOUT="${LMS_READY_TIMEOUT}"
        -e MODE="${MODE}"
        -e CTX_SIZE="${CTX_SIZE}"
        -e LM_HOST="${LM_HOST:-}"
        -e SILENT="${SILENT}"
    )
}

run_test_session() {
    local TESTSCRIPT='
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
    start_situ_log_tail
    podman run --rm -it \
        --pod "${POD_NAME}" \
        --name "${POD_NAME}" \
        "${SITU_ENV[@]}" \
        situ:latest \
        bash -c "$TESTSCRIPT"
}

run_query_session() {
    start_situ_log_tail
    podman run --rm \
        --pod "${POD_NAME}" \
        --name "${POD_NAME}" \
        --volume "${MOUNTPOINT}:/workspace" \
        "${SITU_ENV[@]}" \
        situ:latest \
        pi "$QUERY"
}

run_interactive_session() {
    start_situ_log_tail
    podman run --rm -it \
        --pod "${POD_NAME}" \
        --name "${POD_NAME}" \
        --volume "${MOUNTPOINT}:/workspace" \
        "${SITU_ENV[@]}" \
        situ:latest \
        pi
}

main() {
    parse_cli_args "$@"
    load_config_file "${CONFIG_FILE_ARG}" "${SCRIPT_DIR}"
    apply_llama_defaults
    apply_situ_overrides
    validate_situ_config
    prepare_log_dir
    print_banner

    POD_NAME="situ-$$"
    LOG_PIDS=()
    trap cleanup EXIT INT TERM

    create_pod
    resolve_lm_server_base_url
    build_situ_env

    if [ "${RUN_TEST}" = "1" ]; then
        run_test_session
        exit $?
    fi

    if [ -n "${QUERY}" ]; then
        run_query_session
    else
        run_interactive_session
    fi
}

main "$@"
