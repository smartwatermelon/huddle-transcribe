# huddle-transcribe

Selects, transcribes, and diarizes MacWhisper meeting recordings from the
command line, using the `mw` CLI. Output is a plain-text transcript with
generic speaker labels (`Speaker 1`, `Speaker 2`, ...) ready for a follow-up
pass that attributes names.

## Background

MacWhisper Pro, with speaker detection enabled, provides on-device
diarization via CoreML/ANE — no Python, no GPU load, no external services.
This script wraps the `mw` CLI to automate the day-to-day workflow: pick a
recorded session from MacWhisper's own database, transcribe it, and write a
transcript plus a metadata sidecar to a target directory.

## Prerequisites

- MacWhisper Pro licensed, with speaker detection enabled in Settings
- `mw` CLI installed (tested against v14.7.1) and on `PATH` or at
  `/usr/local/bin/mw`
- `sqlite3` and `jq` (both ship with macOS / Homebrew)

## Installation

```bash
git clone git@github.com:smartwatermelon/huddle-transcribe.git
ln -s "$(pwd)/huddle-transcribe/huddle-transcribe" ~/.local/bin/huddle-transcribe
ln -s "$(pwd)/huddle-transcribe/huddle-watch" ~/.local/bin/huddle-watch
```

Ensure `~/.local/bin` is on your `PATH`.

## Usage

```
huddle-transcribe [OPTIONS] [SESSION_ID_OR_DATE]
```

### Arguments

- `SESSION_ID_OR_DATE` — optional. If omitted, uses the most recent
  MacWhisper session.
  - `latest` (default)
  - `YYYY-MM-DD` — a session recorded on that calendar date. A date with no
    recording is an error, not a silent jump to the nearest session. If a
    day holds several sessions, the most recent is used and the others are
    reported.
  - a MacWhisper session UUID, dashed or bare hex, or an unambiguous prefix
    of one. An ambiguous prefix is an error listing the matches, rather
    than a guess.

### Options

```
--dry-run                Show which session would be selected; changes nothing
--list                   List recent qualifying MacWhisper sessions with metadata
--mark-reviewed          Set reviewed=true and remove the source .m4a for the
                         selected session
--yes                    Skip confirmation prompt
--output-dir PATH        Override the configured output directory
-h, --help               Show usage
```

### Examples

```bash
# Transcribe the most recent session
huddle-transcribe

# Confirm session selection without transcribing
huddle-transcribe --dry-run

# Transcribe the session closest to a specific date
huddle-transcribe 2026-08-27

# List recent sessions
huddle-transcribe --list

# Confirm what --mark-reviewed would act on, without touching anything
huddle-transcribe --dry-run --mark-reviewed 2026-08-27

# Mark a transcript reviewed and remove its source audio
huddle-transcribe --mark-reviewed 2026-08-27
```

## Automatic transcription (`huddle-watch`)

`huddle-watch` is a companion script that watches MacWhisper's own SQLite
database and runs `huddle-transcribe <session-id> --yes` as soon as a meeting
has finished both recording *and* transcription. It posts a macOS
notification naming the transcript it wrote.

### What it watches, and why the database

The trigger is MacWhisper's database, not the auto-export folder. Watching the
database is better on three counts:

- **It fires earlier.** The database records completion the moment
  transcription and diarization finish; an export file appears later.
- **It carries the session id.** The watcher passes that id to
  `huddle-transcribe` explicitly and never uses `latest`, so two meetings that
  finish within moments of each other cannot race — each is transcribed as
  itself.
- **It cannot trigger itself.** `huddle-transcribe` only ever *reads*
  MacWhisper's database, so its own `.md` and `.meta.json` output is invisible
  to the watcher. A folder watcher has to exclude those files by name to avoid
  an infinite self-trigger loop.

The database is in WAL mode, so a commit lands in `main.sqlite-wal` before
`main.sqlite` is touched. The LaunchAgent therefore watches **both** files;
watching only `main.sqlite` fires late, or not at all. The watcher opens the
database read-only (`sqlite3 -readonly` plus a `mode=ro` URI) and never writes
to it. A transient "database is locked" — normal while MacWhisper holds the
file open — is retried briefly and then left for the next event.

### When a session counts as ready

A session is transcribed when all of the following hold:

- MacWhisper reports the transcription succeeded;
- speaker diarization has finished;
- the session is not being re-transcribed (the row is still settling);
- it is not a transient scratch row;
- it has not been deleted;
- its duration is over 5 minutes, the same floor `huddle-transcribe` applies;
- and its session id is not already recorded in the state file.

Duration is read from the recorded meeting or the system-audio recording,
whichever MacWhisper populated for that capture method. That chain matches
`huddle-transcribe`'s exactly, and deliberately so: the watcher only hands
over a session id, and the transcriber re-resolves it through its own filter.
A session the watcher considered ready but the transcriber cannot resolve
would fail three times and then report a failure for a perfectly good
recording.

### Install

```bash
huddle-watch --install      # writes and loads the LaunchAgent
huddle-watch --status       # report agent, state file, log, and lock
huddle-watch --uninstall    # unloads and removes the LaunchAgent
```

