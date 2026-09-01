# Findings: bash 4+ scripts on macOS launch surfaces

**Date:** 2026-09-01
**Origin:** `huddle-watch` produced no transcript for the 08:00 Slack huddle.
Root cause was not the script's logic but the interpreter launchd selected.
**Fixed in:** smartwatermelon/huddle-transcribe#8
**Scope of this audit:** `~/.claude`, `~/Developer/claude-config`,
`~/Developer/dotfiles`, `~/Developer/scripts`, `~/.local/bin`, `~/.config`,
plus work repos under `~/Developer/beacon-biosignals`. 338 shell scripts, 262
with a bash shebang.

---

## 1. The mechanism

`#!/usr/bin/env bash` is not a declaration of "run me with bash." It is a
declaration of "run me with whatever `bash` the ambient `PATH` points at." That
is not a dependency — it is an unbound variable resolved at exec time by an
environment you do not control.

On this machine:

| Path | Version |
|---|---|
| `/bin/bash` | **3.2.57** (Apple; never updated) |
| `/opt/homebrew/bin/bash` | **5.3.15** |
| `/usr/local/bin/bash` | absent |

Interactive shells and CI have Homebrew on `PATH`, so `env bash` finds 5.3 and
everything works. launchd, cron, and GUI-spawned processes get a minimal `PATH`
with no Homebrew, so `env bash` finds 3.2.

**Why this class of bug survives every local check:**

- `bash -n` **passes** on all of it. Verified: `bash -n lint-shell.sh` under
  3.2 exits 0 despite `declare -A` on line 5. Bash 4 features are runtime
  errors, not parse errors.
- `shellcheck` does not flag them by default (it targets the declared shell,
  and assumes a modern bash).
- The test suite runs under your shell's bash 5.
- CI runs bash 5.

So the only environment that reproduces the failure is the one with no human
watching. `huddle-watch` failed silently for three days.

### Why `chsh` does not help

Setting Homebrew bash as your login shell has no effect here. launchd does not
read your login shell, does not source your profile, and does not inherit your
interactive `PATH`. `launchctl config user path` can set a global launchd
`PATH`, but it needs `sudo`, requires a reboot, and is global mutable state
affecting every job on the box.

---

## 2. The fix pattern

**The launcher is responsible for the interpreter, not the script.**

Three layers. Apply all three; each covers what the others miss.

### Layer 1 — the launcher names the interpreter (primary)

For launchd, `ProgramArguments[0]` is an absolute bash and the script is `[1]`:

```json
"ProgramArguments": ["/opt/homebrew/bin/bash", "/path/to/script", "--once"]
```

When argv[0] is an interpreter the kernel never reads the shebang, so `PATH`
becomes irrelevant. The ambiguity is gone **by construction**, not by defense.

Equivalents:

| Surface | Fix |
|---|---|
| launchd | `ProgramArguments[0]` = absolute bash |
| cron | `SHELL=/opt/homebrew/bin/bash` in the crontab |
| systemd | `ExecStart=/path/to/bash /path/to/script` |
| pre-commit `entry:` | pin the absolute path instead of bare `bash` |

### Layer 2 — resolve that path at install time, never hardcode it

A literal `/opt/homebrew/bin/bash` in a tracked file is wrong on Intel
(`/usr/local`), Linuxbrew, and in containers. Resolve it in the installer,
which runs **on the target machine**, and write the answer into the generated
plist — untracked, machine-local state, which is the correct home for a
machine-specific absolute path.

Use `$BASH`: the absolute path of the interpreter currently executing the
installer. Free, exact, no `PATH` search, no version parsing. If the version
guard (layer 3) has already run, reaching the installer proves that interpreter
is adequate.

```bash
resolve_interpreter() {
  if [[ -n "${BASH:-}" && -x "$BASH" ]]; then
    printf '%s\n' "$BASH"
    return 0
  fi
  echo "Error: cannot determine the path of the running bash." >&2
  return 1
}
```

