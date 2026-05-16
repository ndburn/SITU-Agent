#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=../scripts/lib/common.sh
source "${SITU_REPO_ROOT}/scripts/lib/common.sh"

# Benchmark prompt. Swap freely; must instruct the agent to write the
# artifact to a file literally named "result.html" - that filename is the
# contract this script relies on for scoring.
PROMPT='Create a single, production-ready file containing all HTML, CSS, and JavaScript; this file must implement a polished, full-screen Tic-Tac-Toe game featuring a Human (X) vs. Computer (O) mode with the human starting, automated computer logic, win/draw detection across all axes, and a post-game result display with a Restart-Button. Do not output anything, just store the HTML file locally into a file called result.html.'

# Scoring rubric passed to the grader. Use deduction-based wording so the
# grader is forced to find faults rather than defaulting to 10 or 1.
SCORE_PROMPT='You are a strict technical reviewer grading an HTML game submission. Be critical and precise - reserve 8–10 for genuinely polished, production-quality work; a functional but unremarkable implementation should land around 5–6. Most submissions have defects; find them.

Grade by starting at 10 and subtracting for each defect:
  CRITICAL (−3 each): page is blank or crashes on load; computer never makes a move; win/draw detection is absent or always wrong
  MAJOR (−2 each): computer AI is pure random with no strategy (e.g. no attempt to block or win); win check silently misses one or more of the 8 lines (3 rows, 3 columns, 2 diagonals); game continues accepting moves after a win or draw; Restart button is missing or does not reset state correctly
  MINOR (−1 each): layout is not full-screen as specified; X and O are visually indistinct; no indication of whose turn it is; dead or unreachable code blocks; non-semantic HTML structure (e.g. divs for everything with no semantic tags)

Clamp the final score to [1, 10]. Respond with ONLY a single integer. No words, no punctuation, no explanation.'

EXPECTED_FILE="result.html"
MODELS_DIR="${HOME}/.situ/models"
RESULTS_FILE="${SITU_TESTS_DIR}/benchmark_results.md"

# Per-invocation working directory: tests/tmp/YYYYMMDD_HHMM/. Holds every
# artifact this run produces (per-model result.html, gemini score prompts
# and outputs) so successive runs don't clobber each other.
RUN_ID="$(date +%Y%m%d_%H%M)"
RUN_DIR="${SITU_TMP_DIR}/${RUN_ID}"

MODELS=()
RESULT_DURATION=()
RESULT_STATUS=()
RESULT_SCORE=()

W_DATE=10
W_VER=7
W_CFG=0
W_DUR=8
W_SCORE=10
CUDA_SUFFIX=""

usage() {
    cat <<EOF
Usage: test_models.sh [-h|--help]

Runs SITU once per .gguf in ${MODELS_DIR} with the prompt embedded in this
script. Records wall-clock duration, classifies failures (OUT MEM / ERROR),
then asks 'gemini -p' to score each generated ${EXPECTED_FILE} on a 1-10
scale. Results are appended to ${RESULTS_FILE}.

Artifacts are kept under tests/tmp/YYYYMMDD_HHMM/<modelname>/ for later
inspection (one fresh directory per invocation).
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
        esac
    done
}

