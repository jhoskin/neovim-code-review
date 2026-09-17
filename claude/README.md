# Claude Code integration

This bundle wires the plugin into [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
as a `/interactive-review` slash command, so an agent can hand control to you
for a review and read your feedback as JSON.

- `commands/interactive-review.md` — the slash command.
- `../scripts/interactive-review-launch` — the launcher it runs (runs Neovim
  in a detached zmx session, opens a kitty window, returns the review JSON, and
  closes the tab when the review exits).

## Install

From a clone of this repo:

```bash
claude/install.sh          # symlink into ~/.claude (tracks git pull)
claude/install.sh --copy   # copy instead, if you prefer
```

Then run `/interactive-review` (optionally with a git range, e.g.
`/interactive-review HEAD~3..HEAD`) in Claude Code.

See [../docs/claude-integration.md](../docs/claude-integration.md) for the full
guide and the manual (no-installer) setup.