**Keep the tracked shebang as `#!/usr/bin/env bash`.** That is what keeps
interactive use and CI portable. The absolute path belongs only in generated
artifacts.

### Layer 3 — a version guard in the script (backstop)

Covers every invocation path a launcher fix does not: manual runs, `bash
script.sh`, other people's tooling, a stale plist.

```bash
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2))); then
  printf 'Error: %s requires bash 4.2 or newer; running under %s (%s).\n' \
    "${BASH_SOURCE[0]##*/}" "${BASH_VERSION:-unknown}" "${BASH:-unknown}" >&2
  printf 'macOS ships bash 3.2 at /bin/bash. Install a current bash (brew install bash).\n' >&2
  exit 1
fi
```

Both `BASH_VERSINFO` and `(( ))` exist since bash 2.x, so the guard itself runs
under 3.2 — that property is what makes it work, and is worth preserving.

Set the minor version to what the script actually needs (table in §5). Place it
**above the first use** of any bash 4 feature.

### A trap worth knowing: reinstall does not replace a loaded job

`launchctl bootstrap` fails when the label is already loaded, and the legacy
`launchctl load` fallback does **not** replace a loaded job either. A reinstall
prints "Loaded" while launchd keeps running the **old** argv — so a plist you
just corrected goes on failing, and `launchctl print` looks healthy.

```bash
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
```

This cost real debugging time on #8. The corrected plist was on disk and the
job still ran bash 3.2.

---

## 3. Findings, ranked

### P1 — `dotfiles/bash/gh-wrapper.sh` (confirmed broken under 3.2, no guard)

The only finding with a reproduced end-to-end failure.

| Line | Feature | Requires |
|---|---|---|
| 176, 215, 394 | `${owner,,}` case modification | 4.0 |
| 458, 533 | `mapfile -t -d ''` | 4.4 |

Reproduced:

```
$ /bin/bash gh-wrapper.sh pr create --title x
gh-wrapper.sh: line 215: ${owner,,}: bad substitution
rc=1
```

**It fails closed — verified.** Under 3.2 it dies at line 215 with rc=1 and
never reaches a real `gh` invocation, so off-org draft-forcing and the
REST/GraphQL merge bypass guards are **not** circumvented. Both `mapfile` call
sites additionally have an explicit truncation check
(`[[ ${#_new_args[@]} -lt $# ]]` → refuse) and standalone mode sets
`set -euo pipefail`. This is breakage, not a security hole.

Why it still matters most: the wrapper's own header names "LaunchAgents/cron
with a stripped environment" as a target use case — exactly where 3.2 gets
picked. It is reachable three ways: the `~/.local/bin/gh` PATH shim, `BASH_ENV`
(`~/.config/bash/functions.sh:1037` sources it into **every** non-interactive
bash Claude Code spawns), and directly.

**Fix:** add a 4.4 guard. Needs bash 4.4 for `mapfile -d`, the highest
requirement in the reachable set.

### P2 — unguarded bash 4.3+ libraries reached by global git hooks

`core.hooksPath = ~/.config/git/hooks`. `commit-msg` and `pre-push` invoke
`~/.claude/hooks/run-review.sh`, which sources:

| File | Line | Feature | Requires |
|---|---|---|---|
| `claude-config/hooks/lib-review-issues.sh` | 183–186, 201 | `local -n` nameref | 4.3 |
| `claude-config/hooks/lib-review-context.sh` | 114, 115 | `${rounds[-1]}` negative index | 4.3 |

Safe **today**: git honors the shebang and `env bash` currently resolves to
5.3. No guard anywhere in the chain, including `run-review.sh`. These are the
newest requirements in the reachable set, so they break first if `PATH` ever
thins.

**Fix:** one 4.3 guard in `run-review.sh` covers both, since it is the entry
point that sources them.

### P3 — `claude-config/scripts/hook-block-git-worktree.sh`

