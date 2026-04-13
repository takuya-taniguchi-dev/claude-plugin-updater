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
VERBOSE="${CLAUDE_PLUGIN_UPDATE_VERBOSE:-0}"

# --- Logging ---

log_verbose() {
  [ "$VERBOSE" = "1" ] && echo "[update-plugins] $*" >&2
  return 0  # Prevent set -e from treating $VERBOSE != "1" as failure
}

log_error() {
  echo "[update-plugins] ERROR: $*" >&2
}

# --- Lock ---

LOCK_METHOD=""
LOCK_DIR="${LOCK_FILE}.d"

acquire_lock() {
  if command -v flock &>/dev/null; then
    # Preferred: flock-based locking (atomic, no race conditions)
    exec 200>"$LOCK_FILE"
    flock -n 200 || return 1
    LOCK_METHOD="flock"
  else
    # Fallback for macOS: mkdir-based locking (POSIX atomic, no TOCTOU race)
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo $$ > "$LOCK_DIR/pid"
      LOCK_METHOD="mkdir"
      return 0
    fi
    # Check for stale lock
    local lock_pid
    lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null) || return 1
    if kill -0 "$lock_pid" 2>/dev/null; then
      return 1
    fi
    # Stale lock: remove and retry (single retry to avoid infinite loop)
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo $$ > "$LOCK_DIR/pid"
      LOCK_METHOD="mkdir"
      return 0
    fi
    return 1
  fi
}

release_lock() {
  if [ "$LOCK_METHOD" = "flock" ]; then
    exec 200>&-  # Explicitly close FD to release flock
    rm -f "$LOCK_FILE"
  elif [ "$LOCK_METHOD" = "mkdir" ]; then
    local lock_pid
    lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null) || return 0
    [ "$lock_pid" = "$$" ] && rm -rf "$LOCK_DIR"
  fi
}

# Set trap after acquire_lock succeeds (not before) to avoid
# running release_lock when no lock was acquired.
if ! acquire_lock; then
  log_verbose "Another instance is running, exiting"
  exit 0
fi

trap release_lock EXIT

# --- Security Audit ---
#
# IMPORTANT: This audit is best-effort heuristic detection only.
# It catches common patterns but CANNOT detect:
#   - String concatenation to build identifiers (e.g. "fe"+"tch")
#   - Dynamic imports or eval-based code execution
#   - Obfuscated or minified code changes (warned separately)
#   - Indirect references via variables or reflection
# Manual review is still recommended for critical updates.

AUDIT_LOG_DIR="$HOME/.claude/logs/plugin-audit"
mkdir -p "$AUDIT_LOG_DIR" 2>/dev/null || true  # Non-critical: fallback path used below
AUDIT_LOG="$AUDIT_LOG_DIR/$(date +%Y-%m-%d).log"
AUDIT_SESSION_MARKER="--- Session $(date -u +%Y-%m-%dT%H:%M:%SZ) PID=$$ ---"
echo "$AUDIT_SESSION_MARKER" >> "$AUDIT_LOG" 2>/dev/null || {
  # Fallback to tmpdir if persistent path is not writable
  AUDIT_LOG="${TMPDIR:-/tmp}/claude-plugin-audit.log"
  : > "$AUDIT_LOG"
}

# Track whether any warnings were emitted this session
AUDIT_HAS_WARNINGS=0

audit_warn() {
  local plugin="$1" msg="$2"
  echo "[SECURITY] $plugin: $msg" >> "$AUDIT_LOG"
  AUDIT_HAS_WARNINGS=1
}