discover_models() {
    shopt -s nullglob
    MODELS=( "${MODELS_DIR}"/*.gguf )
    if [ ${#MODELS[@]} -eq 0 ]; then
        echo "No .gguf models found in ${MODELS_DIR}" >&2
        exit 1
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

run_one_model() {
    local gguf_path="$1"
    local gguf
    gguf="$(basename "${gguf_path}")"
    local stem="${gguf%.gguf}"
    local mount="${RUN_DIR}/${stem}"
    mkdir -p "${mount}"
    rm -f "${mount}/${EXPECTED_FILE}"

    printf "${BLUE}| %-${W_DATE}s | %-${W_VER}s | %-${W_CFG}s | %-${W_DUR}s | %-${W_SCORE}s |${NC}\r" \
        "[RUNNING]" "" "${gguf}${CUDA_SUFFIX}" "" ""

    local start=${SECONDS}
    local output rc
    set +e
    output="$(run_situ -q --model "${gguf}" --mountpoint "${mount}" -p "${PROMPT}" 2>&1)"
    rc=$?
    set -e 2>/dev/null || true
    local dur_str
    dur_str="$(format_duration $((SECONDS - start)))"

    local file_present=0
    [ -f "${mount}/${EXPECTED_FILE}" ] && file_present=1

    local outcome
    outcome="$(classify_outcome "${rc}" "${output}" "${file_present}")"

    local date_str
    date_str="$(date +%Y-%m-%d)"
    case "${outcome}" in
        OK)
            RESULT_DURATION+=("${dur_str}")
            RESULT_STATUS+=("OK")
            printf "${BLUE}| %-${W_DATE}s | %-${W_VER}s | %-${W_CFG}s | %-${W_DUR}s | %-${W_SCORE}s |${NC}\r" \
                "[SCORING]" "" "${gguf}${CUDA_SUFFIX}" "${dur_str}" ""
            local s
            s="$(score_one "${gguf_path}")"
            RESULT_SCORE+=("${s}")
            printf "${CLR}${GREEN}| %-${W_DATE}s | %-${W_VER}s | %-${W_CFG}s | %-${W_DUR}s | %-${W_SCORE}s |${NC}\n" \
                "${date_str}" "v${VERSION}" "${gguf}${CUDA_SUFFIX}" "${dur_str}" "${s}"
            ;;
        OOM)
            RESULT_DURATION+=("OUT MEM")
            RESULT_STATUS+=("OOM")
            RESULT_SCORE+=("-")
            printf "${CLR}${RED}| %-${W_DATE}s | %-${W_VER}s | %-${W_CFG}s | %-${W_DUR}s | %-${W_SCORE}s |${NC}\n" \
                "${date_str}" "v${VERSION}" "${gguf}${CUDA_SUFFIX}" "OUT MEM" "-"
            ;;
        ERROR)
            RESULT_DURATION+=("ERROR")
            RESULT_STATUS+=("ERROR")
            RESULT_SCORE+=("-")
            printf "${CLR}${RED}| %-${W_DATE}s | %-${W_VER}s | %-${W_CFG}s | %-${W_DUR}s | %-${W_SCORE}s |${NC}\n" \
                "${date_str}" "v${VERSION}" "${gguf}${CUDA_SUFFIX}" "ERROR" "-"
            printf '%s\n' "${output}" | tail -n 20 >&2
            ;;
    esac
}

# Calls gemini to grade one model's artifact. Echoes a 1-10 integer, or
# "?" if gemini failed or returned something unparseable. Raw gemini
# output (stdout+stderr) is always written to <mount>/score_output.txt
# for later inspection.
score_one() {
    local gguf_path="$1"
    local gguf
    gguf="$(basename "${gguf_path}")"
    local stem="${gguf%.gguf}"
    local mount="${RUN_DIR}/${stem}"
    local generated="${mount}/${EXPECTED_FILE}"
    local prompt_file="${mount}/score_prompt.txt"
    local output_file="${mount}/score_output.txt"

    if [ ! -f "${generated}" ]; then
        echo "?"; return
    fi

    {
        printf 'TASK:\n%s\n\n' "${PROMPT}"
        printf 'SUBMITTED FILE (%s):\n' "${EXPECTED_FILE}"
        cat "${generated}"
        printf '\n\n%s\n' "${SCORE_PROMPT}"
    } > "${prompt_file}"

    local rc=0
    gemini -p "$(cat "${prompt_file}")" > "${output_file}" 2>&1 || rc=$?

    local score
    score="$(grep -oE '\b([1-9]|10)\b' "${output_file}" | head -n1)"
    if [ -z "${score}" ]; then
        echo "gemini scoring failed for ${gguf} (rc=${rc}). First 20 lines of ${output_file}:" >&2
        head -n 20 "${output_file}" >&2
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
    } | tee "${RUN_DIR}/benchmark_results.md" > "${RESULTS_FILE}"
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
    echo "Results written to: ${RESULTS_FILE}"
}

main() {
    parse_args "$@"
    discover_models
    mkdir -p "${RUN_DIR}"
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
