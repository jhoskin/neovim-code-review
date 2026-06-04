# neovim-code-review Specification

Version: 0.1.0-draft
Date: 2026-05-26

## 1. Overview

### 1.1 Purpose

A local code review tool for reviewing LLM coding agent output inside Neovim.
A coding agent launches Neovim into a diff view. The reviewer adds comments on
diff lines or files. On exit, the review is persisted as
a JSON file in a local audit trail directory. The agent reads the file and
acts on the feedback.

### 1.2 Scope

- Display diffs for working tree, branch, or commit range
- Line-level and file-level comments
- Persist reviews as JSON files in a local audit trail directory
- Blocking CLI interface for agent invocation
- JSON output readable by any tool that can read a file

### 1.3 Non-goals

- Git ref storage (reviews are stored as files, not git objects)
- Comment threading or replies
- Structured approval workflow (no approve/reject/merge)
- Multi-round review sessions (each session is independent)
- Automatic staging or stashing of working tree changes
- Structured verdict field (the reviewer's overall opinion goes in line or file comments)

## 2. Architecture

```text
┌─────────────────────────────────────────────┐
│                  Neovim >= 0.10              │
│                                             │
│  ┌──────────────┐    ┌───────────────────────────────────┐  │
│  │ code-review  │───>│  diff renderer (side-by-side,     │  │
│  │   plugin     │    │  pure Lua: nofile scratch buffers │  │
│  │   (Lua)      │    │  + window layout + treesitter)    │  │
│  │              │    └───────────────────────────────────┘  │
│  │  ┌────────────────────────────────┐      │
│  │  │ comment layer                  │      │
│  │  │ (extmarks + virtual text)      │      │
│  │  └────────────────────────────────┘      │
│  │              │                           │
│  │  ┌────────────────────────────────┐      │
│  │  │ storage layer                  │      │
│  │  │ (file I/O)                     │      │
│  │  └────────────────────────────────┘      │
│  └──────────────┘                           │
└─────────────────────────────────────────────┘
                    │
                    ▼
  ~/.local/share/nvim/code-review/<project>/
  (review JSON files)
```

### 2.1 Dependencies

| Dependency    | Version   | Purpose                        |
|---------------|-----------|--------------------------------|
| Neovim        | >= 0.10   | `vim.system()` (added in 0.10), `sign_text` in extmarks (added in 0.10), `nvim_buf_set_extmark` with `virt_lines` (added in 0.8). The binding floor is `vim.system()`. |
| git           | >= 2.30   | Read-only operations (`git diff`, `git rev-parse`, `git merge-base`). All commands used are available since git 1.x; the 2.30 floor may be lowerable. |

### 2.2 Data flow

1. Agent invokes `nvim -c 'CodeReview <range>'`
2. Plugin parses the range, runs `git diff` for the resolved spec, builds
   per-file old/new `nofile` buffers, and opens the side-by-side layout (file
   panel + two diff windows). Side (old/new) and repo-relative path come from
   the plugin's own window/buffer registry. (See section 4.4 for the renderer
   internals.)
3. User navigates diffs, adds comments via keybindings
4. Comments are held in memory and rendered as extmarks
5. User finishes review (`:CodeReviewSubmit` or summary confirmation). If the
   user quits Neovim without submitting (`:q`, `:qa`, `ZQ`), no review is
   persisted and the exit code is 2.
6. Plugin serializes review to JSON
7. Plugin writes review JSON to audit trail directory
8. Plugin writes the audit trail file path to the result file (see section
   5.2), exits Neovim

The plugin calls `vim.system()` (Neovim >= 0.10) for read-only git
operations: `git diff`, `git rev-parse`, and `git merge-base`. These run
during range parsing and diff display. The storage layer uses Lua file I/O
(`io.open`, `vim.fn.mkdir`) to write review JSON at submission time.

## 3. Data Model

### 3.1 File storage

Reviews are stored as JSON files in the audit trail directory.

**Audit trail directory**: `~/.local/share/nvim/code-review/<project-hash>/`
where `<project-hash>` is the first 8 characters of the SHA-256 hash of
the git repository root path. This prevents collisions between projects
with the same name.

**Review files**: `<timestamp>.json` where timestamp is `YYYYMMDDTHHMMSS`
(UTC). Each submitted review creates one file. The plugin never deletes
these files.

**Session files**: `sessions/<session-id>.json` stores in-progress review
state for pause/resume. Session files are deleted when the session is
submitted or explicitly discarded.

**Directory structure**:

```text
~/.local/share/nvim/code-review/
  └── a1b2c3d4/                    (project hash)
      ├── 20260526T143000.json     (completed review)
      ├── 20260526T150000.json     (completed review)
      └── sessions/
          └── abc123.json          (paused session)
```

**Result file**: On submit, the plugin writes the full path of the saved
review JSON to the result file. The result file path comes from
`$NVIM_CODE_REVIEW_RESULT` (or `$TMPDIR/nvim-code-review-result` if
unset). The result file contains a single line: the absolute path to the
review JSON file, with no trailing newline.

**Reading a review**: Any tool can read a review by parsing the JSON file
directly. No git commands or plugin installation required.

### 3.2 review.json schema

The canonical schema is `schema/review.v1.json` (JSON Schema draft 2020-12).
The example and field table below are informational.

```json
{
  "version": 1,
  "id": "20260526T143000",
  "created_at": "2026-05-26T14:30:00Z",

  "diff_spec": {
    "type": "working_tree",
    "base": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
    "head": null
  },

  "files": [
    {
      "path": "src/main.lua",
      "comment": "<file-level comment string or null>",
      "lines": [
        {
          "old_lineno": null,
          "new_lineno": 42,
          "side": "new",
          "diff_hunk": "@@ -38,6 +38,10 @@\n context line\n+added line",
          "body": "This allocation grows unbounded in a loop."
        }
      ]
    }
  ]
}
```

**Field definitions**:

| Field | Type | Required | Description |
|---|---|---|---|
| `version` | integer | yes | Schema version, currently `1`. Consumers that encounter an unsupported version shall treat the review as unreadable and report the mismatch. New versions may add fields but will not remove or change semantics of existing fields (additive-only within a major version). Consumers shall ignore unknown fields (forward compatibility). |
| `id` | string | yes | Review ID in the format `YYYYMMDDTHHMMSS` (UTC timestamp). Matches the filename stem in the audit trail directory (see section 3.1). |
| `created_at` | string (ISO 8601) | yes | UTC timestamp with second precision, always suffixed with `Z` (e.g., `2026-05-26T14:30:00Z`). No fractional seconds. No timezone offset other than `Z`. |
| `diff_spec.type` | enum | yes | One of `commit_range`, `branch`, `working_tree` |
| `diff_spec.base` | string or null | yes | Full 40-character SHA of the base commit, resolved at review time. See diff_spec table below. |
| `diff_spec.head` | string or null | yes | Full 40-character SHA of the head commit, resolved at review time. Null for working-tree reviews. |
| `files` | array | yes | One entry per file with comments (empty array if no comments) |
| `files[].path` | string | yes | File path relative to the repository root, using forward slashes as separators (e.g., `src/main.lua`). Never starts with `./` or `/`. Matches the format of `git diff --name-only`. |
| `files[].comment` | string or null | yes | File-level comment |
| `files[].lines` | array | yes | Line-level comments for this file |
| `files[].lines[].old_lineno` | integer or null | yes | Line number in the base side. Null when the line exists only in the head (pure addition). |
| `files[].lines[].new_lineno` | integer or null | yes | Line number in the head side. Null when the line exists only in the base (pure deletion). |
| `files[].lines[].side` | enum | yes | `old` or `new`: which side the comment is anchored to. For context lines (unchanged, present on both sides), `side` shall be `new`. Both `old_lineno` and `new_lineno` shall be populated for context lines. |
| `files[].lines[].diff_hunk` | string | yes | The full unified-diff hunk (from `@@` header through the last line of the hunk) that contains the commented line, extracted from the same diff source used for display. Lines use unified diff prefixes: ` ` for context, `+` for additions, `-` for deletions, separated by `\n`. |
| `files[].lines[].body` | string (non-empty) | yes | The comment text. Must contain at least one non-whitespace character. |

