#!/usr/bin/env bash
# Never execute local env files: they may contain secrets or arbitrary shell text.
read_branch_db() {
  local file value saved=""
  for file in .env.dev.local .env.test.local; do
    [ -f "$file" ] || continue
    while IFS= read -r value; do
      if [[ ! "$value" =~ ^[a-zA-Z0-9_]{1,24}$ ]]; then
        echo "Error: $file BRANCH_DB must be 1 to 24 letters, digits or underscores" >&2
        return 1
      fi
      if [ -n "$saved" ] && [ "$saved" != "$value" ]; then
        echo "Error: conflicting BRANCH_DB settings in local env files" >&2
        return 1
      fi
      saved=$value
    done < <(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?BRANCH_DB[[:space:]]*=[[:space:]]*(.*)$/\2/p' "$file" |
      sed -E "s/[[:space:]]+$//; s/^['\"](.*)['\"]$/\\1/")
  done
  printf '%s' "$saved"
}

# An empty value is present; callers distinguish it from an absent key by status.
read_env_assignment() {
  local file=$1 key=$2 raw value
  [ -f "$file" ] || return 1
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  raw=$(sed -nE "s/^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=[[:space:]]*(.*)\$/FOUND:\\2/p" "$file" | tail -n 1)
  [[ "$raw" == FOUND:* ]] || return 1
  value=${raw#FOUND:}
  if [[ "$value" =~ ^\"(.*)\"([[:space:]]*(#.*)?)?$ ]]; then
    value=${BASH_REMATCH[1]}
  elif [[ "$value" =~ ^\'(.*)\'([[:space:]]*(#.*)?)?$ ]]; then
    value=${BASH_REMATCH[1]}
  else
    # Match Dotenvy’s treatment of unquoted hashes.
    value=${value%%#*}
    value=${value%"${value##*[![:space:]]}"}
  fi
  printf '%s' "$value"
}

# Keep worktree port precedence aligned with config/runtime.exs.
dev_port() {
  local branch_id file value
  branch_id=$(read_branch_db) || return 1
  if [ -z "$branch_id" ]; then
    printf '7654'
    return 0
  fi
  if [ -n "${PORT+x}" ]; then
    printf '%s' "$PORT"
    return 0
  fi
  for file in .env.dev.local .env.dev .env.local .env; do
    if value=$(read_env_assignment "$file" PORT); then
      printf '%s' "$value"
      return 0
    fi
  done
  printf '4000'
}

set_env_default() {
  local file=$1 key=$2 value=$3
  if [ -f "$file" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$file"; then
    return
  fi
  printf '\n%s=%s\n' "$key" "$value" >> "$file"
}
