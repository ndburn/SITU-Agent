#! /bin/bash
set -eo pipefail

echo "Building SITU ..."

cd "$(dirname "$0")/.."

podman build --quiet -t situ:latest -f docker/Dockerfile . > /dev/null

podman image ls | grep situ || true