**Line number invariants**:

| Line type | `old_lineno` | `new_lineno` | `side` |
|---|---|---|---|
| Added line | null | set | `new` |
| Deleted line | set | null | `old` |
| Context/modified line | set | set | reviewer's anchor pane (default `new`) |

Both `old_lineno` and `new_lineno` are never null simultaneously.

**`diff_spec` by type**:

| `type` | `base` | `head` | CLI input |
|---|---|---|---|
| `working_tree` | HEAD SHA (resolved) | null | `CodeReview` |
| `commit_range` | base commit SHA | head commit SHA | `CodeReview A..B` |
| `branch` | merge-base commit SHA | branch tip commit SHA | `CodeReview A...B` |

Values for `base` and `head` are always full 40-character commit SHAs
resolved at review time, not symbolic refs or abbreviated hashes.

**Extensibility**: Future schema versions may add new top-level fields or new
fields within `files[]` and `files[].lines[]` entries. Consumers shall ignore
unknown fields rather than treating them as errors. Producers shall not add
fields outside the defined schema for the declared version.

**Empty review**: When the user submits without commenting, the review is
created with `files` as an empty array. This signals
"reviewed, no feedback" rather than "not reviewed."

### 3.3 Reading a review

Any tool can read a review by parsing the JSON file at its audit trail
path:

```bash
cat ~/.local/share/nvim/code-review/a1b2c3d4/20260526T143000.json | jq .
```

List all reviews for a project:

```bash
ls ~/.local/share/nvim/code-review/a1b2c3d4/*.json
```

The agent reads the result file after neovim exits:

```bash
review_path=$(cat "$NVIM_CODE_REVIEW_RESULT")
cat "$review_path" | jq .
```

### 3.4 Audit trail management

Review files accumulate in the audit trail directory. The plugin does not
delete them automatically. To remove old reviews:

```bash
# Delete reviews older than 30 days
find ~/.local/share/nvim/code-review/ -name "*.json" -mtime +30 -delete
```

To delete all reviews for a project:

```bash
rm -rf ~/.local/share/nvim/code-review/<project-hash>/
```

## 4. User Interface Spec

### 4.1 Screens

#### SCR-DIFF-01: Diff view

The primary screen. Rendered by the plugin's built-in side-by-side diff
renderer.

**Layout**: a file-panel + diff-panel layout. The file panel presents changed
files as a compact, indented directory tree (slim, configurable width). The diff
panel shows the side-by-side old/new diff for the selected file.

**Comment rendering**: Existing comments appear as extmarks with virtual text
below the commented line. The virtual text uses a distinct highlight group
(`CodeReviewComment`) to distinguish comments from code.

**Logical identifiers** (for spec cross-references and test hooks, not Neovim
API objects):

| Logical ID             | Neovim object              | Description                          |
|------------------------|----------------------------|--------------------------------------|
| `panel.file-list`      | plugin file-panel buffer   | The plugin's file-tree panel         |
| `panel.diff`           | old/new diff buffers       | The plugin's old and new diff buffers |
| `extmark.comment`      | namespace + extmark ID     | Inline comment virtual text          |
| `extmark.file-comment` | namespace + extmark ID     | File-level comment indicator         |

#### SCR-COMMENT-01: Comment input

A floating window buffer for entering a comment. Opens anchored below the
current diff line.

**Behavior**: The buffer starts in insert mode. A dedicated mapping (`<C-s>`)
confirms the comment from any mode. `<Esc>` exits insert mode to normal mode
(standard Neovim behavior). `q` in normal mode cancels and closes the float
without saving. Multi-line comments are supported; `<CR>` in normal mode
retains its default behavior (cursor movement) so multi-line editing works.

**Filetype**: The float buffer uses the custom filetype `codereview` (not
`markdown`) so third-party LSP servers configured for `markdown` (e.g.,
Marksman) do not attach to the transient scratch buffer and crash when it
is deleted on confirm/cancel. The plugin sets `syntax = "markdown"`
manually after the filetype is applied, so markdown highlighting (bold,
code spans, fenced blocks) is still available inside the comment.

**Logical identifiers**:

| Logical ID            | Neovim object | Description                          |
|-----------------------|---------------|--------------------------------------|
| `float.comment-input` | window handle | The floating window                  |
| `buf.comment-input`   | buffer handle | The scratch buffer inside the float  |

#### SCR-SUMMARY-01: Review summary

A read-only floating window shown before the review is saved. Lists all
comments grouped by file, with line numbers. The user can confirm or cancel.

**Logical identifiers**:

| Logical ID       | Neovim object | Description                          |
|------------------|---------------|--------------------------------------|
| `float.summary`  | window handle | The summary floating window          |
| `buf.summary`    | buffer handle | The summary buffer                   |

### 4.2 Keybindings

All keybindings are buffer-local mappings set via
`vim.keymap.set("n", key, fn, { buffer = bufnr })`. The plugin sets these
mappings when it creates each diff or panel buffer. Mappings are removed
automatically when the buffer is wiped.

For the file panel, mappings are set on the file-panel buffer (filetype
`codereview-panel`). For the diff panel, mappings are set on each diff buffer.

Default mappings (user configurable; see REQ-UIX-0008):

| Key          | Context        | Action                                  |
|--------------|----------------|-----------------------------------------|
| `<leader>Rc` | diff panel    | Add line comment at cursor              |
| `<leader>Rf` | file panel    | Add file-level comment for the file shown in the diff (resolved via `render.current_path()`) |
| `<leader>Rd` | diff panel    | Delete comment at cursor                |
| `<leader>Rs` | any           | Show review summary and submit          |
| `<leader>Rq` | any           | Cancel review                           |
| `<leader>Rp` | any           | Pause review                            |
| `<C-s>`      | comment float | Confirm comment (works in any mode)     |
| `q`          | comment float | Cancel comment, close float             |
| `q`          | summary       | Cancel summary, return to diff          |
| `<CR>`       | summary       | Confirm and save review                 |

### 4.3 Extmark rendering

Comments are rendered using `vim.api.nvim_buf_set_extmark()` within a
dedicated namespace created via `vim.api.nvim_create_namespace("code_review")`.
All comment extmarks use this namespace. This allows bulk operations (clearing
all comments from a buffer) and prevents ID collisions with other plugins.

Properties:

- `virt_lines`: one or more virtual lines below the commented line. Each
  virtual line is a list of `{text, hl_group}` chunk tuples:
  `virt_lines = { { { "● comment text here", "CodeReviewComment" } } }`.
  The top-level `hl_group` on the extmark controls the sign text and the
  extmark's range highlight, not the virtual lines.
- `virt_lines_above`: false (comment appears after the line)
- `sign_text`: `●` in the sign column for lines with comments
- `sign_hl_group`: `CodeReviewSign`

**Highlight group defaults**: The plugin defines default highlight groups linked
to standard groups:

```lua
vim.api.nvim_set_hl(0, "CodeReviewComment", { default = true, link = "Comment" })
vim.api.nvim_set_hl(0, "CodeReviewSign", { default = true, link = "DiagnosticInfo" })
vim.api.nvim_set_hl(0, "CodeReviewFileComment", { default = true, link = "Comment" })
vim.api.nvim_set_hl(0, "CodeReviewFileSign", { default = true, link = "DiagnosticHint" })

-- Diff line backgrounds link to the colorscheme's diff groups.
vim.api.nvim_set_hl(0, "CodeReviewAdd", { default = true, link = "DiffAdd" })
vim.api.nvim_set_hl(0, "CodeReviewChange", { default = true, link = "DiffChange" })
vim.api.nvim_set_hl(0, "CodeReviewDelete", { default = true, link = "DiffDelete" })
-- Current file row in the panel.
vim.api.nvim_set_hl(0, "CodeReviewPanelCurrent", { default = true, link = "Visual" })
```

