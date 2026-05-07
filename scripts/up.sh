#!/bin/sh
# Two-phase startup. Use this instead of plain `docker compose up -d`.
#
# Why: docker compose reads env_file once at the start of `up`, before any
# container runs. The EDC services receive their vault token through
# runtime/edc-vault.env, which `vault-init` populates. On a cold start the
# file is empty when compose reads it, so the EDC starts without a token.
#
# This script does it in two passes: first bring vault and vault-init up
# (which writes runtime/edc-vault.env), then bring the rest up so they read
# the now-populated env_file.
#
# Subsequent runs are still safe — vault-init is idempotent.
set -eu

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
    echo ".env not found. Run scripts/setup.sh first." >&2
    exit 1
fi

echo "==> Phase 1: vault + vault-init (refresh token)"
docker compose up -d --wait vault
docker compose run --rm vault-init

echo "==> Phase 2: full stack"
docker compose up -d

echo
echo "Stack is up. Tail logs with:"
echo "  docker compose logs -f controlplane"
