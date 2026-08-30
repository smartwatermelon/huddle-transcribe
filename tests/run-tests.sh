#!/usr/bin/env bash
# Behavioral tests for huddle-transcribe.
#
# MacWhisper and its `mw` CLI are macOS-only and cannot be installed on a CI
# runner, so these tests build a synthetic MacWhisper database (the four
# tables SESSION_QUERY touches) plus a stub `mw`, then run the real script
# against them with DB/MEDIA_DIR/MW_BIN/CONFIG_FILE repointed.
#
# What is NOT covered: the real `mw` binary's flag handling and transcription
# output. Everything the script itself does -- argument parsing, session
# selection, row parsing, output naming, and the --mark-reviewed guards --
# is exercised here.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SCRIPT="$REPO_ROOT/huddle-transcribe"

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

# --- summary -----------------------------------------------------------

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
