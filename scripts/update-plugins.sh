#!/bin/bash
# Claude Code Plugin Updater & Cache Cleaner
# Automatically updates marketplace plugins and removes stale cache versions.
# Runs as a SessionStart hook in Claude Code.

set -euo pipefail

PLUGINS_DIR="${CLAUDE_PLUGINS_DIR:-$HOME/.claude/plugins}"
MARKETPLACE_DIR="$PLUGINS_DIR/marketplaces"
CACHE_DIR="$PLUGINS_DIR/cache"
INSTALLED_PLUGINS="$PLUGINS_DIR/installed_plugins.json"
LOCK_FILE="${TMPDIR:-/tmp}/claude-plugin-updater.lock"

# --- Lock ---

acquire_lock() {
  if (set -o noclobber; echo $$ > "$LOCK_FILE") 2>/dev/null; then
    return 0
  fi
  local lock_pid
  lock_pid=$(cat "$LOCK_FILE" 2>/dev/null) || return 1
  if kill -0 "$lock_pid" 2>/dev/null; then
    return 1
  fi
  rm -f "$LOCK_FILE"
  (set -o noclobber; echo $$ > "$LOCK_FILE") 2>/dev/null
}

release_lock() {
  rm -f "$LOCK_FILE"
}

trap release_lock EXIT

# --- Functions ---

detect_default_branch() {
  local branch
  branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@') || true
  if [ -z "$branch" ]; then
    for candidate in main master; do
      if git rev-parse "origin/$candidate" &>/dev/null; then
        branch="$candidate"
        break
      fi
    done
  fi
  [ -n "$branch" ] && echo "$branch"
}

update_plugin() {
  local plugin_dir="$1"

  [ -d "$plugin_dir/.git" ] || return 0

  (
    cd "$plugin_dir"

    git fetch origin 2>/dev/null || exit 0

    local local_hash remote_hash default_branch
    local_hash=$(git rev-parse HEAD 2>/dev/null) || exit 0

    default_branch=$(detect_default_branch) || exit 0
    [ -z "$default_branch" ] && exit 0

    remote_hash=$(git rev-parse "origin/$default_branch" 2>/dev/null) || exit 0

    [ "$local_hash" = "$remote_hash" ] && exit 0

    git pull origin "$default_branch" 2>/dev/null || exit 0

    if [ -f "package.json" ]; then
      if command -v bun &>/dev/null; then
        bun install --frozen-lockfile 2>/dev/null || bun install 2>/dev/null || true
      elif command -v npm &>/dev/null; then
        npm ci 2>/dev/null || npm install 2>/dev/null || true
      fi
    fi
  )
}

update_registry() {
  local vendor="$1"
  local plugin_dir="$2"

  [ -f "$INSTALLED_PLUGINS" ] || return 0
  [ -d "$plugin_dir/.git" ] || return 0
  command -v python3 &>/dev/null || return 0

  local plugin_name version commit_sha
  read -r plugin_name version <<< "$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d['name'], d['version'])
" "$plugin_dir/package.json" 2>/dev/null)" || return 0
  commit_sha=$(git -C "$plugin_dir" rev-parse HEAD 2>/dev/null) || return 0

  local plugin_key="${plugin_name}@${vendor}"
  local cache_path="$CACHE_DIR/$vendor/$plugin_name/$version"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

  # Update registry atomically with python3 (safe JSON manipulation)
  python3 -c "
import json, sys, os

path = sys.argv[1]
key = sys.argv[2]
new_values = {
    'installPath': sys.argv[3],
    'version': sys.argv[4],
    'gitCommitSha': sys.argv[5],
    'lastUpdated': sys.argv[6],
}

tmp_path = path + '.tmp'
try:
    with open(path) as f:
        data = json.load(f)

    if key not in data.get('plugins', {}):
        sys.exit(0)

    for entry in data['plugins'][key]:
        entry.update(new_values)

    with open(tmp_path, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    os.replace(tmp_path, path)
except Exception:
    try:
        os.remove(tmp_path)
    except OSError:
        pass
    sys.exit(1)
" "$INSTALLED_PLUGINS" "$plugin_key" "$cache_path" "$version" "$commit_sha" "$now"
}

sort_semver() {
  # Sort version directory names by semver (descending), non-semver names are excluded
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -t. -k1,1rn -k2,2rn -k3,3rn
}

clean_old_caches() {
  local cache_path="$1"

  [ -d "$cache_path" ] || return 0

  local count=0
  while IFS= read -r ver; do
    [ -z "$ver" ] && continue
    count=$((count + 1))
    if [ "$count" -gt 1 ]; then
      rm -rf "$cache_path/$ver"
    fi
  done <<< "$(ls -1 "$cache_path" 2>/dev/null | sort_semver)"
}

# --- Main ---

acquire_lock || exit 0

[ -d "$MARKETPLACE_DIR" ] || exit 0

for vendor_dir in "$MARKETPLACE_DIR"/*/; do
  [ -d "$vendor_dir" ] || continue
  vendor=$(basename "$vendor_dir")

  update_plugin "$vendor_dir" || true
  update_registry "$vendor" "$vendor_dir" || true

  # Clean caches for all plugins under this vendor
  if [ -d "$CACHE_DIR/$vendor" ]; then
    for plugin_cache in "$CACHE_DIR/$vendor"/*/; do
      [ -d "$plugin_cache" ] || continue
      clean_old_caches "$plugin_cache"
    done
  fi
done
