# Claude Code integration

This plugin is designed to let a coding agent (Claude Code or any tool
that can shell out and read files) hand control over to you for an
interactive review, then read your feedback as structured JSON.

This guide assumes you run Claude Code in your local terminal, where
Neovim can take over the screen interactively. Headless and remote
scenarios are out of scope.

## How it works

1. The agent runs `nvim -c 'CodeReview <range>'` with the environment
   variable `NVIM_CODE_REVIEW_RESULT` set to a temp file path.
2. Neovim opens in your terminal showing the diff. You add comments
   (`<leader>Rc` per line, `<leader>Rf` per file) and submit
   (`<leader>Rs`).
3. The plugin writes a JSON review file under
   `~/.local/share/nvim/code-review/<project>/<timestamp>.json` and
   writes that file's absolute path to `NVIM_CODE_REVIEW_RESULT`.
4. Neovim exits with code 0. The agent reads the result file, parses
   the JSON, and acts on your comments.

Exit codes the agent should handle:

| Exit | Meaning                                              |
|------|------------------------------------------------------|
| 0    | Review submitted (may be empty — check `files`)      |
| 2    | You cancelled (no review file)                       |
| 1    | Error (diagnostic in stderr, no review file)         |

## The result file contract

After a successful submit, the file at `$NVIM_CODE_REVIEW_RESULT`
contains a single line: the absolute path to a JSON file. The JSON
schema is defined in [`spec.md` section 3.2](spec.md). Briefly:

```json
{
  "version": 1,
  "id": "20260528T143000",
  "created_at": "2026-05-28T14:30:00Z",
  "diff_spec": {
    "type": "commit_range",
    "base": "<40-char SHA>",
    "head": "<40-char SHA>"
  },
  "files": [
    {
      "path": "src/example.lua",
      "comment": "File-level comment, or null.",
      "lines": [
        {
          "old_lineno": null,
          "new_lineno": 42,
          "side": "new",
          "diff_hunk": "@@ -38,6 +38,10 @@\n context line\n+added line",
          "body": "The line comment text."
        }
      ]
    }
  ]
}
```

Read it from a shell with:

```bash
review_path=$(cat "$NVIM_CODE_REVIEW_RESULT")
cat "$review_path" | jq .
```

## Setting up the `/code-review` slash command

Claude Code reads slash commands from `~/.claude/commands/`. Each is a
markdown file with YAML frontmatter (a `description`) and a body
containing the prompt template. The body can reference `$ARGUMENTS` for
positional input.

Create `~/.claude/commands/code-review.md`:

````markdown
---
description: Open a code review in Neovim and act on the feedback
---

Hand control to the user for an interactive code review in Neovim,
then read their structured feedback and apply it.

The user may pass a git revision range as `$ARGUMENTS`. Examples:

- `/code-review` — review the working tree against HEAD
- `/code-review HEAD~3..HEAD` — review the last three commits
- `/code-review main...HEAD` — review this branch vs main (merge-base)

Steps:

1. Create a temp file for the result:
   ```bash
   result_file=$(mktemp -t nvim-code-review.XXXXXX)
   ```
2. Invoke Neovim, blocking until the user submits or cancels:
   ```bash
   NVIM_CODE_REVIEW_RESULT="$result_file" nvim -c "CodeReview $ARGUMENTS"
   ```
   The user takes over the terminal. They will add comments, then
   press `<leader>Rs` to submit (or `<leader>Rq` to cancel).
3. After Neovim exits, branch on the exit code:
   - **0**: read the review path, read the JSON, summarize the
     comments for the user, then apply the requested changes.
   - **2**: the user cancelled. Acknowledge briefly and stop.
   - **1**: print the contents of stderr and report the error.
4. Read the review:
   ```bash
   review_path=$(cat "$result_file")
   cat "$review_path"
   ```
   Parse the JSON. For each entry in `files[].lines[]`, the comment
   refers to `path` at line `new_lineno` (or `old_lineno` if `side` is
   `old`). `diff_hunk` shows the surrounding diff for context.
5. Treat the comments as authoritative reviewer feedback. For each
   actionable comment, edit the file accordingly. File-level comments
   are general guidance.
6. Clean up the temp file:
   ```bash
   rm -f "$result_file"
   ```

Keep your initial response under three lines: confirm the command
launched and tell the user to add comments in Neovim. After Neovim
exits, summarize the feedback in 5–10 lines before starting edits.
````

## End-to-end example

```
You: /code-review HEAD~2..HEAD

Claude: Launching code review for HEAD~2..HEAD. Add comments in
Neovim, then <leader>Rs to submit (or <leader>Rq to cancel).

[Neovim takes over the terminal. You navigate the diff, press
<leader>Rc on a line to add a comment, type your feedback, <C-s>
to confirm. After commenting on a few lines, <leader>Rs opens the
summary, <CR> submits.]

[Neovim exits, returning to Claude.]

Claude: Review submitted with 3 comments:
- src/auth.lua:42 — Missing HMAC validation
- src/auth.lua:47 — Magic number needs a comment
- tests/test_auth.py:10 — Why was this assertion removed?

I'll start with the HMAC validation fix.

[Claude edits files.]
```

## Tips

Always use agent mode
: The slash command above sets `NVIM_CODE_REVIEW_RESULT`, putting the
  plugin into agent mode (forces Neovim to exit on submit/cancel so
  Claude regains control). If you run `:CodeReview` from your own
  Neovim session without the env var, Claude won't know when you're
  done.

Cancel cleanly
: `<leader>Rq` cancels the session and exits Neovim with code 2.
  Claude will see the cancellation and stop.

Pause is for you, not the agent
: `<leader>Rp` saves your in-progress session for later (`<leader>gR`
  or `:CodeReviewSessions` resumes it). In agent mode this is awkward
  because Claude's invocation will hang until the session ends one
  way or another. Avoid pause during agent invocations; cancel
  instead and resume from your own Neovim session later.

Quit Neovim entirely
: `:qa` or `:cquit 2` also work to cancel — same exit code as
  `<leader>Rq`.

Reading reviews later
: All submitted reviews accumulate under
  `~/.local/share/nvim/code-review/<project>/`. To list and re-read
  them later (without launching Neovim), use `ls` and `cat`:
  ```bash
  hash=$(printf '%s' "$(git rev-parse --show-toplevel)" | shasum -a 256 | cut -c1-8)
  ls -1t ~/.local/share/nvim/code-review/$hash/*.json | head -5
  ```

## Next

- [Installation and configuration](installation.md)
- [Specification](spec.md) — JSON schema, exit-code semantics, full
  requirements
