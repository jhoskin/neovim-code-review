-- render/view.lua — layout owner for the side-by-side diff renderer.
--
-- The view builds the window layout: a file panel on the left and two diff
-- windows (old | new) side by side. It owns the two scratch diff buffers and
-- a window registry mapping each window id to { side, path }.
--
-- The view does NOT compute diffs or paint extmarks. It accepts already
-- computed line arrays through a content provider so the renderer (paint.lua)
-- and the tests can drive it without pulling in the diff/paint modules. See
-- render/CONTRACT.md "View".

local M = {}

local View = {}
View.__index = View

-- Per-file content is supplied by a provider callback set with
-- view:set_content_provider(fn). fn(path) -> old_lines, new_lines (arrays of
-- strings). Tests pass a fake; the orchestrator wires diff.file_contents +
-- diff.compute through paint. The view itself only moves lines into buffers.

local function set_buf_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  vim.bo[buf].modifiable = false
end

-- Create one scratch diff buffer per the buffer contract (REQ-RND-0005).
local function make_diff_buf(side, path)
  local buf = vim.api.nvim_create_buf(false, true) -- not listed, scratch
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  -- Name reflects side + path. nvim_buf_set_name can clash if two buffers in
  -- the tab share a name across files; we rename on every show_file.
  pcall(vim.api.nvim_buf_set_name, buf, "code-review://" .. side .. "/" .. path)
  vim.bo[buf].modifiable = false
  return buf
end

-- The opposite side. Zoom keeps one side and hides the other (REQ-RND-0017).
local function other(side)
  return side == "old" and "new" or "old"
end

local function win_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

-- Lock a diff window: pin its buffer and bind scroll/cursor to its sibling.
local function lock_diff_win(win)
  vim.wo[win].winfixbuf = true
  vim.wo[win].scrollbind = true
  vim.wo[win].cursorbind = true
  vim.wo[win].wrap = false
  -- Keep line numbers, but trim the rest of the gutter (REQ-RND-0015): absolute
  -- numbers (not LazyVim's relative), a tight number column that auto-grows, no
  -- fold column, and a sign column only when a +/~/- or comment sign is present.
  vim.wo[win].number = true
  vim.wo[win].relativenumber = false
  vim.wo[win].numberwidth = 2
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].signcolumn = "auto"
end

function View.new()
  local self = setmetatable({}, View)
  self.registry = {} -- win id -> { side, path }
  self.path = nil
  self.content_provider = nil
  self.zoomed_side = nil -- "old" | "new" | nil; the side kept full-width
  return self
end

function View:set_content_provider(fn)
  self.content_provider = fn
end

