#!/usr/bin/env bash
set -euo pipefail
source scripts/ci/common.sh
ci_install_cleanup
tar -cf - . | ci_run test-1 --rm -i -w /workspace elixir:1.17-slim \
  sh -c 'tar --no-same-owner -xf - && mix local.hex --force && mix deps.get && mix test'
