#! /bin/bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat >&2 <<EOF
Usage: llamaservice.sh [options] [-- <llama.cpp args>...]

Options:
  -c, --config <file>           Use a specific config file (default: situ.conf).
  -h, --help                    Show this help message and exit.
      --llama-config <file>     Inject a llama.cpp JSON config file into the server.
  -l, --log <directory>         Write logs to <directory>/llama_<ts>.log.
  -q, --quiet                   Suppress status messages (useful when piping output).
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

parse_cli_args() {
    SILENT=0
    CONFIG_FILE_ARG=""
    LLAMA_CONFIG_FILE=""
    LOG_DIR=""
    LLAMA_PASSTHROUGH=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                [ $# -ge 2 ] || die "--config requires an argument"
                CONFIG_FILE_ARG="$2"; shift 2 ;;
            -q|--quiet)
                SILENT=1; shift ;;
            --llama-config)
                [ $# -ge 2 ] || die "--llama-config requires an argument"
                LLAMA_CONFIG_FILE="$2"; shift 2 ;;
            -l|--log)
                [ $# -ge 2 ] || die "--log requires an argument"
                LOG_DIR="$2"; shift 2 ;;
            -h|--help)
                usage; exit 0 ;;
            --)
                shift
                LLAMA_PASSTHROUGH=("$@")
                break ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                exit 1 ;;
        esac
    done
}

print_banner() {
    [ "${SILENT}" = "1" ] && return 0
    echo "llama.sh v${VERSION}"
    echo ""
    echo "Config    : ${CONFIG_FILE}"
    echo "Image     : ${LLAMA_IMAGE}"
    echo "Model     : ${MODEL}"
    echo "Ctx size  : ${CTX_SIZE}"
    echo "Port      : ${LM_PORT} (published on 0.0.0.0)"
    [ -n "${LOG_DIR}" ] && echo "Logs      : ${LOG_DIR}"
    echo ""
}

cleanup() {
    kill_tracked_pids
    ${CE} rm -f "${CONTAINER_NAME}" > /dev/null 2>&1 || true
}

start_llama_container() {
    ${CE} run -d \
        --name "${CONTAINER_NAME}" \
        --user "$(id -u):$(id -g)" \
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
        --jinja \
        --parallel "${PARALLEL}" \
        "${LLAMA_GPU_LAYERS[@]}" \
        "${LLAMA_PASSTHROUGH[@]}" > /dev/null
    if [ -n "${LOG_DIR}" ]; then
        tail_container_to_file "${CONTAINER_NAME}" "${LOG_DIR}/llama_${LOG_TS}.log"
    fi
}

follow_or_wait() {
    if [ "${SILENT}" = "1" ]; then
        ${CE} wait "${CONTAINER_NAME}" > /dev/null
    else
        ${CE} logs -f "${CONTAINER_NAME}"
    fi
}

main() {
    parse_cli_args "$@"
    load_config_file "${CONFIG_FILE_ARG}" "${SCRIPT_DIR}"
    apply_llama_defaults
    require_model_file
    prepare_log_dir
    build_llama_runtime_args
    print_banner

    CONTAINER_NAME=$(generate_unique_name "llama")
    LOG_PIDS=()
    trap cleanup EXIT INT TERM

    reset_stale_resources "${CONTAINER_NAME}"
    start_llama_container
    follow_or_wait
}

main "$@"
