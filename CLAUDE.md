# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Bash script, `huddle-transcribe`, that wraps MacWhisper Pro's `mw`
CLI. It picks a meeting recording out of MacWhisper's own SQLite database,
transcribes it with speaker diarization, and writes a `.txt` transcript plus a
`.meta.json` sidecar. There is no build step, no package manager, and no test
suite — the repo is the script, a README, a LICENSE, and the CI workflows.

## Commands

```bash
./tests/run-tests.sh                                        # 51 behavioral tests
shellcheck -S info huddle-transcribe tests/run-tests.sh     # must be clean
shfmt -i 2 -ci -d huddle-transcribe tests/run-tests.sh      # show diff
shfmt -i 2 -ci -w huddle-transcribe tests/run-tests.sh      # apply formatting
```

CI runs exactly these. Run the test suite before every commit — the linters
pass on every data-loss bug this repo has had.

`shfmt -i 2 -ci` is the repo's format — plain `shfmt` defaults to tabs and
will rewrite the whole file. Always pass both flags.

Exercising the script:

```bash
./huddle-transcribe --list       # read-only; lists 10 most recent sessions
./huddle-transcribe --dry-run    # resolves and prints selection, transcribes nothing
```

`--list` and `--dry-run` are the safe paths and the ones to reach for when
verifying a change; `--dry-run` is honored even alongside `--mark-reviewed`.
Any invocation without them runs a real transcription, and `--mark-reviewed`
**removes the source `.m4a`** — never run it to test something.

`tests/run-tests.sh` does exactly this: it builds a synthetic SQLite DB with
the four tables the query touches (`session`, `recordedmeeting`,
`systemaudiorecording`, `mediafile`) plus a stub `mw`, then repoints
`DB`/`MEDIA_DIR`/`MW_BIN`/`CONFIG_FILE` in a copy of the script. Add a case
there for any behavior change; the fixture is cheap to extend.

## Runtime dependencies are not present in every checkout

The script hard-requires `/usr/local/bin/mw` (path is not configurable) and
`~/Library/Application Support/MacWhisper/Database/main.sqlite`. On a machine
without MacWhisper Pro installed, both are missing and the script exits early
with a specific error for each. It also checks for `sqlite3` and `jq` up
front.

The test suite needs none of that. Verify MacWhisper's presence before
claiming a change was tested against real data; otherwise run the suite and
say so. The one thing nothing here covers is the real `mw` binary's flag
handling.

The script deliberately shells out only to POSIX-portable utilities —
notably it does **not** call `date(1)`, because `date -j` is BSD-only and
`date -d` is GNU-only. Date validation is pure bash arithmetic. Keep it that
way so the suite runs on a Linux CI runner.

## Architecture

Single-pass flow, top to bottom: parse args → build the session list from
SQLite → select one session → resolve its audio file → confirm → shell out to
`mw` → write the sidecar.

**`SESSION_QUERY` is the spine.** One SQL string defines a fixed 7-column
row: `session_id, dateCreated, duration, merged_filename,
app_audio_filename, mic_audio_filename, title`. Every selection path
(`--list`, latest, by-date, by-id) runs that same query, and all three
consumers read it with `IFS="$SEP" read -r`. Changing the SELECT list means
updating every one of those readers.

Two properties of that row are load-bearing and easy to undo by accident:

- **The separator is `$SEP` (0x1F), not a tab.** Tab is IFS whitespace, so
  `IFS=$'\t' read` collapses runs of consecutive tabs and shifts every later
  field whenever a column is empty — the normal case, since a session
  usually has only one of the three media types. Do not "simplify" this
  back to a tab.
- **The title is selected last and scrubbed of tab/CR/LF in SQL.** It is the
  only free-text field, so it sits where a stray control character can only
  truncate the title rather than displace a filename column and send
  `SOURCE_PATH` at a fragment of a name.

Notable details of the query: session IDs are `lower(hex(s.id))` — bare hex,
no dashes, so `find_session_by_id` strips dashes from its argument before
prefix-matching (a UUID copied from MacWhisper's UI is dashed and would
otherwise never match) and rejects anything non-hex. Title and duration are `COALESCE` chains across
`session`, `recordedmeeting`, and `systemaudiorecording`, because MacWhisper
populates different tables depending on how a recording was captured. The
`WHERE` clause filters on `MIN_DURATION_SECONDS` (300) to drop stray short
recordings.

