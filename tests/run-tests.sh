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
# install.sh runs on temp dirs with stubbed huddle-watch and launchctl,
# so it never touches the real HOME or loads a job.
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
MIGRATE="$REPO_ROOT/huddle-migrate-md"

PASS=0
FAIL=0
SKIP=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# True when <bash-path> satisfies the script's bash 4.2+ requirement.
# The version test runs INSIDE the candidate, since that is the only way to
# learn its version. `-c` receives the expression via a positional parameter
# rather than an inlined literal so nothing here needs single-quote quoting
# that shellcheck would read as a failed expansion.
bash_is_modern() {
  local candidate="$1"
  [[ -x "$candidate" ]] || return 1
  # Read the version from `bash --version` rather than by running shell code
  # in the candidate. Any `-c` payload that reads a variable needs single
  # quotes to defer expansion to the child, which shellcheck reports as
  # SC2016; --version passes no code at all, so the check has nothing to flag
  # and no directive is needed.
  local ver major minor
  ver=$("$candidate" --version 2>/dev/null | head -1) || return 1
  ver="${ver#*version }"
  ver="${ver%%[!0-9.]*}"
  major="${ver%%.*}"
  minor="${ver#*.}"
  minor="${minor%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  ((major > 4 || (major == 4 && minor >= 2)))
}

