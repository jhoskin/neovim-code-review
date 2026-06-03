---
description: Open an interactive code review in Neovim and act on the feedback
argument-hint: "[git-range]"
allowed-tools: Bash, Read, Edit
---

Hand control to the user for an interactive code review, then read the JSON they submit and apply their feedback. A review can take far longer than the Bash tool's 10-minute cap, so drive it asynchronously: start it, then wait in the background.

Do not read other files first.

Step 1 — start the review. This returns immediately and prints a HANDLE on stdout (the iTerm tab opens for the user):

```bash
~/.claude/scripts/interactive-review-launch start "${ARGUMENTS:-}"
```

Capture the handle (the single stdout line). If `start` exits non-zero, print its stderr and stop.

Step 2 — wait for the user to finish, in the background so it is not capped at 10 minutes. Run this with `run_in_background: true`, substituting the handle from step 1:

```bash
~/.claude/scripts/interactive-review-launch wait <HANDLE>
```

It polls every second and exits the moment the user submits or cancels; you are notified when it completes. (To peek without blocking, run `... status <HANDLE>` — exit code 3 means still running. Tell the user to take their time.)

Step 3 — when the background `wait` completes, act on its exit code:

- **0**: parse the printed JSON. Each `files[].lines[]` entry is a comment on `path` at `new_lineno` (or `old_lineno` if `side == "old"`). Summarize the feedback in <=10 lines, then apply the edits. An empty `files` array means the user approved with no comments — acknowledge and stop.
- **2**: user cancelled. Acknowledge in one line and stop.
- other: print the stderr the command captured, then stop.

`$ARGUMENTS` is an optional git revision range (`HEAD~3..HEAD`, `main...HEAD`, empty for working tree).
