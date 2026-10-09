#!/usr/bin/env bash
set -euo pipefail
source scripts/ci/common.sh
ci_prepare_publish
revision="$(git rev-parse HEAD)"
docker_cmd buildx build --builder "$BUILDER" --platform linux/amd64 \
  --file Dockerfile --tag "$CI_REGISTRY/wg-key-rotator:$revision" \
  --metadata-file artifacts/wg-key-rotator.json --push .
