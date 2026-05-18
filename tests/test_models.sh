#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=../scripts/lib/common.sh
source "${SITU_REPO_ROOT}/scripts/lib/common.sh"

# Benchmark prompt. Swap freely; must instruct the agent to write the
# artifact to a file literally named "result.html" - that filename is the
# contract this script relies on for scoring.
PROMPT=$(cat <<'EOF'
Create a fully playable, self-contained Player-vs-Computer Connect Four game embedded entirely within a single, serverless result.html file using raw HTML, CSS, and JavaScript without external libraries or frameworks. The application must track a 7-column by 6-row grid, manage player turns, and automatically detect wins across all horizontal, vertical, and diagonal lines of four, as well as draws when the board is full. Every piece — whether placed by the player or the computer — must land in the lowest unfilled row of the chosen column. The user interface must render the grid as a clean styled board where pieces appear in the correct position, highlight the winning four pieces when the game ends, and show the current game status. The computer opponent must look ahead using a minimax search to select its move; the UI must remain responsive and reflect the player's move before the computer responds.
EOF
)

# Scoring rubric passed to the grader. Use deduction-based wording so the
# grader is forced to find faults rather than defaulting to 10 or 1.
SCORE_PROMPT=$(cat <<'EOF'
You are a strict reviewer performing static analysis of a single-file web application submission containing HTML, CSS, and JavaScript. Judge only against the criteria below — ignore code length, verbosity, and any stylistic preferences not listed in the rubric.

For each criterion, note whether the defect is present in the source. Then subtract the listed points and compute the final score starting from 10.

CRITICAL - Subtract 3 points each:
- Win detection is missing or fails to check all directions (horizontal, vertical, and both diagonals).
- The computer opponent has no look-ahead and plays randomly or greedily without minimax search.

MAJOR - Subtract 2 points each:
- Pieces do not drop to the lowest available row in the selected column.
- The UI does not highlight the winning four pieces when the game ends.
- AI calculations run synchronously on the main thread without asynchronous scheduling.

MINOR - Subtract 1 point each:
- var is used instead of let or const.
- Loose equality (== or !=) is used instead of strict equality (=== or !==).
- Variables or functions are declared in global scope instead of being encapsulated in a module or function scope.

Clamp the final score between 1 and 10. Provide the final score integer on the very first line, followed by a concise summary of the defects found on the remaining lines.
EOF
)

EXPECTED_FILE="result.html"
MODELS_DIR="${HOME}/.situ/models"
SCORER="gemini"
SCORER_MODEL="gemini-2.5-flash-lite"

# Per-invocation working directory: tests/tmp/YYYYMMDD_HHMM/. Holds every
# artifact this run produces (per-model result.html, gemini score prompts
# and outputs) so successive runs don't clobber each other.
RUN_ID="$(date +%Y%m%d_%H%M)"
RUN_DIR="${SITU_TMP_DIR}/${RUN_ID}"

MODELS=()
RESULT_DURATION=()
RESULT_STATUS=()
RESULT_SCORE=()

ITERATIONS=1

W_DATE=11
W_VER=7
W_CFG=0
W_DUR=8
W_SCORE=10
CUDA_SUFFIX=""

usage() {
    cat <<EOF
Usage: test_models.sh [-h|--help] [-i|--iterations N] [-m|--model GGUF] [-s|--scorer TOOL] [--scorer-model MODEL]

Runs SITU once (or N times) per .gguf in ${MODELS_DIR} with the prompt
embedded in this script. Records wall-clock duration, classifies failures
(OUT MEM / ERROR), then asks a scorer CLI to grade each generated
${EXPECTED_FILE} on a 1-10 scale. Results are written to the run artifact directory.

Options:
  -i, --iterations N      Run each model N times (default: 1)
  -m, --model GGUF        Run only this model (filename, with or without .gguf extension)
  -s, --scorer TOOL       Scorer CLI to use: gemini, claude, codex (default: ${SCORER})
      --scorer-model MODEL  Model passed to the scorer (default: ${SCORER_MODEL})

Artifacts are kept under tests/tmp/YYYYMMDD_HHMM/<modelname>[_N]/ for later
inspection (one fresh directory per invocation).
EOF
}

