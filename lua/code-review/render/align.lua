-- render/align.lua — keeps the two wrapped diff windows row-aligned.
--
-- With 'wrap' on, a long line takes several screen rows on one side while its
-- counterpart takes one. Neovim's own 'scrollbind' cannot compensate: it
-- steps the sibling window by buffer lines, and once a buffer carries virtual
-- lines every fill row eats one step, so the two toplines drift (native diff
-- mode documents the same limit under :h diff-mode). This module does what
-- diff mode does for its own fillers, but for wrapped rows:
--
--   * equalize(view): pads the shorter side of every row with blank virt_lines
--     so each buffer line occupies the same number of screen rows in both
--     windows. Heights come from nvim_win_text_height(), so Neovim's wrap
--     math (breakindent, showbreak, tabs, wide chars, signs) is the source of
--     truth. One-sided comment virt_lines are mirrored the same way.
--   * sync(view, src): copies (topline, topfill) from the window that scrolled
--     to its sibling. Where one side wraps and the other is padded a partial
--     fill has no counterpart, so the view snaps to the nearest line start in
--     the direction of travel. 'cursorbind' stays native.
--
-- The invariant this maintains: for every line i the cumulative screen height
-- of lines 1..i is equal on both sides, and both windows show the same
-- (topline, topfill), with topfill == 0 wherever the sides' fills differ.
-- Together those give row-for-row alignment. See render/CONTRACT.md "Align".

local M = {}

M.NS = "code_review_wrapfill"
local AUGROUP = "code_review_align"

local state = {
  view = nil,
  group = nil,
  fill = {}, -- win -> fill[i]: virtual rows above line i (after padding)
  last = {}, -- win -> { topline, topfill } as of the last sync
  pending = false, -- a resize re-equalize is scheduled
}

local function win_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

-- The two diff windows when alignment applies: wrap mode, not zoomed, both
-- windows alive. nil otherwise.
local function both_wins(view)
  if not (view and view.wrap and view.zoomed_side == nil) then
    return nil
  end
  local ow, nw = view.old_win, view.new_win
  if not (win_valid(ow) and win_valid(nw)) then
    return nil
  end
  return ow, nw
end

local function view_of(win)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview()
  end)
end

local function restview(win, v)
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview(v)
  end)
end

