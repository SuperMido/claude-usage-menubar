# Contributing

Small project, informal process — but a couple of habits keep it pleasant to share.

## Workflow

```sh
git checkout -b my-change
make test                    # before you start, so you know it was green
# ... edit ...
make test                    # and after
make install                 # try it on your own menu bar
git commit -am "..." && git push -u origin my-change
```

Then open a pull request. Anything that changes rendering, please paste the
`--dump` output (and `--png` for bar changes) in the PR — it's the cheapest way for the
other person to see what you saw without installing your branch.

## Ground rules

- **Add a test for behavior.** `tests/run.sh` needs no GUI and runs in a couple of
  seconds, so there's no excuse. Assert on `--dump` output against fixture state.
- **Don't trust one session's rate-limit data.** See the aggregation note in the README:
  idle sessions report expired windows. If you touch `Snapshot`, keep the
  "newest window wins" test passing.
- **Keep it dependency-free.** No Homebrew packages, no SwiftPM, no menu-bar host like
  SwiftBar. `jq` + `swiftc` is the whole toolchain, and `install.sh` should stay a
  single command.
- **Watch for time-boundary flakiness in tests.** Fixtures built from `date +%s` can tip
  over a minute boundary between setup and assertion; offsets carry ~30s of slack for
  that reason.
- **Never assume the payload shape.** It isn't a documented API. Capture a real one
  before relying on a field:
  ```sh
  # temporarily, at the top of statusline.sh
  printf '%s' "$input" > /tmp/payload.json
  ```

## Things worth building next

Roughly easiest first:

- **Configurable thresholds and colors** — the 50/80 cutoffs and the blue/purple identity
  colors are hardcoded; move them into `config.json` alongside `display`.
- **Threshold notifications** — a native notification at 80% of the 5-hour window, so you
  find out before Claude Code stops mid-task. Needs debouncing so it fires once per window.
- **Cost budget** — a monthly or weekly target, with the dropdown showing progress toward it.
  Costs are already summed across sessions.
- **Click a session to focus its terminal** — the state files carry `dir` and
  `session_id`; jumping to the right window is the obvious follow-on.
- **Usage history** — append a snapshot every refresh and draw a sparkline of the last 24h
  in the dropdown. The state files are already timestamped.
- **A Linux/tmux port of the status line** — `statusline.sh` is portable already
  (`--no-menubar` installs just it); a tmux segment reading the same state files would be
  a natural companion.
- **Per-model weekly bars** — blocked today: `seven_day_opus` / `seven_day_sonnet` are not
  in the statusLine payload. If a future Claude Code version passes them through, this
  becomes a small change to `Snapshot` and `Render`.

## Verifying without a screenshot

Terminals generally can't capture the screen without Screen Recording permission, so the
app is built to describe itself: `--dump` prints the rendered text, `--png` draws the bar
to a file magnified 12×, and both accept `CLAUDE_USAGE_DIR` for fixtures. Reach for those
before reaching for a screenshot.