pass() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [[ $# -lt 2 ]] || printf '        %s\n' "$2"
}

# A precondition the runner cannot supply -- counted separately so it can
# never be mistaken for coverage that ran. Used for the bash-3.2 guard check,
# which needs a real bash <4.2 and so is macOS-only.
skip() {
  SKIP=$((SKIP + 1))
  printf '  skip  %s\n' "$1"
}

# --- fixture -----------------------------------------------------------

MEDIA="$WORK/media"
DB="$WORK/db.sqlite"
BIN="$WORK/bin"
mkdir -p "$MEDIA" "$BIN"

# Stub mw: writes a plausible diarized transcript to whatever -o names, and
# records its full argument list in $MW_CALLS so the flags the script passes
# are assertable. The transcript body mirrors the real `mw --format md
# --end-timestamps` shape -- label / italicized start-end timestamp / body /
# blank -- because the speaker-label smoke test and the rewrite planned in
# docs/plans/speaker-name-attribution.md both anchor on those line forms.
cat >"$BIN/mw" <<'STUB'
#!/usr/bin/env bash
[[ -n "${MW_CALLS:-}" ]] && printf '%s\n' "$*" >>"$MW_CALLS"
out="" in=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      in="$1"
      shift
      ;;
  esac
done
[[ -n "$out" ]] || exit 2
# MW_FAIL_MATCH fails one input; MW_LONG adds a block past the hour.
[[ -z "${MW_FAIL_MATCH:-}" || "$in" != *"$MW_FAIL_MATCH"* ]] || exit 3
printf 'Speaker 1\n*00:00-00:06*\nhello from %s\n\nSpeaker 2\n*00:06-00:12*\nhi there\n\n' "${in##*/}" >"$out"
[[ -z "${MW_LONG:-}" ]] || printf 'Speaker 1\n*59:50-01:00:02*\nlate\n\n' >>"$out"
# MW_MARK_REVIEWED: flip that sidecar to reviewed mid-run, as a racing --mark-reviewed would.
if [[ -n "${MW_MARK_REVIEWED:-}" ]]; then
  jq '.reviewed = true' "$MW_MARK_REVIEWED" >"$MW_MARK_REVIEWED.tmp" && mv "$MW_MARK_REVIEWED.tmp" "$MW_MARK_REVIEWED"
fi
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
INSERT INTO mediafile VALUES (x'eeee0005', 'mergedMultitrack', 'E_merged.m4a');

-- Non-numeric duration. Bash evaluates arithmetic on this value, and an
-- array-subscript payload would execute if it reached $(( )) unvalidated.
INSERT INTO recordedmeeting VALUES (x'66', 'HOME[$(touch ' || char(34) || 'PWNMARKER' || char(34) || ')0]', 'Hostile');
INSERT INTO session VALUES (x'ffff0006', '2026-08-19 09:00:00.000', 'Hostile Duration', NULL, x'66', NULL);
INSERT INTO mediafile VALUES (x'ffff0006', 'mergedMultitrack', 'F_merged.m4a');

-- Added after the positional inserts above. NULL date/appName keep those
-- sessions out of split-meeting grouping.
ALTER TABLE recordedmeeting ADD COLUMN date TEXT;
ALTER TABLE recordedmeeting ADD COLUMN appName TEXT;
ALTER TABLE recordedmeeting ADD COLUMN bundleIdentifier TEXT;
ALTER TABLE session ADD COLUMN dateDeleted TEXT;
SQL

reset_media() {
  rm -f "$MEDIA"/*.m4a
  touch "$MEDIA/A_merged.m4a" "$MEDIA/B_app.m4a" \
    "$MEDIA/C_merged.m4a" "$MEDIA/D_mic.m4a" "$MEDIA/E_merged.m4a" \
    "$MEDIA/F_merged.m4a"
}

# Build a runnable copy with the five environment constants repointed at the
# fixture. Editing constants is how the script is made testable without
# MacWhisper; the rest of the file is byte-for-byte the shipped script.
#
# DEFAULT_OUTPUT_DIR is repointed too, even though every test below passes
# --output-dir explicitly: any invocation missing --output-dir (there is
# none today, but a future test easily could) must never `mkdir -p` a real
# Drive folder on the machine actually running the suite. The real script
# resolves DEFAULT_OUTPUT_DIR in two steps -- a plain fallback assignment,
# then a conditional override if exactly one GoogleDrive-* mount with a
# knowledge-base/ directory exists under the real $HOME -- and both sed
# rules below target both assignments with the SAME safe value, so the
# result is $OUT regardless of which branch actually fires on this
# machine. The `if` condition itself still runs the glob against the real
# $HOME (harmless: it only stats a directory, never writes), but its
# result can no longer matter.
OUT="$WORK/out"
# build [MW] [DEST] [DB] [OUTPUT_DIR]; the per-recording cache defaults into $WORK.
build() {
  local mw="${1:-$BIN/mw}" dest="${2:-$WORK/ht.sh}" db="${3:-$DB}" out="${4:-$OUT}"
  sed -e "s|^DB=.*|DB=\"$db\"|" \
    -e "s|^MEDIA_DIR=.*|MEDIA_DIR=\"$MEDIA\"|" \
    -e "s|^MW_BIN=.*|MW_BIN=\"$mw\"|" \
    -e "s|^CONFIG_FILE=.*|CONFIG_FILE=\"$WORK/no-such-config\"|" \
    -e "s|^DEFAULT_OUTPUT_DIR=.*|DEFAULT_OUTPUT_DIR=\"$out\"|" \
    -e "s|^  DEFAULT_OUTPUT_DIR=.*|  DEFAULT_OUTPUT_DIR=\"$out\"|" \
    -e "s|^PIECES_DIR=.*|PIECES_DIR=\"\${HUDDLE_PIECES_DIR:-$WORK/pieces}\"|" \
    "$SCRIPT" >"$dest"
  chmod +x "$dest"
  printf '%s\n' "$dest"
}

HT=$(build)

# --- DEFAULT_OUTPUT_DIR resolution (unit-style) -------------------------
#
# The real script cannot have DEFAULT_OUTPUT_DIR exercised through $HT: the
# build() sed rewrite above deliberately neutralizes it (both the fallback
# assignment and the glob-driven override), on purpose, so no test run ever
# touches whatever Google Drive folder happens to be mounted on the machine
# actually running the suite. That means the resolution logic itself -- the
# glob for GoogleDrive-* under CloudStorage, and its fallback -- has to be
# tested in isolation, against a fake $HOME, with the shipped code
# extracted verbatim rather than re-implemented here.
echo "DEFAULT_OUTPUT_DIR resolution"

DOD_UNIT="$WORK/default_output_dir_unit.sh"
{
  cat <<'UNIT'
set -euo pipefail
HOME="$1"
UNIT
  sed -n '/^DEFAULT_OUTPUT_DIR=/,/^fi$/p' "$SCRIPT"
  cat <<'UNIT'
printf '%s\n' "$DEFAULT_OUTPUT_DIR"
UNIT
} >"$DOD_UNIT"

DOD_HOME="$WORK/dod_home"

# No CloudStorage directory at all (Google Drive never installed): falls
# back to the plain Documents path, and never mentions a Drive account.
rm -rf "$DOD_HOME"
mkdir -p "$DOD_HOME"
dod_out=$(bash "$DOD_UNIT" "$DOD_HOME")
if [[ "$dod_out" == "$DOD_HOME/Documents/huddle-transcripts" ]]; then
  pass "no CloudStorage dir falls back to ~/Documents/huddle-transcripts"
else
  fail "no CloudStorage dir falls back to ~/Documents/huddle-transcripts" "$dod_out"
fi

# A GoogleDrive-* mount exists, but has no knowledge-base directory yet
# (Drive installed, KB never created): still falls back, rather than
# pointing at a transcripts/ directory nothing else will ever look inside.
rm -rf "$DOD_HOME"
mkdir -p "$DOD_HOME/Library/CloudStorage/GoogleDrive-someone@example.com/My Drive"
dod_out=$(bash "$DOD_UNIT" "$DOD_HOME")
if [[ "$dod_out" == "$DOD_HOME/Documents/huddle-transcripts" ]]; then
  pass "a Drive mount without knowledge-base/ falls back rather than guessing"
else
  fail "a Drive mount without knowledge-base/ falls back rather than guessing" "$dod_out"
fi

# The real case: exactly one GoogleDrive-* mount, with a knowledge-base/
# directory already present. Resolves to transcripts/ inside it.
rm -rf "$DOD_HOME"
mkdir -p "$DOD_HOME/Library/CloudStorage/GoogleDrive-someone@example.com/My Drive/knowledge-base"
dod_out=$(bash "$DOD_UNIT" "$DOD_HOME")
want="$DOD_HOME/Library/CloudStorage/GoogleDrive-someone@example.com/My Drive/knowledge-base/transcripts"
if [[ "$dod_out" == "$want" ]]; then
  pass "a single Drive mount with knowledge-base/ resolves to its transcripts/"
else
  fail "a single Drive mount with knowledge-base/ resolves to its transcripts/" "$dod_out"
fi

# Two GoogleDrive-* mounts (a machine signed into more than one account):
# ambiguous, so fall back rather than guessing which account's KB is meant.
rm -rf "$DOD_HOME"
mkdir -p "$DOD_HOME/Library/CloudStorage/GoogleDrive-one@example.com/My Drive/knowledge-base"
mkdir -p "$DOD_HOME/Library/CloudStorage/GoogleDrive-two@example.com/My Drive/knowledge-base"
dod_out=$(bash "$DOD_UNIT" "$DOD_HOME")
if [[ "$dod_out" == "$DOD_HOME/Documents/huddle-transcripts" ]]; then
  pass "two Drive mounts is ambiguous and falls back"
else
  fail "two Drive mounts is ambiguous and falls back" "$dod_out"
fi

rm -rf "$DOD_HOME"

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

# Sessions below the duration floor are filtered from --list, `latest` and
# date lookup, but an explicit session id bypasses the floor (#37).
refute_out "short session filtered from --list" "Short One" --list
expect_rc "short session selectable by explicit id" 0 --dry-run --output-dir "$OUT" eeee0005
expect_out "short session by id resolves to that session" "Short One" \
  --dry-run --output-dir "$OUT" eeee0005
expect_rc "short session selectable by dashed id" 0 --dry-run --output-dir "$OUT" eeee-0005
expect_rc "short session not selectable by date" 1 --dry-run --output-dir "$OUT" 2026-08-28
refute_out "latest does not pick the short session" "Short One" --dry-run --output-dir "$OUT"

# HUDDLE_MIN_DURATION moves the floor and is validated, as in huddle-watch.
lowered=$(HUDDLE_MIN_DURATION=30 "$HT" --list 2>&1 || true)
if grep -qF "Short One" <<<"$lowered"; then
  pass "HUDDLE_MIN_DURATION=30 lets --list show the 60s session"
else
  fail "HUDDLE_MIN_DURATION=30 lets --list show the 60s session" "not listed"
fi
for bad in "" "abc" "0 OR 1=1" "5;--"; do
  rc=0
  HUDDLE_MIN_DURATION="$bad" "$HT" --list >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 1 ]]; then
    pass "HUDDLE_MIN_DURATION='$bad' rejected"
  else
    fail "HUDDLE_MIN_DURATION='$bad' rejected" "exit $rc, wanted 1"
  fi
done

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
  "$OUT/2026-08-27_sre-daily-huddle_aaaa0001.md"
exists "sidecar written with session-id suffix" \
  "$OUT/2026-08-27_sre-daily-huddle_aaaa0001.meta.json"
exists "source audio survives transcription" "$MEDIA/A_merged.m4a"

meta_sid=$(jq -r '.session_id' "$OUT/2026-08-27_sre-daily-huddle_aaaa0001.meta.json")
if [[ "$meta_sid" == "aaaa0001" ]]; then
  pass "sidecar records the resolved session id"
else
  fail "sidecar records the resolved session id"
fi

# The sidecar's output_file is what a reader uses to find the transcript, so
# it must carry the real extension rather than a stale .txt.
meta_out=$(jq -r '.output_file' "$OUT/2026-08-27_sre-daily-huddle_aaaa0001.meta.json")
if [[ "$meta_out" == "2026-08-27_sre-daily-huddle_aaaa0001.md" ]]; then
  pass "sidecar output_file carries the .md extension"
else
  fail "sidecar output_file carries the .md extension" "got: $meta_out"
fi

# No .txt may be produced. Output lands in Google Drive, whose web viewer
# previews .md inline but only offers a download prompt for .txt -- which is
# the entire reason for the format. A regression here is silent otherwise,
# since a .txt transcript is still perfectly valid content.
if compgen -G "$OUT/*.txt" >/dev/null; then
  fail "transcription produces no .txt files"
else
  pass "transcription produces no .txt files"
fi

# Assert the format flags actually reach mw. The extension is chosen by the
# script but the markup is chosen by mw, and a mismatch between the two (a
# .md file holding --format txt output) is invisible to every other check.
rm -f "$WORK/mw-calls"
# Its own output dir: a second run into $OUT would add a -2 transcript.
MW_CALLS="$WORK/mw-calls" "$HT" --yes --output-dir "$WORK/out-flags" aaaa0001 >/dev/null 2>&1 || true
rm -rf "$WORK/out-flags"
mw_flags=$(cat "$WORK/mw-calls" 2>/dev/null || true)
if grep -qF -- "--format md" <<<"$mw_flags"; then
  pass "mw is invoked with --format md"
else
  fail "mw is invoked with --format md" "flags: $mw_flags"
fi
if grep -qF -- "--end-timestamps" <<<"$mw_flags"; then
  pass "mw is invoked with --end-timestamps"
else
  fail "mw is invoked with --end-timestamps" "flags: $mw_flags"
fi

# The colliding-slug session must not overwrite the first transcript.
expect_rc "colliding-slug session transcribes" 0 --yes --output-dir "$OUT" bbbb0002
exists "colliding slugs produce separate transcripts" \
  "$OUT/2026-08-27_sre-daily-huddle_bbbb0002.md"

# A failing mw must leave an existing good transcript untouched.
HT=$(build "$BIN/mw-fail")
before=$(cat "$OUT/2026-08-27_sre-daily-huddle_aaaa0001.md")
expect_rc "failing mw exits non-zero" 1 --yes --output-dir "$OUT" aaaa0001
after=$(cat "$OUT/2026-08-27_sre-daily-huddle_aaaa0001.md")
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

# --- an existing transcript is never overwritten ------------------------

echo "no overwrite"
OUT_DUP="$WORK/out-dup"
DUP1="2026-01-05_january-session_cccc0003"
rm -rf "$OUT_DUP"
expect_rc "a first transcription succeeds" 0 --yes --output-dir "$OUT_DUP" cccc0003
printf 'hand-edited\n' >>"$OUT_DUP/$DUP1.md"
before=$(cat "$OUT_DUP/$DUP1.md")
dup_out=$("$HT" --yes --output-dir "$OUT_DUP" cccc0003 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -qF "Transcript written: $OUT_DUP/2026-01-05_january-session-2_cccc0003.md" <<<"$dup_out"; then
  pass "a second run writes the next free name, counter before the id"
else
  fail "a second run writes the next free name, counter before the id" "exit $rc: $dup_out"
fi
after=$(cat "$OUT_DUP/$DUP1.md")
if [[ "$after" == "$before" ]]; then
  pass "a second run leaves the existing transcript untouched"
else
  fail "a second run leaves the existing transcript untouched" "$after"
fi
dup_first=$(head -1 "$OUT_DUP/2026-01-05_january-session-2_cccc0003.md" 2>/dev/null || true)
if [[ "$dup_first" == "> **Note:** this transcript may duplicate $DUP1.md, which already existed when it was written." ]]; then
  pass "the second transcript opens with a note naming the first"
else
  fail "the second transcript opens with a note naming the first" "$dup_first"
fi
if grep -q '^Speaker 1$' "$OUT_DUP/2026-01-05_january-session-2_cccc0003.md" 2>/dev/null; then
  pass "the note sits above the full transcript"
else
  fail "the note sits above the full transcript"
fi
dup_meta=$(jq -r '[.session_id, .output_file, .may_duplicate] | join(",")' \
  "$OUT_DUP/2026-01-05_january-session-2_cccc0003.meta.json" 2>/dev/null || true)
if [[ "$dup_meta" == "cccc0003,2026-01-05_january-session-2_cccc0003.md,$DUP1.md" ]]; then
  pass "the second sidecar names its own transcript and may_duplicate"
else
  fail "the second sidecar names its own transcript and may_duplicate" "$dup_meta"
fi
if jq -e 'has("may_duplicate")' "$OUT_DUP/$DUP1.meta.json" >/dev/null 2>&1; then
  fail "a first transcript's sidecar has no may_duplicate"
else
  pass "a first transcript's sidecar has no may_duplicate"
fi
expect_out "--dry-run names the next free transcript" \
  "Output:   $OUT_DUP/2026-01-05_january-session-3_cccc0003.md" --dry-run --output-dir "$OUT_DUP" cccc0003
expect_rc "a third run succeeds" 0 --yes --output-dir "$OUT_DUP" cccc0003
exists "a third run takes -3" "$OUT_DUP/2026-01-05_january-session-3_cccc0003.md"
# An orphan transcript with no sidecar also blocks its name.
rm -f "$OUT_DUP/$DUP1.meta.json"
expect_rc "a run beside an orphan transcript succeeds" 0 --yes --output-dir "$OUT_DUP" cccc0003
exists "an orphan transcript is not overwritten either" "$OUT_DUP/2026-01-05_january-session-4_cccc0003.md"
after=$(cat "$OUT_DUP/$DUP1.md")
if [[ "$after" == "$before" ]]; then
  pass "the orphan transcript keeps its content"
else
  fail "the orphan transcript keeps its content" "$after"
fi
expect_out "--skip-existing still counts a -N transcript as done" "Already transcribed: " \
  --skip-existing --yes --output-dir "$OUT_DUP" cccc0003
# Two sidecars for one session: --mark-reviewed refuses rather than guess.
expect_rc "--mark-reviewed refuses while duplicates exist" 1 \
  --mark-reviewed --yes --output-dir "$OUT_DUP" cccc0003
exists "--mark-reviewed with duplicates keeps the audio" "$MEDIA/C_merged.m4a"
rm -rf "$OUT_DUP"

# A transcript of the session under an older title is named, not replaced.
mkdir -p "$OUT_DUP"
printf 'old body\n' >"$OUT_DUP/2026-01-05_old-title_cccc0003.md"
printf '{"session_id": "cccc0003", "output_file": "2026-01-05_old-title_cccc0003.md"}\n' \
  >"$OUT_DUP/2026-01-05_old-title_cccc0003.meta.json"
expect_rc "a run after a retitle succeeds" 0 --yes --output-dir "$OUT_DUP" cccc0003
dup_first=$(head -1 "$OUT_DUP/$DUP1.md" 2>/dev/null || true)
if [[ "$dup_first" == *"may duplicate 2026-01-05_old-title_cccc0003.md,"* ]]; then
  pass "a transcript under an older title is named in the note"
else
  fail "a transcript under an older title is named in the note" "$dup_first"
fi
rm -rf "$OUT_DUP"

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
txt="$OUT/2026-08-27_sre-daily-huddle_aaaa0001.md"
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

# --- --mark-reviewed after a retitle ------------------------------------
#
# MacWhisper keeps titling a session after its transcript is written, so the
# basename derived from today's title can name a file that never existed.
# The sidecar must still be found, by session id suffix.

# Built on ffff0006, which no other test transcribes, so the pair below is
# the only thing that names it. Reusing a session whose sidecar later tests
# read would rename that sidecar out from under them.
retitle_meta="$OUT/2026-08-19_stale-title_ffff0006.meta.json"
retitle_doc="$OUT/2026-08-19_stale-title_ffff0006.md"
printf 'transcript body\n' >"$retitle_doc"
cat >"$retitle_meta" <<'RETITLE_META'
{
  "session_id": "ffff0006",
  "date": "2026-08-19",
  "duration_seconds": 700,
  "source_file": "F_merged.m4a",
  "output_file": "2026-08-19_stale-title_ffff0006.md",
  "title": "Stale Title",
  "reviewed": false,
  "deleted_source": false
}
RETITLE_META

# --dry-run must report the resolved transcript, not the one today's title
# would derive ("Hostile Duration" -> 2026-08-19_hostile-duration_ffff0006.md).
expect_out "dry-run reports the retitled transcript" "2026-08-19_stale-title_ffff0006.md" \
  --dry-run --mark-reviewed --yes --output-dir "$OUT" ffff0006
exists "dry-run after retitle keeps the audio" "$MEDIA/F_merged.m4a"

# An ambiguous id suffix must refuse rather than pick one.
cp "$retitle_meta" "$OUT/2026-08-18_decoy_ffff0006.meta.json"
expect_rc "ambiguous id suffix refuses" 1 \
  --mark-reviewed --yes --output-dir "$OUT" ffff0006
exists "ambiguous id suffix keeps the audio" "$MEDIA/F_merged.m4a"
rm -f "$OUT/2026-08-18_decoy_ffff0006.meta.json"

# With one match, the retitled session marks reviewed and loses its audio.
expect_rc "retitled session marks reviewed" 0 \
  --mark-reviewed --yes --output-dir "$OUT" ffff0006
absent "retitled session removes the audio" "$MEDIA/F_merged.m4a"
retitle_flags=$(jq -r '[.reviewed, .deleted_source] | join(",")' "$retitle_meta")
if [[ "$retitle_flags" == "true,true" ]]; then
  pass "retitled sidecar records reviewed and deleted_source"
else
  fail "retitled sidecar records reviewed and deleted_source" "flags: $retitle_flags"
fi
rm -f "$retitle_meta" "$retitle_doc"
reset_media

# --- sidecar title field and _index.md ---------------------------------
#
# At this point in $OUT: aaaa0001 (2026-08-27, reviewed) and bbbb0002
# (2026-08-27, not reviewed) both exist from the transcription tests above.

echo "sidecar title field and _index.md"

meta_aaaa="$OUT/2026-08-27_sre-daily-huddle_aaaa0001.meta.json"
meta_bbbb="$OUT/2026-08-27_sre-daily-huddle_bbbb0002.meta.json"
index="$OUT/_index.md"

title_aaaa=$(jq -r '.title' "$meta_aaaa")
if [[ "$title_aaaa" == "SRE Daily Huddle" ]]; then
  pass "sidecar records the session title"
else
  fail "sidecar records the session title" "got: $title_aaaa"
fi

exists "_index.md exists after a transcribe run" "$index"
if [[ -s "$index" ]]; then
  pass "_index.md is non-empty"
else
  fail "_index.md is non-empty"
fi

index_body=$(cat "$index")
if grep -qF "SRE Daily Huddle" <<<"$index_body"; then
  pass "_index.md contains the session title"
else
  fail "_index.md contains the session title"
fi
if grep -qF "2026-08-27" <<<"$index_body"; then
  pass "_index.md contains the session date"
else
  fail "_index.md contains the session date"
fi
if grep -qF "[2026-08-27_sre-daily-huddle_aaaa0001.md](2026-08-27_sre-daily-huddle_aaaa0001.md)" <<<"$index_body"; then
  pass "_index.md contains a working relative link"
else
  fail "_index.md contains a working relative link"
fi

# Two sessions on different dates: dddd0004 (2026-08-20) is transcribed
# fresh here so the newer-first ordering assertion is not resting on a
# same-day tie between aaaa0001 and bbbb0002.
expect_rc "second-date session transcribes" 0 --yes --output-dir "$OUT" dddd0004
exists "second-date transcript written" \
  "$OUT/2026-08-20_tab-title-here_dddd0004.md"

index_body=$(cat "$index")
line_aaaa=$(grep -nF "sre-daily-huddle_aaaa0001" <<<"$index_body" | cut -d: -f1)
line_dddd=$(grep -nF "tab-title-here_dddd0004" <<<"$index_body" | cut -d: -f1)
if [[ -n "$line_aaaa" && -n "$line_dddd" && "$line_aaaa" -lt "$line_dddd" ]]; then
  pass "_index.md lists the newer session first"
else
  fail "_index.md lists the newer session first" "aaaa line $line_aaaa, dddd line $line_dddd"
fi

# --mark-reviewed on aaaa0001 already happened above; confirm the index
# reflects the flipped reviewed field for that row and still shows bbbb0002
# (never mark-reviewed) as not reviewed.
index_body=$(cat "$index")
row_aaaa=$(grep -F "sre-daily-huddle_aaaa0001" <<<"$index_body")
row_bbbb=$(grep -F "sre-daily-huddle_bbbb0002" <<<"$index_body")
if grep -qF "| yes |" <<<"$row_aaaa"; then
  pass "_index.md shows the mark-reviewed session as Reviewed: yes"
else
  fail "_index.md shows the mark-reviewed session as Reviewed: yes" "row: $row_aaaa"
fi
if grep -qF "| no |" <<<"$row_bbbb"; then
  pass "_index.md shows the unreviewed session as Reviewed: no"
else
  fail "_index.md shows the unreviewed session as Reviewed: no" "row: $row_bbbb"
fi

# --list is read-only and must not create or touch _index.md.
rm -f "$index"
"$HT" --list >/dev/null 2>&1 || true
absent "--list does not create _index.md" "$index"

# Rebuild the index for the remaining assertions below.
"$HT" --mark-reviewed --yes --output-dir "$OUT" aaaa0001 >/dev/null 2>&1 || true

# A malformed sidecar mixed in with valid ones must not abort the index
# write -- same precedent as huddle-migrate-md's badjson case.
printf 'not json at all' >"$OUT/2026-09-01_corrupt_deadbeef.meta.json"
rc=0
"$HT" --yes --output-dir "$OUT" bbbb0002 >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 0 ]]; then
  pass "a malformed sidecar does not abort the index write"
else
  fail "a malformed sidecar does not abort the index write" "exit $rc"
fi
index_body=$(cat "$index")
if grep -qF "SRE Daily Huddle" <<<"$index_body"; then
  pass "valid sidecars still appear alongside a malformed one"
else
  fail "valid sidecars still appear alongside a malformed one"
fi
rm -f "$OUT/2026-09-01_corrupt_deadbeef.meta.json"

# A sidecar missing the title field (as huddle-transcribe wrote them before
# this feature existed) must still produce a readable row via the
# slug-derived fallback, not an empty or errored cell.
jq 'del(.title)' "$meta_bbbb" >"$meta_bbbb.tmp" && mv "$meta_bbbb.tmp" "$meta_bbbb"
"$HT" --yes --output-dir "$OUT" dddd0004 >/dev/null 2>&1 || true
index_body=$(cat "$index")
if grep -qF "sre daily huddle" <<<"$index_body"; then
  pass "a sidecar missing title falls back to a de-slugified title"
else
  fail "a sidecar missing title falls back to a de-slugified title"
fi

# --- --all -------------------------------------------------------------

echo "--all"
# --all skips sessions deleted in MacWhisper (dateDeleted, added by the fixture).
sqlite3 "$DB" <<'SQL'
INSERT INTO recordedmeeting (id, duration, title) VALUES (x'77', 1000.0, 'rmG');
INSERT INTO session VALUES (x'abab0007', '2025-12-01 10:00:00.000', 'Deleted One', NULL, x'77', NULL, '2025-12-02 10:00:00.000');
INSERT INTO mediafile VALUES (x'abab0007', 'mergedMultitrack', 'G_merged.m4a');
SQL
reset_media
touch "$MEDIA/G_merged.m4a"
OUT_ALL="$WORK/out-all"
rm -rf "$OUT_ALL"
"$HT" --yes --output-dir "$OUT_ALL" aaaa0001 >/dev/null 2>&1

expect_rc "--all with a target rejected" 1 --all --output-dir "$OUT_ALL" bbbb0002
expect_rc "--all --list rejected" 1 --all --list --output-dir "$OUT_ALL"
expect_rc "--all --mark-reviewed rejected" 1 --all --mark-reviewed --yes --output-dir "$OUT_ALL"
exists "--all --mark-reviewed keeps the audio" "$MEDIA/A_merged.m4a"

# With no answer on stdin, each prompt must say why it stopped, not exit
# silently, and must act on nothing.
for args in "--all" "bbbb0002" "--mark-reviewed aaaa0001"; do
  read -r -a argv <<<"$args"
  eof_out=$("$HT" "${argv[@]}" --output-dir "$OUT_ALL" </dev/null 2>&1) && rc=0 || rc=$?
  if [[ $rc -eq 1 ]] && grep -qF -- "Re-run with --yes" <<<"$eof_out"; then
    pass "'$args' with closed stdin explains and exits 1"
  else
    fail "'$args' with closed stdin explains and exits 1" "exit $rc: $eof_out"
  fi
done
absent "closed stdin writes no sidecar" "$OUT_ALL/2026-08-27_sre-daily-huddle_bbbb0002.meta.json"
exists "closed stdin keeps the audio" "$MEDIA/A_merged.m4a"

rm -f "$WORK/mw-calls"
all_out=$(MW_CALLS="$WORK/mw-calls" "$HT" --all --dry-run --output-dir "$OUT_ALL" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then pass "--all --dry-run exits 0"; else fail "--all --dry-run exits 0" "exit $rc"; fi
absent "--all --dry-run never runs mw" "$WORK/mw-calls"
for want in bbbb0002 cccc0003 dddd0004 ffff0006 "would transcribe 4"; do
  if grep -qF "$want" <<<"$all_out"; then
    pass "--all --dry-run lists $want"
  else
    fail "--all --dry-run lists $want" "$all_out"
  fi
done
for unwanted in aaaa0001 "Short One" abab0007; do
  if grep -qF "$unwanted" <<<"$all_out"; then
    fail "--all --dry-run skips $unwanted" "$all_out"
  else
    pass "--all --dry-run skips $unwanted"
  fi
done

all_out=$(echo n | "$HT" --all --output-dir "$OUT_ALL" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 1 ]] && grep -qF "Aborted." <<<"$all_out"; then
  pass "--all declined at the prompt aborts"
else
  fail "--all declined at the prompt aborts" "exit $rc"
fi
absent "--all declined writes nothing" "$OUT_ALL/2026-08-27_sre-daily-huddle_bbbb0002.meta.json"

all_out=$("$HT" --all --yes --output-dir "$OUT_ALL" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then pass "--all --yes exits 0"; else fail "--all --yes exits 0" "exit $rc"; fi
for f in 2026-08-27_sre-daily-huddle_bbbb0002 2026-01-05_january-session_cccc0003 \
  2026-08-20_tab-title-here_dddd0004 2026-08-19_hostile-duration_ffff0006; do
  exists "--all writes $f.md" "$OUT_ALL/$f.md"
  exists "--all writes $f.meta.json" "$OUT_ALL/$f.meta.json"
done
# Oldest first: January's session must be processed before August's.
first=$(grep -n '^\[1/4\]' <<<"$all_out" | cut -d: -f1)
jan=$(grep -n '^\[[0-9]/4\] cccc0003' <<<"$all_out" | cut -d: -f1)
if [[ -n "$first" && "$first" == "$jan" ]]; then
  pass "--all processes the oldest session first"
else
  fail "--all processes the oldest session first" "$all_out"
fi
absent "--all skips the session deleted in MacWhisper" \
  "$OUT_ALL/2025-12-01_deleted-one_abab0007.meta.json"

rm -f "$WORK/mw-calls"
all_out=$(MW_CALLS="$WORK/mw-calls" "$HT" --all --yes --output-dir "$OUT_ALL" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -qF "Nothing to transcribe" <<<"$all_out"; then
  pass "--all with nothing pending says so and exits 0"
else
  fail "--all with nothing pending says so and exits 0" "exit $rc: $all_out"
fi
absent "--all with nothing pending never runs mw" "$WORK/mw-calls"

# One failure must not stop the batch. The stub fails the oldest session,
# so every later session has to survive it.
cat >"$BIN/mw-fail-c" <<'STUB'
#!/usr/bin/env bash
for last in "$@"; do :; done
[[ "$last" == *C_merged.m4a ]] && exit 3
exec "$(dirname -- "$0")/mw" "$@"
STUB
chmod +x "$BIN/mw-fail-c"
HT=$(build "$BIN/mw-fail-c")
rm -rf "$OUT_ALL"
all_out=$("$HT" --all --yes --output-dir "$OUT_ALL" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 1 ]]; then pass "--all exits 1 when a session fails"; else fail "--all exits 1 when a session fails" "exit $rc"; fi
if grep -qF "Failed: cccc0003" <<<"$all_out"; then
  pass "--all names the failed session"
else
  fail "--all names the failed session" "$all_out"
fi
exists "--all continues past a failure" "$OUT_ALL/2026-08-27_sre-daily-huddle_aaaa0001.meta.json"
absent "--all writes no sidecar for the failed session" \
  "$OUT_ALL/2026-01-05_january-session_cccc0003.meta.json"
HT=$(build)

# --skip-existing: a sidecar means done, even with the audio gone, as it is
# after --mark-reviewed.
rm -rf "$OUT_ALL"
reset_media
"$HT" --yes --output-dir "$OUT_ALL" bbbb0002 >/dev/null 2>&1
rm -f "$MEDIA/B_app.m4a" "$WORK/mw-calls"
skip_out=$(MW_CALLS="$WORK/mw-calls" "$HT" --skip-existing --yes --output-dir "$OUT_ALL" bbbb0002 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -qF "Already transcribed: " <<<"$skip_out"; then
  pass "--skip-existing exits 0 for a transcribed session with its audio gone"
else
  fail "--skip-existing exits 0 for a transcribed session with its audio gone" "exit $rc: $skip_out"
fi
absent "--skip-existing never runs mw for a transcribed session" "$WORK/mw-calls"
# A sidecar that only shares the 8-hex suffix is someone else's: transcribe.
reset_media
jq '.session_id = "aaaa0001ffff"' "$OUT_ALL/2026-08-27_sre-daily-huddle_bbbb0002.meta.json" \
  >"$OUT_ALL/x.json" && mv "$OUT_ALL/x.json" "$OUT_ALL/2026-08-27_sre-daily-huddle_bbbb0002.meta.json"
skip_out=$("$HT" --skip-existing --yes --output-dir "$OUT_ALL" bbbb0002 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -qF "Transcript written: " <<<"$skip_out"; then
  pass "--skip-existing transcribes when the sidecar names another session"
else
  fail "--skip-existing transcribes when the sidecar names another session" "exit $rc: $skip_out"
fi
skip_out=$("$HT" --skip-existing --yes --output-dir "$OUT_ALL" cccc0003 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -qF "Transcript written: " <<<"$skip_out"; then
  pass "--skip-existing transcribes a session with no sidecar"
else
  fail "--skip-existing transcribes a session with no sidecar" "exit $rc: $skip_out"
fi
expect_rc "--skip-existing --mark-reviewed rejected" 1 \
  --skip-existing --mark-reviewed --yes --output-dir "$OUT_ALL" cccc0003
exists "--skip-existing --mark-reviewed keeps the audio" "$MEDIA/C_merged.m4a"

sqlite3 "$DB" "DELETE FROM session WHERE id = x'abab0007'; DELETE FROM recordedmeeting WHERE id = x'77'; DELETE FROM mediafile WHERE sessionID = x'abab0007';"
rm -f "$MEDIA/G_merged.m4a"
rm -rf "$OUT_ALL"

# --- split meetings are stitched ---------------------------------------

# a1a1000[1-3] mirror 2026-10-15: one Slack call, three pieces. 4 is another app, 5 is 90 s late.
echo "split meetings are stitched"
sqlite3 "$DB" <<'SQL'
INSERT INTO recordedmeeting VALUES (x'a1', 83.073625, NULL, '2026-10-15 15:01:23.955', 'Slack', 'com.tinyspeck.slackmacgap');
INSERT INTO session VALUES (x'a1a10001', '2026-10-15 15:02:54.630', 'Split Huddle', NULL, x'a1', NULL, NULL);
INSERT INTO mediafile VALUES (x'a1a10001', 'mergedMultitrack', 'S1_merged.m4a');
INSERT INTO recordedmeeting VALUES (x'a2', 42.2019375, NULL, '2026-10-15 15:02:53.351', 'Slack', 'com.tinyspeck.slackmacgap');
INSERT INTO session VALUES (x'a1a10002', '2026-10-15 15:03:40.742', NULL, 'Later Piece', x'a2', NULL, NULL);
INSERT INTO mediafile VALUES (x'a1a10002', 'mergedMultitrack', 'S2_merged.m4a');
INSERT INTO recordedmeeting VALUES (x'a3', 1075.9269375, NULL, '2026-10-15 15:03:39.467', 'Slack', 'com.tinyspeck.slackmacgap');
INSERT INTO session VALUES (x'a1a10003', '2026-10-15 15:22:56.495', NULL, 'Last Piece', x'a3', NULL, NULL);
INSERT INTO mediafile VALUES (x'a1a10003', 'mergedMultitrack', 'S3 it''s merged.m4a');
INSERT INTO recordedmeeting VALUES (x'a4', 400.0, NULL, '2026-10-15 15:21:50.000', 'Chrome', 'com.google.Chrome');
INSERT INTO session VALUES (x'a1a10004', '2026-10-15 15:28:30.000', 'Other App', NULL, x'a4', NULL, NULL);
INSERT INTO mediafile VALUES (x'a1a10004', 'mergedMultitrack', 'S4_merged.m4a');
INSERT INTO recordedmeeting VALUES (x'a5', 400.0, NULL, '2026-10-15 15:23:05.500', 'Slack', 'com.tinyspeck.slackmacgap');
INSERT INTO session VALUES (x'a1a10005', '2026-10-15 15:29:45.500', 'Too Late', NULL, x'a5', NULL, NULL);
INSERT INTO mediafile VALUES (x'a1a10005', 'mergedMultitrack', 'S5_merged.m4a');
SQL
reset_split_media() {
  touch "$MEDIA/S1_merged.m4a" "$MEDIA/S2_merged.m4a" "$MEDIA/S3 it's merged.m4a" \
    "$MEDIA/S4_merged.m4a" "$MEDIA/S5_merged.m4a"
}
reset_split_media
OUT_ST="$WORK/out-stitch"
ST_BASE="$OUT_ST/2026-10-15_split-huddle_a1a10001"
rm -rf "$OUT_ST"
# Each scenario gets its own per-recording cache.
export HUDDLE_PIECES_DIR="$WORK/pieces-stitch"
rm -rf "$HUDDLE_PIECES_DIR"

# --list and --all show a split meeting once, under its first recording and total.
list_out=$("$HT" --list 2>&1 || true)
if grep -qE '^a1a10001 .* 20m01s +Split Huddle$' <<<"$list_out"; then
  pass "--list shows a split meeting once, with its total duration"
else
  fail "--list shows a split meeting once, with its total duration" "$list_out"
fi
for unwanted in a1a10002 a1a10003; do
  if grep -qF "$unwanted" <<<"$list_out"; then
    fail "--list hides later recording $unwanted of a split meeting" "$list_out"
  else
    pass "--list hides later recording $unwanted of a split meeting"
  fi
done
all_out=$("$HT" --all --dry-run --output-dir "$OUT_ST" 2>&1 || true)
if grep -qF a1a10001 <<<"$all_out" && ! grep -qE 'a1a1000[23]' <<<"$all_out"; then
  pass "--all queues a split meeting once"
else
  fail "--all queues a split meeting once" "$all_out"
fi

# Any recording selects the whole meeting; the dry run names each part's
# start and gap (the watcher logs these lines).
dry_out=$("$HT" --dry-run --output-dir "$OUT_ST" a1a10002 2>&1 || true)
for want in "Session:  a1a10001" "Stitched: 3 recordings of one meeting (a1a10001 a1a10002 a1a10003)" \
  "Duration: 20m01s" "Output:   $ST_BASE.md" "Part 1:   a1a10001 starts at 00:00: $MEDIA/S1_merged.m4a" \
  "Part 2:   a1a10002 starts at 01:29, after a 6 s gap: $MEDIA/S2_merged.m4a" \
  "Part 3:   a1a10003 starts at 02:16, after a 4 s gap: $MEDIA/S3 it's merged.m4a"; do
  if grep -qF -- "$want" <<<"$dry_out"; then
    pass "dry run of a later recording shows '$want'"
  else
    fail "dry run of a later recording shows '$want'" "$dry_out"
  fi
done
absent "a dry run writes no cached piece" "$HUDDLE_PIECES_DIR"

rm -f "$WORK/mw-calls"
st_rc=0
st_out=$(MW_CALLS="$WORK/mw-calls" "$HT" --yes --output-dir "$OUT_ST" a1a10002 2>&1) || st_rc=$?
if [[ $st_rc -eq 0 ]]; then
  pass "a split meeting transcribes"
else
  fail "a split meeting transcribes" "exit $st_rc: $st_out"
fi
exists "a split meeting writes one transcript named after its first recording" "$ST_BASE.md"
exists "a split meeting writes one sidecar named after its first recording" "$ST_BASE.meta.json"
if compgen -G "$OUT_ST/*_a1a1000[23].*" >/dev/null; then
  fail "later recordings of a split meeting get no transcript of their own"
else
  pass "later recordings of a split meeting get no transcript of their own"
fi
st_ids=$(jq -c '.session_ids' "$ST_BASE.meta.json" 2>/dev/null || true)
if [[ "$st_ids" == '["a1a10001","a1a10002","a1a10003"]' ]]; then
  pass "the sidecar lists every recording, oldest first"
else
  fail "the sidecar lists every recording, oldest first" "session_ids: $st_ids"
fi
st_sid=$(jq -r '.session_id' "$ST_BASE.meta.json" 2>/dev/null || true)
st_dur=$(jq -r '.duration_seconds | floor' "$ST_BASE.meta.json" 2>/dev/null || true)
st_title=$(jq -r '.title' "$ST_BASE.meta.json" 2>/dev/null || true)
if [[ "$st_sid" == "a1a10001" && "$st_dur" == "1201" && "$st_title" == "Split Huddle" ]]; then
  pass "the sidecar keeps session_id and title of the first recording, and the total duration"
else
  fail "the sidecar keeps session_id and title of the first recording, and the total duration" \
    "session_id=$st_sid duration=$st_dur title=$st_title"
fi
st_keys=$(jq -c '[has("restitchable"), has("missing_session_ids")]' "$ST_BASE.meta.json" 2>/dev/null || true)
if [[ "$st_keys" == "[false,false]" ]]; then
  pass "a manual stitch is not marked replaceable and misses no part"
else
  fail "a manual stitch is not marked replaceable and misses no part" "$st_keys"
fi
# One mw run per piece, oldest first: joined audio lost all punctuation.
mw_inputs=$(awk '{ print $NF }' "$WORK/mw-calls" 2>/dev/null | sed 's|.*/||' | tr '\n' ',' || true)
if [[ "$mw_inputs" == "S1_merged.m4a,S2_merged.m4a,merged.m4a," ]] &&
  grep -qF -- "$MEDIA/S3 it's merged.m4a" "$WORK/mw-calls"; then
  pass "mw transcribes each recording on its own, oldest first"
else
  diag=$(cat "$WORK/mw-calls" 2>/dev/null || true)
  fail "mw transcribes each recording on its own, oldest first" "$diag"
fi
for sid in a1a10001 a1a10002 a1a10003; do
  exists "the transcript of $sid is cached outside the output dir" "$HUDDLE_PIECES_DIR/$sid.md"
done
if compgen -G "$HUDDLE_PIECES_DIR/*.partial.*" >/dev/null || compgen -G "$OUT_ST/*.partial.*" >/dev/null; then
  fail "no temp file is left behind"
else
  pass "no temp file is left behind"
fi
# The join: a heading per part, timestamps continuous from the first piece,
# everything else as mw wrote it.
st_doc=$(cat "$ST_BASE.md" 2>/dev/null || true)
st_heads=$(grep '^## ' <<<"$st_doc" || true)
want_heads="## Part 1 of 3 — starts at 00:00
## Part 2 of 3 — starts at 01:29, after a 6 s gap
## Part 3 of 3 — starts at 02:16, after a 4 s gap"
if [[ "$st_heads" == "$want_heads" ]]; then
  pass "each part has a heading with its start and gap"
else
  fail "each part has a heading with its start and gap" "$st_heads"
fi
st_stamps=$(grep -E '^\*[0-9:-]+\*$' <<<"$st_doc" | tr '\n' ' ' || true)
if [[ "$st_stamps" == "*00:00-00:06* *00:06-00:12* *01:29-01:35* *01:35-01:41* *02:16-02:22* *02:22-02:28* " ]]; then
  pass "timestamps are offset by each part's start"
else
  fail "timestamps are offset by each part's start" "$st_stamps"
fi
for want in "hello from S1_merged.m4a" "hello from S2_merged.m4a" "hello from S3 it's merged.m4a"; do
  if grep -qxF "$want" <<<"$st_doc"; then
    pass "the joined transcript keeps '$want'"
  else
    fail "the joined transcript keeps '$want'" "$st_doc"
  fi
done
labels=$(grep -c '^Speaker [0-9]$' <<<"$st_doc" || true)
if [[ "$labels" == "6" ]] && ! grep -qE '^\*\*?(Part|Speaker)' <<<"$st_doc" &&
  head -1 <<<"$st_doc" | grep -qF '> **Note:** joined from 3 recordings of one meeting.'; then
  pass "speaker labels pass through unchanged and nothing added starts with *"
else
  fail "speaker labels pass through unchanged and nothing added starts with *" "$st_doc"
fi

# An hour or more prints as HH:MM:SS, as mw does past the hour.
OUT_LONG="$WORK/out-long"
rm -rf "$OUT_LONG"
MW_LONG=1 "$HT" --yes --output-dir "$OUT_LONG" a1a10001 >/dev/null 2>&1 || true
long_stamps=$(grep -hE '^\*59|^\*01:0' "$OUT_LONG"/*.md 2>/dev/null | tr '\n' ' ' || true)
if [[ "$long_stamps" == "*59:50-01:00:02* *01:01:19-01:01:31* *01:02:06-01:02:18* " ]]; then
  pass "an offset past the hour is written HH:MM:SS"
else
  fail "an offset past the hour is written HH:MM:SS" "$long_stamps"
fi
rm -rf "$OUT_LONG"

# --skip-existing recognizes the meeting from any of its recordings.
rm -f "$WORK/mw-calls"
skip_out=$(MW_CALLS="$WORK/mw-calls" "$HT" --skip-existing --yes --output-dir "$OUT_ST" a1a10003 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -qF "Already transcribed: $ST_BASE.meta.json" <<<"$skip_out"; then
  pass "--skip-existing recognizes a later recording of a stitched meeting"
else
  fail "--skip-existing recognizes a later recording of a stitched meeting" "exit $rc: $skip_out"
fi
absent "--skip-existing runs no mw for a stitched meeting" "$WORK/mw-calls"
all_out=$("$HT" --all --dry-run --output-dir "$OUT_ST" 2>&1 || true)
if grep -qF a1a10001 <<<"$all_out"; then
  fail "--all treats a stitched meeting as transcribed" "$all_out"
else
  pass "--all treats a stitched meeting as transcribed"
fi

# Per-piece transcripts from before stitching: done when they name every
# piece; a piece none names is still pending.
OUT_LEGACY="$WORK/out-legacy"
rm -rf "$OUT_LEGACY"
mkdir -p "$OUT_LEGACY"
for piece in a1a10001 a1a10002 a1a10003; do
  printf '{"session_id": "%s", "output_file": "2026-10-15_piece_%s.md"}\n' "$piece" "${piece:0:8}" \
    >"$OUT_LEGACY/2026-10-15_piece_${piece:0:8}.meta.json"
done
rm -f "$WORK/mw-calls"
skip_out=$(MW_CALLS="$WORK/mw-calls" "$HT" --skip-existing --yes --output-dir "$OUT_LEGACY" a1a10001 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -qF "Already transcribed: " <<<"$skip_out"; then
  pass "--skip-existing counts per-recording transcripts that name every piece"
else
  fail "--skip-existing counts per-recording transcripts that name every piece" "exit $rc: $skip_out"
fi
absent "per-recording transcripts of every piece prevent a duplicate stitch" "$WORK/mw-calls"
rm -f "$OUT_LEGACY"/2026-10-15_piece_a1a1000[12].meta.json
all_out=$("$HT" --all --dry-run --output-dir "$OUT_LEGACY" 2>&1 || true)
if grep -qF a1a10001 <<<"$all_out"; then
  pass "--all queues a meeting whose earlier pieces no sidecar names"
else
  fail "--all queues a meeting whose earlier pieces no sidecar names" "$all_out"
fi
skip_out=$("$HT" --skip-existing --yes --output-dir "$OUT_LEGACY" a1a10001 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -qF "Transcript written: $OUT_LEGACY/2026-10-15_split-huddle_a1a10001.md" <<<"$skip_out" &&
  head -1 "$OUT_LEGACY/2026-10-15_split-huddle_a1a10001.md" | grep -qF "may duplicate 2026-10-15_piece_a1a10003.md"; then
  pass "--skip-existing stitches the meeting when one piece has a transcript, noting it"
else
  fail "--skip-existing stitches the meeting when one piece has a transcript, noting it" "exit $rc: $skip_out"
fi
rm -rf "$OUT_LEGACY"

# --all leaves a part the watcher recorded as missing to the watcher's retry.
mkdir -p "$OUT_LEGACY"
printf '{"session_id": "a1a10001", "session_ids": ["a1a10001", "a1a10003"], "missing_session_ids": ["a1a10002"], "output_file": "x_a1a10001.md"}\n' \
  >"$OUT_LEGACY/2026-10-15_split-huddle_a1a10001.meta.json"
all_out=$("$HT" --all --dry-run --output-dir "$OUT_LEGACY" 2>&1 || true)
if grep -qF a1a10001 <<<"$all_out"; then
  fail "--all does not write a duplicate for a meeting with a missing part" "$all_out"
else
  pass "--all does not write a duplicate for a meeting with a missing part"
fi
rm -f "$OUT_LEGACY/2026-10-15_split-huddle_a1a10001.meta.json"
rmdir "$OUT_LEGACY"

# A lone recording that a stitched sidecar lists, under another id, is done too.
mkdir -p "$OUT_LEGACY"
printf '{"session_id": "a1a10001", "session_ids": ["a1a10001", "a1a10005"], "output_file": "x_a1a10001.md"}\n' \
  >"$OUT_LEGACY/2026-10-15_split-huddle_a1a10001.meta.json"
rm -f "$WORK/mw-calls"
skip_out=$(MW_CALLS="$WORK/mw-calls" "$HT" --skip-existing --yes --output-dir "$OUT_LEGACY" a1a10005 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -qF "Already transcribed: $OUT_LEGACY/2026-10-15_split-huddle_a1a10001.meta.json" <<<"$skip_out"; then
  pass "--skip-existing counts a lone recording a stitched sidecar lists"
else
  fail "--skip-existing counts a lone recording a stitched sidecar lists" "exit $rc: $skip_out"
fi
absent "a lone recording a stitched sidecar lists is not transcribed again" "$WORK/mw-calls"
rm -rf "$OUT_LEGACY"

# Another app or a gap past 60 s does not join; a lone recording keeps the old path.
for lone in a1a10004 a1a10005; do
  rm -f "$WORK/mw-calls"
  lone_out=$(MW_CALLS="$WORK/mw-calls" "$HT" --yes --output-dir "$OUT_ST" "$lone" 2>&1) && rc=0 || rc=$?
  if [[ $rc -eq 0 ]] && ! grep -qF "Stitched:" <<<"$lone_out" && grep -qF "_${lone}.md" <<<"$lone_out"; then
    pass "$lone is transcribed on its own"
  else
    fail "$lone is transcribed on its own" "exit $rc: $lone_out"
  fi
  lone_calls=$(grep -c . "$WORK/mw-calls" 2>/dev/null || true)
  if [[ "$lone_calls" == "1" ]] && ! grep -q '^## Part' "$OUT_ST"/*_"$lone".md; then
    pass "$lone runs mw once and gets no part heading"
  else
    fail "$lone runs mw once and gets no part heading" "calls: $lone_calls"
  fi
  absent "$lone is not cached" "$HUDDLE_PIECES_DIR/$lone.md"
done
lone_keys=$(jq -c 'keys_unsorted' "$OUT_ST"/2026-10-15_too-late_a1a10005.meta.json 2>/dev/null || true)
if [[ "$lone_keys" == '["session_id","date","duration_seconds","source_file","output_file","title","reviewed","deleted_source"]' ]]; then
  pass "a single recording's sidecar is unchanged"
else
  fail "a single recording's sidecar is unchanged" "keys: $lone_keys"
fi

# HUDDLE_STITCH_GAP_SECONDS moves the threshold, 0 disables it, and it is validated.
gap_out=$(HUDDLE_STITCH_GAP_SECONDS=100 "$HT" --dry-run --output-dir "$OUT_ST" a1a10005 2>&1 || true)
if grep -qF "Stitched: 4 recordings" <<<"$gap_out"; then
  pass "a wider HUDDLE_STITCH_GAP_SECONDS joins the later recording"
else
  fail "a wider HUDDLE_STITCH_GAP_SECONDS joins the later recording" "$gap_out"
fi
gap_out=$(HUDDLE_STITCH_GAP_SECONDS=0 "$HT" --dry-run --output-dir "$OUT_ST" a1a10002 2>&1 || true)
if grep -qF "Session:  a1a10002" <<<"$gap_out" && ! grep -qF "Stitched:" <<<"$gap_out"; then
  pass "HUDDLE_STITCH_GAP_SECONDS=0 disables stitching"
else
  fail "HUDDLE_STITCH_GAP_SECONDS=0 disables stitching" "$gap_out"
fi
for bad in "" "abc" "60;--" "-1"; do
  rc=0
  HUDDLE_STITCH_GAP_SECONDS="$bad" "$HT" --list >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 1 ]]; then
    pass "HUDDLE_STITCH_GAP_SECONDS='$bad' rejected"
  else
    fail "HUDDLE_STITCH_GAP_SECONDS='$bad' rejected" "exit $rc, wanted 1"
  fi
done

# Group by bundle id ("Chrome" and "Google Chrome" are one app). With none,
# appName decides, and never joins a bundle-id piece.
sqlite3 "$DB" <<'SQL'
INSERT INTO recordedmeeting VALUES (x'b1', 200.0, NULL, '2026-10-16 10:00:00.000', 'Chrome', 'com.google.Chrome');
INSERT INTO session VALUES (x'b1b10001', '2026-10-16 10:03:20.000', 'Chrome Call', NULL, x'b1', NULL, NULL);
INSERT INTO mediafile VALUES (x'b1b10001', 'mergedMultitrack', 'B1.m4a');
INSERT INTO recordedmeeting VALUES (x'b2', 200.0, NULL, '2026-10-16 10:03:30.000', 'Google Chrome', 'com.google.Chrome');
INSERT INTO session VALUES (x'b1b10002', '2026-10-16 10:06:50.000', 'Chrome Call 2', NULL, x'b2', NULL, NULL);
INSERT INTO mediafile VALUES (x'b1b10002', 'mergedMultitrack', 'B2.m4a');
INSERT INTO recordedmeeting VALUES (x'b3', 200.0, NULL, '2026-10-16 12:00:00.000', 'Zoom', NULL);
INSERT INTO session VALUES (x'b1b10003', '2026-10-16 12:03:20.000', 'Zoom Call', NULL, x'b3', NULL, NULL);
INSERT INTO mediafile VALUES (x'b1b10003', 'mergedMultitrack', 'B3.m4a');
INSERT INTO recordedmeeting VALUES (x'b4', 200.0, NULL, '2026-10-16 12:03:25.000', 'Zoom', NULL);
INSERT INTO session VALUES (x'b1b10004', '2026-10-16 12:06:45.000', 'Zoom Call 2', NULL, x'b4', NULL, NULL);
INSERT INTO mediafile VALUES (x'b1b10004', 'mergedMultitrack', 'B4.m4a');
INSERT INTO recordedmeeting VALUES (x'b5', 200.0, NULL, '2026-10-16 12:06:50.000', 'Zoom', 'us.zoom.xos');
INSERT INTO session VALUES (x'b1b10005', '2026-10-16 12:10:10.000', 'Zoom Call 3', NULL, x'b5', NULL, NULL);
INSERT INTO mediafile VALUES (x'b1b10005', 'mergedMultitrack', 'B5.m4a');
SQL
bundle_out=$("$HT" --dry-run --output-dir "$OUT_ST" b1b10002 2>&1 || true)
if grep -qF "Stitched: 2 recordings of one meeting (b1b10001 b1b10002)" <<<"$bundle_out"; then
  pass "'Chrome' and 'Google Chrome' with one bundle id are one meeting"
else
  fail "'Chrome' and 'Google Chrome' with one bundle id are one meeting" "$bundle_out"
fi
bundle_out=$("$HT" --dry-run --output-dir "$OUT_ST" b1b10004 2>&1 || true)
if grep -qF "Stitched: 2 recordings of one meeting (b1b10003 b1b10004)" <<<"$bundle_out"; then
  pass "pieces without a bundle id group by appName"
else
  fail "pieces without a bundle id group by appName" "$bundle_out"
fi
bundle_out=$("$HT" --dry-run --output-dir "$OUT_ST" b1b10005 2>&1 || true)
if grep -qF "Session:  b1b10005" <<<"$bundle_out" && ! grep -qF "Stitched:" <<<"$bundle_out"; then
  pass "a piece with a bundle id does not join pieces without one"
else
  fail "a piece with a bundle id does not join pieces without one" "$bundle_out"
fi
sqlite3 "$DB" "DELETE FROM session WHERE hex(id) LIKE 'B1B1000%'; DELETE FROM recordedmeeting WHERE id IN (x'b1', x'b2', x'b3', x'b4', x'b5'); DELETE FROM mediafile WHERE hex(sessionID) LIKE 'B1B1000%';"

# huddle-watch keeps its own copy of GROUP_CTE; minus its readiness column
# (rec.ok), the two must group identically.
cte_of() {
  sed -n '/^GROUP_CTE="$/,/^)"$/p' "$1" | grep -v 'AS ok$' | sed -e 's/AS dur,$/AS dur/'
}
cte_t=$(cte_of "$SCRIPT")
cte_w=$(cte_of "$WATCH")
if [[ -n "$cte_t" && "$cte_t" == "$cte_w" ]] && grep -qF bundleIdentifier <<<"$cte_t"; then
  pass "huddle-transcribe and huddle-watch group split meetings identically"
else
  fail "huddle-transcribe and huddle-watch group split meetings identically" "$(diff <(echo "$cte_t") <(echo "$cte_w") || true)"
fi

# One bad piece does not block the meeting: the rest is joined with a note,
# and --mark-reviewed spares the bad piece's audio.
OUT_PART="$WORK/out-partial"
rm -rf "$OUT_PART"
part_out=$(MW_FAIL_MATCH="S2_merged" "$HT" --yes --output-dir "$OUT_PART" a1a10001 2>&1) && rc=0 || rc=$?
part_doc=$(cat "$OUT_PART/2026-10-15_split-huddle_a1a10001.md" 2>/dev/null || true)
if [[ $rc -eq 0 ]] && grep -qF "Part failed: a1a10002 (mw transcribe failed for $MEDIA/S2_merged.m4a)" <<<"$part_out" &&
  grep -qxF "> **Note:** this part (session a1a10002) was not transcribed: mw transcribe failed for $MEDIA/S2_merged.m4a." <<<"$part_doc" &&
  grep -qF "## Part 3 of 3" <<<"$part_doc" && grep -qxF "hello from S3 it's merged.m4a" <<<"$part_doc"; then
  pass "a piece mw fails on is noted and the rest is joined"
else
  fail "a piece mw fails on is noted and the rest is joined" "exit $rc: $part_out / $part_doc"
fi
part_ids=$(jq -c '[.session_ids, .missing_session_ids, .source_files]' "$OUT_PART/2026-10-15_split-huddle_a1a10001.meta.json" 2>/dev/null || true)
if [[ "$part_ids" == "[[\"a1a10001\",\"a1a10003\"],[\"a1a10002\"],[\"S1_merged.m4a\",\"S3 it's merged.m4a\"]]" ]]; then
  pass "the sidecar lists the missing part apart from the ones it holds"
else
  fail "the sidecar lists the missing part apart from the ones it holds" "$part_ids"
fi
mr_out=$("$HT" --dry-run --mark-reviewed --yes --output-dir "$OUT_PART" a1a10001 2>&1 | sed -n '/would mark/,$p' || true)
if grep -qF "would mark reviewed and delete 2 files" <<<"$mr_out" && ! grep -qF S2_merged <<<"$mr_out"; then
  pass "--mark-reviewed would not delete a missing part's audio"
else
  fail "--mark-reviewed would not delete a missing part's audio" "$mr_out"
fi
expect_rc "--mark-reviewed refuses for the missing part itself" 1 \
  --mark-reviewed --yes --output-dir "$OUT_PART" a1a10002
exists "the missing part's audio is kept" "$MEDIA/S2_merged.m4a"
rm -rf "$OUT_PART"
part_out=$(MW_FAIL_MATCH="merged" "$HT" --yes --output-dir "$OUT_PART" a1a10001 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 1 ]] && grep -qF "no part of the meeting a1a10001 could be transcribed" <<<"$part_out" &&
  ! compgen -G "$OUT_PART/*.m*" >/dev/null; then
  pass "a meeting with no part transcribed fails and writes nothing"
else
  fail "a meeting with no part transcribed fails and writes nothing" "exit $rc: $part_out"
fi
# The first piece failing: session_id is still a piece the sidecar holds.
MW_FAIL_MATCH="S1_merged" "$HT" --yes --output-dir "$OUT_PART" a1a10001 >/dev/null 2>&1 || true
part_ids=$(jq -c '[.session_id, .session_ids, .missing_session_ids, .source_file]' "$OUT_PART/2026-10-15_split-huddle_a1a10001.meta.json" 2>/dev/null || true)
if [[ "$part_ids" == '["a1a10002",["a1a10002","a1a10003"],["a1a10001"],"S2_merged.m4a"]' ]]; then
  pass "when the first piece fails, session_id is the first piece the transcript holds; the name stays"
else
  fail "when the first piece fails, session_id is the first piece the transcript holds; the name stays" "$part_ids"
fi
rm -rf "$OUT_PART"

# Audio gone: the cached transcript stands in. No saved audio row at all:
# MacWhisper has not finished the piece, so it is left out, not noted.
rm -f "$MEDIA/S2_merged.m4a"
part_out=$("$HT" --yes --output-dir "$OUT_PART" a1a10001 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -qF "Part cached: a1a10002" <<<"$part_out" &&
  grep -qxF "hello from S2_merged.m4a" "$OUT_PART/2026-10-15_split-huddle_a1a10001.md"; then
  pass "a piece whose audio is gone joins from its cached transcript"
else
  fail "a piece whose audio is gone joins from its cached transcript" "exit $rc: $part_out"
fi
rm -rf "$OUT_PART" "$HUDDLE_PIECES_DIR/a1a10002.md"
part_out=$("$HT" --yes --output-dir "$OUT_PART" a1a10001 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -qF "Part failed: a1a10002 (audio file not found at $MEDIA/S2_merged.m4a)" <<<"$part_out"; then
  pass "a piece with neither audio nor a cached transcript is noted as missing"
else
  fail "a piece with neither audio nor a cached transcript is noted as missing" "exit $rc: $part_out"
fi
rm -rf "$OUT_PART"
reset_split_media
sqlite3 "$DB" "DELETE FROM mediafile WHERE sessionID = x'a1a10003';"
rm -f "$HUDDLE_PIECES_DIR/a1a10003.md"
part_out=$("$HT" --yes --output-dir "$OUT_PART" a1a10001 2>&1) && rc=0 || rc=$?
part_ids=$(jq -c '[.session_ids, has("missing_session_ids"), .pending_session_ids]' "$OUT_PART/2026-10-15_split-huddle_a1a10001.meta.json" 2>/dev/null || true)
part_tail=$(tail -1 "$OUT_PART/2026-10-15_split-huddle_a1a10001.md" 2>/dev/null || true)
if [[ $rc -eq 0 ]] && grep -qF "a1a10003, recording 3 of 3 of this meeting, is not ready yet; it is left out." <<<"$part_out" &&
  [[ "$part_ids" == '[["a1a10001","a1a10002"],false,["a1a10003"]]' ]] &&
  grep -qF "## Part 2 of 3" "$OUT_PART/2026-10-15_split-huddle_a1a10001.md" &&
  [[ "$part_tail" == "> **Note:** this transcript may be incomplete. MacWhisper had not finished saving part 3 of 3 (starts at 02:16, session a1a10003) when it was written. Transcribe the meeting again when that part finishes." ]]; then
  pass "a piece with no saved audio yet is left out, recorded as pending, and named at the end"
else
  fail "a piece with no saved audio yet is left out, recorded as pending, and named at the end" "exit $rc: $part_out $part_ids $part_tail"
fi
sqlite3 "$DB" "INSERT INTO mediafile VALUES (x'a1a10003', 'mergedMultitrack', 'S3 it''s merged.m4a');"
rm -rf "$OUT_PART"

# --restitch replaces only its own unreviewed transcript. Each case starts
# from the one-part transcript the watcher writes first.
RS="$WORK/out-restitch"
RS_DOC="$RS/2026-10-15_split-huddle_a1a10001.md"
RS_META="$RS/2026-10-15_split-huddle_a1a10001.meta.json"
restitch_seed() {
  rm -rf "$RS" "$HUDDLE_PIECES_DIR"
  mkdir -p "$RS" "$HUDDLE_PIECES_DIR"
  printf 'Speaker 1\n*00:00-00:05*\ncached piece one\n\n' >"$HUDDLE_PIECES_DIR/a1a10001.md"
  printf 'one-part transcript\n' >"$RS_DOC"
  # The hash of the doc as the watcher wrote it, so it is replaceable.
  local rs_hash
  rs_hash=$(shasum -a 256 <"$RS_DOC")
  jq -n --argjson extra "$1" --arg h "${rs_hash%% *}" '{session_id: "a1a10001", date: "2026-10-15", duration_seconds: 83,
    source_file: "S1_merged.m4a", output_file: "2026-10-15_split-huddle_a1a10001.md", title: "Split Huddle",
    reviewed: false, deleted_source: false, doc_sha256: $h} + $extra' >"$RS_META"
}
# A cached part that cannot be read mid-join fails the run; nothing is replaced.
restitch_seed '{"restitchable": true}'
chmod 000 "$HUDDLE_PIECES_DIR/a1a10001.md"
rs_out=$("$HT" --restitch --yes --output-dir "$RS" a1a10001 2>&1) && rc=0 || rc=$?
chmod 600 "$HUDDLE_PIECES_DIR/a1a10001.md"
if [[ $rc -ne 0 ]] && grep -qF "failed to join" <<<"$rs_out" && grep -qxF "one-part transcript" "$RS_DOC"; then
  pass "an unreadable cached part fails the join and leaves the transcript alone"
else
  fail "an unreadable cached part fails the join and leaves the transcript alone" "exit $rc: $rs_out"
fi
restitch_seed '{"restitchable": true}'
rm -f "$WORK/mw-calls"
rs_out=$(MW_CALLS="$WORK/mw-calls" "$HT" --restitch --yes --output-dir "$RS" a1a10001 2>&1) && rc=0 || rc=$?
rs_calls=$(awk '{ print $NF }' "$WORK/mw-calls" 2>/dev/null | sed 's|.*/||' | tr '\n' ',' || true)
if [[ $rc -eq 0 ]] && grep -qF "Replaced: $RS_DOC" <<<"$rs_out" && grep -qF "Transcript written: $RS_DOC" <<<"$rs_out"; then
  pass "--restitch replaces its own unreviewed transcript in place"
else
  fail "--restitch replaces its own unreviewed transcript in place" "exit $rc: $rs_out"
fi
if [[ "$rs_calls" == "S2_merged.m4a,merged.m4a," ]] && grep -qxF "cached piece one" "$RS_DOC" &&
  grep -qF "## Part 3 of 3" "$RS_DOC" && ! grep -qF "one-part transcript" "$RS_DOC"; then
  pass "--restitch transcribes only the new pieces and reuses the cached one"
else
  fail "--restitch transcribes only the new pieces and reuses the cached one" "mw: $rs_calls"
fi
rs_files=$(find "$RS" -name '*.md' ! -name '_index.md' | wc -l | tr -d ' ')
rs_meta=$(jq -c '[.session_ids, .restitchable, .reviewed]' "$RS_META" 2>/dev/null || true)
if [[ "$rs_files" == "1" && "$rs_meta" == '[["a1a10001","a1a10002","a1a10003"],true,false]' ]]; then
  pass "the replaced sidecar names all three pieces and stays replaceable"
else
  fail "the replaced sidecar names all three pieces and stays replaceable" "files=$rs_files meta=$rs_meta"
fi
rm -f "$WORK/mw-calls"
rs_out=$(MW_CALLS="$WORK/mw-calls" "$HT" --restitch --yes --output-dir "$RS" a1a10003 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -qF "Already transcribed: $RS_META" <<<"$rs_out"; then
  pass "--restitch of a meeting whose sidecar names every piece does nothing"
else
  fail "--restitch of a meeting whose sidecar names every piece does nothing" "exit $rc: $rs_out"
fi
absent "--restitch with nothing new runs no mw" "$WORK/mw-calls"

# Not replaced: a manual transcript, a reviewed one, or any transcript when
# the run is manual (decision d). Each gets -2.
for rs_case in manual reviewed deleted by-hand; do
  case "$rs_case" in
    manual) restitch_seed '{}' ;;
    reviewed) restitch_seed '{"restitchable": true, "reviewed": true}' ;;
    deleted) restitch_seed '{"restitchable": true, "reviewed": true, "deleted_source": true}' ;;
    *) restitch_seed '{"restitchable": true}' ;;
  esac
  rs_flag="--restitch" rs_part1="cached piece one"
  # A manual run transcribes afresh any piece whose audio is still there.
  [[ "$rs_case" != "by-hand" ]] || rs_flag="--skip-existing" rs_part1="hello from S1_merged.m4a"
  # A reviewed piece's audio is gone; its cached transcript still joins.
  [[ "$rs_case" != "deleted" ]] || rm -f "$MEDIA/S1_merged.m4a"
  rs_out=$("$HT" "$rs_flag" --yes --output-dir "$RS" a1a10001 2>&1) && rc=0 || rc=$?
  rs_two="$RS/2026-10-15_split-huddle-2_a1a10001.md"
  rs_first=$(cat "$RS_DOC" 2>/dev/null || true)
  if [[ $rc -eq 0 && "$rs_first" == "one-part transcript" ]] && ! grep -qF "Replaced:" <<<"$rs_out" &&
    head -1 "$rs_two" 2>/dev/null | grep -qF "may duplicate 2026-10-15_split-huddle_a1a10001.md" &&
    grep -qxF "$rs_part1" "$rs_two" && grep -qF "## Part 3 of 3" "$rs_two"; then
    pass "$rs_case: the earlier transcript is kept and the whole meeting goes to -2"
  else
    fail "$rs_case: the earlier transcript is kept and the whole meeting goes to -2" "exit $rc: $rs_out"
  fi
  reset_split_media
