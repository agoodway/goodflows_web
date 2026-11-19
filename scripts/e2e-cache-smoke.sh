#!/usr/bin/env bash
# End-to-end smoke test of remote caches (openspec change
# add-remote-cache-storage) against a local GoodFlows Web server and MinIO,
# with curl standing in for the goodflows CLI. Run after .agents/setup:
#
#   scripts/e2e-cache-smoke.sh
#
# By default it starts MinIO (app/scripts/minio.sh, MINIO_PORT default 9100,
# throwaway data) and a Phoenix server (SMOKE_PORT default 4124) configured
# for it, and stops both at the end. To use servers that are already
# running, set SMOKE_URL to the Phoenix URL (its CACHE_S3_* must point at the
# bucket) and leave MinIO to it.
#
# Every request is echoed with tokens shown as $SK / $CK, so the output
# doubles as a protocol walkthrough for the goodflows CLI companion change.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/goodflows-cache-e2e.XXXXXX)
pids=()
failures=0

[[ -f "$HOME/.local/share/goodflows/env" ]] && source "$HOME/.local/share/goodflows/env"

say() { printf '\n== %s\n' "$*"; }
check() { # check NAME COMMAND...
  if "${@:2}" >/dev/null; then echo "PASS  $1"; else echo "FAIL  $1"; failures=$((failures + 1)); fi
}
cleanup() {
  for pid in "${pids[@]}"; do kill -TERM -- "-$pid" 2>/dev/null || true; done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

wait_for() { # wait_for URL LOG
  for _ in $(seq 120); do
    curl -fsS -o /dev/null "$1" 2>/dev/null && return 0
    sleep 1
  done
  echo "$1 did not come up; see $2" >&2
  exit 1
}

if [[ -n ${SMOKE_URL:-} ]]; then
  url=$SMOKE_URL
else
  port=${SMOKE_PORT:-4124}
  url="http://127.0.0.1:$port"
  minio_port=${MINIO_PORT:-9100}
  if curl -s -o /dev/null "$url" || curl -s -o /dev/null "http://127.0.0.1:$minio_port"; then
    echo "port $port or $minio_port is in use; set SMOKE_PORT / MINIO_PORT or SMOKE_URL" >&2
    exit 1
  fi

  say "MinIO on port $minio_port"
  export CACHE_S3_BUCKET=goodflows-cache-smoke CACHE_S3_ENDPOINT="http://127.0.0.1:$minio_port"
  export CACHE_S3_REGION=us-east-1 CACHE_S3_ACCESS_KEY_ID=minioadmin CACHE_S3_SECRET_ACCESS_KEY=minioadmin
  MINIO_PORT=$minio_port MINIO_CONSOLE_PORT=$((minio_port + 1)) MINIO_DATA="$work/minio" \
    setsid "$repo/app/scripts/minio.sh" >"$work/minio.log" 2>&1 &
  pids+=($!)
  wait_for "$CACHE_S3_ENDPOINT/minio/health/live" "$work/minio.log"
  for _ in $(seq 60); do grep -q CACHE_S3_BUCKET "$work/minio.log" && break; sleep 0.5; done

  say "GoodFlows Web on port $port"
  "$repo/.agents/resume"
  (cd "$repo/app" && PORT=$port exec setsid mix phx.server >"$work/server.log" 2>&1) &
  pids+=($!)
  wait_for "$url/users/log-in" "$work/server.log"
fi

say "Private key (seeded user@example.com / Acme Corp) and project"
SK=$(cd "$repo/app" && mix run -e '
  alias GoodFlows.{Accounts, Repo}
  user = Accounts.get_user_by_email("user@example.com")
  account = Repo.get_by!(Accounts.Account, name: "Acme Corp")
  {:ok, {_key, token}} =
    Accounts.create_api_key(Accounts.get_account_user(user, account), %{
      "name" => "e2e-cache-smoke",
      "type" => "private"
    })
  IO.puts("TOKEN=" <> token)
' 2>/dev/null | sed -n 's/^TOKEN=//p')
CK=
project="cache-smoke-$(date +%s)"

# api METHOD PATH TOKEN_VAR [JSON] -> response body in $work/body, status in $status
api() {
  local token=${!3}
  local args=(-sS -o "$work/body" -w '%{http_code}' -X "$1" -H "Authorization: Bearer $token")
  [[ -n ${4:-} ]] && args+=(-H 'content-type: application/json' -d "$4")
  echo "\$ curl -X $1 -H 'Authorization: Bearer \$$3' $url$2${4:+ -d '$4'}"
  status=$(curl "${args[@]}" "$url$2")
  echo "  -> $status $(jq -c . "$work/body" 2>/dev/null | sed -E 's/"ck_[^"]*"/"ck_…"/g' | cut -c1-300)"
}
is() { [[ $status == "$1" ]]; }

api POST /api/v1/projects SK "{\"slug\":\"$project\"}"
check "create project (default_branch main)" jq -e '.data.default_branch == "main"' "$work/body"
caches="/api/v1/projects/$project/caches"

say "Mint a cache key bound to main (read_write, 1 hour)"
api POST "/api/v1/projects/$project/cache-keys" SK \
  '{"access":"read_write","scope":"main","ttl_seconds":3600,"name":"cache smoke"}'
check "mint 201" is 201
CK=$(jq -r .data.token "$work/body")
ck_id=$(jq -r .data.id "$work/body")
check "token starts with ck_" test "${CK:0:3}" = ck_

say "Archive"
mkdir -p "$work/src" && head -c 300000 /dev/urandom >"$work/src/blob" && echo hi >"$work/src/a.txt"
tar -czf "$work/cache.tar.gz" -C "$work/src" .
size=$(stat -c %s "$work/cache.tar.gz")
sha=$(sha256sum "$work/cache.tar.gz" | cut -d' ' -f1)
partial=$(printf 'partial-%s' "$project" | sha256sum | cut -d' ' -f1)
key=$(printf 'key-%s-%s' "$partial" "$sha" | sha256sum | cut -d' ' -f1)
echo "size=$size sha256=$sha partial=$partial key=$key"

say "Reserve in main"
body="{\"name\":\"deps\",\"partial\":\"$partial\",\"scope\":\"main\",\"size\":$size,\"sha256\":\"$sha\"}"
api POST "$caches/entries/$key" CK "$body"
check "reserve 201" is 201
cp "$work/body" "$work/reservation.json"
upload_id=$(jq -r .data.upload_id "$work/reservation.json")
check "upload_headers carry the size" jq -e --arg s "$size" '.data.upload_headers["content-length"] == $s' "$work/reservation.json"

say "A key bound to main cannot write feature/login"
api POST "$caches/entries/$key" CK "${body/\"main\"/\"feature/login\"}"
check "reserve in another scope 403" is 403

say "PUT the archive with exactly upload_headers (no Authorization)"
headers=()
while IFS=$'\t' read -r name value; do headers+=(-H "$name: $value"); done \
  < <(jq -r '.data.upload_headers | to_entries[] | [.key, .value] | @tsv' "$work/reservation.json")
printf '$ curl -X PUT -T cache.tar.gz'
jq -r '.data.upload_headers | to_entries[] | " -H \u0027\(.key): \(.value)\u0027"' "$work/reservation.json" | tr -d '\n'
echo ' "$upload_url"   # no Authorization'
put_status=$(curl -sS -o "$work/put.body" -w '%{http_code}' -X PUT -T "$work/cache.tar.gz" \
  "${headers[@]}" "$(jq -r .data.upload_url "$work/reservation.json")")
echo "  -> $put_status"
check "presigned PUT 200" test "$put_status" = 200

say "Commit"
api POST "$caches/uploads/$upload_id/commit" CK
check "commit 200" is 200
check "commit returns the entry" jq -e --arg sha "$sha" '.data.sha256 == $sha and .data.scope == "main"' "$work/body"
api POST "$caches/uploads/$upload_id/commit" CK
check "retried commit 200" is 200

say "Restore by exact key in main, then download the archive"
api GET "$caches/entries/$key?scope=main" CK
check "exact lookup 200" is 200
# Spec scenario "Download the archive": GET the presigned download_url with
# no Authorization header and compare the bytes' SHA-256 to the reserved
# sha256. mix test covers only the URL's shape (fake store); this is the
# live check against a real object store.
echo "\$ curl -o restored.tar.gz \"\$download_url\"   # no Authorization"
curl -fsS -o "$work/restored.tar.gz" "$(jq -r .data.download_url "$work/body")"
check "downloaded archive matches sha256" test "$(sha256sum "$work/restored.tar.gz" | cut -d' ' -f1)" = "$sha"

say "Restore by partial from a second scope (falls back to main)"
api POST "/api/v1/projects/$project/cache-keys" SK '{"access":"read","scope":"feature/login"}'
CK_FEATURE=$(jq -r .data.token "$work/body")
api GET "$caches/entries?partial=$partial&scope=feature/login" CK_FEATURE
check "partial lookup from feature/login 200" is 200
check "it matched the main entry" jq -e --arg key "$key" '.data.scope == "main" and .data.key == $key' "$work/body"
api GET "$caches/entries/$key?scope=feature/other" CK_FEATURE
check "a bound key reading another branch is 403" is 403

say "List and purge by name (private key)"
api GET "$caches?name=deps" SK
check "list 200 with one entry" jq -e '(.data | length) == 1 and .usage.entries == 1' "$work/body"
api DELETE "$caches/entries?name=deps&scope=main" SK
check "purge 200 deleted 1" jq -e '.data.deleted == 1' "$work/body"
api GET "$caches/entries?partial=$partial&scope=main" CK
check "lookup after purge 404" is 404

say "Revoke the cache key"
api DELETE "/api/v1/projects/$project/cache-keys/$ck_id" SK
check "revoke 204" is 204
api GET "$caches/entries/$key?scope=main" CK
check "revoked key 401" is 401

say "Result"
echo "project $project, workspace $work"
if ((failures)); then
  echo "FAILED: $failures check(s)"
  exit 1
fi
echo "ALL CHECKS PASSED"
