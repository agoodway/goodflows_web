#!/usr/bin/env bash
# Checks that an S3-compatible bucket enforces what remote caches rely on
# (openspec change add-remote-cache-storage, task 6.2), through the app's own
# GoodFlows.Caches.ObjectStore.S3 presigner:
#
#   1. a 5,000,000,000-byte PUT through a presigned URL succeeds,
#   2. HEAD with checksum mode returns x-amz-checksum-sha256 (and the size),
#   3. a PUT whose body differs from the signed checksum is rejected,
#   4. a PUT without the signed headers is rejected,
#   5. DELETE removes the objects,
#
# and multipart uploads (openspec change add-multipart-cache-uploads, task
# 6.2), through ObjectStore.S3's create/presign_part/list/complete/abort:
#
#   6. a 5,000,000,000-byte archive uploads as parallel presigned parts that
#      sign content-length and content-md5,
#   7. a part whose body differs from its signed MD5 is rejected (BadDigest),
#   8. a part PUT without the signed headers fails signature verification,
#   9. ListParts returns every part with ETag = hex MD5; after completing,
#      HEAD reports the size and ETag hex(md5(concatenated part MD5s))-N,
#  10. a part PUT after AbortMultipartUpload fails with NoSuchUpload,
#  11. abort and delete clean up.
#
# Point CACHE_S3_* at the bucket (MinIO: see `just minio` in app/; R2:
# endpoint https://<account>.r2.cloudflarestorage.com, region auto) and run:
#
#   scripts/cache-object-store-check.sh
#
# CHECK_LARGE_BYTES (default 5000000000) sets the large PUT's size. The
# archive is a sparse file of zeros under a temporary directory.
# CHECK_MULTIPART_BYTES (default 5000000000) sets the multipart archive's
# size, CHECK_PART_BYTES (default 16 MiB) the part size and CHECK_PARALLEL
# (default 8) how many parts upload at once. Uploads the script started are
# aborted and its objects deleted on exit, also after a failure.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
large_bytes=${CHECK_LARGE_BYTES:-5000000000}
multipart_bytes=${CHECK_MULTIPART_BYTES:-5000000000}
part_bytes=${CHECK_PART_BYTES:-16777216}
parallel=${CHECK_PARALLEL:-8}
work=$(mktemp -d /tmp/goodflows-store-check.XXXXXX)
failures=0
cleanup_uploads=() # "KEY UPLOAD_ID" of uploads to abort on exit
cleanup_keys=()     # objects to delete on exit

[[ -f "$HOME/.local/share/goodflows/env" ]] && source "$HOME/.local/share/goodflows/env"
: "${CACHE_S3_BUCKET:?set CACHE_S3_BUCKET and the other CACHE_S3_* variables}"

say() { printf '\n== %s\n' "$*"; }
check() { # check NAME EXPECTED ACTUAL
  if [[ $2 == "$3" ]]; then echo "PASS  $1 ($3)"; else echo "FAIL  $1: expected $2, got $3"; failures=$((failures + 1)); fi
}

# Runs one ObjectStore.S3 call in the dev app config: presign_put KEY SIZE SHA,
# head KEY, delete KEY, create KEY, presign_parts KEY UPLOAD_ID SIZE PART_SIZE
# MD5_FILE (one base64 MD5 per line), list_parts KEY UPLOAD_ID, complete KEY
# UPLOAD_ID (completes from the listed parts), or abort KEY UPLOAD_ID. Prints
# one line of JSON.
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

        ["create", key] ->
          case S3.create_multipart(key) do
            {:ok, upload_id} -> %{upload_id: upload_id}
            {:error, reason} -> %{error: inspect(reason)}
          end

        ["presign_parts", key, upload_id, size, part_size, md5_file] ->
          {size, part_size} = {String.to_integer(size), String.to_integer(part_size)}
          md5s = md5_file |> File.read!() |> String.split()
          count = length(md5s)

          for {md5, n} <- Enum.with_index(md5s, 1) do
            length = if n == count, do: size - (n - 1) * part_size, else: part_size

            {url, headers} =
              S3.presign_part(key, upload_id, n, %{size: length, md5: md5, expires_in: 7200})

            %{number: n, url: url, headers: headers}
          end

        ["list_parts", key, upload_id] ->
          case S3.list_parts(key, upload_id) do
            {:ok, parts} -> %{parts: parts}
            {:error, reason} -> %{error: inspect(reason)}
          end

        ["complete", key, upload_id] ->
          {:ok, parts} = S3.list_parts(key, upload_id)

          %{
            result:
              inspect(S3.complete_multipart(key, upload_id, Enum.map(parts, &{&1.number, &1.etag})))
          }

        ["abort", key, upload_id] ->
          %{result: inspect(S3.abort_multipart(key, upload_id))}
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

