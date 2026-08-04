#!/usr/bin/env bash
# Remove the menu bar app and its LaunchAgent.
#
#   ./uninstall.sh          menu bar app, LaunchAgent, published state
#   ./uninstall.sh --all    also remove the status line and its settings.json entry

set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
LABEL="com.claude-code.usage-menubar"
LEGACY_LABELS=("com.hqtran.claude-usage")

ALL=0
[ "${1:-}" = "--all" ] && ALL=1

say()  { printf '  %s\n' "$*"; }
step() { printf '\n▸ %s\n' "$*"; }

step "Stopping the menu bar app"
for label in "$LABEL" "${LEGACY_LABELS[@]}"; do
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null && say "stopped $label" || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done

step "Removing files"
rm -rf "$CLAUDE_DIR/menubar" "$CLAUDE_DIR/usage"
say "$CLAUDE_DIR/menubar"
say "$CLAUDE_DIR/usage"

if [ "$ALL" = 1 ]; then
  step "Removing the status line"
  rm -f "$CLAUDE_DIR/statusline.sh"
  say "$CLAUDE_DIR/statusline.sh"
  if [ -f "$SETTINGS" ] && command -v jq >/dev/null; then
    backup="$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS" "$backup"
    tmp=$(mktemp)
    jq 'del(.statusLine)' "$SETTINGS" >"$tmp" && mv "$tmp" "$SETTINGS"
    say "removed statusLine from settings.json (backup: $backup)"
  fi
else
  say ""
  say "Status line left in place. Use --all to remove it too."
fi

step "Done"
