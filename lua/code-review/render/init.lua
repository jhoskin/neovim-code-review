-- render/init.lua — orchestration for the in-plugin side-by-side renderer.
--
-- Ties the layers together: the git read layer (diff.lua) supplies file lists
-- and per-file line arrays; the diff model (render/diff.lua) aligns them into
-- rows; the view (render/view.lua) owns the windows/buffers; the panel
-- (render/panel.lua) lists files and drives navigation; paint (render/paint.lua)
-- fills the buffers and lays the extmarks.
--
-- This module holds the only mutable session state: the diff_info, the store,
-- the changed-files list, a per-path model cache, and the live view handle. The
-- comment layer calls M.cursor_context() to anchor a comment to a file line
-- (REQ-RND-0009), replacing diffview's infer_cur_file. The view is filled in one
-- place (paint.apply); the orchestrator never round-trips lines through the
-- view's content provider. See render/CONTRACT.md "Orchestration".

local diff = require("code-review.diff")
local render_diff = require("code-review.render.diff")
local view_mod = require("code-review.render.view")
local panel = require("code-review.render.panel")
local paint = require("code-review.render.paint")
local align = require("code-review.render.align")
local config = require("code-review.config")

local M = {}

-- The single session state table. Fields are mutated in place (never the table
-- reassigned) so the content-provider closure below keeps seeing live values.
local state = {
  diff_info = nil,
  store = nil,
  files = {}, -- changed-files list (FileEntry[]) for the panel
  file_meta = {}, -- path -> old_path (for renames; nil otherwise)
  models = {}, -- path -> diff model ({ rows = ... })
  view = nil,
  current_path = nil, -- path of the file currently shown in the diff windows
}

-- Model for a path: cached, else computed from the git read layer. The cache is
-- what cursor_context maps against, so it must hold the same model paint drew.
-- file_meta[path] carries the pre-rename name so the old side reads the right
-- blob (else a rename renders as an all-additions diff).
local function model_for(path)
  local m = state.models[path]
  if m then
    return m
  end
  local old_lines, new_lines =
    diff.file_contents(state.diff_info, path, state.file_meta[path])
  m = render_diff.compute(old_lines, new_lines)
  state.models[path] = m
  return m
end

-- Treesitter language for a path, or nil when none applies. paint guards a nil
-- lang (skips treesitter) and pcalls a missing parser, so a best-effort guess
-- is safe.
local function detect_lang(path)
  local ft = vim.filetype.match({ filename = path })
  if not ft or ft == "" then
    return nil
  end
  local ok, lang = pcall(vim.treesitter.language.get_lang, ft)
  if ok and lang then
    return lang
  end
  return ft
end

-- Re-render the file panel from the current files + store. Cheap, and it is the
-- only place the per-file comment-count markers refresh, so it must run after
-- navigation and after a comment is added or deleted.
local function render_panel()
  if state.view and state.files then
    panel.render(state.view, state.files, state.store)
  end
end

-- While a diff side is zoomed the surviving buffer must read as plain syntax:
-- the add/change backgrounds drown the treesitter highlighting when the reader
-- zooms in to study a file. Strip the diff paint from the survivor; treesitter
-- and the comment markers (a separate namespace) stay. No-op unless zoomed, and
-- idempotent, so callers can fire it after any repaint or zoom-side swap
-- (REQ-RND-0018).
local function apply_zoom_paint()
  local v = state.view
  if not (v and v.zoomed_side) then
    return
  end
  paint.clear_diff(v[v.zoomed_side .. "_buf"])
end

-- Render one file into the view: compute/replay the model, point the view at the
-- path (rename buffers, reset cursor), set the language for treesitter, then
-- paint. paint.apply is the single buffer fill. Returns the model.
local function render_path(path)
  local model = model_for(path)
  state.view.lang = detect_lang(path)
  state.view:set_path(path)
  paint.apply(state.view, model, state.store)
  state.current_path = path
  -- A file switch while zoomed repaints both buffers, so re-clear the survivor.
  apply_zoom_paint()
  -- Fresh content means fresh wrap heights: re-pad and level the two windows
  -- (no-op while zoomed or in no-wrap mode; REQ-RND-0019).
  align.equalize(state.view)
  align.sync(state.view)
  return model
