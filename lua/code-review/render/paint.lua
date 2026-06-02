-- render/paint.lua — buffer fill + extmark painting for the side-by-side
-- renderer. See render/CONTRACT.md "Paint".
--
-- Two parts:
--   * filler_lines(model) — PURE. Returns the 1-based visual row indices that
--     are fillers on each side (rows where that side has a nil lineno). No
--     Neovim UI calls, so it is fully property-testable headless.
--   * apply(view, model, store) — sets each diff buffer's lines from the
--     model, starts treesitter AFTER the lines are set (the buffer must be
--     loaded or the tree is empty), then paints line backgrounds, gutter
--     signs, intra-line word highlights, and comment markers via extmarks in
--     the "code_review_render" namespace.

local M = {}

M.NS = "code_review_render"

-- Highlight groups for line backgrounds. Defined locally with default=true so
-- a user colorscheme can still override them; linked to the standard diff
-- groups. (config.lua owns the CodeReview* comment groups — we do not touch
-- it; we only reuse those names for comment markers.)
local LINE_HL = {
  add = "CodeReviewAdd",
  change = "CodeReviewChange",
  delete = "CodeReviewDelete",
}

local LINE_HL_LINK = {
  CodeReviewAdd = "DiffAdd",
  CodeReviewChange = "DiffChange",
  CodeReviewDelete = "DiffDelete",
}

-- Gutter sign text per kind.
local SIGN_TEXT = {
  add = "+",
  change = "~",
  delete = "-",
}

-- Intra-line word highlight group (links to a search-ish emphasis).
local INTRA_HL = "CodeReviewIntra"

local highlights_defined = false

local function ensure_highlights()
  if highlights_defined then
    return
  end
  for group, link in pairs(LINE_HL_LINK) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  vim.api.nvim_set_hl(0, INTRA_HL, { link = "DiffText", default = true })
  highlights_defined = true
end

-- ── PURE: filler row math ──────────────────────────────────────────────────
-- A row is a filler on the old side when old_lineno is nil, and on the new
-- side when new_lineno is nil. Visual row index is the 1-based position in the
-- model's row list (every row is exactly one visual line per side).
function M.filler_lines(model)
  local old, new = {}, {}
  for i, row in ipairs(model.rows) do
    if row.old_lineno == nil then
      old[#old + 1] = i
    end
    if row.new_lineno == nil then
      new[#new + 1] = i
    end
  end
  return { old = old, new = new }
end

-- ── Buffer line text per side ──────────────────────────────────────────────
-- Old side shows old_text or "" for a filler; new side shows new_text or "".
local function side_lines(model)
  local old, new = {}, {}
  for i, row in ipairs(model.rows) do
    old[i] = row.old_text or ""
    new[i] = row.new_text or ""
  end
  return old, new
end

-- ── Buffer resolution from the view ────────────────────────────────────────
-- The view owns the two scratch buffers per file. We accept either explicit
-- fields (view.old_buf / view.new_buf) or a method (view:buffers() ->
-- old_buf, new_buf). Tests pass a light stub.
local function view_buffers(view)
  if type(view.buffers) == "function" then
    return view:buffers()
  end
  return view.old_buf, view.new_buf
end

-- The language for treesitter on a diff buffer. The view may expose the
-- filetype/lang of the current file; default to filetype detection or nil.
local function view_lang(view)
  if type(view.lang) == "function" then
    return view:lang()
  end
  return view.lang
end

local function set_buf_lines(buf, lines)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return false
  end
  local was_modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = was_modifiable
  return true
end

-- Start treesitter on a loaded buffer. Must run AFTER lines are set.
local function start_treesitter(buf, lang)
  if not lang then
    return
  end
  -- Guard: a missing parser raises; we never want paint to fail over it.
  pcall(vim.treesitter.start, buf, lang)
end

-- Paint one side's line backgrounds + gutter signs from the model rows.
local function paint_side(buf, ns, model, side)
  for i, row in ipairs(model.rows) do
    -- NB: not `side == "old" and row.old_lineno or row.new_lineno` — that
    -- and/or idiom returns the new lineno whenever the old one is nil (a
    -- filler), which would defeat the side gate below.
    local lineno
    if side == "old" then
      lineno = row.old_lineno
    else
      lineno = row.new_lineno
    end
    local kind = row.kind
    -- Mark the line background + gutter sign only on the side that holds real
    -- content for this row. An `add` lives on the new side and a `delete` on
    -- the old side; painting a "+" on the old filler (or "-" on the new
    -- filler) would put the indicator on the wrong gutter (REQ-RND-0006).
    if kind ~= "context" and lineno ~= nil then
      local hl = LINE_HL[kind]
      if hl then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
          line_hl_group = hl,
          sign_text = SIGN_TEXT[kind],
          sign_hl_group = hl,
        })
      end
    end

    -- Intra-line word spans live on change rows; paint them on the side that
    -- has real text.
    if row.intra and lineno ~= nil then
      local spans = side == "old" and row.intra.old or row.intra.new
      local text = side == "old" and row.old_text or row.new_text
      local maxbyte = text and #text or 0
      for _, span in ipairs(spans or {}) do
        local sb = span[1] - 1 -- 1-based inclusive -> 0-based start
        local eb = span[2] -- 1-based inclusive -> 0-based exclusive end
        if sb >= 0 and eb <= maxbyte and sb < eb then
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, sb, {
            end_row = i - 1,
            end_col = eb,
            hl_group = INTRA_HL,
          })
        end
      end
    end
  end