**Audio source preference** is merged multitrack → app/system audio → mic
audio, resolved from the three filename columns after selection.

**Date selection matches the calendar date, not a timestamp distance.**
`find_session_by_date` compares the `YYYY-MM-DD` prefix of each row's
`dateCreated` against the target. An earlier version anchored the target at
08:00 America/Los_Angeles while parsing rows as UTC and allowed a 16h
half-width window; the mixed zones meant a session stored at 00:30 matched
both that day and the one before. Prefix comparison is exact, needs no
window, and matches what `--list` prints. It re-looks-up the winner via
`find_session_by_id` rather than reusing the row it read; preserve that
indirection.

**The sidecar is the state.** `reviewed` and `deleted_source` live only in
`<basename>.meta.json`; nothing is written back to MacWhisper's database. The
script only ever reads that database. Both the transcript and the sidecar are
written to a temp path beside the target and `mv`d into place, so an
interrupted run cannot clobber a good file — `mktemp` beside the target, not
in `$TMPDIR`, keeps that rename atomic when `OUTPUT_DIR` is on another
volume.

**Output naming** is `YYYY-MM-DD_<slugified-title>_<8-hex-session-id>`. The
id suffix is what keeps two same-day sessions with colliding slugs from
overwriting each other — and, because `--mark-reviewed` finds its sidecar by
that same basename, it is also what stops the delete path from acting on a
different session's sidecar. Do not drop it.

## Configuration

`~/.config/huddle-transcribe/config` is *parsed* with `sed`, not sourced —
only a single `OUTPUT_DIR=` line is honored. This is deliberate: the file
cannot execute shell code. Do not "fix" it by switching to `source`.
Precedence is `--output-dir` > config file > `~/Documents/huddle-transcripts`.

## CI

`lint.yml` runs shellcheck, shfmt, an exec-bit check, `--help`, and the
behavioral suite on every PR, with both tools pinned by version and SHA so
CI and local dev agree.

The other three workflows are thin caller stubs for reusable workflows in
`smartwatermelon/github-workflows`. Read the header comment in
`dependabot-auto-merge.yml` before editing it — it documents several things
that must NOT be added to that file (`secrets: inherit`, `actions/checkout`)
and why.

**A PR that touches `.github/workflows/` gets no Claude review.**
`claude-code-action` refuses to run against a PR that modifies its own
workflow, so `claude-blocking-review` reports a green SKIP having reviewed
nothing. The step log names the real reason ("workflow-self-modification").
Treat a green blocking-review on a workflow-touching PR as "did not run",
and get the diff reviewed another way — a local adversarial-reviewer pass
over the committed diff is what caught the last round of defects here.

The reusable workflows are tracked on floating tags (`@v3`,
`@dependabot-auto-merge-v1`) rather than exact versions, deliberately, so
security fixes arrive without a Dependabot round-trip. See the comment in
`claude-blocking-review.yml` for the incident behind that choice; do not
"harden" it back to an exact pin without reading it first.

## The destructive path

`--mark-reviewed` is the only irreversible operation. It removes the source
audio (via `trash(1)` where available, else `rm -f`) and is fenced by four
checks, each of which exists because its absence was a reproducible
data-loss bug:

1. a sidecar must exist for the resolved session;
2. that sidecar's `session_id` must equal the resolved `$SID`;
3. the transcript must exist and be non-empty;
4. `--dry-run` is honored *before* this block runs.

Check 4 is ordering-sensitive: the `$DRY_RUN` early-exit must stay above the
`--mark-reviewed` block. When it sat below, `--dry-run --mark-reviewed`
deleted the audio.

The sidecar is written only after the audio is confirmed gone, so a failed
removal cannot leave `deleted_source: true` behind.

## Known state

`shellcheck -S info`, `shfmt -i 2 -ci -d`, and `bash -n` are all clean, and
CI enforces all three. There are no `# shellcheck disable` directives and
none should be added.
