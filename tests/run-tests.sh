#!/usr/bin/env bash
# Behavioral tests for huddle-transcribe and huddle-watch.
#
# MacWhisper and its `mw` CLI are macOS-only and cannot be installed on a CI
# runner, so these tests build a synthetic MacWhisper database (the four
# tables SESSION_QUERY touches) plus a stub `mw`, then run the real script
# against them with DB/MEDIA_DIR/MW_BIN/CONFIG_FILE repointed.
#
# huddle-watch is exercised the same way, but through its environment
# overrides rather than a rewritten copy: HUDDLE_DB points at a second
# synthetic database carrying the readiness columns, and
# HUDDLE_TRANSCRIBE_BIN points at a stub, so no real transcription and no
# `--mark-reviewed` can ever run from the suite.
#
# What is NOT covered: the real `mw` binary's flag handling and transcription
# output, and launchd/osascript behavior (both absent on a Linux runner).
# Everything the scripts themselves do -- argument parsing, session
# selection, row parsing, output naming, the --mark-reviewed guards, and the
# watcher's readiness predicate, seeding, dedupe, attempt cap and lock --
# is exercised here.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SCRIPT="$REPO_ROOT/huddle-transcribe"
WATCH="$REPO_ROOT/huddle-watch"

PASS=0
FAIL=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [[ $# -lt 2 ]] || printf '        %s\n' "$2"
}

# --- fixture -----------------------------------------------------------

MEDIA="$WORK/media"
DB="$WORK/db.sqlite"
BIN="$WORK/bin"
mkdir -p "$MEDIA" "$BIN"

# Stub mw: writes a plausible diarized transcript to whatever -o names.
cat >"$BIN/mw" <<'STUB'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || exit 2
printf 'Speaker 1: hello\nSpeaker 2: hi there\n' >"$out"
STUB
chmod +x "$BIN/mw"

# Stub mw that fails, for the failure-path tests.
cat >"$BIN/mw-fail" <<'STUB'
#!/usr/bin/env bash
echo "mw: simulated failure" >&2
exit 3
STUB
chmod +x "$BIN/mw-fail"

sqlite3 "$DB" <<'SQL'
CREATE TABLE session (id BLOB PRIMARY KEY, dateCreated TEXT, userChosenTitle TEXT, aiTitle TEXT, recordedMeetingID BLOB, systemAudioRecordingID BLOB);
CREATE TABLE recordedmeeting (id BLOB PRIMARY KEY, duration REAL, title TEXT);
CREATE TABLE systemaudiorecording (id BLOB PRIMARY KEY, duration REAL, title TEXT);
CREATE TABLE mediafile (sessionID BLOB, type TEXT, filename TEXT);

-- A and B: same date, titles that slugify identically. Exercises the
-- session-id suffix that keeps their basenames apart.
INSERT INTO recordedmeeting VALUES (x'11', 1076.0, 'rmA');
INSERT INTO session VALUES (x'aaaa0001', '2026-08-27 15:00:00.000', 'SRE Daily Huddle', NULL, x'11', NULL);
INSERT INTO mediafile VALUES (x'aaaa0001', 'mergedMultitrack', 'A_merged.m4a');

INSERT INTO recordedmeeting VALUES (x'22', 900.0, 'rmB');
INSERT INTO session VALUES (x'bbbb0002', '2026-08-27 17:00:00.000', 'SRE/Daily Huddle', NULL, x'22', NULL);
INSERT INTO mediafile VALUES (x'bbbb0002', 'meetingAppAudio', 'B_app.m4a');

-- Distant session: a date query must not reach this one.
INSERT INTO recordedmeeting VALUES (x'33', 800.0, 'rmC');
INSERT INTO session VALUES (x'cccc0003', '2026-01-05 12:00:00.000', 'January Session', NULL, x'33', NULL);
INSERT INTO mediafile VALUES (x'cccc0003', 'mergedMultitrack', 'C_merged.m4a');

-- Tab in the title, and only mic audio: exercises both the SQL scrub and
-- the empty-column handling that a tab separator would collapse.
INSERT INTO recordedmeeting VALUES (x'44', 700.0, 'Tab	Title	Here');
INSERT INTO session VALUES (x'dddd0004', '2026-08-20 10:00:00.000', NULL, NULL, x'44', NULL);
INSERT INTO mediafile VALUES (x'dddd0004', 'meetingMicAudio', 'D_mic.m4a');

-- Under MIN_DURATION_SECONDS: must never appear.
INSERT INTO recordedmeeting VALUES (x'55', 60.0, 'Too Short');
INSERT INTO session VALUES (x'eeee0005', '2026-08-28 10:00:00.000', 'Short One', NULL, x'55', NULL);

-- Non-numeric duration. Bash evaluates arithmetic on this value, and an
-- array-subscript payload would execute if it reached $(( )) unvalidated.
INSERT INTO recordedmeeting VALUES (x'66', 'HOME[$(touch ' || char(34) || 'PWNMARKER' || char(34) || ')0]', 'Hostile');
INSERT INTO session VALUES (x'ffff0006', '2026-08-19 09:00:00.000', 'Hostile Duration', NULL, x'66', NULL);
INSERT INTO mediafile VALUES (x'ffff0006', 'mergedMultitrack', 'F_merged.m4a');
SQL

reset_media() {
  rm -f "$MEDIA"/*.m4a
  touch "$MEDIA/A_merged.m4a" "$MEDIA/B_app.m4a" \
    "$MEDIA/C_merged.m4a" "$MEDIA/D_mic.m4a" "$MEDIA/F_merged.m4a"
}

# Build a runnable copy with the four environment constants repointed at the
# fixture. Editing constants is how the script is made testable without
# MacWhisper; the rest of the file is byte-for-byte the shipped script.
build() {
  local mw="${1:-$BIN/mw}" dest="$WORK/ht.sh"
  sed -e "s|^DB=.*|DB=\"$DB\"|" \
    -e "s|^MEDIA_DIR=.*|MEDIA_DIR=\"$MEDIA\"|" \
    -e "s|^MW_BIN=.*|MW_BIN=\"$mw\"|" \
    -e "s|^CONFIG_FILE=.*|CONFIG_FILE=\"$WORK/no-such-config\"|" \
    "$SCRIPT" >"$dest"
  chmod +x "$dest"
  printf '%s\n' "$dest"
}

HT=$(build)
OUT="$WORK/out"

# --- helpers -----------------------------------------------------------

# expect_rc <name> <expected_rc> <args...>
expect_rc() {
  local name="$1" want="$2"
  shift 2
  local rc=0
  "$HT" "$@" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq $want ]]; then
    pass "$name"
  else
    fail "$name" "exit $rc, wanted $want"
  fi
}

# expect_out <name> <pattern> <args...>
expect_out() {
  local name="$1" pattern="$2"
  shift 2
  local output
  output=$("$HT" "$@" 2>&1 || true)
  if grep -qF -- "$pattern" <<<"$output"; then
    pass "$name"
  else
    fail "$name" "output did not contain: $pattern"
  fi
}

# refute_out <name> <pattern> <args...>
refute_out() {
  local name="$1" pattern="$2"
  shift 2
  local output
  output=$("$HT" "$@" 2>&1 || true)
  if grep -qF -- "$pattern" <<<"$output"; then
    fail "$name" "output unexpectedly contained: $pattern"
  else
    pass "$name"
  fi
}

exists() {
  if [[ -e "$2" ]]; then pass "$1"; else fail "$1" "missing: $2"; fi
}

absent() {
  if [[ -e "$2" ]]; then fail "$1" "unexpectedly present: $2"; else pass "$1"; fi
}

# --- argument handling -------------------------------------------------

echo "argument handling"
reset_media
expect_rc "--help exits 0" 0 --help
expect_rc "--list exits 0" 0 --list
expect_rc "unknown flag rejected" 1 --bogus
expect_rc "--output-dir requires an argument" 1 --output-dir
expect_rc "empty target rejected" 1 --dry-run --output-dir "$OUT" ""
expect_rc "second positional rejected" 1 --dry-run --output-dir "$OUT" aaaa0001 bbbb0002
expect_out "extra argument names the conflict" "unexpected extra argument" \
  --dry-run --output-dir "$OUT" aaaa0001 bbbb0002

# --- session selection -------------------------------------------------

echo "session selection"
expect_rc "latest resolves" 0 --dry-run --output-dir "$OUT"
expect_rc "bare hex id resolves" 0 --dry-run --output-dir "$OUT" aaaa0001
expect_rc "dashed uuid resolves" 0 --dry-run --output-dir "$OUT" aaaa-0001
expect_rc "date on a recorded day resolves" 0 --dry-run --output-dir "$OUT" 2026-08-27
expect_rc "date with no session rejected" 1 --dry-run --output-dir "$OUT" 2026-06-15
expect_rc "impossible date rejected" 1 --dry-run --output-dir "$OUT" 2026-02-30
expect_rc "out-of-range month rejected" 1 --dry-run --output-dir "$OUT" 2026-13-01
expect_rc "malformed date rejected" 1 --dry-run --output-dir "$OUT" 2026-8-27
expect_rc "unknown id rejected" 1 --dry-run --output-dir "$OUT" 99999999

# A date query must not silently reach a session months away.
refute_out "date query does not reach a distant session" "January Session" \
  --dry-run --output-dir "$OUT" 2026-06-15
expect_out "missing date names the date" "no qualifying session on 2026-06-15" \
  --dry-run --output-dir "$OUT" 2026-06-15

# Sessions below the duration floor are filtered out entirely.
refute_out "short session filtered from --list" "Short One" --list
expect_rc "short session not selectable" 1 --dry-run --output-dir "$OUT" eeee0005

# --- row parsing -------------------------------------------------------

echo "row parsing"
# Only one of the three media columns is populated for this session, so a
# separator that collapses empty fields would resolve the wrong column.
expect_out "empty media columns do not shift fields" "D_mic.m4a" \
  --dry-run --output-dir "$OUT" dddd0004
expect_out "app-audio session resolves its own file" "B_app.m4a" \
  --dry-run --output-dir "$OUT" bbbb0002
expect_out "merged audio preferred when present" "A_merged.m4a" \
  --dry-run --output-dir "$OUT" aaaa0001
# Tabs in a title are scrubbed to spaces rather than splitting the row.
expect_out "tabbed title survives intact" "Tab Title Here" \
  --dry-run --output-dir "$OUT" dddd0004

# --- duration handling -------------------------------------------------

echo "duration handling"
rm -f "$WORK/PWNMARKER" PWNMARKER
expect_rc "non-numeric duration does not abort" 0 --dry-run --output-dir "$OUT" ffff0006
"$HT" --list >/dev/null 2>&1 || true
if [[ -e "$WORK/PWNMARKER" || -e PWNMARKER ]]; then
  fail "arithmetic payload in duration does not execute" "PWNMARKER was created"
  rm -f "$WORK/PWNMARKER" PWNMARKER
else
  pass "arithmetic payload in duration does not execute"
fi
expect_out "non-numeric duration renders as zero" "0m00s" \
  --dry-run --output-dir "$OUT" ffff0006

# --- transcription -----------------------------------------------------

echo "transcription"
rm -rf "$OUT"
reset_media
expect_rc "transcribe succeeds" 0 --yes --output-dir "$OUT" aaaa0001
exists "transcript written with session-id suffix" \
  "$OUT/2026-08-27_sre-daily-huddle_aaaa0001.txt"
exists "sidecar written with session-id suffix" \
  "$OUT/2026-08-27_sre-daily-huddle_aaaa0001.meta.json"
exists "source audio survives transcription" "$MEDIA/A_merged.m4a"

meta_sid=$(jq -r '.session_id' "$OUT/2026-08-27_sre-daily-huddle_aaaa0001.meta.json")
if [[ "$meta_sid" == "aaaa0001" ]]; then
  pass "sidecar records the resolved session id"
else
  fail "sidecar records the resolved session id"
fi

# The colliding-slug session must not overwrite the first transcript.
expect_rc "colliding-slug session transcribes" 0 --yes --output-dir "$OUT" bbbb0002
exists "colliding slugs produce separate transcripts" \
  "$OUT/2026-08-27_sre-daily-huddle_bbbb0002.txt"

# A failing mw must leave an existing good transcript untouched.
HT=$(build "$BIN/mw-fail")
before=$(cat "$OUT/2026-08-27_sre-daily-huddle_aaaa0001.txt")
expect_rc "failing mw exits non-zero" 1 --yes --output-dir "$OUT" aaaa0001
after=$(cat "$OUT/2026-08-27_sre-daily-huddle_aaaa0001.txt")
if [[ "$after" == "$before" ]]; then
  pass "failing mw preserves the previous transcript"
else
  fail "failing mw preserves the previous transcript"
fi
if compgen -G "$OUT/*.partial.*" >/dev/null; then
  fail "failing mw leaves no partial file"
else
  pass "failing mw leaves no partial file"
fi
HT=$(build)

# --- --mark-reviewed guards --------------------------------------------

echo "--mark-reviewed guards"

# --dry-run must win over --mark-reviewed.
expect_rc "--dry-run --mark-reviewed exits 0" 0 \
  --dry-run --mark-reviewed --yes --output-dir "$OUT" aaaa0001
exists "--dry-run --mark-reviewed keeps the audio" "$MEDIA/A_merged.m4a"

# No sidecar: refuse.
expect_rc "no sidecar refuses" 1 --mark-reviewed --yes --output-dir "$OUT" cccc0003
exists "no sidecar keeps the audio" "$MEDIA/C_merged.m4a"

# Sidecar describing a different session: refuse.
meta="$OUT/2026-08-27_sre-daily-huddle_aaaa0001.meta.json"
jq '.session_id = "9999dead"' "$meta" >"$meta.tmp" && mv "$meta.tmp" "$meta"
expect_rc "mismatched sidecar refuses" 1 --mark-reviewed --yes --output-dir "$OUT" aaaa0001
exists "mismatched sidecar keeps the audio" "$MEDIA/A_merged.m4a"
jq '.session_id = "aaaa0001"' "$meta" >"$meta.tmp" && mv "$meta.tmp" "$meta"

# Empty transcript: refuse.
txt="$OUT/2026-08-27_sre-daily-huddle_aaaa0001.txt"
saved=$(cat "$txt")
: >"$txt"
expect_rc "empty transcript refuses" 1 --mark-reviewed --yes --output-dir "$OUT" aaaa0001
exists "empty transcript keeps the audio" "$MEDIA/A_merged.m4a"
printf '%s\n' "$saved" >"$txt"

# Positive control: with every guard satisfied, the removal must succeed.
# Passes whether the audio went to the Trash (macOS 14+, where trash(1)
# exists) or was deleted outright -- both leave MEDIA_DIR without the file.
expect_rc "valid mark-reviewed succeeds" 0 --mark-reviewed --yes --output-dir "$OUT" aaaa0001
absent "valid mark-reviewed removes the audio" "$MEDIA/A_merged.m4a"
review_flags=$(jq -r '[.reviewed, .deleted_source] | join(",")' "$meta")
if [[ "$review_flags" == "true,true" ]]; then
  pass "sidecar records reviewed and deleted_source"
else
  fail "sidecar records reviewed and deleted_source"
fi
if compgen -G "$OUT/*.meta.json.*" >/dev/null; then
  fail "mark-reviewed leaves no temp sidecar"
else
  pass "mark-reviewed leaves no temp sidecar"
fi

# Re-running is idempotent and says so rather than claiming a fresh delete.
expect_rc "mark-reviewed is idempotent" 0 --mark-reviewed --yes --output-dir "$OUT" aaaa0001
expect_out "idempotent run reports the audio was already gone" "already gone" \
  --mark-reviewed --yes --output-dir "$OUT" aaaa0001

# --- huddle-watch ------------------------------------------------------
#
# The watcher is driven purely through its environment overrides. Its
# huddle-transcribe is a stub that records the arguments it was handed, so the
# suite can assert an explicit session id was passed (never `latest`) without
# any real transcription taking place.

echo "huddle-watch"

WDB="$WORK/watch.sqlite"
WSTATE="$WORK/watch-state"
WLOG="$WORK/watch.log"
WBIN="$WORK/wbin"
CALLS="$WORK/calls"
mkdir -p "$WBIN"

# Stub huddle-transcribe: appends its arguments to $CALLS and prints the same
# success line the real script prints, which is what the watcher parses for
# the notification body. Exits non-zero when FAIL_TRANSCRIBE is set, to drive
# the retry and attempt-cap tests.
cat >"$WBIN/huddle-transcribe" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
if [[ -n "${FAIL_TRANSCRIBE:-}" ]]; then
  echo "stub: simulated failure" >&2
  exit 1
fi
echo "Transcript written: /tmp/out/${1:0:8}.txt"
STUB
chmod +x "$WBIN/huddle-transcribe"

# Stub osascript. EVERY huddle-watch invocation in this suite is routed here
# via HUDDLE_NOTIFY_BIN, so the real osascript is never reached and the suite
# cannot post desktop notifications on a developer's Mac. It records the
# AppleScript it was handed, which is also what makes the notification text
# and the AppleScript escaping testable at all.
NOTIFYLOG="$WORK/notifications"
cat >"$WBIN/osascript-stub" <<'STUB'
#!/usr/bin/env bash
# Record every argument verbatim; -e's value is the assembled AppleScript.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e)
      printf '%s\n' "$2" >>"$NOTIFYLOG"
      shift 2
      ;;
    *) shift ;;
  esac
done
STUB
chmod +x "$WBIN/osascript-stub"

# Exported once, globally, rather than added to each `env` invocation: there
# are many call sites and a single missed one posts a real desktop alert. Any
# huddle-watch started from this suite -- through a helper or a bare `env` --
# inherits these.
export HUDDLE_NOTIFY_BIN="$WBIN/osascript-stub"
export NOTIFYLOG

# Belt and braces. If a future edit somehow bypasses HUDDLE_NOTIFY_BIN, a
# real `osascript` on PATH would still be reached, so shadow it with the stub
# too. The suite must be incapable of notifying the desktop.
ln -sf "$WBIN/osascript-stub" "$WBIN/osascript"
export PATH="$WBIN:$PATH"

notify_reset() {
  rm -f "$NOTIFYLOG"
}

# Synthetic database carrying the readiness columns. One session per gating
# condition, so each column can be shown to gate on its own.
build_watch_db() {
  rm -f "$WDB"
  sqlite3 "$WDB" <<'SQL'
CREATE TABLE session (
  id BLOB PRIMARY KEY,
  dateCreated TEXT,
  userChosenTitle TEXT,
  aiTitle TEXT,
  recordedMeetingID BLOB,
  systemAudioRecordingID BLOB,
  transcriptionDidSucceed BOOLEAN,
  hasBeenDiarized BOOLEAN NOT NULL DEFAULT 0,
  isBeingRetranscribed BOOLEAN NOT NULL DEFAULT 0,
  isTransient BOOLEAN NOT NULL DEFAULT 0,
  dateDeleted DOUBLE,
  playbackDuration DOUBLE
);
CREATE TABLE recordedmeeting (id BLOB PRIMARY KEY, duration REAL, title TEXT);
CREATE TABLE systemaudiorecording (id BLOB PRIMARY KEY, duration REAL, title TEXT);

-- READY: every condition satisfied. This is the one the watcher must pick.
INSERT INTO recordedmeeting VALUES (x'71', 803.25, 'rmReady');
INSERT INTO session VALUES (x'aaaa1111', '2026-08-31 15:18:37.000', 'Ready Session',
  NULL, x'71', NULL, 1, 1, 0, 0, NULL, NULL);

-- Not diarized: MacWhisper has transcribed but not yet separated speakers.
INSERT INTO recordedmeeting VALUES (x'72', 900.0, 'rmNoDia');
INSERT INTO session VALUES (x'bbbb2222', '2026-08-30 10:00:00.000', 'Not Diarized',
  NULL, x'72', NULL, 1, 0, 0, 0, NULL, NULL);

-- Transcription did not succeed.
INSERT INTO recordedmeeting VALUES (x'73', 900.0, 'rmNoOk');
INSERT INTO session VALUES (x'cccc3333', '2026-08-29 10:00:00.000', 'Failed Transcription',
  NULL, x'73', NULL, 0, 1, 0, 0, NULL, NULL);

-- Mid-retranscription: the row is still settling.
INSERT INTO recordedmeeting VALUES (x'74', 900.0, 'rmRtx');
INSERT INTO session VALUES (x'dddd4444', '2026-08-28 10:00:00.000', 'Retranscribing',
  NULL, x'74', NULL, 1, 1, 1, 0, NULL, NULL);

-- Transient scratch row.
INSERT INTO recordedmeeting VALUES (x'75', 900.0, 'rmTransient');
INSERT INTO session VALUES (x'eeee5555', '2026-08-27 10:00:00.000', 'Transient',
  NULL, x'75', NULL, 1, 1, 0, 1, NULL, NULL);

-- Deleted by the user.
INSERT INTO recordedmeeting VALUES (x'76', 900.0, 'rmDeleted');
INSERT INTO session VALUES (x'ffff6666', '2026-08-26 10:00:00.000', 'Deleted',
  NULL, x'76', NULL, 1, 1, 0, 0, 1756000000.0, NULL);

-- Under MIN_DURATION_SECONDS: ready in every other respect.
INSERT INTO recordedmeeting VALUES (x'77', 60.0, 'rmShort');
INSERT INTO session VALUES (x'aaaa7777', '2026-08-25 10:00:00.000', 'Too Short',
  NULL, x'77', NULL, 1, 1, 0, 0, NULL, NULL);

-- System-audio capture: duration lives in systemaudiorecording, not
-- recordedmeeting, so this exercises the COALESCE chain.
INSERT INTO systemaudiorecording VALUES (x'78', 700.0, 'sarReady');
INSERT INTO session VALUES (x'bbbb8888', '2026-08-24 10:00:00.000', NULL,
  'System Audio Session', NULL, x'78', 1, 1, 0, 0, NULL, NULL);

-- playbackDuration ONLY: ready in every other respect, with NO
-- recordedmeeting and NO systemaudiorecording row, so its duration exists
-- solely in session.playbackDuration. The watcher's predicate must NOT admit
-- it, because huddle-transcribe's SESSION_QUERY does not -- its duration
-- chain is COALESCE(rm.duration, sar.duration, 0) with no playbackDuration
-- term. A row the watcher queues but the parent cannot resolve gets retried
-- to the attempt cap and then reported as a FAILED transcription for a
-- recording that was never eligible.
INSERT INTO session VALUES (x'cafe9999', '2026-08-23 10:00:00.000',
  'Playback Duration Only', NULL, NULL, NULL, 1, 1, 0, 0, NULL, 1200.0);

-- transcriptionDidSucceed = 2, a truthy value that is not 1. The predicate
-- tests `= 1`, so this must not be selected. MacWhisper uses 1; a `!= 0`
-- "cleanup" of that comparison would start admitting rows like this one.
INSERT INTO recordedmeeting VALUES (x'79', 900.0, 'rmTruthyTwo');
INSERT INTO session VALUES (x'dead1010', '2026-08-22 10:00:00.000', 'Truthy Two',
  NULL, x'79', NULL, 2, 1, 0, 0, NULL, NULL);

-- transcriptionDidSucceed NULL rather than 0/1. SQL three-valued logic makes
-- `NULL = 1` neither true nor false, so the row is excluded -- fail-closed,
-- which is the correct direction. Pinned so a future rewrite cannot start
-- admitting rows whose readiness is genuinely unknown.
--
-- transcriptionDidSucceed is the only one of the flag columns that is
-- nullable in MacWhisper's schema; hasBeenDiarized, isBeingRetranscribed and
-- isTransient are all NOT NULL, so a NULL in those is unreachable and is not
-- fixtured here.
INSERT INTO recordedmeeting VALUES (x'7a', 900.0, 'rmNullFlags');
INSERT INTO session VALUES (x'dead2020', '2026-08-21 10:00:00.000', 'Null Flags',
  NULL, x'7a', NULL, NULL, 1, 0, 0, NULL, NULL);
SQL
}

build_watch_db

# watch <args...>: run huddle-watch against the fixture. Every path the
# watcher could use is repointed, so it can touch nothing real.
watch() {
  env -u FAIL_TRANSCRIBE \
    HUDDLE_DB="$WDB" \
    HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
    HUDDLE_STATE_FILE="$WSTATE" \
    HUDDLE_LOG_FILE="$WLOG" \
    CALLS="$CALLS" \
    "$WATCH" "$@"
}

# watch_failing <args...>: same, but the stub transcribe exits non-zero.
watch_failing() {
  env FAIL_TRANSCRIBE=1 \
    HUDDLE_DB="$WDB" \
    HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
    HUDDLE_STATE_FILE="$WSTATE" \
    HUDDLE_LOG_FILE="$WLOG" \
    CALLS="$CALLS" \
    "$WATCH" "$@"
}

watch_reset() {
  rm -f "$WSTATE" "$WLOG" "$CALLS" "$NOTIFYLOG"
  rm -rf "$WSTATE.lock"
}

# Read a file for a failure message, tolerating its absence. Used only in the
# diagnostic argument to fail(), so it must never itself abort the suite.
dump() {
  local content=""
  if [[ -f "$1" ]]; then
    content=$(cat -- "$1") || content="(unreadable)"
  else
    content="(missing: $1)"
  fi
  printf '%s' "$content"
}

# expect_watch_rc <name> <expected_rc> <args...>
expect_watch_rc() {
  local name="$1" want="$2"
  shift 2
  local rc=0
  watch "$@" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq $want ]]; then
    pass "$name"
  else
    fail "$name" "exit $rc, wanted $want"
  fi
}

# expect_watch_out <name> <pattern> <args...>
expect_watch_out() {
  local name="$1" pattern="$2"
  shift 2
  local output
  output=$(watch "$@" 2>&1 || true)
  if grep -qF -- "$pattern" <<<"$output"; then
    pass "$name"
  else
    fail "$name" "output did not contain: $pattern"
  fi
}

# refute_watch_out <name> <pattern> <args...>
refute_watch_out() {
  local name="$1" pattern="$2"
  shift 2
  local output
  output=$(watch "$@" 2>&1 || true)
  if grep -qF -- "$pattern" <<<"$output"; then
    fail "$name" "output unexpectedly contained: $pattern"
  else
    pass "$name"
  fi
}

# --- argument handling ---

watch_reset
expect_watch_rc "watch --help exits 0" 0 --help
expect_watch_rc "watch unknown flag rejected" 1 --bogus
expect_watch_rc "watch positional argument rejected" 1 somesession
expect_watch_rc "watch --list exits 0" 0 --list

# --- readiness predicate, via --dry-run (which mutates nothing) ---

watch_reset
expect_watch_out "ready session is detected" "aaaa1111" --dry-run
expect_watch_out "system-audio duration satisfies the floor" "bbbb8888" --dry-run
refute_watch_out "not-diarized session is not selected" "bbbb2222" --dry-run
refute_watch_out "failed transcription is not selected" "cccc3333" --dry-run
refute_watch_out "retranscribing session is not selected" "dddd4444" --dry-run
refute_watch_out "transient session is not selected" "eeee5555" --dry-run
refute_watch_out "deleted session is not selected" "ffff6666" --dry-run
refute_watch_out "under-duration session is not selected" "aaaa7777" --dry-run

# The watcher's duration chain must match huddle-transcribe's SESSION_QUERY
# exactly. This session's duration exists ONLY in session.playbackDuration,
# which the parent's COALESCE chain does not consult, so the parent cannot
# resolve it. Admitting it here means queueing a session that fails three
# times and then reports "Transcription FAILED" for a fine recording.
refute_watch_out "playbackDuration-only session is not selected" "cafe9999" --dry-run

# Boolean flags are compared with `= 1`, which is fail-closed: a truthy-but-
# not-1 value and a NULL are both excluded. Pinned so a future `!= 0`
# "simplification" cannot silently start transcribing such rows.
refute_watch_out "truthy-2 transcriptionDidSucceed is not selected" "dead1010" --dry-run
refute_watch_out "NULL transcriptionDidSucceed is not selected" "dead2020" --dry-run

# The parent must genuinely be unable to resolve the playbackDuration-only
# session -- that is the whole reason the watcher must not queue it. Proven
# against the real huddle-transcribe query rather than asserted, using a
# database shaped like the watcher fixture.
pd_probe=$(sqlite3 "$WDB" "
SELECT count(*) FROM session s
LEFT JOIN recordedmeeting rm ON rm.id = s.recordedMeetingID
LEFT JOIN systemaudiorecording sar ON sar.id = s.systemAudioRecordingID
WHERE lower(hex(s.id)) = 'cafe9999'
  AND COALESCE(rm.duration, sar.duration, 0) > 300;" 2>/dev/null || echo "?")
if [[ "$pd_probe" == "0" ]]; then
  pass "the parent's duration chain excludes the playbackDuration-only session"
else
  fail "the parent's duration chain excludes the playbackDuration-only session" \
    "parent matched $pd_probe row(s); the watcher must not queue what the parent cannot resolve"
fi

# HUDDLE_MIN_DURATION is honored, so the duration floor is genuinely the
# gate rather than something else about that row.
short_out=$(env HUDDLE_DB="$WDB" HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
  HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" HUDDLE_MIN_DURATION=30 \
  "$WATCH" --dry-run 2>&1 || true)
if grep -qF "aaaa7777" <<<"$short_out"; then
  pass "lowering HUDDLE_MIN_DURATION admits the short session"
else
  fail "lowering HUDDLE_MIN_DURATION admits the short session"
fi

# --- --dry-run mutates nothing ---

watch_reset
expect_watch_rc "watch --dry-run exits 0" 0 --dry-run
absent "watch --dry-run writes no state file" "$WSTATE"
absent "watch --dry-run runs no transcription" "$CALLS"
expect_watch_out "watch --dry-run says nothing was transcribed" \
  "no state was written" --dry-run
absent "watch --dry-run still writes no state after a second run" "$WSTATE"

# --- first-run seeding ---

watch_reset
expect_watch_rc "first run exits 0" 0 --once
exists "first run creates the state file" "$WSTATE"
absent "first run transcribes nothing" "$CALLS"
# Both ready sessions must be recorded as seen, and only those two.
seeded=$(grep -c . "$WSTATE" || true)
if [[ "$seeded" == "2" ]]; then
  pass "first run seeds exactly the ready sessions"
else
  fail "first run seeds exactly the ready sessions" "seeded $seeded, wanted 2"
fi
if grep -q '^aaaa1111 done$' "$WSTATE" && grep -q '^bbbb8888 done$' "$WSTATE"; then
  pass "seeded ids are the ready ones"
else
  diag=$(dump "$WSTATE")
  fail "seeded ids are the ready ones" "$diag"
fi
if grep -q 'bbbb2222' "$WSTATE"; then
  fail "seeding excludes non-ready sessions"
else
  pass "seeding excludes non-ready sessions"
fi

# --- already-seen sessions are skipped ---

expect_watch_rc "second run over seeded state exits 0" 0 --once
absent "seeded session is not re-transcribed" "$CALLS"
expect_watch_out "--list marks a seeded session as seen" "seen" --list

# --- a newly-ready session is detected and transcribed ---

# Flip the not-diarized session to ready: this is exactly what MacWhisper
# does when diarization finishes, and it is the event the watcher exists for.
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'bbbb2222';"
expect_watch_rc "newly-ready session transcribes" 0 --once
exists "newly-ready session invoked huddle-transcribe" "$CALLS"
if [[ -f "$CALLS" ]] && grep -q 'bbbb2222' "$CALLS"; then
  pass "the explicit session id was passed"
else
  diag=$(dump "$CALLS")
  fail "the explicit session id was passed" "$diag"
fi
# The id must be passed explicitly: `latest` races when two meetings finish
# close together, and would transcribe the wrong one.
if [[ -f "$CALLS" ]] && grep -q 'latest' "$CALLS"; then
  diag=$(dump "$CALLS")
  fail "the watcher never passes 'latest'" "$diag"
else
  pass "the watcher never passes 'latest'"
fi
if [[ -f "$CALLS" ]] && grep -q -- '--yes' "$CALLS"; then
  pass "--yes is passed so the child never prompts"
else
  fail "--yes is passed so the child never prompts"
fi
if grep -q '^bbbb2222 done$' "$WSTATE"; then
  pass "a successful run marks the session seen"
else
  diag=$(dump "$WSTATE")
  fail "a successful run marks the session seen" "$diag"
fi
# Only the one newly-ready session, not the whole backlog.
call_count=$(grep -c . "$CALLS" || true)
if [[ "$call_count" == "1" ]]; then
  pass "only the newly-ready session was transcribed"
else
  fail "only the newly-ready session was transcribed" "$call_count calls"
fi
expect_watch_rc "run after success exits 0 with nothing pending" 0 --once

# --- attempt cap ---

watch_reset
# Seed first, then make one session newly ready, so the failure path has
# exactly one candidate to retry.
watch --once >/dev/null 2>&1 || true
# cccc3333 is seeded diarized but not succeeded, so this is the only flip
# needed to make it ready.
sqlite3 "$WDB" "UPDATE session SET transcriptionDidSucceed = 1 WHERE id = x'cccc3333';"
rm -f "$CALLS"

rc=0
watch_failing --once >/dev/null 2>&1 || rc=$?
if [[ $rc -ne 0 ]]; then
  pass "a failed transcription exits non-zero"
else
  fail "a failed transcription exits non-zero" "exit $rc"
fi
if grep -q '^cccc3333 1$' "$WSTATE"; then
  pass "a failed session records attempt 1"
else
  diag=$(dump "$WSTATE")
  fail "a failed session records attempt 1" "$diag"
fi

watch_failing --once >/dev/null 2>&1 || true
if grep -q '^cccc3333 2$' "$WSTATE"; then
  pass "a second failure records attempt 2"
else
  diag=$(dump "$WSTATE")
  fail "a second failure records attempt 2" "$diag"
fi

give_up=$(watch_failing --once 2>&1 || true)
if grep -qF "gave up" <<<"$give_up"; then
  pass "the third failure gives up and says so"
else
  fail "the third failure gives up and says so" "$give_up"
fi
if grep -q '^cccc3333 3$' "$WSTATE"; then
  pass "giving up records the attempt count at the cap"
else
  diag=$(dump "$WSTATE")
  fail "giving up records the attempt count at the cap" "$diag"
fi

# Past the cap the session is terminal: no further attempts, even though the
# database still reports it ready.
rm -f "$CALLS"
expect_watch_rc "a capped session is no longer attempted" 0 --once
absent "a capped session invokes nothing further" "$CALLS"

# A success after a failure must clear the count back to 0, so a transient
# failure does not permanently consume the session's budget.
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'dddd4444'; UPDATE session SET isBeingRetranscribed = 0 WHERE id = x'dddd4444';"
watch_failing --once >/dev/null 2>&1 || true
if grep -q '^dddd4444 1$' "$WSTATE"; then
  pass "transient failure records an attempt"
else
  diag=$(dump "$WSTATE")
  fail "transient failure records an attempt" "$diag"
fi
watch --once >/dev/null 2>&1 || true
if grep -q '^dddd4444 done$' "$WSTATE"; then
  pass "a later success clears the attempt count"
else
  diag=$(dump "$WSTATE")
  fail "a later success clears the attempt count" "$diag"
fi

# --- locking ---

watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'eeee5555'; UPDATE session SET isTransient = 0 WHERE id = x'eeee5555';"
rm -f "$CALLS"
# Hold the lock as a live process would: a directory with our own pid, which
# is alive by definition, so the watcher must decline rather than reclaim.
mkdir -p "$WSTATE.lock"
printf '%s\n' "$$" >"$WSTATE.lock/pid"
printf '%s\n' "$EPOCHSECONDS" >"$WSTATE.lock/born"
expect_watch_rc "a held lock makes the run exit 0" 0 --once
absent "a held lock prevents a concurrent transcription" "$CALLS"

# A lock whose owner is gone must be reclaimed, or one crashed run would
# wedge the watcher permanently. pid 2^31-1 cannot be live.
printf '%s\n' "2147483647" >"$WSTATE.lock/pid"
expect_watch_rc "a stale lock is reclaimed" 0 --once
exists "a reclaimed lock lets the transcription run" "$CALLS"
absent "the lock is released after the run" "$WSTATE.lock"

# --- log handling ---

watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'ffff6666'; UPDATE session SET dateDeleted = NULL WHERE id = x'ffff6666';"
watch --once >/dev/null 2>&1 || true
exists "a run writes the log file" "$WLOG"
if grep -qF "ffff6666" "$WLOG"; then
  pass "the log names the transcribed session"
else
  diag=$(dump "$WLOG")
  fail "the log names the transcribed session" "$diag"
fi

# The log is capped: a log already over the limit is rotated aside rather
# than appended to forever.
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'aaaa7777';"
head -c 2000000 /dev/zero | tr '\0' 'x' >"$WLOG"
env HUDDLE_DB="$WDB" HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
  HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" HUDDLE_MIN_DURATION=30 \
  CALLS="$CALLS" "$WATCH" --once >/dev/null 2>&1 || true
exists "an oversized log is rotated aside" "$WLOG.1"
new_size=$(wc -c <"$WLOG")
if ((new_size < 1000000)); then
  pass "the rotated-in log starts small"
else
  fail "the rotated-in log starts small" "$new_size bytes"
fi

# --- database is only ever read ---

watch_reset
db_before=$(cksum <"$WDB")
watch --once >/dev/null 2>&1 || true
watch --list >/dev/null 2>&1 || true
watch --dry-run >/dev/null 2>&1 || true
db_after=$(cksum <"$WDB")
if [[ "$db_before" == "$db_after" ]]; then
  pass "the watcher never modifies the MacWhisper database"
else
  fail "the watcher never modifies the MacWhisper database"
fi

# A read-only database file must still work: the watcher opens it with
# -readonly and a mode=ro URI, so a non-writable file is not an error.
chmod 444 "$WDB"
expect_watch_rc "a read-only database file still queries" 0 --list
chmod 644 "$WDB"

# --- missing dependencies -------------------------------------------

# A missing database reports itself rather than surfacing as a SQL error.
missing_out=$(env HUDDLE_DB="$WORK/no-such.sqlite" \
  HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
  HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" \
  "$WATCH" --once 2>&1 || true)
if grep -qF "not readable" <<<"$missing_out"; then
  pass "a missing database names itself"
else
  fail "a missing database names itself" "$missing_out"
fi

# A missing huddle-transcribe is reported, not silently skipped.
# Rebuild the fixture first: the tests above mutated several rows into the
# ready state, and this case needs a session that is pending AFTER seeding.
build_watch_db
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'bbbb2222';"
nobin_rc=0
env HUDDLE_DB="$WDB" HUDDLE_TRANSCRIBE_BIN="$WORK/no-such-bin" \
  HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" \
  "$WATCH" --once >/dev/null 2>&1 || nobin_rc=$?
if [[ $nobin_rc -ne 0 ]]; then
  pass "a missing huddle-transcribe exits non-zero"
else
  fail "a missing huddle-transcribe exits non-zero"
fi
if grep -q '^bbbb2222' "$WSTATE"; then
  fail "a missing huddle-transcribe does not mark the session seen"
else
  pass "a missing huddle-transcribe does not mark the session seen"
fi

# --- HUDDLE_MIN_DURATION validation ---------------------------------
#
# MIN_DURATION_SECONDS is interpolated into SQL and also reaches a bash
# arithmetic context, so an unvalidated value was exploitable two ways. Both
# are checked here, on every path that reads it.

# watch_env <VALUE> <args...>: run the watcher with a chosen
# HUDDLE_MIN_DURATION, capturing combined output.
watch_min_dur() {
  local value="$1"
  shift
  env HUDDLE_DB="$WDB" HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
    HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" \
    HUDDLE_MIN_DURATION="$value" CALLS="$CALLS" \
    "$WATCH" "$@" 2>&1
}

build_watch_db
watch_reset

# The exact payload from the review: a UNION that appends an attacker-chosen
# row to the result set. Those rows drive the loop that feeds session ids to
# huddle-transcribe, so this is arbitrary-session-id injection, not merely a
# malformed query.
inj_payload='0 UNION SELECT 999 --'
for inj_mode in --dry-run --list --once; do
  inj_rc=0
  inj_out=$(watch_min_dur "$inj_payload" "$inj_mode") || inj_rc=$?
  if [[ $inj_rc -ne 0 ]] && grep -qF "HUDDLE_MIN_DURATION must be a whole number" <<<"$inj_out"; then
    pass "SQL injection payload is rejected ($inj_mode)"
  else
    fail "SQL injection payload is rejected ($inj_mode)" "exit $inj_rc: $inj_out"
  fi
done

# A 4-column UNION matches the SELECT list's shape, so without validation it
# parses cleanly and injects a usable session id rather than erroring.
inj_shaped="0 UNION SELECT 'deadbeefcafe','2026-01-01 00:00:00',999,'INJECTED' --"
inj_out=$(watch_min_dur "$inj_shaped" --dry-run || true)
# The payload text appears in the rejection message itself, so matching on it
# directly would pass for the wrong reason. Assert on the injected row's
# OBSERVABLE effect instead: a "would transcribe" line for the injected id.
if grep -qE 'would transcribe +deadbeef' <<<"$inj_out"; then
  fail "a shape-matched UNION injects no session" "$inj_out"
else
  pass "a shape-matched UNION injects no session"
fi
if grep -qF "must be a whole number" <<<"$inj_out"; then
  pass "a shape-matched UNION is rejected by validation"
else
  fail "a shape-matched UNION is rejected by validation" "$inj_out"
fi

# The arithmetic context: (( )) recursively evaluates a bare NAME, so an
# array-subscript payload naming a DEFINED variable executes its command
# substitution. --list reaches `((dur_int > MIN_DURATION_SECONDS))`.
rm -f "$WORK/ARITHPWN"
arith_out=$(watch_min_dur "LOG_MAX_BYTES[\$(touch $WORK/ARITHPWN)]" --list || true)
if [[ -e "$WORK/ARITHPWN" ]]; then
  fail "an arithmetic payload does not execute" "ARITHPWN was created"
  rm -f "$WORK/ARITHPWN"
else
  pass "an arithmetic payload does not execute"
fi
if grep -qF "HUDDLE_MIN_DURATION must be a whole number" <<<"$arith_out"; then
  pass "an arithmetic payload is reported as a validation error"
else
  fail "an arithmetic payload is reported as a validation error" "$arith_out"
fi

# Empty, negative, and fractional values are all rejected rather than
# silently coerced.
for bad_dur in "" "-5" "3.5" "30 " "abc"; do
  bad_rc=0
  bad_out=$(watch_min_dur "$bad_dur" --dry-run) || bad_rc=$?
  if [[ $bad_rc -ne 0 ]] && grep -qF "HUDDLE_MIN_DURATION must be a whole number" <<<"$bad_out"; then
    pass "HUDDLE_MIN_DURATION='$bad_dur' is rejected"
  else
    fail "HUDDLE_MIN_DURATION='$bad_dur' is rejected" "exit $bad_rc: $bad_out"
  fi
done

# A legitimate value still works, so the validator is not simply refusing
# everything.
good_out=$(watch_min_dur 30 --dry-run || true)
if grep -qF "aaaa7777" <<<"$good_out"; then
  pass "a valid HUDDLE_MIN_DURATION is still honored"
else
  fail "a valid HUDDLE_MIN_DURATION is still honored" "$good_out"
fi

# --- state file robustness -------------------------------------------

# A malformed state line must NOT read as "successfully transcribed". When
# success was encoded as attempts=0 and an unparseable field was coerced to
# 0, a truncated line silently made the session terminal forever.
build_watch_db
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'bbbb2222';"
# Replace the record with a partial write: an id-only line with no status.
printf 'bbbb2222\n' >"$WSTATE"
rm -f "$CALLS"
watch --once >/dev/null 2>&1 || true
if [[ -f "$CALLS" ]] && grep -q 'bbbb2222' "$CALLS"; then
  pass "a malformed state line is not treated as done"
else
  diag=$(dump "$CALLS")
  fail "a malformed state line is not treated as done" "$diag"
fi
if grep -qF "malformed state line" "$WLOG" 2>/dev/null; then
  pass "a malformed state line is logged"
else
  diag=$(dump "$WLOG")
  fail "a malformed state line is logged" "$diag"
fi

# A final line with no trailing newline must still be read. `while read -r`
# returns false on an unterminated line, which used to discard that record.
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'bbbb2222';"
printf 'bbbb2222 done' >"$WSTATE" # deliberately no trailing newline
rm -f "$CALLS"
watch --once >/dev/null 2>&1 || true
if [[ -f "$CALLS" ]] && grep -q 'bbbb2222' "$CALLS"; then
  diag=$(dump "$CALLS")
  fail "an unterminated final state line is still honored" "$diag"
else
  pass "an unterminated final state line is still honored"
fi

# A legacy `<id> 0` record still means done, so an existing state file does
# not re-transcribe its whole backlog after the sentinel change.
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'bbbb2222';"
printf 'bbbb2222 0\n' >"$WSTATE"
rm -f "$CALLS"
watch --once >/dev/null 2>&1 || true
if [[ -f "$CALLS" ]] && grep -q 'bbbb2222' "$CALLS"; then
  diag=$(dump "$CALLS")
  fail "a legacy '<id> 0' record is still treated as done" "$diag"
else
  pass "a legacy '<id> 0' record is still treated as done"
fi

# An EMPTY state file is a first run, not a fully-seen backlog. Gated on -f
# rather than -s, a zero-byte file skipped seeding and every ready session
# looked pending, transcribing the entire backlog.
build_watch_db
watch_reset
: >"$WSTATE" # zero-byte file, as an interrupted mv leaves behind
rm -f "$CALLS"
watch --once >/dev/null 2>&1 || true
absent "an empty state file transcribes nothing" "$CALLS"
empty_seeded=$(grep -c . "$WSTATE" || true)
if [[ "$empty_seeded" == "2" ]]; then
  pass "an empty state file is treated as first-run and seeded"
else
  diag=$(dump "$WSTATE")
  fail "an empty state file is treated as first-run and seeded" \
    "seeded $empty_seeded, wanted 2: $diag"
fi

# --- state_set failure after a successful transcription ---------------

# state_set had no error handling under `set -euo pipefail`, so a failing
# mktemp (full disk, read-only home) killed the script AFTER
# huddle-transcribe had already succeeded but BEFORE the success was
# recorded: the next firing re-transcribed it and every remaining queue
# entry was silently dropped. The failure must now be loud and non-fatal.
#
# Skipped as root, which can write to a 0500 directory regardless of mode.
# Exercised as a focused unit test of state_set rather than through a full
# run. Driving it end-to-end is not possible: the only lever that makes
# mktemp fail is an unwritable state DIRECTORY, and LOCK_DIR is
# "${STATE_FILE}.lock" -- a sibling in that same directory -- so the lock
# cannot be claimed either and the run exits before state_set is ever
# reached. The function is sourced out of the real script so the code under
# test is the shipped code.
test_uid=$(id -u)
if [[ "$test_uid" -ne 0 ]]; then
  STATE_UNIT="$WORK/state_set_unit.sh"
  {
    printf 'set -euo pipefail\nSTATE_DONE="done"\n'
    sed -n '/^state_set() {/,/^}/p' "$WATCH"
    cat <<'UNIT'
STATE_FILE="$1"
rc=0
state_set "abcd1234" "done" || rc=$?
printf 'state_set_rc=%s\n' "$rc"
printf 'reached_end=yes\n'
UNIT
  } >"$STATE_UNIT"
  STATE_UNIT_DIR="$WORK/rostate"
  rm -rf "$STATE_UNIT_DIR"
  mkdir -p "$STATE_UNIT_DIR"
  printf 'zzzz1111 done\n' >"$STATE_UNIT_DIR/state"

  # Control: a writable directory must succeed, so the failure case below is
  # attributable to the permissions and not to the harness.
  unit_ok=$(bash "$STATE_UNIT" "$STATE_UNIT_DIR/state" 2>&1 || true)
  if grep -qF 'state_set_rc=0' <<<"$unit_ok"; then
    pass "state_set succeeds when the state directory is writable"
  else
    fail "state_set succeeds when the state directory is writable" "$unit_ok"
  fi

  chmod 500 "$STATE_UNIT_DIR" # mktemp beside the state file now fails
  unit_out=$(bash "$STATE_UNIT" "$STATE_UNIT_DIR/state" 2>&1 || true)
  chmod 700 "$STATE_UNIT_DIR"
  # It must report failure via its exit status...
  if grep -qF 'state_set_rc=1' <<<"$unit_out"; then
    pass "state_set reports a failed write instead of aborting"
  else
    fail "state_set reports a failed write instead of aborting" "$unit_out"
  fi
  # ...and must not have carried on past the failed mktemp with an empty $tmp,
  # which is what produced "mv: : No such file or directory" and left the
  # caller's queue in an undefined state.
  if grep -qE 'mv: |No such file or directory' <<<"$unit_out"; then
    fail "a failed mktemp does not fall through to an empty temp path" "$unit_out"
  else
    pass "a failed mktemp does not fall through to an empty temp path"
  fi
  # The caller must still be able to continue with the rest of the queue.
  if grep -qF 'reached_end=yes' <<<"$unit_out"; then
    pass "a failed state write leaves the caller able to continue"
  else
    fail "a failed state write leaves the caller able to continue" "$unit_out"
  fi
  rm -rf "$STATE_UNIT_DIR"
else
  pass "state_set succeeds when the state directory is writable (skipped: root)"
  pass "state_set reports a failed write instead of aborting (skipped: root)"
  pass "a failed mktemp does not fall through to an empty temp path (skipped: root)"
  pass "a failed state write leaves the caller able to continue (skipped: root)"
fi

# The success path must log loudly when it cannot record a completed
# transcription, since the session will otherwise be re-transcribed silently.
if grep -qF 'could not record success for' "$WATCH"; then
  pass "the success path logs a failed state write"
else
  fail "the success path logs a failed state write"
fi

# --- lock robustness --------------------------------------------------

# A lock directory with no pid file must be treated as HELD. It is a claim
# whose owner has not finished writing its metadata yet; reading owner="" used
# to skip the liveness guard entirely and reclaim a live owner's lock, and
# both runs then transcribed the same session.
build_watch_db
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'bbbb2222';"
rm -f "$CALLS"
rm -rf "$WSTATE.lock"
mkdir -p "$WSTATE.lock" # no pid, no born: mid-claim
expect_watch_rc "a lock missing its pid file exits 0" 0 --once
absent "a lock missing its pid file is treated as held" "$CALLS"

# A pid file that is present but unparseable is equally untrustworthy.
printf 'not-a-pid\n' >"$WSTATE.lock/pid"
rm -f "$CALLS"
expect_watch_rc "a lock with an unparseable pid exits 0" 0 --once
absent "a lock with an unparseable pid is treated as held" "$CALLS"

# A live owner whose `born` file is missing must NOT have its lock stolen.
# Forcing born=0 made age ~1.79e9, which always exceeded LOCK_MAX_AGE_SECONDS.
printf '%s\n' "$$" >"$WSTATE.lock/pid"
rm -f "$WSTATE.lock/born"
rm -f "$CALLS"
expect_watch_rc "a live lock with no born file exits 0" 0 --once
absent "a missing born file does not steal a live lock" "$CALLS"

# The positive control: a genuinely dead owner is still reclaimed, so the
# fail-closed changes above cannot wedge the watcher permanently.
printf '%s\n' "2147483647" >"$WSTATE.lock/pid"
printf '%s\n' "$EPOCHSECONDS" >"$WSTATE.lock/born"
rm -f "$CALLS"
expect_watch_rc "a dead owner's lock is still reclaimed" 0 --once
exists "a reclaimed lock still lets the transcription run" "$CALLS"

# The claim must never publish a lock without its metadata: a lock this
# script holds always has a readable, live pid.
rm -rf "$WSTATE.lock"

# --- sql() keeps stderr out of the data stream ------------------------

# On a SUCCESSFUL query, anything sqlite3 wrote to stderr must not be
# returned as query output -- a warning line would otherwise be parsed as a
# data row whose first field becomes a session id.
build_watch_db
watch_reset
SQLSHIM="$WORK/sqlshim"
mkdir -p "$SQLSHIM"
cat >"$SQLSHIM/sqlite3" <<'STUB'
#!/usr/bin/env bash
# Emit a warning on stderr, then behave like the real sqlite3. Exits 0, so
# this is the successful-query path.
echo "sqlite3: WARNING recovered 1 frames from WAL file" >&2
exec /usr/bin/env -u PATH_SHIM "$REAL_SQLITE3" "$@"
STUB
chmod +x "$SQLSHIM/sqlite3"
REAL_SQLITE3=$(command -v sqlite3)
export REAL_SQLITE3
rm -f "$CALLS"
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'bbbb2222';"
: >"$WSTATE" # first-run seeding path, so the rows are only parsed
stderr_probe_out=$(env PATH="$SQLSHIM:$PATH" HUDDLE_DB="$WDB" \
  HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
  HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" CALLS="$CALLS" \
  "$WATCH" --once 2>&1 || true)
# A successful query must not surface sqlite3's stderr as script output.
if grep -qF "recovered 1 frames" <<<"$stderr_probe_out"; then
  fail "a successful query does not echo sqlite3 stderr as output" "$stderr_probe_out"
else
  pass "a successful query does not echo sqlite3 stderr as output"
fi
# The warning text must never appear in the state file as a seeded "session".
if grep -qF "WARNING" "$WSTATE" 2>/dev/null || grep -qF "sqlite3" "$WSTATE" 2>/dev/null; then
  diag=$(dump "$WSTATE")
  fail "stderr from a successful query does not become a data row" "$diag"
else
  pass "stderr from a successful query does not become a data row"
fi
if grep -qF "recovered" "$WSTATE" 2>/dev/null; then
  diag=$(dump "$WSTATE")
  fail "a stderr warning is not seeded as a session id" "$diag"
else
  pass "a stderr warning is not seeded as a session id"
fi
unset REAL_SQLITE3

# --- log file handling ------------------------------------------------

# The log carries meeting titles and huddle-transcribe's full output, so it
# must not be world-readable. `>>` alone yields 0644 under umask 022.
build_watch_db
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'bbbb2222';"
watch --once >/dev/null 2>&1 || true
if [[ -f "$WLOG" ]]; then
  log_mode=$(stat -f '%Lp' "$WLOG" 2>/dev/null || stat -c '%a' "$WLOG" 2>/dev/null || echo "?")
  if [[ "$log_mode" == "600" ]]; then
    pass "the log file is created mode 0600"
  else
    fail "the log file is created mode 0600" "mode was $log_mode"
  fi
else
  fail "the log file is created mode 0600" "no log file at $WLOG"
fi

# The plist must point launchd at a DIFFERENT path from the one the script
# rotates. launchd opens its path once and holds that fd for the life of the
# job, so when both were $LOG_FILE the `mv -f` in rotation left launchd
# writing into the rotated-aside inode (now <log>.1) while the script wrote a
# fresh <log>, splitting one run's output across two files.
#
# Asserted on the generated plist rather than on the script text, so the test
# tracks what launchd is actually told. plutil is macOS-only, hence the guard:
# on a Linux runner this reduces to the value check below.
if command -v plutil >/dev/null 2>&1; then
  # `launchctl` is shadowed by a no-op stub for this probe. --install would
  # otherwise `launchctl bootstrap` a REAL LaunchAgent onto the developer's
  # machine, which the suite must never do. HOME is repointed too, so the
  # plist lands in the fixture rather than in ~/Library/LaunchAgents.
  mkdir -p "$WORK/fakehome" "$WBIN"
  cat >"$WBIN/launchctl" <<'STUB'
#!/usr/bin/env bash
# Deliberately inert: report failure so do_install never claims a load.
exit 1
STUB
  chmod +x "$WBIN/launchctl"
  probe_out=$(env PATH="$WBIN:$PATH" HUDDLE_DB="$WDB" \
    HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
    HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" \
    HOME="$WORK/fakehome" "$WATCH" --install 2>&1 || true)
  generated=$(find "$WORK/fakehome" -name '*.plist' 2>/dev/null | head -1)
  if [[ -n "$generated" ]]; then
    std_out_path=$(plutil -extract StandardOutPath raw -o - "$generated" 2>/dev/null || echo "?")
    std_err_path=$(plutil -extract StandardErrorPath raw -o - "$generated" 2>/dev/null || echo "?")
    if [[ "$std_out_path" != "$WLOG" && "$std_err_path" != "$WLOG" ]]; then
      pass "the plist does not point launchd at the self-rotated log"
    else
      fail "the plist does not point launchd at the self-rotated log" \
        "StandardOutPath=$std_out_path StandardErrorPath=$std_err_path equals \$LOG_FILE $WLOG"
    fi
    if [[ "$std_out_path" == "$WLOG."* ]]; then
      pass "the plist points launchd at a log path derived from \$LOG_FILE"
    else
      fail "the plist points launchd at a log path derived from \$LOG_FILE" \
        "StandardOutPath=$std_out_path"
    fi
  else
    fail "the plist does not point launchd at the self-rotated log" \
      "no plist generated: $probe_out"
  fi
  rm -rf "$WORK/fakehome"
else
  # No plutil (Linux CI): assert the two paths are distinct values, which is
  # the property the plist inherits.
  # Built by concatenation so the ${...} is never inside single quotes,
  # where shellcheck would (correctly) flag it as a non-expanding expression.
  launchd_literal='LAUNCHD_LOG_FILE="'"\${LOG_FILE}"
  if grep -qF "$launchd_literal" "$WATCH"; then
    pass "the launchd log path is distinct from the rotated log path"
  else
    fail "the launchd log path is distinct from the rotated log path"
  fi
fi

# The transcript blob appended after a run must be bounded too: checking only
# the pre-existing size let one run overshoot the cap by its whole output.
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'cccc3333'; UPDATE session SET transcriptionDidSucceed = 1 WHERE id = x'cccc3333';"
# A stub whose output alone exceeds LOG_MAX_BYTES.
cat >"$WBIN/huddle-transcribe-big" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
head -c 1500000 /dev/zero | tr '\0' 'y'
echo "Transcript written: /tmp/out/big.txt"
STUB
chmod +x "$WBIN/huddle-transcribe-big"
env HUDDLE_DB="$WDB" HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe-big" \
  HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" CALLS="$CALLS" \
  "$WATCH" --once >/dev/null 2>&1 || true
if [[ -f "$WLOG" ]]; then
  blob_size=$(wc -c <"$WLOG")
  blob_size="${blob_size//[[:space:]]/}"
  # The cap is 1048576. A single oversized blob must trigger rotation rather
  # than being appended on top of the existing log.
  if ((blob_size <= 1600000)); then
    pass "an oversized transcript blob is bounded by rotation"
  else
    fail "an oversized transcript blob is bounded by rotation" "$blob_size bytes"
  fi
else
  fail "an oversized transcript blob is bounded by rotation" "no log file"
fi

# --- --status ---------------------------------------------------------

# `grep -c .` prints 0 AND exits 1 on an empty file, so a `|| echo 0`
# fallback appended a second zero and the count printed as "0\n0".
build_watch_db
watch_reset
# A file of only newlines is the case that triggers it: non-empty, so it
# passes the -s gate and reaches the count, but NO line contains a character,
# so `grep -c .` prints 0 and exits 1 -- and the `|| echo 0` fallback then
# appended a second zero, printing the count as "0\n0". A zero-byte file
# cannot reach this branch at all, so testing with one proves nothing.
printf '\n\n\n' >"$WSTATE"
status_out=$(watch --status 2>&1 || true)
# The stray zero lands on its own line, which is what to assert on.
if grep -qE '^0$' <<<"$status_out"; then
  fail "--status prints no stray bare zero" "$status_out"
else
  pass "--status prints no stray bare zero"
fi
# The count must render as a single number inside the State: line.
if grep -qE 'State:.*\([0-9]+ session\(s\) recorded\)' <<<"$status_out"; then
  pass "--status prints a single well-formed count"
else
  fail "--status prints a single well-formed count" "$status_out"
fi
# A genuinely zero-byte state file is reported as the pending first run it
# will be treated as, rather than as a populated one.
: >"$WSTATE"
status_empty_out=$(watch --status 2>&1 || true)
if grep -qF "empty; next run seeds it" <<<"$status_empty_out"; then
  pass "--status reports an empty state file as a pending first run"
else
  fail "--status reports an empty state file as a pending first run" "$status_empty_out"
fi

# A populated state file reports an accurate count.
printf 'aaaa1111 done\nbbbb8888 done\n' >"$WSTATE"
status_out=$(watch --status 2>&1 || true)
if grep -qF "(2 session(s) recorded)" <<<"$status_out"; then
  pass "--status counts recorded sessions correctly"
else
  fail "--status counts recorded sessions correctly" "$status_out"
fi

# Sessions abandoned at the attempt cap must be visible somewhere.
printf 'aaaa1111 done\ncccc3333 3\n' >"$WSTATE"
status_out=$(watch --status 2>&1 || true)
if grep -qF "Given up:" <<<"$status_out" && grep -qF "cccc3333" <<<"$status_out"; then
  pass "--status surfaces given-up sessions"
else
  fail "--status surfaces given-up sessions" "$status_out"
fi
if grep -qF -- "--retry" <<<"$status_out"; then
  pass "--status names the --retry escape hatch"
else
  fail "--status names the --retry escape hatch" "$status_out"
fi

# --- --retry ----------------------------------------------------------

# The escape hatch for the attempt cap: without it, three transient failures
# abandoned a real meeting permanently.
build_watch_db
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'bbbb2222';"
# Every OTHER ready session must be marked done as well, or it would be
# transcribed here and create $CALLS for a reason unrelated to the cap.
printf 'aaaa1111 done\nbbbb8888 done\nbbbb2222 3\n' >"$WSTATE"
rm -f "$CALLS"
# Confirm the session really is terminal before the retry, so the test proves
# the escape hatch rather than a session that would have run anyway.
watch --once >/dev/null 2>&1 || true
absent "a capped session is terminal before --retry" "$CALLS"
expect_watch_rc "--retry exits 0" 0 --retry bbbb2222
if grep -q 'bbbb2222' "$WSTATE"; then
  diag=$(dump "$WSTATE")
  fail "--retry clears the session's record" "$diag"
else
  pass "--retry clears the session's record"
fi
rm -f "$CALLS"
watch --once >/dev/null 2>&1 || true
if [[ -f "$CALLS" ]] && grep -q 'bbbb2222' "$CALLS"; then
  pass "a retried session is transcribed again"
else
  diag=$(dump "$CALLS")
  fail "a retried session is transcribed again" "$diag"
fi

# --retry must not clear a different session, and must validate its argument.
printf 'aaaa1111 done\nbbbb8888 done\n' >"$WSTATE"
watch --retry aaaa1111 >/dev/null 2>&1 || true
if grep -q 'bbbb8888' "$WSTATE"; then
  pass "--retry leaves other sessions' records intact"
else
  diag=$(dump "$WSTATE")
  fail "--retry leaves other sessions' records intact" "$diag"
fi
# A prefix must not clear a full record: the id field is matched exactly.
printf 'aaaa1111 done\n' >"$WSTATE"
watch --retry aaaa >/dev/null 2>&1 || true
if grep -q 'aaaa1111' "$WSTATE"; then
  pass "--retry does not clear a record by prefix"
else
  diag=$(dump "$WSTATE")
  fail "--retry does not clear a record by prefix" "$diag"
fi
expect_watch_rc "--retry rejects a non-hex id" 1 --retry 'not-hex!'
expect_watch_rc "--retry requires an argument" 1 --retry
# A dashed UUID from MacWhisper's UI is normalized like huddle-transcribe does.
printf 'aaaa1111 done\n' >"$WSTATE"
watch --retry 'aaaa-1111' >/dev/null 2>&1 || true
if grep -q 'aaaa1111' "$WSTATE"; then
  diag=$(dump "$WSTATE")
  fail "--retry normalizes a dashed uuid" "$diag"
else
  pass "--retry normalizes a dashed uuid"
fi

# --- notifications ----------------------------------------------------
#
# notify() previously guarded only on `command -v osascript`, which succeeds
# on every real Mac, so running this suite posted real desktop alerts. The
# whole suite is routed through a stub via HUDDLE_NOTIFY_BIN; these cases
# assert the override works and cover the notification text, which was
# untested.

build_watch_db
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'bbbb2222';"
notify_reset
watch --once >/dev/null 2>&1 || true
if [[ -f "$NOTIFYLOG" ]]; then
  pass "a successful run posts a notification through the override"
else
  fail "a successful run posts a notification through the override" \
    "no notification recorded at $NOTIFYLOG"
fi
# The success notification names the transcript file, which is what the user
# is actually looking for.
if grep -qF 'with title "Transcript ready"' "$NOTIFYLOG" 2>/dev/null; then
  pass "the success notification is titled 'Transcript ready'"
else
  diag=$(dump "$NOTIFYLOG")
  fail "the success notification is titled 'Transcript ready'" "$diag"
fi
if grep -qF 'bbbb2222.txt' "$NOTIFYLOG" 2>/dev/null; then
  pass "the success notification names the transcript basename"
else
  diag=$(dump "$NOTIFYLOG")
  fail "the success notification names the transcript basename" "$diag"
fi

# HUDDLE_NO_NOTIFY suppresses entirely, checked before the command -v probe.
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'cccc3333'; UPDATE session SET transcriptionDidSucceed = 1 WHERE id = x'cccc3333';"
notify_reset
env HUDDLE_NO_NOTIFY=1 HUDDLE_DB="$WDB" \
  HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
  HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" CALLS="$CALLS" \
  "$WATCH" --once >/dev/null 2>&1 || true
absent "HUDDLE_NO_NOTIFY suppresses notifications" "$NOTIFYLOG"

# The give-up notification must be distinct from the success one and must
# name the log, since that is the only record of what went wrong.
build_watch_db
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET hasBeenDiarized = 1 WHERE id = x'bbbb2222';"
notify_reset
for _attempt in 1 2 3; do
  watch_failing --once >/dev/null 2>&1 || true
done
if grep -qF 'with title "Transcription FAILED"' "$NOTIFYLOG" 2>/dev/null; then
  pass "the give-up notification is titled 'Transcription FAILED'"
else
  diag=$(dump "$NOTIFYLOG")
  fail "the give-up notification is titled 'Transcription FAILED'" "$diag"
fi
if grep -qF "$WLOG" "$NOTIFYLOG" 2>/dev/null; then
  pass "the give-up notification names the log path"
else
  diag=$(dump "$NOTIFYLOG")
  fail "the give-up notification names the log path" "$diag"
fi
if grep -qF "Transcript ready" "$NOTIFYLOG" 2>/dev/null; then
  diag=$(dump "$NOTIFYLOG")
  fail "the give-up notification is distinct from the success one" "$diag"
else
  pass "the give-up notification is distinct from the success one"
fi

# --- AppleScript escaping ---------------------------------------------
#
# The title is interpolated into an AppleScript string, so a title containing
# a quote could close that string and append statements. Escaping is
# backslash-first then quote, and that ORDER is load-bearing: reversing it
# would re-escape the backslashes introduced by the quote pass.
#
# The notification body falls back to the session title when
# huddle-transcribe prints no "Transcript written:" line, which is the path
# that puts an untrusted title into the AppleScript.
build_watch_db
sqlite3 "$WDB" "INSERT INTO recordedmeeting VALUES (x'8f', 900.0, 'rmHostileTitle');"
sqlite3 "$WDB" "INSERT INTO session VALUES (x'beef7777', '2026-08-17 10:00:00.000', 'x\" & (do shell script \"touch $WORK/APPLEPWNED\") & \"y back\\slash', NULL, x'8f', NULL, 1, 1, 0, 0, NULL, NULL);"
# A stub that succeeds but prints nothing, forcing the title-fallback path.
cat >"$WBIN/huddle-transcribe-silent" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
exit 0
STUB
chmod +x "$WBIN/huddle-transcribe-silent"
# Clear the canary BEFORE any run that could create it. Removing it after a
# run destroys the evidence the assertion below looks for, which makes this
# test -- the only one guarding AppleScript injection -- pass even when the
# payload fires.
rm -f "$WORK/APPLEPWNED"
watch_reset
watch --once >/dev/null 2>&1 || true
notify_reset
# Mark everything else done so only the hostile-titled session runs.
printf 'beef7777 retry\n' >"$WSTATE"
env HUDDLE_DB="$WDB" HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe-silent" \
  HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" CALLS="$CALLS" \
  "$WATCH" --once >/dev/null 2>&1 || true
if [[ -e "$WORK/APPLEPWNED" ]]; then
  fail "a hostile title does not execute via AppleScript" "APPLEPWNED was created"
  rm -f "$WORK/APPLEPWNED"
else
  pass "a hostile title does not execute via AppleScript"
fi
# The quote must arrive escaped, so it cannot terminate the AppleScript
# string literal.
if grep -qF '\"' "$NOTIFYLOG" 2>/dev/null; then
  pass "a double quote in a title is backslash-escaped"
else
  diag=$(dump "$NOTIFYLOG")
  fail "a double quote in a title is backslash-escaped" "$diag"
fi
# The backslash must be doubled.
if grep -qF 'back\\slash' "$NOTIFYLOG" 2>/dev/null; then
  pass "a backslash in a title is doubled"
else
  diag=$(dump "$NOTIFYLOG")
  fail "a backslash in a title is doubled" "$diag"
fi
# `do shell script` must survive only as inert text inside the quoted string,
# never as a statement: an unescaped quote before it is what would make it
# executable.
if grep -qE 'display notification "([^"\\]|\\.)*" with title' "$NOTIFYLOG" 2>/dev/null; then
  pass "the AppleScript body remains a single well-formed string literal"
else
  diag=$(dump "$NOTIFYLOG")
  fail "the AppleScript body remains a single well-formed string literal" "$diag"
fi

# --- --once is required, not inert ------------------------------------

# --once used to end the script as `[[ $ONCE -eq 1 ]] || true`, a literal
# no-op: behavior was identical with or without it.
build_watch_db
watch_reset
bare_rc=0
bare_out=$(watch 2>&1) || bare_rc=$?
if [[ $bare_rc -ne 0 ]] && grep -qF -- "--once is required" <<<"$bare_out"; then
  pass "a bare invocation requires --once"
else
  fail "a bare invocation requires --once" "exit $bare_rc: $bare_out"
fi
absent "a bare invocation writes no state file" "$WSTATE"
absent "a bare invocation transcribes nothing" "$CALLS"
# --dry-run and --list still work without --once, since neither processes.
expect_watch_rc "--dry-run works without --once" 0 --dry-run
expect_watch_rc "--list works without --once" 0 --list

# --- summary -----------------------------------------------------------

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
