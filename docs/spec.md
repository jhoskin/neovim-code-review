# neovim-code-review Specification

Version: 0.1.0-draft
Date: 2026-05-26

## 1. Overview

### 1.1 Purpose

A local code review tool for reviewing LLM coding agent output inside Neovim.
A coding agent launches Neovim into a diff view. The reviewer adds comments on
diff lines, files, or the review as a whole. On exit, the review is persisted as
a custom git ref containing JSON. The agent reads the ref and acts on the
feedback.

### 1.2 Scope

- Display diffs for working tree, branch, or commit range
- Line-level, file-level, and review-level comments
- Persist reviews as git refs in the local repository
- Blocking CLI interface for agent invocation
- JSON output readable by any tool that can call `git`

### 1.3 Non-goals

- Remote sync (no push to GitHub, Gerrit, or any server)
- Comment threading or replies
- Structured approval workflow (no approve/reject/merge)
- Multi-round review sessions (each session is independent)
- Automatic staging or stashing of working tree changes

## 2. Architecture

```text
┌─────────────────────────────────────────────┐
│                  Neovim >= 0.10              │
│                                             │
│  ┌──────────────┐    ┌───────────────────┐  │
│  │ code-review  │───>│  diffview.nvim    │  │
│  │   plugin     │    │  (diff rendering) │  │
│  │   (Lua)      │    └───────────────────┘  │
│  │              │                           │
│  │  ┌────────────────────────────────┐      │
│  │  │ comment layer                  │      │
│  │  │ (extmarks + virtual text)      │      │
│  │  └────────────────────────────────┘      │
│  │              │                           │
│  │  ┌────────────────────────────────┐      │
│  │  │ storage layer                  │      │
│  │  │ (vim.system → git CLI)         │      │
│  │  └────────────────────────────────┘      │
│  └──────────────┘                           │
└─────────────────────────────────────────────┘
                    │
                    ▼
          .git/refs/reviews/<id>
          (commit → tree → review.json)
```

### 2.1 Dependencies