The high-contrast diff accents take background-aware defaults chosen by
`&background` rather than a simple link: `CodeReviewIntraAdd` and
`CodeReviewIntraDelete` highlight the changed words (green on the new side, red
on the old), and `CodeReviewAddSign` / `CodeReviewChangeSign` /
`CodeReviewDeleteSign` colour the `+` / `~` / `-` gutter signs brightly. The
`default = true` flag allows colorschemes and user config to override these
without load-order issues.

**File-level comments** are rendered with two visual elements:

1. A **virtual line above line 1** of the file's diff buffer showing the
   comment text, using highlight group `CodeReviewFileComment`.
2. A **📄 sign in the file panel** on that file's row (`📄` configurable via
   `config.file_sign_text`, highlight group `CodeReviewFileSign`), so a reader
   scanning the file tree sees which files carry a comment without opening
   each. The diff buffer itself carries no file-comment sign.

**Buffer lifecycle**: the plugin creates and destroys diff buffers as the
user navigates files. Extmarks are buffer-local and are lost when a buffer is
wiped. The plugin re-applies extmarks from its in-memory comment store
whenever it (re)creates a file's diff buffers, with a `BufWinEnter` autocmd as
a safety net.

### 4.4 Diff renderer internals

The plugin owns the layout. It keeps a window registry that maps each layout
window to a side (`old` or `new`) and a repo-relative path.

**Side detection**: the plugin compares `vim.api.nvim_get_current_win()`
against the stored old-window and new-window IDs for the current file:

```lua
local win = vim.api.nvim_get_current_win()
if win == registry.old_win then
  side = "old"
elseif win == registry.new_win then
  side = "new"
end
```

**File path resolution**: the repo-relative path is read from the registry
entry for the current diff window. No external API is consulted.

For file-level comments, the target file is the one currently shown in the diff
windows, resolved via `render.current_path()` (valid even when the cursor is in
the panel), not by parsing a panel line.

**Buffer lifecycle**: the plugin re-renders the two diff buffers when the
user selects a different file in the panel. Extmarks are re-applied from the
comment store on (re)creation, with a `BufWinEnter` autocmd as a safety net,
so comments remain visible even if a buffer is recreated.

**Floating windows**: Floating windows (SCR-COMMENT-01, SCR-SUMMARY-01)
are independent Neovim windows. The renderer's layout is tab-scoped and does
not close or rearrange windows it did not create. No special handling is
needed.

### 4.5 Plugin configuration

The plugin is configured via a `setup()` function following Neovim plugin
convention:

```lua
require("code-review").setup({
  keymaps = {
    add_comment = "<leader>Rc",
    file_comment = "<leader>Rf",
    delete_comment = "<leader>Rd",
    summary = "<leader>Rs",
    cancel = "<leader>Rq",
    pause = "<leader>Rp",
    confirm_comment = "<C-s>",
  },
  highlights = {
    comment = { link = "Comment" },
    sign = { link = "DiagnosticInfo" },
    file_comment = { link = "Comment" },
    file_sign = { link = "DiagnosticHint" },
    -- High-contrast diff accents. Defaults are background-aware; override any.
    intra_add = { bg = "#1f6f3f", fg = "#ffffff", bold = true },
    intra_delete = { bg = "#7a2c33", fg = "#ffffff", bold = true },
    add_sign = { fg = "#3fb950", bold = true },
    change_sign = { fg = "#d29922", bold = true },
    delete_sign = { fg = "#f85149", bold = true },
    panel_current = { link = "Visual" },
  },
  sign_text = "●",
})
```

### 4.6 `:CodeReviewSubmit` command

`:CodeReviewSubmit` is a user command registered by the plugin when a review
session is active. It triggers the summary screen (SCR-SUMMARY-01). If the
user confirms, the review is saved. The command is removed when no review
session is active. It is equivalent to pressing the summary keybinding
(`<leader>Rs`).

### 4.7 `:CodeReviewCopy` command

`:CodeReviewCopy` exports the current review as GitHub-flavored Markdown to
the system clipboard. Available during an active review session. The export
is designed for pasting into an LLM chat, so it captures only the reviewer's
comments. It deliberately omits diff hunks (the agent already has the diff)
and any review-level metadata. The format:

````markdown
# Code Review Comments

A human reviewer left the following comments on a code change. Each
comment is anchored to either a file or a specific line within a
file. File paths are relative to the repository root. Line-level
comments include the line number and the side of the diff:

- **new** — line in the post-change version of the file
- **old** — line in the pre-change version of the file

Use these comments to understand what the reviewer wants changed,
clarified, or kept as-is in the next iteration.

## `src/example.lua`

Overall this file needs a refactor.

- **Line 42 (new)**
  This validation looks incomplete. Need HMAC verification.
- **Line 47 (new)**
  This needs a comment explaining the magic number.

## `tests/test_example.py`

- **Line 10 (old)**
  Why was this assertion removed?
````

If the review has no comments, the body is `(The reviewer left no
comments.)` after the preamble.

### 4.8 Session management

**`:CodeReviewPause`**: Saves the current review session state and closes
the diff UI. The session is stored at
`~/.local/share/nvim/code-review/<project-hash>/sessions/<session-id>.json`.
Neovim does not exit. The user returns to their normal editing session.

Session state includes:

- All comments (line and file)
- The diff range (type, base, head)
- The list of files with comments
- Timestamp of creation and last modification

**`:CodeReviewSessions`**: Lists saved sessions for the current project in
a floating window. Each entry shows the diff range, comment count, and
last modified date. Selecting an entry resumes the session: opens the diff
view with the same range, restores all comments and extmarks.

**Session lifecycle**:

- Created: when `:CodeReviewPause` is called
- Resumed: when selected from `:CodeReviewSessions`
- Deleted: when the resumed session is submitted via `:CodeReviewSubmit`
- A session can be resumed and paused multiple times

### 4.9 Quit interception

When the user quits Neovim (`:qa`, `ZQ`, or `:q` on the last window) without
having submitted, the plugin intercepts the exit via a `VimLeavePre` autocmd,
lets the quit proceed, creates no review file, and in agent mode exits with
code 2. `VimLeavePre` is used rather than `QuitPre` because `QuitPre` cannot
distinguish a `:q` that closes one of several diff panes from a full quit; a
`:q` that only closes a pane leaves the review running. The summary screen
(SCR-SUMMARY-01) is shown by the submit keymap, not on quit.

The plugin does not prevent quitting. A quit without submitting is treated as
cancellation, not as an empty review.

**Working-tree review caveat**: The review JSON captures the diff as it
appeared at review time. Subsequent edits to the working tree are not
reflected in the stored `diff_hunk` context.

## 5. CLI Interface Spec

### 5.1 Invocation

```text
nvim -c 'CodeReview [<range>]'
```

The invoking process must have a controlling terminal (TTY). If stdin is not a
TTY, Neovim cannot render the TUI and the review session cannot proceed.
Agents that invoke this command must allocate a PTY or use a terminal
multiplexer.

**Range formats**:

| Format | Diff type | Example |
|---|---|---|
| (empty) | Working tree vs HEAD | `CodeReview` |
| `<rev>` | Single commit vs its parent | `CodeReview abc1234` |
| `<rev>..<rev>` | Commit range (diff A against B) | `CodeReview main..feature` |
| `<rev>...<rev>` | Symmetric difference (merge-base to tip, equivalent to `git diff A...B`) | `CodeReview main...feature` |

