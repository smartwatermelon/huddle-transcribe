# Design & plan: speaker name attribution

**Date:** 2026-09-01
**Status:** proposed; not implemented
**Origin:** The 2026-09-01 Slack huddle transcript
(`2026-09-01_tech-tasks-and-testing_c15ce43e.txt`) differentiates speakers but
does not identify them. `README.md:5-6` describes named output as the intended
end state — "generic speaker labels ... ready for a follow-up pass that
attributes names" — but that follow-up pass has never been written.

---

## 1. Why the current output is unnamed

The script already passes the flag that looks like it should solve this
(`huddle-transcribe:530-537`):

```bash
"$MW_BIN" transcribe --speakers --speaker-names --timestamps ...
```

It does not solve it, and the reason is in `mw transcribe --help`:

| Flag | What it actually does |
|---|---|
| `--speakers` | Enables diarization. "Controls whether speakers are detected, **not whether their names are shown**." |
| `--speaker-names` | "Annotate each segment with **its speaker's name**." |

`--speaker-names` renders a name already attached to a diarized speaker. It
does not derive one. MacWhisper holds no voice print for anyone on the huddle,
so every speaker's "name" is the placeholder `Speaker N`. The flag is working
as documented; it has nothing to render.

**There is no CLI path to fix this at the `mw` layer.** `mw` exposes exactly
three subcommands — `version`, `models`, `transcribe`. There is no `speakers`,
`voices`, `identify`, or enrollment command. Verified 2026-09-01 against the
installed binary. Any attribution must therefore happen *after* `mw` returns.

This also means one existing check is misleading. `huddle-transcribe:550-552`
warns when `^Speaker` is **absent** and stays silent when it is present — but
a transcript full of `Speaker 1` is precisely the unattributed case. The check
is a sound diarization smoke test wearing the wrong label. Reword it rather
than remove it (see §7).

---

## 2. Constraints discovered in the existing corpus

These come from the four transcripts currently in the output directory. They
are the reason several obvious designs do not work.

### 2.1 Label numbering is not stable across meetings

| Transcript | Distinct labels |
|---|---|
| `2026-09-01_tech-tasks-and-testing` | 3 |
| `2026-08-31_testing-terraform-provider-lock-files` | 4 |
| `2026-08-31_eli-lilly-and-centessa...` | **18** |

`Speaker 2` in one meeting is not `Speaker 2` in the next. Diarization assigns
labels in order of first utterance, so the mapping changes whenever someone
joins late or stays quiet. **A global `Speaker 2 = Dave` config file is
therefore wrong and will silently mislabel.** Any persisted mapping must be
keyed per session.

### 2.2 Meeting size varies by an order of magnitude

The 18-speaker file is the 61-minute weekly pulse, and it genuinely has that
many speakers. Its utterance distribution is what a real all-hands looks like:

| Label | Utterances |
|---|---|
| Speaker 1 | 9 |
| Speakers 2-4, 7 | 2-3 each |
| Speakers 9-18 | 1 each |

One host carrying the meeting, then a long tail of people who speak once. So
the tool must handle both a 3-person huddle and an 18-person all-hands as
normal input, not treat the latter as a diarization defect.

Consequences:

- The UI must stay usable at ~18 labels, not just 3.
- A flow that demands all 18 answers before it will write anything is
  unusable. Naming must be **partial and resumable** — name the host and the
  four regulars, leave the one-line drive-bys generic, come back later.
- `--list` should order labels by utterance count, not label number. The
  high-value names are the frequent speakers, and in a long tail the ordering
  is what makes partial naming practical.

An important caveat for a future suggester (§4.3): a single-utterance speaker
gives almost nothing to attribute from. Ten of the 18 labels here have exactly
one line. Attribution confidence is a function of how much someone said.

### 2.3 Naive name-frequency detection does not work

Counting first names across the corpus returns `will` (37), `pat`, `mark`,
`matt`... — because "will", "pat", and "mark" are ordinary English words. Any
auto-detection that greps a name list will produce confident garbage. A name
gazetteer needs, at minimum, a roster to match against and vocative context
("thanks, Dave", "Dave, can you"), not bare token frequency.

### 2.4 The transcript format is strictly regular

