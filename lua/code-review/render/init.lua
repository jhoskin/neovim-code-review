-- render/init.lua — orchestration for the in-plugin side-by-side renderer.
--
-- Ties the layers together: the git read layer (diff.lua) supplies file lists
-- and per-file line arrays; the diff model (render/diff.lua) aligns them into
-- rows; the view (render/view.lua) owns the windows/buffers; the panel
-- (render/panel.lua) lists files and drives navigation; paint (render/paint.lua)
-- fills the buffers and lays the extmarks.
--
-- This module holds the only mutable session state: the diff_info, the store,
-- a per-path model cache, and the live view handle. The comment layer calls
-- M.cursor_context() to anchor a comment to a file line (REQ-RND-0009),
-- replacing diffview's infer_cur_file. See render/CONTRACT.md "Orchestration".

local diff = require("code-review.diff")
local render_diff = require("code-review.render.diff")
local view_mod = require("code-review.render.view")
local panel = require("code-review.render.panel")
local paint = require("code-review.render.paint")

local M = {}

-- The single session state table. Fields are mutated in place (never the table
-- reassigned) so the content-provider closure below keeps seeing live values.
local state = {
  diff_info = nil,
  store = nil,
  models = {}, -- path -> diff model ({ rows = ... })
  view = nil,
  current_path = nil, -- path of the file currently shown in the diff windows
}

-- Aligned per-side buffer lines from a model: one visual line per row, "" for a
-- filler. Mirrors paint.side_lines so the view shows aligned content the instant
-- show_file runs (paint.apply re-sets the same lines a moment later).
local function aligned_lines(model)
  local old, new = {}, {}
  for i, row in ipairs(model.rows) do
    old[i] = row.old_text or ""
    new[i] = row.new_text or ""
  end
  return old, new
end

-- Model for a path: cached, else computed from the git read layer. The cache is
-- what cursor_context maps against, so it must hold the same model paint drew.
local function model_for(path)
  local m = state.models[path]
  if m then
    return m
  end
  local old_lines, new_lines = diff.file_contents(state.diff_info, path)
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

-- The view's content provider: hand it a path, get aligned old/new line arrays.
-- A stable function reference (it reads `state`), so it survives a reset.
local function content_provider(path)
  return aligned_lines(model_for(path))
end

-- Render one file into the view: compute/replay the model, swap the buffers to
-- it, set the language for treesitter, then paint. Returns the model.
local function render_path(path)
  local model = model_for(path)
  state.view.lang = detect_lang(path)
  state.view:show_file(path)
  paint.apply(state.view, model, state.store)
  state.current_path = path
  return model
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
  local first = files[1] and files[1].path or nil

  state.view = view_mod.open(diff_info, {
    content_provider = content_provider,
    first_file = first,
  })

  panel.render(state.view, files, store)
  panel.setup_keymaps(state.view, function(path)
    M.switch_file(path)
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
  end

  return state.view
end

-- Switch the visible file: replay its model, swap buffers, repaint.
function M.switch_file(path)
  if not (state.view and path) then
    return
  end
  render_path(path)
end

-- Tear down the view and clear all session state.
function M.close()
  if state.view then
    pcall(function()
      state.view:close()
    end)
  end
  state.view = nil
  state.diff_info = nil
  state.store = nil
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
  -- Find the row holding the commented line on the given side.
  local target
  for i, row in ipairs(model.rows) do
    local ln = side == "old" and row.old_lineno or row.new_lineno
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

  return { path = cur.path, side = cur.side, lineno = lineno }
end

return M
