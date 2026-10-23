#!/usr/bin/env bash
# Build dhi-aio-studio locally on Linux.
# Usage: ./build.sh [TAG] [PUSH_TARGET]
#   TAG         defaults to dhi-aio-studio:latest
#   PUSH_TARGET if set, also tag + push there (e.g. gwingz/dhi-aio-studio:0.1)
set -euo pipefail

TAG="${1:-dhi-aio-studio:latest}"
PUSH="${2:-}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

echo "==> Building $TAG"
docker build -t "$TAG" \
  --build-arg CUDA_BASE=nvidia/cuda:13.4.2-cudnn-devel-ubuntu24.04 \
  --build-arg UV_SOURCE=gwingz/dhi-uv:0 \
  --build-arg PY_VERSION=3.12 \
  .

if [ -n "$PUSH" ]; then
  echo "==> Tagging and pushing to $PUSH"
  docker tag "$TAG" "$PUSH"
  docker push "$PUSH"
fi

echo "==> Done. See README.md for the run command (requires \$CF_TUNNEL_TOKEN, \$NOBBBY_PASSWORD, etc.)."