parse_args() {
    MODEL_FILTER=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -i|--iterations)
                shift
                if [[ $# -eq 0 || ! "$1" =~ ^[1-9][0-9]*$ ]]; then
                    echo "Error: --iterations requires a positive integer" >&2
                    usage; exit 1
                fi
                ITERATIONS="$1"
                ;;
            -m|--model)
                shift
                if [[ $# -eq 0 ]]; then
                    echo "Error: --model requires a filename" >&2
                    usage; exit 1
                fi
                MODEL_FILTER="${1%.gguf}.gguf"
                ;;
            -s|--scorer)
                shift
                if [[ $# -eq 0 ]]; then
                    echo "Error: --scorer requires a tool name (gemini, claude, codex)" >&2
                    usage; exit 1
                fi
                SCORER="$1"
                ;;
            --scorer-model)
                shift
                if [[ $# -eq 0 ]]; then
                    echo "Error: --scorer-model requires a model name" >&2
                    usage; exit 1
                fi
                SCORER_MODEL="$1"
                ;;
            *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
        esac
        shift
    done
}

discover_models() {
    shopt -s nullglob
    if [ -n "${MODEL_FILTER}" ]; then
        MODELS=( "${MODELS_DIR}/${MODEL_FILTER}" )
        [ -f "${MODELS[0]}" ] || { echo "Model not found: ${MODELS_DIR}/${MODEL_FILTER}" >&2; exit 1; }
    else
        MODELS=( "${MODELS_DIR}"/*.gguf )
        if [ ${#MODELS[@]} -eq 0 ]; then
            echo "No .gguf models found in ${MODELS_DIR}" >&2
            exit 1
        fi
    fi
}

# Reads LLAMA_IMAGE from situ.conf (if set) and echoes ", llama.cpp CUDA"
# when the image is a CUDA build, else empty.
detect_cuda_suffix() {
    local conf="${SITU_REPO_ROOT}/situ.conf"
    local image=""
    if [ -f "${conf}" ]; then
        # shellcheck disable=SC1090
        image="$(LLAMA_IMAGE=""; source "${conf}"; printf '%s' "${LLAMA_IMAGE:-}")"
    fi
    if [[ "${image}" == *cuda* ]]; then
        printf ', llama.cpp CUDA'
    fi
}

format_duration() {
    local s="$1"
    printf '%02dm %02ds' $((s / 60)) $((s % 60))
}

# Classifies a (rc, output, file_present) triple into OK / OOM / ERROR.
# Echoes the classification on stdout.
classify_outcome() {
    local rc="$1" output="$2" file_present="$3"
    if [ "${rc}" -eq 0 ] && [ "${file_present}" = "1" ]; then
        echo "OK"; return
    fi
    if printf '%s' "${output}" | grep -qiE 'out of memory|oomkilled|cuda error|failed to allocate|sidecar exited|\bkilled\b'; then
        echo "OOM"; return
    fi
    echo "ERROR"
}

init_column_widths() {
    CUDA_SUFFIX="$(detect_cuda_suffix)"
    W_CFG=13
    local m
    for m in "${MODELS[@]}"; do
        local cfg
        cfg="$(basename "${m}")${CUDA_SUFFIX}"
        (( ${#cfg} > W_CFG )) && W_CFG=${#cfg}
    done
    # Score column: up to "10" per iteration with comma separators = 3N-1 chars
    local score_width=$(( 3 * ITERATIONS - 1 ))
    (( score_width > W_SCORE )) && W_SCORE=${score_width}
}

print_table_header() {
    local sd sv sc sdu ss
    sd="$(printf '%.0s-' $(seq 1 $W_DATE))"
    sv="$(printf '%.0s-' $(seq 1 $W_VER))"
    sc="$(printf '%.0s-' $(seq 1 $W_CFG))"
    sdu="$(printf '%.0s-' $(seq 1 $W_DUR))"
    ss="$(printf '%.0s-' $(seq 1 $W_SCORE))"
    printf "| %-${W_DATE}s | %-${W_VER}s | %-${W_CFG}s | %-${W_DUR}s | %-${W_SCORE}s |\n" \
        "Date" "Version" "Configuration" "Duration" "Assessment"
    printf "|-%s-|-%s-|-%s-|-%s-|-%s-|\n" "${sd}" "${sv}" "${sc}" "${sdu}" "${ss}"
}

# Creates mount and log dirs for one iteration; removes any stale artifact.
# Writes to caller's locals: mount, log_dir
prepare_iter_dirs() {
    local stem="$1" iter="$2"
    mount="${RUN_DIR}/${stem}"
    log_dir="${RUN_DIR}/logs/${stem}"
    if (( ITERATIONS > 1 )); then
        mount="${mount}/${iter}"
        log_dir="${log_dir}/${iter}"
    fi
    mkdir -p "${mount}" "${log_dir}"
    rm -f "${mount}/${EXPECTED_FILE}"
}

# Invokes run_situ and records timing.
# Writes to caller's locals: output, rc, stderr_output, dur_secs, dur_str
run_situ_timed() {
    local gguf="$1"
    local start=${SECONDS}
    local stderr_file
    stderr_file="$(mktemp)"
    set +e
    output="$(run_situ -q --model "${gguf}" --mountpoint "${mount}" -l "${log_dir}" -p "${PROMPT}" 2>"${stderr_file}")"
    rc=$?
    stderr_output="$(cat "${stderr_file}")"
    rm -f "${stderr_file}"
    set -e 2>/dev/null || true
    dur_secs=$(( SECONDS - start ))
    dur_str="$(format_duration "${dur_secs}")"
}

# Removes an empty mount dir (and its empty parent) after an OOM failure.
# Reads caller's local: mount
cleanup_empty_mount() {
    local stem="$1"
    if [ -d "${mount}" ] && [ -z "$(find "${mount}" -mindepth 1 -type f 2>/dev/null | head -n 1)" ]; then
        rm -rf "${mount}"
        local model_dir="${RUN_DIR}/${stem}"
        if [ "${mount}" != "${model_dir}" ] && [ -d "${model_dir}" ] && \
           [ -z "$(find "${model_dir}" -mindepth 1 2>/dev/null | head -n 1)" ]; then
            rm -rf "${model_dir}"
        fi
    fi
}

run_one_model() {
    local gguf_path="$1"
    local gguf
    gguf="$(basename "${gguf_path}")"
    local stem="${gguf%.gguf}"
    local date_str
    date_str="$(date +%Y-%m-%d)"

    local ok_dur_total=0 ok_dur_count=0 worst_status="OK"
    local all_scores=() last_error_output=""
    local mount log_dir output rc stderr_output dur_secs dur_str

    for (( iter=1; iter<=ITERATIONS; iter++ )); do
        local iter_label=""
        (( ITERATIONS > 1 )) && iter_label=" ${iter}/${ITERATIONS}"

        prepare_iter_dirs "${stem}" "${iter}"

        printf "${BLUE}| %-${W_DATE}s | %-${W_VER}s | %-${W_CFG}s | %-${W_DUR}s | %-${W_SCORE}s |${NC}\r" \
            "[RUNNING]" "" "${gguf}${CUDA_SUFFIX}" "${iter_label# }" ""

        run_situ_timed "${gguf}"

        local file_present=0
        [ -f "${mount}/${EXPECTED_FILE}" ] && file_present=1
        local outcome
        outcome="$(classify_outcome "${rc}" "${stderr_output}" "${file_present}")"

        case "${outcome}" in
            OK)
                ok_dur_total=$(( ok_dur_total + dur_secs ))
                ok_dur_count=$(( ok_dur_count + 1 ))
                printf "${BLUE}| %-${W_DATE}s | %-${W_VER}s | %-${W_CFG}s | %-${W_DUR}s | %-${W_SCORE}s |${NC}\r" \
                    "[SCORE${iter_label}]" "" "${gguf}${CUDA_SUFFIX}" "${dur_str}" ""
                all_scores+=("$(score_one "${mount}" "${gguf}")")
                ;;
            OOM)
                [ "${worst_status}" != "OOM" ] && worst_status="OOM"
                all_scores+=("-")
                cleanup_empty_mount "${stem}"
                break
                ;;
            ERROR)
                [ "${worst_status}" = "OK" ] && worst_status="ERROR"
                all_scores+=("-")
                last_error_output="${stderr_output}"
                ;;
        esac
    done

    local mean_dur_str
    if (( ok_dur_count > 0 )); then
        mean_dur_str="$(format_duration $(( ok_dur_total / ok_dur_count )))"
    elif [ "${worst_status}" = "OOM" ]; then
        mean_dur_str="OUT MEM"
    else
        mean_dur_str="ERROR"
    fi

    local scores_str
    local IFS=','
    scores_str="${all_scores[*]}"

    local color="${GREEN}"
    [ "${worst_status}" != "OK" ] && color="${RED}"

    printf "${CLR}${color}| %-${W_DATE}s | %-${W_VER}s | %-${W_CFG}s | %-${W_DUR}s | %-${W_SCORE}s |${NC}\n" \
        "${date_str}" "v${VERSION}" "${gguf}${CUDA_SUFFIX}" "${mean_dur_str}" "${scores_str}"

    [ -n "${last_error_output}" ] && printf '%s\n' "${last_error_output}" | tail -n 20 >&2

    RESULT_DURATION+=("${mean_dur_str}")
    RESULT_STATUS+=("${worst_status}")
    RESULT_SCORE+=("${scores_str}")
}

# Invokes the configured scorer CLI with a prompt file.
# stdout → stdout_file (the model's response, used for score extraction)
# stderr → stderr_file (warnings, retries, diagnostics)
# Returns the scorer's exit code. Flags differ per tool:
#   gemini: -p PROMPT --model MODEL
#   claude: -p PROMPT --model MODEL --bare
#   codex:  exec PROMPT --model MODEL
invoke_scorer() {
    local prompt_file="$1" stdout_file="$2" stderr_file="$3"
    local prompt
    prompt="$(cat "${prompt_file}")"
    case "${SCORER}" in
        gemini) (cd "${SCRIPT_DIR}/lib/scorer" && gemini -p "${prompt}" --model "${SCORER_MODEL}" --output-format text) > "${stdout_file}" 2> "${stderr_file}" ;;
        claude) claude -p "${prompt}" --model "${SCORER_MODEL}" --bare > "${stdout_file}" 2> "${stderr_file}" ;;
        codex)  codex exec --model "${SCORER_MODEL}" "${prompt}" > "${stdout_file}" 2> "${stderr_file}" ;;
        *)      echo "Unknown scorer: ${SCORER}. Use gemini, claude, or codex." >&2; return 1 ;;
    esac
}

# Calls the scorer to grade one model's artifact. Echoes a 1-10 integer, or
# "?" if scoring failed or returned something unparseable.
# score_output.txt  ← scorer stdout (the response used for score extraction)
# score_stderr.txt  ← scorer stderr (warnings, retries, diagnostics)
score_one() {
    local mount="$1"
    local gguf="$2"
    local generated="${mount}/${EXPECTED_FILE}"
    local prompt_file="${mount}/score_prompt.txt"
    local stdout_file="${mount}/score_output.txt"
    local stderr_file="${mount}/score_stderr.txt"

    if [ ! -f "${generated}" ]; then
        echo "?"; return
    fi

    {
        printf 'SUBMITTED FILE (%s):\n' "${EXPECTED_FILE}"
        cat "${generated}"
        printf '\n\n%s\n' "${SCORE_PROMPT}"
    } > "${prompt_file}"

    local rc=0
    invoke_scorer "${prompt_file}" "${stdout_file}" "${stderr_file}" || rc=$?

    local score
    score="$(head -n1 "${stdout_file}" | grep -oE '\b([1-9]|10)\b')"
    if [ -z "${score}" ]; then
        echo "Scorer (${SCORER}) failed for ${gguf} (rc=${rc}). stdout:" >&2
        head -n 20 "${stdout_file}" >&2
        echo "stderr:" >&2
        head -n 20 "${stderr_file}" >&2
        echo "?"
    else
        echo "${score}"
    fi
}


write_results() {
    local date_str
    date_str="$(date +%Y-%m-%d)"

    local sd sv sc sdu ss
    sd="$(printf '%.0s-' $(seq 1 $W_DATE))"
    sv="$(printf '%.0s-' $(seq 1 $W_VER))"
    sc="$(printf '%.0s-' $(seq 1 $W_CFG))"
    sdu="$(printf '%.0s-' $(seq 1 $W_DUR))"
    ss="$(printf '%.0s-' $(seq 1 $W_SCORE))"

    {
        printf "| %-${W_DATE}s | %-${W_VER}s | %-${W_CFG}s | %-${W_DUR}s | %-${W_SCORE}s |\n" \
            "Date" "Version" "Configuration" "Duration" "Assessment"
        printf "|-%s-|-%s-|-%s-|-%s-|-%s-|\n" "${sd}" "${sv}" "${sc}" "${sdu}" "${ss}"
        for i in "${!MODELS[@]}"; do
            local gguf
            gguf="$(basename "${MODELS[$i]}")"
            printf "| %-${W_DATE}s | %-${W_VER}s | %-${W_CFG}s | %-${W_DUR}s | %-${W_SCORE}s |\n" \
                "${date_str}" "v${VERSION}" "${gguf}${CUDA_SUFFIX}" \
                "${RESULT_DURATION[$i]}" "${RESULT_SCORE[$i]}"
        done
    } > "${RUN_DIR}/benchmark_results.md"
}

summary() {
    echo ""
    echo "------------------------------------"
    local total=${#MODELS[@]}
    local ok=0 oom=0 err=0
    local i
    for i in "${!RESULT_STATUS[@]}"; do
        case "${RESULT_STATUS[$i]}" in
            OK)    ok=$((ok + 1)) ;;
            OOM)   oom=$((oom + 1)) ;;
            ERROR) err=$((err + 1)) ;;
        esac
    done
    printf "${GREEN}OK${NC}: %d   ${RED}OOM${NC}: %d   ${RED}ERROR${NC}: %d   (total: %d)\n" \
        "${ok}" "${oom}" "${err}" "${total}"
    echo "Results written to: ${RUN_DIR}/benchmark_results.md"
}

main() {
    parse_args "$@"
    discover_models
    mkdir -p "${RUN_DIR}"
    cp "${SITU_REPO_ROOT}/situ.conf" "${RUN_DIR}/situ.conf"
    echo "Run artifacts: ${RUN_DIR}"

    init_column_widths
    print_table_header

    local m
    for m in "${MODELS[@]}"; do
        run_one_model "${m}"
    done

    write_results
    summary
}

main "$@"
