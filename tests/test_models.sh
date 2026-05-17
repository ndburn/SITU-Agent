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
Create a fully playable Player-vs-Computer Chess Game using raw HTML, CSS, and strict TypeScript. No external libraries, frameworks (React, Vue, etc.), or chess-specific engines (chess.js, Stockfish) are allowed.

The application must feature a clean, functional HTML/CSS user interface alongside a high-performance, independent game engine. Your solution will be assessed strictly on its architecture, algorithmic correctness, and the separation of concerns between the visual interface and the underlying logic. Save the game into a single result.html file that can be opened in any modern web browser without a server. The file must include all necessary HTML, CSS, and JavaScript embedded within it. Do not create any other file than result.html.

Implement the following requirements:

1. MONOLITHIC DECOUPLED ENGINE & STATE MUTABILITY
- The core logic must exist as an independent engine, completely decoupled from the DOM. It must track the 8x8 board state, active turns, and piece placement.
- The engine must provide a reliable mechanism to execute a move, evaluate its outcomes, and cleanly roll back that exact move to its identical pre-move state.
- The state mutation and rollback operations must execute fast enough to evaluate hundreds of thousands of hypothetical positions per second during AI calculations without causing memory leaks or call-stack overflows.

2. REACTIVE HTML/CSS USER INTERFACE
- Board Rendering: Build an interactive 8x8 visual grid using HTML and CSS. The board must visually represent the current engine state, rendering pieces using crisp Unicode chess symbols or styled CSS elements.
- Interaction Layer: Implement intuitive click-to-move or drag-and-drop mechanics. When a user clicks a piece, the UI must query the engine for valid moves and visually highlight those target squares on the board.
- State Sync: The UI must be a pure "view" layer. It cannot hold game state. It must reactively re-render or surgically update the DOM only when the underlying engine state changes.
- Status Panel: Display a responsive sidebar or header showing the active turn, captured pieces, a move history log, and prominent alerts for critical game phases (e.g., CHECK, CHECKMATE, STALEMATE, DRAW).

3. EXHAUSTIVE LAW-OF-CHESS LEGALITY FILTERING
- The engine must calculate the complete, exact set of legal moves available to the active player on their turn. Any move attempted via the UI that is not in this set must be rejected, and the piece must snap back.
- King Safety: A player cannot make any move that leaves or places their own King in Check. The engine must verify this by checking if any opponent piece can capture the King on the immediate next sub-ply.
- Special Moves: Correctly validate and visually handle En Passant (revoked if not exploited immediately on the next turn) and Castling (permanently revoked if King/Rook moves; temporarily blocked if paths are occupied or threatened). Ensure pawn promotion forces a UI choice overlay (Queen/Rook/Bishop/Knight) that updates the engine upon selection.

4. AUTOMATIC DRAW DETECTION
- Threefold Repetition: The system must automatically detect when the exact same configuration of pieces, active player turn, castling rights, and en passant eligibility has occurred three times throughout the game, immediately forcing a draw state in the UI.
- Fifty-Move Rule: The engine must automatically terminate the game as a draw if 50 consecutive turns elapse without a pawn movement or a piece capture.

5. AUTONOMOUS COMPUTER OPPONENT (AI BOT)
- The application must feature an automated computer opponent playing as the opposite color of the user.
- Decision Latency & Horizon Management: Upon the player executing a move via the UI, the computer must autonomously calculate its response. The algorithm must look ahead a minimum of 4 consecutive plies deep.
- Tactical Extension & Evaluation: The search must utilize a quiescence search to dynamically extend past the depth limit for unresolved captures. Decisions must mathematically balance material values against positional intellect (e.g., center control, piece development, king safety).
- Non-Blocking Execution: The AI's heavy tree calculations must not freeze the browser's UI thread. Implement asynchronous processing breaks (e.g., Web Workers or scheduled `setTimeout`/`requestAnimationFrame` chunks) so the interface remains responsive during the computer's turn.

6. CODE QUALITY & SYSTEM CONSTRAINTS
- Use strict TypeScript. The use of 'any', 'unknown' bypasses, or structural type-assertions ('as') to circumvent compiler safety checks is prohibited.
- Game states, match phases, and action inputs must be structured using clean discriminated unions and type-safe interfaces.

