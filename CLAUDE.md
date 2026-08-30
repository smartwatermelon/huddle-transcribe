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
shellcheck -S info huddle-transcribe   # must be clean before commit
shfmt -i 2 -ci -d huddle-transcribe    # show formatting diff
shfmt -i 2 -ci -w huddle-transcribe    # apply formatting
```

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

There is no test suite, but the script is testable without MacWhisper: build
a synthetic SQLite DB with the four tables the query touches (`session`,
`recordedmeeting`, `systemaudiorecording`, `mediafile`), a stub `mw` on
`$PATH`, and repoint `DB`/`MEDIA_DIR`/`MW_BIN`/`CONFIG_FILE` in a copy of
the script. That is how the current behavior was verified.

## Runtime dependencies are not present in every checkout

The script hard-requires `/usr/local/bin/mw` (path is not configurable) and
`~/Library/Application Support/MacWhisper/Database/main.sqlite`. On a machine
without MacWhisper Pro installed, both are missing and the script exits early
with a specific error for each. It also checks for `sqlite3` and `jq` up
front.

Verify their presence before claiming a change was tested against real data;
when they are absent, use the synthetic-DB harness described above and say
which parts were exercised that way.

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

**Date selection walks the whole list.** `find_session_by_date` converts the
target to 8:00 AM `America/Los_Angeles`, converts each row's `dateCreated` as
UTC, and keeps the smallest absolute difference — then rejects the winner if
it falls outside `DATE_MATCH_WINDOW` (16h either side of the anchor). Without
that bound, a date with no recording silently resolved to the nearest session
months away and presented it as a match. It re-looks-up the winner via
`find_session_by_id` with the bare hex id rather than reusing the row it
already read; preserve that indirection.

Note the asymmetry worth knowing: the anchor is Pacific, row timestamps are
parsed as UTC. That assumes MacWhisper stores `dateCreated` in UTC, which is
unverified — it matters only for meetings near midnight.

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

`lint.yml` runs shellcheck, shfmt, an exec-bit check, and `--help` on every
PR, with both tools pinned by version and SHA so CI and local dev agree.
The other three workflows are thin caller stubs for reusable workflows in
`smartwatermelon/github-workflows`. Read the header comment in
`dependabot-auto-merge.yml` before editing it — it documents several things
that must NOT be added to that file (`secrets: inherit`, `actions/checkout`)
and why.

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