done
# Two sidecars now name a1a10001: --mark-reviewed still refuses to guess.
expect_rc "--mark-reviewed refuses while a stitched -2 and the original both name a piece" 1 \
  --mark-reviewed --yes --output-dir "$RS" a1a10001
exists "--mark-reviewed with two sidecars keeps the audio" "$MEDIA/S2_merged.m4a"
# Asked through a piece only the -2 names, it still sees the shared one.
mr_out=$("$HT" --mark-reviewed --yes --output-dir "$RS" a1a10003 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 1 ]] && grep -qF "other sidecars in $RS also name" <<<"$mr_out" &&
  [[ -f "$MEDIA/S1_merged.m4a" && -f "$MEDIA/S3 it's merged.m4a" ]]; then
  pass "--mark-reviewed through an unshared piece refuses while another sidecar holds a shared one"
else
  fail "--mark-reviewed through an unshared piece refuses while another sidecar holds a shared one" "exit $rc: $mr_out"
fi
# A non-string entry in the -2's ids does not switch the shared-piece guard off.
rs_two_meta="${rs_two%.md}.meta.json"
cp "$rs_two_meta" "$WORK/rs-two.orig"
jq '.session_ids += [{}]' "$WORK/rs-two.orig" >"$rs_two_meta"
mr_out=$("$HT" --mark-reviewed --yes --output-dir "$RS" a1a10003 2>&1) && rc=0 || rc=$?
mv "$WORK/rs-two.orig" "$rs_two_meta"
if [[ $rc -eq 1 ]] && grep -qF "other sidecars in $RS also name" <<<"$mr_out" &&
  [[ -f "$MEDIA/S1_merged.m4a" && -f "$MEDIA/S3 it's merged.m4a" ]]; then
  pass "--mark-reviewed refuses a shared piece when the sidecar also holds a non-string id"
