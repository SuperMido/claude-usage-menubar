# Claude Code usage — status line + macOS menu bar

See what Claude Code is costing you and how close you are to your rate limits, in the
terminal *and* in the macOS menu bar.

```
◆ Opus 5 1M  ⚙ high  $14.84  ▦ 24%  ⏱ 5h 9% ↻24m  ▤ 7d 2% ↻3d 2h  my-repo main
```
<sub>model · effort · session cost · context used · 5-hour limit · 7-day limit · repo</sub>

And in the menu bar, next to your clock — two modes, switchable from the dropdown:

```
✻ 11% 13m  2% 3d 2h          percent + time-to-reset

▐██░░░░░░░░▌ 11% 2%          progress bar: 5h on top (blue),
▐█░░░░░░░░░▌                 7d below (purple), one track
```

Click it for the details:

```
MODEL
  Opus 5 (1M context) · high effort
USAGE LIMITS
  5-hour session      11%   resets in 13m
  7-day, all models    2%   resets in 3d 2h
SESSIONS (3)
  $4.77    Add status line with model and usage info      ctx 12%
  $17.88   Dynamically calculate resource quota…          ctx 25%
  $14.84   Fix fsGroup and missing dependencies…          ctx 24%
  $37.50   total
  Updated 5s ago
DISPLAY
  ✓ Percent + reset time
    Progress bar
```

## Install

Requires `jq`, plus Xcode Command Line Tools for the menu bar app
(`brew install jq`, `xcode-select --install`).

```sh
git clone https://github.com/SuperMido/claude-usage-menubar.git
cd claude-usage-menubar
./install.sh
```

That installs the status line to `~/.claude/statusline.sh`, points
`~/.claude/settings.json` at it (backing the file up first, and refusing to clobber an
existing `statusLine` unless you pass `--force`), builds the menu bar app into
`~/.claude/menubar/`, and registers a LaunchAgent so it starts at login.

```sh
./install.sh --no-menubar     # status line only — works on Linux too
./install.sh --no-settings    # don't touch settings.json
./uninstall.sh                # remove the menu bar app
./uninstall.sh --all          # also remove the status line
```

## How it works

Claude Code runs a `statusLine` command on every render, piping it a JSON blob about
the session. This project reads that blob twice: once to draw the terminal line, once
to publish a small state file the menu bar app can poll.

```
Claude Code ──(statusLine hook, JSON on stdin)──▶ ~/.claude/statusline.sh
                                                        │
                                    renders the terminal status line
                                                        │
                                    writes ~/.claude/usage/<session_id>.json
                                                        │
                                                        ▼
                                          ClaudeUsage  (polls every 15s)
                                                        │
                                                        ▼
                                             ✻ 11% 13m  2% 3d 2h
```

`refreshInterval: 30` in the settings block keeps the countdowns ticking while you sit idle.

### Aggregating across sessions

Rate limits are account-wide, but each session only knows what it saw on **its own** last
API response — so an idle session keeps reporting a window that has already expired. The
app therefore aggregates across every session file and takes the largest
`(resets_at, used_percentage)`: windows roll forward, and within one window usage only
grows. An expired window shows `—`, never a number that is no longer true.

### Colors

Percentages are green below 50%, yellow below 80%, red at or above. In bar mode the
fills keep identity colors — blue for 5h, purple for 7d — so each number ties to its
row; the numbers still switch to yellow/red past the thresholds. The track uses
`labelColor` at low alpha, so it adapts to a light or dark menu bar.

## What the data can and can't tell you

- **No Opus-specific weekly bar.** The statusLine payload exposes only
  `rate_limits.five_hour` and `rate_limits.seven_day`. `seven_day_opus` /
  `seven_day_sonnet` exist inside Claude Code but are **not** passed to statusLine
  commands — only `/usage` sees them. The `7d` here is the all-models weekly limit.
- **Nothing until the first API response.** The numbers come from
  `anthropic-ratelimit-unified-*` response headers, so a new session shows `—` until
  its first message.
- **The menu bar goes quiet when Claude Code isn't running.** Nothing refreshes the state
  files, so after 6h the title falls back to `—`, and after 24h sessions are ignored.

Verified against Claude Code **2.1.221**. The payload shape is not a documented API, so a
future version could rename fields; `--dump` (below) is the fastest way to check.

## Development

```sh
make build     # compile to build/ClaudeUsage
make test      # 24 assertions, no GUI needed
make install   # build + install + restart the LaunchAgent
```

You cannot screenshot the menu bar from a terminal without Screen Recording permission,
so the app renders itself two other ways instead:

```sh
build/ClaudeUsage --dump                    # what it would show, as text
build/ClaudeUsage --dump --mode bar         # force a mode
build/ClaudeUsage --png /tmp/bar.png        # draw the bar, magnified 12×
build/ClaudeUsage --png /tmp/bar.png --pct 88,64   # with made-up values
```

Both honor `CLAUDE_USAGE_DIR`, so you can point them at fixture state instead of your
real sessions — which is exactly what `tests/run.sh` does.

| Path | Role |
|---|---|
| `statusline.sh` | Terminal status line; publishes state |
| `menubar/ClaudeUsage.swift` | Menu bar app (AppKit, no dependencies) |
| `install.sh` / `uninstall.sh` | Setup and teardown |
| `tests/run.sh` | Regression tests |

See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and a list of things worth building next.

## License

MIT — see [LICENSE](LICENSE).