`mapfile` at line 339 (bash 4.0). Reachable from `settings.json` PreToolUse via
`hook-block-all.sh:21`. Safe today because `CLAUDE_CODE_SHELL` is pinned to
`/opt/homebrew/bin/bash` — that pin is load-bearing and should not be removed.
No guard.

### P4 — `dotfiles/git/hooks/lint-shell.sh`

`declare -A` at lines 5–6 (bash 4.0). No guard.

**Correcting an initial reading:** the pre-commit entries at
`claude-config/.pre-commit-config.yaml:38` and
`dotfiles/pre-commit/config.yaml:82` use
`entry: bash -c '$HOME/.config/git/hooks/lint-shell.sh "$@"' --`. That bare
`bash` is a `PATH` lookup, but it does **not** discard the inner script's
shebang, because the script is invoked as a command rather than as a source
file. Verified:

```
$ /bin/bash -c /tmp/probe.sh
inner ran under: 5.3.15(1)-release
```

So the exposure is only via `env bash` resolving to 3.2, same as every other
script here — not a separate structural hole. Still worth a guard; pinning the
`entry:` path is optional hardening, not a fix for a live bug.

### P5 — interactive-only, no launch surface

- `Developer/scripts/smb-mount.sh` — `${byte^^}` line 97 (4.0). Run manually.
- `beacon-biosignals/infra/bin/terratest-prune.sh` — `mapfile` line 25.
- `beacon-biosignals/platform-production/.github/bin/check-automerge-platform-pr.sh`
  — `mapfile` lines 65, 114. Both run in CI on Linux/bash 5.
- `beacon-biosignals/infra/bin/utils.sh` — has a `BASH_VERSINFO` check at
  108–112 that only **warns**; it does not exit. Worth upgrading to a gate.
- `dotfiles/bash/tests/test-gh-wrapper-draft-off-org.sh` — `mapfile -d`,
  `${arr[*]@Q}` (4.4). No in-file guard; relies on `run-tests.sh:46`.

### Already correct — no action

| File | Guard |
|---|---|
| `huddle-transcribe/huddle-watch` | 4.2 gate + absolute interpreter in plist (**the model**) |
| `claude-config/scripts/update-tools.sh` | line 9, bash 5 gate, `exit 0` |
| `dotfiles/bash/tests/run-tests.sh` | line 46, 4.4 gate |
| `dotfiles/.project-hooks/pre-push` | line 23, 4.4 gate |

### Launch-surface inventory

- **crontab:** empty (`no crontab for arich`). Nothing to fix.
- **`~/Library/LaunchAgents`** (6 plists): only `huddle-transcribe.watch` runs a
  shell script, and it is now correct. The other five (3× Grammarly, Synergy,
  logrotate) exec compiled binaries.
- **`/Library/LaunchAgents` + `/Library/LaunchDaemons`:** root-owned, no shell
  scripts. `com.docker.socket` and `com.symless.synergy-agent` mention `arich`
  only as a string argument.
- **Uninstalled template** `Developer/scripts/LaunchAgents/com.asiago.break-watcher.plist`
  → `["/Users/andrewrich/.local/bin/break-watcher.sh"]`. Bare script as argv[0],
  and the path is for a different machine. `break-watcher.sh` uses no bash 4
  features, so harmless — but fix argv[0] before ever installing it.
- **Automator / Shortcuts:** none found.
- **Empty categories:** no script in scope uses `coproc`, `&>>`, `;;&`/`;&`,
  `wait -n`, `[[ -v ]]`, `${!prefix@}`, `readarray`, or `declare -n`. None of
  the five `#!/bin/bash` scripts uses any bash 4 feature.

---

## 4. Batch-fix procedure

Ordered by risk. P1 first — it is the only confirmed live breakage.

**Step 1 — P1, `gh-wrapper.sh`.** Add a 4.4 guard above line 176. Verify with
`/bin/bash gh-wrapper.sh --version`: expect the guard message, not `bad
substitution`. Confirm normal operation still works via `gh --version`.

