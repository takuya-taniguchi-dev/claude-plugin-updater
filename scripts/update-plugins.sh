#!/bin/bash
# Claude Code Plugin Updater & Cache Cleaner
# Automatically updates marketplace plugins and removes stale cache versions.
# Runs as a SessionStart hook in Claude Code.

set -euo pipefail

PLUGINS_DIR="${CLAUDE_PLUGINS_DIR:-$HOME/.claude/plugins}"
MARKETPLACE_DIR="$PLUGINS_DIR/marketplaces"
CACHE_DIR="$PLUGINS_DIR/cache"

update_plugin() {
  local plugin_dir="$1"

  [ -d "$plugin_dir/.git" ] || return 0

  cd "$plugin_dir"

  git fetch origin 2>/dev/null || return 0

  local local_hash remote_hash default_branch
  local_hash=$(git rev-parse HEAD 2>/dev/null) || return 0

  default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@') || true
  if [ -z "$default_branch" ]; then
    default_branch=$(git remote show origin 2>/dev/null | grep 'HEAD branch' | sed 's/.*: //') || true
  fi
  [ -z "$default_branch" ] && default_branch="main"

  remote_hash=$(git rev-parse "origin/$default_branch" 2>/dev/null) || return 0

  [ "$local_hash" = "$remote_hash" ] && return 0

  git pull origin "$default_branch" 2>/dev/null || return 0

  if [ -f "package.json" ]; then
    if command -v bun &>/dev/null; then
      bun install --frozen-lockfile 2>/dev/null || bun install 2>/dev/null || true
    elif command -v npm &>/dev/null; then
      npm ci 2>/dev/null || npm install 2>/dev/null || true
    fi
  fi
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
  done <<< "$(ls -1t "$cache_path" 2>/dev/null)"
}

# --- Main ---

[ -d "$MARKETPLACE_DIR" ] || exit 0

for vendor_dir in "$MARKETPLACE_DIR"/*/; do
  [ -d "$vendor_dir" ] || continue
  vendor=$(basename "$vendor_dir")

  update_plugin "$vendor_dir"

  # Clean caches for all plugins under this vendor
  if [ -d "$CACHE_DIR/$vendor" ]; then
    for plugin_cache in "$CACHE_DIR/$vendor"/*/; do
      [ -d "$plugin_cache" ] || continue
      clean_old_caches "$plugin_cache"
    done
  fi
done
