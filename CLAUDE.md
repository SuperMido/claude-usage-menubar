# Notes for Claude Code

## Build, install, verify

```sh
make build     # swiftc -O menubar/ClaudeUsage.swift -o build/ClaudeUsage -framework AppKit
make test      # tests/run.sh — 24 assertions, no GUI required
make install   # ./install.sh — copies into ~/.claude, restarts the LaunchAgent
```

Run `make test` after any change to `statusline.sh` or `menubar/ClaudeUsage.swift`.

## Verifying UI changes — do not try to screenshot

`screencapture` fails in this environment ("could not create image from display") because
the terminal lacks Screen Recording permission. Use the app's own output instead:

```sh
build/ClaudeUsage --dump                            # rendered text + dropdown
build/ClaudeUsage --dump --mode bar                 # force text|bar
build/ClaudeUsage --png /tmp/bar.png --pct 88,64    # draw the bar, magnified 12×
```

Then `Read` the PNG. Both honor `CLAUDE_USAGE_DIR=<dir>` for fixture state, which is how
`tests/run.sh` reaches the empty / expired / stale / multi-session branches.

## Architecture in one paragraph

Claude Code pipes a JSON payload to the `statusLine` command on every render.
`statusline.sh` renders the terminal line from it and also writes
`~/.claude/usage/<session_id>.json`. The Swift app polls that directory every 15s
(and on `menuWillOpen`), aggregates the rate limits, and draws the menu bar item.
`Render` and `Snapshot` are pure and AppKit-free apart from `NSColor`, so `--dump`
exercises the same code the GUI does.

## Things that have bitten before

- **`IFS=$'\t' read` collapses empty fields**, because tab is IFS whitespace — the field
  values silently shift by one. `statusline.sh` joins with `U+001F` instead. Don't
  "simplify" it back to `@tsv`.
- **An idle session reports an expired rate-limit window.** `updated_at` is when the status
  line last *rendered*, not when the session last hit the API. `Snapshot.best()` picks the
  largest `(resetsAt, pct)` and drops expired windows; the "newest window wins" test guards it.
- **Tiny fills look like dots.** In bar mode, fills are square-cut and clipped to the
  rounded track for that reason; rounding each fill turned 2% into a circle.
- **Test fixtures can tip over a minute boundary** between `date +%s` and the assertion.
  Offsets carry ~30s of slack.
- **The payload is not a documented API.** Verified against Claude Code 2.1.221. To check a
  field, capture a real payload rather than guessing:
  `printf '%s' "$input" > /tmp/payload.json` at the top of `statusline.sh`.

## Known data limitation

Only `rate_limits.five_hour` and `rate_limits.seven_day` reach a statusLine command.
`seven_day_opus` / `seven_day_sonnet` exist internally but are only surfaced in `/usage`,
so a per-model weekly bar cannot be built from this data. Don't promise one.
