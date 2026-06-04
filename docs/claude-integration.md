# Claude Code integration

The `neovim-code-review` plugin lets a coding agent (Claude Code or
any tool that can shell out and read files) hand control over to you
for an interactive review, then read your feedback as structured
JSON.

This guide assumes you run Claude Code locally in Ghostty,
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
3. Drop the `/interactive-review` slash command file into
   `~/.claude/commands/` (full body below).
4. From inside a git repo, launch Claude Code and type `/interactive-review`
   to try it.

## How it works

1. The agent runs `nvim -c 'CodeReview <range>'` with the environment
   variable `NVIM_CODE_REVIEW_RESULT` set to a temp file path. That
   variable is the handshake: its presence tells the plugin to run in
   *agent mode* (exit on submit/cancel), and after submit the plugin
   writes the path of the JSON review file into it so the agent knows
   where to look.
2. Neovim opens in your terminal showing the diff. Use the review
   keymaps (`<leader>Rr` to add a line comment, `<leader>RR` for a
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

## Setting up the `/interactive-review` slash command

A *slash command* in Claude Code is a saved prompt template you invoke
by typing `/<name>` at the start of a message. Claude Code discovers
slash commands by scanning `~/.claude/commands/` for markdown files;
the filename (minus `.md`) becomes the command name.

The command name `interactive-review` deliberately avoids
`/code-review`, which is taken by a built-in Claude Code skill that
does AI-only review of a diff. The two are complementary; only the
plugin's command hands control to a human in Neovim.

### Quick install (recommended)

Both the slash command and the launch script live in the repo, under
`claude/commands/interactive-review.md` and
`scripts/interactive-review-launch`. From a clone of the plugin repo, run
the bundled installer:

```bash
claude/install.sh          # symlink into ~/.claude (tracks `git pull`)
claude/install.sh --copy   # copy instead, if you prefer
```

It symlinks `~/.claude/commands/interactive-review.md` and
`~/.claude/scripts/interactive-review-launch` into the repo, so a `git
pull` keeps them current. With `--copy`, re-run the installer after an
update to refresh the copies.

### Manual install (alternative)

If you would rather not run the installer, place the two files yourself.
The launch script:

```bash
mkdir -p ~/.claude/scripts
cp /path/to/neovim-code-review/scripts/interactive-review-launch \
   ~/.claude/scripts/interactive-review-launch
chmod +x ~/.claude/scripts/interactive-review-launch
```

And the slash command — copy the block below (the contents between the
four-backtick fences, not the fences themselves) into
`~/.claude/commands/interactive-review.md` (it is also committed at
`claude/commands/interactive-review.md`):

````markdown
---
description: Open an interactive code review in Neovim and act on the feedback
argument-hint: "[git-range]"
allowed-tools: Bash, Read, Edit
---

Hand control to the user for an interactive code review, then read the JSON they submit and apply their feedback. A review can take far longer than the Bash tool's 10-minute cap, so drive it asynchronously: start it, then wait in the background.

Do not read other files first.

Step 1 — start the review. This returns immediately and prints a HANDLE on stdout (the Ghostty tab opens for the user):

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
````

### Why the body is short

Claude Code loads the entire slash-command body as the prompt the
agent responds to. Long bodies (extensive prerequisites, inline
scripts, explanations) make the agent "think" longer before invoking
the first tool. Keeping the body to a description, the start/wait
calls, and three exit-code rules means the agent acts almost
immediately; the launch script is on disk and tested, not regenerated
each turn.

### Why the script uses tmux

Claude Code's Bash tool does not allocate a controlling TTY for the
foreground command. Run `nvim` directly and it hangs invisibly: there
is no TTY for it to render into, and the agent's Bash call just sits
there until the timeout fires. The bundled script wraps `nvim` in a
detached `tmux new-session -d`, which gives Neovim its own pseudo-TTY,
then opens that session in a new Ghostty tab via AppleScript
(`osascript`, Ghostty's official automation interface). The tab runs
`exec tmux attach` through the surface's `initial input` (typed into a
normal login shell), not the `command` property: Ghostty keeps a
`command`-surface open after the command exits, but a shell that `exec`s
tmux closes the tab by ordinary shell-exit when the review ends. If
AppleScript fails (Ghostty not running, or not on macOS) the script
falls back to printing the `tmux attach -t <session>` command for you to
run by hand in any terminal pane.

### What the script does

`$ARGUMENTS` is interpolated by Claude Code before the agent sees the
slash-command body. The script's first `case` rejects any argument
containing `|`, `"`, `\`, or newline — none appear in legitimate git
revision specs (`HEAD~3..HEAD`, `main...HEAD`, `@^`) but each is a
Vim or shell metacharacter that could break out of
`-c "CodeReview <range>"`. The plugin's
`NVIM_CODE_REVIEW_RESULT` env-var handshake puts the plugin in agent
mode. The script has three subcommands. `start` spawns the review and
prints a handle, returning at once. `status <handle>` checks once
(exit 3 still running, 0 done, 2 cancelled). `wait <handle>` polls the
sentinel file every second until Neovim exits, then prints the review
JSON via `jq` (exit 0), `review cancelled` (exit 2), or an error
diagnostic (exit 1) — the same completion semantics as `status`.
Calling the script with a bare range and no subcommand still runs the
old blocking poll-and-print path.

### Verify the command loaded

In a new Claude Code session, type `/` and confirm `interactive-review`
appears in the completions. If it doesn't:

- Confirm the file exists at `~/.claude/commands/interactive-review.md`.
- Confirm the frontmatter parses: the file must start with `---`,
  contain `description: ...`, and end the frontmatter with `---`.
- Restart Claude Code if it was already running.

## End-to-end example

In the transcript below, lines starting with `>` are what you type to
Claude; unprefixed paragraphs are Claude's replies; bracketed lines
describe what happens in Neovim.

```text
> /interactive-review HEAD~2..HEAD

Launching code review for HEAD~2..HEAD. Add comments in Neovim, then
<leader>Rs to submit (or <leader>Rq to cancel).

⏺ Bash(NVIM_CODE_REVIEW_RESULT=… nvim -c 'CodeReview HEAD~2..HEAD')
  [Neovim takes over the terminal. Navigate the diff, <leader>Rr on a
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

### Pausing to set a review aside

`<leader>Rp` saves your in-progress session for later. The async
launcher runs the review's `wait` in the background, so a pause no
longer hangs the Bash tool — the agent stays free either way. Use pause
when you genuinely want to set a review aside; resume it from your own
Neovim session with `:CodeReviewSessions` (or `<leader>gR` if you took
the recommended LazyVim layout in
[installation.md](installation.md#recommended-lazyvim-layout)). You no
longer need to pause merely to dodge the 10-minute cap.

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

## Troubleshooting

`Plugin neovim-code-review is not installed`
: lazy.nvim has the plugin in its spec but has not cloned it yet (or
  a previous clone failed). Run `:Lazy install` once in your own
  Neovim before invoking `/interactive-review`. If a
  `~/.local/share/nvim/lazy/neovim-code-review.cloning` directory
  exists, that is a half-finished clone — see
  [installation.md's Troubleshooting section](installation.md#troubleshooting)
  for the cleanup.

The Bash call runs for several seconds, then exits with no Neovim window
: The script is waiting for the sentinel file but `nvim` exited
  immediately. The most common cause is that the plugin is not loaded
  yet and `:CodeReview` fired before lazy.nvim finished installing it.
  Run `:Lazy install` first, then re-invoke `/interactive-review`.

No new Ghostty tab opens; the script just prints a `tmux attach` line
: Ghostty AppleScript control failed — Ghostty is not running, or you
  are not on macOS. Run the printed `tmux attach -t <session>` command
  yourself in any terminal pane.

`neovim error (exit ...)` and Neovim never appears
: nvim crashed at startup. Run `nvim --headless +qa` in the same shell
  to surface the underlying error (often a missing dependency in your
  config or a plugin manager that has not finished initialising).

The review takes longer than 10 minutes
: This is fine. The slash command runs `start` to spawn the review,
  then runs `wait <handle>` in the background, so the review never
  blocks the Bash tool's 10-minute cap. Take as long as you need; the
  agent is notified when the background `wait` exits.

## Next

- [Installation and configuration](installation.md)
- [Specification](spec.md) — JSON schema, exit-code semantics, full
  requirements