| Dependency    | Version   | Purpose                        |
|---------------|-----------|--------------------------------|
| Neovim        | >= 0.10   | `vim.system()` (added in 0.10), `sign_text` in extmarks (added in 0.10), `nvim_buf_set_extmark` with `virt_lines` (added in 0.8). The binding floor is `vim.system()`. |
| diffview.nvim | latest    | Diff rendering ([dlyongemallo/diffview.nvim](https://github.com/dlyongemallo/diffview.nvim)). Required because upstream sindrets/diffview.nvim is archived. If upstream revives or a community fork supersedes this one, switch to it. |
| git           | >= 2.30   | Plumbing commands (`hash-object`, `mktree`, `commit-tree`, `update-ref`, `for-each-ref`). All plumbing commands used are available since git 1.x; the 2.30 floor may be lowerable. |

### 2.2 Data flow

1. Agent invokes `nvim -c 'CodeReview <range>'`
2. Plugin parses the range, opens diffview via `:DiffviewOpen <args>` (executed
   with `vim.cmd`). For a working-tree diff: `:DiffviewOpen`. For a commit
   range: `:DiffviewOpen <base>..<head>`. For branch divergence:
   `:DiffviewOpen <base>...<head>`. For a single commit:
   `:DiffviewOpen <commit>^..<commit>`.
3. User navigates diffs, adds comments via keybindings
4. Comments are held in memory and rendered as extmarks
5. User finishes review (`:CodeReviewSubmit` or summary confirmation). If the
   user quits Neovim without submitting (`:q`, `:qa`, `ZQ`), no review is
   persisted and the exit code is 2.
6. Plugin serializes review to JSON
7. Plugin writes JSON blob to git object store, builds commit, creates ref
8. Plugin writes ref name to the result file (see section 5.2), exits Neovim

The storage layer calls git plumbing commands via `vim.system()` (Neovim
\>= 0.10). Each call may be synchronous (`:wait()`) since the plumbing
commands complete in milliseconds and run only at submission time. Errors at
any step abort the sequence and trigger the error exit path (REQ-ERR-0004).

## 3. Data Model

### 3.1 Git ref structure

Each review is stored as a commit under the `refs/reviews/` namespace.

**Ref naming**: `refs/reviews/<id>` where `<id>` has the format
`YYYYMMDDTHHMMSS-<8-char-commit-sha>`. The timestamp component is UTC. The
ref name is written after the commit is created, so the commit SHA is known at
that point. Inside `review.json`, the `id` field stores only the timestamp
portion (`YYYYMMDDTHHMMSS`), because the commit SHA cannot be embedded inside
its own content (hash cycle). The ref name is the authoritative identifier; the
JSON `id` is for correlation.

**Transfer behavior**: `git clone` and `git fetch` transfer only
`refs/heads/*` and `refs/tags/*` by default. Reviews stored under
`refs/reviews/*` will not appear in clones unless the remote's fetch refspec
is configured (e.g., `+refs/reviews/*:refs/reviews/*`). This is consistent
with the non-goal of remote sync (section 1.3).

**Commit topology**:

```text
refs/reviews/20260526T143000-a1b2c3d4
  │
  ▼
commit (review commit)
  ├── parent: single parent (see rules below)
  └── tree
       └── review.json (blob)
```

The review commit has exactly one parent:

- **Single-commit review** (`CodeReview abc1234`): the reviewed commit.
- **Range review** (`CodeReview A..B`): commit B (the tip of the range). The
  base A is recorded in `diff_spec.base`.
- **Three-dot review** (`CodeReview A...B`): commit B. The merge-base is
  recorded in `diff_spec.base`.
- **Working-tree review** (`CodeReview` with no args): HEAD at the time of
  review.

**Reachability and garbage collection**: Because the review commit lists the
reviewed commit as a parent, that commit (and its ancestors) is reachable from
the review ref. `git gc` will not prune it. This is intentional: the reviewed
code should not disappear while the review exists. To release pinned objects,
delete the review ref with `git update-ref -d refs/reviews/<id>` before
running `git gc`.

**Creation sequence** (git plumbing):

```bash
# review.json is assembled in memory; id contains only the timestamp
review_json='{"version":1,"id":"20260526T143000",...}'
blob_sha=$(printf '%s' "$review_json" | git hash-object -w --stdin)
tree_sha=$(printf "100644 blob %s\treview.json\n" "$blob_sha" | git mktree)
commit_sha=$(git commit-tree "$tree_sha" -p "$parent_commit" \
  -m "code-review: 20260526T143000-${commit_sha_placeholder}")
git update-ref "refs/reviews/20260526T143000-${commit_sha:0:8}" "$commit_sha"
```

In the Lua implementation, the plugin uses `vim.system()` with `--stdin` to
pipe the JSON, then writes the ref using the first 8 characters of the
resulting commit SHA.

The commit message format is `code-review: <review-id>`. Including the review
ID makes `git log refs/reviews/` output informative without reading each blob.

The author and committer fields are populated from the user's git config
(`user.name`, `user.email`). The plugin does not override these.

**Failure modes**: The four commands are not atomic. If the process fails
between `commit-tree` and `update-ref`, the blob, tree, and commit objects
exist but are unreferenced. They will be pruned by the next `git gc`.
No ref is created, so no review is recorded. The plugin treats `update-ref`
as the commit point: if it succeeds, the review exists; if any preceding
step fails, the plugin reports the error and does not attempt subsequent
steps. The system does not roll back partial object writes.

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

  "verdict": "<free-form string or null>",

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
| `id` | string | yes | Timestamp portion of the review ID (`YYYYMMDDTHHMMSS`). The full ref name appends `-<8-char-commit-sha>` (see section 3.1). |
| `created_at` | string (ISO 8601) | yes | UTC timestamp with second precision, always suffixed with `Z` (e.g., `2026-05-26T14:30:00Z`). No fractional seconds. No timezone offset other than `Z`. |
| `diff_spec.type` | enum | yes | One of `commit_range`, `branch`, `working_tree` |
| `diff_spec.base` | string or null | yes | Full 40-character SHA of the base commit, resolved at review time. See diff_spec table below. |
| `diff_spec.head` | string or null | yes | Full 40-character SHA of the head commit, resolved at review time. Null for working-tree reviews. |
| `verdict` | string or null | yes | Free-form review summary |
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
created with `verdict` null and `files` as an empty array. This signals
"reviewed, no feedback" rather than "not reviewed."

### 3.3 Reading a review

Any tool can read a review with standard git commands:

```bash
# Porcelain (human-readable, applies pager and formatting):
git show refs/reviews/20260526T143000-a1b2c3d4:review.json

# Plumbing (machine-readable, no formatting):
git cat-file blob refs/reviews/20260526T143000-a1b2c3d4:review.json
```

Agents and scripts should prefer `git cat-file blob` for programmatic access.
`git show` may apply pager settings and add headers in some configurations.

List all reviews:

```bash
git for-each-ref refs/reviews/ --format='%(refname) %(creatordate:iso)' --sort=-creatordate
```

To extract just the review ID from the ref name, use `%(refname:strip=2)`
which deterministically removes the first two path components
(`refs/reviews/`).

**Agent query pattern**: To find reviews whose parent is a specific commit:

```bash
target=abc1234
git for-each-ref refs/reviews/ --format='%(refname)' |
  while read ref; do
    parent=$(git log -1 --format='%P' "$ref")
    case "$parent" in *"$target"*) echo "$ref" ;; esac
  done
```

For repositories with many reviews, read the `diff_spec` from each
`review.json` instead, which stores the base and head revisions explicitly.

### 3.4 Ref lifecycle

Review refs accumulate over time. The plugin does not delete refs
automatically.

Delete a single review:

```bash
git update-ref -d refs/reviews/<id>
```

Delete all reviews:

```bash
git for-each-ref refs/reviews/ --format='%(refname)' |
  while read ref; do git update-ref -d "$ref"; done
```

After deleting refs, run `git gc` to reclaim storage from unreferenced
objects.

## 4. User Interface Spec

### 4.1 Screens

#### SCR-DIFF-01: Diff view

The primary screen. Delegated to diffview.nvim with custom keybindings
registered on top.

**Layout**: diffview's default file-panel + diff-panel layout. The file panel
lists changed files. The diff panel shows side-by-side or inline diff for the
selected file.

**Comment rendering**: Existing comments appear as extmarks with virtual text
below the commented line. The virtual text uses a distinct highlight group
(`CodeReviewComment`) to distinguish comments from code.

**Logical identifiers** (for spec cross-references and test hooks, not Neovim
API objects):

| Logical ID             | Neovim object              | Description                          |
|------------------------|----------------------------|--------------------------------------|
| `panel.file-list`      | diffview file-panel buffer | diffview file panel                  |
| `panel.diff`           | diffview diff-panel buffer | diffview diff panel                  |
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
`vim.keymap.set("n", key, fn, { buffer = bufnr })` on each diffview buffer.
The plugin sets these mappings in response to diffview's `view_opened` event
(or equivalent autocmd on diff buffers). Mappings are removed automatically
when the buffer is wiped.

For the file panel, mappings are set on the file-panel buffer (filetype
`DiffviewFiles`). For the diff panel, mappings are set on each diff buffer.

Default mappings (user configurable):

| Key          | Context        | Action                                  |
|--------------|----------------|-----------------------------------------|
| `<leader>cc` | diff panel    | Add line comment at cursor              |
| `<leader>cf` | file panel    | Add file-level comment for file under cursor (resolved via diffview's file-entry API or by parsing the file-panel buffer line) |
| `<leader>cv` | any           | Set/edit review verdict                 |
| `<leader>cd` | diff panel    | Delete comment at cursor                |
| `<leader>cs` | any           | Show review summary and confirm         |
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
```

The `default = true` flag allows colorschemes and user config to override
these without load-order issues.

File-level comments show as a virtual line at the top of the file's diff buffer,
using highlight group `CodeReviewFileComment`.

**Buffer lifecycle**: diffview.nvim creates and destroys diff buffers as the
user navigates files. Extmarks are buffer-local and are lost when a buffer is
wiped. The plugin shall re-apply extmarks from its in-memory comment store
whenever diffview opens a new buffer for a file that has comments. The plugin
shall listen for `BufWinEnter` or diffview's `view_opened` callback to trigger
re-application.

### 4.4 Diffview integration events

The plugin hooks into diffview's lifecycle via these mechanisms:

- `DiffviewViewOpened`: Triggered when diffview opens. The plugin uses this to
  register buffer-local keymaps on the initial buffers.
- `BufWinEnter` on `DiffviewFile*` filetypes: Triggered when the user navigates
  to a different file. The plugin re-applies extmarks from its comment store for
  the newly visible file.
- `DiffviewViewClosed`: Triggered when diffview closes (`:DiffviewClose` or
  quit). The plugin uses this to trigger the submit/cancel flow.

### 4.5 Plugin configuration

The plugin is configured via a `setup()` function following Neovim plugin
convention:

```lua
require("code-review").setup({
  keymaps = {
    add_comment = "<leader>cc",
    file_comment = "<leader>cf",
    verdict = "<leader>cv",
    delete_comment = "<leader>cd",
    summary = "<leader>cs",
    confirm_comment = "<C-s>",
  },
  highlights = {
    comment = { link = "Comment" },
    sign = { link = "DiagnosticInfo" },
    file_comment = { link = "Comment" },
  },
  sign_text = "●",
})
```

### 4.6 `:CodeReviewSubmit` command

`:CodeReviewSubmit` is a user command registered by the plugin when a review
session is active. It triggers the summary screen (SCR-SUMMARY-01). If the
user confirms, the review is saved. The command is removed when no review
session is active. It is equivalent to pressing the summary keybinding
(`<leader>cs`).

### 4.7 Quit interception

When the user executes `:q`, `:qa`, or `ZQ`, the plugin intercepts the quit
via a `QuitPre` autocmd. If there are unsaved comments, the plugin shows the
summary screen (SCR-SUMMARY-01) for confirmation. If the user cancels the
summary and quits again, no review ref is created and Neovim exits with code 2.

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
diffview. If the range does not parse as one of the four formats above, or if
the referenced revisions do not exist, the plugin exits with code 1 and a
diagnostic (see REQ-ERR-0001, REQ-ERR-0007).

### 5.2 Exit behavior

The plugin writes the ref name to a result file rather than stdout, since
Neovim uses stdout for terminal rendering.

**Result file**: The plugin writes the ref name to the path specified by the
`$NVIM_CODE_REVIEW_RESULT` environment variable. If the variable is unset,
the plugin writes to `$TMPDIR/nvim-code-review-result` (or
`/tmp/nvim-code-review-result` if `$TMPDIR` is unset). The file contains the
full ref name as a single line, with no trailing newline.

**Normal exit** (review submitted, with or without comments):

- Write the ref name to the result file
- Exit code: 0

**Empty review exit** (user submitted review without comments):

- A ref is still created (empty review, see section 3.2)
- Write the ref name to the result file
- Exit code: 0

**Cancelled exit** (user quit without submitting, e.g., `:q!`, `:qa`, `ZQ`):

- No ref is created
- Result file is not written (or is empty)
- Exit code: 2

**Error exit**:

- Print diagnostic message to stderr in the format:
  `code-review: <error-type>: <human-readable message>`
  where `<error-type>` is one of: `invalid_range`, `no_git`, `not_a_repo`,
  `no_diffview`, `version_error`, `storage_error`, `plugin_error`
- Exit code: 1
- No ref is created
- Result file is not written

An API consumer can distinguish the three outcomes:

| Exit code | Result file  | Meaning |
|-----------|--------------|---------|
| 0         | has ref      | Review submitted (may be empty; check `files` array) |
| 2         | empty/absent | User cancelled without submitting |
| 1         | empty/absent | Error occurred |

Consumers that need to distinguish error categories should parse the
`<error-type>` token. The human-readable message is not stable across
versions.

### 5.3 Agent integration example

```bash
export NVIM_CODE_REVIEW_RESULT=$(mktemp)
nvim -c 'CodeReview HEAD~3..HEAD' 2>/tmp/nvim-review-err.log
exit_code=$?
if [ $exit_code -eq 0 ]; then
  ref=$(cat "$NVIM_CODE_REVIEW_RESULT")
  review=$(git cat-file blob "$ref:review.json")
  # parse $review as JSON and act on feedback
elif [ $exit_code -eq 1 ]; then
  cat /tmp/nvim-review-err.log >&2
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

**REQ-DIF-0001** (Ubiquitous): The system shall display diffs using
diffview.nvim in the layout defined by SCR-DIFF-01.

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

**REQ-CMT-0004** (Event-driven): When the user presses the verdict keybinding,
the system shall open a comment input float (SCR-COMMENT-01) for the
review-level verdict, pre-populated with the current verdict text if one
exists.

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

**REQ-CMT-0009** (Unwanted-behavior): If the user confirms the comment input
float with an empty body (no non-whitespace characters), then the system shall
discard the comment and close the float without storing an extmark.

### 6.3 Git storage (REQ-STO)

**REQ-STO-0001** (Event-driven): When the user submits a review, the system
shall create a git blob containing the review JSON, build a tree containing that
blob as `review.json`, create a commit with a single parent, and write a ref
under `refs/reviews/<id>`.

**REQ-STO-0002** (Ubiquitous): The system shall generate review IDs with the
timestamp portion in the format `YYYYMMDDTHHMMSS` (UTC). The ref name appends
`-<8-char-commit-sha>` after the commit is created.

**REQ-STO-0003** (Ubiquitous): The review commit shall have exactly one parent:
for a single-commit review, the reviewed commit; for a range review (`A..B` or
`A...B`), the head revision B; for a working-tree review, HEAD at the time of
review. The full range is recoverable from `diff_spec`.

**REQ-STO-0004** (Ubiquitous): The `review.json` blob shall conform to the
schema defined in section 3.2.

**REQ-STO-0005** (Ubiquitous): Each `files[].lines[]` entry shall include the
full unified-diff hunk (from `@@` header through the last line of the hunk)
that contains the commented line, stored in the `diff_hunk` field. The hunk
shall be extracted from the same diff source used for display.

**REQ-STO-0006** (Event-driven): When the user submits without adding any
comments or verdict, the system shall create a review ref with an empty `files`
array and null `verdict`.

**REQ-STO-0007** (Ubiquitous): The review JSON `diff_spec` object shall record
the diff type (`commit_range`, `branch`, or `working_tree`), the base revision,
and the head revision as full 40-character SHAs resolved at review time,
conforming to the diff_spec-by-type table in section 3.2.

### 6.4 CLI / agent interface (REQ-CLI)

**REQ-CLI-0001** (Event-driven): When invoked via `nvim -c 'CodeReview
<range>'`, the system shall parse the range argument and open the corresponding
diff.

**REQ-CLI-0002** (Event-driven): When a review session ends normally, the system
shall write the full ref name as a single line to the result file (see section
5.2) and exit Neovim with exit code 0.

**REQ-CLI-0003** (Ubiquitous): The system shall use only git plumbing commands
(`hash-object`, `mktree`, `commit-tree`, `update-ref`) for ref creation, not
porcelain commands.

**REQ-CLI-0004** (Ubiquitous): The review JSON shall be self-contained: any
consumer shall be able to read the review using only `git cat-file blob
<ref>:review.json` without needing the plugin installed.

### 6.5 UI interaction (REQ-UIX)

**REQ-UIX-0001** (Event-driven): When the user presses the summary keybinding,
the system shall display a read-only summary (SCR-SUMMARY-01) listing all
comments grouped by file path, with line numbers for line-level comments, the
review verdict, and the total comment count, and wait for confirmation or
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

**REQ-UIX-0006** (Ubiquitous): The system shall render file-level comments as a
virtual line at the top of the file's diff buffer using the
`CodeReviewFileComment` highlight group.

**REQ-UIX-0007** (Event-driven): When the user quits Neovim without submitting
a review, the system shall intercept the quit via `QuitPre`, allow the quit to
proceed, create no review ref, and exit with code 2 (see section 4.7).

### 6.6 Error handling (REQ-ERR)

**REQ-ERR-0001** (Unwanted-behavior): If the specified range resolves to zero
commits and the diff type is not `working_tree`, then the system shall exit with
code 1 and print a diagnostic to stderr.

**REQ-ERR-0002** (Unwanted-behavior): If git is not available on PATH, then the
system shall exit with code 1 and print a diagnostic to stderr.

**REQ-ERR-0003** (Unwanted-behavior): If the current directory is not inside a
git repository, then the system shall exit with code 1 and print a diagnostic to
stderr.

**REQ-ERR-0004** (Unwanted-behavior): If any step in the ref creation sequence
fails (`hash-object`, `mktree`, `commit-tree`, or `update-ref`), then the
system shall stop the sequence, print the failing command and its stderr to
stderr, exit with code 1, and not write a ref name to the result file. Orphaned
objects from incomplete sequences are harmless and reclaimed by `git gc`.

**REQ-ERR-0005** (Unwanted-behavior): If diffview.nvim is not installed or
cannot be loaded, then the system shall display a diagnostic in the Neovim
message area, print a diagnostic to stderr identifying the missing dependency,
and exit with code 1.

**REQ-ERR-0006** (Unwanted-behavior): If the Neovim version is below 0.10, then
the system shall exit with code 1 and print a diagnostic to stderr identifying
the minimum required version.

**REQ-ERR-0007** (Unwanted-behavior): If the range argument contains a revision
that cannot be resolved by git, then the system shall exit with code 1 and print
a diagnostic to stderr identifying the unresolvable revision.

**REQ-ERR-0008** (Unwanted-behavior): If stdin is not a TTY, then the system
shall exit with code 1 and print a diagnostic to stderr.

## 7. Verification Matrix

| Requirement   | Test ID       | Method   | Description |
|---------------|---------------|----------|-------------|
| REQ-DIF-0001  | TST-DIF-0001  | Manual   | Open plugin, verify diffview layout matches SCR-DIFF-01 |
| REQ-DIF-0002  | TST-DIF-0002  | Auto     | Invoke with no args, verify diff command targets HEAD |
| REQ-DIF-0003  | TST-DIF-0003  | Auto     | Invoke with single rev, verify diff targets parent |
| REQ-DIF-0004  | TST-DIF-0004  | Auto     | Invoke with two-dot range, verify diff targets A..B |
| REQ-DIF-0005  | TST-DIF-0005  | Auto     | Invoke with three-dot range, verify diff targets merge-base...B |
| REQ-DIF-0006  | TST-DIF-0006  | Manual   | Modify file without staging, invoke working-tree review, verify unstaged changes visible |
| REQ-CMT-0001  | TST-CMT-0001  | Manual   | Press add-comment key on diff line, verify float opens in insert mode |
| REQ-CMT-0002  | TST-CMT-0002  | Manual   | Confirm comment, verify extmark appears below line with correct highlight |
| REQ-CMT-0003  | TST-CMT-0003  | Manual   | Press file-comment key, verify float opens for file |
| REQ-CMT-0004  | TST-CMT-0004  | Manual   | Press verdict key, verify float opens for verdict; press again, verify pre-populated |
| REQ-CMT-0005  | TST-CMT-0005  | Manual   | Delete comment, verify extmark removed |
| REQ-CMT-0006  | TST-CMT-0006  | Manual   | Enter multi-line comment, verify stored in JSON with line breaks and displayed as multi-line virtual text |
| REQ-CMT-0007  | TST-CMT-0007  | Manual   | Open comment float, press q in normal mode, verify float closes with no comment stored |
| REQ-CMT-0008  | TST-CMT-0008  | Manual   | Add comment on a line, press add-comment on same line, verify float pre-populated; confirm, verify comment replaced |
| REQ-CMT-0009  | TST-CMT-0009  | Manual   | Open comment float, confirm with empty/whitespace body, verify no comment stored |
| REQ-STO-0001  | TST-STO-0001  | Auto     | Submit review, verify ref exists and commit topology is correct |
| REQ-STO-0002  | TST-STO-0002  | Auto     | Submit review, verify ref name matches `YYYYMMDDTHHMMSS-<8-char-sha>` and JSON id matches timestamp portion |
| REQ-STO-0003  | TST-STO-0003  | Auto     | Submit review for each diff type, verify exactly one parent matching the expected commit |
| REQ-STO-0004  | TST-STO-0004  | Auto     | Submit review, validate `review.json` against JSON Schema |
| REQ-STO-0005  | TST-STO-0005  | Auto     | Submit review with line comment, verify `diff_hunk` starts with `@@` header and contains the commented line |
| REQ-STO-0006  | TST-STO-0006  | Auto     | Submit without commenting, verify ref exists with empty files and null verdict |
| REQ-STO-0007  | TST-STO-0007  | Auto     | Submit review for each diff type, verify diff_spec fields contain resolved 40-char SHAs per the diff_spec table |
| REQ-CLI-0001  | TST-CLI-0001  | Auto     | Invoke with each range format via `-c`, verify correct diff opens |
| REQ-CLI-0002  | TST-CLI-0002  | Auto     | Complete review, read result file, verify ref name written |
| REQ-CLI-0003  | TST-CLI-0003  | Auto     | Submit review, intercept `vim.system()` calls via test harness, verify all git invocations use plumbing subcommands |
| REQ-CLI-0004  | TST-CLI-0004  | Auto     | Read review with `git cat-file blob <ref>:review.json`, verify valid JSON |
| REQ-UIX-0001  | TST-UIX-0001  | Manual   | Press summary key, verify summary lists comments grouped by file with line numbers, verdict, and count |
| REQ-UIX-0002  | TST-UIX-0002  | Manual   | Confirm summary, verify review saved and Neovim exits |
| REQ-UIX-0003  | TST-UIX-0003  | Manual   | Add comment, verify virtual text rendered with `CodeReviewComment` highlight |
| REQ-UIX-0004  | TST-UIX-0004  | Manual   | Add comment, verify sign column shows `●` with `CodeReviewSign` highlight |
| REQ-UIX-0005  | TST-UIX-0005  | Manual   | Override keybinding in setup, verify new binding works |
| REQ-UIX-0006  | TST-UIX-0006  | Manual   | Add file-level comment, verify virtual line at top of file's diff buffer with `CodeReviewFileComment` highlight |
| REQ-UIX-0007  | TST-UIX-0007  | Auto     | Quit Neovim without submitting, verify no ref created and exit code is 2 |
| REQ-ERR-0001  | TST-ERR-0001  | Auto     | Invoke with empty range, verify exit code 1 and stderr message |
| REQ-ERR-0002  | TST-ERR-0002  | Auto     | Remove git from PATH, invoke, verify exit code 1 |
| REQ-ERR-0003  | TST-ERR-0003  | Auto     | Invoke outside git repo, verify exit code 1 |
| REQ-ERR-0004  | TST-ERR-0004  | Auto     | Simulate write failure at each plumbing step, verify exit code 1 and no result file written |
| REQ-ERR-0005  | TST-ERR-0005  | Auto     | Remove diffview.nvim from runtimepath, invoke, verify exit code 1 and diagnostic naming diffview |
| REQ-ERR-0006  | TST-ERR-0006  | Auto     | Mock `vim.version()` to return 0.9, verify exit code 1 and version diagnostic |
| REQ-ERR-0007  | TST-ERR-0007  | Auto     | Invoke with nonexistent branch name, verify exit code 1 and diagnostic naming the revision |
| REQ-ERR-0008  | TST-ERR-0008  | Auto     | Invoke with stdin redirected from /dev/null, verify exit code 1 |

## 8. Acceptance Criteria

The system is accepted when all of the following hold.

### 8.1 End-to-end scenarios

Each scenario must pass without modification to the test steps.

**AC-E2E-01: Agent review cycle (commit range)**

1. Create a test repo with at least 3 commits.
2. Run `NVIM_CODE_REVIEW_RESULT=$(mktemp) nvim -c 'CodeReview HEAD~2..HEAD'`.
3. In the diff view, add a line comment on a changed line and a file comment.
4. Set a verdict.
5. Submit via `:CodeReviewSubmit`.
6. Verify: exit code is 0, result file contains a ref starting with
   `refs/reviews/`, `git show <ref>:review.json` returns valid JSON with the
   comment text, correct line numbers, and a non-null verdict.

**AC-E2E-02: Agent review cycle (working tree)**

1. In a git repo, modify a tracked file without staging.
2. Run `NVIM_CODE_REVIEW_RESULT=$(mktemp) nvim -c 'CodeReview'`.
3. Add a line comment.
4. Submit.
5. Verify: exit code 0, `review.json` has `diff_spec.type` of `working_tree`,
   `diff_spec.base` contains the resolved HEAD SHA, `diff_spec.head` is null.

**AC-E2E-03: Empty review (no comments)**

1. Run `NVIM_CODE_REVIEW_RESULT=$(mktemp) nvim -c 'CodeReview HEAD~1..HEAD'`.
2. Submit without adding any comments or verdict.
3. Verify: exit code 0, result file contains a ref, `review.json` has an empty
   `files` array and null `verdict`.

**AC-E2E-04: User cancellation**

1. Run `NVIM_CODE_REVIEW_RESULT=$(mktemp) nvim -c 'CodeReview HEAD~1..HEAD'`.
2. Add a comment, then quit with `:qa!` without submitting.
3. Verify: exit code is 2, result file is empty or absent, no new ref exists
   under `refs/reviews/`.

**AC-E2E-05: Error on bad input**

1. Run `NVIM_CODE_REVIEW_RESULT=$(mktemp) nvim -c 'CodeReview nonexistent..HEAD'`.
2. Verify: exit code is 1, stderr contains a diagnostic naming the unresolvable
   revision, no ref is created.

**AC-E2E-06: Review JSON is self-contained**

1. Complete a review on a commit range.
2. Read the review using only `git cat-file blob <ref>:review.json`.
3. Without the plugin installed, parse the JSON and extract: the diff type,
   base and head SHAs, all file paths, all line numbers, all comment bodies,
   and the verdict.
4. Verify: every field required by the schema in section 3.2 is present and
   parseable. No field requires the plugin or Neovim to interpret.

### 8.2 Quality gates

All gates must pass before a version is tagged.

| Gate | Criterion |
|------|-----------|
| Unit tests | All automated tests in the verification matrix (TST-*) pass |
| Manual tests | All manual tests in the verification matrix executed and recorded as pass |
| Schema validation | `review.json` output validates against `schema/review.v1.json` for every end-to-end scenario |
| Dependency check | Plugin loads and reports a clear error when diffview.nvim is absent, Neovim < 0.10, or git is missing |
| Idempotent reads | `git cat-file blob <ref>:review.json` returns identical JSON on repeated reads |
| No data loss | Comments entered in the UI appear in the persisted JSON without truncation or encoding errors |
| Exit code contract | Exit codes match section 5.2 for all three paths (submit, cancel, error) |

### 8.3 Out-of-scope for acceptance

These are not acceptance criteria and should not block a release:

- Performance benchmarks (the tool is interactive; human review speed dominates)
- Multi-platform testing beyond the developer's primary OS
- Compatibility with Neovim nightly builds ahead of the version floor
- Review listing, search, or cleanup commands (section 3.4 documents manual cleanup)