# Run security checks on changed files between two commits.
# Operates on fetched-but-not-merged refs, so no code is executed before audit.
# Returns 0 if clean, 1 if suspicious changes detected.
security_audit() {
  local plugin_dir="$1"
  local old_hash="$2"
  local new_hash="$3"
  local plugin_name
  plugin_name=$(basename "$plugin_dir")

  local diff_file
  diff_file=$(mktemp "${TMPDIR:-/tmp}/claude-audit-diff.XXXXXX")
  # Ensure temp file is cleaned up even if set -e aborts mid-function
  trap "rm -f '$diff_file'" RETURN

  git -C "$plugin_dir" diff "$old_hash" "$new_hash" -- \
    '*.js' '*.cjs' '*.mjs' '*.ts' '*.jsx' '*.tsx' \
    '*.json' '*.sh' '*.py' \
    '*.yml' '*.yaml' '*.toml' \
    'Makefile' 'Dockerfile' > "$diff_file" 2>/dev/null || return 0

  [ -s "$diff_file" ] || return 0

  local found=0

  # 1. New external URLs (exclude common legitimate domains)
  if grep -E '^\+.*https?://' "$diff_file" \
    | grep -vE 'localhost|127\.0\.0\.1|::1|github\.com|raw\.githubusercontent\.com|registry\.npmjs\.org|npmjs\.org|cdn\.jsdelivr\.net' \
    | grep -q .; then
    audit_warn "$plugin_name" "New external URL(s) detected in diff"
    found=1
  fi

  # 2. New fetch/http/axios calls
  if grep -E '^\+.*(fetch\(|axios\.|http\.request|https\.request|got\(|ky\(|node-fetch|undici)' "$diff_file" | grep -q .; then
    audit_warn "$plugin_name" "New HTTP client call(s) added"
    found=1
  fi

  # 3. New env var reads — both bracket and dot notation (potential credential harvesting)
  #    Excludes standard vars and plugin-prefixed vars
  local env_pattern='^\+.*process\.env(\[["'"'"'"]?|\.)[A-Z]'
  if grep -E "$env_pattern" "$diff_file" \
    | grep -vE 'NODE_ENV|PATH|HOME|TMPDIR|CLAUDE_MEM_|CLAUDE_CODE_|CLAUDE_PLUGINS_' \
    | grep -q .; then
    audit_warn "$plugin_name" "New process.env access detected (non-standard keys)"
    found=1
  fi

  # 4. Modifications to settings/config that enable external providers
  if grep -iE '^\+.*(openrouter|gemini|external|remote).*(default|enabled|true)' "$diff_file" | grep -q .; then
    audit_warn "$plugin_name" "External provider may be enabled by default after update"
    found=1
  fi

  # 5. Child process spawning (potential command injection)
  #    Match require('child_process'), execSync, spawnSync, but not regex .exec()
  if grep -E '^\+.*(child_process|execSync|spawnSync)' "$diff_file" | grep -q .; then
    audit_warn "$plugin_name" "New child_process usage added"
    found=1
  fi
  if grep -E '^\+.*(exec\(|spawn\()' "$diff_file" \
    | grep -vE '\.exec\(' \
    | grep -q .; then
    audit_warn "$plugin_name" "New exec()/spawn() call(s) added"
    found=1
  fi

  # 6. File system access to sensitive paths
  #    Use word boundaries to avoid false positives (e.g. ".environment")
  if grep -E '^\+.*(\/\.ssh[\/"]|\/\.aws[\/"]|credentials\.json|\/etc\/passwd|\.keychain|SecretKey)' "$diff_file" | grep -q .; then
    audit_warn "$plugin_name" "Access to sensitive file paths detected"
    found=1
  fi
  #    Separate check for .env files (literal filename, not substring)
  if grep -E '^\+.*(\/\.env["'"'"'"]|\/\.env\.local|dotenv|loadEnv)' "$diff_file" | grep -q .; then
    audit_warn "$plugin_name" "Access to .env / dotenv files detected"
    found=1
  fi

  # 7. Minified/bundled file changes (large single-line diffs are unauditable)
  local large_lines
  large_lines=$(grep -E '^\+' "$diff_file" | awk 'length > 500 { count++ } END { print count+0 }')
  if [ "$large_lines" -gt 5 ]; then
    audit_warn "$plugin_name" "Minified/bundled file changes detected ($large_lines long lines) — manual review recommended"
    found=1
  fi

  # 8. eval / Function constructor (code injection vectors)
  if grep -E '^\+.*(eval\(|new Function\(|Function\()' "$diff_file" | grep -q .; then
    audit_warn "$plugin_name" "eval() or Function constructor detected"
    found=1
  fi

  # 9. npm lifecycle scripts (postinstall can execute arbitrary commands during install)
  #    Require trailing `":` to avoid matching version strings like `"install": "1.0.0"`
  if grep -E '^\+.*"(preinstall|install|postinstall|prepare|prepublish|prepublishOnly|prepack|postpack|preuninstall|postuninstall)"\s*:' "$diff_file" | grep -q .; then
    audit_warn "$plugin_name" "npm lifecycle script added or modified"
    found=1
  fi

  return $found
}