`--install` writes
`~/Library/LaunchAgents/com.smartwatermelon.huddle-transcribe.watch.plist`
and loads it with `launchctl bootstrap`. `RunAtLoad` is false, so logging in
never causes a burst of transcriptions. Nothing is installed as a side effect
of any other flag. `--uninstall` boots the agent out and removes the plist,
leaving the state file in place.

### First run seeds, and transcribes nothing

The first run — whether from `--install`'s first trigger or a manual
`--once` — records every session that is *already* ready as seen and
transcribes none of them. Without that, switching the watcher on would
re-transcribe the entire backlog. Only sessions that become ready afterwards
are picked up.

### State, log, and retries

- **State file:** `~/.local/state/huddle-transcribe/watch-state`, one
  `<session-id> <status>` record per line, where `<status>` is the token
  `done` or a failed-attempt count. A session is recorded `done` only after
  `huddle-transcribe` exits successfully, so a transient failure is retried.
  After 3 failed attempts the session is given up on, with a notification
  naming the log — a permanently broken recording cannot loop forever.
  Success is a distinct token rather than a count of zero, so a truncated or
  hand-edited line cannot be mistaken for a completed transcription; a line
  that parses as neither is logged and treated as retryable. Records written
  by earlier versions as `<session-id> 0` are still read as done.
- **Recovering a given-up session:** `huddle-watch --retry <session-id>`
  clears that session's attempt count so it is picked up again on the next
  firing. `--status` lists any sessions that hit the cap, so they are not
  invisible. Hand-editing the file still works but is no longer necessary.
- **Log:** `~/Library/Logs/huddle-transcribe-watch.log`, mode 0600 because it
  contains meeting titles and `huddle-transcribe`'s output, capped at 1 MB
  and rotated to `.log.1`, since launchd fires on every database commit.
  launchd's own stdout/stderr go to a separate `.log.launchd` file: launchd
  holds an open descriptor on whatever path it is given, so pointing it at
  the rotated log would split one run's output across two files.
- **Lock:** a `mkdir`-based lock beside the state file stops two firings from
  running two transcriptions at once. `mkdir` is the atomic gate, and a lock
  directory whose pid file is missing or unreadable is treated as *held*
  rather than reclaimable — declining costs one skipped firing, whereas
  reclaiming a lock mid-claim let two runs transcribe the same session. A
  lock whose owning process is demonstrably gone is still reclaimed.

### Verifying

Both of these are read-only and safe:

```bash
huddle-watch --list       # recent sessions with each readiness flag, and
                          # whether they are ready, already seen, or blocked
huddle-watch --dry-run    # report what WOULD be transcribed; writes no state
                          # file and runs nothing
```

`--list` prints one column per condition (`OK`, `DIA`, `RTX`, `TRA`, `DEL`),
so a session that is not being picked up shows exactly which condition it
fails. `--dry-run` mutates nothing at all — not the state file, not even its
parent directory.

Processing requires `--once` explicitly; a bare `huddle-watch` is an error
rather than a silent full run. `--dry-run` and `--list` need no mode flag.

Environment overrides, mainly for testing: `HUDDLE_DB`,
`HUDDLE_TRANSCRIBE_BIN`, `HUDDLE_STATE_FILE`, `HUDDLE_LOG_FILE`,
`HUDDLE_MIN_DURATION`, `HUDDLE_NO_NOTIFY` (suppress notifications), and
`HUDDLE_NOTIFY_BIN` (use something other than `osascript`).
`HUDDLE_MIN_DURATION` must be a whole number of seconds: it is interpolated
into SQL and also evaluated arithmetically, so anything else is rejected at
startup rather than trusted.

## Configuration

Output directory defaults to `~/Documents/huddle-transcripts`. Override it
per-run with `--output-dir`, or persistently via
`~/.config/huddle-transcribe/config`, which should contain a single
`OUTPUT_DIR=` line (the file is parsed, not sourced, so it cannot run
arbitrary shell code) — useful for pointing at a synced folder such as
Google Drive or Dropbox:

```bash
OUTPUT_DIR="/path/to/transcripts"
```

A leading `~` is expanded. Because the file is parsed rather than sourced,
shell variables such as `$HOME` are *not* expanded — write the path out or
use `~`.

## Development

There is no build step. Before committing:

```bash
shellcheck -S info huddle-transcribe huddle-watch tests/run-tests.sh
shfmt -i 2 -ci -d huddle-transcribe huddle-watch tests/run-tests.sh
./tests/run-tests.sh
```

`tests/run-tests.sh` builds a synthetic MacWhisper database and a stub `mw`,
then runs the real script against them, so the suite needs neither MacWhisper
nor a licence. It covers argument handling, session selection, row parsing,
and every `--mark-reviewed` guard. `huddle-watch` is covered the same way,
through its environment overrides and a stub `huddle-transcribe`, so no real
transcription runs: the readiness predicate (each column gating on its own),
first-run seeding, dedupe, the attempt cap, the lock, `HUDDLE_MIN_DURATION`
validation, state-file corruption handling, and notification content.
Notifications are routed to a stub via `HUDDLE_NOTIFY_BIN`, so running the
suite never posts a desktop alert. It does not cover the real `mw` binary's
own behavior, nor launchd's actual scheduling. CI runs the same three
commands.

