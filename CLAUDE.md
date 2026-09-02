# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Two Bash scripts. `huddle-transcribe` wraps MacWhisper Pro's `mw` CLI: it
picks a meeting recording out of MacWhisper's own SQLite database, transcribes
it with speaker diarization, and writes a `.md` transcript plus a
`.meta.json` sidecar. `huddle-watch` drives it from launchd, waking on a
database change and transcribing each session that has newly become ready.

There is no build step and no package manager. The test suite is a single
Bash script, `tests/run-tests.sh`; the rest of the repo is the two scripts, a
README, a LICENSE, and the CI workflows.

## Commands

```bash
./tests/run-tests.sh                                                     # 189 behavioral tests
shellcheck -S info huddle-transcribe huddle-watch tests/run-tests.sh     # must be clean
shfmt -i 2 -ci -d huddle-transcribe huddle-watch tests/run-tests.sh      # show diff
shfmt -i 2 -ci -w huddle-transcribe huddle-watch tests/run-tests.sh      # apply formatting
```

CI runs exactly these. Run the test suite before every commit — the linters
pass on every data-loss bug this repo has had.

`shfmt -i 2 -ci` is the repo's format — plain `shfmt` defaults to tabs and
will rewrite the whole file. Always pass both flags.

`.editorconfig` encodes that same format, and it is load-bearing rather than
decorative. shfmt reads formatting options from it, and the global pre-commit
shell hook applies its own defaults (`-i 2 -ci -bn`) *only* when a repo has no
`.editorconfig`. `-bn` puts binary operators at the start of a continuation
line, which is the opposite of what CI's `shfmt -i 2 -ci` accepts — so without
this file the hook rewrites every `... &&` line ending into a leading `&&` and
CI then rejects it, on a loop no amount of reformatting escapes. Do not delete
it, and keep `binary_next_line = false` in agreement with CI's flags.

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

**The extension is `.md`, and that is a delivery constraint, not a taste
call.** Transcripts land in Google Drive, whose web viewer previews Markdown
inline but only offers a download prompt for `.txt`. `mw --format md` differs
from `--format txt` in exactly one way — the timestamp line is wrapped in
asterisks (`*00:00-00:06*` rather than `00:06`) — so switching back would
change almost no bytes while breaking the only reason the format was chosen.
The variables are `OUT_DOC`/`DOC_TMP`, deliberately not `OUT_TXT`.

`--end-timestamps` renders start-end ranges instead of a bare start. Do not
use `--format html`: `mw` emits the whole transcript body as a single
unbroken line, which defeats the line-anchored rewrite that
`docs/plans/speaker-name-attribution.md` §5.1 depends on. The speaker-label
line is byte-identical across `txt` and `md`, so that plan's anchors are
unaffected by this change.

### huddle-watch requires bash 4.2+, and launchd must be told which bash

The script uses `printf '%(...)T'` (bash 4.2+) in `log()`. macOS ships bash
3.2.57 at `/bin/bash` and never updates it, so `#!/usr/bin/env bash` resolves
to an inadequate interpreter anywhere `PATH` lacks a modern bash — which is
exactly what launchd, cron, and GUI-spawned processes provide. The original
symptom was `printf: \`(': invalid format character` then `ts: unbound
variable`, aborting before a single log line was written: invisible to the
user, invisible to CI (which runs bash 5), and reachable only through launchd.

Three pieces keep that closed, and all three are load-bearing:

- **`ProgramArguments[0]` is an absolute bash, not the script.** When argv[0]
  is an interpreter the kernel never reads the shebang, so launchd's minimal
  `PATH` cannot select the wrong bash. The path is resolved at install time
  from `$BASH` by `resolve_interpreter` — correct on Apple Silicon, Intel, and
  Linuxbrew alike, because `do_install` runs on the target machine and the
  generated plist is untracked machine-local state. Do not hardcode
  `/opt/homebrew/bin/bash`, and do not put an absolute path in the tracked
  shebang; `#!/usr/bin/env bash` is what keeps interactive and CI use portable.
- **The `BASH_VERSINFO` guard at the top** is the backstop for every other
  invocation path. It converts a cryptic mid-run abort into one actionable
  line. Keep it above the first `log()` call.
- **`do_install` boots out before bootstrapping.** `launchctl bootstrap` fails
  when the label is already loaded, and the legacy `load` fallback does not
  replace a loaded job — so a reinstall printed "Loaded" while launchd kept
  running the OLD argv. A plist corrected to name a modern bash therefore went
  on failing. `--status` reports the interpreter the *installed plist* names
  and flags a stale one, which is the check that catches this.

`tests/run-tests.sh` asserts all of it against a real `/bin/bash` 3.2 where
one exists (`skip` on Linux CI, counted separately so it is never mistaken for
coverage that ran). The guard probe uses `--once` with an already-seeded state
file: `--status` never calls `log()`, and a first `--once` returns down the
seeding path before logging, so either would pass against the broken script.

### huddle-watch state

The watcher's own state is one line per session in
`~/.local/state/huddle-transcribe/watch-state`: `<session-id> done` for a
finished session, `<session-id> <n>` for one that has failed `n` times. It is
rewritten via `mktemp` + `mv` beside itself, like every other write in this
repo.

**A first run seeds instead of transcribing.** Otherwise switching the watcher
on re-transcribes the entire backlog. The seeding gate is `[[ ! -s ]]`, not
`-f`: a zero-byte state file is what an interrupted `mv` leaves behind, so it
must be treated as never-seeded rather than as an empty seed.

That gate is why the seeded file always opens with a `#` header line. A first
run that finds nothing ready seeds zero sessions, and without the header it
would leave a zero-byte file — which the `-s` gate then reads as unseeded, so
the next run seeds the first genuinely-ready session as `done` and never
transcribes it, silently. The header keeps a completed seed non-empty while
leaving the gate's meaning intact. Every reader skips `$STATE_COMMENT` lines:
`state_status`, `--status`'s record count, and `--status`'s given-up `awk`.
`state_set` and `--retry` preserve it for free, since both rewrite by
filtering out the lines they are replacing.

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