else
  fail "--mark-reviewed refuses a shared piece when the sidecar also holds a non-string id" "exit $rc: $mr_out"
fi

# A retry that adds nothing (the only new piece fails again) leaves the
# transcript alone and fails, so the watcher counts the attempt.
restitch_seed '{"restitchable": true, "session_ids": ["a1a10001", "a1a10003"], "missing_session_ids": ["a1a10002"]}'
printf 'Speaker 1\n*00:00-00:05*\ncached piece three\n\n' >"$HUDDLE_PIECES_DIR/a1a10003.md"
rs_out=$(MW_FAIL_MATCH="S2_merged" "$HT" --restitch --yes --output-dir "$RS" a1a10001 2>&1) && rc=0 || rc=$?
rs_first=$(cat "$RS_DOC" 2>/dev/null || true)
if [[ $rc -eq 1 && "$rs_first" == "one-part transcript" ]] && grep -qF "Part failed: a1a10002" <<<"$rs_out" &&
  grep -qF "no new part of the meeting a1a10001 could be transcribed" <<<"$rs_out"; then
  pass "--restitch that only fails again rewrites nothing and exits 1"
else
  fail "--restitch that only fails again rewrites nothing and exits 1" "exit $rc: $rs_out"
fi
rs_out=$("$HT" --restitch --yes --output-dir "$RS" a1a10001 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -qF "Replaced: $RS_DOC" <<<"$rs_out" && grep -qxF "cached piece three" "$RS_DOC" &&
  grep -qxF "hello from S2_merged.m4a" "$RS_DOC"; then
  pass "a missing part that succeeds later fills its place in the same transcript"
else
  fail "a missing part that succeeds later fills its place in the same transcript" "exit $rc: $rs_out"
fi

# A hand-edited transcript is kept: the doc no longer matches the hash its
# sidecar recorded, so the meeting goes to -2.
restitch_seed '{"restitchable": true}'
printf 'my own edit\n' >>"$RS_DOC"
rs_out=$("$HT" --restitch --yes --output-dir "$RS" a1a10001 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && ! grep -qF "Replaced:" <<<"$rs_out" && grep -qxF "my own edit" "$RS_DOC" &&
  head -1 "$RS/2026-10-15_split-huddle-2_a1a10001.md" 2>/dev/null | grep -qF "may duplicate 2026-10-15_split-huddle_a1a10001.md"; then
  pass "--restitch keeps a transcript edited by hand and writes -2"
else
  fail "--restitch keeps a transcript edited by hand and writes -2" "exit $rc: $rs_out"
fi
# Reviewed while the run transcribes: the last look before writing sees it.
restitch_seed '{"restitchable": true}'
rs_out=$(MW_MARK_REVIEWED="$RS_META" "$HT" --restitch --yes --output-dir "$RS" a1a10001 2>&1) && rc=0 || rc=$?
rs_first=$(cat "$RS_DOC" 2>/dev/null || true)
if [[ $rc -eq 0 && "$rs_first" == "one-part transcript" ]] && ! grep -qF "Replaced:" <<<"$rs_out" &&
  grep -qF "was reviewed or edited while this ran; writing 2026-10-15_split-huddle-2_a1a10001.md instead" <<<"$rs_out" &&
  head -1 "$RS/2026-10-15_split-huddle-2_a1a10001.md" 2>/dev/null | grep -qF "may duplicate 2026-10-15_split-huddle_a1a10001.md" &&
  [[ "$(jq -r '.reviewed' "$RS_META" 2>/dev/null || true)" == "true" ]]; then
  pass "--restitch writes -2 when the transcript is reviewed mid-run"
else
  fail "--restitch writes -2 when the transcript is reviewed mid-run" "exit $rc: $rs_out"
fi

# --pending: left out, named at the end. Here it is the first piece, so
# session_id is the first part held; the name stays.
restitch_seed '{}'
rm -f "$RS_DOC" "$RS_META" "$HUDDLE_PIECES_DIR/a1a10001.md"
rs_out=$("$HT" --restitch --yes --output-dir "$RS" --pending a1a10001 a1a10002 2>&1) && rc=0 || rc=$?
rs_meta=$(jq -c '[.session_id, .session_ids, .pending_session_ids, .restitchable, (.doc_sha256 | length)]' "$RS_META" 2>/dev/null || true)
rs_tail=$(tail -1 "$RS_DOC" 2>/dev/null || true)
rs_heads=$(grep '^## ' "$RS_DOC" 2>/dev/null | tr '\n' '|' || true)
if [[ $rc -eq 0 && "$rs_meta" == '["a1a10002",["a1a10002","a1a10003"],["a1a10001"],true,64]' ]] &&
  [[ "$rs_heads" == "## Part 2 of 3 — starts at 01:29, after a 6 s gap|## Part 3 of 3 — starts at 02:16, after a 4 s gap|" ]] &&
  [[ "$rs_tail" == "> **Note:** this transcript may be incomplete. MacWhisper had not finished saving part 1 of 3 (starts at 00:00, session a1a10001) when it was written. It will be updated when that part finishes." ]] &&
  grep -qx "Part pending: a1a10001" <<<"$rs_out"; then
  pass "--pending leaves a recording out, records it, and ends the transcript with a note naming it"
else
  fail "--pending leaves a recording out, records it, and ends the transcript with a note naming it" "exit $rc: $rs_meta $rs_heads $rs_tail"
fi
rs_out=$("$HT" --restitch --yes --output-dir "$RS" --pending a1a10001 a1a10001 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -qF "Already transcribed: $RS_META" <<<"$rs_out"; then
  pass "--restitch with the same recording still pending does nothing"
else
  fail "--restitch with the same recording still pending does nothing" "exit $rc: $rs_out"
fi
# By hand, a missing or pending part counts as covered: retrying it is the watcher's job.
all_out=$("$HT" --all --dry-run --output-dir "$RS" 2>&1 || true)
skip_out=$("$HT" --skip-existing --yes --output-dir "$RS" a1a10001 2>&1) && rc=0 || rc=$?
if ! grep -qF a1a10001 <<<"$all_out" && [[ $rc -eq 0 ]] && grep -qF "Already transcribed: $RS_META" <<<"$skip_out"; then
  pass "--all and --skip-existing leave a meeting with a pending part to the watcher"
else
  fail "--all and --skip-existing leave a meeting with a pending part to the watcher" "$all_out / exit $rc: $skip_out"
fi
rm -f "$WORK/mw-calls"
rs_out=$(MW_CALLS="$WORK/mw-calls" "$HT" --restitch --yes --output-dir "$RS" a1a10001 2>&1) && rc=0 || rc=$?
rs_meta=$(jq -c '[.session_id, .session_ids, has("pending_session_ids")]' "$RS_META" 2>/dev/null || true)
if [[ $rc -eq 0 && "$rs_meta" == '["a1a10001",["a1a10001","a1a10002","a1a10003"],false]' ]] &&
  grep -qF "Replaced: $RS_DOC" <<<"$rs_out" && ! grep -qF "may be incomplete" "$RS_DOC" &&
  grep -qF "## Part 1 of 3" "$RS_DOC" && [[ "$(grep -c . "$WORK/mw-calls" 2>/dev/null || true)" == "1" ]]; then
  pass "once the pending recording is ready, --restitch replaces the transcript and the note goes"
else
  fail "once the pending recording is ready, --restitch replaces the transcript and the note goes" "exit $rc: $rs_meta $rs_out"
fi
for bad_pending in "xyz" "--all"; do
  expect_rc "--pending '$bad_pending' is rejected" 1 --restitch --dry-run --output-dir "$RS" --pending "$bad_pending" a1a10001
done
expect_rc "--pending cannot be combined with --all" 1 --all --dry-run --output-dir "$RS" --pending a1a10001
# Like any session id: dashes and case are ignored, and a prefix matches. A
# cached piece is never pending, so these run without the cache.
HUDDLE_PIECES_DIR="$WORK/no-pieces" expect_out "--pending takes a dashed, upper-case id" \
  "Part 3:   a1a10003 starts at 02:16, after a 4 s gap: (not ready yet; left out)" \
  --dry-run --output-dir "$RS" --pending A1A1-0003 a1a10001
HUDDLE_PIECES_DIR="$WORK/no-pieces" expect_out "--pending matches by prefix; with none ready, nothing is written" \
  "Error: no recording of the meeting a1a10001 is ready yet." --restitch --yes --output-dir "$RS" --pending a1a1000 a1a10001
absent "--pending with none ready creates no cache" "$WORK/no-pieces"
rm -rf "$RS"
expect_rc "--restitch cannot be combined with --all" 1 --restitch --all --output-dir "$RS"
expect_rc "--restitch cannot be combined with --mark-reviewed" 1 --restitch --mark-reviewed a1a10001

# --mark-reviewed through any recording removes every piece's audio, and nothing else's.
for sid in a1a10001 a1a10002 a1a10003; do
  printf 'cached\n' >"$HUDDLE_PIECES_DIR/$sid.md"
done
mr_out=$("$HT" --dry-run --mark-reviewed --yes --output-dir "$OUT_ST" a1a10003 2>&1 || true)
if grep -qF "would mark reviewed and delete 3 files" <<<"$mr_out" && grep -qF "S3 it's merged.m4a" <<<"$mr_out" &&
  grep -qF "  $HUDDLE_PIECES_DIR/a1a10002.md" <<<"$mr_out"; then
  pass "--dry-run --mark-reviewed lists every piece of a split meeting and its cached transcripts"
else
  fail "--dry-run --mark-reviewed lists every piece of a split meeting and its cached transcripts" "$mr_out"
fi
exists "--dry-run --mark-reviewed keeps the pieces" "$MEDIA/S1_merged.m4a"
# A removal failing part-way names what is already gone. The stub trash
# refuses the second piece; the full run below then finishes the job.
TRASH_BIN="$WORK/trash-bin"
mkdir -p "$TRASH_BIN" "$WORK/trashed"
cat >"$TRASH_BIN/trash" <<'STUB'
#!/usr/bin/env bash
[[ "$1" != *S2_merged.m4a ]] || exit 1
mv -- "$1" "$TRASHED_DIR/"
STUB
chmod +x "$TRASH_BIN/trash"
mr_out=$(PATH="$TRASH_BIN:$PATH" TRASHED_DIR="$WORK/trashed" \
  "$HT" --mark-reviewed --yes --output-dir "$OUT_ST" a1a10003 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]] && grep -qF "failed to trash $MEDIA/S2_merged.m4a" <<<"$mr_out" &&
  grep -qF "Already removed: $MEDIA/S1_merged.m4a" <<<"$mr_out"; then
  pass "a removal failing part-way names the files already removed"
else
  fail "a removal failing part-way names the files already removed" "exit $rc: $mr_out"
fi
expect_rc "--mark-reviewed through a later recording succeeds" 0 \
  --mark-reviewed --yes --output-dir "$OUT_ST" a1a10003
for gone in S1_merged.m4a S2_merged.m4a "S3 it's merged.m4a"; do
  absent "--mark-reviewed removes $gone" "$MEDIA/$gone"
done
for sid in a1a10001 a1a10002 a1a10003; do
  absent "--mark-reviewed removes the cached transcript of $sid" "$HUDDLE_PIECES_DIR/$sid.md"
done
exists "--mark-reviewed leaves another app's recording alone" "$MEDIA/S4_merged.m4a"
exists "--mark-reviewed leaves a recording past the gap alone" "$MEDIA/S5_merged.m4a"
mr_flags=$(jq -r '[.reviewed, .deleted_source] | join(",")' "$ST_BASE.meta.json" 2>/dev/null || true)
if [[ "$mr_flags" == "true,true" ]]; then
  pass "the stitched sidecar records reviewed and deleted_source"
else
  fail "the stitched sidecar records reviewed and deleted_source" "flags: $mr_flags"
fi
expect_out "a repeated --mark-reviewed reports the pieces already gone" "already gone" \
  --mark-reviewed --yes --output-dir "$OUT_ST" a1a10001

# A piece with its own pre-stitching transcript releases only its own audio.
reset_split_media
OUT_LEGACY="$WORK/out-legacy"
rm -rf "$OUT_LEGACY"
mkdir -p "$OUT_LEGACY"
printf 'transcript body\n' >"$OUT_LEGACY/2026-10-15_later-piece_a1a10002.md"
printf '{"session_id": "a1a10002", "output_file": "2026-10-15_later-piece_a1a10002.md"}\n' \
  >"$OUT_LEGACY/2026-10-15_later-piece_a1a10002.meta.json"
mr_out=$("$HT" --dry-run --mark-reviewed --yes --output-dir "$OUT_LEGACY" a1a10002 2>&1 || true)
if grep -qF "would mark reviewed and delete $MEDIA/S2_merged.m4a)" <<<"$mr_out"; then
  pass "--dry-run --mark-reviewed of a per-piece transcript names only that piece"
else
  fail "--dry-run --mark-reviewed of a per-piece transcript names only that piece" "$mr_out"
fi
expect_rc "--mark-reviewed of a per-piece transcript succeeds" 0 \
  --mark-reviewed --yes --output-dir "$OUT_LEGACY" a1a10002
absent "--mark-reviewed of a per-piece transcript removes that piece" "$MEDIA/S2_merged.m4a"
exists "--mark-reviewed of a per-piece transcript keeps the first piece" "$MEDIA/S1_merged.m4a"
exists "--mark-reviewed of a per-piece transcript keeps the last piece" "$MEDIA/S3 it's merged.m4a"
# Stitched by hand after the pieces had their own transcripts: the refusal
# names both sidecars and says what to move.
printf 'stitched body\n' >"$OUT_LEGACY/2026-10-15_split-huddle_a1a10001.md"
printf '{"session_id": "a1a10001", "session_ids": ["a1a10001", "a1a10002", "a1a10003"], "output_file": "2026-10-15_split-huddle_a1a10001.md"}\n' \
  >"$OUT_LEGACY/2026-10-15_split-huddle_a1a10001.meta.json"
mr_out=$("$HT" --mark-reviewed --yes --output-dir "$OUT_LEGACY" a1a10002 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 1 ]] && grep -qF "2026-10-15_later-piece_a1a10002.meta.json" <<<"$mr_out" &&
  grep -qF "2026-10-15_split-huddle_a1a10001.meta.json" <<<"$mr_out" &&
  grep -qF "2026-10-15_later-piece_a1a10002.md, holds a1a10002 (a per-recording transcript)" <<<"$mr_out" &&
  grep -qF "move each per-recording .md and .meta.json pair" <<<"$mr_out"; then
  pass "--mark-reviewed names the per-recording and stitched sidecars it refuses over, and the fix"
else
  fail "--mark-reviewed names the per-recording and stitched sidecars it refuses over, and the fix" "exit $rc: $mr_out"
fi
exists "the refusal keeps the last piece's audio" "$MEDIA/S3 it's merged.m4a"
rm -rf "$OUT_LEGACY"

sqlite3 "$DB" "DELETE FROM session WHERE hex(id) LIKE 'A1A1000%'; DELETE FROM recordedmeeting WHERE id IN (x'a1', x'a2', x'a3', x'a4', x'a5'); DELETE FROM mediafile WHERE hex(sessionID) LIKE 'A1A1000%';"
rm -f "$MEDIA"/S[1-5]*.m4a
rm -rf "$OUT_ST" "$HUDDLE_PIECES_DIR"
unset HUDDLE_PIECES_DIR

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
if [[ -n "${ALREADY_TRANSCRIBED:-}" ]]; then
  echo "Already transcribed: /tmp/out/${1:0:8}.meta.json"
  exit 0
fi
# The lines a split meeting's partial join and in-place re-stitch print.
[[ -z "${STUB_PART_FAILED:-}" ]] || echo "Part failed: $STUB_PART_FAILED (mw transcribe failed for x.m4a)"
[[ -z "${STUB_PART_PENDING:-}" ]] || echo "Part pending: $STUB_PART_PENDING"
[[ -z "${STUB_REPLACED:-}" ]] || echo "Replaced: ${STUB_OUT_PATH:-/tmp/out/${1:0:8}.md}"
echo "Transcript written: ${STUB_OUT_PATH:-/tmp/out/${1:0:8}.md}"
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

# Alerts are detached, so the stub may still be writing after a run returns.
# Wait (bounded) until none remains.
notify_drain() {
  local tries=0
  if ! command -v pgrep >/dev/null 2>&1; then
    sleep 0.5
    return 0
  fi
  while pgrep -f -- "$WATCH|$WBIN/osascript-" >/dev/null 2>&1 && ((tries < 50)); do
    sleep 0.1
    tries=$((tries + 1))
  done
  return 0
}

notify_reset() {
  notify_drain
  rm -f "$NOTIFYLOG" "$WSTATE".alert-*
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
CREATE TABLE mediafile (sessionID BLOB, type TEXT, filename TEXT);

-- READY: every condition satisfied. This is the one the watcher must pick.
INSERT INTO recordedmeeting VALUES (x'71', 803.25, 'rmReady');
INSERT INTO session VALUES (x'aaaa1111', '2026-08-31 15:18:37.000', 'Ready Session',
  NULL, x'71', NULL, 1, 1, 0, 0, NULL, NULL);

-- No audio row yet: MacWhisper has not finalized the meeting. It is the only
-- session below without a mediafile row, so that row alone is what gates it.
INSERT INTO recordedmeeting VALUES (x'72', 900.0, 'rmNoAudio');
INSERT INTO session VALUES (x'bbbb2222', '2026-08-30 10:00:00.000', 'No Audio Yet',
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

-- Added after the inserts above, which are positional. 0 for every row: none
-- of them is a live meeting still in progress.
ALTER TABLE session ADD COLUMN isIncomingLiveStream BOOLEAN NOT NULL DEFAULT 0;
-- NULL for every row above, which keeps them out of split-meeting grouping.
ALTER TABLE recordedmeeting ADD COLUMN date TEXT;
ALTER TABLE recordedmeeting ADD COLUMN appName TEXT;
ALTER TABLE recordedmeeting ADD COLUMN bundleIdentifier TEXT;

-- Every session except bbbb2222 has its audio saved, so each one is gated
-- only by the condition its comment names.
INSERT INTO mediafile SELECT id, 'mergedMultitrack', 'saved.m4a' FROM session
  WHERE id != x'bbbb2222';
SQL
}

build_watch_db

# watch <args...>: run huddle-watch against the fixture. Every path the
# watcher could use is repointed, so it can touch nothing real.
watch() {
  local rc=0
  env -u FAIL_TRANSCRIBE \
    HUDDLE_DB="$WDB" \
    HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
    HUDDLE_STATE_FILE="$WSTATE" \
    HUDDLE_LOG_FILE="$WLOG" \
    CALLS="$CALLS" \
    "$WATCH" "$@" || rc=$?
  notify_drain
  return $rc
}

# watch_failing <args...>: same, but the stub transcribe exits non-zero.
watch_failing() {
  local rc=0
  env FAIL_TRANSCRIBE=1 \
    HUDDLE_DB="$WDB" \
    HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
    HUDDLE_STATE_FILE="$WSTATE" \
    HUDDLE_LOG_FILE="$WLOG" \
    CALLS="$CALLS" \
    "$WATCH" "$@" || rc=$?
  notify_drain
  return $rc
}

watch_reset() {
  notify_drain
  rm -f "$WSTATE" "$WLOG" "$CALLS" "$NOTIFYLOG" "$WSTATE".alert-*
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
refute_watch_out "session with no saved audio is not selected" "bbbb2222" --dry-run
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

# --- live-captured meetings (MacWhisper since 2026-09-24) ---
#
# These are never marked diarized. Saved audio and the live flag gate them.
sqlite3 "$WDB" <<'SQL'
INSERT INTO recordedmeeting (id, duration, title) VALUES (x'81', 1500.0, 'rmLiveDone');
INSERT INTO session VALUES (x'abcd1313', '2026-09-24 20:01:11.000', 'Live Finalized',
  NULL, x'81', NULL, 1, 0, 0, 0, NULL, NULL, 0);
INSERT INTO mediafile VALUES (x'abcd1313', 'mergedMultitrack', 'live.m4a');
INSERT INTO recordedmeeting (id, duration, title) VALUES (x'82', 1500.0, 'rmLiveNow');
INSERT INTO session VALUES (x'abcd1414', '2026-09-24 21:00:00.000', 'Live In Progress',
  NULL, x'82', NULL, 1, 0, 0, 0, NULL, NULL, 1);
INSERT INTO recordedmeeting (id, duration, title) VALUES (x'83', 1500.0, 'rmLiveNowAudio');
INSERT INTO session VALUES (x'abcd1515', '2026-09-24 22:00:00.000', 'Live With Audio',
  NULL, x'83', NULL, 1, 0, 0, 0, NULL, NULL, 1);
INSERT INTO mediafile VALUES (x'abcd1515', 'mergedMultitrack', 'live2.m4a');
SQL
expect_watch_out "finalized live meeting without diarization is selected" "abcd1313" --dry-run
refute_watch_out "live meeting in progress is not selected" "abcd1414" --dry-run
refute_watch_out "live flag alone excludes a session that has audio" "abcd1515" --dry-run
expect_watch_out "--list shows the live and audio columns" "LIV AUD" --list
build_watch_db

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
# Count session records only: the seeded file also carries a `#` header, which
# is what keeps a zero-session seed from leaving a zero-byte file.
seeded=$(grep -c -v -e '^#' -e '^$' "$WSTATE" || true)
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

# --- seeding with nothing ready still marks the first run as done ---

# A first run on a database with no ready sessions (fresh MacWhisper, or
# everything still transcribing) seeds zero ids. If that leaves a zero-byte
# state file, the -s gate above is still true on the next run, so the first
# real session gets seeded as `done` and is never transcribed -- silently,
# with no error and no notification. The seeding pass must produce a
# non-empty file even when it records no sessions.
watch_reset
build_watch_db
# Make every session non-ready, so READY_ROWS comes back empty.
sqlite3 "$WDB" "UPDATE session SET transcriptionDidSucceed = 0;"
expect_watch_rc "first run with nothing ready exits 0" 0 --once
exists "first run with nothing ready creates the state file" "$WSTATE"
absent "first run with nothing ready transcribes nothing" "$CALLS"
if [[ -s "$WSTATE" ]]; then
  pass "seeding nothing still leaves a non-empty state file"
else
  fail "seeding nothing still leaves a non-empty state file" "state file is zero bytes"
fi
# The real test of the bug: a session becoming ready after an empty seed must
# be transcribed, not re-seeded as already-done.
sqlite3 "$WDB" "UPDATE session SET transcriptionDidSucceed = 1 WHERE id = x'aaaa1111';"
expect_watch_rc "session ready after an empty seed exits 0" 0 --once
if [[ -f "$CALLS" ]] && grep -q 'aaaa1111' "$CALLS"; then
  pass "a session ready after an empty seed is transcribed"
else
  diag=$(dump "$CALLS")
  fail "a session ready after an empty seed is transcribed" "$diag"
fi

# --- the child runs under huddle-watch's bash, not its shebang's ---

# launchd's `env bash` is /bin/bash 3.2. With 3.2 first on PATH, the child
# must still report a modern bash.
old_bash=""
for candidate in /bin/bash /usr/bin/bash; do
  if [[ -x "$candidate" ]] && ! bash_is_modern "$candidate"; then
    old_bash="$candidate"
    break
  fi
done
if [[ -n "$old_bash" ]]; then
  OLDBIN="$WORK/oldbash-bin"
  mkdir -p "$OLDBIN"
  ln -sf "$old_bash" "$OLDBIN/bash"
  cat >"$WBIN/huddle-transcribe-ver" <<'STUB'
#!/usr/bin/env bash
printf 'bash-major=%s\n' "${BASH_VERSINFO[0]}" >>"$CALLS"
echo "Transcript written: /tmp/out/${1:0:8}.md"
STUB
  chmod +x "$WBIN/huddle-transcribe-ver"
  build_watch_db
  watch_reset
  watch --once >/dev/null 2>&1 || true
  sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'bbbb2222', 'mergedMultitrack', 'saved.m4a');"
  env HUDDLE_DB="$WDB" HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe-ver" \
    HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" CALLS="$CALLS" \
    PATH="$OLDBIN:$PATH" "$BASH" "$WATCH" --once >/dev/null 2>&1 || true
  child_major=$(sed -n 's/^bash-major=//p' "$CALLS" 2>/dev/null | tail -1)
  if [[ -n "$child_major" ]] && ((child_major >= 4)); then
    pass "huddle-transcribe runs under huddle-watch's bash, not PATH's"
  else
    diag=$(dump "$CALLS")
    fail "huddle-transcribe runs under huddle-watch's bash, not PATH's" "$diag"
  fi

  # And run directly under 3.2, huddle-transcribe refuses with one clear line.
  t_rc=0
  t_out=$("$old_bash" "$SCRIPT" --list 2>&1) || t_rc=$?
  if ((t_rc != 0)) && [[ "$t_out" == *"requires bash 4.2 or newer"* ]]; then
    pass "huddle-transcribe rejects an inadequate bash"
  else
    fail "huddle-transcribe rejects an inadequate bash" "rc=$t_rc: $t_out"
  fi
else
  skip "huddle-transcribe runs under huddle-watch's bash, not PATH's (no bash <4.2 available)"
  skip "huddle-transcribe rejects an inadequate bash (no bash <4.2 available)"
fi

# Restore the shared fixture for the tests that follow.
build_watch_db
watch_reset
watch --once >/dev/null 2>&1 || true

# --- already-seen sessions are skipped ---

expect_watch_rc "second run over seeded state exits 0" 0 --once
absent "seeded session is not re-transcribed" "$CALLS"
expect_watch_out "--list marks a seeded session as seen" "seen" --list

# --- a newly-ready session is detected and transcribed ---

# Give the no-audio session its audio row, as MacWhisper does when it
# finalizes a meeting. This is the event the watcher exists for.
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'bbbb2222', 'mergedMultitrack', 'saved.m4a');"
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
if [[ -f "$CALLS" ]] && grep -q -- '--restitch' "$CALLS"; then
  pass "--restitch is passed so finished sessions are not redone"
else
  fail "--restitch is passed so finished sessions are not redone"
fi

# --- a session that already has a transcript is recorded, not redone ---

# Sessions done by hand or by --all are not in the state file. The watcher
# must mark them done and post no notification.
build_watch_db
watch_reset
watch --once >/dev/null 2>&1 || true
notify_reset
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'bbbb2222', 'mergedMultitrack', 'saved.m4a');"
rc=0
ALREADY_TRANSCRIBED=1 watch --once >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 0 ]]; then pass "already-transcribed session exits 0"; else fail "already-transcribed session exits 0" "exit $rc"; fi
if grep -q '^bbbb2222 done$' "$WSTATE"; then
  pass "already-transcribed session is marked done"
