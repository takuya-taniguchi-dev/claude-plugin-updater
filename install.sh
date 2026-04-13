#!/bin/bash
# Installer for claude-plugin-updater
# Copies the update script and optionally configures a SessionStart hook.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="$HOME/.claude/scripts"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "Installing claude-plugin-updater..."

# Copy script
mkdir -p "$TARGET_DIR"
cp "$SCRIPT_DIR/scripts/update-plugins.sh" "$TARGET_DIR/update-plugins.sh"
chmod +x "$TARGET_DIR/update-plugins.sh"
echo "  Copied update-plugins.sh to $TARGET_DIR/"

# Hook configuration guidance
echo ""
if [ -f "$SETTINGS_FILE" ] && grep -q "update-plugins.sh" "$SETTINGS_FILE" 2>/dev/null; then
  echo "  Hook already configured in $SETTINGS_FILE (skipped)"
else
  echo "  To auto-run on session start, add this to $SETTINGS_FILE:"
  echo ""
  cat << 'HOOK'
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOME/.claude/scripts/update-plugins.sh 2>/dev/null; exit 0",
            "timeout": 30000
          }
        ]
      }
    ]
  }
HOOK
fi

echo ""
echo "Done! Run manually:  bash ~/.claude/scripts/update-plugins.sh"
echo "See README.md for more usage options (cron, launchd, etc.)"