end

-- True when any model row carries a line number on `side` ("old"/"new"). A pure
-- addition has no old-side content; a pure deletion has no new-side content.
-- Generalizes the old has_new loop; exposed for tests (REQ-RND-0017).
local function side_has_content(model, side)
  local field = side .. "_lineno"
  for _, row in ipairs(model.rows) do
    if row[field] ~= nil then
      return true
    end
  end
  return false
end
M._side_has_content = side_has_content -- exposed for tests

-- Move focus into the diff window a line comment / edit should land in: the new
-- side by default, or the old side for a pure-deletion file (new side is all
-- filler, nothing to comment on). While zoomed the surviving side keeps focus,
-- swapping only when the newly shown file has no content there (REQ-RND-0017).
-- Cursor goes to the top (set_path already reset it).
local function focus_new_win()
  local v = state.view
  if not v then
    return
  end
  local model = state.current_path and model_for(state.current_path) or nil
  -- primary side: "new", or "old" when the file has no new-side content.
  local primary = (model and not side_has_content(model, "new")) and "old" or "new"
  local target
  if v.zoomed_side then
    -- Zoom persists across file switches on the same side; swap only when the
    -- zoomed side has no content in the newly shown file (pure add/delete).
    local side = v.zoomed_side
    if model and not side_has_content(model, side) then
      side = (side == "old") and "new" or "old"
    end
    v:set_zoom_side(side)
    target = v[side .. "_win"]
  else
    target = v[primary .. "_win"]
  end
  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
    pcall(vim.api.nvim_win_set_cursor, target, { 1, 0 })
  end
  -- A pure add/delete file may have swapped the zoomed side above; the newly
  -- zoomed buffer is a fresh survivor that must be cleared too (REQ-RND-0018).
  apply_zoom_paint()
end

-- 1-based index of `path` in the changed-files list, or nil.
local function index_of(path)
  for i, entry in ipairs(state.files) do
    if entry.path == path then
      return i
    end
  end
  return nil
end

-- Open the renderer for a resolved diff_info against a comment store. Resolves
-- changed files, builds the view + panel, wires navigation, and paints the
-- first file. Returns the view handle.
--
-- opts (optional):
--   keymaps = {
--     diff  = function(bufnr)  -- applied to each of the two diff buffers
--     panel = function(bufnr)  -- applied to the file-panel buffer
--   }
-- The renderer owns the buffers, so it owns WHEN comment-action keymaps land;
-- init.lua owns WHAT they do and passes them here (the maps call back into
-- init.lua, so the renderer must not require it). See render/CONTRACT.md.
function M.open(diff_info, store, opts)
  -- Tear down any prior session so reopening does not leak a tab.
  M.close()

  state.diff_info = diff_info
  state.store = store
  state.models = {}

  local files = diff.changed_files(diff_info)
  -- Order the file list to match the panel's tree (directories first, then
  -- case-insensitive alphabetical). next_file/prev_file iterate state.files, so
  -- ordering it once here keeps navigation in lockstep with the visible tree
  -- (REQ-RND-0011/0013).
  local rank = {}
  for i, p in ipairs(panel.leaf_order(files)) do
    rank[p] = i
  end
  table.sort(files, function(a, b)
    return (rank[a.path] or math.huge) < (rank[b.path] or math.huge)
  end)
  state.files = files
  state.file_meta = {}
  for _, entry in ipairs(files) do
    if entry.old_path then
      state.file_meta[entry.path] = entry.old_path
    end
  end
  local first = files[1] and files[1].path or nil

  -- No content provider: paint.apply fills the diff buffers (render_path). The
  -- view only lays out windows and tracks the path.
  state.view = view_mod.open(diff_info, {
    first_file = first,
    panel_width = config.values.panel_width,
    wrap = config.values.wrap,
  })
  -- Watch the diff windows for scrolls and resizes so wrapped rows stay level
  -- (REQ-RND-0019). No-op in no-wrap mode.
  align.attach(state.view)

  render_panel()
  panel.setup_keymaps(state.view, function(path)
    M.switch_file(path)
    focus_new_win()
  end)

  -- Apply the caller's comment-action keymaps to the buffers we own. The two
  -- diff buffers are stable across file switches (reused), so once is enough.
  local km = opts and opts.keymaps
  if km then
    if km.diff then
      if state.view.old_buf then
        km.diff(state.view.old_buf)
      end
      if state.view.new_buf then
        km.diff(state.view.new_buf)
      end
    end
    if km.panel and state.view.panel_buf then
      km.panel(state.view.panel_buf)
    end
  end

  if first then
    render_path(first)
    -- Mark the first file as current in the panel, then drop the cursor into
    -- its new-side diff window so the reviewer starts on the code, not the file
    -- tree (REQ-RND-0011, REQ-RND-0012). focus_new_win runs last so it wins
    -- over view.open's park-in-panel default.
    panel.set_current(state.view, first)
    focus_new_win()
  end

  return state.view