else
  diag=$(dump "$WSTATE")
  fail "already-transcribed session is marked done" "$diag"
fi
if grep -qF 'SKIP bbbb2222' "$WLOG" 2>/dev/null; then
  pass "already-transcribed session is logged as SKIP"
else
  diag=$(dump "$WLOG")
  fail "already-transcribed session is logged as SKIP" "$diag"
fi
absent "already-transcribed session posts no notification" "$NOTIFYLOG"
rm -f "$CALLS"
expect_watch_rc "run after a skip exits 0" 0 --once
absent "a skipped session is not queued again" "$CALLS"
build_watch_db
watch_reset
watch --once >/dev/null 2>&1 || true

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
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'dddd4444', 'mergedMultitrack', 'saved.m4a'); UPDATE session SET isBeingRetranscribed = 0 WHERE id = x'dddd4444';"
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
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'eeee5555', 'mergedMultitrack', 'saved.m4a'); UPDATE session SET isTransient = 0 WHERE id = x'eeee5555';"
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
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'ffff6666', 'mergedMultitrack', 'saved.m4a'); UPDATE session SET dateDeleted = NULL WHERE id = x'ffff6666';"
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
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'aaaa7777', 'mergedMultitrack', 'saved.m4a');"
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
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'bbbb2222', 'mergedMultitrack', 'saved.m4a');"
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
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'bbbb2222', 'mergedMultitrack', 'saved.m4a');"
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
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'bbbb2222', 'mergedMultitrack', 'saved.m4a');"
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
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'bbbb2222', 'mergedMultitrack', 'saved.m4a');"
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
empty_seeded=$(grep -c -v -e '^#' -e '^$' "$WSTATE" || true)
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
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'bbbb2222', 'mergedMultitrack', 'saved.m4a');"
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
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'bbbb2222', 'mergedMultitrack', 'saved.m4a');"
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
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'bbbb2222', 'mergedMultitrack', 'saved.m4a');"
watch --once >/dev/null 2>&1 || true
if [[ -f "$WLOG" ]]; then
  # GNU stat must be tried first. Its -f means --file-system, so BSD's
  # `stat -f '%Lp'` does not fail on Linux -- it succeeds and prints a
  # filesystem report, which the 2>/dev/null cannot catch because there is
  # no error. BSD stat rejects -c outright, so this order is unambiguous on
  # both platforms. Anything that is not three octal digits is an error.
  log_mode=$(stat -c '%a' "$WLOG" 2>/dev/null || stat -f '%Lp' "$WLOG" 2>/dev/null || echo "?")
  [[ "$log_mode" =~ ^[0-7]{3}$ ]] || log_mode="unparseable: $log_mode"
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
    # ProgramArguments[0] must be an absolute bash, not the script. launchd
    # hands the job a minimal PATH, so a plist naming the script relies on
    # `#!/usr/bin/env bash` resolving there -- which finds macOS bash 3.2 and
    # dies in log() on printf's 4.2-only `%(...)T`. Naming the interpreter
    # explicitly means the shebang is never consulted.
    pa0=$(plutil -extract ProgramArguments.0 raw -o - "$generated" 2>/dev/null || echo "?")
    pa1=$(plutil -extract ProgramArguments.1 raw -o - "$generated" 2>/dev/null || echo "?")
    if [[ "$pa0" == /*bash ]]; then
      pass "the plist names an absolute bash as ProgramArguments[0]"
    else
      fail "the plist names an absolute bash as ProgramArguments[0]" \
        "ProgramArguments[0]=$pa0"
    fi
    if [[ "$pa1" == *huddle-watch ]]; then
      pass "the plist passes the script as ProgramArguments[1]"
    else
      fail "the plist passes the script as ProgramArguments[1]" \
        "ProgramArguments[1]=$pa1"
    fi
    # StartInterval is the PRIMARY trigger; WatchPaths only makes it sooner.
    # launchd makes no delivery guarantee for WatchPaths -- one measured
    # session became ready ten seconds after a run exited, produced no
    # wakeup, and waited 25 minutes; others waited 9.5h and ~23h. A job that
    # is never woken writes no log line, so nothing but this assertion
    # catches the plist regressing to WatchPaths alone.
    start_interval=$(plutil -extract StartInterval raw -o - "$generated" 2>/dev/null || echo "?")
    if [[ "$start_interval" =~ ^[0-9]+$ ]] && ((start_interval > 0)); then
      pass "the plist sets a positive StartInterval"
    else
      fail "the plist sets a positive StartInterval" \
        "StartInterval=$start_interval"
    fi
    # It must be a plist <integer>. jq --arg would emit <string>600</string>,
    # which launchd rejects at load -- the timer then silently does not exist
    # and the job is back on WatchPaths alone, looking installed either way.
    # `plutil -extract raw` prints both forms identically, so the type is
    # checked against the XML rather than the extracted value.
    plist_xml=$(plutil -convert xml1 -o - "$generated" 2>/dev/null || printf '')
    interval_xml=$(printf '%s\n' "$plist_xml" |
      grep -A1 '<key>StartInterval</key>' || printf '')
    if [[ "$interval_xml" == *'<integer>'* ]]; then
      pass "StartInterval is a plist integer, not a string"
    else
      fail "StartInterval is a plist integer, not a string" "$interval_xml"
    fi
    # HUDDLE_POLL_INTERVAL must reach the plist. A default-only path would
    # make the override silently inert.
    custom_plist_out=$(env PATH="$WBIN:$PATH" HUDDLE_DB="$WDB" \
      HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
      HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" \
      HUDDLE_POLL_INTERVAL=137 \
      HOME="$WORK/fakehome" "$WATCH" --install 2>&1 || true)
    custom_interval=$(plutil -extract StartInterval raw -o - "$generated" 2>/dev/null || echo "?")
    if [[ "$custom_interval" == "137" ]]; then
      pass "HUDDLE_POLL_INTERVAL is recorded in the generated plist"
    else
      fail "HUDDLE_POLL_INTERVAL is recorded in the generated plist" \
        "StartInterval=$custom_interval ($custom_plist_out)"
    fi
    # A non-numeric interval must be refused BEFORE it reaches the plist:
    # launchd rejects the malformed job at load time, which presents as a
    # watcher that is installed and never runs.
    if env PATH="$WBIN:$PATH" HUDDLE_DB="$WDB" \
      HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
      HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" \
      HUDDLE_POLL_INTERVAL="600; touch $WORK/pwned" \
      HOME="$WORK/fakehome" "$WATCH" --install >/dev/null 2>&1; then
      fail "a non-numeric HUDDLE_POLL_INTERVAL is rejected" "--install succeeded"
    elif [[ -e "$WORK/pwned" ]]; then
      fail "a non-numeric HUDDLE_POLL_INTERVAL is rejected" "injected command ran"
    else
      pass "a non-numeric HUDDLE_POLL_INTERVAL is rejected"
    fi
    # Restore the default-interval plist for any later assertion.
    env PATH="$WBIN:$PATH" HUDDLE_DB="$WDB" \
      HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
      HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" \
      HOME="$WORK/fakehome" "$WATCH" --install >/dev/null 2>&1 || true
    # RunAtLoad catches a session that became ready while the machine was off
    # or logged out -- the one gap neither WatchPaths nor StartInterval can
    # observe. It is safe only because the state file makes a load-time run a
    # no-op; the seeding test below pins that half.
    run_at_load=$(plutil -extract RunAtLoad raw -o - "$generated" 2>/dev/null || echo "?")
    if [[ "$run_at_load" == "true" || "$run_at_load" == "1" ]]; then
      pass "the plist sets RunAtLoad so a missed session is caught up at login"
    else
      fail "the plist sets RunAtLoad so a missed session is caught up at login" \
        "RunAtLoad=$run_at_load"
    fi
    # The recorded interpreter must actually satisfy the 4.2 requirement --
    # an absolute path that happens to be /bin/bash would still fail.
    if [[ "$pa0" == /*bash ]] && bash_is_modern "$pa0"; then
      pass "the interpreter recorded in the plist is bash 4.2 or newer"
    else
      fail "the interpreter recorded in the plist is bash 4.2 or newer" \
        "ProgramArguments[0]=$pa0"
    fi
  else
    fail "the plist does not point launchd at the self-rotated log" \
      "no plist generated: $probe_out"
  fi
  rm -rf "$WORK/fakehome"

  # The version guard, exercised against a REAL bash 3.2. macOS keeps one at
  # /bin/bash forever, so this is a true known-bad case rather than a
  # simulation -- and it is the interpreter launchd actually picked. Skipped
  # where no such bash exists (Linux CI), because there the guard has nothing
  # inadequate to reject.
  old_bash=""
  for candidate in /bin/bash /usr/bin/bash; do
    if [[ -x "$candidate" ]] && ! bash_is_modern "$candidate"; then
      old_bash="$candidate"
      break
    fi
  done
  if [[ -n "$old_bash" ]]; then
    # Probed via --once, and with a state file that is already seeded.
    # --status never calls log(), and a FIRST --once run returns down the
    # seeding path before logging -- so both would pass even against the
    # pre-fix script. Only a seeded run reaches log(), which is where the
    # 4.2-only printf lives and where launchd actually died.
    watch_reset
    printf '# huddle-watch state v1\n' >"$WSTATE"
    guard_rc=0
    guard_out=$(env HUDDLE_DB="$WDB" HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
      HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" \
      "$old_bash" "$WATCH" --once 2>&1) || guard_rc=$?
    if ((guard_rc != 0)); then
      pass "an inadequate bash is rejected with a non-zero status"
    else
      fail "an inadequate bash is rejected with a non-zero status" \
        "exit 0 under $old_bash"
    fi
    if [[ "$guard_out" == *"requires bash 4.2 or newer"* ]]; then
      pass "the guard names the version requirement"
    else
      fail "the guard names the version requirement" "$guard_out"
    fi
    # The pre-fix symptom: printf's %(...)T is unsupported, so `ts` is never
    # assigned and `set -u` aborts with `ts: unbound variable`. The guard must
    # pre-empt that entirely, so neither string may reach the user.
    if [[ "$guard_out" != *"unbound variable"* && "$guard_out" != *"invalid format character"* ]]; then
      pass "the guard pre-empts the bash 3.2 printf failure"
    else
      fail "the guard pre-empts the bash 3.2 printf failure" "$guard_out"
    fi
    watch_reset
  else
    skip "the version guard rejects an inadequate bash (no bash <4.2 available)"
  fi
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
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'cccc3333', 'mergedMultitrack', 'saved.m4a'); UPDATE session SET transcriptionDidSucceed = 1 WHERE id = x'cccc3333';"
# A stub whose output alone exceeds LOG_MAX_BYTES.
cat >"$WBIN/huddle-transcribe-big" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
head -c 1500000 /dev/zero | tr '\0' 'y'
echo "Transcript written: /tmp/out/big.md"
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
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'bbbb2222', 'mergedMultitrack', 'saved.m4a');"
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
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'bbbb2222', 'mergedMultitrack', 'saved.m4a');"
notify_reset
watch --once >/dev/null 2>&1 || true
if [[ -f "$NOTIFYLOG" ]]; then
  pass "a successful run raises an alert through the override"
else
  fail "a successful run raises an alert through the override" \
    "no alert recorded at $NOTIFYLOG"
fi
# A dialog that stays until dismissed, not a banner: banners were missed.
if grep -qxF 'set r to display alert "Meeting transcript ready" message "bbbb2222.md" buttons {"Open Transcript", "OK"} default button "OK"' "$NOTIFYLOG" 2>/dev/null; then
  pass "the success alert names the transcript and offers 'Open Transcript'"
else
  diag=$(dump "$NOTIFYLOG")
  fail "the success alert names the transcript and offers 'Open Transcript'" "$diag"
fi
if grep -qxF 'if button returned of r is "Open Transcript" then do shell script "open -- " & quoted form of "/tmp/out/bbbb2222.md"' "$NOTIFYLOG" 2>/dev/null; then
  pass "'Open Transcript' opens the written transcript path"
else
  diag=$(dump "$NOTIFYLOG")
  fail "'Open Transcript' opens the written transcript path" "$diag"
fi
if grep -qF 'display notification' "$NOTIFYLOG" 2>/dev/null; then
  diag=$(dump "$NOTIFYLOG")
  fail "the success alert is a dialog, not a transient banner" "$diag"
else
  pass "the success alert is a dialog, not a transient banner"
fi
if command -v osacompile >/dev/null 2>&1; then
  ok_script=()
  while IFS= read -r line; do ok_script+=(-e "$line"); done <"$NOTIFYLOG"
  if osacompile -o "$WORK/alert-ok.scpt" "${ok_script[@]}" >/dev/null 2>&1; then
    pass "the success alert's AppleScript compiles"
  else
    diag=$(dump "$NOTIFYLOG")
    fail "the success alert's AppleScript compiles" "$diag"
  fi
else
  skip "the success alert's AppleScript compiles (osacompile unavailable)"
fi

# A real transcript path has spaces; quotes and backslashes must survive too.
build_watch_db
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'bbbb2222', 'mergedMultitrack', 'saved.m4a');"
notify_reset
odd_path='/tmp/out dir/Team "sync" back\slash.md'
STUB_OUT_PATH="$odd_path" watch --once >/dev/null 2>&1 || true
open_line=$(grep -F '"open -- "' "$NOTIFYLOG" 2>/dev/null || true)
if [[ "$open_line" == 'if button returned of r is "Open Transcript" then do shell script "open -- " & quoted form of "/tmp/out dir/Team \"sync\" back\\slash.md"' ]]; then
  pass "an awkward transcript path is escaped in the open line"
else
  diag=$(dump "$NOTIFYLOG")
  fail "an awkward transcript path is escaped in the open line" "$diag"
fi
# Round-trip through real AppleScript, with printf in place of open.
if [[ ! -x /usr/bin/osascript ]]; then
  skip "'Open Transcript' hands open the exact transcript path (osascript unavailable)"
elif [[ -z "$open_line" ]]; then
  fail "'Open Transcript' hands open the exact transcript path" "no open line recorded"
else
  probe_line="${open_line/'"open -- "'/'"printf %s "'}"
  round=$(/usr/bin/osascript -e 'set r to {button returned:"Open Transcript"}' -e "$probe_line" 2>&1 || true)
  if [[ "$round" == "$odd_path" ]]; then
    pass "'Open Transcript' hands open the exact transcript path"
  else
    fail "'Open Transcript' hands open the exact transcript path" "got: $round"
  fi
fi

# HUDDLE_NO_NOTIFY suppresses entirely, checked before the command -v probe.
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'cccc3333', 'mergedMultitrack', 'saved.m4a'); UPDATE session SET transcriptionDidSucceed = 1 WHERE id = x'cccc3333';"
notify_reset
env HUDDLE_NO_NOTIFY=1 HUDDLE_DB="$WDB" \
  HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
  HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" CALLS="$CALLS" \
  "$WATCH" --once >/dev/null 2>&1 || true
notify_drain
absent "HUDDLE_NO_NOTIFY suppresses alerts" "$NOTIFYLOG"
if compgen -G "$WSTATE.alert-*" >/dev/null; then
  stray=$(ls "$WSTATE".alert-* 2>&1 || true)
  fail "HUDDLE_NO_NOTIFY writes no alert list or pid file" "$stray"
else
  pass "HUDDLE_NO_NOTIFY writes no alert list or pid file"
fi

# The give-up alert must be distinct from the success one and must
# name the log, since that is the only record of what went wrong.
build_watch_db
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'bbbb2222', 'mergedMultitrack', 'saved.m4a');"
notify_reset
for _attempt in 1 2 3; do
  watch_failing --once >/dev/null 2>&1 || true
done
if grep -qxF "set r to display alert \"Transcription FAILED\" message \"Gave up on bbbb2222 (No Audio Yet) after 3 tries. Log: $WLOG\" buttons {\"Open Log\", \"OK\"} default button \"OK\" as critical" "$NOTIFYLOG" 2>/dev/null; then
  pass "the give-up alert is critical and names the session and the log"
else
  diag=$(dump "$NOTIFYLOG")
  fail "the give-up alert is critical and names the session and the log" "$diag"
fi
if grep -qxF "if button returned of r is \"Open Log\" then do shell script \"open -- \" & quoted form of \"$WLOG\"" "$NOTIFYLOG" 2>/dev/null; then
  pass "'Open Log' opens the log file"
else
  diag=$(dump "$NOTIFYLOG")
  fail "'Open Log' opens the log file" "$diag"
fi
if grep -qF "Meeting transcript ready" "$NOTIFYLOG" 2>/dev/null; then
  diag=$(dump "$NOTIFYLOG")
  fail "the give-up alert is distinct from the success one" "$diag"
else
  pass "the give-up alert is distinct from the success one"
fi
alert_n=$(grep -c 'display alert' "$NOTIFYLOG" 2>/dev/null || true)
if [[ "$alert_n" == "1" ]]; then
  pass "only the give-up raises an alert, not each retryable failure"
else
  diag=$(dump "$NOTIFYLOG")
  fail "only the give-up raises an alert, not each retryable failure" "$diag"
fi
if command -v osacompile >/dev/null 2>&1; then
  fail_script=()
  while IFS= read -r line; do fail_script+=(-e "$line"); done <"$NOTIFYLOG"
  if osacompile -o "$WORK/alert-fail.scpt" "${fail_script[@]}" >/dev/null 2>&1; then
    pass "the give-up alert's AppleScript compiles"
  else
    diag=$(dump "$NOTIFYLOG")
    fail "the give-up alert's AppleScript compiles" "$diag"
  fi
else
  skip "the give-up alert's AppleScript compiles (osacompile unavailable)"
fi

# The alert is detached: --once must return while it is still on screen.
cat >"$WBIN/osascript-hold" <<'STUB'
#!/usr/bin/env bash
# Like osascript-stub, but stays up like a dialog and records its pid/pgid.
printf '%s %s\n' "$$" "$(ps -o pgid= -p "$$" | tr -d ' ')" >>"$HOLD_PGIDS"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e)
      printf '%s\n' "$2" >>"$NOTIFYLOG"
      shift 2
      ;;
    *) shift ;;
  esac
done
tries=0
while [[ ! -e "$HOLD_RELEASE" ]] && ((tries < 150)); do
  sleep 0.1
  tries=$((tries + 1))
done
STUB
chmod +x "$WBIN/osascript-hold"
HOLD_RELEASE="$WORK/hold-release"
HOLD_PGIDS="$WORK/hold-pgids"
rm -f "$HOLD_RELEASE" "$HOLD_PGIDS"
build_watch_db
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'bbbb2222', 'mergedMultitrack', 'saved.m4a');"
notify_reset
env HUDDLE_NOTIFY_BIN="$WBIN/osascript-hold" HOLD_RELEASE="$HOLD_RELEASE" \
  HOLD_PGIDS="$HOLD_PGIDS" HUDDLE_DB="$WDB" HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
  HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" CALLS="$CALLS" \
  "$WATCH" --once >/dev/null 2>&1 &
hold_pid=$!
tries=0
while kill -0 "$hold_pid" 2>/dev/null && ((tries < 50)); do
  sleep 0.1
  tries=$((tries + 1))
done
if kill -0 "$hold_pid" 2>/dev/null; then
  fail "--once returns while the alert is still open" "still running after 5 s"
else
  pass "--once returns while the alert is still open"
fi
tries=0
while ! grep -qF 'Meeting transcript ready' "$NOTIFYLOG" 2>/dev/null && ((tries < 50)); do
  sleep 0.1
  tries=$((tries + 1))
done
if ! command -v pgrep >/dev/null 2>&1; then
  skip "the alert outlives the run that raised it (pgrep unavailable)"
elif grep -qF 'Meeting transcript ready' "$NOTIFYLOG" 2>/dev/null &&
  pgrep -f -- "$WBIN/osascript-hold" >/dev/null 2>&1; then
  pass "the alert outlives the run that raised it"
else
  diag=$(dump "$NOTIFYLOG")
  fail "the alert outlives the run that raised it" "$diag"
fi
# set -m in alert(): the alert leads its own process group, so launchd's
# kill of the job's group at exit does not reach it.
hold_rec=$(head -n1 "$HOLD_PGIDS" 2>/dev/null || true)
hold_alert_pid="${hold_rec%% *}"
hold_alert_pgid="${hold_rec##* }"
suite_pgid=$(ps -o pgid= -p "$$" | tr -d ' ')
if [[ -n "$hold_alert_pid" && "$hold_alert_pgid" == "$hold_alert_pid" &&
  "$hold_alert_pgid" != "$suite_pgid" ]]; then
  pass "the alert runs in its own process group, apart from huddle-watch's"
else
  fail "the alert runs in its own process group, apart from huddle-watch's" \
    "alert pid/pgid=$hold_rec, huddle-watch pgid=$suite_pgid"
fi
recorded_pid=$(cat "$WSTATE.alert-ready.pid" 2>/dev/null || true)
if [[ -n "$recorded_pid" && "$recorded_pid" == "$hold_alert_pid" ]]; then
  pass "the alert's pid is recorded beside the state file"
else
  fail "the alert's pid is recorded beside the state file" \
    "pid file=$recorded_pid, alert pid=$hold_alert_pid"
fi

# watch_repend SID: forget SID's done record so the next run transcribes it.
watch_repend() {
  grep -v "^$1 " "$WSTATE" >"$WSTATE.tmp" || true
  mv "$WSTATE.tmp" "$WSTATE"
}

# A second ready alert while the first is up replaces it with one naming both.
watch_repend aaaa1111
env HUDDLE_NOTIFY_BIN="$WBIN/osascript-hold" HOLD_RELEASE="$HOLD_RELEASE" \
  HOLD_PGIDS="$HOLD_PGIDS" HUDDLE_DB="$WDB" \
  HUDDLE_TRANSCRIBE_BIN="$WBIN/huddle-transcribe" \
  HUDDLE_STATE_FILE="$WSTATE" HUDDLE_LOG_FILE="$WLOG" CALLS="$CALLS" \
  "$WATCH" --once >/dev/null 2>&1 || true
merged_show='set r to display alert "2 meeting transcripts ready" message "bbbb2222.md\naaaa1111.md" buttons {"Open Transcripts", "OK"} default button "OK"'
tries=0
while ! grep -qxF "$merged_show" "$NOTIFYLOG" 2>/dev/null && ((tries < 50)); do
  sleep 0.1
  tries=$((tries + 1))
done
if grep -qxF "$merged_show" "$NOTIFYLOG" 2>/dev/null; then
  pass "a second ready alert merges with the one on screen"
else
  diag=$(dump "$NOTIFYLOG")
  fail "a second ready alert merges with the one on screen" "$diag"
fi
if grep -qxF 'if button returned of r is "Open Transcripts" then do shell script "open -- " & quoted form of "/tmp/out/bbbb2222.md" & " " & quoted form of "/tmp/out/aaaa1111.md"' "$NOTIFYLOG" 2>/dev/null; then
  pass "'Open Transcripts' opens every listed transcript"
else
  diag=$(dump "$NOTIFYLOG")
  fail "'Open Transcripts' opens every listed transcript" "$diag"
fi
tries=0
while [[ -n "$hold_alert_pid" ]] && kill -0 "$hold_alert_pid" 2>/dev/null && ((tries < 50)); do
  sleep 0.1
  tries=$((tries + 1))
done
if [[ -n "$hold_alert_pid" ]] && ! kill -0 "$hold_alert_pid" 2>/dev/null; then
  pass "the merged alert closes the one it replaces"
else
  fail "the merged alert closes the one it replaces" "pid $hold_alert_pid still running"
fi
merged_pid=$(sed -n 2p "$HOLD_PGIDS" 2>/dev/null || true)
merged_pid="${merged_pid%% *}"
recorded_pid=$(cat "$WSTATE.alert-ready.pid" 2>/dev/null || true)
if [[ -n "$merged_pid" ]] && kill -0 "$merged_pid" 2>/dev/null &&
  [[ "$recorded_pid" == "$merged_pid" ]]; then
  pass "the merged alert stays up and its pid replaces the old one"
else
  fail "the merged alert stays up and its pid replaces the old one" \
    "merged pid=$merged_pid, pid file=$recorded_pid"
fi
if command -v osacompile >/dev/null 2>&1; then
  merged_script=()
  while IFS= read -r line; do merged_script+=(-e "$line"); done <"$NOTIFYLOG"
  if osacompile -o "$WORK/alert-merged.scpt" "${merged_script[@]}" >/dev/null 2>&1; then
    pass "the merged alert's AppleScript compiles"
  else
    diag=$(dump "$NOTIFYLOG")
    fail "the merged alert's AppleScript compiles" "$diag"
  fi
else
  skip "the merged alert's AppleScript compiles (osacompile unavailable)"
fi
touch "$HOLD_RELEASE"
wait "$hold_pid" 2>/dev/null || true
notify_drain

# Dismissal runs the alert's rm line. Run it via real AppleScript (no
# dialog, just do shell script): it must clear the merge state.
rm_line=$(grep -F '"rm -f -- "' "$NOTIFYLOG" 2>/dev/null | tail -n1 || true)
if [[ ! -x /usr/bin/osascript ]]; then
  skip "dismissing an alert clears its list and pid file (osascript unavailable)"
elif [[ -z "$rm_line" ]]; then
  fail "dismissing an alert clears its list and pid file" "no rm line recorded"
elif [[ ! -f "$WSTATE.alert-ready.list" ]]; then
  fail "dismissing an alert clears its list and pid file" "no list file to clear"
else
  /usr/bin/osascript -e "$rm_line" >/dev/null 2>&1 || true
  if [[ -e "$WSTATE.alert-ready.list" || -e "$WSTATE.alert-ready.pid" ]]; then
    fail "dismissing an alert clears its list and pid file" "$rm_line"
  else
    pass "dismissing an alert clears its list and pid file"
  fi
fi

# A pid file naming a live process that is not our alert (pid reuse):
# never killed or merged with; the next alert starts a fresh list.
sleep 30 &
decoy_pid=$!
printf 'zzzz9999.md%s/tmp/out/zzzz9999.md\n' $'\x1f' >"$WSTATE.alert-ready.list"
printf '%s\n' "$decoy_pid" >"$WSTATE.alert-ready.pid"
decoy_list=$(cat "$WSTATE.alert-ready.list")
rm -f "$NOTIFYLOG"
watch_repend aaaa1111
watch --once >/dev/null 2>&1 || true
if grep -qxF 'set r to display alert "Meeting transcript ready" message "aaaa1111.md" buttons {"Open Transcript", "OK"} default button "OK"' "$NOTIFYLOG" 2>/dev/null; then
  pass "a pid that is not our alert starts a fresh list"
else
  diag=$(dump "$NOTIFYLOG")
  fail "a pid that is not our alert starts a fresh list" "list was: $decoy_list; $diag"
fi
if kill -0 "$decoy_pid" 2>/dev/null; then
  pass "a pid that is not our alert is not killed"
else
  fail "a pid that is not our alert is not killed" "decoy $decoy_pid is gone"
fi
kill "$decoy_pid" 2>/dev/null || true
wait "$decoy_pid" 2>/dev/null || true
notify_reset

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
sqlite3 "$WDB" "INSERT INTO recordedmeeting (id, duration, title) VALUES (x'8f', 900.0, 'rmHostileTitle');"
sqlite3 "$WDB" "INSERT INTO session VALUES (x'beef7777', '2026-08-17 10:00:00.000', 'x\" & (do shell script \"touch $WORK/APPLEPWNED\") & \"y back\\slash', NULL, x'8f', NULL, 1, 1, 0, 0, NULL, NULL, 0);"
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'beef7777', 'mergedMultitrack', 'saved.m4a');"
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
notify_drain
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
if grep -qE '^set r to display alert "([^"\\]|\\.)*" message "([^"\\]|\\.)*" buttons \{"OK"\} default button "OK"$' "$NOTIFYLOG" 2>/dev/null; then
  pass "the AppleScript body remains a single well-formed string literal"
else
  diag=$(dump "$NOTIFYLOG")
  fail "the AppleScript body remains a single well-formed string literal" "$diag"
fi
if grep -qF '"open -- "' "$NOTIFYLOG" 2>/dev/null; then
  diag=$(dump "$NOTIFYLOG")
  fail "with no transcript path, the alert offers only OK" "$diag"
else
  pass "with no transcript path, the alert offers only OK"
fi

# --- split meetings: each piece as it lands, then re-stitched -----------

echo "huddle-watch: split meetings"
# Pieces end 6 s and 4 s apart; the last ends 2026-10-15 15:21:35.394 UTC.
add_split_meeting() {
  sqlite3 "$WDB" <<'SQL'
INSERT INTO recordedmeeting VALUES (x'c1', 83.073625, NULL, '2026-10-15 15:01:23.955', 'Slack', 'com.tinyspeck.slackmacgap');
INSERT INTO session VALUES (x'c1c10001', '2026-10-15 15:02:54.630', 'Split Watch', NULL, x'c1', NULL, 1, 0, 0, 0, NULL, NULL, 0);
INSERT INTO mediafile VALUES (x'c1c10001', 'mergedMultitrack', 'w1.m4a');
INSERT INTO recordedmeeting VALUES (x'c2', 42.2019375, NULL, '2026-10-15 15:02:53.351', 'Slack', 'com.tinyspeck.slackmacgap');
INSERT INTO session VALUES (x'c1c10002', '2026-10-15 15:03:40.742', 'Split Watch 2', NULL, x'c2', NULL, 1, 0, 0, 0, NULL, NULL, 0);
INSERT INTO mediafile VALUES (x'c1c10002', 'mergedMultitrack', 'w2.m4a');
INSERT INTO recordedmeeting VALUES (x'c3', 1075.9269375, NULL, '2026-10-15 15:03:39.467', 'Slack', 'com.tinyspeck.slackmacgap');
INSERT INTO session VALUES (x'c1c10003', '2026-10-15 15:22:56.495', 'Split Watch 3', NULL, x'c3', NULL, 1, 0, 0, 0, NULL, NULL, 0);
SQL
}
calls_for() {
  grep -c "$1" "$CALLS" 2>/dev/null || true
}
split_fresh() {
  build_watch_db
  watch_reset
  watch --once >/dev/null 2>&1 || true
  add_split_meeting
  sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'c1c10003', 'mergedMultitrack', 'w3.m4a');"
}

build_watch_db
watch_reset
watch --once >/dev/null 2>&1 || true
add_split_meeting

# The newest piece has no saved audio yet. The ready ones go now, and the
# child is told which one is not ready.
split_out=$(watch --dry-run 2>&1 || true)
if grep -qF "would transcribe  c1c10001" <<<"$split_out" &&
  grep -qF "(stitched from 2 of 3 recordings, 2 new; 1 not ready yet)" <<<"$split_out"; then
  pass "a split meeting does not wait for a piece that is not ready"
else
  fail "a split meeting does not wait for a piece that is not ready" "$split_out"
fi
watch --once >/dev/null 2>&1 || true
lead_calls=$(calls_for '^c1c10001 --yes --restitch --pending c1c10003$')
if [[ "$lead_calls" == "1" ]] &&
  grep -q '^c1c10001 done$' "$WSTATE" && grep -q '^c1c10002 done$' "$WSTATE" && ! grep -q '^c1c10003 ' "$WSTATE"; then
  pass "the ready pieces are transcribed with --pending for the one that is not"
else
  diag_calls=$(dump "$CALLS")
  diag_state=$(dump "$WSTATE")
  diag="calls=$diag_calls state=$diag_state"
  fail "the ready pieces are transcribed with --pending for the one that is not" "$diag"
fi
if grep -qF "STITCH c1c10001: c1c10001 c1c10002 (new: c1c10001 c1c10002; not ready yet: c1c10003)" "$WLOG" 2>/dev/null; then
  pass "the piece that is not ready is logged with the stitch"
else
  diag=$(dump "$WLOG")
  fail "the piece that is not ready is logged with the stitch" "$diag"
fi
# A piece that stays not ready neither re-runs the meeting nor fills the log.
watch --once >/dev/null 2>&1 || true
watch --once >/dev/null 2>&1 || true
stitch_logs=$(grep -c 'STITCH c1c10001' "$WLOG" 2>/dev/null || true)
if [[ "$(grep -c . "$CALLS" 2>/dev/null || true)" == "1" && "$stitch_logs" == "1" ]]; then
  pass "a piece that stays not ready causes no re-run and no repeated log line"
else
  diag=$(dump "$CALLS")
  fail "a piece that stays not ready causes no re-run and no repeated log line" "calls=$diag stitch_logs=$stitch_logs"
fi

# When it becomes ready, the meeting is re-stitched once, without --pending.
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'c1c10003', 'mergedMultitrack', 'w3.m4a');"
split_out=$(watch --dry-run 2>&1 || true)
split_lines=$(grep -c c1c1000 <<<"$split_out" || true)
if grep -qF "would transcribe  c1c10001" <<<"$split_out" &&
  grep -qF "(stitched from 3 recordings, 1 new)" <<<"$split_out" && [[ "$split_lines" == "1" ]]; then
  pass "--dry-run shows a complete split meeting once"
else
  fail "--dry-run shows a complete split meeting once" "$split_out"
fi
split_out=$(watch --list 2>&1 || true)
if grep -qE '^c1c10003 .* yes ' <<<"$split_out" && grep -qE '^c1c10001 .* seen ' <<<"$split_out"; then
  pass "--list shows the new piece as ready and the done ones as seen"
else
  fail "--list shows the new piece as ready and the done ones as seen" "$split_out"
fi
watch --once >/dev/null 2>&1 || true
split_calls=$(grep -c . "$CALLS" 2>/dev/null || true)
lead_calls=$(calls_for '^c1c10001 --yes --restitch$')
if [[ "$split_calls" == "2" && "$lead_calls" == "1" ]]; then
  pass "a piece that becomes ready re-stitches the meeting via its first piece, with --restitch"
else
  diag=$(dump "$CALLS")
  fail "a piece that becomes ready re-stitches the meeting via its first piece, with --restitch" "$diag"
fi
if grep -q '^c1c10001 done$' "$WSTATE" && grep -q '^c1c10002 done$' "$WSTATE" &&
  grep -q '^c1c10003 done$' "$WSTATE"; then
  pass "every piece of the meeting is recorded as done"
else
  diag=$(dump "$WSTATE")
  fail "every piece of the meeting is recorded as done" "$diag"
fi
if grep -qF "STITCH c1c10001: c1c10001 c1c10002 c1c10003 (new: c1c10003)" "$WLOG" 2>/dev/null; then
  pass "the stitch decision is logged with every piece"
else
  diag=$(dump "$WLOG")
  fail "the stitch decision is logged with every piece" "$diag"
fi
watch --once >/dev/null 2>&1 || true
split_calls=$(grep -c . "$CALLS" 2>/dev/null || true)
if [[ "$split_calls" == "2" ]]; then
  pass "a transcribed split meeting is not queued again"
else
  diag=$(dump "$CALLS")
  fail "a transcribed split meeting is not queued again" "$diag"
fi
split_out=$(watch --list 2>&1 || true)
if grep -qE '^c1c10003 .* seen ' <<<"$split_out"; then
  pass "--list shows a meeting with every piece done as seen"
else
  fail "--list shows a meeting with every piece done as seen" "$split_out"
fi

# A child that still finds a piece not ready leaves it unrecorded.
watch_reset
printf '# huddle-watch state v1\naaaa1111 done\nbbbb8888 done\nc1c10001 done\nc1c10002 done\n' >"$WSTATE"
STUB_PART_PENDING=c1c10003 watch --once >/dev/null 2>&1 || true
lead_calls=$(calls_for '^c1c10001 ')
if [[ "$lead_calls" == "1" ]] && ! grep -q '^c1c10003 ' "$WSTATE"; then
  pass "a piece the child reports not ready is not recorded as done"
else
  diag=$(dump "$WSTATE")
  fail "a piece the child reports not ready is not recorded as done" "$diag"
fi
printf '# huddle-watch state v1\naaaa1111 done\nbbbb8888 done\nc1c10001 done\nc1c10002 done\nc1c10003 done\n' >"$WSTATE"

# The bug this fixes: a piece saved after its meeting was handled was skipped
# for good. Now it makes the meeting pending again.
sqlite3 "$WDB" <<'SQL'
INSERT INTO recordedmeeting VALUES (x'c4', 30.0, NULL, '2026-10-15 15:21:40.000', 'Slack', 'com.tinyspeck.slackmacgap');
INSERT INTO session VALUES (x'c1c10004', '2026-10-15 15:23:30.000', 'Split Watch 4', NULL, x'c4', NULL, 1, 0, 0, 0, NULL, NULL, 0);
INSERT INTO mediafile VALUES (x'c1c10004', 'mergedMultitrack', 'w4.m4a');
SQL
split_out=$(watch --dry-run 2>&1 || true)
if grep -qF "would transcribe  c1c10001" <<<"$split_out" && grep -qF "(stitched from 4 recordings, 1 new)" <<<"$split_out"; then
  pass "a piece saved after its meeting was transcribed makes the meeting pending"
else
  fail "a piece saved after its meeting was transcribed makes the meeting pending" "$split_out"
fi
notify_reset
rm -f "$CALLS"
STUB_REPLACED=1 watch --once >/dev/null 2>&1 || true
lead_calls=$(calls_for '^c1c10001 --yes --restitch$')
if [[ "$lead_calls" == "1" ]] && grep -q '^c1c10004 done$' "$WSTATE"; then
  pass "the late piece re-stitches the meeting and is recorded as done"
else
  diag_calls=$(dump "$CALLS")
  diag_state=$(dump "$WSTATE")
  diag="calls=$diag_calls state=$diag_state"
  fail "the late piece re-stitches the meeting and is recorded as done" "$diag"
fi
if grep -qF "(updated with a later recording)" "$NOTIFYLOG" 2>/dev/null; then
  pass "a re-stitched transcript raises a new ready alert saying it was updated"
else
  diag=$(dump "$NOTIFYLOG")
  fail "a re-stitched transcript raises a new ready alert saying it was updated" "$diag"
fi

# A piece already done before (e.g. transcribed alone) does not hold back
# the others: the child is still run, and the sidecars decide.
watch_reset
printf '# huddle-watch state v1\naaaa1111 done\nbbbb8888 done\nc1c10003 done\n' >"$WSTATE"
watch --once >/dev/null 2>&1 || true
lead_calls=$(calls_for '^c1c10001 ')
if [[ "$lead_calls" == "1" ]] && grep -q '^c1c10002 done$' "$WSTATE"; then
  pass "a meeting with only some pieces done is still processed"
else
  diag_calls=$(dump "$CALLS")
  diag_state=$(dump "$WSTATE")
  diag="calls=$diag_calls state=$diag_state"
  fail "a meeting with only some pieces done is still processed" "$diag"
fi
watch_reset
printf '# huddle-watch state v1\naaaa1111 done\nbbbb8888 done\nc1c10001 done\nc1c10002 3\nc1c10003 done\nc1c10004 done\n' >"$WSTATE"
watch --once >/dev/null 2>&1 || true
absent "a meeting whose pieces are all done or given up is not run" "$CALLS"

# A failure costs each pending piece one attempt; a piece the child reports
# failed is retried alone, the rest recorded done.
split_fresh
watch_failing --once >/dev/null 2>&1 || true
split_calls=$(grep -c . "$CALLS" 2>/dev/null || true)
if [[ "$split_calls" == "1" ]] && grep -q '^c1c10001 1$' "$WSTATE" && grep -q '^c1c10002 1$' "$WSTATE" &&
  grep -q '^c1c10003 1$' "$WSTATE"; then
  pass "a failed split meeting costs one attempt on each pending piece"
else
  diag="calls=$split_calls state=$(dump "$WSTATE")"
  fail "a failed split meeting costs one attempt on each pending piece" "$diag"
fi
split_fresh
notify_reset
STUB_PART_FAILED=c1c10002 watch --once >/dev/null 2>&1 || true
if grep -q '^c1c10001 done$' "$WSTATE" && grep -q '^c1c10002 1$' "$WSTATE" &&
  grep -q '^c1c10003 done$' "$WSTATE" && grep -qF "Meeting transcript ready" "$NOTIFYLOG" 2>/dev/null; then
  pass "a part the child could not transcribe is retried alone; the meeting is still announced"
else
  diag="state=$(dump "$WSTATE")"
  fail "a part the child could not transcribe is retried alone; the meeting is still announced" "$diag"
fi
for _ in 2 3; do
  STUB_PART_FAILED=c1c10002 watch --once >/dev/null 2>&1 || true
done
if grep -q '^c1c10002 3$' "$WSTATE" && grep -q 'GAVE UP on c1c10002' "$WLOG" &&
  grep -qF "Transcription FAILED" "$NOTIFYLOG" 2>/dev/null; then
  pass "a piece that keeps failing is given up on by itself"
else
  diag="state=$(dump "$WSTATE")"
  fail "a piece that keeps failing is given up on by itself" "$diag"
fi
split_calls=$(grep -c . "$CALLS" 2>/dev/null || true)
watch --once >/dev/null 2>&1 || true
calls_after=$(grep -c . "$CALLS" || true)
if [[ "$calls_after" == "$split_calls" ]]; then
  pass "a meeting whose last pending piece was given up on is not run again"
else
  diag=$(dump "$CALLS")
  fail "a meeting whose last pending piece was given up on is not run again" "$diag"
fi

# A first run seeds every ready piece; there is no gap window any more.
build_watch_db
watch_reset
add_split_meeting
sqlite3 "$WDB" "INSERT INTO mediafile VALUES (x'c1c10003', 'mergedMultitrack', 'w3.m4a');"
watch --once >/dev/null 2>&1 || true
if grep -q '^c1c10001 done$' "$WSTATE" && grep -q '^c1c10003 done$' "$WSTATE"; then
  pass "seeding records every piece of a ready meeting"
else
  diag=$(dump "$WSTATE")
  fail "seeding records every piece of a ready meeting" "$diag"
fi
absent "seeding transcribes nothing" "$CALLS"

# Nothing ready at all: the empty pending list must not trip set -u.
build_watch_db
watch_reset
watch --once >/dev/null 2>&1 || true
sqlite3 "$WDB" "UPDATE session SET transcriptionDidSucceed = 0;"
expect_watch_rc "a run with nothing ready exits 0" 0 --once
expect_watch_rc "a dry run with nothing ready exits 0" 0 --dry-run

for bad in "" "abc" "1;--"; do
  rc=0
  HUDDLE_STITCH_GAP_SECONDS="$bad" watch --dry-run >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 1 ]]; then pass "watch HUDDLE_STITCH_GAP_SECONDS='$bad' rejected"; else fail "watch HUDDLE_STITCH_GAP_SECONDS='$bad' rejected" "exit $rc"; fi
done

# bash 4.2/4.3 call an empty "${a[@]}" unbound under set -u. Statically:
# every bare expansion must be of an array listed here as never empty.
nonempty=" DEL_PATHS GROUP_IDS PART_IDS id_matches idx_rows member_list missing_ids ok_files ok_ids pending"
nonempty+=" args done_ids member_ids new_ids texts opens "
bare=$(grep -ohE '[^+]"\$\{!?[A-Za-z_]+\[[@*]\]\}"' "$SCRIPT" "$WATCH" | sed -E 's/.*\{!?([A-Za-z_]+)\[.*/\1/' | sort -u)
unlisted=""
for name in $bare; do
  [[ "$nonempty" == *" $name "* ]] || unlisted+="$name "
done
if [[ -z "$unlisted" && -n "$bare" ]]; then
  pass "every bare array expansion is of an array known to be non-empty"
else
  fail "every bare array expansion is of an array known to be non-empty" "unlisted: $unlisted"
fi
for guarded in metas order PENDING; do
  if grep -qE "[^+]\"\\\$\{$guarded\[@\]\}\"" "$SCRIPT" "$WATCH"; then
    fail "the possibly-empty array '$guarded' is expanded with the guard"
  else
    pass "the possibly-empty array '$guarded' is expanded with the guard"
  fi
done

# --- the watcher drives the real huddle-transcribe -------------------------

# Real days replayed through huddle-watch and huddle-transcribe (stub mw).
# Rows appear after a recording ends: pieces are added one at a time.
echo "huddle-watch: split meetings, end to end"
RP="$WORK/out-replay"
RP_PIECES="$WORK/pieces-replay"
HTW=$(build "$BIN/mw" "$WORK/htw.sh" "$WDB" "$RP")
watch_real() {
  local rc=0
  env -u FAIL_TRANSCRIBE \
    HUDDLE_DB="$WDB" \
    HUDDLE_TRANSCRIBE_BIN="$HTW" \
    HUDDLE_STATE_FILE="$WSTATE" \
    HUDDLE_LOG_FILE="$WLOG" \
    HUDDLE_PIECES_DIR="$RP_PIECES" \
    MW_CALLS="$WORK/mw-calls" \
    MW_FAIL_MATCH="${MW_FAIL_MATCH:-}" \
    "$WATCH" "$@" || rc=$?
  notify_drain
  return $rc
}
replay_fresh() {
  build_watch_db
  watch_reset
  rm -rf "$RP" "$RP_PIECES" "$WORK/mw-calls"
  watch_real --once >/dev/null 2>&1 || true
}
# add_piece SID RM START DURATION CREATED FILE TITLE: one saved Slack recording.
add_piece() {
  sqlite3 "$WDB" "
INSERT INTO recordedmeeting VALUES (x'$2', $4, NULL, '$3', 'Slack', 'com.tinyspeck.slackmacgap');
INSERT INTO session VALUES (x'$1', '$5', $7, NULL, x'$2', NULL, 1, 0, 0, 0, NULL, NULL, 0);
INSERT INTO mediafile VALUES (x'$1', 'mergedMultitrack', '$6');"
  touch "$MEDIA/$6"
}
# 2026-10-13: 1749 s, 841 s and 5071 s pieces, 11.3 s and 9.6 s apart; each
# row landed 1.3 to 7.5 minutes after its recording ended.
oct13_piece() {
  case "$1" in
    1) add_piece e1e10001 e1 '2026-10-13 20:04:01.020' 1749.1883333 '2026-10-13 20:35:48.870' e1.m4a "'Design Review'" ;;
    2) add_piece e1e10002 e2 '2026-10-13 20:33:21.473' 840.6741042 '2026-10-13 20:48:38.189' e2.m4a NULL ;;
    *) add_piece e1e10003 e3 '2026-10-13 20:47:31.760' 5071.4638542 '2026-10-13 22:19:34.262' e3.m4a NULL ;;
  esac
}
RP_DOC="$RP/2026-10-13_design-review_e1e10001.md"
RP_META="$RP/2026-10-13_design-review_e1e10001.meta.json"
# Snapshot after each run, so no check below masks a command's status.
rp_snap() {
  N_MW=0
  [[ ! -f "$WORK/mw-calls" ]] || N_MW=$(grep -c . "$WORK/mw-calls" || true)
  N_DOCS=$(find "$RP" -name '*.md' ! -name '_index.md' 2>/dev/null | wc -l | tr -d ' ' || true)
  D_LOG=$(dump "$WLOG")
  D_STATE=$(dump "$WSTATE")
  D_DOC=$(dump "$RP_DOC")
  D_META=$(dump "$RP_META")
}

