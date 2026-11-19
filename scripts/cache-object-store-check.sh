#!/usr/bin/env bash
# Checks that an S3-compatible bucket enforces what remote caches rely on
# (openspec change add-remote-cache-storage, task 6.2), through the app's own
# GoodFlows.Caches.ObjectStore.S3 presigner:
#
#   1. a 5,000,000,000-byte PUT through a presigned URL succeeds,
#   2. HEAD with checksum mode returns x-amz-checksum-sha256 (and the size),
#   3. a PUT whose body differs from the signed checksum is rejected,
#   4. a PUT without the signed headers is rejected,
#   5. DELETE removes the objects.
#
# Point CACHE_S3_* at the bucket (MinIO: see `just minio` in app/; R2:
# endpoint https://<account>.r2.cloudflarestorage.com, region auto) and run:
#
#   scripts/cache-object-store-check.sh
#
# CHECK_LARGE_BYTES (default 5000000000) sets the large PUT's size. The
# archive is a sparse file of zeros under a temporary directory.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
large_bytes=${CHECK_LARGE_BYTES:-5000000000}
work=$(mktemp -d /tmp/goodflows-store-check.XXXXXX)
trap 'rm -rf "$work"' EXIT
failures=0

[[ -f "$HOME/.local/share/goodflows/env" ]] && source "$HOME/.local/share/goodflows/env"
: "${CACHE_S3_BUCKET:?set CACHE_S3_BUCKET and the other CACHE_S3_* variables}"

say() { printf '\n== %s\n' "$*"; }
check() { # check NAME EXPECTED ACTUAL
  if [[ $2 == "$3" ]]; then echo "PASS  $1 ($3)"; else echo "FAIL  $1: expected $2, got $3"; failures=$((failures + 1)); fi
}

# Runs one ObjectStore.S3 call in the dev app config: presign_put KEY SIZE SHA,
# head KEY, or delete KEY. Prints one line of JSON.
store() {
  (cd "$repo/app" && MIX_ENV=dev mix run --no-start -e '
    {:ok, _} = Application.ensure_all_started(:req)
    alias GoodFlows.Caches.ObjectStore.S3

    result =
      case System.argv() do
        ["presign_put", key, size, sha] ->
          {url, headers} =
            S3.presign_put(key, %{size: String.to_integer(size), sha256: sha, expires_in: 900})

          %{url: url, headers: headers}

        ["head", key] ->
          case S3.head(key) do
            {:ok, info} -> info
            {:error, reason} -> %{error: inspect(reason)}
          end

        ["delete", key] ->
          %{result: inspect(S3.delete(key))}
      end

    IO.puts(Jason.encode!(result))
  ' -- "$@" | tail -1)
}

# put NAME FILE PRESIGN_JSON [SKIP_HEADERS] -> prints the HTTP status
put() {
  local url args=()
  url=$(jq -r .url <<<"$3")
  if [[ ${4:-} != skip-headers ]]; then
    while IFS=$'\t' read -r name value; do args+=(-H "$name: $value"); done \
      < <(jq -r '.headers | to_entries[] | [.key, .value] | @tsv' <<<"$3")
  fi
  curl -sS -o "$work/$1.body" -w '%{http_code}' -X PUT -T "$2" "${args[@]}" "$url"
}

prefix="store-check/$(date -u +%Y%m%dT%H%M%SZ)-$$"
echo "bucket=$CACHE_S3_BUCKET endpoint=${CACHE_S3_ENDPOINT:-<AWS S3>} region=${CACHE_S3_REGION:-us-east-1} prefix=$prefix"

say "1. $large_bytes-byte PUT through a presigned URL"
truncate -s "$large_bytes" "$work/large"
large_sha=$(sha256sum "$work/large" | cut -d' ' -f1)
presigned=$(store presign_put "$prefix/large" "$large_bytes" "$large_sha")
echo "signed headers: $(jq -r .url <<<"$presigned" | grep -o 'X-Amz-SignedHeaders=[^&]*')"
start=$(date +%s)
status=$(put large "$work/large" "$presigned")
echo "upload took $(($(date +%s) - start))s"
check "large presigned PUT" 200 "$status"

say "2. HEAD with checksum mode"
head_json=$(store head "$prefix/large")
echo "$head_json"
check "HEAD size" "$large_bytes" "$(jq -r .size <<<"$head_json")"
check "HEAD x-amz-checksum-sha256" \
  "$(xxd -r -p <<<"$large_sha" | base64)" "$(jq -r .checksum_sha256 <<<"$head_json")"
rm -f "$work/large"

say "3. PUT with a body that differs from the signed checksum"
head -c 1024 /dev/urandom >"$work/right"
head -c 1024 /dev/urandom >"$work/wrong"
right_sha=$(sha256sum "$work/right" | cut -d' ' -f1)
presigned=$(store presign_put "$prefix/small" 1024 "$right_sha")
status=$(put wrong "$work/wrong" "$presigned")
grep -o '<Code>[^<]*</Code>' "$work/wrong.body" || true
check "wrong body rejected" 400 "$status"
check "no object after the rejected PUT" '"not_found"' "$(store head "$prefix/small" | jq .error -c | tr -d ':\\' )"

say "4. PUT without the signed headers"
# Providers differ on the status (S3 403, MinIO 400); both refuse the
# signature with AccessDenied or SignatureDoesNotMatch.
status=$(put unsigned "$work/right" "$presigned" skip-headers)
code=$(grep -o '<Code>[^<]*</Code>' "$work/unsigned.body" || true)
echo "$code $(grep -o '<Message>[^<]*</Message>' "$work/unsigned.body" || true)"
check "unsigned headers rejected (4xx)" 4 "${status:0:1}"
check "rejected by signature verification" yes \
  "$([[ $code =~ AccessDenied|SignatureDoesNotMatch ]] && echo yes || echo "no: $code")"

say "   (control) the same URL with its headers and the right body"
check "right body accepted" 200 "$(put right "$work/right" "$presigned")"

say "5. DELETE"
for key in "$prefix/large" "$prefix/small"; do
  check "delete $key" '":ok"' "$(store delete "$key" | jq .result -c | tr -d '\\')"
done
check "large object gone" '"not_found"' "$(store head "$prefix/large" | jq .error -c | tr -d ':\\')"

say "Result"
if ((failures)); then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