# Static audit of plugin-provided audit.sh files.
# Previously this executed audit.sh, but executing plugin-provided shell scripts
# is an inherent security risk (rbash is trivially bypassed via `bash -c`).
# Now we only perform a static scan: if the file exists and contains suspicious
# patterns, we warn but never execute it.
#
# When new_hash is provided, scans the NEW (post-merge) version of audit.sh
# via `git show`, so newly added malicious scripts are caught before merge.
static_audit_plugin_hook() {
  local plugin_dir="$1"
  local new_hash="${2:-}"
  local plugin_name
  plugin_name=$(basename "$plugin_dir")

  local content
  if [ -n "$new_hash" ]; then
    # Inspect the incoming version (not yet merged)
    content=$(git -C "$plugin_dir" show "$new_hash:.claude-plugin/audit.sh" 2>/dev/null) || return 0
  else
    local audit_script="$plugin_dir/.claude-plugin/audit.sh"
    [ -f "$audit_script" ] || return 0
    content=$(cat "$audit_script")
  fi

  [ -z "$content" ] && return 0

  # Static scan: flag dangerous patterns (excluding comments)
  # Pattern notes:
  #   - `(^|\s|;|&&|\|\|)sh ` avoids false positives like "finished" or "push"
  #   - `\$\(` catches subshell command substitution
  if echo "$content" | grep -vE '^\s*#' \
    | grep -qE '(curl |wget |fetch\(|nc |ncat |socat |\/dev\/tcp|mkfifo|base64|eval |python.* -c|ruby -e|perl -e|bash |zsh |(^|[[:space:];]|\&\&|\|\|)sh ($|-c)|source |\$\()'; then
    audit_warn "$plugin_name" "Plugin audit.sh contains suspicious commands — review recommended"
    return 1
  fi
  return 0
}

# Check claude-mem settings after update.
# Separated into its own config file for maintainability.
audit_claude_mem_settings() {
  local settings_file="$HOME/.claude-mem/settings.json"
  [ -f "$settings_file" ] || return 0

  command -v python3 &>/dev/null || return 0

  local output
  local py_exit=0
  # Capture stdout only; stderr goes to log_error via fd redirect
  output=$(python3 -c "
import json, sys

try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
except (json.JSONDecodeError, OSError) as e:
    print(f'PARSE_ERROR:{e}', file=sys.stderr)
    sys.exit(2)

warnings = []

provider = s.get('CLAUDE_MEM_PROVIDER', 'claude')
if provider not in ('claude', ''):
    warnings.append(f'Provider set to \"{provider}\" (external service)')

for key in ('CLAUDE_MEM_GEMINI_API_KEY', 'CLAUDE_MEM_OPENROUTER_API_KEY', 'CLAUDE_MEM_CHROMA_API_KEY'):
    val = s.get(key, '')
    if val:
        warnings.append(f'{key} is configured (data may be sent externally)')

chroma_mode = s.get('CLAUDE_MEM_CHROMA_MODE', 'local')
if chroma_mode != 'local':
    warnings.append(f'Chroma mode is \"{chroma_mode}\" (non-local)')

chroma_host = s.get('CLAUDE_MEM_CHROMA_HOST', '127.0.0.1')
if chroma_host not in ('127.0.0.1', 'localhost', '::1', ''):
    warnings.append(f'Chroma host is \"{chroma_host}\" (remote)')

if warnings:
    for w in warnings:
        print(w)
    sys.exit(1)
" "$settings_file" 2>/dev/null) || py_exit=$?

  if [ "$py_exit" -eq 0 ]; then
    return 0
  elif [ "$py_exit" -eq 1 ] && [ -n "$output" ]; then
    # Intentional exit: settings warnings detected
    # Use here-string instead of pipe to avoid subshell (AUDIT_HAS_WARNINGS must propagate)
    while IFS= read -r line; do
      audit_warn "claude-mem settings" "$line"
    done <<< "$output"
    return 1
  elif [ "$py_exit" -eq 2 ]; then
    # JSON parse error or file read error
    audit_warn "claude-mem settings" "Failed to parse settings file (invalid JSON or unreadable)"
    return 1
  else
    # Unexpected python3 failure (missing module, syntax error, etc.)
    audit_warn "claude-mem settings" "Settings audit crashed (python3 exit=$py_exit)"
    return 1
  fi
}

# --- Functions ---

# Must be called from within a git repository directory
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
  if [ -n "$branch" ]; then
    echo "$branch"
    return 0
  fi
  return 1
}