## Session selection

Sessions come from MacWhisper's own SQLite database. A session qualifies if
its recording duration exceeds 5 minutes. Among a session's media files, the
script prefers the merged multitrack file, falling back to system/app audio
and then microphone audio.

## Output

For a session dated `2026-08-27` titled "SRE Daily Huddle", the script
writes:

- `2026-08-27_sre-daily-huddle_243d5daf.md` — the diarized transcript
- `2026-08-27_sre-daily-huddle_243d5daf.meta.json` — a metadata sidecar:

```json
{
  "session_id": "243d5daf...",
  "date": "2026-08-27",
  "duration_seconds": 1076,
  "source_file": "..._merged-audio_....m4a",
  "output_file": "2026-08-27_sre-daily-huddle_243d5daf.md",
  "reviewed": false,
  "deleted_source": false
}
```

The trailing session-id fragment keeps two same-day meetings apart when
their titles reduce to the same slug (`SRE Daily Huddle` and
`SRE/Daily Huddle` both slugify to `sre-daily-huddle`).

### Why Markdown

Transcripts are written as `.md` rather than `.txt` for one practical
reason: transcripts end up in Google Drive, and its web viewer previews
Markdown inline while offering only a download prompt for plain text.

The choice is about the extension, not the markup. `mw --format md` differs
from `--format txt` in exactly one respect — it wraps the timestamp line in
asterisks — so the transcript body is otherwise byte-identical. The
four-line block structure is the same either way:

```
Speaker 1
*00:00-00:06*
Good morning everyone, let's start the daily huddle.

```

`--end-timestamps` renders that timestamp as a `start-end` range rather
than a bare start, which makes segment length visible at a glance.

`mw` also offers `--format html`, which is *not* used: it emits the entire
transcript body as a single unbroken line, which would defeat any
line-oriented post-processing.

### Migrating pre-Markdown transcripts

Transcripts written before the Markdown switch are `.txt`, and their
sidecars record `"output_file": "<basename>.txt"`. `huddle-transcribe` now
resolves `<basename>.md`, so `--mark-reviewed` no longer finds them. That
**fails closed** — it refuses to delete the source audio rather than acting
on the wrong file — so nothing is at risk; those transcripts are simply
stranded.

`huddle-migrate-md` adopts them:

```bash
huddle-migrate-md --dry-run     # show what would be renamed; changes nothing
huddle-migrate-md               # rename, with a confirmation prompt
```

It renames each `.txt` to `.md` and repoints its sidecar's `output_file`.
**Transcript content is not modified** — `mw --format md` differs from
`--format txt` only in wrapping the timestamp line in asterisks, so an old
transcript is already valid Markdown, and rewriting the body would be a
lossy re-interpretation of text the script never parsed.

Every candidate is classified before anything moves, so the summary you
confirm describes the whole job. A pair is skipped, never guessed at, when:

| Condition | Why |
|---|---|
| No sidecar | A lone `.txt` is someone else's file or failed-run debris |
| `<basename>.md` already exists | One of the two was written by something else; picking a winner silently is data loss |
| Sidecar is unparseable | The rename must not outrun a sidecar that cannot be rewritten |
| Sidecar names a different file | The pairing is already broken, and rewriting it destroys the evidence |

Skipped pairs do not stop the run — good pairs in the same directory still
migrate — and re-running over an already-migrated directory is a no-op. It
reads `OUTPUT_DIR` with the same precedence as `huddle-transcribe`, or takes
`--output-dir`.

If a pair's sidecar cannot be written after its transcript is renamed, the
script exits non-zero and prints the exact repair. **A re-run will not fix
that one**: the scan looks at `*.txt`, and that pair's `.txt` is already
gone, so it is no longer a candidate. The transcript itself is complete at
its new `.md` name; only the sidecar's `output_file` needs correcting, by
hand or by fixing the permissions and editing the field.

## Source file lifecycle

The script never removes source audio on transcription. Once a transcript
has been reviewed and is no longer needed, run:

```bash
huddle-transcribe --mark-reviewed 2026-08-27
```

This sets `reviewed: true` and `deleted_source: true` in the sidecar and
removes the source `.m4a`. Where `trash(1)` is available (macOS 14+) the
file goes to the Trash and stays recoverable from Finder; otherwise it is
deleted outright.

This is the only destructive operation in the script, so it is fenced:

- it refuses to run unless a sidecar exists for the selected session, and
  that sidecar's `session_id` matches the session actually resolved;
- it refuses to run if the transcript is missing or empty;
- it prompts unless `--yes` is passed;
- the sidecar is updated only *after* the audio is confirmed gone, so a
  failed removal never leaves the sidecar claiming otherwise.

Pair it with `--dry-run` first if you want to see which session and file a
given argument resolves to.

## License

MIT — see [LICENSE](LICENSE).
