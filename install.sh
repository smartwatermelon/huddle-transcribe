#!/usr/bin/env bash
# install.sh: link this checkout's scripts and skill, and install the
# huddle-watch LaunchAgent (#43). Safe to re-run; --uninstall reverses it.
set -euo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

BIN_DIR="${HUDDLE_BIN_DIR:-$HOME/.local/bin}"
SKILLS_DIR="${HUDDLE_SKILLS_DIR:-$HOME/.claude/skills}"
# Run from the checkout, not the ~/.local/bin link: huddle-watch writes its
# own path into the plist. Tests replace both with stubs.
WATCH_BIN="${HUDDLE_WATCH_BIN:-$SELF_DIR/huddle-watch}"
LAUNCHCTL="${HUDDLE_LAUNCHCTL_BIN:-launchctl}"

SCRIPTS=(huddle-transcribe huddle-watch)

# huddle-mic-guard was retired on 2026-10-15. An older install may still
# have its link and its LaunchAgent; both are cleaned up on every run.
RETIRED_SCRIPT="huddle-mic-guard"
RETIRED_LABEL="com.smartwatermelon.huddle-transcribe.mic-guard"
RETIRED_PLIST="$HOME/Library/LaunchAgents/${RETIRED_LABEL}.plist"
SKILL_NAME="huddle-review"
SKILL_SRC="$SELF_DIR/skills/$SKILL_NAME"
SKILL_DEST="$SKILLS_DIR/$SKILL_NAME"

UNINSTALL=0

usage() {
  cat <<'EOF'
Usage: install.sh [OPTIONS]

Links huddle-transcribe and huddle-watch into ~/.local/bin, links the
huddle-review skill's files into ~/.claude/skills/huddle-review/, runs
huddle-watch --install, and ends with huddle-watch --status. Files are
linked, not copied, so edits in this checkout take effect immediately.

Safe to re-run. A link that points elsewhere is replaced; a real file in
the way is never overwritten, and nothing is changed when one is found.
Leftovers of the retired huddle-mic-guard (its link into this checkout and
its LaunchAgent) are removed.

Options:
  --uninstall           Run huddle-watch --uninstall, and remove only the
                        links that point into this checkout
  -h, --help            Show this help

Environment overrides (chiefly for testing):
  HUDDLE_BIN_DIR        Where the script links go (default ~/.local/bin)
  HUDDLE_SKILLS_DIR     Claude Code skills directory (default ~/.claude/skills)
  HUDDLE_WATCH_BIN      huddle-watch to run for --install, --uninstall and
                        --status (default: the one in this checkout)
  HUDDLE_LAUNCHCTL_BIN  launchctl to use for the retired agent's bootout
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      echo "Error: unexpected argument '$1' (install.sh takes options only)" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Every regular file in the skill dir, each linked into a REAL directory
# (#36), not the directory itself.
SKILL_FILES=()
for f in "$SKILL_SRC"/*; do
  [[ -f "$f" ]] || continue
  SKILL_FILES+=("${f##*/}")
done
unset f

# link_state <path> <want>: LINK_STATE is ok, stale, missing or blocked (a
# real file). readlink, not -f: -f hid the per-file links in #36.
LINK_STATE=""
LINK_TARGET=""
link_state() {
  local path="$1" want="$2"
  LINK_TARGET=""
  if [[ -L "$path" ]]; then
    LINK_TARGET=$(readlink -- "$path")
    if [[ "$LINK_TARGET" == "$want" ]]; then
      LINK_STATE=ok
    else
      LINK_STATE=stale
    fi
  elif [[ -e "$path" ]]; then
    LINK_STATE=blocked
  else
    LINK_STATE=missing
  fi
}

# link <src> <dest>: create or repair one link. The caller has already
# refused every `blocked` destination.
link() {
  local src="$1" dest="$2"
  link_state "$dest" "$src"
  case "$LINK_STATE" in
    ok)
      echo "Linked:    $dest (already)"
      ;;
    stale)
      echo "Relinked:  $dest (was -> $LINK_TARGET)"
      rm -f -- "$dest"
      ln -s -- "$src" "$dest"
      ;;
    missing)
      echo "Linked:    $dest"
      ln -s -- "$src" "$dest"
      ;;
    *)
      echo "Error: $dest is a real file; refusing to overwrite it." >&2
      exit 1
      ;;
  esac
}

# unlink_ours <dest> <src>: remove <dest> only when it is a link to <src>, a
# file in this checkout. Anything else is reported and left alone.
unlink_ours() {
  local dest="$1" src="$2"
  link_state "$dest" "$src"
  case "$LINK_STATE" in
    ok)
      rm -f -- "$dest"
      echo "Removed:   $dest"
      ;;
    stale)
      echo "Left:      $dest (links to $LINK_TARGET, not this checkout)"
      ;;
    blocked)
      echo "Left:      $dest (not a link)"
      ;;
    *) ;;
  esac
}

