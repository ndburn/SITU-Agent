#!/bin/bash
set -e

LM_SERVER_BASE_URL="${LM_SERVER_BASE_URL:-http://host.docker.internal:1234/v1}"
MODEL="${MODEL:-}"
LMS_READY_TIMEOUT="${LMS_READY_TIMEOUT:-300}"
CTX_SIZE="${CTX_SIZE:-64000}"
MAX_TOKENS="${MAX_TOKENS:-16384}"
REASONING="${REASONING:-true}"

# Runs in background; caller must kill $SPIN_PID and wait
_spinner() {
    local msg="$1"
    local frames=('.' '..' '...' '..')
    local i=0
    while true; do
        printf "\r\033[K  %s %s" "$msg" "${frames[$((i % 4))]}" >&2
        i=$((i + 1))
        sleep 0.4
    done
}

_spin_start() { [ "${SILENT:-0}" = "1" ] && return; _spinner "$1" & SPIN_PID=$!; }
_spin_stop()  { [ -z "${SPIN_PID:-}" ] && return; kill $SPIN_PID 2>/dev/null; wait $SPIN_PID 2>/dev/null || true; SPIN_PID=; }

lm_ready() { curl -sf "${LM_SERVER_BASE_URL}/models" -o /dev/null 2>/dev/null; }

if ! lm_ready; then
    _spin_start "Starting up"

    elapsed=0
    while ! lm_ready; do
        sleep 1; elapsed=$((elapsed + 1))
        if [ "${elapsed}" -ge "${LMS_READY_TIMEOUT}" ]; then
            _spin_stop
            printf "\r\033[K\n" >&2
            echo "Error: LM server at ${LM_SERVER_BASE_URL} did not become ready within ${LMS_READY_TIMEOUT}s." >&2
            exit 1
        fi
        if [ "${elapsed}" -eq 8 ]; then
            _spin_stop
            _spin_start "Loading model"
        fi
    done

    _spin_stop
    [ "${SILENT:-0}" = "0" ] && printf "\r\033[K  Connected\n" >&2
fi

# Use absolute paths to avoid any $HOME confusion
MODELS_FILE="/root/.pi/agent/models.json"
SETTINGS_FILE="/root/.pi/agent/settings.json"

# Auto-detect model if missing
if [ -z "${MODEL:-}" ]; then
    MODEL=$(curl -sf "${LM_SERVER_BASE_URL}/models" | node -e "
        const d = require('fs').readFileSync('/dev/stdin', 'utf8');
        try {
            const m = JSON.parse(d);
            if (m.data && m.data[0]) process.stdout.write(m.data[0].id);
        } catch(e) {}
    ")
fi

if [ -z "${MODEL:-}" ]; then
    echo "Error: could not determine model." >&2
    exit 1
fi

# Update configuration files via node
node -e "
const fs = require('fs');
try {
    const cfg = JSON.parse(fs.readFileSync('${MODELS_FILE}', 'utf8'));
    cfg.providers['lm-server'].baseUrl = '${LM_SERVER_BASE_URL}';
    cfg.providers['lm-server'].models[0].id = '${MODEL}';
    cfg.providers['lm-server'].models[0].contextWindow = parseInt('${CTX_SIZE}');
    cfg.providers['lm-server'].models[0].maxTokens = parseInt('${MAX_TOKENS}');
    cfg.providers['lm-server'].models[0].reasoning = '${REASONING}' === 'true';
    fs.writeFileSync('${MODELS_FILE}', JSON.stringify(cfg, null, 2));

    const settings = JSON.parse(fs.readFileSync('${SETTINGS_FILE}', 'utf8'));
    settings.defaultModel = '${MODEL}';
    fs.writeFileSync('${SETTINGS_FILE}', JSON.stringify(settings, null, 2));
} catch (e) {
    console.error('Error updating config at ${MODELS_FILE}:', e.message);
    process.exit(1);
}
"

if [ $# -eq 0 ]; then
    exec bash
fi

# In non-interactive mode show spinner while agent thinks
if [ ! -t 1 ]; then
    _spin_start "Working"
    "$@" | (
        if IFS= read -r -N 1 first_char; then
            kill "$SPIN_PID" 2>/dev/null || true
            printf "\r\033[K" >&2
            printf "%s" "$first_char"
            cat
        else
            kill "$SPIN_PID" 2>/dev/null || true
            printf "\r\033[K" >&2
        fi
    )
    CODE=${PIPESTATUS[0]}
    _spin_stop
    exit $CODE
fi

exec "$@"