replay_fresh
oct13_piece 1
notify_reset
watch_real --once >/dev/null 2>&1 || true
rp_snap
if [[ -f "$RP_DOC" ]] && grep -qxF "hello from e1.m4a" "$RP_DOC" && ! grep -q '^## Part' "$RP_DOC" &&
  [[ "$N_MW" == "1" ]] && grep -q '^e1e10001 done$' "$WSTATE"; then
  pass "Oct 13: the first piece is transcribed alone as soon as it is saved"
else
  fail "Oct 13: the first piece is transcribed alone as soon as it is saved" "$D_LOG"
fi
rp_flag=$(jq -r '.restitchable' "$RP_META" 2>/dev/null || true)
if [[ "$rp_flag" == "true" ]] &&
  grep -qF "2026-10-13_design-review_e1e10001.md" "$NOTIFYLOG" 2>/dev/null; then
  pass "Oct 13: its sidecar is marked replaceable and a ready alert is raised"
else
  fail "Oct 13: its sidecar is marked replaceable and a ready alert is raised" "$D_META"
fi
oct13_piece 2
notify_reset
watch_real --once >/dev/null 2>&1 || true
rp_snap
if [[ "$N_DOCS" == "1" ]] && grep -qxF "## Part 2 of 2 — starts at 29:20, after a 11 s gap" "$RP_DOC" &&
  grep -qxF "hello from e1.m4a" "$RP_DOC" && grep -qxF "hello from e2.m4a" "$RP_DOC" &&
  [[ "$N_MW" == "2" ]] && grep -q '^e1e10002 done$' "$WSTATE"; then
  pass "Oct 13: the second piece re-stitches the same transcript, transcribing only itself"