40 blocks in the sample, every one a 4-line unit:

```
Speaker 1        <- ^Speaker [0-9]+$
00:06            <- ^[0-9]+:[0-9][0-9]$
<body text>
                 <- blank
```

Census: 40 LABEL / 40 TIME / 40 TEXT / 41 BLANK. Zero occurrences of the string
`Speaker` inside body text across the corpus.

This regularity is what makes a line-anchored rewrite safe — but §5.1 explains
why the implementation must still anchor rather than trust it.

---

## 3. Options considered

| # | Approach | Verdict |
|---|---|---|
| 1 | **Post-pass rename tool.** New `huddle-name-speakers` maps labels to names, rewrites the `.txt`, records the mapping in the sidecar. | **Recommended.** Offline, no new dependency, reuses existing state. |
| 2 | **LLM attribution pass.** Send transcript to Claude; it proposes a mapping from self-reference and vocative context. | Deferred. Real value, but adds an API key and network egress to a repo that shells out only to POSIX utilities — and sends meeting audio content off-device, reversing the "on-device, no external services" property the README sells in its Background section. Viable later as an opt-in *suggester* feeding option 1. |
| 3 | **Persistent voice prints.** True identification by voice. | Rejected for now. `mw` cannot do it (§1); needs a different diarization stack. Large, and discards the CoreML/ANE benefit. |

Option 1 is the whole of this plan. Option 2 is designed *around* in §4.3 so it
can be added later without rework.

---

## 4. Design: `huddle-name-speakers`

A third script alongside `huddle-transcribe` and `huddle-watch`. Same idioms:
`set -euo pipefail`, POSIX-portable utilities only, no `date(1)`, `mktemp` +
`mv` beside the target for every write.

### 4.1 Interface

```
huddle-name-speakers [OPTIONS] <transcript.txt | session-id | date | latest>
```

| Option | Behavior |
|---|---|
| `--set N=NAME` | Map `Speaker N` to `NAME`. Repeatable. |
| `--interactive` | Prompt per label, showing a sample utterance. Empty input leaves the label unchanged. |
| `--list` | Print each label with its utterance count and first line, ordered by count descending. Read-only. *(§2.2)* |
| `--dry-run` | Print the rewrite that would happen. Changes nothing. |
| `--revert` | Restore generic labels from the sidecar mapping. |
| `--output-dir PATH` | Same override as `huddle-transcribe`. |

Target resolution should reuse `huddle-transcribe`'s existing vocabulary
(`latest`, `YYYY-MM-DD`, session-id prefix) so the two tools accept the same
arguments. A bare path is also accepted, since the user's natural move is to
point at the file they just read.

### 4.2 Sidecar schema addition

The sidecar is already the state store, and this follows that rule. Add one
optional key:

```json
{
  "session_id": "c15ce43e1dcd4cf0a0c52eff8134f21a",
  "output_file": "2026-09-01_tech-tasks-and-testing_c15ce43e.txt",
  "reviewed": false,
  "deleted_source": false,
  "speaker_names": {
    "1": "Andrew",
    "2": "Dave",
    "3": "Chris"
  }
}
```

Rules:

- **Absent key means never named.** Distinct from `{}`, which means "the tool
  ran and the user named nobody." Same `-s`-vs-`-f` distinction `huddle-watch`
  already makes for its state file.
- **Keys are the numeric part as a string**, not the full label. Storing `"1"`
  rather than `"Speaker 1"` keeps the mapping meaningful if the label prefix
  ever changes, and avoids JSON keys that differ only by whitespace.
- **Partial maps are valid and expected** (§2.2). Unlisted labels stay generic.
- `huddle-transcribe` keeps writing sidecars without this key. No migration is
  needed; readers treat absent as empty.

Emitting it as an object rather than an array matters: `jq` object access is a
total function returning `null` for a missing key, so a partial map needs no
bounds checking on the read side.

### 4.3 Forward compatibility with an LLM suggester

Option 2 later becomes a *source of proposals*, never a writer. It would emit
the same `{"1": "Andrew"}` object; `huddle-name-speakers` would present it as
prefilled defaults in `--interactive`. Keeping the mapping format identical and
the human confirmation mandatory means option 2 adds a front end, not a
rewrite. Recording provenance (`"speaker_names_source": "manual" | "suggested"`)
is worth adding at that point, not now.

