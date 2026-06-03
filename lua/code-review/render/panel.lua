-- render/panel.lua — the file panel for the side-by-side diff renderer.
--
-- The panel lists the changed files, one per line:
--   "<status> <path> <comment-count>"
-- where status is M/A/D and comment-count is the number of comments anchored
-- to that file (from a store-like object).
--
-- The panel is decoupled from the diff/store internals: render() takes the
-- files list and a store object that answers count_for(path). Navigation maps
-- j/k and <CR>; <CR> invokes a provided on_select(path) callback. See
-- render/CONTRACT.md "Panel".

local M = {}

-- We own the line format, so path_at_cursor can parse it back. A line is:
--   "M path/to/file.lua  (3)"
-- The leading char is the status; the path is everything up to the trailing
-- count marker; the count marker is "(N)" only when N > 0.
local LINE_PAT = "^(%S)%s+(.-)%s*%(%d+%)%s*$"
local LINE_PAT_NOCOUNT = "^(%S)%s+(.-)%s*$"

-- Each render stashes the parsed paths per buffer line so path_at_cursor and
-- on_select resolve without re-parsing format edge cases. Keyed by panel buf.
local state = {}

local function file_path(f)
  return type(f) == "table" and f.path or f
end

local function file_status(f)
  if type(f) == "table" and f.status then
    return f.status
  end
  return "M"
end

-- Per-file comment count. The real Store exposes count_for(path); a plain
-- {path = n} table is accepted too so tests can pass a light stub. NB: the old
-- code fell through to store.comment_count(store, path), but Store:comment_count
-- ignores its argument and returns the whole-store total, so every file showed
-- the same number.
local function count_for(store, path)
  if not store then
    return 0
  end
  if type(store.count_for) == "function" then
    return store:count_for(path) or 0
  end
  if type(store) == "table" and type(store[path]) == "number" then
    return store[path]
  end
  return 0
end

local function format_line(f, store)
  local path = file_path(f)
  local status = file_status(f)
  local n = count_for(store, path) or 0
  if n > 0 then
    return string.format("%s %s (%d)", status, path, n)
  end
  return string.format("%s %s", status, path)
end

-- Fill the panel buffer. Returns the list of paths in line order.
function M.render(view, files, store)
  local buf = view.panel_buf
  local lines = {}
  local paths = {}
  for i, f in ipairs(files) do
    lines[i] = format_line(f, store)
    paths[i] = file_path(f)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  state[buf] = { paths = paths, view = view }
  return paths
end

-- Parse the path out of the panel line under the cursor. Prefers the stashed
-- per-line path (exact), falling back to parsing the rendered text.
function M.path_at_cursor(view)
  local buf = view.panel_buf
  local win = view.panel_win
  if not (buf and win and vim.api.nvim_win_is_valid(win)) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]

  local st = state[buf]
  if st and st.paths[row] then
    return st.paths[row]
  end

  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  if not line then
    return nil
  end
  local _, path = line:match(LINE_PAT)
  if not path then
    _, path = line:match(LINE_PAT_NOCOUNT)
  end
  return path
end

-- Wire j/k/<CR> on the panel buffer. <CR> resolves the path under the cursor
-- and calls on_select(path) (the orchestrator passes a fn that calls
-- view:show_file(path)).
function M.setup_keymaps(view, on_select)
  local buf = view.panel_buf
  local opts = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "j", function()
    local win = view.panel_win
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local last = vim.api.nvim_buf_line_count(buf)
    if row < last then
      vim.api.nvim_win_set_cursor(win, { row + 1, 0 })
    end
  end, opts)

  vim.keymap.set("n", "k", function()
    local win = view.panel_win
    local row = vim.api.nvim_win_get_cursor(win)[1]
    if row > 1 then
      vim.api.nvim_win_set_cursor(win, { row - 1, 0 })
    end
  end, opts)

  vim.keymap.set("n", "<CR>", function()
    local path = M.path_at_cursor(view)
    if path and on_select then
      on_select(path)
    end
  end, opts)
end

return M
