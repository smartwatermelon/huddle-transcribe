---
name: huddle-review
description: >
  Turn a finished huddle-transcribe transcript into a synthesized knowledge-base
  note and register it. Use when the user says a transcript is ready, or asks to
  import, read, analyze, review, or index a meeting transcript. Reads the raw
  transcript plus its .meta.json sidecar, attributes generic Speaker N labels,
  writes a note, and updates the KB registry. Not triggered by a request for a
  morning brief or a schedule question — those only read a transcript, they do
  not index one.
---

# Huddle Review

A transcript is source material. This skill produces the thing that gets read
later: a synthesized note, registered where a future reader will find it.

## Configuration

Settings come from `~/.config/huddle-transcribe/config`, the same file
`huddle-transcribe` reads. Five keys matter here; all are optional.

| Key | Default |
| --- | --- |
| `OUTPUT_DIR` | resolved by the script; ask it, do not guess (see step 1) |
| `KB_ROOT` | the parent directory of `OUTPUT_DIR` |
| `KB_NOTES_DIR` | `$KB_ROOT/topics/meetings` |
| `KB_INDEX` | `$KB_ROOT/INDEX.md` |
| `RELEASE_AUDIO` | `ask`; `auto` releases the audio without asking (see step 6) |

Read the file with the Read tool and match `^KEY=` lines literally. **Never
source it and never pass it to a shell.** It is user-editable text, and the
script deliberately parses rather than sources it so a config file cannot
execute code. Honor that here. A leading `~` arrives literally and means
`$HOME`; expand only that. Take every other value exactly as written.

The script itself honors only `OUTPUT_DIR`. The other four keys are read by
this skill. If a key is absent, use the default in the table — do not invent a
layout, and do not write outside `KB_ROOT`.

If `KB_ROOT` does not resolve to a directory that exists, stop and say so.
Creating a knowledge base is not this skill's job.

## Steps

### 1. Resolve the transcript

Ask the tool rather than reconstructing a filename:

```bash
huddle-transcribe --dry-run <session-id-or-date>
```

It prints `Title:`, `Duration:`, `Source:`, and `Output:` and changes nothing.
`Output:` is the transcript path. With no argument it resolves the most recent
session, which is the common case right after a meeting.

Prefer a **session id** over a date. A date with two recordings silently
resolves to the most recent one.

Then read the `.meta.json` sidecar beside the transcript. It carries the
authoritative `title`, `duration_seconds`, and `session_id`, and sometimes a
`trimmed_note` recording that a tail of the recording was cut. A
`trimmed_note` changes what the duration means — say so in the note.

### 2. Check the transcript is real before spending effort on it

Whisper transcribes silence as a short phrase repeated at intervals — "Thank
you.", "Sigh." — for the full length of the recording. The file looks
plausible and is worthless.

Count distinct non-timestamp lines. A few unique lines spread across many
minutes is silence, not content. **Stop and report it.** Do not write a note,
and do not offer to mark the session reviewed: the audio is the only remaining
copy, and the user may want to re-transcribe or listen to it.

### 3. Read it in full, then attribute the speakers

Labels are `Speaker 1`, `Speaker 2`, … and carry no identity. Two facts from
`docs/plans/speaker-name-attribution.md`, which are easy to get wrong:

- **Numbering is per-meeting.** Diarization assigns labels in order of first
  utterance, so `Speaker 2` in one meeting is a different person in the next.
  Never carry a mapping across transcripts.
- **Frequency does not identify anyone.** Common first names are ordinary
  English words, so counting tokens produces confident nonsense.
- **A stitched transcript restarts numbering in each part.** MacWhisper can
  split one meeting into several recordings. The transcript then opens with
  `> **Note:** joined from N recordings of one meeting` and has one
  `## Part i of N` heading per recording, and `Speaker 1` in part 2 need not
  be `Speaker 1` in part 1. Attribute each part on its own. A part can have
  no speaker labels at all, be only a note that it was not transcribed, or
  be absent, named in a closing note as not ready yet; say so in the note
  rather than guess.

Attribute from direct address in the transcript ("thanks, X", "X, can you") and
from who owns the work being described. **State in the note that attribution is
inferred**, and record any name the transcriber consistently misspells, since
that misspelling is what a future search will hit.

Leave a one-line speaker generic rather than guessing. A wrong name is worse
than `Speaker 7`.

### 4. Write the note

One note per meeting, in `KB_NOTES_DIR`. Match the frontmatter of existing
notes in that directory; read one first. A typical shape:

```markdown
---
id: YYYYMMDD-short-slug
title: "Meeting Name — Mon DD YYYY"
tags: [meetings, ...]
created: YYYY-MM-DD
updated: YYYY-MM-DD
source: ../../transcripts/<transcript filename>
---
```

Take tags **only** from the controlled vocabulary in `KB_INDEX`. Read that list
before choosing; add a new tag to the vocabulary before using it, or use none.

Synthesize. Capture decisions and who made them, root causes, owners, and what
is still open. A reader should not need the transcript afterward. Do not paste
transcript text. Record things that were explicitly deferred, and by whom — a
deferral is a decision.

**If a note for this transcript already exists**, edit it in place and bump
`updated`. Check by searching `KB_NOTES_DIR` for a `source:` line naming this
transcript. Do not create a second note for one meeting.

### 5. Register it

A note nobody can find is not done. In the same change:

1. Add a line to the registry in `KB_INDEX`, matching the surrounding format.
2. Add the note to its topic index (commonly `_topic.md` beside the note).

Both, every time. A KB that requires a full-text scan to find a note has lost
the thing the index was for.

**Never edit `transcripts/_index.md`.** It is generated by `huddle-transcribe`
and carries a header saying so; the next run overwrites any edit. The new
transcript is already listed there.

### 6. Release the audio

```bash
huddle-transcribe --mark-reviewed <session-id>
```

**This deletes the source `.m4a`**: to the Trash where `trash(1)` exists,
otherwise outright. Pass the **session id**, not the date, for the reason in
step 1.

Only after the note exists **and** is registered (step 5). Never after
step 2 stopped on a silence transcript: there the audio is the only useful
copy.

While the sidecar has `"restitchable": true` and is not reviewed,
`huddle-watch` replaces the transcript in place if a later recording of the
same meeting lands. Marking it reviewed stops that; a later piece then goes
to a new `-2` transcript instead. If the user keeps the audio, say that the
note may need updating should a later part arrive.

A transcript that ends with `> **Note:** this transcript may be incomplete`
(its sidecar has `pending_session_ids`) is missing a part MacWhisper had
not finished. Say so in the note, and say that marking it reviewed now
sends that part to a separate `-2` transcript when it arrives.

What happens next depends on `RELEASE_AUDIO`:

- **`ask`, absent, or any other value:** offer it as a question. Say plainly
  that it deletes the audio. Never run it unprompted, never bundle it into
  another step, and never add `--yes` on the user's behalf. If the user
  declines, the transcript and audio both stay. That is a valid end state.
- **`auto`:** the user has already said yes, once, in their own config. Run it
  with `--yes` as the last step, then report the path the script says it
  removed. If the script refuses (a sidecar or session-id guard fails), report
  the refusal as it is. Do not work around it.

## Boundaries

- Read the transcript; never edit it. It is the record of what was said.
- Write only inside `KB_ROOT`.
- Deleting audio requires an explicit yes: every time, or once as
  `RELEASE_AUDIO=auto` in the config. Nothing else counts as a yes.
- If something in the transcript is ambiguous, say so in the note rather than
  resolving it silently. A note that marks its own uncertainty stays useful;
  one that guesses confidently does not.
