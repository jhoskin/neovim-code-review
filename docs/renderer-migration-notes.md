# Renderer migration notes

This records the spec changes that replaced the diffview.nvim dependency with
a built-in, pure-Lua side-by-side diff renderer. Each entry is the
section/requirement touched and the one-line reason.

## User decisions

- Remove the layout-desync feature entirely. `winfixbuf` on the diff windows
  makes desync structurally impossible, so detection and recovery are moot.
- Trust `buftype=nofile` for LSP isolation on diff buffers. No active
  stop/guard is needed; `nofile` prevents LSP attach on its own.

## Auto-decisions (pre-existing conflicts resolved)

- Keymap prefix `<leader>R*` wins. The 4.2 table used `<leader>c*` while
  REQ-UIX-0008 mandated `<leader>R*`; reconciled to `<leader>R*`.
- `:quitall!` keeps the `!`. With `nofile` buffers nothing is modified, but the
  `!` stays as a defensive guard against incidental modified scratch state.

## Sections reworded

- Section 2 architecture diagram: diffview box replaced with the in-plugin
  diff renderer box. The plugin renders diffs itself now.
- Section 2.1 dependency table: diffview.nvim row deleted; Neovim and git rows
  kept; API floor stays >= 0.10. No third-party diff dependency.
- Section 2.2 data flow step 2: `:DiffviewOpen` / diffview Lua API replaced
  with `git diff` + per-file nofile buffers + the plugin's own layout and
  window/buffer registry.
- Section 1.3 Non-goals: deleted the winfixbuf/file-picker-prevention bullet;
  the desync feature it justified is gone.
- SCR-DIFF-01 (4.1): "Delegated to diffview.nvim" reworded to "Rendered by the
  plugin's built-in side-by-side diff renderer"; logical IDs now name the
  plugin's own panel and old/new diff buffers.
- Section 4.2 keybindings: maps set when the plugin creates each diff/panel
  buffer (not on diffview events); file-panel filetype is now
  `codereview-panel`; table updated to the `<leader>R*` prefix.
- Section 4.3 Buffer lifecycle paragraph: the plugin controls lifecycle and
  re-applies extmarks on (re)create, with `BufWinEnter` as a safety net.
- Section 4.5 and 4.6: setup() keymap defaults and the submit-keybinding
  reference updated to `<leader>R*` for consistency.
- Section 5.2 submit/agent-mode justification: rewritten because nofile
  buffers are never flagged modified; the `!` is now defensive only.
- Section 6.8 LSP intro: reworded to drop diffview synthetic-URI wording; diff
  buffers avoid the crash by being nofile (folds into REQ-RND-0005).
- REQ-DIF-0007: kept "non-modifiable"; dropped the diffview-staging and
  live-on-disk premise; notes the new side is a nofile copy.
- Section 8.1 AC-E2E-08: "diffview closes/reopens" reworded to "the diff view
  closes/reopens".
- Section 8.2 quality gates: dependency-check gate drops diffview; keeps
  Neovim-version and git checks.
- Verification matrix: TST-DIF-0001, TST-SES-0001, TST-SES-0004 reworded off
  diffview wording.

## Sections replaced

- Section 4.4 (Diffview integration) replaced with "4.4 Diff renderer
  internals": window registry (window→side+path), side detection via stored
  window IDs, path lookup via registry, file-panel resolution by parsing the
  plugin's own panel line. No `User Diffview*` events, no `require('diffview.lib')`.

## Sections deleted

- Section 4.10 (Diffview API dependency): no external diff API is used.
- Section 4.11 (Recovery from layout desync): desync is structurally
  impossible with winfixbuf.

## Requirements deleted

- REQ-UIX-0011..REQ-UIX-0015: layout-desync detection/recovery feature removed.
- REQ-ERR-0005 (diffview not installed): diffview is no longer a dependency.
- REQ-ERR-0009 (diffview API not available): no external diff API.
- REQ-LSP-0001 (graceful-stop + LspAttach guard on diff buffers): superseded
  by nofile-prevents-attach (REQ-RND-0005).

## Requirements kept unchanged

- REQ-DIF-0002..REQ-DIF-0006: git-level range/diff semantics stand.
- REQ-LSP-0002, REQ-LSP-0003: about the comment/summary floats, not diff
  buffers; renderer-independent.

## Requirements reworded

- REQ-DIF-0001: now "display diffs using its built-in side-by-side renderer".

## Requirements added (Section 6.9, REQ-RND)

- REQ-RND-0001: line diff via `vim.diff()` with `result_type="indices"`,
  `algorithm="histogram"`, `linematch=60`, `indent_heuristic=true`.
- REQ-RND-0002: word/character intra-line diff via a pure-Lua token diff.
- REQ-RND-0003: treesitter via `vim.treesitter.start(buf, lang)` after lines
  are set on a loaded buffer.
- REQ-RND-0004: old/new sides aligned with filler rows.
- REQ-RND-0005: diff buffers are nofile/buflisted=false/bufhidden=wipe/
  modifiable=false, windows winfixbuf=true; no LSP attaches.
- REQ-RND-0006: per-line add/change/delete gutter signs via extmarks.
- REQ-RND-0007: file panel with M/A/D markers, comment counts, j/k/<CR> nav
  that re-renders the diff buffers.
- REQ-RND-0008: scroll/cursor sync between the two diff windows.
- REQ-RND-0009: cursor row resolves to `{path, side, lineno}` via the
  renderer's row→line mapping.

## Verification matrix updates

- Added TST-RND-0001..TST-RND-0009.
- Deleted TST-UIX-0011..TST-UIX-0015, TST-ERR-0005, TST-ERR-0009.
- TST-LSP-0001 kept but remapped to REQ-RND-0005, reworded to assert no LSP
  attaches as a consequence of `buftype=nofile`.
