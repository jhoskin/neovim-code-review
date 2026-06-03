---
description: Open an interactive code review in Neovim and act on the feedback
argument-hint: "[git-range]"
allowed-tools: Bash, Read, Edit
---

Hand control to the user for an interactive code review, then read the JSON they submit and apply their feedback.

Do not read other files first. Run the script below with `timeout: 600000`. The script polls for up to five hours, but Claude Code's Bash tool caps at ten minutes; if the user needs longer, they can pause the review (`<leader>Rp`), let this call time out, and resume with `:CodeReviewSessions` later.

```bash
~/.claude/scripts/interactive-review-launch "${ARGUMENTS:-}"
```

After the Bash returns, act based on the exit code:

- **0**: parse the printed JSON. Each `files[].lines[]` entry is a comment on `path` at `new_lineno` (or `old_lineno` if `side == "old"`). Summarize the feedback in <=10 lines, then apply the edits. An empty `files` array means the user approved with no comments — acknowledge and stop.
- **2**: user cancelled. Acknowledge in one line and stop.
- **1**: print the stderr the script captured, then stop.

`$ARGUMENTS` is an optional git revision range (`HEAD~3..HEAD`, `main...HEAD`, empty for working tree).