else
  fail "Oct 13: the second piece re-stitches the same transcript, transcribing only itself" "docs=$N_DOCS mw=$N_MW $D_DOC"
fi
if grep -qF "(updated with a later recording)" "$NOTIFYLOG" 2>/dev/null &&
  grep -qF "Part 2:   e1e10002 starts at 29:20, after a 11 s gap" "$WLOG"; then
  pass "Oct 13: the update is announced and its gap logged"
else
  fail "Oct 13: the update is announced and its gap logged" "$D_LOG"
fi
oct13_piece 3
watch_real --once >/dev/null 2>&1 || true
rp_snap
rp_heads=$(grep '^## ' "$RP_DOC" 2>/dev/null || true)
want_heads="## Part 1 of 3 — starts at 00:00
## Part 2 of 3 — starts at 29:20, after a 11 s gap
## Part 3 of 3 — starts at 43:31, after a 10 s gap"
if [[ "$N_DOCS" == "1" && "$rp_heads" == "$want_heads" && "$N_MW" == "3" ]] &&
  grep -qxF "*43:31-43:37*" "$RP_DOC"; then
  pass "Oct 13: the third piece completes the one transcript, timestamps continuous"
else
  fail "Oct 13: the third piece completes the one transcript, timestamps continuous" "mw=$N_MW $rp_heads"
fi
rp_ids=$(jq -c '.session_ids' "$RP_META" 2>/dev/null || true)
if [[ "$rp_ids" == '["e1e10001","e1e10002","e1e10003"]' ]] && grep -qxF "hello from e3.m4a" "$RP_DOC" &&
  grep -q '^e1e10003 done$' "$WSTATE"; then
  pass "Oct 13: nothing is lost -- every piece is in the transcript and its sidecar"
else
  fail "Oct 13: nothing is lost -- every piece is in the transcript and its sidecar" "$rp_ids"
fi
watch_real --once >/dev/null 2>&1 || true
rp_snap
if [[ "$N_MW" == "3" ]]; then
  pass "Oct 13: a later run finds nothing to do"
else
  fail "Oct 13: a later run finds nothing to do" "mw=$N_MW"
fi

# 2026-10-15: 83 s and 42 s pieces are under the 300 s floor on their own,
# so nothing runs until the third makes the meeting long enough.
replay_fresh
add_piece f1f10001 f1 '2026-10-15 15:01:23.955' 83.073625 '2026-10-15 15:02:54.630' f1.m4a "'Standup'"
watch_real --once >/dev/null 2>&1 || true
rp_snap
add_piece f1f10002 f2 '2026-10-15 15:02:53.351' 42.2019375 '2026-10-15 15:03:40.742' f2.m4a NULL
watch_real --once >/dev/null 2>&1 || true
rp_snap
if [[ "$N_MW" == "0" ]] && ! grep -q '^f1f1' "$WSTATE"; then
  pass "Oct 15: pieces under the floor together wait, untouched"
else
  fail "Oct 15: pieces under the floor together wait, untouched" "mw=$N_MW $D_STATE"
fi
add_piece f1f10003 f3 '2026-10-15 15:03:39.467' 1075.9269375 '2026-10-15 15:22:56.495' f3.m4a NULL
watch_real --once >/dev/null 2>&1 || true
rp_snap
oct15_doc="$RP/2026-10-15_standup_f1f10001.md"
oct15_heads=$(grep '^## ' "$oct15_doc" 2>/dev/null | tr '\n' '|' || true)
if [[ "$N_MW" == "3" && "$N_DOCS" == "1" ]] &&
  [[ "$oct15_heads" == "## Part 1 of 3 — starts at 00:00|## Part 2 of 3 — starts at 01:29, after a 6 s gap|## Part 3 of 3 — starts at 02:16, after a 4 s gap|" ]] &&
  grep -q '^f1f10001 done$' "$WSTATE" && grep -q '^f1f10003 done$' "$WSTATE"; then
  pass "Oct 15: the third piece brings the whole meeting in, once"
else
  fail "Oct 15: the third piece brings the whole meeting in, once" "mw=$N_MW $oct15_heads"
fi

# A saved piece not finished (transcriptionDidSucceed = 0) holds back
# nothing; the transcript names it, then takes it in.
replay_fresh
oct13_piece 1
oct13_piece 2
oct13_piece 3
sqlite3 "$WDB" "UPDATE session SET transcriptionDidSucceed = 0 WHERE id = x'e1e10002';"
watch_real --once >/dev/null 2>&1 || true
rp_snap
rp_tail=$(tail -1 "$RP_DOC" 2>/dev/null || true)
rp_pend=$(jq -c '[.session_ids, .pending_session_ids]' "$RP_META" 2>/dev/null || true)
if [[ "$N_MW" == "2" && "$N_DOCS" == "1" && "$rp_pend" == '[["e1e10001","e1e10003"],["e1e10002"]]' ]] &&
  [[ "$rp_tail" == "> **Note:** this transcript may be incomplete. MacWhisper had not finished saving part 2 of 3 (starts at 29:20, session e1e10002) when it was written. It will be updated when that part finishes." ]] &&
  grep -q '^e1e10001 done$' "$WSTATE" && grep -q '^e1e10003 done$' "$WSTATE" && ! grep -q '^e1e10002 ' "$WSTATE"; then
  pass "not ready: the ready pieces are joined now, and the transcript ends naming the other"
else
  fail "not ready: the ready pieces are joined now, and the transcript ends naming the other" "mw=$N_MW $rp_pend $rp_tail $D_STATE"
fi
watch_real --once >/dev/null 2>&1 || true
rp_snap
if [[ "$N_MW" == "2" ]]; then
  pass "not ready: a piece that stays not ready runs nothing"
else
  fail "not ready: a piece that stays not ready runs nothing" "mw=$N_MW"
fi
sqlite3 "$WDB" "UPDATE session SET transcriptionDidSucceed = 1 WHERE id = x'e1e10002';"
notify_reset
watch_real --once >/dev/null 2>&1 || true
rp_snap
if [[ "$N_MW" == "3" && "$N_DOCS" == "1" ]] && grep -qxF "hello from e2.m4a" "$RP_DOC" &&
  ! grep -qF "may be incomplete" "$RP_DOC" && grep -qF "(updated with a later recording)" "$NOTIFYLOG" 2>/dev/null &&
  [[ "$(jq -c '[.session_ids, has("pending_session_ids")]' "$RP_META" 2>/dev/null || true)" == '[["e1e10001","e1e10002","e1e10003"],false]' ]] &&
  grep -q '^e1e10002 done$' "$WSTATE"; then
  pass "not ready: when it is ready, the same transcript is replaced and the note is gone"
else
  fail "not ready: when it is ready, the same transcript is replaced and the note is gone" "mw=$N_MW $D_LOG"
fi

# Reviewed before the last piece landed: that transcript stays and the
# late piece goes to -2; review released the others' audio and cache.
replay_fresh
oct13_piece 1
watch_real --once >/dev/null 2>&1 || true
rp_snap
oct13_piece 2
watch_real --once >/dev/null 2>&1 || true
rp_snap
HUDDLE_PIECES_DIR="$RP_PIECES" "$HTW" --mark-reviewed --yes e1e10001 >/dev/null 2>&1 || true
before=$(cat "$RP_DOC" 2>/dev/null || true)
if [[ ! -e "$MEDIA/e1.m4a" && ! -e "$MEDIA/e2.m4a" ]]; then
  pass "reviewed: --mark-reviewed removed both pieces' audio"
else
  fail "reviewed: --mark-reviewed removed both pieces' audio"
fi
if [[ ! -e "$RP_PIECES/e1e10001.md" && ! -e "$RP_PIECES/e1e10002.md" ]]; then
  pass "reviewed: --mark-reviewed removed both pieces' cached transcripts"
else
  fail "reviewed: --mark-reviewed removed both pieces' cached transcripts" "$(ls "$RP_PIECES" 2>&1 || true)"
fi
oct13_piece 3
notify_reset
watch_real --once >/dev/null 2>&1 || true
rp_snap
rp_two="$RP/2026-10-13_design-review-2_e1e10001.md"
after=$(cat "$RP_DOC" 2>/dev/null || true)
if [[ "$after" == "$before" ]] && head -1 "$rp_two" 2>/dev/null | grep -qF "may duplicate 2026-10-13_design-review_e1e10001.md" &&
  grep -qxF "> **Note:** this part (session e1e10002) was not transcribed: audio file not found at $MEDIA/e2.m4a." "$rp_two" &&
  ! grep -qxF "hello from e1.m4a" "$rp_two" && grep -qxF "hello from e3.m4a" "$rp_two" &&
  grep -qF "design-review-2_e1e10001.md" "$NOTIFYLOG" && grep -q '^e1e10003 done$' "$WSTATE"; then
  pass "reviewed: the late piece writes -2 and leaves the reviewed one alone"
else
  fail "reviewed: the late piece writes -2 and leaves the reviewed one alone" "$D_LOG"
fi
rp_flags=$(jq -r '.reviewed' "$RP_META" 2>/dev/null || true)
rp_flags+=,$(jq -r '.restitchable' "$RP/2026-10-13_design-review-2_e1e10001.meta.json" 2>/dev/null || true)
if [[ "$rp_flags" == "true,true" ]]; then
  pass "reviewed: the original stays reviewed; the -2 is the one later pieces may replace"
else
  fail "reviewed: the original stays reviewed; the -2 is the one later pieces may replace"
fi
rc=0
HUDDLE_PIECES_DIR="$RP_PIECES" "$HTW" --mark-reviewed --yes e1e10003 >/dev/null 2>&1 || rc=$?
rp_sid=$(jq -r '.session_id' "$RP/2026-10-13_design-review-2_e1e10001.meta.json" 2>/dev/null || true)
if [[ $rc -eq 0 && ! -e "$MEDIA/e3.m4a" && "$rp_sid" == "e1e10003" ]]; then
  pass "reviewed: the -2 releases the late piece, which only it holds"
else
  fail "reviewed: the -2 releases the late piece, which only it holds" "exit $rc"
fi

# One bad piece: the meeting is written without it, with a note; a retry
# that works completes the same transcript.
replay_fresh
oct13_piece 1
oct13_piece 2
oct13_piece 3
notify_reset
MW_FAIL_MATCH="e2.m4a" watch_real --once >/dev/null 2>&1 || true
rp_snap
if grep -qxF "> **Note:** this part (session e1e10002) was not transcribed: mw transcribe failed for $MEDIA/e2.m4a." "$RP_DOC" &&
  grep -qxF "hello from e3.m4a" "$RP_DOC" && grep -q '^e1e10002 1$' "$WSTATE" &&
  grep -q '^e1e10001 done$' "$WSTATE" && grep -q '^e1e10003 done$' "$WSTATE" &&
  grep -qF "Meeting transcript ready" "$NOTIFYLOG" 2>/dev/null; then
  pass "failed piece: the meeting is joined without it, noted, and announced"
else
  fail "failed piece: the meeting is joined without it, noted, and announced" "$D_STATE $D_DOC"
fi
before=$(cat "$RP_DOC" 2>/dev/null || true)
MW_FAIL_MATCH="e2.m4a" watch_real --once >/dev/null 2>&1 || true
rp_snap
after=$(cat "$RP_DOC" 2>/dev/null || true)
if [[ "$after" == "$before" ]] && grep -q '^e1e10002 2$' "$WSTATE" && [[ "$N_MW" == "4" ]]; then
  pass "failed piece: a retry that fails again costs an attempt and rewrites nothing"
else
  fail "failed piece: a retry that fails again costs an attempt and rewrites nothing" "mw=$N_MW $D_STATE"
fi
watch_real --once >/dev/null 2>&1 || true
rp_snap
if [[ "$N_DOCS" == "1" ]] && grep -qxF "hello from e2.m4a" "$RP_DOC" && ! grep -qF "was not transcribed" "$RP_DOC" &&
  grep -q '^e1e10002 done$' "$WSTATE" && [[ "$N_MW" == "5" ]]; then
  pass "failed piece: a retry that works completes the same transcript"
else
  fail "failed piece: a retry that works completes the same transcript" "mw=$N_MW $D_STATE"
fi
rm -rf "$RP" "$RP_PIECES" "$WORK/mw-calls"
rm -f "$MEDIA"/e[123].m4a "$MEDIA"/f[123].m4a

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

# --- huddle-migrate-md -------------------------------------------------
#
# The migration adopts pre-Markdown .txt transcripts. Its whole risk surface
# is that it renames files and rewrites the sidecar that points at them, so
# the cases below are weighted toward what it must REFUSE to touch.

echo "huddle-migrate-md"

MIGDIR="$WORK/mig"

# Write a transcript + sidecar pair whose output_file names the transcript,
# which is the shape huddle-transcribe produced before the Markdown switch.
mig_pair() {
  local stem="$1"
  printf 'Speaker 1\n00:00\nhello from %s\n\n' "$stem" >"$MIGDIR/$stem.txt"
  jq -n --arg o "$stem.txt" \
    '{session_id:"aaaa0001",date:"2026-08-27",duration_seconds:1076,
      source_file:"x.m4a",output_file:$o,reviewed:false,deleted_source:false}' \
    >"$MIGDIR/$stem.meta.json"
}

mig_reset() {
  rm -rf "$MIGDIR"
  mkdir -p "$MIGDIR"
}

# migrate <args...>
migrate() {
  "$MIGRATE" --output-dir "$MIGDIR" "$@"
}

# expect_mig_rc <name> <want-rc> <args...>
expect_mig_rc() {
  local name="$1" want="$2"
  shift 2
  local rc=0
  migrate "$@" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq $want ]]; then
    pass "$name"
  else
    fail "$name" "exit $rc, wanted $want"
  fi
}

mig_reset
expect_mig_rc "--help exits 0" 0 --help
expect_mig_rc "unknown flag rejected" 1 --bogus
expect_mig_rc "--output-dir requires an argument" 1 --output-dir
expect_mig_rc "an empty directory exits 0" 0 --yes
expect_mig_rc "a missing directory exits 1" 1 --yes --output-dir "$WORK/no-such-dir"

# The happy path: transcript renamed, sidecar repointed, bytes preserved.
mig_reset
mig_pair "2026-08-27_sre-daily-huddle_aaaa0001"
mig_before=$(cat "$MIGDIR/2026-08-27_sre-daily-huddle_aaaa0001.txt")
expect_mig_rc "a valid pair migrates" 0 --yes
exists "the transcript becomes .md" "$MIGDIR/2026-08-27_sre-daily-huddle_aaaa0001.md"
absent "the .txt is gone" "$MIGDIR/2026-08-27_sre-daily-huddle_aaaa0001.txt"
mig_after=$(cat "$MIGDIR/2026-08-27_sre-daily-huddle_aaaa0001.md")
if [[ "$mig_before" == "$mig_after" ]]; then
  pass "transcript content is byte-identical after migration"
else
  fail "transcript content is byte-identical after migration"
fi
mig_out=$(jq -r '.output_file' "$MIGDIR/2026-08-27_sre-daily-huddle_aaaa0001.meta.json")
if [[ "$mig_out" == "2026-08-27_sre-daily-huddle_aaaa0001.md" ]]; then
  pass "the sidecar output_file is repointed at the .md"
else
  fail "the sidecar output_file is repointed at the .md" "got: $mig_out"
fi
# Every other sidecar field must survive the rewrite -- the migration edits
# one key, and clobbering session_id would break --mark-reviewed's identity
# fence, which is the guard that stops it deleting the wrong audio.
mig_sid=$(jq -r '.session_id' "$MIGDIR/2026-08-27_sre-daily-huddle_aaaa0001.meta.json")
if [[ "$mig_sid" == "aaaa0001" ]]; then
  pass "the sidecar keeps its session_id"
else
  fail "the sidecar keeps its session_id" "got: $mig_sid"
fi

# Running again must be a no-op, not an error: the migration is something a
# user may reasonably run twice, and on a directory that is already clean.
expect_mig_rc "a second run is a no-op" 0 --yes

