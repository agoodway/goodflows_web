#!/usr/bin/env bash
# Use private copies so compiling here cannot change another worktree.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
worktree_root="$PWD"
# Git lists main first; NUL delimiters keep paths with spaces intact.
IFS= read -r -d '' main_entry < <(git worktree list --porcelain -z)
main_root=${main_entry#worktree }
if [[ "$main_root" == "$worktree_root" || ! -d "$main_root/app" ]]; then
  printf 'Workie cache: no separate main checkout; using normal setup.\n'
  exit 0
fi

staging=''
trap 'if [[ -n "$staging" ]]; then rm -rf -- "$staging"; fi' EXIT

for cache in deps _build/dev _build/test; do
  source_cache="$main_root/app/$cache"
  target_cache="$worktree_root/app/$cache"
  # Existing caches belong to this branch and must not be overwritten.
  if [[ -e "$target_cache" || -L "$target_cache" ]]; then
    printf 'Workie cache: keeping existing %s.\n' "$cache"
    continue
  fi
  if [[ ! -d "$source_cache" ]]; then
    printf 'Workie cache: main checkout has no %s; Mix will build it.\n' "$cache"
    continue
  fi

  mkdir -p -- "$(dirname "$target_cache")"
  staging=$(mktemp -d "$worktree_root/app/.workie-cache.XXXXXXXX")
  # Avoid hardlinks so compilation in one worktree cannot mutate another.
  if cp -a --reflink=auto -- "$source_cache/." "$staging/"; then
    mv -T -- "$staging" "$target_cache"
    staging=''
    printf 'Workie cache: copied %s from %s.\n' "$cache" "$main_root"
  else
    printf 'Workie cache: could not copy %s; Mix will build it.\n' "$cache" >&2
    rm -rf -- "$staging"
    staging=''
  fi
done
