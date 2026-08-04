#!/usr/bin/env bash
# Install the Claude Code status line and (on macOS) the usage menu bar app.
#
#   ./install.sh                 status line + menu bar app
#   ./install.sh --no-menubar    status line only (works on Linux too)
#   ./install.sh --no-settings   don't touch settings.json
#   ./install.sh --force         overwrite an existing statusLine setting
#
# Everything it installs is listed by ./uninstall.sh.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MENUBAR_DIR="$CLAUDE_DIR/menubar"
SETTINGS="$CLAUDE_DIR/settings.json"

LABEL="com.claude-code.usage-menubar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# Earlier personal installs used a different label; migrate them.
LEGACY_LABELS=("com.hqtran.claude-usage")

DO_MENUBAR=1 DO_SETTINGS=1 FORCE=0
for arg in "$@"; do
  case "$arg" in
    --no-menubar)  DO_MENUBAR=0 ;;
    --no-settings) DO_SETTINGS=0 ;;
    --force)       FORCE=1 ;;
    -h|--help)     sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '  %s\n' "$*"; }
step() { printf '\n▸ %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || DO_MENUBAR=0

step "Checking dependencies"
command -v jq >/dev/null || die "jq is required — install it (macOS: brew install jq)"
say "jq        $(command -v jq)"
if [ "$DO_MENUBAR" = 1 ]; then
  command -v swiftc >/dev/null || die "swiftc is required for the menu bar app — install Xcode Command Line Tools (xcode-select --install), or use --no-menubar"
  say "swiftc    $(command -v swiftc)"
fi

step "Installing the status line"
mkdir -p "$CLAUDE_DIR"
install -m 755 "$REPO_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
say "$CLAUDE_DIR/statusline.sh"

if [ "$DO_SETTINGS" = 1 ]; then
  step "Wiring it into settings.json"
  desired_cmd="$CLAUDE_DIR/statusline.sh"
  [ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"

  existing=$(jq -r '.statusLine.command // ""' "$SETTINGS")
  if [ -n "$existing" ] && [ "$existing" != "$desired_cmd" ] && [ "$FORCE" != 1 ]; then
    say "settings.json already has a statusLine: $existing"
    say "left it alone — re-run with --force to replace it"
  else
    backup="$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS" "$backup"
    tmp=$(mktemp)
    jq --arg cmd "$desired_cmd" \
       '.statusLine = {type: "command", command: $cmd, padding: 0, refreshInterval: 30}' \
       "$SETTINGS" >"$tmp" && mv "$tmp" "$SETTINGS"
    say "statusLine -> $desired_cmd"
    say "backup     $backup"
  fi
fi

if [ "$DO_MENUBAR" = 1 ]; then
  step "Building the menu bar app"
  mkdir -p "$REPO_DIR/build"
  swiftc -O "$REPO_DIR/menubar/ClaudeUsage.swift" -o "$REPO_DIR/build/ClaudeUsage" -framework AppKit
  say "build/ClaudeUsage"

  step "Installing the menu bar app"
  # Stop anything running before replacing the binary it is executing.
  for legacy in "${LEGACY_LABELS[@]}"; do
    if launchctl print "gui/$(id -u)/$legacy" >/dev/null 2>&1; then
      launchctl bootout "gui/$(id -u)/$legacy" 2>/dev/null || true
      say "removed legacy agent $legacy"
    fi
    rm -f "$HOME/Library/LaunchAgents/$legacy.plist"
  done
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

  mkdir -p "$MENUBAR_DIR"
  install -m 755 "$REPO_DIR/build/ClaudeUsage" "$MENUBAR_DIR/ClaudeUsage"
  say "$MENUBAR_DIR/ClaudeUsage"

  step "Starting it at login"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat >"$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$MENUBAR_DIR/ClaudeUsage</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Restart if it crashes, but let "Quit" in the dropdown actually stick:
         a clean exit 0 is not relaunched. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/tmp/claude-usage.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-usage.log</string>
</dict>
</plist>
PLIST_EOF
  plutil -lint "$PLIST" >/dev/null
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  say "$PLIST"
fi

step "Done"
if [ "$DO_MENUBAR" = 1 ]; then
  say "Look at your menu bar — you should see the usage item near the clock."
  say "Click it to switch between percent and progress-bar display."
  say "It shows — until a Claude Code session reports; limits come from API response headers."
else
  say "Status line installed. Open a new Claude Code session to see it."
fi