---

## 5. The rewrite, and its failure modes

This is the part that can lose data, so it gets the same treatment as
`--mark-reviewed`.

### 5.1 Anchor the substitution; do not trust the corpus

§2.4 shows no body text currently contains `Speaker`. That is an observation
about four files, not an invariant — a huddle that discusses this very tool
will say "speaker 2 is Dave" in the body. A bare `sed 's/Speaker 1/Andrew/g'`
would corrupt it.

The substitution must apply **only to lines matching `^Speaker [0-9]+$` in
full**, leaving every other line byte-identical:

```bash
awk -v map="$MAPPING" '
  /^Speaker [0-9]+$/ { ... substitute ... ; print; next }
  { print }
'
```

Body text is then untouchable by construction.

### 5.2 Idempotency and re-running

Once `Speaker 1` becomes `Andrew`, the anchor no longer matches it. So:

- Re-running with a new mapping cannot re-map an already-named label.
- The **sidecar mapping is authoritative**, not the file. To change `Andrew` to
  `Andy`, the tool reads the existing mapping, computes the current on-disk
  label for each speaker, and substitutes from that. This makes the operation
  idempotent and `--revert` trivial.
- Anchoring for already-named labels must match the *stored* name, exactly and
  in full (`^Andrew$`), for the same reason as §5.1.

A name that is itself of the form `Speaker 4` must be rejected at input
validation; so must a name containing a newline. Both would make the file
unparseable on the next pass.

### 5.3 Atomic write

Identical to the existing pattern (`huddle-transcribe:565-587`): build the new
transcript and the new sidecar as temp files **beside their targets**, verify
both non-empty, then perform two same-directory renames with nothing fallible
between them. `mktemp` beside the target rather than in `$TMPDIR` keeps the
rename atomic when `OUTPUT_DIR` is on another volume — which it is here, since
output lands in Google Drive.

Note the Google Drive path specifically: `OUTPUT_DIR` is under
`~/Library/CloudStorage/GoogleDrive-.../My Drive/Slack transcripts`. A
File Provider mount can make `rename(2)` behave unlike a local volume, and can
resurrect or re-sync a file mid-write. Worth an explicit manual test (§8) even
though the pattern is already the repo's.

### 5.4 The transcript/sidecar pair must not desynchronize

If the transcript rename succeeds and the sidecar rename does not, the file
says `Andrew` while the mapping says nothing — and `--revert` can no longer
restore it. Order the two renames **sidecar first, then transcript**: a
sidecar naming speakers the transcript has not yet renamed is recoverable (a
re-run completes it), whereas the reverse is not.

This is the opposite order from `huddle-transcribe:586-587`, and deliberately
so — there, the transcript is the artifact and the sidecar is the permission
slip, so the transcript lands first. Here the sidecar is the undo record.

### 5.5 Interaction with `--mark-reviewed`

`--mark-reviewed` verifies `sidecar.session_id == $SID` and that the transcript
is non-empty (`huddle-transcribe:420-441`). Renaming speakers changes neither.
Confirm in testing that a renamed transcript still passes all four fences, and
that this tool never runs against a session whose source audio is already
deleted — it does not need the audio, so it should work fine, but it should be
tested rather than assumed.

---

## 6. Worked example

For the transcript that prompted this, the speakers are distinguishable from
context alone:

- **Speaker 1** runs the huddle, owns the Keycloak upgrade and the
  contractor-access policy work, says "I'll go first" while moving cards.
- **Speaker 2** reports who is absent; cold brew, french press.
- **Speaker 3** joins with "monster energy for me."

