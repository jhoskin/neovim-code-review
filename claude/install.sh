#!/usr/bin/env bash
# Install the Claude Code integration for neovim-code-review.
#
# Symlinks the `/interactive-review` slash command and the launcher script into
# your `~/.claude/` so Claude Code can drive an interactive review. Symlinks
# (the default) keep them in sync with `git pull`; pass --copy to copy instead.
#
# Usage:
#   claude/install.sh            # symlink into ~/.claude
#   claude/install.sh --copy     # copy instead of symlink

set -euo pipefail

mode="symlink"
if [ "${1:-}" = "--copy" ]; then
  mode="copy"
fi

# Repo root = the parent of this script's directory.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

command_src="$root/claude/commands/interactive-review.md"
launch_src="$root/scripts/interactive-review-launch"
command_dst="$HOME/.claude/commands/interactive-review.md"
launch_dst="$HOME/.claude/scripts/interactive-review-launch"

for f in "$command_src" "$launch_src"; do
  if [ ! -f "$f" ]; then
    printf 'install: missing source file: %s\n' "$f" >&2
    exit 1
  fi
done

mkdir -p "$HOME/.claude/commands" "$HOME/.claude/scripts"

link_or_copy() {
  local src="$1" dst="$2"
  if [ "$mode" = "copy" ]; then
    cp "$src" "$dst"
  else
    ln -sf "$src" "$dst"
  fi
  printf '  %s -> %s\n' "$dst" "$src"
}

printf 'Installing the code-review Claude integration (%s):\n' "$mode"
link_or_copy "$command_src" "$command_dst"
link_or_copy "$launch_src" "$launch_dst"
chmod +x "$launch_src"

printf 'Done. Use /interactive-review in Claude Code (optionally with a git range).\n'
