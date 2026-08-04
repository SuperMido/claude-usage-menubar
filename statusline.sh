#!/usr/bin/env bash
# Claude Code status line.
#   ◆ model  ⚙ effort  $cost  ▦ context  ⏱ 5h limit  ▤ 7d all-models limit  dir branch
#
# Also publishes state to ~/.claude/usage/<session_id>.json, which the macOS
# menu bar app reads. See README.md.

SHOW_DIR=1                       # 0 hides the "dir branch" segment
STATE_DIR="${CLAUDE_USAGE_DIR:-$HOME/.claude/usage}"
JQ=${JQ:-$(command -v jq || true)}

input=$(cat)

if [ -z "$JQ" ]; then
  printf '◆ jq not found — brew install jq'
  exit 0
fi

# Fields are joined with U+001F: unlike tab, bash's read does not collapse it,
# so empty values keep their position.
IFS=$'\x1f' read -r model effort fast cost ctx h5_pct h5_reset d7_pct d7_reset dir sid <<<"$(
  printf '%s' "$input" | "$JQ" -r '
    [ (.model.display_name // "?")
    , (.effort.level // "")
    , (if .fast_mode then "1" else "" end)
    , (.cost.total_cost_usd // 0)
    , (.context_window.used_percentage // "")
    , (.rate_limits.five_hour.used_percentage // "")
    , (.rate_limits.five_hour.resets_at // "")
    , (.rate_limits.seven_day.used_percentage // "")
    , (.rate_limits.seven_day.resets_at // "")
    , (.workspace.current_dir // "")
    , (.session_id // "")
    ] | map(tostring) | join("")'
)"

# ---- publish state for the menu bar app ----
if [ -n "$sid" ]; then
  mkdir -p "$STATE_DIR"
  tmp="$STATE_DIR/.$sid.tmp"
  if printf '%s' "$input" | "$JQ" -c --argjson now "$(date +%s)" '
      { session_id, session_name, updated_at: $now
      , dir: .workspace.current_dir
      , model: .model.display_name
      , effort: .effort.level
      , fast_mode: (.fast_mode // false)
      , cost_usd: (.cost.total_cost_usd // 0)
      , ctx_pct: .context_window.used_percentage
      , five_hour: .rate_limits.five_hour
      , seven_day: .rate_limits.seven_day
      }' >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$STATE_DIR/$sid.json"
  else
    rm -f "$tmp"
  fi
  # Occasionally drop state from sessions that ended days ago.
  [ $((RANDOM % 10)) -eq 0 ] && find "$STATE_DIR" -name '*.json' -mtime +2 -delete 2>/dev/null
fi

# ---- colors ----
esc=$'\033'
dim="${esc}[2m"; rst="${esc}[0m"; bold="${esc}[1m"
grey="${esc}[38;5;245m"; cyan="${esc}[38;5;117m"; mag="${esc}[38;5;176m"
green="${esc}[38;5;114m"; yellow="${esc}[38;5;221m"; red="${esc}[38;5;210m"
gap="  "                         # menu-bar style: spacing, not separators

# Green < 50% < yellow < 80% <= red
pct_color() {
  local p=${1%%.*}
  if   [ "${p:-0}" -ge 80 ]; then printf '%s' "$red"
  elif [ "${p:-0}" -ge 50 ]; then printf '%s' "$yellow"
  else printf '%s' "$green"; fi
}

round() { printf '%.0f' "${1:-0}" 2>/dev/null || printf '0'; }

# epoch seconds -> "3d 4h" / "1h48m" / "12m" / "now"
until_reset() {
  local target=${1%%.*} now diff d h m
  [ -z "$target" ] && { printf '?'; return; }
  now=$(date +%s)
  diff=$((target - now))
  [ "$diff" -le 0 ] && { printf 'now'; return; }
  d=$((diff / 86400)); h=$(((diff % 86400) / 3600)); m=$(((diff % 3600) / 60))
  if   [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

# "<icon> <label> <pct>% ↻<time>", or a dim placeholder before the first API response
limit_seg() {
  local icon=$1 label=$2 pct=$3 reset=$4 p
  if [ -z "$pct" ]; then
    printf '%s%s %s —%s' "$dim" "$icon" "$label" "$rst"; return
  fi
  p=$(round "$pct")
  printf '%s%s%s %s%s%s %s%s%%%s %s↻%s%s' \
    "$dim" "$icon" "$rst" \
    "$grey" "$label" "$rst" \
    "$(pct_color "$p")" "$p" "$rst" \
    "$dim" "$(until_reset "$reset")" "$rst"
}

# ---- segments ----
model=${model/ (1M context)/ 1M}
out="${dim}◆${rst} ${cyan}${bold}${model}${rst}"

[ -n "$effort" ] && out="${out}${gap}${dim}⚙${rst} ${mag}${effort}${rst}"
[ -n "$fast" ]   && out="${out} ${yellow}⚡${rst}"

out="${out}${gap}${grey}\$${rst}$(printf '%.2f' "${cost:-0}")"

if [ -n "$ctx" ]; then
  c=$(round "$ctx")
  out="${out}${gap}${dim}▦${rst} $(pct_color "$c")${c}%${rst}"
fi

out="${out}${gap}$(limit_seg '⏱' '5h' "$h5_pct" "$h5_reset")"
out="${out}${gap}$(limit_seg '▤' '7d' "$d7_pct" "$d7_reset")"

if [ "$SHOW_DIR" = "1" ] && [ -n "$dir" ]; then
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ ${#branch} -gt 24 ] && branch="${branch:0:23}…"
  seg="${dim}${dir##*/}${rst}"
  [ -n "$branch" ] && seg="${seg}${dim} ${branch}${rst}"
  out="${out}${gap}${seg}"
fi

printf '%s' "$out"