# --dry-run must not touch the directory at all. This mirrors the ordering
# rule huddle-transcribe enforces for --mark-reviewed.
mig_reset
mig_pair "2026-08-31_terraform_bbbb0002"
expect_mig_rc "--dry-run exits 0" 0 --dry-run
exists "--dry-run leaves the .txt in place" "$MIGDIR/2026-08-31_terraform_bbbb0002.txt"
absent "--dry-run writes no .md" "$MIGDIR/2026-08-31_terraform_bbbb0002.md"
dry_out=$(jq -r '.output_file' "$MIGDIR/2026-08-31_terraform_bbbb0002.meta.json")
if [[ "$dry_out" == "2026-08-31_terraform_bbbb0002.txt" ]]; then
  pass "--dry-run leaves the sidecar unchanged"
else
  fail "--dry-run leaves the sidecar unchanged" "got: $dry_out"
fi

# A .txt with no sidecar is not ours. huddle-transcribe writes the pair
# together, so a lone .txt is someone else's file or failed-run debris --
# renaming a stranger's file is worse than leaving a transcript stranded.
mig_reset
printf 'orphan\n' >"$MIGDIR/2026-09-01_orphan_cccc0003.txt"
expect_mig_rc "a sidecar-less .txt does not block the run" 0 --yes
exists "a sidecar-less .txt is left alone" "$MIGDIR/2026-09-01_orphan_cccc0003.txt"
absent "a sidecar-less .txt produces no .md" "$MIGDIR/2026-09-01_orphan_cccc0003.md"

# An existing .md is the collision that loses data: one of the two files was
# written by something this script did not, and silently picking a winner is
# the class of bug the session-id suffix exists to prevent.
mig_reset
mig_pair "2026-09-02_collide_dddd0004"
printf 'pre-existing markdown\n' >"$MIGDIR/2026-09-02_collide_dddd0004.md"
expect_mig_rc "an existing .md does not block the run" 0 --yes
exists "an existing .md is not overwritten" "$MIGDIR/2026-09-02_collide_dddd0004.txt"
collide=$(cat "$MIGDIR/2026-09-02_collide_dddd0004.md")
if [[ "$collide" == "pre-existing markdown" ]]; then
  pass "the pre-existing .md keeps its content"
else
  fail "the pre-existing .md keeps its content" "got: $collide"
fi

# A sidecar that will not parse must stop that pair, not the whole run, and
# must not leave the transcript renamed past a sidecar it could not rewrite.
mig_reset
mig_pair "2026-09-03_badjson_eeee0005"
printf 'not json at all' >"$MIGDIR/2026-09-03_badjson_eeee0005.meta.json"
expect_mig_rc "an unparseable sidecar does not block the run" 0 --yes
exists "an unparseable sidecar leaves its .txt alone" "$MIGDIR/2026-09-03_badjson_eeee0005.txt"
absent "an unparseable sidecar produces no .md" "$MIGDIR/2026-09-03_badjson_eeee0005.md"

# A sidecar pointing at a different filename means the pairing is already
# broken. Rewriting output_file would destroy the evidence of how.
mig_reset
mig_pair "2026-09-04_mismatch_ffff0006"
jq '.output_file = "some-other-file.txt"' \
  "$MIGDIR/2026-09-04_mismatch_ffff0006.meta.json" >"$MIGDIR/tmp.json"
mv "$MIGDIR/tmp.json" "$MIGDIR/2026-09-04_mismatch_ffff0006.meta.json"
expect_mig_rc "a mismatched sidecar does not block the run" 0 --yes
exists "a mismatched sidecar leaves its .txt alone" "$MIGDIR/2026-09-04_mismatch_ffff0006.txt"
mismatch=$(jq -r '.output_file' "$MIGDIR/2026-09-04_mismatch_ffff0006.meta.json")
if [[ "$mismatch" == "some-other-file.txt" ]]; then
  pass "a mismatched sidecar is left unrewritten"
else
  fail "a mismatched sidecar is left unrewritten" "got: $mismatch"
fi

# A bad pair must not prevent a good one in the same directory from
# migrating -- the survey classifies every candidate before anything moves.
mig_reset
mig_pair "2026-09-05_good_11110007"
printf 'orphan\n' >"$MIGDIR/2026-09-05_bad_22220008.txt"
expect_mig_rc "a mixed directory exits 0" 0 --yes
exists "the good pair migrates alongside a bad one" "$MIGDIR/2026-09-05_good_11110007.md"
exists "the bad one is still skipped" "$MIGDIR/2026-09-05_bad_22220008.txt"

# The point of the whole migration: a migrated pair must satisfy every
# --mark-reviewed fence, since being invisible to --mark-reviewed is the
# problem it exists to fix.
mig_reset
reset_media
rm -rf "$OUT"
expect_rc "a session transcribes for the migration check" 0 --yes --output-dir "$OUT" aaaa0001
# Walk it back to the pre-migration shape, then migrate it forward again.
mv "$OUT/2026-08-27_sre-daily-huddle_aaaa0001.md" \
  "$OUT/2026-08-27_sre-daily-huddle_aaaa0001.txt"
jq '.output_file = "2026-08-27_sre-daily-huddle_aaaa0001.txt"' \
  "$OUT/2026-08-27_sre-daily-huddle_aaaa0001.meta.json" >"$OUT/tmp.json"
mv "$OUT/tmp.json" "$OUT/2026-08-27_sre-daily-huddle_aaaa0001.meta.json"
mig_rc=0
"$MIGRATE" --yes --output-dir "$OUT" >/dev/null 2>&1 || mig_rc=$?
if [[ $mig_rc -eq 0 ]]; then
  pass "a real transcript pair migrates"
else
  fail "a real transcript pair migrates" "exit $mig_rc"
fi
expect_rc "a migrated pair satisfies --mark-reviewed" 0 \
  --mark-reviewed --yes --output-dir "$OUT" aaaa0001
absent "--mark-reviewed removes the audio after migration" "$MEDIA/A_merged.m4a"
reset_media

# A failed sidecar rename leaves the transcript renamed and the sidecar stale.
# Re-running does NOT repair that -- the survey globs *.txt and this pair's
# .txt is gone -- so the error message must not promise that it does. An
# earlier version of the script claimed exactly that in both a comment and the
# message; CI review caught it. Pin the real behavior.
#
# chflags is macOS-only. It is the way to make the rename ONTO the sidecar
# fail while leaving mktemp in the same directory working: a read-only
# directory fails earlier, at mktemp, which never reaches this branch.
if command -v chflags >/dev/null 2>&1; then
  mig_reset
  mig_pair 2026-09-01_alpha_11110001
  chflags uchg "$MIGDIR/2026-09-01_alpha_11110001.meta.json"
  mig_out=$("$MIGRATE" --yes --output-dir "$MIGDIR" 2>&1 || true)
  chflags nouchg "$MIGDIR/2026-09-01_alpha_11110001.meta.json"

  exists "a failed sidecar rename still leaves the .md in place" \
    "$MIGDIR/2026-09-01_alpha_11110001.md"
  if [[ "$mig_out" == *"Re-running will NOT fix this"* ]]; then
    pass "the failure message does not promise a re-run repairs it"
  else
    fail "the failure message does not promise a re-run repairs it" "$mig_out"
  fi

  # And the claim itself must be true: a re-run must leave the sidecar stale.
  "$MIGRATE" --yes --output-dir "$MIGDIR" >/dev/null 2>&1 || true
  stale=$(jq -r '.output_file' "$MIGDIR/2026-09-01_alpha_11110001.meta.json")
  if [[ "$stale" == "2026-09-01_alpha_11110001.txt" ]]; then
    pass "a re-run does not silently repair the stale sidecar"
  else
    fail "a re-run does not silently repair the stale sidecar" "output_file=$stale"
  fi
else
  # One skip per assertion in the if-branch, named identically, so a Linux run
  # accounts for exactly what it did not execute. A skip whose name matches no
  # real test hides a missing one.
  skip "a failed sidecar rename still leaves the .md in place (chflags unavailable)"
  skip "the failure message does not promise a re-run repairs it (chflags unavailable)"
  skip "a re-run does not silently repair the stale sidecar (chflags unavailable)"
fi

# --- install.sh --------------------------------------------------------
#
# HOME and target dirs are in $WORK; launchd calls are stubs.

echo "install.sh"

INSTALL="$REPO_ROOT/install.sh"
IHOME="$WORK/inst/home"
IBIN="$IHOME/.local/bin"
ISKILLS="$IHOME/.claude/skills"
ISKILL="$ISKILLS/huddle-review"
ISTUB="$WORK/inst/stub"
ICALLS="$WORK/inst/calls"
ISKILL_SRC="$REPO_ROOT/skills/huddle-review/SKILL.md"
IRETIRED_LABEL="com.smartwatermelon.huddle-transcribe.mic-guard"
IRETIRED_PLIST="$IHOME/Library/LaunchAgents/$IRETIRED_LABEL.plist"

mkdir -p "$ISTUB"
# Each stub logs "<name> <args>" to $ICALLS. INSTALL_STUB_FAIL names one
# "<name> <first-arg>" pair that exits 1.
for stub in huddle-watch launchctl; do
  cat >"$ISTUB/$stub" <<'STUB'
#!/usr/bin/env bash
name="${0##*/}"
printf '%s %s\n' "$name" "$*" >>"$ICALLS"
[[ "${INSTALL_STUB_FAIL:-}" != "$name ${1:-}" ]] || exit 1
exit 0
STUB
  chmod +x "$ISTUB/$stub"
done
unset stub

inst_reset() {
  rm -rf "$IHOME" "$ICALLS"
  mkdir -p "$IHOME"
  : >"$ICALLS"
}

# inst <args...>: run install.sh against the fixture. Output lands in
# $IOUT and the exit status in $IRC. INST_PATH replaces PATH when set.
inst() {
  IRC=0
  IOUT=$(env HOME="$IHOME" HUDDLE_BIN_DIR="$IBIN" HUDDLE_SKILLS_DIR="$ISKILLS" \
    HUDDLE_WATCH_BIN="$ISTUB/huddle-watch" \
    HUDDLE_LAUNCHCTL_BIN="$ISTUB/launchctl" ICALLS="$ICALLS" \
    PATH="${INST_PATH:-$PATH}" "$INSTALL" "$@" 2>&1) || IRC=$?
}

# Every assertion also checks install.sh's exit or refusal message, so
# none passes when install.sh is missing.

# expect_link <name> <path> <want-target> [<want-rc>]
expect_link() {
  local target=""
  if [[ -L "$2" ]]; then
    target=$(readlink -- "$2")
  fi
  if [[ $IRC -eq ${4:-0} && "$target" == "$3" ]]; then
    pass "$1"
  else
    fail "$1" "exit $IRC; $2 -> '${target}' (wanted '$3')"
  fi
}

# expect_calls <name> <want>: install.sh exited 0 and the stubs were called
# exactly as <want>.
expect_calls() {
  local calls
  calls=$(cat "$ICALLS")
  if [[ $IRC -eq 0 && "$calls" == "$2" ]]; then
    pass "$1"
  else
    fail "$1" "exit $IRC; calls: $calls"
  fi
}

inst_reset
inst --help
if [[ $IRC -eq 0 && "$IOUT" == *"--uninstall"* ]]; then
  pass "install.sh --help exits 0 and documents --uninstall"
else
  fail "install.sh --help exits 0 and documents --uninstall" "exit $IRC: $IOUT"
fi
if [[ $IRC -eq 0 && ! -e "$IBIN" && ! -e "$ISKILLS" ]]; then
  pass "install.sh --help links nothing"
else
  fail "install.sh --help links nothing" "exit $IRC"
fi
expect_calls "install.sh --help runs no LaunchAgent command" ""

inst --bogus
if [[ $IRC -ne 0 && "$IOUT" == *"Unknown option: --bogus"* ]]; then
  pass "install.sh rejects an unknown option"
else
  fail "install.sh rejects an unknown option" "exit $IRC: $IOUT"
fi
inst extra
if [[ $IRC -ne 0 && "$IOUT" == *"unexpected argument 'extra'"* && ! -e "$IBIN" ]]; then
  pass "install.sh rejects a positional argument and installs nothing"
else
  fail "install.sh rejects a positional argument and installs nothing" "exit $IRC: $IOUT"
fi

# Fresh install.
inst_reset
inst
if [[ $IRC -eq 0 ]]; then
  pass "a fresh install exits 0"
else
  fail "a fresh install exits 0" "exit $IRC: $IOUT"
fi
for name in huddle-transcribe huddle-watch; do
  expect_link "a fresh install links $name into the bin dir" \
    "$IBIN/$name" "$REPO_ROOT/$name"
done
if [[ $IRC -eq 0 && ! -e "$IBIN/huddle-mic-guard" && ! -L "$IBIN/huddle-mic-guard" ]]; then
  pass "a fresh install does not link the retired huddle-mic-guard"
else
  fail "a fresh install does not link the retired huddle-mic-guard" "exit $IRC"
fi
if [[ $IRC -eq 0 && -d "$ISKILL" && ! -L "$ISKILL" ]]; then
  pass "the skill directory is a real directory, not a link"
else
  fail "the skill directory is a real directory, not a link"
fi
expect_link "the skill's SKILL.md is a link into the checkout" \
  "$ISKILL/SKILL.md" "$ISKILL_SRC"
want_calls=$'huddle-watch --install\nhuddle-watch --status'
expect_calls "install runs huddle-watch --install, then --status last" "$want_calls"
if [[ "$IOUT" == *"is not on PATH"* ]]; then
  pass "install warns when the bin dir is not on PATH"
else
  fail "install warns when the bin dir is not on PATH" "$IOUT"
fi

# The warning is absent once the bin dir is on PATH.
inst_reset
INST_PATH="$IBIN:$PATH" inst
if [[ $IRC -eq 0 && "$IOUT" != *"is not on PATH"* ]]; then
  pass "install does not warn when the bin dir is on PATH"
else
  fail "install does not warn when the bin dir is on PATH" "exit $IRC: $IOUT"
fi

# A re-run is a no-op for the links, and still drives the install.
: >"$ICALLS"
inst
if [[ $IRC -eq 0 && "$IOUT" == *"(already)"* && "$IOUT" != *"Relinked"* ]]; then
  pass "a re-run exits 0 and relinks nothing"
else
  fail "a re-run exits 0 and relinks nothing" "exit $IRC: $IOUT"
fi
expect_link "a re-run leaves the huddle-watch link as it was" \
  "$IBIN/huddle-watch" "$REPO_ROOT/huddle-watch"
expect_link "a re-run leaves the SKILL.md link as it was" \
  "$ISKILL/SKILL.md" "$ISKILL_SRC"
expect_calls "a re-run runs the LaunchAgent install again" "$want_calls"

# A stale link -- dangling, or into another checkout -- is replaced.
mkdir -p "$IBIN" "$ISKILL"
rm -f "$IBIN/huddle-watch" "$ISKILL/SKILL.md"
ln -s "$WORK/inst/no-such-checkout/huddle-watch" "$IBIN/huddle-watch"
ln -s "$WORK/inst/no-such-checkout/SKILL.md" "$ISKILL/SKILL.md"
inst
if [[ $IRC -eq 0 && "$IOUT" == *"Relinked"* ]]; then
  pass "install with stale links exits 0 and reports the relink"
else
  fail "install with stale links exits 0 and reports the relink" "exit $IRC: $IOUT"
fi
expect_link "a stale bin link is replaced" "$IBIN/huddle-watch" "$REPO_ROOT/huddle-watch"
expect_link "a stale SKILL.md link is replaced" "$ISKILL/SKILL.md" "$ISKILL_SRC"

# A real file is never overwritten, and a refusal changes nothing: a
# stale link elsewhere is not repaired either.
inst_reset
mkdir -p "$IBIN"
printf 'precious\n' >"$IBIN/huddle-transcribe"
ln -s "$WORK/inst/elsewhere/huddle-watch" "$IBIN/huddle-watch"
inst
refused=0
[[ $IRC -eq 0 || "$IOUT" != *"refusing to overwrite"* ]] || refused=1
if [[ $refused -eq 1 && "$IOUT" == *"$IBIN/huddle-transcribe"* ]]; then
  pass "install refuses a real file in the bin dir and names it"
else
  fail "install refuses a real file in the bin dir and names it" "exit $IRC: $IOUT"
fi
content=$(cat "$IBIN/huddle-transcribe" 2>/dev/null || true)
if [[ $refused -eq 1 && ! -L "$IBIN/huddle-transcribe" && "$content" == "precious" ]]; then
  pass "the refused real file is left untouched"
else
  fail "the refused real file is left untouched"
fi
expect_link "a refusal leaves a stale link elsewhere unrepaired" \
  "$IBIN/huddle-watch" "$WORK/inst/elsewhere/huddle-watch" 1
calls=$(cat "$ICALLS")
if [[ $refused -eq 1 && ! -e "$ISKILLS" && -z "$calls" ]]; then
  pass "a refusal creates no skill directory and runs no LaunchAgent command"
else
  fail "a refusal creates no skill directory and runs no LaunchAgent command" "calls: $calls"
fi

# Same rule for a real SKILL.md inside a real skill directory.
inst_reset
mkdir -p "$ISKILL"
printf 'local edit\n' >"$ISKILL/SKILL.md"
inst
content=$(cat "$ISKILL/SKILL.md" 2>/dev/null || true)
if [[ "$IOUT" == *"refusing to overwrite"* && $IRC -ne 0 &&
  "$content" == "local edit" && ! -L "$ISKILL/SKILL.md" ]]; then
  pass "install refuses a real SKILL.md and leaves it untouched"
else
  fail "install refuses a real SKILL.md and leaves it untouched" "exit $IRC: $IOUT"
fi

# The old README form: the skill directory itself linked into the checkout.
inst_reset
mkdir -p "$ISKILLS"
ln -s "$REPO_ROOT/skills/huddle-review" "$ISKILL"
inst
if [[ $IRC -eq 0 && -d "$ISKILL" && ! -L "$ISKILL" ]]; then
  pass "an old directory-link skill becomes a real directory"
else
  fail "an old directory-link skill becomes a real directory" "exit $IRC: $IOUT"
fi
expect_link "the converted skill directory holds a SKILL.md link" \
  "$ISKILL/SKILL.md" "$ISKILL_SRC"
if [[ $IRC -eq 0 && -f "$ISKILL_SRC" && ! -L "$ISKILL_SRC" ]]; then
  pass "converting the directory link leaves the checkout's SKILL.md in place"
else
  fail "converting the directory link leaves the checkout's SKILL.md in place"
fi

# Retired huddle-mic-guard: an old link into this checkout and its plist
# are removed. retired_setup <link-target> lays them down.
retired_setup() {
  inst_reset
  mkdir -p "$IBIN" "${IRETIRED_PLIST%/*}"
  ln -s "$1" "$IBIN/huddle-mic-guard"
  printf '<plist/>\n' >"$IRETIRED_PLIST"
}
iuid=$(id -u)
retired_setup "$REPO_ROOT/huddle-mic-guard"
inst
if [[ $IRC -eq 0 && ! -L "$IBIN/huddle-mic-guard" ]]; then
  pass "install removes the retired huddle-mic-guard link into this checkout"
else
  fail "install removes the retired huddle-mic-guard link into this checkout" "exit $IRC: $IOUT"
fi
absent "install removes the retired mic-guard plist" "$IRETIRED_PLIST"
expect_calls "install boots out the retired mic-guard agent" \
  "launchctl bootout gui/$iuid/$IRETIRED_LABEL"$'\n'"$want_calls"
if [[ "$IOUT" == *"Removed:   $IRETIRED_PLIST"* ]]; then
  pass "install reports the retired plist it removed"
else
  fail "install reports the retired plist it removed" "$IOUT"
fi

# A mic-guard link into some other checkout is not ours to remove.
retired_setup "$WORK/inst/other-checkout/huddle-mic-guard"
inst
expect_link "install leaves a huddle-mic-guard link into another checkout" \
  "$IBIN/huddle-mic-guard" "$WORK/inst/other-checkout/huddle-mic-guard"

# --uninstall removes only what points into this checkout.
inst_reset
inst
mkdir -p "$IBIN"
rm -f "$IBIN/huddle-watch"
ln -s "$WORK/inst/other-checkout/huddle-watch" "$IBIN/huddle-watch"
ln -s "$WORK/inst/other-tool" "$IBIN/other-tool"
: >"$ICALLS"
inst --uninstall
if [[ $IRC -eq 0 ]]; then
  pass "--uninstall exits 0"
else
  fail "--uninstall exits 0" "exit $IRC: $IOUT"
fi
if [[ $IRC -eq 0 && ! -e "$IBIN/huddle-transcribe" && ! -L "$IBIN/huddle-transcribe" ]]; then
  pass "--uninstall removes the links into this checkout"
else
  fail "--uninstall removes the links into this checkout"
fi
expect_link "--uninstall leaves a link into another checkout" \
  "$IBIN/huddle-watch" "$WORK/inst/other-checkout/huddle-watch"
expect_link "--uninstall leaves an unrelated link" \
  "$IBIN/other-tool" "$WORK/inst/other-tool"
if [[ $IRC -eq 0 && ! -e "$ISKILL" && ! -L "$ISKILL" ]]; then
  pass "--uninstall removes the emptied skill directory"
else
  fail "--uninstall removes the emptied skill directory"
fi
expect_calls "--uninstall runs huddle-watch --uninstall" "huddle-watch --uninstall"

# --uninstall cleans up the retired mic-guard the same way install does.
retired_setup "$REPO_ROOT/huddle-mic-guard"
inst --uninstall
if [[ $IRC -eq 0 && ! -L "$IBIN/huddle-mic-guard" && ! -e "$IRETIRED_PLIST" ]]; then
  pass "--uninstall removes the retired mic-guard link and plist"
else
  fail "--uninstall removes the retired mic-guard link and plist" "exit $IRC: $IOUT"
fi
expect_calls "--uninstall boots out the retired mic-guard agent" \
  $'huddle-watch --uninstall\n'"launchctl bootout gui/$iuid/$IRETIRED_LABEL"

# A skill directory holding anything else is kept, minus our link.
inst_reset
inst
mkdir -p "$ISKILL"
printf 'notes\n' >"$ISKILL/NOTES.md"
inst --uninstall
if [[ $IRC -eq 0 && -d "$ISKILL" && -f "$ISKILL/NOTES.md" && ! -L "$ISKILL/SKILL.md" ]]; then
  pass "--uninstall keeps a non-empty skill directory but removes SKILL.md"
else
  fail "--uninstall keeps a non-empty skill directory but removes SKILL.md" "$IOUT"
fi

# A real file where a link was is never removed by --uninstall.
inst_reset
mkdir -p "$IBIN"
printf 'precious\n' >"$IBIN/huddle-transcribe"
inst --uninstall
content=$(cat "$IBIN/huddle-transcribe" 2>/dev/null || true)
if [[ $IRC -eq 0 && ! -L "$IBIN/huddle-transcribe" && "$content" == "precious" ]]; then
  pass "--uninstall leaves a real file in the bin dir"
else
  fail "--uninstall leaves a real file in the bin dir" "exit $IRC: $IOUT"
fi

# A LaunchAgent install failure is not swallowed.
inst_reset
INSTALL_STUB_FAIL="huddle-watch --install" inst
calls=$(cat "$ICALLS")
if [[ $IRC -ne 0 && "$calls" == "huddle-watch --install" ]]; then
  pass "a failed huddle-watch --install fails install.sh"
else
  fail "a failed huddle-watch --install fails install.sh" "exit $IRC; calls: $calls"
fi

# --- summary -----------------------------------------------------------

echo
if ((SKIP > 0)); then
  printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
else
  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
fi
[[ $FAIL -eq 0 ]]
