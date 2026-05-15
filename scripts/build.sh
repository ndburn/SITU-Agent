#! /bin/bash
set -eo pipefail

QUIET="--quiet"
NPM_LOGLEVEL="error"
REBUILD_FLAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose)
            QUIET=""
            NPM_LOGLEVEL="warn"
            shift ;;
        -r|--rebuild)
            REBUILD_FLAG="--no-cache --pull"
            shift ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1 ;;
    esac
done

echo "Building SITU ..."

cd "$(dirname "$0")/.."

podman build ${QUIET} ${REBUILD_FLAG} --build-arg NPM_LOGLEVEL="${NPM_LOGLEVEL}" -t situ:latest -f docker/Dockerfile .

podman image ls | grep situ || true