**Validation**: The plugin validates the range argument before opening
the diff view. If the range does not parse as one of the four formats above, or if
the referenced revisions do not exist, the plugin exits with code 1 and a
diagnostic (see REQ-ERR-0001, REQ-ERR-0007).

### 5.2 Exit behavior

The plugin writes the review file path to a result file rather than stdout,
since Neovim uses stdout for terminal rendering.

**Result file**: The plugin writes the audit trail file path to the path
specified by the `$NVIM_CODE_REVIEW_RESULT` environment variable. If the
variable is unset, the plugin writes to `$TMPDIR/nvim-code-review-result`
(or `/tmp/nvim-code-review-result` if `$TMPDIR` is unset). The file
contains the absolute path to the review JSON file as a single line, with
no trailing newline.

The submit and cancel behavior depends on the **invocation mode**, which is
determined by whether `$NVIM_CODE_REVIEW_RESULT` is set:

- **Agent mode**: `$NVIM_CODE_REVIEW_RESULT` is set in the environment.
  Neovim was launched by an agent that is blocked waiting for the review.
  Submit and cancel must signal completion by exiting Neovim with a
  meaningful exit code so the agent can react.
- **Interactive mode**: `$NVIM_CODE_REVIEW_RESULT` is unset. The user
  launched the review themselves from an existing Neovim session. Submit
  and cancel should close the review UI but leave Neovim running.

**Submit, agent mode** (`$NVIM_CODE_REVIEW_RESULT` set):

- Write the review JSON to the audit trail directory (section 3.1)
- Write the audit trail file path to `$NVIM_CODE_REVIEW_RESULT`
- Force-quit Neovim via `:quitall!`. With `nofile` diff buffers nothing is
  flagged modified, so the `!` is not strictly needed; it stays as a
  defensive guard against any incidental modified scratch state.
- Exit code: 0

**Submit, interactive mode** (`$NVIM_CODE_REVIEW_RESULT` unset):

- Write the review JSON to the audit trail directory (section 3.1)
- Export the review as GitHub-flavored Markdown to the system clipboard
  (same format as `:CodeReviewCopy`)
- Close the diff view, end the review session, leave Neovim running
- Notify the user with the audit trail path and a confirmation that the
  clipboard was populated
- No exit code (Neovim does not exit)

**Empty review**: An empty review (no comments) follows the
same submit path as a non-empty review. The audit trail file is created
with an empty `files` array.

**Cancel, agent mode** (`$NVIM_CODE_REVIEW_RESULT` set):

- No audit trail file is written
- `$NVIM_CODE_REVIEW_RESULT` is not written (or is left empty)
- Force-quit Neovim with exit code 2

**Cancel, interactive mode** (`$NVIM_CODE_REVIEW_RESULT` unset):

- No audit trail file is written
- Close the diff view, end the review session, leave Neovim running
- Notify the user that the review was cancelled
- No exit code

**Error exit**:

- Print diagnostic message to stderr in the format:
  `code-review: <error-type>: <human-readable message>`
  where `<error-type>` is one of: `invalid_range`, `no_git`, `not_a_repo`,
  `version_error`, `storage_error`, `plugin_error`
- Exit code: 1
- No review file is created
- Result file is not written

An API consumer can distinguish the three outcomes:

| Exit code | Result file      | Meaning |
|-----------|------------------|---------|
| 0         | has file path    | Review submitted (may be empty; check `files` array) |
| 2         | empty/absent     | User cancelled without submitting |
| 1         | empty/absent     | Error occurred |

Consumers that need to distinguish error categories should parse the
`<error-type>` token. The human-readable message is not stable across
versions.

### 5.3 Agent integration example

```bash
export NVIM_CODE_REVIEW_RESULT=$(mktemp)
nvim -c 'CodeReview HEAD~3..HEAD' 2>/tmp/nvim-review-err.log
exit_code=$?
if [ $exit_code -eq 0 ]; then
  review_path=$(cat "$NVIM_CODE_REVIEW_RESULT")
  review=$(cat "$review_path")
  # parse $review as JSON and act on feedback
elif [ $exit_code -eq 2 ]; then
  echo "Review cancelled by user"
fi
rm -f "$NVIM_CODE_REVIEW_RESULT" /tmp/nvim-review-err.log
```

### 5.4 Timeout and non-interactive considerations

The spec does not define a timeout. A review session lasts until the user
submits or quits. Agents that need a timeout should implement it externally
(e.g., `timeout 600 nvim ...`) and treat the resulting SIGTERM/exit code 124
as a cancellation.

## 6. Requirements

Requirements use EARS (Easy Approach to Requirements Syntax) patterns:

- **Ubiquitous**: The system shall...
- **Event-driven**: When \<event\>, the system shall...
- **State-driven**: While \<state\>, the system shall...
- **Optional-feature**: Where \<feature\>, the system shall...
- **Unwanted-behavior**: If \<condition\>, then the system shall...

### 6.1 Diff display (REQ-DIF)

**REQ-DIF-0001** (Ubiquitous): The system shall display diffs using its
built-in side-by-side renderer in the layout defined by SCR-DIFF-01.

**REQ-DIF-0002** (Event-driven): When invoked with no range argument, the system
shall display the working tree diff against HEAD.

**REQ-DIF-0003** (Event-driven): When invoked with a single revision, the system
shall display that commit's diff against its parent.

**REQ-DIF-0004** (Event-driven): When invoked with a two-dot revision range
(`A..B`), the system shall display the diff of all commits reachable from B but
not from A (equivalent to `git diff A..B`).

**REQ-DIF-0005** (Event-driven): When invoked with a three-dot revision range
(`A...B`), the system shall display the diff from the merge-base of A and B to
B (equivalent to `git diff A...B`).

**REQ-DIF-0006** (State-driven): While the diff type is `working_tree`, the
system shall display the working tree as-is, without staging or stashing
changes.

**REQ-DIF-0007** (State-driven): While a review session is active, all
diff buffers (both old and new sides, all diff types) shall be set
non-modifiable so the user cannot accidentally edit through the diff view.
The plugin sets `vim.bo[bufnr].modifiable = false` on each diff buffer after
its lines are filled. The new-side buffer is a `nofile` copy of the head
content, not the on-disk file.

### 6.2 Commenting (REQ-CMT)

**REQ-CMT-0001** (Event-driven): When the user presses the add-comment
keybinding on a diff line, the system shall open a comment input float
(SCR-COMMENT-01) anchored to that line. The float shall open in insert mode.

**REQ-CMT-0002** (Event-driven): When the user confirms a comment in
SCR-COMMENT-01, the system shall store the comment in memory and render it as
an extmark per REQ-UIX-0003.

**REQ-CMT-0003** (Event-driven): When the user presses the file-comment
keybinding, the system shall open a comment input float for the currently
selected file.

**REQ-CMT-0005** (Event-driven): When the user presses the delete-comment
keybinding on a line with an existing comment, the system shall remove that
comment from memory and remove the corresponding extmark.

**REQ-CMT-0006** (Ubiquitous): The system shall accept, store, persist, and
render comments containing multiple lines of text, preserving line breaks in
the `body` field of the review JSON and in the extmark virtual text.

**REQ-CMT-0007** (Event-driven): When the user cancels the comment input float
(SCR-COMMENT-01), the system shall discard any text entered and close the
floating window without storing a comment.

**REQ-CMT-0008** (Event-driven): When the user presses the add-comment
keybinding on a diff line that already has a comment, the system shall open the
comment input float (SCR-COMMENT-01) pre-populated with the existing comment
text, and on confirmation replace the existing comment.

**REQ-CMT-0010** (Ubiquitous): The comment input float buffer shall have
filetype `codereview` (not `markdown`) so third-party LSP servers
configured for `markdown` (e.g., Marksman) do not attach to the transient
scratch buffer and error when it is deleted. Syntax highlighting is
provided by setting `syntax = "markdown"` directly on the buffer after
the filetype is set.