# Exit codes from subshell:
#   0 = success (up-to-date, no changes)
#   1 = git/network error (non-fatal)
#   2 = security audit blocked the update
#   3 = success (merged new changes)
update_plugin() {
  local plugin_dir="$1"

  [ -d "$plugin_dir/.git" ] || return 0

  # Resolve to absolute path to avoid issues after cd
  plugin_dir="$(cd "$plugin_dir" && pwd)"

  (
    cd "$plugin_dir"
    local pname
    pname=$(basename "$plugin_dir")

    local cmd_output
    if ! cmd_output=$(git fetch origin 2>&1); then
      log_error "$pname: git fetch failed"
      [ "$VERBOSE" = "1" ] && echo "$cmd_output" >&2
      exit 1
    fi
    [ "$VERBOSE" = "1" ] && [ -n "$cmd_output" ] && echo "$cmd_output" >&2

    local local_hash remote_hash default_branch
    local_hash=$(git rev-parse HEAD 2>/dev/null) || exit 1

    default_branch=$(detect_default_branch) || exit 1

    remote_hash=$(git rev-parse "origin/$default_branch" 2>/dev/null) || exit 1

    [ "$local_hash" = "$remote_hash" ] && exit 0

    log_verbose "$pname: update available $local_hash -> $remote_hash"

    # --- Security audit BEFORE merge ---
    # Audit the diff between current HEAD and the fetched remote ref.
    # No code from the update has been checked out or executed at this point.
    if ! security_audit "$plugin_dir" "$local_hash" "$remote_hash"; then
      audit_warn "$pname" "Update BLOCKED — suspicious changes between $local_hash and $remote_hash"
      exit 2
    fi

    # Static audit of plugin-provided hook (never executed, only scanned)
    # Scans the NEW (post-merge) version so newly added malicious scripts are caught
    if ! static_audit_plugin_hook "$plugin_dir" "$remote_hash"; then
      audit_warn "$pname" "Update BLOCKED — suspicious plugin audit.sh"
      exit 2
    fi

    # Audit passed — safe to merge
    if ! cmd_output=$(git merge "origin/$default_branch" 2>&1); then
      log_error "$pname: git merge failed (conflicts?) — manual resolution required"
      [ "$VERBOSE" = "1" ] && echo "$cmd_output" >&2
      # Abort the failed merge to leave worktree clean
      git merge --abort 2>/dev/null || true  # Best-effort cleanup; may fail if no merge in progress
      exit 1
    fi
    [ "$VERBOSE" = "1" ] && [ -n "$cmd_output" ] && echo "$cmd_output" >&2

    log_verbose "$pname: merged successfully"

    if [ -f "package.json" ]; then
      if command -v bun &>/dev/null; then
        if ! cmd_output=$(bun install --frozen-lockfile 2>&1); then
          log_error "$pname: bun install --frozen-lockfile failed — lockfile may be out of sync"
          [ "$VERBOSE" = "1" ] && echo "$cmd_output" >&2
        fi
      elif command -v npm &>/dev/null; then
        if ! cmd_output=$(npm ci 2>&1); then
          log_error "$pname: npm ci failed — lockfile may be out of sync"
          [ "$VERBOSE" = "1" ] && echo "$cmd_output" >&2
        fi
      fi
    fi

    exit 3  # Merged successfully
  )
}

update_registry() {
  local vendor="$1"
  local plugin_dir="$2"

  [ -f "$INSTALLED_PLUGINS" ] || return 0
  [ -d "$plugin_dir/.git" ] || return 0
  command -v python3 &>/dev/null || return 0

  # npm package names cannot contain spaces, so space-delimited read is safe
  local plugin_name version commit_sha
  read -r plugin_name version <<< "$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d['name'], d['version'])
" "$plugin_dir/package.json" 2>/dev/null)" || return 0
  commit_sha=$(git -C "$plugin_dir" rev-parse HEAD 2>/dev/null) || return 0

  local plugin_key="${plugin_name}@${vendor}"
  local cache_path="$CACHE_DIR/$vendor/$plugin_name/$version"

  # Skip if cache directory doesn't exist (avoids "Plugin directory does not exist" error)
  [ -d "$cache_path" ] || return 0
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
except Exception as e:
    print(f"Registry update failed: {e}", file=sys.stderr)
    try:
        os.remove(tmp_path)
    except OSError:
        pass
    sys.exit(1)
" "$INSTALLED_PLUGINS" "$plugin_key" "$cache_path" "$version" "$commit_sha" "$now"
}

