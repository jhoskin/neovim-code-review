# Renderer module contract

This is the locked interface boundary for the in-plugin diff renderer
(REQ-RND-*). Parallel work builds against these shapes; do not change a
shape without updating this file and the dependents in the same change.

The diff model and word-diff shapes below are not aspirational — they
are implemented and property-tested in `render/diff.lua` +
`tests/unit/render_diff_spec.lua`, and the buffer/window mechanics are
validated by the Stage A spike (treesitter-on-scratch, nofile,
winfixbuf-blocks-swap, real-filler alignment all confirmed on Neovim
0.12).

## The diff model (`render/diff.lua`)

`compute(old_lines, new_lines) -> { rows = Row[] }`

`old_lines` / `new_lines` are arrays of strings (no trailing newline on
each element). A row maps to exactly one visual line on EACH side
(real text or filler), which is what makes side-by-side alignment and
`scrollbind` trivial.

```
Row = {
  kind       = "context" | "add" | "delete" | "change",
  old_lineno = integer | nil,   -- 1-based index into old_lines; nil = filler on old side
  new_lineno = integer | nil,   -- 1-based index into new_lines; nil = filler on new side
  old_text   = string | nil,    -- nil iff old_lineno == nil
  new_text   = string | nil,    -- nil iff new_lineno == nil
  intra      = nil | { old = Span[], new = Span[] },  -- present only on kind == "change"
}
Span = { first_byte, last_byte }  -- 1-based, inclusive, into the row's text on that side
```

Invariants (property-tested):
- Reconstruction: collecting `old_text` over rows with non-nil
  `old_lineno`, in order, equals `old_lines`; same for new.
- Alignment equality: every row is one visual line per side, so the
  old and new visual-row counts are equal.
- `change` rows are 1:1 (one old line paired with one new line);
  surplus lines in an unbalanced hunk become `add`/`delete` rows.

`word_diff(old_text, new_text) -> { old = Span[], new = Span[] }`
- Byte ranges that differ between the two strings (LCS over word tokens).
- Spans are in-bounds, strictly ordered, non-overlapping.

## Git read layer (`diff.lua`, retained from the diffview era)

Keep: `parse_range`, `resolve_shas`, `_git`, `git_root`,
`is_inside_work_tree`. Add (Stage B):
- `changed_files(diff_info) -> FileEntry[]`
  `FileEntry = { path, status = "M"|"A"|"D", old_path? }`
  (`old_path` is the pre-rename name on a rename/copy, else nil).
- `file_contents(diff_info, path[, old_path]) -> old_lines, new_lines`
  (old via `git show <base_sha>:<old_path or path>` or {} for added;
  new via `git show <head_sha>:<path>` or working-tree read for
  working_tree reviews; {} for deleted). All git calls run with
  `-c core.quotePath=false` so non-ASCII paths stay literal.
Remove: `open` (DiffviewOpen), `get_diff_hunk` (replaced by the model;
`diff_hunk` for review JSON is derived from the model — see below).

## View (`render/view.lua`)

Owns the layout and the two scratch buffers per file.

```
open(diff_info) -> view
  -- builds file panel + old/new windows; renders the first file
view:set_path(path)         -- rename buffers + registry + reset cursor (no fill)
view:show_file(path)        -- set_path + fill from the content provider
view:close()
view:current() -> { path, side = "old"|"new", win, buf }
```

The orchestrator fills the diff buffers exactly once, via `paint.apply`,
so it calls `set_path` (bookkeeping only). `show_file` layers the
content-provider fill on top and is what tests and standalone callers
use. `set_path` resets both diff windows to line 1 so a comment added
right after a file switch anchors to a visible row.

Buffer contract (REQ-RND-0005, spike-verified):
- `nvim_create_buf(false, true)`, names `code-review://old/<path>` and
  `code-review://new/<path>`, `buftype=nofile`, `buflisted=false`,
  `bufhidden=wipe`, `modifiable=false` after fill.
- Both diff windows: `winfixbuf=true` (blocks picker swaps — verified),
  `scrollbind=true` + `cursorbind=true` (line counts equal, so sync is
  automatic).

Window registry: view maps each window id -> { side, path } so side
detection is "current win vs registry" (no diffview API).

## Paint (`render/paint.lua`)

Pure helpers + extmark application in two namespaces: diff paint in
`code_review_render` (NS), comment markers in `code_review_comments`
(NS_COMMENTS). The split lets a comment edit repaint only the markers.
- `filler_lines(model) -> { old = int[], new = int[] }` — which buffer
  rows are fillers per side (pure; testable).
- `apply(view, model, store)` — sets buffer lines from the model, starts
  treesitter (`vim.treesitter.start(buf, lang)` AFTER lines are set —
  the buffer must be loaded or the tree is empty; stops any prior
  highlighter first, since buffers are reused), paints add/change/del
  line backgrounds + gutter signs and intra-line word highlights (NS),
  then comment markers (NS_COMMENTS).
- `apply_comments(view, model, store[, path])` — clears and repaints
  only the comment markers (NS_COMMENTS); no buffer fill, no treesitter
  restart, no diff repaint. The cheap path for a comment add/delete.
- Highlight groups reuse the existing `CodeReview*` groups in
  `config.lua`; add `CodeReviewAdd/Change/Delete` + their sign groups.

## Panel (`render/panel.lua`)

- `render(view, files, store)` — fills the file-panel buffer
  (`filetype=codereview-panel`): one line per file with `M/A/D` status
  and a comment-count marker.
- Navigation: `j`/`k` move; `<CR>` calls `view:show_file(path)`.
- `path_at_cursor() -> path` by parsing the panel line (we own the
  format).

## Orchestration (`render/init.lua`)

```
open(diff_info, store, opts)    -- build view, panel, paint first file
switch_file(path)               -- repaint diff + panel for a new file
repaint_comments()              -- comment-only repaint after add/delete
close()
current_path() -> path | nil    -- file shown in the diff windows (panel-safe)
review_windows() -> win[]        -- still-open renderer windows (lifecycle)
diff_hunk(path, side, lineno, ctx?) -> string  -- unified hunk from the model
cursor_context() -> { path, side = "old"|"new", lineno } | nil
  -- maps the current cursor row in a diff buffer back to a file line via
  -- the model's row table for the current file. REQ-RND-0009. This is
  -- what the comment layer calls instead of diffview's infer_cur_file.
```

`switch_file` re-renders the panel so the per-file comment-count markers
(`store:count_for(path)`) stay current; `repaint_comments` is the cheap
path the comment layer calls after an add/delete (markers + panel only).

`cursor_context` returns nil when the cursor is on a filler row or in
the panel. `lineno` is the `old_lineno` or `new_lineno` of the row at
the cursor, picked by which side's window is current.

## Comment-layer integration (existing modules)

- `store.lua` keys comments by `{path, side, lineno}` — unchanged.
- `init.lua` calls `render.cursor_context()` to anchor a new comment.
- `review.lua` `diff_hunk`: derive from the model — for a commented
  row, emit a unified-diff-style hunk window around it built from the
  surrounding model rows (replaces the old `git diff` reparse).

## Test layout

- `tests/unit/<module>_spec.lua` — unit + property tests, run via
  `make unit` (`nvim --headless -l tests/unit/run.lua`).
- Pure modules (diff model, word diff, paint filler math, store) MUST
  have property tests for their invariants.
- `tests/e2e/*` — tmux behavior tests (Stage D rewrite probes the
  renderer buffers, not diffview).
