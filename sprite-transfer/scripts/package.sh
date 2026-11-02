#!/usr/bin/env bash
# Build static musl gf-transfer binaries and write a manifest for GoodFlows.
#
# Usage: scripts/package.sh [OUT_DIR]
#   OUT_DIR defaults to ../app/priv/gf-transfer (relative to the crate).
#   GF_TRANSFER_TARGETS overrides the target list (space separated), default
#   "x86_64-unknown-linux-musl aarch64-unknown-linux-musl".
#
# Output:
#   OUT_DIR/<target>/gf-transfer
#   OUT_DIR/manifest.json
#     {"name":"gf-transfer","version":"X","protocol":1,"artifacts":[
#       {"target":"...","arch":"x86_64","path":"<target>/gf-transfer","sha256":"...","size":N},...],
#      "rustc":"rustc 1.x.y (...)"}
#   Only the targets built by this run are published: per-target directories
#   left in OUT_DIR from earlier runs are dropped, so binaries and manifest
#   always match.
#
# Any failed target, an unsupported target, or a binary larger than the
# 16 MiB (16,777,216-byte) filesystem write limit fails the script and
# leaves OUT_DIR untouched.
#
# Publishing is all-or-nothing: the new binaries and manifest are staged in a
# sibling directory (a copy of OUT_DIR plus the new files) and swapped in with
# one atomic exchange (`mv --exchange`, coreutils >= 9.5). Readers therefore
# see either the old binaries with the old manifest or the new binaries with
# the new manifest, never a mix. Without `mv --exchange` the swap falls back
# to two renames, so OUT_DIR is briefly missing (a missing manifest, never a
# mismatched one).
#
# Binaries are read from cargo's real target directory (`cargo metadata`), so
# CARGO_TARGET_DIR or a `build.target-dir` setting cannot make the script
# package a stale binary. Builds remap the crate and cargo registry paths
# (`--remap-path-prefix`, appended to any RUSTFLAGS) so binaries do not embed
# the builder's home directory, and the manifest records `rustc -V`. A
# cross-architecture binary is version-checked through `qemu-<arch>` when it
# is installed; otherwise the check is skipped with a warning.
#
# If the fallback swap fails after moving OUT_DIR aside, the previous OUT_DIR
# is restored.
#
# Cross-linking: when the target architecture differs from the host and
# CARGO_TARGET_<TRIPLE>_LINKER is unset, rust-lld is used (musl targets ship
# self-contained CRT objects and libc).
set -euo pipefail

CRATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ARG="${1:-$CRATE_DIR/../app/priv/gf-transfer}"
mkdir -p "$OUT_ARG"
OUT="$(cd "$OUT_ARG" && pwd)"
STAGE="$(mktemp -d "$(dirname "$OUT")/.$(basename "$OUT").stage.XXXXXX")"
OLD=""
cleanup() {
  rm -rf "$STAGE"
  [ -z "$OLD" ] || rm -rf "$OLD"
}
trap cleanup EXIT
# Start from the current contents so unrelated files survive the swap, but
# drop earlier per-target outputs: only this run's targets are published.
cp -a "$OUT/." "$STAGE/"
rm -rf "$STAGE"/*-unknown-linux-musl
TARGETS="${GF_TRANSFER_TARGETS:-x86_64-unknown-linux-musl aarch64-unknown-linux-musl}"
MAX_SIZE=16777216
PROTOCOL=1
HOST_ARCH="$(uname -m)"

die() {
  echo "package.sh: $*" >&2
  exit 1
}

metadata="$(cargo metadata --format-version 1 --no-deps --manifest-path "$CRATE_DIR/Cargo.toml")" ||
  die "cargo metadata failed"
TARGET_DIR="$(printf '%s' "$metadata" | sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')"
[ -n "$TARGET_DIR" ] || TARGET_DIR="${CARGO_TARGET_DIR:-$CRATE_DIR/target}"

CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=$CRATE_DIR=/gf-transfer --remap-path-prefix=$CARGO_HOME_DIR/registry/src=/cargo/registry/src"
RUSTC_VERSION="$(rustc -V)" || die "rustc -V failed"

VERSION="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$CRATE_DIR/Cargo.toml" | head -n1)"
[ -n "$VERSION" ] || die "could not read version from Cargo.toml"

entries=()
for target in $TARGETS; do
  arch="${target%%-*}"
  case "$target" in
    x86_64-unknown-linux-musl | aarch64-unknown-linux-musl) ;;
    *) die "unsupported target $target (expected a *-unknown-linux-musl target for x86_64 or aarch64)" ;;
  esac

  linker_var="CARGO_TARGET_$(echo "$target" | tr 'a-z-' 'A-Z_')_LINKER"
  if [ "$arch" != "$HOST_ARCH" ] && [ -z "${!linker_var:-}" ]; then
    export "$linker_var=rust-lld"
  fi

  echo "==> building $target" >&2
  cargo build --release --locked --manifest-path "$CRATE_DIR/Cargo.toml" --target "$target" >&2 ||
    die "cargo build failed for $target"

  bin="$TARGET_DIR/$target/release/gf-transfer"
  [ -f "$bin" ] || die "missing binary for $target at $bin"

  size="$(stat -c %s "$bin")"
  if [ "$size" -gt "$MAX_SIZE" ]; then
    die "$target binary is $size bytes, above the $MAX_SIZE-byte bootstrap limit"
  fi

  want="{\"name\":\"gf-transfer\",\"version\":\"$VERSION\",\"protocol\":$PROTOCOL}"
  if [ "$arch" = "$HOST_ARCH" ]; then
    got="$("$bin" version)"
    [ "$got" = "$want" ] || die "$target version handshake mismatch: $got"
  elif command -v "qemu-$arch" >/dev/null 2>&1; then
    got="$("qemu-$arch" "$bin" version)"
    [ "$got" = "$want" ] || die "$target version handshake mismatch: $got"
  else
    echo "package.sh: warning: qemu-$arch not found; skipping the $target version handshake" >&2
  fi

  mkdir -p "$STAGE/$target"
  install -m 0755 "$bin" "$STAGE/$target/gf-transfer"
  sha="$(sha256sum "$STAGE/$target/gf-transfer" | cut -d' ' -f1)"

  entries+=("$(printf '{"target":"%s","arch":"%s","path":"%s/gf-transfer","sha256":"%s","size":%s}' \
    "$target" "$arch" "$target" "$sha" "$size")")
  echo "    $target: $size bytes, sha256 $sha" >&2
done

[ "${#entries[@]}" -gt 0 ] || die "no targets selected"

joined="$(IFS=,; echo "${entries[*]}")"
rustc_json="$(printf '%s' "$RUSTC_VERSION" | sed 's/\\/\\\\/g; s/"/\\"/g')"
printf '{"name":"gf-transfer","version":"%s","protocol":%s,"artifacts":[%s],"rustc":"%s"}\n' \
  "$VERSION" "$PROTOCOL" "$joined" "$rustc_json" >"$STAGE/manifest.json"
if command -v jq >/dev/null 2>&1; then
  jq -e . "$STAGE/manifest.json" >/dev/null || die "generated manifest is not valid JSON"
fi
chmod 0755 "$STAGE"
sync -f "$STAGE" 2>/dev/null || sync

if mv --exchange -T "$STAGE" "$OUT" 2>/dev/null; then
  # $STAGE now holds the previous contents; the EXIT trap removes it.
  :
else
  OLD="$(dirname "$OUT")/.$(basename "$OUT").old.$$"
  mv -T "$OUT" "$OLD"
  if ! mv -T "$STAGE" "$OUT"; then
    # Put the previous contents back; the trap must not delete them.
    mv -T "$OLD" "$OUT" && OLD=""
    die "swap into $OUT failed; previous contents restored"
  fi
fi
echo "==> wrote $OUT/manifest.json" >&2
