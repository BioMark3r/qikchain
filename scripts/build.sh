#!/usr/bin/env bash
set -euo pipefail

docker run --rm \
  -v "$PWD:/src" \
  -w /src \
  golang:1.20.14-bookworm \
  bash -lc '
    set -euo pipefail
    export PATH="/usr/local/go/bin:$PATH"
    go version
    apt-get update
    apt-get install -y --no-install-recommends git make ca-certificates
    make clean
    make all
  '