**REQ-CMT-0009** (Unwanted-behavior): If the user confirms the comment input
float with an empty body (no non-whitespace characters), then the system shall
discard the comment and close the float without storing an extmark.

**REQ-CMT-0011** (Event-driven): When the user confirms or cancels the comment
input float, the system shall return the editor to normal mode. The confirm key
is bound in insert mode, so closing the float shall drop insert mode rather than
leave the underlying diff or panel buffer in insert mode.

### 6.3 File storage (REQ-STO)

**REQ-STO-0001** (Event-driven): When the user submits a review, the system
shall write the review JSON to the audit trail directory at
`~/.local/share/nvim/code-review/<project-hash>/<timestamp>.json`.

**REQ-STO-0002** (Ubiquitous): The system shall generate review IDs in the
format `YYYYMMDDTHHMMSS` (UTC).

**REQ-STO-0003** (Event-driven): When the user submits a review and
`$NVIM_CODE_REVIEW_RESULT` is set (agent mode), the system shall write the
absolute path of the saved review JSON file to that path.

**REQ-STO-0008** (Event-driven): When the user submits a review and
`$NVIM_CODE_REVIEW_RESULT` is unset (interactive mode), the system shall
export the review as GitHub-flavored Markdown to the system clipboard in
addition to writing the audit trail file.

**REQ-STO-0004** (Ubiquitous): The review JSON shall conform to the schema
defined in section 3.2.

**REQ-STO-0005** (Ubiquitous): Each `files[].lines[]` entry shall include
the full unified-diff hunk (from `@@` header through the last line of the
hunk) that contains the commented line, stored in the `diff_hunk` field.

**REQ-STO-0006** (Event-driven): When the user exits without adding any
comments, the system shall create a review file with an empty
`files` array.

**REQ-STO-0007** (Ubiquitous): The review JSON `diff_spec` object shall
record the diff type, the base revision (as full 40-character SHA), and the
head revision, resolved at review time.

### 6.4 CLI / agent interface (REQ-CLI)

**REQ-CLI-0001** (Event-driven): When invoked via `nvim -c 'CodeReview
<range>'`, the system shall parse the range argument and open the
corresponding diff.

**REQ-CLI-0002** (Event-driven): When a review session ends normally in
agent mode (`$NVIM_CODE_REVIEW_RESULT` is set), the system shall write
the review file path to the result file and force-quit Neovim with exit
code 0.

**REQ-CLI-0005** (Event-driven): When a review session ends normally in
interactive mode (`$NVIM_CODE_REVIEW_RESULT` is unset), the system shall
close the diff view and leave Neovim running, without exiting.

**REQ-CLI-0003** (Event-driven): When the user executes `:CodeReviewCopy`,
the system shall export the current review as GitHub-flavored Markdown
(format defined in section 4.7) to the system clipboard, containing only
the reviewer's comments (no diff hunks, no metadata).

**REQ-CLI-0004** (Ubiquitous): The review JSON shall be self-contained: any
consumer shall be able to read the review by parsing the JSON file without
needing the plugin installed.

**REQ-CLI-0006** (Event-driven): When the user executes `:CodeReviewCancel`
during an active review session, the system shall discard all in-memory
comments, close the diff view, and:
- In agent mode (`$NVIM_CODE_REVIEW_RESULT` set), exit Neovim with code 2.
- In interactive mode, leave Neovim running and display a `vim.notify`
  message confirming the cancellation.

**REQ-CLI-0007** (Event-driven): When the user executes `:CodeReviewPause`
during an active review session, the system shall save the session JSON
(per REQ-SES-0003) to the sessions directory, close the diff view, leave
Neovim running, and display a `vim.notify` message containing the saved
session ID.

**REQ-CLI-0008** (Ubiquitous): The plugin shall register four user commands
that are only valid during an active review session: `:CodeReviewSubmit`,
`:CodeReviewCancel`, `:CodeReviewPause`, `:CodeReviewCopy`. These commands
shall be removed from the command list when no session is active. The
always-available commands `:CodeReview` and `:CodeReviewSessions` are
registered at plugin load.

### 6.5 UI interaction (REQ-UIX)

**REQ-UIX-0001** (Event-driven): When the user presses the summary keybinding,
the system shall display a read-only summary (SCR-SUMMARY-01) listing all
comments grouped by file path, with line numbers for line-level comments and
the total comment count, and wait for confirmation or
cancellation.

**REQ-UIX-0002** (Event-driven): When the user confirms the summary, the system
shall save the review and exit.

**REQ-UIX-0003** (Ubiquitous): The system shall render line comments as virtual
lines below the commented diff line using the `CodeReviewComment` highlight
group, with the extmark logical ID `extmark.comment` (see REQ-CMT-0002).

**REQ-UIX-0004** (Ubiquitous): The system shall display a sign column indicator
(`●`) in the `CodeReviewSign` highlight group on lines that have comments.

**REQ-UIX-0005** (Ubiquitous): All keybindings shall be user-configurable via
the plugin's `setup()` function (see section 4.5).

**REQ-UIX-0006** (Ubiquitous): The system shall indicate a file-level comment
in two places: a 📄 sign in the file panel's gutter on that file's row
(highlight `CodeReviewFileSign`), so the reader sees which files carry a comment
without opening each, and a virtual line above line 1 of the file's diff buffer
showing the comment body (highlight `CodeReviewFileComment`). The diff buffer
itself carries no file-comment sign.

**REQ-UIX-0007** (Event-driven): When the user quits Neovim without submitting
a review, the system shall intercept the exit via `VimLeavePre`, allow the quit
to proceed, create no review file, and exit with code 2 (see section 4.9).

**REQ-UIX-0008** (Ubiquitous): Default keybindings shall use the `<leader>R`
prefix (Review) to avoid collision with common LazyVim/which-key
`<leader>c*` (code) bindings. Defaults: `<leader>Rc` (add line comment),
`<leader>Rf` (file comment), `<leader>Rd` (delete comment), `<leader>Rs`
(submit / show summary), `<leader>Rq` (cancel), `<leader>Rp` (pause), and
`<C-s>` (confirm comment in float). All keybindings are configurable via
`setup({ keymaps = { ... } })` (see REQ-UIX-0005).

**REQ-UIX-0010** (Optional-feature): Where a value in the `keymaps`
table passed to `setup()` is `false`, the system shall skip registering
that keybinding entirely. This lets users disable a default and bind
their own action with `vim.keymap.set` without colliding with the
plugin's default.

