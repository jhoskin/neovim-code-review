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
view:zoom(side)             -- keep `side`, hide the other; true on success, false if a window is gone
view:unzoom()               -- restore both diff windows; no-op if not zoomed
view:set_zoom_side(side)    -- switch the kept side; no-op unless zoomed on the other side
view.zoomed_side            -- "old" | "new" | nil (nil when both windows show)
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

Zoom (REQ-RND-0017): `zoom(side)` hides the other diff window so `side`
takes the full diff width, tmux-style; `unzoom()` restores `old | new`.
Invariants while zoomed:

- The hidden side's `*_win` field is nil and its registry entry is removed,
  so the valid diff windows equal the registry keys at all times.
- The hidden buffer's `bufhidden` is temporarily `hide` (the diff buffers
  are `wipe`, so hiding their only window would wipe them); `unzoom`
  restores `wipe`.
- The survivor drops `scrollbind`/`cursorbind` and turns `wrap` on, since
  it has no sibling to bind to.
- `unzoom` re-applies the full `lock_diff_win` option set (`winfixbuf`,
  binds, `wrap=false`, gutter) to both windows and copies the survivor's
  cursor row into the restored window. The restored window is opened with
  its buffer already in it, so `winfixbuf` holds. If the survivor was
  closed (`:q`), the restored window anchors on the panel instead.

Plain syntax while zoomed (REQ-RND-0018): the orchestrator strips diff
paint from the survivor so treesitter shows through. `init.lua` calls
`paint.clear_diff(buf)` after zoom, after each paint while zoomed, and
after a side swap. Orchestration-level invariants:

- While zoomed the survivor buffer's diff namespace (`code_review_render`)
  holds no extmarks; the comments namespace (`code_review_comments`) is
  untouched, so comment markers stay.
- The clearing persists across file and hunk navigation while zoomed,
  including a side swap for a pure add/delete file.
- `unzoom` repaints, so full diff paint returns on both sides.

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
- `clear_diff(buf)` — clears the diff namespace (NS) on `buf`, leaving
  comment markers (NS_COMMENTS) and treesitter intact. The orchestrator
  calls it to strip diff paint from the zoomed survivor (REQ-RND-0018).
- Highlight groups reuse the existing `CodeReview*` groups in
  `config.lua`; add `CodeReviewAdd/Change/Delete` + their sign groups.

## Panel (`render/panel.lua`)

- `render(view, files, store) -> leaf_paths` — fills the file-panel
  buffer (`filetype=codereview-panel`) as an indented directory tree:
  one path segment per row drawn with box-drawing guides, directory
  rows (`<segment>/`) and file leaf rows (`<status> <basename>` + a
  `(<count>)` marker). Siblings sort directories-first then
  case-insensitive alphabetical. Over-long names are abbreviated with a
  `~` (a file keeps its extension) to `view.panel_width`. Returns the
  leaf paths in visual (top-to-bottom) order — the order navigation
  steps through.
- `leaf_order(files) -> leaf_paths` — pure; the same visual leaf order
  without a view, so the orchestrator can keep `next_file`/`prev_file`
  in lockstep with the tree.
- `set_current(view, path)` — marks the current file's leaf row
  (`CodeReviewPanelCurrent`) and moves the panel cursor there.
- Navigation: `j`/`k` move; `<CR>` on a leaf calls `on_select(path)`, on
  a directory row is a no-op.
- `path_at_cursor() -> path | nil` resolves from the per-line stash
  (full path on a leaf, nil on a directory row). The stash is the single
  source of truth — the rendered text may be abbreviated and is not
  parsed back.

## Orchestration (`render/init.lua`)

```
open(diff_info, store, opts)    -- build view, panel, paint first file
switch_file(path)               -- repaint diff + panel for a new file
next_file() / prev_file()       -- switch changed file (wraps), focus new side
next_change([count]) / prev_change([count])
  -- move cursor to the next/previous hunk start in the current file, wrapping
  -- within the file, honoring [count] (default vim.v.count1). REQ-RND-0016.
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