Store the entire game in a single result.html file. The file must be self-contained, with all HTML, CSS, and JavaScript embedded within it. It should run in any modern web browser without requiring a server. Do not create any other files besides result.html.
EOF
)

# Scoring rubric passed to the grader. Use deduction-based wording so the
# grader is forced to find faults rather than defaulting to 10 or 1.
SCORE_PROMPT=$(cat <<'EOF'
You are a strict technical code reviewer performing static analysis of a single-file HTML chess game submission against the task specification shown above. You cannot run the code — assess correctness, completeness, and quality purely by reading the source. Be critical and precise — reserve 8–10 for genuinely polished, production-quality work; a functional but unremarkable implementation should land around 5–6. Most submissions have logical defects; find them.

Grade by starting at 10 and subtracting for each defect found in the source code:

  CRITICAL (−3 each):
    - Move legality is not filtered: no code verifies that a move leaves the king out of check before accepting it
    - Checkmate and stalemate are never distinguished or detected in the logic
    - The AI has no search tree: it picks moves without any look-ahead (e.g. pure random or greedy single-ply)

  MAJOR (−2 each):
    - The minimax/alpha-beta search depth is hard-coded below 4 plies or the recursion clearly cannot reach 4 plies
    - Quiescence search is absent: the search terminates at the horizon even when captures are pending
    - En passant capture logic is missing or the en passant flag is never revoked after one turn
    - Castling legality is not checked: missing any of — king/rook moved flag, intervening squares occupied, king passing through check
    - Pawn promotion has no promotion-choice UI: it silently auto-promotes or the code path is absent
    - Threefold repetition is not tracked (no position hashing or history comparison logic)
    - Fifty-move rule counter is absent
    - The engine's make/unmake (or equivalent rollback) corrupts state: captured pieces, castling rights, or en passant flags are not restored on unmake
    - The UI reads or writes game state directly instead of querying the engine
    - AI search runs synchronously on the main thread with no Web Worker or chunked async scheduling

  MINOR (−1 each):
    - The evaluation function scores material only, with no positional terms (e.g. piece-square tables, center control, king safety)
    - Legal-move highlighting has no corresponding code wired to click/selection events
    - Status panel is missing code for any of: active turn, captured pieces, move history, check/checkmate/stalemate/draw alerts
    - 'any', 'unknown', or unchecked 'as' type assertions appear in the TypeScript source
    - Game phases or move actions are not modelled with discriminated unions or type-safe interfaces

Clamp the final score to [1, 10]. Respond with ONLY a single integer. No words, no punctuation, no explanation.
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
Usage: test_models.sh [-h|--help] [-i|--iterations N] [-s|--scorer TOOL] [--scorer-model MODEL]

Runs SITU once (or N times) per .gguf in ${MODELS_DIR} with the prompt
embedded in this script. Records wall-clock duration, classifies failures
(OUT MEM / ERROR), then asks a scorer CLI to grade each generated
${EXPECTED_FILE} on a 1-10 scale. Results are written to the run artifact directory.

Options:
  -i, --iterations N      Run each model N times (default: 1)
  -s, --scorer TOOL       Scorer CLI to use: gemini, claude, codex (default: ${SCORER})
      --scorer-model MODEL  Model passed to the scorer (default: ${SCORER_MODEL})

Artifacts are kept under tests/tmp/YYYYMMDD_HHMM/<modelname>[_N]/ for later
inspection (one fresh directory per invocation).
EOF
}

parse_args() {
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
        gemini) (cd "${SCRIPT_DIR}/lib/scorer" && gemini -p "${prompt}" --model "${SCORER_MODEL}") > "${stdout_file}" 2> "${stderr_file}" ;;
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
        printf 'TASK:\n%s\n\n' "${PROMPT}"
        printf 'SUBMITTED FILE (%s):\n' "${EXPECTED_FILE}"
        cat "${generated}"
        printf '\n\n%s\n' "${SCORE_PROMPT}"
    } > "${prompt_file}"

    local rc=0
    invoke_scorer "${prompt_file}" "${stdout_file}" "${stderr_file}" || rc=$?

    local score
    score="$(grep -oE '\b([1-9]|10)\b' "${stdout_file}" | head -n1)"
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
