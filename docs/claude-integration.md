# Claude Code integration

The `neovim-code-review` plugin lets a coding agent (Claude Code or
any tool that can shell out and read files) hand control over to you
for an interactive review, then read your feedback as structured
JSON.

This guide assumes you run Claude Code locally in iTerm2,
Terminal.app, or another terminal where Neovim can take over the
screen interactively. Headless and remote scenarios are out of scope.

Prerequisites: the plugin installed and working in interactive mode
(see [installation.md](installation.md)), and Claude Code installed
and on your `PATH`. If `:CodeReview` works in your own Neovim, you
have everything you need for this guide.

## Before you start

You need all of these in place before the steps below work:

- Neovim 0.10+ with the `neovim-code-review` plugin installed and
  configured. Follow [installation.md](installation.md) first; come
  back here once `:CodeReview` works inside your own Neovim.
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
  installed and runnable in the terminal as `claude`.
- `jq` on your `$PATH` (used by the slash command to pretty-print the
  review file).

Setup, in order:

1. Install the plugin (see [installation.md](installation.md)) and
   confirm `:CodeReview` works in your own Neovim.
2. Install [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
   and confirm `claude` runs in your terminal.
3. Drop the `/code-review` slash command file into
   `~/.claude/commands/` (full body below).
4. From inside a git repo, launch Claude Code and type `/code-review`
   to try it.

## How it works

1. The agent runs `nvim -c 'CodeReview <range>'` with the environment
   variable `NVIM_CODE_REVIEW_RESULT` set to a temp file path. That
   variable is the handshake: its presence tells the plugin to run in
   *agent mode* (exit on submit/cancel), and after submit the plugin
   writes the path of the JSON review file into it so the agent knows
   where to look.
2. Neovim opens in your terminal showing the diff. Use the review
   keymaps (`<leader>Rc` to add a line comment, `<leader>Rf` for a
   file-level comment, `<C-s>` (Ctrl-S) to confirm the comment text,
   `<leader>Rs` to open the summary and submit, `<leader>Rq` to
   cancel). See the
   [full keymap table](installation.md#recommended-lazyvim-layout) in
   installation.md for the full set and how to rebind them.
3. The plugin writes a JSON review file under
   `~/.local/share/nvim/code-review/<project>/<timestamp>.json` (the
   audit trail) and writes that file's absolute path into the temp
   file the agent passed via `NVIM_CODE_REVIEW_RESULT`.
4. Neovim exits with code 0. The agent reads the result file, parses
   the JSON, and acts on your comments.

The indirection is so the agent picks the temp filename (and can
clean it up) while the plugin picks the audit-trail filename (so
reviews accumulate predictably per project).

The plugin has two modes. *Interactive mode* is what you get when you
run `:CodeReview` in your own Neovim — comments are saved but Neovim
stays open. *Agent mode* is what you get when
`NVIM_CODE_REVIEW_RESULT` is set in the environment — Neovim exits
as soon as you submit or cancel so the agent can read the result.
The slash command below uses agent mode.

Exit codes the agent should handle:

| Exit | Meaning                                              |
|------|------------------------------------------------------|
| 0    | Review submitted (may be empty — check `files`)      |
| 1    | Error (diagnostic on stderr, no review file)         |
| 2    | You cancelled (no review file)                       |

On exit codes 1 and 2 the temp file at `$NVIM_CODE_REVIEW_RESULT` is
left empty (or absent on early errors). The agent should not attempt
to read a review path from it.

## The result file contract

After a successful submit, the file at `$NVIM_CODE_REVIEW_RESULT`
contains a single line: the absolute path to a JSON file. Field values
shown below are illustrative; see
[`spec.md` §3.2](spec.md#32-reviewjson-schema) for the normative
schema.

```json
{
  "version": 1,
  "id": "20260528T143000",
  "created_at": "2026-05-28T14:30:00Z",
  "diff_spec": {
    "type": "commit_range",
    "base": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
    "head": "f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5"
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

An empty review (`files: []`) means the user reviewed the diff and
chose to leave no feedback — treat it as approval, not as an
unfinished session. Acknowledge briefly and stop.

`<project>` is the first 8 hex characters of a SHA-256 of the
repository's top-level path. The directory and its files are created
with the user's default umask; if you keep sensitive review content
here, harden the parent with
`chmod 700 ~/.local/share/nvim/code-review`.

Read it from a shell (install [`jq`](https://jqlang.org/) first if
you don't already have it):

```bash
review_path=$(cat "$NVIM_CODE_REVIEW_RESULT")
jq . "$review_path"
```

The plugin writes the path with no trailing newline. `$(cat …)` strips
up to one trailing newline, so the substitution works either way. Do
not replace it with `IFS= read -r path < file`; `read` returns
non-zero at EOF without a newline even though the variable is set,
which trips up scripts that gate on `read`'s exit status.

## Setting up the `/code-review` slash command

A *slash command* in Claude Code is a saved prompt template you invoke
by typing `/<name>` at the start of a message — for example
`/code-review`. Claude Code discovers slash commands by scanning
`~/.claude/commands/` for markdown files; the filename (minus `.md`)
becomes the command name. Each file has YAML frontmatter
(`description`, `argument-hint`, `allowed-tools`) followed by the
prompt body that Claude will read and execute. The body can reference
`$ARGUMENTS`, which Claude Code substitutes with whatever you typed
after the command name (e.g. `/code-review HEAD~3..HEAD` makes
`$ARGUMENTS` equal `HEAD~3..HEAD`).

The body below is the prompt Claude sees, written in the second person
addressed *to Claude*. You (the human) are configuring it once and can
stop reading after the frontmatter. Copy the block below (everything
between the four-backtick fences, *not* the fences themselves) into
`~/.claude/commands/code-review.md`. The outer fence uses four
backticks so the inner triple-backtick code blocks render correctly
here.

````markdown
---
description: Open a code review in Neovim and act on the feedback
argument-hint: "[git-range]"
allowed-tools: Bash, Read, Edit
---

Hand control to the user for an interactive code review in Neovim, then read the JSON they submit and apply their feedback.

Do not read other files first. Run the following Bash immediately (one tool call, foreground). It blocks until the user submits or cancels.

```bash
set -euo pipefail
case "${ARGUMENTS:-}" in *[\|\"\\]*|*$'\n'*) echo "code-review: unsafe ARGUMENTS" >&2; exit 1 ;; esac

result_file=$(mktemp "${TMPDIR:-/tmp}/nvim-code-review.XXXXXX")
stderr_file=$(mktemp "${TMPDIR:-/tmp}/nvim-code-review-err.XXXXXX")
trap 'rm -f "$result_file" "$stderr_file"' EXIT INT TERM HUP

NVIM_CODE_REVIEW_RESULT="$result_file" \
  nvim -c "CodeReview ${ARGUMENTS:-}" 2>"$stderr_file"
rc=$?

case "$rc" in
  0)
    review_path=$(cat "$result_file")
    [ -n "$review_path" ] || { echo "code-review: empty result"; cat "$stderr_file" >&2; exit 1; }
    jq . "$review_path"
    ;;
  2) echo "review cancelled" >&2; exit 2 ;;
  *) echo "neovim error (exit $rc)"; cat "$stderr_file" >&2; exit "$rc" ;;
esac
```

After the Bash returns, act based on the exit code:

- **0**: parse the printed JSON. Each `files[].lines[]` is a comment on `path` at `new_lineno` (or `old_lineno` if `side == "old"`). Summarize the feedback in <=10 lines, then apply the edits. An empty `files` array means the user approved with no comments — acknowledge and stop.
- **2**: user cancelled. Acknowledge in one line and stop.
- **1**: print the stderr the script captured, then stop.

`$ARGUMENTS` is an optional git revision range (`HEAD~3..HEAD`, `main...HEAD`, empty for working tree).
````

### Why this body is short

Claude Code loads the entire slash-command body as the prompt the agent
responds to. Long bodies — extensive prerequisites, explanations,
checklists — cause the agent to "think" longer before invoking the
first tool, so `/code-review` can feel like it hangs for tens of
seconds before Neovim appears. The body above strips out everything
the agent does not need at runtime (it lives in the rest of this doc
for human readers); the explicit "Do not read other files first" is
there to keep the agent from chasing the spec or the README before
running the script.

### What the body does, in plain English

`$ARGUMENTS` is interpolated by Claude Code before the agent sees the
body. The first `case` rejects anything containing `|`, `"`, `\` or a
newline — none of which appear in legitimate git revision specs
(`HEAD~3..HEAD`, `main...HEAD`, `@^`) but each of which is a Vim or
shell metacharacter that could break out of `-c "CodeReview $ARGUMENTS"`.
The two `mktemp` files hold the result path the plugin writes and the
stderr from Neovim; the `trap` line removes them on every exit path so
nothing leaks. `NVIM_CODE_REVIEW_RESULT` is the env-var handshake — its
presence is what tells the plugin to run in agent mode. The plugin
exits 0 (submitted), 2 (cancelled), or 1 (error). `jq .` pretty-prints
the JSON so the agent reads it as text in its next turn.

### TTY note

The script must run on a real TTY: Neovim is a full-screen TUI and
needs to take over the terminal. Claude Code in iTerm2, Terminal.app,
or a tmux pane works; headless Bash without a controlling TTY fails
with `Vim: Warning: Output is not to a terminal`. If `/code-review`
exits immediately without Neovim appearing, check `tty < /dev/tty` in
the same Bash environment first.

### Verify the command loaded

In a new Claude Code session, type `/` and confirm `code-review`
appears in the completions. If it doesn't:

- Confirm the file exists at `~/.claude/commands/code-review.md`.
- Confirm the frontmatter parses: the file must start with `---`,
  contain `description: ...`, and end the frontmatter with `---`.
- Restart Claude Code if it was already running.

## End-to-end example

In the transcript below, lines starting with `>` are what you type to
Claude; unprefixed paragraphs are Claude's replies; bracketed lines
describe what happens in Neovim.

```text
> /code-review HEAD~2..HEAD

Launching code review for HEAD~2..HEAD. Add comments in Neovim, then
<leader>Rs to submit (or <leader>Rq to cancel).

⏺ Bash(NVIM_CODE_REVIEW_RESULT=… nvim -c 'CodeReview HEAD~2..HEAD')
  [Neovim takes over the terminal. Navigate the diff, <leader>Rc on a
   line to add a comment, <C-s> (Ctrl-S) to confirm. After commenting,
   <leader>Rs opens the summary, <CR> submits.]
  ⎿  (Neovim exits 0; control returns to Claude Code.)

Review submitted with 3 comments:
- src/auth.lua:42 — Missing HMAC validation
- src/auth.lua:47 — Magic number needs a comment
- tests/test_auth.py:10 — Why was this assertion removed?

I'll start with the HMAC validation fix.
```

## Tips

### Always use agent mode

The slash command above sets `NVIM_CODE_REVIEW_RESULT`, putting the
plugin into agent mode (forces Neovim to exit on submit/cancel so
Claude regains control). If you run `:CodeReview` from your own Neovim
session without the env var, Claude won't know when you're done.

### Cancel cleanly

`<leader>Rq` cancels the session and exits Neovim with code 2. Claude
will see the cancellation and stop.

### Pause hangs Claude Code's Bash tool

`<leader>Rp` saves your in-progress session for later. The invocation
Claude Code is blocked on never returns, so the agent sits idle until
you submit or cancel. Prefer `<leader>Rq` (cancel) during an agent
run; resume the paused session from your own Neovim session with
`:CodeReviewSessions` (or `<leader>gR` if you took the recommended
LazyVim layout in [installation.md](installation.md#recommended-lazyvim-layout)).

### Quit Neovim entirely

`:cquit 2` exits with the same code as `<leader>Rq` (cancellation,
exit 2) and is the safest "get me out" key combo. Plain `:qa` exits
with code 0, which the agent will interpret as a successful submit and
try to read a review file that was never written — prefer
`<leader>Rq` or `:cquit 2` instead. `:qa!` behaves the same as `:qa`.

### Reading reviews later

All submitted reviews accumulate under
`~/.local/share/nvim/code-review/<project-hash>/`, where
`<project-hash>` is the first eight hex characters of the SHA-256 of
your git root path. To list the five most recent for the current repo
without launching Neovim:

```bash
root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "not inside a git repo" >&2
  exit 1
}
if command -v sha256sum >/dev/null 2>&1; then
  hash=$(printf '%s' "$root" | sha256sum | cut -c1-8)
else
  hash=$(printf '%s' "$root" | shasum -a 256 | cut -c1-8)
fi
ls -1t -- ~/.local/share/nvim/code-review/"$hash"/*.json 2>/dev/null \
  | head -5
```

## Next

- [Installation and configuration](installation.md)
- [Specification](spec.md) — JSON schema, exit-code semantics, full
  requirements