**REQ-UIX-0009** (Event-driven): When the user invokes submit (via
`<leader>Rs` or `:CodeReviewSubmit`), the summary float (SCR-SUMMARY-01)
shall display the exact Markdown that would be exported on confirmation
(per section 4.7), preceded by a one-line mode note describing the effect
of confirming (e.g., "Confirming will copy the markdown below to your
clipboard and close the review" in interactive mode, "Confirming will
write to the result file and exit Neovim" in agent mode).

**REQ-UIX-0011** (Ubiquitous): The comment input float (SCR-COMMENT-01) shall
state in its title whether the comment is line-level ("Line comment") or
file-level ("File comment: <file>", naming the file), and shall be sized to give
room for multi-line comments (width up to 70% of the editor, height growing with
the prefilled content).

### 6.6 Error handling (REQ-ERR)

**REQ-ERR-0001** (Unwanted-behavior): If the specified range resolves to zero
commits and the diff type is not `working_tree`, then the system shall exit with
code 1 and print a diagnostic to stderr.

**REQ-ERR-0002** (Unwanted-behavior): If git is not available on PATH, then the
system shall exit with code 1 and print a diagnostic to stderr.

**REQ-ERR-0003** (Unwanted-behavior): If the current directory is not inside a
git repository, then the system shall exit with code 1 and print a diagnostic to
stderr.

**REQ-ERR-0004** (Unwanted-behavior): If the audit trail directory cannot be
created or written to, then the system shall exit with code 1 and print a
diagnostic to stderr.

**REQ-ERR-0006** (Unwanted-behavior): If the Neovim version is below 0.10, then
the system shall exit with code 1 and print a diagnostic to stderr identifying
the minimum required version.

**REQ-ERR-0007** (Unwanted-behavior): If the range argument contains a revision
that cannot be resolved by git, then the system shall exit with code 1 and print
a diagnostic to stderr identifying the unresolvable revision.

**REQ-ERR-0008** (Unwanted-behavior): If Neovim is running without an
interactive UI (headless, `nvim_list_uis()` empty), then the system shall exit
with code 1 and print a diagnostic to stderr. The review is interactive and
cannot collect comment input without an attached UI. (Stated as "stdin not a
TTY" originally; `nvim_list_uis()` is the reliable signal because a redirected
stderr alone flips stdin's handle type even with a UI attached.)

### 6.7 Session management (REQ-SES)

**REQ-SES-0001** (Event-driven): When the user executes `:CodeReviewPause`,
the system shall save the current session state to the sessions directory
and close the diff UI without exiting Neovim.

**REQ-SES-0002** (Event-driven): When the user executes
`:CodeReviewSessions`, the system shall display a list of saved sessions
for the current project in a floating window.

**REQ-SES-0003** (Ubiquitous): Session state shall include all comments,
the diff range, and the timestamp of creation and last
modification.

**REQ-SES-0004** (Event-driven): When the user selects a session from the
session list, the system shall resume the session by opening the diff view
with the saved range and restoring all comments.

**REQ-SES-0005** (Event-driven): When a resumed session is submitted, the
system shall delete the session file.

**REQ-SES-0006** (Event-driven): When the user executes `:CodeReviewSessions`
and one or more sessions exist, the system shall present a `vim.ui.select`
picker where each entry displays: the first 8 characters of the session ID,
the diff range string, the comment count, and the last modified timestamp.
When the user selects an entry, the system shall resume that session.

### 6.8 LSP handling (REQ-LSP)

Third-party LSP clients configured for `markdown` (such as Marksman) can
crash when a transient scratch buffer is deleted, because the buffer does
not resolve to a real file on disk and the LSP's `textDocument/didClose`
handler may attempt to re-read the file. The plugin's diff buffers avoid
this entirely by being `buftype=nofile` (see REQ-RND-0005), which prevents
LSP attach. This category of requirements isolates the plugin's floats from
such LSPs.

**REQ-LSP-0002** (Ubiquitous): The comment input float (SCR-COMMENT-01)
and the summary float (SCR-SUMMARY-01) shall use the custom filetype
`codereview` (not `markdown`) so third-party markdown LSPs do not attach
in the first place. Syntax highlighting is provided by setting
`syntax = "markdown"` manually after the filetype is set.

**REQ-LSP-0003** (Ubiquitous): As a defense-in-depth measure, after the
filetype is set on a float buffer, the plugin shall detach any LSP
clients that did attach (via `vim.lsp.buf_detach_client`) and register a
buffer-local `LspAttach` autocmd to detach any client that attaches
later. Detach is safe for floats (the buffer is transient and the URI is
not on disk to begin with), unlike for diff buffers.

### 6.9 Diff renderer (REQ-RND)

**REQ-RND-0001** (Ubiquitous): Line-level diffs shall be computed with the
built-in `vim.diff()` using `result_type="indices"`,
`algorithm="histogram"`, `linematch=60`, and `indent_heuristic=true`.

**REQ-RND-0002** (Ubiquitous): Within a changed hunk where old and new line
counts permit, the system shall compute word/character-level intra-line
differences using a pure-Lua token diff and highlight the differing tokens
side-specifically: the new side with `CodeReviewIntraAdd` and the old side with
`CodeReviewIntraDelete`, so changed words read as added (green) on the new side
and removed (red) on the old.

**REQ-RND-0003** (Ubiquitous): Each diff buffer shall have treesitter
highlighting started via `vim.treesitter.start(buf, lang)` after its lines
are set. The buffer must be loaded; an unloaded buffer yields an empty tree.

**REQ-RND-0004** (Ubiquitous): The old and new sides shall be visually
aligned with filler rows so corresponding lines occupy the same screen row.

**REQ-RND-0005** (Ubiquitous): Diff buffers shall be created with
`buftype=nofile`, `buflisted=false`, `bufhidden=wipe`, set
`modifiable=false` after fill, and their windows locked with
`winfixbuf=true`. As a consequence no LSP client attaches to them.

**REQ-RND-0006** (Ubiquitous): Per-line change indicators (added/changed/
deleted) shall be shown as extmark gutter signs.

**REQ-RND-0007** (Ubiquitous): The file panel shall present changed files as an
indented directory tree — directory rows for path segments and file (leaf) rows
showing the basename with an M/A/D status marker and a per-file comment-count
indicator — and support `j`/`k`/`<CR>` navigation, where `<CR>` on a file row
re-renders the two diff buffers for that file and `<CR>` on a directory row is a
no-op.

**REQ-RND-0008** (Ubiquitous): The two diff windows shall keep their scroll
and cursor positions synchronized.

**REQ-RND-0009** (Event-driven): When the user moves the cursor in a diff
buffer and adds a comment, the system shall resolve the cursor row to
`{path, side, lineno}` via the renderer's row→line mapping.

**REQ-RND-0010** (Event-driven): When the user invokes next-file or
previous-file navigation, the system shall switch the diff to the
next/previous changed file (wrapping at the ends) and move focus into the
new-side diff window, except on a pure-deletion file (no new-side content)
where it shall focus the old-side window.

**REQ-RND-0011** (Event-driven): When the diff switches to a file (on open,
panel select, or next/previous navigation), the system shall mark that file's
row in the panel with a persistent highlight (`CodeReviewPanelCurrent`) and move
the panel cursor to it, so the file tree shows which file is displayed even
while focus is in a diff window. Exactly one row is marked at a time.

**REQ-RND-0012** (Event-driven): When a review is opened, the system shall place
the cursor in the new-side diff window of the first file (the old-side window for
a pure-deletion file), not in the file panel, so the reviewer starts on the code.

**REQ-RND-0013** (Ubiquitous): The file tree shall draw indentation with
tree-guide connectors, order siblings deterministically (directories before
files, then case-insensitive alphabetical), give each directory segment its own
indented row (no chain collapsing), and abbreviate any label wider than the
panel's inner width with a `~` marker — a file basename keeps its extension
(`stem~.ext`), while a directory segment or an extensionless name end-truncates
(`prefix~`).

**REQ-RND-0014** (Ubiquitous): The file panel width shall be configurable via
`config.values.panel_width` (default 20 columns), applied to the panel window on
open and pinned (`winfixwidth`) so it keeps that width as focus moves between
windows.

## 7. Verification Matrix

| Requirement   | Test ID       | Method   | Description |
|---------------|---------------|----------|-------------|
| REQ-DIF-0001  | TST-DIF-0001  | Manual   | Open plugin, verify the built-in side-by-side layout matches SCR-DIFF-01 |
| REQ-DIF-0002  | TST-DIF-0002  | Auto     | Invoke with no args, verify diff command targets HEAD |
| REQ-DIF-0003  | TST-DIF-0003  | Auto     | Invoke with single rev, verify diff targets parent |
| REQ-DIF-0004  | TST-DIF-0004  | Auto     | Invoke with two-dot range, verify diff targets A..B |
| REQ-DIF-0005  | TST-DIF-0005  | Auto     | Invoke with three-dot range, verify diff targets merge-base...B |
| REQ-DIF-0006  | TST-DIF-0006  | Manual   | Modify file without staging, invoke working-tree review, verify unstaged changes visible |
| REQ-CMT-0001  | TST-CMT-0001  | Manual   | Press add-comment key on diff line, verify float opens in insert mode |
| REQ-CMT-0002  | TST-CMT-0002  | Manual   | Confirm comment, verify extmark appears below line with correct highlight |
| REQ-CMT-0003  | TST-CMT-0003  | Manual   | Press file-comment key, verify float opens for file |
| REQ-CMT-0005  | TST-CMT-0005  | Manual   | Delete comment, verify extmark removed |
| REQ-CMT-0006  | TST-CMT-0006  | Manual   | Enter multi-line comment, verify stored in JSON with line breaks and displayed as multi-line virtual text |
| REQ-CMT-0007  | TST-CMT-0007  | Manual   | Open comment float, press q in normal mode, verify float closes with no comment stored |
| REQ-CMT-0008  | TST-CMT-0008  | Manual   | Add comment on a line, press add-comment on same line, verify float pre-populated; confirm, verify comment replaced |
| REQ-CMT-0009  | TST-CMT-0009  | Manual   | Open comment float, confirm with empty/whitespace body, verify no comment stored |
| REQ-STO-0001  | TST-STO-0001  | Auto     | Submit review, verify JSON file exists in audit trail directory with correct timestamp filename |
| REQ-STO-0002  | TST-STO-0002  | Auto     | Submit review, verify review ID matches `YYYYMMDDTHHMMSS` format and matches the filename stem |
| REQ-STO-0003  | TST-STO-0003  | Auto     | Submit review, verify result file contains the absolute path to the review JSON |
| REQ-STO-0004  | TST-STO-0004  | Auto     | Submit review, validate review JSON against JSON Schema |
| REQ-STO-0005  | TST-STO-0005  | Auto     | Submit review with line comment, verify `diff_hunk` starts with `@@` header and contains the commented line |
| REQ-STO-0006  | TST-STO-0006  | Auto     | Submit without commenting, verify review file exists with empty files |
| REQ-STO-0007  | TST-STO-0007  | Auto     | Submit review for each diff type, verify diff_spec fields contain resolved 40-char SHAs |
| REQ-CLI-0001  | TST-CLI-0001  | Auto     | Invoke with each range format via `-c`, verify correct diff opens |
| REQ-CLI-0002  | TST-CLI-0002  | Auto     | In agent mode, complete review, read result file, verify review file path written and nvim exited |
| REQ-CLI-0005  | TST-CLI-0005  | Auto     | In interactive mode, complete review, verify nvim still running and clipboard contains markdown |
| REQ-STO-0008  | TST-STO-0008  | Auto     | In interactive mode, submit a review with comments, verify clipboard contains markdown export |
| REQ-CLI-0003  | TST-CLI-0003  | Manual   | Execute `:CodeReviewCopy`, verify system clipboard contains GitHub-flavored Markdown with correct structure |
| REQ-CLI-0004  | TST-CLI-0004  | Auto     | Read review JSON file directly, verify valid JSON parseable without the plugin |
| REQ-UIX-0001  | TST-UIX-0001  | Manual   | Press summary key, verify summary lists comments grouped by file with line numbers and count |
| REQ-UIX-0002  | TST-UIX-0002  | Manual   | Confirm summary, verify review saved and Neovim exits |
| REQ-UIX-0003  | TST-UIX-0003  | Manual   | Add comment, verify virtual text rendered with `CodeReviewComment` highlight |
| REQ-UIX-0004  | TST-UIX-0004  | Manual   | Add comment, verify sign column shows `●` with `CodeReviewSign` highlight |
| REQ-UIX-0005  | TST-UIX-0005  | Manual   | Override keybinding in setup, verify new binding works |
| REQ-UIX-0006  | TST-UIX-0006  | Auto     | Add a file-level comment, verify a 📄 sign extmark in the `code_review_panel` namespace on the file's panel row and a virtual line above line 1 of the diff buffer, with no file-comment sign on the diff buffer |
| REQ-DIF-0007  | TST-DIF-0007  | Auto     | Start a working-tree review, verify both diff buffers have `modifiable = false` |
| REQ-CMT-0010  | TST-CMT-0010  | Auto     | Open the comment input float, verify `vim.bo[buf].filetype` is `codereview` (not `markdown`) |
| REQ-CMT-0011  | TST-CMT-0011  | Auto     | Open a comment float, type a note, confirm with the confirm key, verify the editor is back in normal mode (`nvim_get_mode().mode == "n"`), not insert |
| REQ-UIX-0007  | TST-UIX-0007  | Auto     | Quit Neovim without submitting, verify no review file created and exit code is 2 |
| REQ-ERR-0001  | TST-ERR-0001  | Auto     | Invoke with empty range, verify exit code 1 and stderr message |
| REQ-ERR-0002  | TST-ERR-0002  | Auto     | Remove git from PATH, invoke, verify exit code 1 |
| REQ-ERR-0003  | TST-ERR-0003  | Auto     | Invoke outside git repo, verify exit code 1 |
| REQ-ERR-0004  | TST-ERR-0004  | Auto     | Make audit trail directory unwritable, verify exit code 1 and diagnostic to stderr |
| REQ-ERR-0006  | TST-ERR-0006  | Auto     | Mock `vim.version()` to return 0.9, verify exit code 1 and version diagnostic |
| REQ-ERR-0007  | TST-ERR-0007  | Auto     | Invoke with nonexistent branch name, verify exit code 1 and diagnostic naming the revision |
| REQ-ERR-0008  | TST-ERR-0008  | Auto     | Invoke under `nvim --headless` (no UI), verify exit code 1 and stderr diagnostic |
| REQ-SES-0001  | TST-SES-0001  | Manual   | Execute `:CodeReviewPause`, verify session file created in sessions directory and the diff view closed |
| REQ-SES-0002  | TST-SES-0002  | Manual   | Execute `:CodeReviewSessions`, verify floating window lists saved sessions with range, count, and date |
| REQ-SES-0003  | TST-SES-0003  | Auto     | Pause a session, read the session JSON, verify it contains comments, diff range, and timestamps |
| REQ-SES-0004  | TST-SES-0004  | Manual   | Pause a session with comments, resume from session list, verify the diff view reopens with all comments restored |
| REQ-SES-0005  | TST-SES-0005  | Auto     | Resume a paused session and submit, verify the session file is deleted from the sessions directory |
| REQ-SES-0006  | TST-SES-0006  | Manual   | Pause two sessions, run `:CodeReviewSessions`, verify selection picker shows both with id-prefix, range, count, and timestamp; select one, verify it resumes |
| REQ-CLI-0006  | TST-CLI-0006  | Auto     | In interactive mode, start review and run `:CodeReviewCancel`, verify nvim stays running and a notification is shown; in agent mode, verify exit code 2 |
| REQ-CLI-0007  | TST-CLI-0007  | Auto     | Start review, run `:CodeReviewPause`, verify session JSON written and `vim.notify` message contains the session ID |
| REQ-CLI-0008  | TST-CLI-0008  | Auto     | Before session, verify `:CodeReviewSubmit` does not exist; start session, verify it exists; end session, verify it is removed |
| REQ-UIX-0008  | TST-UIX-0008  | Auto     | Verify `vim.api.nvim_buf_get_keymap()` on a diff buffer contains the documented default keys (`<leader>Rc`, `<leader>Rs`, etc.) |
| REQ-UIX-0009  | TST-UIX-0009  | Auto     | Trigger `:CodeReviewSubmit`, capture the summary float content, verify it includes the markdown preamble from section 4.7 |
| REQ-UIX-0010  | TST-UIX-0010  | Auto     | Call `setup({ keymaps = { add_comment = false, delete_comment = false } })`, start a review, verify those keys are not bound on diff buffers while other defaults are |
| REQ-UIX-0011  | TST-UIX-0011  | Manual   | Open the comment float on a line vs a file, verify the title reads "Line comment" / "File comment: <file>" and the float is larger |
| REQ-RND-0001  | TST-RND-0001  | Auto     | Compute a line diff via the renderer, verify `vim.diff()` is called with `result_type="indices"`, `algorithm="histogram"`, `linematch=60`, `indent_heuristic=true` |
| REQ-RND-0002  | TST-RND-0002  | Auto     | Render a changed hunk with a single edited line, verify the differing tokens carry `CodeReviewIntraAdd` on the new side and `CodeReviewIntraDelete` on the old side |
| REQ-RND-0003  | TST-RND-0003  | Auto     | Render a diff buffer for a known filetype, verify treesitter is active (`vim.treesitter.start` ran and the tree is non-empty) on the loaded buffer |
| REQ-RND-0004  | TST-RND-0004  | Manual   | Render a diff with unbalanced add/delete counts, verify filler rows keep corresponding lines on the same screen row |
| REQ-RND-0005  | TST-RND-0005  | Auto     | Render a diff buffer, verify `buftype=nofile`, `buflisted=false`, `bufhidden=wipe`, `modifiable=false`, and window `winfixbuf=true` |
| REQ-RND-0006  | TST-RND-0006  | Auto     | Render a diff with added/changed/deleted lines, verify gutter sign extmarks are present on the corresponding rows |
| REQ-RND-0007  | TST-RND-0007  | Manual   | Open the file panel, verify changed files render as an indented directory tree with file rows showing basename + M/A/D + comment-count; press `<CR>` on a file row, verify the two diff buffers re-render; `<CR>` on a directory row does nothing |
| REQ-RND-0008  | TST-RND-0008  | Manual   | Scroll and move the cursor in one diff window, verify the other window stays in sync |
| REQ-RND-0009  | TST-RND-0009  | Auto     | Place the cursor on a known diff row and add a comment, verify the resolved `{path, side, lineno}` matches the row→line mapping |
| REQ-RND-0010  | TST-RND-0010  | Auto     | Invoke next/previous-file navigation, verify the current file advances (wrapping) and focus moves into the new-side window (old side for a pure-deletion file) |
| REQ-RND-0011  | TST-RND-0011  | Auto     | Switch files, verify exactly one panel row carries a `CodeReviewPanelCurrent` extmark (the current file) and the panel cursor sits on it |
| REQ-RND-0012  | TST-RND-0012  | Auto     | Open a review, verify the current window is the new-side diff window (old side for a pure-deletion file), not the panel |
| REQ-RND-0013  | TST-RND-0013  | Auto     | Render a nested file set; verify the panel shows an indented tree with guide connectors, one directory segment per row, directories-first alphabetical order, and an over-long basename abbreviated to `stem~.ext` keeping its extension |
| REQ-RND-0014  | TST-RND-0014  | Auto     | Set config.values.panel_width and open a review; verify the panel window width equals the configured value |
| REQ-LSP-0002  | TST-LSP-0002  | Auto     | Open the comment float and summary float, verify both have filetype `codereview` (covered by `test_12_float_filetype.sh`) |
| REQ-LSP-0003  | TST-LSP-0003  | Auto     | Open the comment float, verify no LSPs are attached after the filetype is set |
| REQ-RND-0005  | TST-LSP-0001  | Auto     | Start a review whose diff includes a `.md` file; assert no LSP client is attached to either diff buffer (consequence of `buftype=nofile`) |

## 8. Acceptance Criteria

The system is accepted when all of the following hold.

### 8.1 End-to-end scenarios

Each scenario must pass without modification to the test steps.

**AC-E2E-01: Agent review cycle (commit range)**

1. Create a test repo with at least 3 commits.
2. Run `NVIM_CODE_REVIEW_RESULT=$(mktemp) nvim -c 'CodeReview HEAD~2..HEAD'`.
3. In the diff view, add a line comment on a changed line and a file comment.
4. Submit via `:CodeReviewSubmit`.
5. Verify: exit code is 0, result file contains an absolute path to a JSON
   file in the audit trail directory. Reading that file returns valid JSON
   with the comment text and correct line numbers.

**AC-E2E-02: Agent review cycle (working tree)**

1. In a git repo, modify a tracked file without staging.
2. Run `NVIM_CODE_REVIEW_RESULT=$(mktemp) nvim -c 'CodeReview'`.
3. Add a line comment.
4. Submit.
5. Verify: exit code 0, `review.json` has `diff_spec.type` of `working_tree`,
   `diff_spec.base` contains the resolved HEAD SHA, `diff_spec.head` is null.

**AC-E2E-03: Empty review (no comments)**

1. Run `NVIM_CODE_REVIEW_RESULT=$(mktemp) nvim -c 'CodeReview HEAD~1..HEAD'`.
2. Submit without adding any comments.
3. Verify: exit code 0, result file contains a file path, the review JSON has
   an empty `files` array.

**AC-E2E-04: User cancellation**

1. Run `NVIM_CODE_REVIEW_RESULT=$(mktemp) nvim -c 'CodeReview HEAD~1..HEAD'`.
2. Add a comment, then quit with `:qa!` without submitting.
3. Verify: exit code is 2, result file is empty or absent, no new review
   file exists in the audit trail directory.

**AC-E2E-05: Error on bad input**

1. Run `NVIM_CODE_REVIEW_RESULT=$(mktemp) nvim -c 'CodeReview nonexistent..HEAD'`.
2. Verify: exit code is 1, stderr contains a diagnostic naming the unresolvable
   revision, no review file is created.

**AC-E2E-06: Review JSON is self-contained**

1. Complete a review on a commit range.
2. Read the review JSON file directly from the audit trail directory.
3. Without the plugin installed, parse the JSON and extract: the diff type,
   base and head SHAs, all file paths, all line numbers, and all comment
   bodies.
4. Verify: every field required by the schema in section 3.2 is present and
   parseable. No field requires the plugin or Neovim to interpret.

**AC-E2E-07: Clipboard export**

1. Start a review on a commit range and add line and file comments.
2. Execute `:CodeReviewCopy`.
3. Verify: system clipboard contains GitHub-flavored Markdown with headings
   per file, diff hunks in fenced code blocks, comment text, and a summary
   section with total count.

**AC-E2E-08: Session pause and resume**

1. Start a review, add two comments, and execute `:CodeReviewPause`.
2. Verify: the diff view closes, Neovim remains open, a session file exists in
   the sessions directory.
3. Execute `:CodeReviewSessions`, select the saved session.
4. Verify: the diff view reopens with the same range, both comments are visible
   as extmarks.
5. Submit the resumed session.
6. Verify: the session file is deleted, a review file is created in the
   audit trail directory with both comments.

### 8.2 Quality gates

All gates must pass before a version is tagged.

| Gate | Criterion |
|------|-----------|
| Unit tests | All automated tests in the verification matrix (TST-*) pass |
| Manual tests | All manual tests in the verification matrix executed and recorded as pass |
| Schema validation | `review.json` output validates against `schema/review.v1.json` for every end-to-end scenario |
| Dependency check | Plugin loads and reports a clear error when Neovim < 0.10 or git is missing |
| Portable reads | Review files are valid JSON parseable without the plugin by any JSON parser |
| No data loss | Comments entered in the UI appear in the persisted JSON without truncation or encoding errors |
| Exit code contract | Exit codes match section 5.2 for all three paths (submit, cancel, error) |

### 8.3 Out-of-scope for acceptance

These are not acceptance criteria and should not block a release:

- Performance benchmarks (the tool is interactive; human review speed dominates)
- Multi-platform testing beyond the developer's primary OS
- Compatibility with Neovim nightly builds ahead of the version floor
- Review listing, search, or cleanup commands (section 3.4 documents manual cleanup)