-- Per-line screen heights of a window's buffer: text[i] = rows the line's own
-- text takes (wrapped), fill[i] = virtual rows above line i (the previous
-- line's virt_lines below, plus virt_lines_above on i). fill[n+1] holds the
-- virtual rows below the last line. `all` from nvim_win_text_height counts the
-- fill above the line as part of it, hence the subtraction.
function M.measure(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local n = vim.api.nvim_buf_line_count(buf)
  local text, fill = {}, {}
  for i = 1, n do
    local r = vim.api.nvim_win_text_height(win, { start_row = i - 1, end_row = i - 1 })
    text[i] = r.all - r.fill
    fill[i] = r.fill
  end
  local tail = vim.api.nvim_win_text_height(win, { start_row = n - 1 })
  fill[n + 1] = tail.all - text[n] - fill[n]
  return text, fill
end

local function pad(buf, ns, row, k, above)
  local vl = {}
  for _ = 1, k do
    vl[#vl + 1] = { { "", "NonText" } }
  end
  local opts = { virt_lines = vl }
  if above then
    opts.virt_lines_above = true
  end
  vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, opts)
end

-- Pad the shorter side of every row so both windows give each buffer line the
-- same screen height. Returns true when padding was (re)computed, false when
-- alignment does not apply (no wrap, zoomed, a window gone).
function M.equalize(view)
  local ow, nw = both_wins(view)
  if not ow then
    return false
  end
  local ns = vim.api.nvim_create_namespace(M.NS)
  local ob, nb = view.old_buf, view.new_buf
  vim.api.nvim_buf_clear_namespace(ob, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(nb, ns, 0, -1)

  local to, fo = M.measure(ow)
  local tn, fn = M.measure(nw)
  local n = math.min(#to, #tn) -- the model keeps both sides equal; be safe

  -- Virtual rows above line 1 (a file-level comment) mirror with a
  -- virt_lines_above pad on the other side's first row.
  local fill_o, fill_n = { [1] = math.max(fo[1], fn[1]) }, { [1] = math.max(fo[1], fn[1]) }
  if fo[1] ~= fn[1] then
    pad(fo[1] < fn[1] and ob or nb, ns, 1, math.abs(fo[1] - fn[1]), true)
  end
  -- Row i's height is its text rows plus the virtual rows below it. Pad the
  -- shorter side below line i. After padding, the fill above line i+1 on a
  -- side is the row's equalized height minus that side's text rows.
  for i = 1, n do
    local ho = to[i] + fo[i + 1]
    local hn = tn[i] + fn[i + 1]
    local h = math.max(ho, hn)
    if ho ~= hn then
      pad(ho < hn and ob or nb, ns, i, h - math.min(ho, hn), false)
    end
    fill_o[i + 1] = h - to[i]
    fill_n[i + 1] = h - tn[i]
  end
  state.fill[ow], state.fill[nw] = fill_o, fill_n
  return true
end

-- Drop all padding (used when a side is zoomed away).
function M.clear(view)
  local ns = vim.api.nvim_create_namespace(M.NS)
  for _, buf in ipairs({ view and view.old_buf, view and view.new_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  state.fill = {}
end

-- Copy the scroll position of `src` (a diff window; defaults to the current
-- diff window, else the new side) to its sibling. Returns true when a sync
-- happened.
function M.sync(view, src)
  local ow, nw = both_wins(view)
  if not ow then
    return false
  end
  if src ~= ow and src ~= nw then
    local cur = vim.api.nvim_get_current_win()
    src = (cur == ow or cur == nw) and cur or nw
  end
  local dst = src == ow and nw or ow
  local fs, fd = state.fill[src], state.fill[dst]
  local v = view_of(src)
  local topline, topfill = v.topline, v.topfill

  -- A partial fill where the sides differ means one side is showing some of
  -- its pad rows while the other would have to show the tail of a wrapped
  -- line, which needs 'smoothscroll'. Snap to a line start instead: the line
  -- itself when scrolling down, the line above when scrolling up (the same
  -- whole-line steps Ctrl-E/Ctrl-Y take over a wrapped line).
  if topfill > 0 and fs and fd and fs[topline] ~= fd[topline] then
    local prev = state.last[src]
    local down = prev == nil
      or topline > prev.topline
      or (topline == prev.topline and topfill < prev.topfill)
    topline = down and topline or math.max(1, topline - 1)
    topfill = 0
    restview(src, { topline = topline, topfill = 0 })
    -- Snapping up reveals more rows at the top and drops some at the bottom;
    -- keep the cursor on screen the way Ctrl-Y does. cursorbind has already
    -- run for this command, so move the sibling's cursor too.
    local bot = vim.fn.line("w$", src)
    local cur = vim.api.nvim_win_get_cursor(src)
    if cur[1] > bot then
      for _, win in ipairs({ src, dst }) do
        if not pcall(vim.api.nvim_win_set_cursor, win, { bot, cur[2] }) then
          pcall(vim.api.nvim_win_set_cursor, win, { bot, 0 })
        end
      end
    end
  end

  restview(dst, { topline = topline, topfill = topfill })
  local vs, vd = view_of(src), view_of(dst)
  state.last[src] = { topline = vs.topline, topfill = vs.topfill }
  state.last[dst] = { topline = vd.topline, topfill = vd.topfill }
  return true
end

-- Which diff window scrolled per v:event (WinScrolled). Prefers the current
-- window so a sync we caused on the sibling never overrides the user's view.
local function scrolled_source(ow, nw)
  local ev = vim.v.event or {}
  local function moved(win)
    local e = ev[tostring(win)]
    return e ~= nil and ((e.topline or 0) ~= 0 or (e.topfill or 0) ~= 0)
  end
  local cur = vim.api.nvim_get_current_win()
  if (cur == ow or cur == nw) and moved(cur) then
    return cur
  end
  if moved(ow) then
    return ow
  end
  if moved(nw) then
    return nw
  end
  return nil
end

function M.on_scrolled()
  local view = state.view
  local ow, nw = both_wins(view)
  if not ow then
    return
  end
  local src = scrolled_source(ow, nw)
  if src then
    M.sync(view, src)
  end
end

-- A resize changes wrap points, so the padding must be recomputed. Coalesce
-- the burst of events a drag produces into one pass after the batch.
function M.on_resized()
  if state.pending then
    return
  end
  state.pending = true
  vim.schedule(function()
    state.pending = false
    local view = state.view
    if both_wins(view) then
      M.equalize(view)
      M.sync(view)
    end
  end)
end

-- Install the WinScrolled/WinResized watchers for a view. No-op unless the
-- view is in wrap mode.
function M.attach(view)
  M.detach()
  if not (view and view.wrap) then
    return
  end
  state.view = view
  state.group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = state.group,
    callback = function()
      M.on_scrolled()
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = state.group,
    callback = function()
      M.on_resized()
    end,
  })
end

function M.detach()
  if state.group then
    pcall(vim.api.nvim_del_augroup_by_id, state.group)
  end
  state.view = nil
  state.group = nil
  state.fill = {}
  state.last = {}
  state.pending = false
end

-- Cached fills for a window (tests).
function M._fill(win)
  return state.fill[win]
end

return M
