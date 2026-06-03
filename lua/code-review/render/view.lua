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

-- Lock a diff window: pin its buffer and bind scroll/cursor to its sibling.
local function lock_diff_win(win)
  vim.wo[win].winfixbuf = true
  vim.wo[win].scrollbind = true
  vim.wo[win].cursorbind = true
  vim.wo[win].wrap = false
  vim.wo[win].number = true
end

function View.new()
  local self = setmetatable({}, View)
  self.registry = {} -- win id -> { side, path }
  self.path = nil
  self.content_provider = nil
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
  -- Reserve a gutter so the 📄 file-comment sign has somewhere to land
  -- (panel.lua, REQ-UIX-0006).
  vim.wo[panel_win].signcolumn = "yes"
  -- Panel on the left, narrow.
  local panel_width = opts.panel_width or 30

  -- Open the old diff window to the right of the panel.
  vim.cmd("vertical rightbelow split")
  local old_win = vim.api.nvim_get_current_win()
  -- Then the new diff window to the right of old.
  vim.cmd("vertical rightbelow split")
  local new_win = vim.api.nvim_get_current_win()

  -- Size the panel.
  pcall(vim.api.nvim_win_set_width, panel_win, panel_width)

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
