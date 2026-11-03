#!/usr/bin/env bash
# Worktrees need port overrides so several checkouts can run together.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/branch_db_env.sh
export PORT="$(dev_port)"
exec mix phx.server