on_path() {
  case ":$PATH:" in
    *":$BIN_DIR:"* | *":$BIN_DIR/:"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Remove an old mic-guard link into this checkout and its LaunchAgent. A
# failed bootout just means it was not loaded.
retire_mic_guard() {
  unlink_ours "$BIN_DIR/$RETIRED_SCRIPT" "$SELF_DIR/$RETIRED_SCRIPT"
  [[ -f "$RETIRED_PLIST" ]] || return 0
  local uid
  uid=$(id -u)
  if "$LAUNCHCTL" bootout "gui/$uid/$RETIRED_LABEL" 2>/dev/null; then
    echo "Unloaded:  LaunchAgent $RETIRED_LABEL (retired)"
  fi
  rm -f -- "$RETIRED_PLIST"
  echo "Removed:   $RETIRED_PLIST (retired)"
}

do_uninstall() {
  "$WATCH_BIN" --uninstall
  retire_mic_guard
  local name
  for name in "${SCRIPTS[@]}"; do
    unlink_ours "$BIN_DIR/$name" "$SELF_DIR/$name"
  done
  # The old README linked the skill directory itself. Remove that form too,
  # but only when it points at this checkout's skill.
  if [[ -L "$SKILL_DEST" ]]; then
    unlink_ours "$SKILL_DEST" "$SKILL_SRC"
    return 0
  fi
  [[ -d "$SKILL_DEST" ]] || return 0
  for name in "${SKILL_FILES[@]}"; do
    unlink_ours "$SKILL_DEST/$name" "$SKILL_SRC/$name"
  done
  # Only an empty directory is removed: anything left in it is not ours.
  local leftover
  leftover=$(ls -A -- "$SKILL_DEST")
  if [[ -z "$leftover" ]]; then
    rmdir -- "$SKILL_DEST"
    echo "Removed:   $SKILL_DEST/"
  else
    echo "Left:      $SKILL_DEST/ (not empty)"
  fi
}

do_install() {
  local name
  for name in "${SCRIPTS[@]}"; do
    if [[ ! -x "$SELF_DIR/$name" ]]; then
      echo "Error: $SELF_DIR/$name is missing or not executable; run install.sh from a full checkout." >&2
      exit 1
    fi
  done
  if [[ ${#SKILL_FILES[@]} -eq 0 ]]; then
    echo "Error: no skill files found in $SKILL_SRC." >&2
    exit 1
  fi

  # Check every destination first, so a refusal changes nothing.
  local blocked=()
  for name in "${SCRIPTS[@]}"; do
    link_state "$BIN_DIR/$name" "$SELF_DIR/$name"
    [[ "$LINK_STATE" != blocked ]] || blocked+=("$BIN_DIR/$name")
  done
  if [[ -L "$SKILL_DEST" ]]; then
    : # the old directory-link form; replaced below
  elif [[ -d "$SKILL_DEST" ]]; then
    for name in "${SKILL_FILES[@]}"; do
      link_state "$SKILL_DEST/$name" "$SKILL_SRC/$name"
      [[ "$LINK_STATE" != blocked ]] || blocked+=("$SKILL_DEST/$name")
    done
  elif [[ -e "$SKILL_DEST" ]]; then
    blocked+=("$SKILL_DEST")
  fi
  if [[ ${#blocked[@]} -gt 0 ]]; then
    echo "Error: refusing to overwrite these real files (not links):" >&2
    printf '  %s\n' "${blocked[@]}" >&2
    echo "Move them aside and re-run. Nothing was changed." >&2
    exit 1
  fi

  mkdir -p -- "$BIN_DIR"
  for name in "${SCRIPTS[@]}"; do
    link "$SELF_DIR/$name" "$BIN_DIR/$name"
  done

  # Replace the old directory-link form with a real dir. Plain rm of the
  # link leaves its target alone.
  if [[ -L "$SKILL_DEST" ]]; then
    link_state "$SKILL_DEST" "$SKILL_SRC"
    echo "Replaced:  $SKILL_DEST (directory link -> $LINK_TARGET)"
    rm -f -- "$SKILL_DEST"
  fi
  mkdir -p -- "$SKILL_DEST"
  for name in "${SKILL_FILES[@]}"; do
    link "$SKILL_SRC/$name" "$SKILL_DEST/$name"
  done

  retire_mic_guard

  # huddle-watch owns its plist generation; this only drives it.
  "$WATCH_BIN" --install

  if ! on_path; then
    echo
    echo "Warning: $BIN_DIR is not on PATH, so the commands above will not be found." >&2
    echo "Add it in your shell profile, e.g.: export PATH=\"$BIN_DIR:\$PATH\"" >&2
  fi

  echo
  "$WATCH_BIN" --status
}

if [[ $UNINSTALL -eq 1 ]]; then
  do_uninstall
else
  do_install
fi
