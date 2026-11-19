#!/usr/bin/env bash
# Local S3-compatible object storage for remote caches (MinIO), for
# development and scripts/e2e-cache-smoke.sh. Runs in the foreground:
#
#   just minio              # from app/
#   app/scripts/minio.sh    # from anywhere
#
# It creates the bucket and prints the CACHE_S3_* settings to put in
# app/.env.dev.local (or export) before starting the Phoenix server.
#
# MinIO no longer publishes server or client binaries, so the first run
# builds `minio` and `mc` from source with Go (installed under
# ~/.local/share/goodflows/go when `go` is missing) into
# ~/.local/share/goodflows/minio. Set MINIO_BIN_DIR to use other binaries.
#
# MINIO_PORT (default 9000), MINIO_CONSOLE_PORT (9001), MINIO_DATA
# (~/.local/share/goodflows/minio/data), MINIO_ROOT_USER and
# MINIO_ROOT_PASSWORD (minioadmin), and CACHE_S3_BUCKET (goodflows-caches).
set -euo pipefail

home=$HOME/.local/share/goodflows
bin_dir=${MINIO_BIN_DIR:-$home/minio}
minio_ref=RELEASE.2025-10-15T17-29-55Z
go_version=go1.27.4
port=${MINIO_PORT:-9000}
console_port=${MINIO_CONSOLE_PORT:-9001}
data=${MINIO_DATA:-$home/minio/data}
bucket=${CACHE_S3_BUCKET:-goodflows-caches}
export MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
export MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}

build() {
  local go=go
  if ! command -v go >/dev/null; then
    go=$home/go/bin/go
    if [[ ! -x $go ]]; then
      echo "Installing $go_version into $home/go" >&2
      curl -fsSL "https://go.dev/dl/$go_version.linux-amd64.tar.gz" | tar -xz -C "$home"
    fi
  fi
  echo "Building minio $minio_ref and mc into $bin_dir (first run only)" >&2
  mkdir -p "$bin_dir"
  GOBIN=$bin_dir CGO_ENABLED=0 "$go" install "github.com/minio/minio@$minio_ref"
  GOBIN=$bin_dir CGO_ENABLED=0 "$go" install github.com/minio/mc@latest
}

[[ -x $bin_dir/minio && -x $bin_dir/mc ]] || build
mkdir -p "$data"

"$bin_dir/minio" server "$data" --address "127.0.0.1:$port" \
  --console-address "127.0.0.1:$console_port" --quiet &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT INT TERM

for _ in $(seq 60); do
  curl -fsS -o /dev/null "http://127.0.0.1:$port/minio/health/live" 2>/dev/null && break
  sleep 0.5
done

mc_config=$(mktemp -d)
"$bin_dir/mc" --config-dir "$mc_config" alias set local "http://127.0.0.1:$port" \
  "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
"$bin_dir/mc" --config-dir "$mc_config" mb --ignore-existing "local/$bucket" >/dev/null
rm -rf "$mc_config"

cat <<ENV
MinIO is running on http://127.0.0.1:$port (console :$console_port).
Remote cache settings for the Phoenix server:

CACHE_S3_BUCKET=$bucket
CACHE_S3_ENDPOINT=http://127.0.0.1:$port
CACHE_S3_REGION=us-east-1
CACHE_S3_ACCESS_KEY_ID=$MINIO_ROOT_USER
CACHE_S3_SECRET_ACCESS_KEY=$MINIO_ROOT_PASSWORD
ENV

wait "$server"
