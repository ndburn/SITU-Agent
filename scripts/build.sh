#! /bin/bash

cd "$(dirname "$0")/.."

podman build --quiet -t situ:latest -f docker/Dockerfile .

podman image ls | grep situ