Note that the transcript also names **Chris** and **Matt** — both explicitly
*absent* ("Chris said he has to talk to the mechanic"; "I don't know where Matt
is"). A naive suggester would map those names onto present speakers and be
confidently wrong. Any future option-2 implementation must handle
mentioned-but-absent people; this example is a good regression fixture for it.

---

## 7. Companion fix

Reword `huddle-transcribe:550-552`. Current logic warns only when no `Speaker`
label is found. Keep that check — it is a valid diarization smoke test — but
stop implying that finding generic labels is the finished state. Suggested:

> `Note: transcript has generic speaker labels. Run huddle-name-speakers to attribute names.`

emitted when labels are present and the sidecar has no `speaker_names`, with
the existing "no labels found — check speaker detection" warning retained for
the genuinely-undiarized case.

---

## 8. Test plan

`tests/run-tests.sh` builds a synthetic SQLite DB plus a stub `mw` and
repoints `DB`/`MEDIA_DIR`/`MW_BIN`/`CONFIG_FILE`. Extend the same fixture; the
stub `mw` should gain a canned diarized transcript to rename.

Behavioral cases:

1. Single mapping rewrites only matching label lines.
2. Body text containing the literal string `Speaker 2` is left untouched. *(§5.1)*
3. Partial mapping: unnamed labels stay generic. *(§2.2)*
4. Double-digit labels — verify `Speaker 1` does not match inside `Speaker 10`.
   The `$`-anchor handles this, but it is exactly the bug that anchoring
   exists to prevent, so assert it.
5. Idempotency: running the same mapping twice is a no-op.
6. Re-map an already-named speaker via the sidecar. *(§5.2)*
7. `--revert` restores byte-identical generic labels.
8. `--dry-run` changes neither file.
9. Rejects a name matching `^Speaker [0-9]+$`, and a name with a newline.
10. Absent `speaker_names` vs. `{}` are distinguished. *(§4.2)*
11. Sidecar write failure leaves the transcript untouched. *(§5.4)*
12. A renamed transcript still passes all four `--mark-reviewed` fences. *(§5.5)*
13. Missing/malformed sidecar is an error, not a silent generic rewrite.

Manual, outside the suite:

- Run against the real Google Drive `OUTPUT_DIR` and confirm the rename is
  atomic and File Provider does not resurrect the pre-rename file. *(§5.3)*
- Run against the 18-speaker weekly-pulse transcript and confirm
  `--interactive` stays usable across a long tail of one-utterance speakers,
  and that abandoning it partway still leaves a valid partial mapping. *(§2.2)*

Before commit, per `CLAUDE.md`: `./tests/run-tests.sh`, then
`shellcheck -S info` and `shfmt -i 2 -ci -d` over all four scripts — the new
script included. CI discovers scripts by shebang, so `huddle-name-speakers`
is picked up automatically once it is executable with a bash shebang; the
exec-bit check in `lint.yml` will fail it otherwise.

---

## 9. Implementation order

Each step is independently committable and leaves the repo green.

| Step | Change | Notes |
|---|---|---|
| 1 | Sidecar schema: document `speaker_names`, teach readers that absent means never-named | No behavior change; unblocks the rest |
| 2 | `huddle-name-speakers` with `--list` and `--dry-run` only | Read-only; safe to iterate on target resolution |
| 3 | `--set` + the anchored atomic rewrite | The data-loss surface. Tests 1-5, 8-11, 13 land with it |
| 4 | `--revert` and sidecar-authoritative re-mapping | Tests 6, 7 |
| 5 | `--interactive` | Pure UX over step 3 |
| 6 | Reword the `huddle-transcribe` warning *(§7)* | One-line change |
| 7 | README: replace "ready for a follow-up pass" with the real workflow | Closes the gap this document opened with |

Step 3 is the one that can destroy a transcript. It should get its own commit
and its own adversarial review pass, per `CLAUDE.md`'s note that the linters
pass on every data-loss bug this repo has had.

---

## 10. Open questions

1. **Should `huddle-watch` invoke this automatically?** It cannot name anyone
   unattended, so probably not. A plausible middle path: the watcher logs that
   a new transcript has unnamed speakers, so it surfaces in `--status` rather
   than being silently forgotten. Deferred until the manual tool has been used
   a few times.
2. **Is a per-session mapping enough, or is a roster wanted?** §2.1 rules out a
   global label mapping, but a `~/.config/huddle-transcribe/roster` of known
   colleague names would help `--interactive` offer completions and would
   constrain a future suggester (§2.3). Note the config file is deliberately
   *parsed*, never sourced — a roster must not become an excuse to switch to
   `source`.
3. **Backfill?** Four transcripts exist already. Once step 4 lands, naming
   them is a few minutes of work and would validate the tool against real
   files. Optional.
