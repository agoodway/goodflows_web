#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/branch_db_env.sh
port=$(dev_port)
printf '%s\n' "$port"