cleanup() {
  local entry
  for entry in "${cleanup_uploads[@]}"; do
    # shellcheck disable=SC2086
    store abort $entry >/dev/null 2>&1 || true
  done
  for entry in "${cleanup_keys[@]}"; do store delete "$entry" >/dev/null 2>&1 || true; done
  rm -rf "$work"
}
trap cleanup EXIT

# part_md5 FILE NUMBER PART_BYTES -> base64 MD5 of that part of FILE
part_md5() {
  dd if="$1" bs="$3" skip=$(($2 - 1)) count=1 iflag=fullblock status=none | openssl md5 -binary | base64
}

# put_part DIR FILE PART_BYTES PARTS_JSONL LINE -> "NUMBER STATUS ETAG": PUTs
# the part on line LINE of PARTS_JSONL with its headers and no Authorization.
put_part() {
  local part n url args=() status etag
  part=$(sed -n "${5}p" "$4")
  n=$(jq -r .number <<<"$part")
  url=$(jq -r .url <<<"$part")
  while IFS=$'\t' read -r name value; do args+=(-H "$name: $value"); done \
    < <(jq -r '.headers | to_entries[] | [.key, .value] | @tsv' <<<"$part")
  dd if="$2" bs="$3" skip=$((n - 1)) count=1 iflag=fullblock status=none >"$1/part.$n"
  status=$(curl -sS -D "$1/part.$n.headers" -o "$1/part.$n.body" -w '%{http_code}' \
    -X PUT -T "$1/part.$n" "${args[@]}" "$url")
  etag=$({ grep -i '^etag:' "$1/part.$n.headers" || true; } | tr -d '"\r' | awk '{print tolower($2)}')
  rm -f "$1/part.$n" "$1/part.$n.body" "$1/part.$n.headers"
  echo "$n $status $etag"
}
export -f part_md5 put_part

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

say "6. $multipart_bytes-byte multipart upload, $part_bytes-byte parts, $parallel in parallel"
key="$prefix/multipart"
upload_id=$(store create "$key" | jq -r '.upload_id // empty')
check "create multipart upload" yes "$([[ -n $upload_id ]] && echo yes || echo no)"
cleanup_uploads+=("$key $upload_id")
cleanup_keys+=("$key")
truncate -s "$multipart_bytes" "$work/multipart"
count=$(((multipart_bytes + part_bytes - 1) / part_bytes))
start=$(date +%s)
mkdir -p "$work/md5"
seq "$count" | xargs -P "$parallel" -I{} \
  bash -c 'part_md5 "$0" {} "$1" >"$2/{}"' "$work/multipart" "$part_bytes" "$work/md5"
for n in $(seq "$count"); do cat "$work/md5/$n"; done >"$work/md5s"
echo "$count parts, MD5s took $(($(date +%s) - start))s"
store presign_parts "$key" "$upload_id" "$multipart_bytes" "$part_bytes" "$work/md5s" \
  | jq -c '.[]' >"$work/parts.jsonl"
echo "part 1 signed headers: $(head -1 "$work/parts.jsonl" | jq -r .url | grep -o 'X-Amz-SignedHeaders=[^&]*')"
check "a URL for every part" "$count" "$(wc -l <"$work/parts.jsonl" | tr -d ' ')"
mkdir -p "$work/parts"
start=$(date +%s.%N)
seq "$count" | xargs -P "$parallel" -I{} bash -c 'put_part "$0" "$1" "$2" "$3" {}' \
  "$work/parts" "$work/multipart" "$part_bytes" "$work/parts.jsonl" >"$work/put-results"
elapsed=$(echo "$(date +%s.%N) - $start" | bc)
echo "upload took ${elapsed}s ($(echo "$multipart_bytes / $elapsed / 1000000" | bc) MB/s)"
check "every part PUT 200" "$count" "$(awk '$2 == 200' "$work/put-results" | wc -l | tr -d ' ')"

