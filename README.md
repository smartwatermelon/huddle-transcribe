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
  - `YYYY-MM-DD` — session closest to that date
  - a MacWhisper session UUID (or unambiguous prefix)

### Options

```
--dry-run                Show which session would be selected, don't transcribe
--list                   List recent qualifying MacWhisper sessions with metadata
--mark-reviewed          Set reviewed=true, delete source .m4a for the selected session
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

# Mark a transcript reviewed and delete its source audio
huddle-transcribe --mark-reviewed 2026-08-27 --yes
```

## Configuration

Output directory defaults to a Google Drive path baked in for the author's
setup. Override it per-run with `--output-dir`, or persistently via
`~/.config/huddle-transcribe/config`, which should contain a single
`OUTPUT_DIR=` line (the file is parsed, not sourced, so it cannot run
arbitrary shell code):

```bash
OUTPUT_DIR="/path/to/transcripts"
```

## Session selection

Sessions come from MacWhisper's own SQLite database. A session qualifies if
its recording duration exceeds 5 minutes. Among a session's media files, the
script prefers the merged multitrack file, falling back to system/app audio
and then microphone audio.

## Output

For a session dated `2026-08-27` titled "SRE Daily Huddle", the script
writes:

- `2026-08-27_sre-daily-huddle.txt` — the diarized transcript
- `2026-08-27_sre-daily-huddle.meta.json` — a metadata sidecar:

```json
{
  "session_id": "243d5daf-...",
  "date": "2026-08-27",
  "duration_seconds": 1076,
  "source_file": "..._merged-audio_....m4a",
  "output_file": "2026-08-27_sre-daily-huddle.txt",
  "reviewed": false,
  "deleted_source": false
}
```

## Source file lifecycle

The script never deletes source audio on transcription. Once a transcript
has been reviewed and is no longer needed, run:

```bash
huddle-transcribe --mark-reviewed 2026-08-27
```

This sets `reviewed: true` and `deleted_source: true` in the sidecar and
deletes the source `.m4a`.

## License

MIT — see [LICENSE](LICENSE).