sort_semver() {
  # Sort version directory names by semver (descending).
  # Pre-release/build metadata (-beta.1, +build123) is stripped for numeric sort.
  # Per semver spec: release (no pre-release) ranks higher than pre-release at
  # the same version. We use awk to extract major.minor.patch as tab-separated
  # numeric fields + a pre-release flag, then sort on those fields.
  { grep -E '^[0-9]+\.[0-9]+\.[0-9]+' || true; } \
    | awk -F'[-+]' '{
        split($1, v, ".");
        prerel = (NF > 1) ? 1 : 0;
        printf "%s\t%s\t%s\t%s\t%s\n", v[1], v[2], v[3], prerel, $0
      }' \
    | sort -t$'\t' -k1,1rn -k2,2rn -k3,3rn -k4,4n \
    | cut -f5
}

clean_old_caches() {
  local cache_path="$1"
  local keep="${2:-2}"  # Keep N most recent versions (default: 2 for rollback)

  [ -d "$cache_path" ] || return 0

  local count=0
  while IFS= read -r ver; do
    [ -z "$ver" ] && continue
    count=$((count + 1))
    if [ "$count" -gt "$keep" ]; then
      log_verbose "Removing old cache: $cache_path/$ver"
      rm -rf "$cache_path/$ver"
    fi
  done <<< "$(for d in "$cache_path"/*/; do [ -d "$d" ] && basename "$d"; done | sort_semver)"
}

# --- Main ---

[ -d "$MARKETPLACE_DIR" ] || exit 0

for vendor_dir in "$MARKETPLACE_DIR"/*/; do
  [ -d "$vendor_dir" ] || continue
  vendor=$(basename "$vendor_dir")

  # IMPORTANT: update_plugin uses non-zero exit codes for success (3 = merged).
  # Always capture with `|| update_result=$?` — bare calls will trigger set -e.
  update_result=0
  update_plugin "$vendor_dir" || update_result=$?

  if [ "$update_result" -eq 2 ]; then
    # Security audit blocked — propagate flag from subshell
    AUDIT_HAS_WARNINGS=1
    log_error "$vendor: update blocked by security audit"
  elif [ "$update_result" -eq 1 ]; then
    log_verbose "$vendor: update failed (git/network error)"
  fi

  # Only update registry if plugin was actually merged (exit 3)
  if [ "$update_result" -eq 3 ]; then
    update_registry "$vendor" "$vendor_dir" || log_verbose "$vendor: registry update failed"
  fi

  # Clean caches for all plugins under this vendor
  if [ -d "$CACHE_DIR/$vendor" ]; then
    for plugin_cache in "$CACHE_DIR/$vendor"/*/; do
      [ -d "$plugin_cache" ] || continue
      clean_old_caches "$plugin_cache"
    done
  fi
done

# --- Post-update security checks ---

# Check plugin-specific settings for external data exposure
audit_claude_mem_settings || true  # Warnings logged to audit file; don't block script exit

# Rotate audit logs older than 30 days (macOS/GNU find; -delete may not work on BusyBox)
find "$AUDIT_LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null || true  # Non-critical cleanup

# Report audit findings for this session
if [ "$AUDIT_HAS_WARNINGS" -eq 1 ]; then
  # Extract only this session's warnings (after the session marker) using awk
  local_warnings=$(awk -v marker="$AUDIT_SESSION_MARKER" '
    found && /^\[SECURITY\]/ { print }
    $0 == marker { found=1 }
  ' "$AUDIT_LOG")
  if [ -n "$local_warnings" ]; then
    echo
    echo "=========================================="
    echo "  PLUGIN SECURITY AUDIT WARNINGS"
    echo "=========================================="
    echo "$local_warnings"
    echo "=========================================="
    echo "Full log: $AUDIT_LOG"
    echo
  fi
fi