**Step 2 — P2, `run-review.sh`.** Add a 4.3 guard. This is a git-hook path, so
test by making a real commit on a throwaway branch.

**Step 3 — P3/P4.** Add 4.0 guards to `hook-block-git-worktree.sh` and
`lint-shell.sh`.

**Step 4 — P5.** Upgrade `utils.sh`'s warn to a gate; guard `smb-mount.sh`.

**Step 5 — audit every plist you own** for a bare script as argv[0]. A
non-interpreter argv[0] only matters when it resolves to a *script*; a compiled
binary is fine, so this filters on `file` output rather than flagging all five
of your app-installed agents as noise:

```bash
for p in ~/Library/LaunchAgents/*.plist; do
  pa0=$(plutil -extract ProgramArguments.0 raw -o - "$p" 2>/dev/null) ||
    pa0=$(plutil -extract Program raw -o - "$p" 2>/dev/null) || continue
  case "$pa0" in
    */bash | */sh | */zsh | */python* | */perl* | */ruby*)
      printf 'OK      %-46s %s\n' "$(basename "$p" .plist)" "$pa0"
      continue
      ;;
  esac
  # Flag only if argv[0] is a TEXT file (a script). A compiled binary is fine.
  if [[ -f "$pa0" ]] && file -b "$pa0" 2>/dev/null | grep -qiE 'text|script'; then
    printf 'FIX     %-46s %s\n' "$(basename "$p" .plist)" "$pa0"
  fi
done
```

Current output on this machine is one line — `OK
com.smartwatermelon.huddle-transcribe.watch /opt/homebrew/bin/bash`. Validated
against a synthetic plist naming a bare script, which it correctly reports as
`FIX`; a clean result from an unvalidated check proves nothing.

**Step 6 — after any plist change, force a real reload** (`bootout` then
`bootstrap`; see §2), then confirm:

```bash
launchctl print "gui/$(id -u)/<LABEL>" | grep -A4 arguments
```

Check the **in-memory** argv, not the file on disk. This is the step that
catches a reinstall that claimed success and changed nothing.

### Verification that a guard actually works

Always test against the known-bad case. macOS keeps a real bash 3.2 at
`/bin/bash`, so this is a true negative control, not a simulation:

```bash
/bin/bash ./script.sh --some-flag   # expect the guard message, exit 1
```

A guard you have only tested under bash 5 is untested. Pick the probe path with
care — in `huddle-watch`, `--status` never calls `log()` and a first `--once`
returns before logging, so both would have passed against the broken script.
The probe must reach the code that uses the bash 4 feature.

### Making it stick

- A regression test that asserts the generated plist names an absolute bash,
  and that the recorded interpreter satisfies the version requirement.
- Where a suite skips for a missing precondition (no bash < 4.2 on Linux CI),
  count skips **separately**. A skip reported as a pass is a false green.
- Consider a repo-wide check: grep for the bash 4 markers in §5 and require a
  `BASH_VERSINFO` guard in any file that hits one.

---

## 5. Reference: feature → minimum version

Used to pick the right minor version for each guard.

| Feature | Min |
|---|---|
| `declare -A` associative arrays | 4.0 |
| `${var,,}` `${var^^}` case modification | 4.0 |
| `mapfile` / `readarray` | 4.0 |
| `&>>` append stdout+stderr | 4.0 |
| `coproc` | 4.0 |
| `;;&` and `;&` in `case` | 4.0 |
| `printf '%(fmt)T'` | 4.2 |
| `[[ -v var ]]` | 4.2 |
| `declare -n` / `local -n` nameref | 4.3 |
| `${arr[-1]}` negative index | 4.3 |
| `wait -n` | 4.3 |
| `mapfile -d` custom delimiter | 4.4 |
| `${var@Q}` parameter transformation | 4.4 |

macOS `/bin/bash` is **3.2.57** and supports none of these.