-- Build the three-window layout in the current tabpage. The first file is
-- whatever the provider is given; open does not require the diff modules, it
-- just lays out windows and fills the first file via the provider.
function M.open(diff_info, opts)
  opts = opts or {}
  local self = View.new()
  self.diff_info = diff_info
  self.content_provider = opts.content_provider

  -- Open the layout in its own tabpage so close() can tear the whole thing
  -- down without fighting Neovim's "a tab always keeps one window" rule.
  vim.cmd("tabnew")
  self.tabpage = vim.api.nvim_get_current_tabpage()

  -- Panel buffer: nofile, its own filetype so the panel module + ftplugin
  -- can attach keymaps.
  local panel_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[panel_buf].buftype = "nofile"
  vim.bo[panel_buf].buflisted = false
  vim.bo[panel_buf].bufhidden = "wipe"
  vim.bo[panel_buf].swapfile = false
  vim.bo[panel_buf].filetype = "codereview-panel"
  vim.bo[panel_buf].modifiable = false
  self.panel_buf = panel_buf

  local panel_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel_win, panel_buf)
  self.panel_win = panel_win
  -- A file tree has no use for line numbers or a fold column; disable them so
  -- inherited globals (e.g. LazyVim's number/relativenumber) don't steal columns
  -- from the tree (REQ-RND-0015). signcolumn "auto" still shows the 📄
  -- file-comment sign on demand (panel.lua, REQ-UIX-0006).
  vim.wo[panel_win].number = false
  vim.wo[panel_win].relativenumber = false
  vim.wo[panel_win].foldcolumn = "0"
  vim.wo[panel_win].signcolumn = "auto"
  -- Never wrap the tree: rows are pre-sized to the panel width, so an inherited
  -- global 'wrap' (or a narrowing from the on-demand sign gutter) would spill a
  -- row onto the next line and break the tree layout. Truncation, not wrap.
  vim.wo[panel_win].wrap = false
  -- Panel on the left, slim. Stashed so the panel can size its tree rows and
  -- abbreviate over-long names to the available width (REQ-RND-0013/0014).
  local panel_width = opts.panel_width or 30
  self.panel_width = panel_width

  -- Open the old diff window to the right of the panel.
  vim.cmd("vertical rightbelow split")
  local old_win = vim.api.nvim_get_current_win()
  -- Then the new diff window to the right of old.
  vim.cmd("vertical rightbelow split")
  local new_win = vim.api.nvim_get_current_win()

  -- Size the panel, then pin it: winfixwidth keeps the slim width when focus
  -- moves between windows (otherwise 'winwidth' bumps whichever window is
  -- current up to its minimum, and 'equalalways' re-spreads on splits).
  pcall(vim.api.nvim_win_set_width, panel_win, panel_width)
  vim.wo[panel_win].winfixwidth = true

  self.old_win = old_win
  self.new_win = new_win

  -- First file: pick from diff_info.files if present, else nil.
  local first = nil
  if opts.first_file then
    first = opts.first_file
  elseif diff_info and diff_info.files and diff_info.files[1] then
    local f = diff_info.files[1]
    first = type(f) == "table" and f.path or f
  end

  -- Create the two reusable diff buffers (named for the first file).
  self.old_buf = make_diff_buf("old", first or "")
  self.new_buf = make_diff_buf("new", first or "")

  vim.api.nvim_win_set_buf(old_win, self.old_buf)
  vim.api.nvim_win_set_buf(new_win, self.new_buf)

  -- Lock both diff windows AFTER their buffers are set (winfixbuf must be set
  -- with the intended buffer already in the window).
  lock_diff_win(old_win)
  lock_diff_win(new_win)

  -- Register windows.
  self.registry[old_win] = { side = "old", path = first }
  self.registry[new_win] = { side = "new", path = first }

  if first and self.content_provider then
    self:show_file(first)
  elseif first then
    -- No content provider: the orchestrator fills the buffers via paint.apply,
    -- so just set the buffer names / registry without an extra empty fill.
    self:set_path(first)
  end

  -- Park the cursor back in the panel by default.
  if vim.api.nvim_win_is_valid(panel_win) then
    vim.api.nvim_set_current_win(panel_win)
  end

  return self
end

-- Path bookkeeping for a file swap, WITHOUT touching buffer content: rename the
-- two reused diff buffers, repoint the registry, and reset both diff windows to
-- the top of the file. The orchestrator calls this and lets paint.apply do the
-- single buffer fill (so the buffers are not filled twice per switch).
function View:set_path(path)
  self.path = path

  -- Rename to reflect the current path (names must be unique within the tab;
  -- the pcall swallows a transient rename collision on the reused buffers).
  pcall(vim.api.nvim_buf_set_name, self.old_buf, "code-review://old/" .. path)
  pcall(vim.api.nvim_buf_set_name, self.new_buf, "code-review://new/" .. path)

  -- Refresh the registry path for both diff windows.
  if self.old_win and self.registry[self.old_win] then
    self.registry[self.old_win].path = path
  end
  if self.new_win and self.registry[self.new_win] then
    self.registry[self.new_win].path = path
  end

  -- Reset both diff windows to line 1 so a comment added right after a switch
  -- anchors to a visible row, not one clamped down from the previous file.
  for _, win in ipairs({ self.old_win, self.new_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
    end
  end
end

-- Swap the two diff buffers' content for a new file. Reuses the same buffers
-- (REQ-RND-0005 + CONTRACT: never recreate, just refill). The line arrays come
-- from the content provider; the orchestrator instead uses set_path + paint to
-- fill once. Tests drive this directly with a fake provider.
function View:show_file(path)
  self:set_path(path)

  local old_lines, new_lines = {}, {}
  if self.content_provider then
    old_lines, new_lines = self.content_provider(path)
    old_lines = old_lines or {}
    new_lines = new_lines or {}
  end

  set_buf_lines(self.old_buf, old_lines)
  set_buf_lines(self.new_buf, new_lines)
end

-- Zoom the layout to a single diff side (REQ-RND-0017): hide the OTHER side so
-- `side` takes the full diff width, tmux-style. `side` is the side to KEEP.
-- Returns true on success, false if either window is gone.
function View:zoom(side)
  if self.zoomed_side == side then
    return true
  end
  if self.zoomed_side then
    self:unzoom()
  end
  local hide_side = other(side)
  local hide_win, hide_buf = self[hide_side .. "_win"], self[hide_side .. "_buf"]
  local keep_win = self[side .. "_win"]
  if not (win_valid(hide_win) and win_valid(keep_win)) then
    return false
  end
  -- The diff buffers are bufhidden="wipe", so hiding their only window would
  -- WIPE the buffer. Flip to "hide" first; unzoom restores "wipe".
  vim.bo[hide_buf].bufhidden = "hide"
  self.registry[hide_win] = nil
  pcall(vim.api.nvim_win_hide, hide_win)
  self[hide_side .. "_win"] = nil -- invariant: the hidden side's win field is nil
  -- Alone on screen, the survivor has no sibling to bind to; let long lines
  -- wrap. Indent and mark the wrapped continuations (breakindent + showbreak)
  -- so they read as part of their diff line, not as text bleeding into the
  -- file tree beside the pane.
  vim.wo[keep_win].scrollbind = false
  vim.wo[keep_win].cursorbind = false
  vim.wo[keep_win].wrap = true
  vim.wo[keep_win].breakindent = true
  vim.wo[keep_win].showbreak = "↳ "
  self.zoomed_side = side
  return true
end

-- Restore both diff windows after a zoom. No-op if not zoomed.
function View:unzoom()
  if not self.zoomed_side then
    return
  end
  local hidden_side = other(self.zoomed_side)
  local surv_win = self[self.zoomed_side .. "_win"]
  local hid_buf = self[hidden_side .. "_buf"]
  -- The survivor may have been :q'd; fall back to anchoring on the panel.
  local anchor = win_valid(surv_win) and surv_win or self.panel_win
  local split = (anchor == surv_win) and (hidden_side == "old" and "left" or "right") or "right"
  -- Open with the buffer already in the window: winfixbuf must be set with the
  -- intended buffer present, so never split-then-set-buf.
  local win = vim.api.nvim_open_win(hid_buf, false, { win = anchor, split = split })
  vim.bo[hid_buf].bufhidden = "wipe"
  if win_valid(surv_win) then
    pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_win_get_cursor(surv_win)[1], 0 })
    lock_diff_win(surv_win) -- wrap=false, binds back on
  end
  lock_diff_win(win)
  self[hidden_side .. "_win"] = win
  self.registry[win] = { side = hidden_side, path = self.path }
  self.zoomed_side = nil
  if win_valid(surv_win) then
    vim.api.nvim_win_call(surv_win, function()
      vim.cmd("syncbind")
    end)
    -- Re-spread the diff widths; the panel keeps its slim width via winfixwidth.
    vim.api.nvim_win_call(surv_win, function()
      vim.cmd("wincmd =")
    end)
  end
end

-- Switch which side is zoomed. No-op unless zoomed on the OTHER side.
function View:set_zoom_side(side)
  if self.zoomed_side and self.zoomed_side ~= side then
    self:unzoom()
    self:zoom(side)
  end
end

-- Resolve the current cursor position to { path, side, win, buf } using the
-- window registry. Returns nil when the current window is not a diff window.
function View:current()
  local win = vim.api.nvim_get_current_win()
  local entry = self.registry[win]
  if not entry then
    return nil
  end
  local buf = win == self.old_win and self.old_buf or self.new_buf
  return { path = entry.path, side = entry.side, win = win, buf = buf }
end

-- Look up a window's side from the registry (helper for callers/tests).
function View:side_of(win)
  local entry = self.registry[win]
  return entry and entry.side or nil
end

function View:close()
  -- Closing the tabpage tears down all three windows at once, even the last
  -- one, which nvim_win_close refuses to close on its own.
  if self.tabpage and vim.api.nvim_tabpage_is_valid(self.tabpage) then
    pcall(vim.cmd, "tabclose! " .. vim.api.nvim_tabpage_get_number(self.tabpage))
  end
  -- Fall back to closing any windows still standing (e.g. tabclose refused
  -- because the layout was the only tab).
  for _, win in ipairs({ self.old_win, self.new_win, self.panel_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ self.old_buf, self.new_buf, self.panel_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  self.registry = {}
  self.tabpage = nil
  self.old_win, self.new_win, self.panel_win = nil, nil, nil
  self.old_buf, self.new_buf, self.panel_buf = nil, nil, nil
end

return M