say "7. part with a body that differs from its signed MD5"
small_key="$prefix/multipart-small"
small_id=$(store create "$small_key" | jq -r '.upload_id // empty')
cleanup_uploads+=("$small_key $small_id")
cleanup_keys+=("$small_key")
head -c 5242880 /dev/urandom >"$work/small-right"
head -c 5242880 /dev/urandom >"$work/small-wrong"
openssl md5 -binary "$work/small-right" | base64 >"$work/small-md5"
store presign_parts "$small_key" "$small_id" 5242880 5242880 "$work/small-md5" | jq -c '.[]' >"$work/small.jsonl"
read -r _ status _ < <(put_part "$work" "$work/small-wrong" 5242880 "$work/small.jsonl" 1)
check "wrong part body rejected" 400 "$status"
small_url=$(jq -r .url "$work/small.jsonl")
code=$(curl -sS -X PUT -H "content-length: 5242880" -H "content-md5: $(cat "$work/small-md5")" \
  -T "$work/small-wrong" "$small_url" | grep -o '<Code>[^<]*</Code>' || true)
check "rejected as BadDigest" "<Code>BadDigest</Code>" "$code"

say "8. part PUT without the signed headers"
status=$(curl -sS -o "$work/nohdr.body" -w '%{http_code}' -X PUT -T "$work/small-right" "$small_url")
code=$(grep -o '<Code>[^<]*</Code>' "$work/nohdr.body" || true)
echo "$status $code"
check "unsigned part headers rejected (4xx)" 4 "${status:0:1}"
check "rejected by signature verification" yes \
  "$([[ $code =~ AccessDenied|SignatureDoesNotMatch ]] && echo yes || echo "no: $code")"
read -r _ status _ < <(put_part "$work" "$work/small-right" 5242880 "$work/small.jsonl" 1)
check "(control) right part body accepted" 200 "$status"

say "9. ListParts, complete, HEAD"
listed=$(store list_parts "$key" "$upload_id")
check "ListParts returns every part" "$count" "$(jq '.parts | length' <<<"$listed")"
expected=$(while read -r md5; do base64 -d <<<"$md5" | xxd -p; done <"$work/md5s" | jq -R -s -c 'split("\n") | map(select(. != ""))')
check "every ETag is the part's hex MD5" true \
  "$(jq --argjson want "$expected" '[.parts[].etag] == $want and ([.parts[].number] == [range(1; ($want | length) + 1)])' <<<"$listed")"
check "PUT response ETags match" "$count" "$(sort -n "$work/put-results" | awk '{print $3}' \
  | paste -d' ' - <(jq -r '.[]' <<<"$expected") | awk '$1 == $2' | wc -l | tr -d ' ')"
start=$(date +%s)
check "complete" '":ok"' "$(store complete "$key" "$upload_id" | jq .result -c | tr -d '\\')"
echo "complete took $(($(date +%s) - start))s (including one ListParts)"
head_json=$(store head "$key")
echo "$head_json"
want_etag="$(while read -r md5; do base64 -d <<<"$md5"; done <"$work/md5s" | openssl md5 -binary | xxd -p | tr -d '\n')-$count"
check "HEAD size" "$multipart_bytes" "$(jq -r .size <<<"$head_json")"
check "HEAD ETag is hex(md5(concatenated md5s))-N" "$want_etag" "$(jq -r .etag <<<"$head_json")"
rm -f "$work/multipart"

say "10. part PUT after abort"
check "abort" '":ok"' "$(store abort "$small_key" "$small_id" | jq .result -c | tr -d '\\')"
status=$(curl -sS -o "$work/aborted.body" -w '%{http_code}' -X PUT -H "content-length: 5242880" \
  -H "content-md5: $(cat "$work/small-md5")" -T "$work/small-right" "$small_url")
code=$(grep -o '<Code>[^<]*</Code>' "$work/aborted.body" || true)
check "part after abort rejected" 404 "$status"
check "rejected as NoSuchUpload" "<Code>NoSuchUpload</Code>" "$code"
check "no object for the aborted upload" '"not_found"' "$(store head "$small_key" | jq .error -c | tr -d ':\\')"

say "11. abort and delete clean up"
# Stores differ (MinIO and R2 answer 204, S3 404 NoSuchUpload); the app
# counts both as done and deletes the object next.
result=$(store abort "$key" "$upload_id" | jq -r .result)
echo "abort of the completed upload: $result"
check "abort of the completed upload is ok or gone" yes \
  "$([[ $result == ":ok" || $result == "{:error, :not_found}" ]] && echo yes || echo "no: $result")"
check "delete $key" '":ok"' "$(store delete "$key" | jq .result -c | tr -d '\\')"
check "multipart object gone" '"not_found"' "$(store head "$key" | jq .error -c | tr -d ':\\')"

say "Result"
if ((failures)); then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