end

-- Switch the visible file: replay its model, swap buffers, repaint, and refresh
-- the panel (so its comment-count markers reflect the store).
function M.switch_file(path)
  if not (state.view and path) then
    return
  end
  render_path(path)
  render_panel()
  -- Keep the panel selection in sync with the file now on screen. After
  -- render_panel so the freshly-rendered line paths are in place (REQ-RND-0011).
  panel.set_current(state.view, path)
end

-- Switch to the next changed file (wrapping past the last back to the first) and
-- focus the new-side window. No-op when there are no files.
function M.next_file()
  if not (state.view and #state.files > 0) then
    return
  end
  local i = index_of(state.current_path) or 0
  local nxt = (i % #state.files) + 1
  M.switch_file(state.files[nxt].path)
  focus_new_win()
end

-- Switch to the previous changed file (wrapping past the first back to the last)
-- and focus the new-side window.
function M.prev_file()
  if not (state.view and #state.files > 0) then
    return
  end
  local i = index_of(state.current_path) or 1
  local prv = ((i - 2) % #state.files) + 1
  M.switch_file(state.files[prv].path)
  focus_new_win()
end

-- ── Change (hunk) navigation ───────────────────────────────────────────────
-- A hunk is a maximal run of non-context rows. hunk_starts returns the 1-based
-- model-row indices that begin a hunk (a non-context row whose predecessor is
-- context or absent). Pure — no UI — so it is unit-testable.
local function hunk_starts(model)
  local starts, prev_ctx = {}, true
  for i, row in ipairs(model.rows) do
    local is_change = row.kind ~= "context"
    if is_change and prev_ctx then
      starts[#starts + 1] = i
    end
    prev_ctx = not is_change
  end
  return starts
end
M._hunk_starts = hunk_starts -- exposed for tests

-- Step `count` hunk starts from row `cur` in `dir` ("next"/"prev"), wrapping
-- within the file (past the last back to the first, before the first to the
-- last). Returns the target row, or nil when there are no hunks.
local function step_hunk(starts, cur, dir, count)
  if #starts == 0 then
    return nil
  end
  count = math.max(count or 1, 1)
  local pos = cur
  for _ = 1, count do
    local found
    if dir == "prev" then
      for i = #starts, 1, -1 do
        if starts[i] < pos then
          found = starts[i]
          break
        end
      end
      pos = found or starts[#starts] -- wrap to the last
    else
      for _, s in ipairs(starts) do
        if s > pos then
          found = s
          break
        end
      end
      pos = found or starts[1] -- wrap to the first
    end
  end
  return pos
end

-- The diff window to navigate from: the current one if it is a diff window, else
-- the new-side window. Returns win, cursor_row (or nil, nil).
local function nav_window()
  local v = state.view
  if not v then
    return nil, nil
  end
  local cur = v:current()
  -- Fall back to whichever diff window survives: new by default, old when
  -- zoomed into the old side (new_win is nil then), so ]c/[c work from the panel.
  local win = (cur and cur.win) or v.new_win or v.old_win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return nil, nil
  end
  return win, vim.api.nvim_win_get_cursor(win)[1]
end

-- Move the cursor to the start of the next/previous changed hunk in the current
-- file, wrapping within the file and honoring a [count] (vim.v.count1 by
-- default; tests may pass an explicit count). Both diff windows move together so
-- the scrollbind/cursorbind pair stays aligned (REQ-RND-0016).
local function goto_change(dir, count)
  if not (state.view and state.current_path) then
    return
  end
  local starts = hunk_starts(model_for(state.current_path))
  if #starts == 0 then
    return
  end
  local _, row = nav_window()
  local target = step_hunk(starts, row or 0, dir, count or vim.v.count1)
  if not target then
    return
  end
  -- Build the list without a nil hole: while zoomed one side's win field is nil,
  -- and ipairs stops at the first nil, which would skip the survivor (REQ-RND-0017).
  local wins = {}
  if state.view.old_win then
    wins[#wins + 1] = state.view.old_win
  end
  if state.view.new_win then
    wins[#wins + 1] = state.view.new_win
  end
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_set_cursor, w, { target, 0 })
    end
  end
end

function M.next_change(count)
  goto_change("next", count)
end

function M.prev_change(count)
  goto_change("prev", count)
end

-- Toggle a tmux-style zoom of the current diff side: hide the other diff window
-- so the survivor spans the full width, or restore both. From the panel there is
-- no current side, so zoom the primary one (new, or old for a pure deletion).
-- Unzoom leaves focus where it is (REQ-RND-0017).
function M.toggle_zoom()
  local v = state.view
  if not v then
    return
  end
  if v.zoomed_side then
    v:unzoom()
    -- Zoom stripped the survivor's diff paint (REQ-RND-0018); restore the full
    -- diff paint on both buffers now. paint.apply refills the buffers, so save
    -- and restore the diff windows' cursors around it to leave the view put.
    if state.current_path then
      local model = model_for(state.current_path)
      local saved = {}
      for _, side in ipairs({ "old", "new" }) do
        local win = v[side .. "_win"]
        if win and vim.api.nvim_win_is_valid(win) then
          saved[win] = vim.api.nvim_win_get_cursor(win)
        end
      end
      paint.apply(v, model, state.store)
      for win, pos in pairs(saved) do
        if vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_win_set_cursor, win, pos)
        end
      end
      -- Both windows are back: re-pad for wrap and level them again.
      align.equalize(v)
      align.sync(v)
    end
    return
  end
  local cur = v:current()
  local side
  if cur then
    side = cur.side
  else
    local model = state.current_path and model_for(state.current_path) or nil
    side = (model and not side_has_content(model, "new")) and "old" or "new"
  end
  v:zoom(side)
  -- Alone on screen the survivor needs no padding; drop it so wrapped lines
  -- read without blank rows between them.
  align.clear(v)
  -- Clear the freshly zoomed survivor so treesitter reads plainly (REQ-RND-0018).
  apply_zoom_paint()
end

-- Repaint just the comment markers for the current file from the store, plus the
-- panel counts. The cheap path after a comment add/delete: no buffer refill, no
-- treesitter restart, no diff repaint (unlike switch_file).
function M.repaint_comments()
  if not (state.view and state.current_path) then
    return
  end
  local model = model_for(state.current_path)
  paint.apply_comments(state.view, model, state.store, state.current_path)
  -- Comment blocks are virtual lines on one side; mirror them so the rows
  -- below stay level (REQ-RND-0019).
  align.equalize(state.view)
  align.sync(state.view)
  render_panel()
end

-- The renderer's still-open windows (panel + both diff windows). The session
-- lifecycle uses this to tell a single-pane :q from closing the whole review.
function M.review_windows()
  if not state.view then
    return {}
  end
  -- Collect candidates without a nil hole: while zoomed one diff side's win
  -- field is nil, and ipairs over a literal stops at the first nil, which would
  -- drop later windows (returning {} zoomed on new, or losing the panel zoomed
  -- on old). Append the non-nil fields first, then validity-filter. (REQ-RND-0017)
  local candidates = {}
  if state.view.old_win then
    candidates[#candidates + 1] = state.view.old_win
  end
  if state.view.new_win then
    candidates[#candidates + 1] = state.view.new_win
  end
  if state.view.panel_win then
    candidates[#candidates + 1] = state.view.panel_win
  end
  local wins = {}
  for _, w in ipairs(candidates) do
    if vim.api.nvim_win_is_valid(w) then
      wins[#wins + 1] = w
    end
  end
  return wins
end

-- Tear down the view and clear all session state.
function M.close()
  align.detach()
  if state.view then
    pcall(function()
      state.view:close()
    end)
  end
  state.view = nil
  state.diff_info = nil
  state.store = nil
  state.files = {}
  state.file_meta = {}
  state.models = {}
  state.current_path = nil
end

-- The path of the file currently shown in the diff windows. Unlike
-- cursor_context(), this is valid even when the cursor is in the panel, so
-- file-level comments (which apply to the whole current file) can be anchored
-- from anywhere in the review UI.
function M.current_path()
  return state.current_path
end

-- Build a unified-diff-style hunk string around the commented line, derived
-- from the cached model (replaces the removed diff.get_diff_hunk git reparse).
-- `side`/`lineno` identify the commented line; `ctx` lines of surrounding
-- context are included. Returns "" if the line is not found in the model.
function M.diff_hunk(path, side, lineno, ctx)
  ctx = ctx or 3
  local model = state.models[path] or model_for(path)
  if not model then
    return ""
  end
  -- Find the row holding the commented line on the given side. Explicit branch,
  -- NOT `side == "old" and row.old_lineno or row.new_lineno`: that idiom falls
  -- through to new_lineno on any old-side filler/add row, so an add row whose
  -- new_lineno equals the target old lineno would match the wrong row.
  local target
  for i, row in ipairs(model.rows) do
    local ln
    if side == "old" then
      ln = row.old_lineno
    else
      ln = row.new_lineno
    end
    if ln == lineno then
      target = i
      break
    end
  end
  if not target then
    return ""
  end
  local first = math.max(1, target - ctx)
  local last = math.min(#model.rows, target + ctx)

  -- Hunk header: @@ -<old_start>,<old_count> +<new_start>,<new_count> @@
  local old_start, new_start, old_count, new_count
  for i = first, last do
    local row = model.rows[i]
    if row.old_lineno then
      old_start = old_start or row.old_lineno
      old_count = (old_count or 0) + 1
    end
    if row.new_lineno then
      new_start = new_start or row.new_lineno
      new_count = (new_count or 0) + 1
    end
  end
  local lines = {
    string.format(
      "@@ -%d,%d +%d,%d @@",
      old_start or 0,
      old_count or 0,
      new_start or 0,
      new_count or 0
    ),
  }
  for i = first, last do
    local row = model.rows[i]
    if row.kind == "context" then
      lines[#lines + 1] = " " .. (row.new_text or row.old_text or "")
    elseif row.kind == "delete" then
      lines[#lines + 1] = "-" .. (row.old_text or "")
    elseif row.kind == "add" then
      lines[#lines + 1] = "+" .. (row.new_text or "")
    elseif row.kind == "change" then
      lines[#lines + 1] = "-" .. (row.old_text or "")
      lines[#lines + 1] = "+" .. (row.new_text or "")
    end
  end
  return table.concat(lines, "\n")
end

-- Map the cursor to a file line for the current diff buffer (REQ-RND-0009).
-- Returns { path, side = "old"|"new", lineno } or nil. nil when the cursor is
-- in the panel (or any non-diff window), when no model is cached for the path,
-- or when the cursor sits on a filler row (no lineno on that side).
function M.cursor_context()
  if not state.view then
    return nil
  end
  local cur = state.view:current()
  if not cur then
    return nil
  end

  local model = state.models[cur.path]
  if not model then
    return nil
  end

  local row_idx = vim.api.nvim_win_get_cursor(cur.win)[1]
  local row = model.rows[row_idx]
  if not row then
    return nil
  end

  -- Explicit branch, NOT `side == "old" and old or new`: the and/or idiom would
  -- fall through to new_lineno whenever old_lineno is nil (a filler), defeating
  -- the filler check below.
  local lineno
  if cur.side == "old" then
    lineno = row.old_lineno
  else
    lineno = row.new_lineno
  end
  if lineno == nil then
    return nil
  end

  -- Carry BOTH line numbers from the model row. For a context or modified row
  -- both are set; the spec requires both populated for such comments (3.2 line
  -- number invariants). `lineno` stays the anchor-side number (the store key).
  return {
    path = cur.path,
    side = cur.side,
    lineno = lineno,
    old_lineno = row.old_lineno,
    new_lineno = row.new_lineno,
  }
end

return M
