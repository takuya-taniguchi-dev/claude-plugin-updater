# claude-plugin-updater

Auto-update [Claude Code](https://docs.anthropic.com/en/docs/claude-code) marketplace plugins and clean up stale cache versions.

## Problem

Claude Code caches plugin versions in `~/.claude/plugins/cache/`. When a plugin is updated, old cached versions remain and can conflict with newer ones, causing `SessionStart:startup hook error` on launch.

This tool:
- Updates marketplace plugins to their latest version (`git pull` + dependency install)
- Removes outdated cache directories (keeps only the latest)

## Compatibility

| Platform | Status |
|----------|--------|
| macOS | Supported |
| Linux | Supported |
| Windows (WSL) | Supported |
| Windows (native) | Not supported |

## Install

```bash
git clone https://github.com/takuya-taniguchi-dev/claude-plugin-updater.git
cd claude-plugin-updater
bash install.sh
```

The installer copies `update-plugins.sh` to `~/.claude/scripts/` and prints hook configuration instructions.

## Usage

### Manual

```bash
bash ~/.claude/scripts/update-plugins.sh
```

### Claude Code SessionStart Hook

Add to `~/.claude/settings.json`:

```json
{
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
}
```

> **Note**: If `settings.json` already has other entries, merge the `hooks` section into the existing object.

### Cron (periodic background update)

```bash
# Update every 6 hours
(crontab -l 2>/dev/null; echo "0 */6 * * * bash \$HOME/.claude/scripts/update-plugins.sh >/dev/null 2>&1") | crontab -
```

### launchd (macOS)

Create `~/Library/LaunchAgents/com.claude.plugin-updater.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.plugin-updater</string>
    <key>ProgramArguments</key>
    <array>
        <string>bash</string>
        <!-- Replace YOUR_USERNAME with your actual username -->
        <string>/Users/YOUR_USERNAME/.claude/scripts/update-plugins.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>21600</integer>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.claude.plugin-updater.plist
```

### systemd (Linux)

Create `~/.config/systemd/user/claude-plugin-updater.service`:

```ini
[Unit]
Description=Claude Code Plugin Updater

[Service]
Type=oneshot
ExecStart=bash %h/.claude/scripts/update-plugins.sh
```

Create `~/.config/systemd/user/claude-plugin-updater.timer`:

```ini
[Unit]
Description=Run Claude Plugin Updater every 6 hours

[Timer]
OnCalendar=*-*-* 0/6:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl --user enable --now claude-plugin-updater.timer
```

## How It Works

1. Scans `~/.claude/plugins/marketplaces/` for git-managed plugins
2. Runs `git fetch` to check for updates (skips if offline)
3. If updates are available, pulls the latest changes and installs dependencies
4. Updates `~/.claude/plugins/installed_plugins.json` to point to the new version
5. Scans `~/.claude/plugins/cache/` and removes all but the latest version (semver sorted)

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `CLAUDE_PLUGINS_DIR` | `~/.claude/plugins` | Override the plugins directory path |

## Security

- The script only operates on files within `~/.claude/plugins/`
- No network requests are made beyond `git fetch` and `git pull` to existing remote origins
- Dependency installation uses lockfile-first (`--frozen-lockfile` / `npm ci`) to prevent supply chain attacks from modifying resolved versions
- All network failures are silently ignored (safe for offline use)

## License

[MIT](LICENSE)
