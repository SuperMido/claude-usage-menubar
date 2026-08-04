#!/usr/bin/env bash
# Regression tests. No GUI needed: they drive `ClaudeUsage --dump` against fixture
# state directories and assert on what it would render.
#
#   ./tests/run.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
BIN=${BIN:-build/ClaudeUsage}
STATUSLINE=${STATUSLINE:-./statusline.sh}

if [ ! -x "$BIN" ]; then
  echo "building $BIN"
  mkdir -p build
  swiftc -O menubar/ClaudeUsage.swift -o "$BIN" -framework AppKit || exit 1
fi

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
now=$(date +%s)
pass=0 fail=0

# state <file> <json>  — write a fixture session
state() { printf '%s' "$2" >"$FIX/$1.json"; }
reset()  { rm -f "$FIX"/*.json; }

# check <name> <expected-substring> <actual>
check() {
  if printf '%s' "$3" | grep -qF -- "$2"; then
    printf '  ✓ %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  ✗ %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$(printf '%s' "$3" | head -3 | tr '\n' '|')"
    fail=$((fail + 1))
  fi
}

dump() { CLAUDE_USAGE_DIR="$FIX" "$BIN" --dump "$@" 2>&1; }

session() { # session <id> <name> <updated_at> <5h pct> <5h reset> <7d pct> <7d reset>
  cat <<JSON
{"session_id":"$1","session_name":"$2","dir":"/tmp/$1","model":"Opus 5 (1M context)",
 "effort":"high","fast_mode":false,"cost_usd":1.5,"ctx_pct":10,"updated_at":$3,
 "five_hour":{"used_percentage":$4,"resets_at":$5},
 "seven_day":{"used_percentage":$6,"resets_at":$7}}
JSON
}

echo "menu bar app"

reset
out=$(dump --mode text)
check "no sessions -> em dash"        "✻ —"                          "$out"
check "no sessions -> explains why"   "No active Claude Code session" "$out"

reset
state a "$(session a "work" "$now" 10 "$((now + 1350))" 2 "$((now + 268000))")"
out=$(dump --mode text)
check "text mode: pct then reset"     "✻ 10% 22m  2% 3d 2h"          "$out"
check "dropdown: 5h line"             "5-hour session   10%"         "$out"
check "dropdown: 7d line"             "7-day, all models   2%"       "$out"

out=$(dump --mode bar)
check "bar mode: draws fills"         "█"                            "$out"
check "bar mode: pct after bar"       "10% 2%"                       "$out"
check "bar mode: labels the rows"     "top row = 5h"                 "$out"

reset
state a "$(session a "old" "$now" 77 "$((now - 120))" 85 "$((now + 200000))")"
out=$(dump --mode text)
check "expired window is not shown"   "window rolled over"           "$out"
check "expired window drops the pct"  "✻ 85%"                        "$out"

# An idle session keeps reporting its old window; the live one must win.
reset
state idle "$(session idle "idle" "$now" 9 "$((now - 60))" 2 "$((now + 268000))")"
state live "$(session live "live" "$((now - 5))" 31 "$((now + 9000))" 2 "$((now + 268000))")"
out=$(dump --mode text)
check "newest window wins"            "5-hour session   31%"         "$out"
check "both sessions listed"          "SESSIONS (2)"                 "$out"
check "costs are totalled"            "\$3.00   total"               "$out"

reset
state a "$(session a "stale" "$((now - 28800))" 40 "$((now + 3600))" 20 "$((now + 200000))")"
out=$(dump --mode text)
check "stale data is flagged"         "may be out of date"           "$out"
check "stale data leaves title bare"  "✻ —"                          "$out"

echo
echo "status line"

payload() {
  cat <<JSON
{"session_id":"sl-test","session_name":"t","cwd":"/tmp",
 "model":{"display_name":"Opus 5 (1M context)"},"effort":{"level":"high"},"fast_mode":false,
 "cost":{"total_cost_usd":2.5},"context_window":{"used_percentage":34},
 "workspace":{"current_dir":"/tmp"},
 "rate_limits":{"five_hour":{"used_percentage":62,"resets_at":$((now + 6510))},
                "seven_day":{"used_percentage":41,"resets_at":$((now + 361000))}}}
JSON
}

out=$(payload | CLAUDE_USAGE_DIR="$FIX" $STATUSLINE)
plain=$(printf '%s' "$out" | perl -pe 's/\e\[[0-9;]*m//g')
check "renders model, shortened"      "◆ Opus 5 1M"                  "$plain"
check "renders effort"                "⚙ high"                       "$plain"
check "renders cost"                  "\$2.50"                       "$plain"
check "renders context"               "▦ 34%"                        "$plain"
check "renders 5h limit + reset"      "⏱ 5h 62% ↻1h48m"              "$plain"
check "renders 7d limit + reset"      "▤ 7d 41% ↻4d 4h"              "$plain"
check "publishes state for menu bar"  "sl-test"                      "$(ls "$FIX")"

# Empty fields must keep their position (tab would collapse them).
out=$(echo '{"session_id":"x","model":{"display_name":"Sonnet 5"},"cost":{"total_cost_usd":0}}' \
      | CLAUDE_USAGE_DIR="$FIX" $STATUSLINE)
plain=$(printf '%s' "$out" | perl -pe 's/\e\[[0-9;]*m//g')
check "missing limits -> placeholder" "⏱ 5h —"                       "$plain"
check "no effort field -> no gear"    "◆ Sonnet 5  \$0.00"           "$plain"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
