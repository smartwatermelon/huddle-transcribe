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
shellcheck -S info huddle-transcribe tests/run-tests.sh
shfmt -i 2 -ci -d huddle-transcribe tests/run-tests.sh
./tests/run-tests.sh
```

`tests/run-tests.sh` builds a synthetic MacWhisper database and a stub `mw`,
then runs the real script against them, so the suite needs neither MacWhisper
nor a licence. It covers argument handling, session selection, row parsing,
and every `--mark-reviewed` guard. It does not cover the real `mw` binary's
own behavior. CI runs the same three commands.

## Session selection

Sessions come from MacWhisper's own SQLite database. A session qualifies if
its recording duration exceeds 5 minutes. Among a session's media files, the
script prefers the merged multitrack file, falling back to system/app audio
and then microphone audio.

## Output

For a session dated `2026-08-27` titled "SRE Daily Huddle", the script
writes:

- `2026-08-27_sre-daily-huddle_243d5daf.txt` — the diarized transcript
- `2026-08-27_sre-daily-huddle_243d5daf.meta.json` — a metadata sidecar:

```json
{
  "session_id": "243d5daf...",
  "date": "2026-08-27",
  "duration_seconds": 1076,
  "source_file": "..._merged-audio_....m4a",
  "output_file": "2026-08-27_sre-daily-huddle_243d5daf.txt",
  "reviewed": false,
  "deleted_source": false
}
```

The trailing session-id fragment keeps two same-day meetings apart when
their titles reduce to the same slug (`SRE Daily Huddle` and
`SRE/Daily Huddle` both slugify to `sre-daily-huddle`).

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