end

-- Map a stored comment to a buffer row index (1-based) on each side. The
-- comment store keys by {side, lineno}; we invert the model to find the
-- visual row whose old/new lineno matches.
local function lineno_to_row(model)
  local old_idx, new_idx = {}, {}
  for i, row in ipairs(model.rows) do
    if row.old_lineno ~= nil then
      old_idx[row.old_lineno] = i
    end
    if row.new_lineno ~= nil then
      new_idx[row.new_lineno] = i
    end
  end
  return old_idx, new_idx
end

-- Paint comment markers (sign + virt_lines) from the store onto the diff
-- buffer for the current path. Reuses the CodeReview* groups from config.lua.
local function paint_comments(old_buf, new_buf, ns, model, store, path)
  if not (store and type(store.get_all) == "function") then
    return
  end
  local old_idx, new_idx = lineno_to_row(model)

  for _, file in ipairs(store:get_all()) do
    if file.path == path then
      -- File-level comment: virt_lines above row 1 + a sign on row 1, on the
      -- new buffer (the canonical side for a file comment).
      if file.comment and file.comment ~= "" then
        local buf = new_buf
        if buf and vim.api.nvim_buf_is_valid(buf) then
          local vlines = {}
          for _, ln in ipairs(vim.split(file.comment, "\n", { plain = true })) do
            vlines[#vlines + 1] = { { ln, "CodeReviewFileComment" } }
          end
          vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
            virt_lines = vlines,
            virt_lines_above = true,
            sign_text = vim.g.code_review_file_sign or "📄",
            sign_hl_group = "CodeReviewFileSign",
          })
        end
      end

      -- Line-level comments.
      for _, c in ipairs(file.lines or {}) do
        local side = c.side
        local buf = side == "old" and old_buf or new_buf
        local idx_map = side == "old" and old_idx or new_idx
        local lineno = side == "old" and c.old_lineno or c.new_lineno
        local row = lineno and idx_map[lineno]
        if buf and row and vim.api.nvim_buf_is_valid(buf) then
          local vlines = {}
          for _, ln in ipairs(vim.split(c.body or "", "\n", { plain = true })) do
            vlines[#vlines + 1] = { { ln, "CodeReviewComment" } }
          end
          vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
            virt_lines = vlines,
            sign_text = vim.g.code_review_sign or "●",
            sign_hl_group = "CodeReviewSign",
          })
        end
      end
    end
  end
end

-- ── API: apply ─────────────────────────────────────────────────────────────
function M.apply(view, model, store)
  ensure_highlights()
  local ns = vim.api.nvim_create_namespace(M.NS)
  local old_buf, new_buf = view_buffers(view)
  local lang = view_lang(view)
  local path = (type(view.current) == "function" and view:current() or {}).path
    or view.path

  local old_lines, new_lines = side_lines(model)
  set_buf_lines(old_buf, old_lines)
  set_buf_lines(new_buf, new_lines)

  -- Treesitter AFTER lines are set; buffer must be loaded.
  if old_buf and vim.api.nvim_buf_is_valid(old_buf) then
    start_treesitter(old_buf, lang)
  end
  if new_buf and vim.api.nvim_buf_is_valid(new_buf) then
    start_treesitter(new_buf, lang)
  end

  -- Clear prior paint, then repaint.
  if old_buf and vim.api.nvim_buf_is_valid(old_buf) then
    vim.api.nvim_buf_clear_namespace(old_buf, ns, 0, -1)
    paint_side(old_buf, ns, model, "old")
  end
  if new_buf and vim.api.nvim_buf_is_valid(new_buf) then
    vim.api.nvim_buf_clear_namespace(new_buf, ns, 0, -1)
    paint_side(new_buf, ns, model, "new")
  end

  paint_comments(old_buf, new_buf, ns, model, store, path)
end

return M
