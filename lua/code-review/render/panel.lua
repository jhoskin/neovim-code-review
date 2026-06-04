-- render/panel.lua — the file panel for the side-by-side diff renderer.
--
-- The panel presents the changed files as a compact, indented directory tree:
-- one path segment per row, drawn with box-drawing guides. A file (leaf) row
-- shows "<status> <basename>" plus a " (<count>)" comment marker; a directory
-- row shows "<segment>/". Siblings are ordered directories-first, then
-- case-insensitive alphabetical. Names that overflow the slim panel are
-- shortened with a "~" marker — a file basename keeps its extension
-- ("stem~.ext"). Abbreviation is display-only: the per-line stash holds the
-- full path, so selection and navigation are unaffected.
--
-- The panel is decoupled from the diff/store internals: render() takes the
-- files list and a store answering count_for(path) + get_comments_for_file(path).
-- Navigation maps j/k and <CR>; <CR> on a file row invokes on_select(path), on a
-- directory row is a no-op. See render/CONTRACT.md "Panel".

local M = {}

-- Two panel namespaces. PANEL_NS carries the 📄 file-comment signs (rebuilt on
-- every render so it tracks add/delete). CURRENT_NS carries the single
-- current-file row highlight (rebuilt by set_current). They are split so a
-- file switch redrawing the current-file mark never wipes the comment signs,
-- and a re-render never wipes the current-file mark.
local PANEL_NS = "code_review_panel"
local CURRENT_NS = "code_review_panel_current"

-- Tree-guide connectors, 2 display cells each (one glyph + a space). An ancestor
-- column is GUIDE.vert when that ancestor still has siblings below it, else
-- GUIDE.blank; a node is GUIDE.tee when more siblings follow it, else GUIDE.last.
local GUIDE = {
  vert = "│ ",
  blank = "  ",
  tee = "├ ",
  last = "└ ",
}

-- Each render stashes the per-line resolution so path_at_cursor / set_current
-- resolve without parsing the rendered (possibly abbreviated) text. Keyed by
-- panel buf. paths[row] is the full path on a leaf row, false on a directory row.
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
-- {path = n} table is accepted too so tests can pass a light stub.
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

-- Does this file carry a file-level comment? The real Store answers
-- get_comments_for_file(path) -> { comment = ..., lines = ... } | nil; we guard
-- the method so a light test stub without it simply shows no sign.
local function has_file_comment(store, path)
  if not (store and type(store.get_comments_for_file) == "function") then
    return false
  end
  local file = store:get_comments_for_file(path)
  return file ~= nil and file.comment ~= nil and file.comment ~= ""
end

-- ── Trie over the file paths ───────────────────────────────────────────────
-- node = { name, children = { [seg] = node }, order = { seg, ... },
--          is_file = bool, path = full path (leaf), status = "M"|"A"|"D" }

local function new_node(name)
  return { name = name, children = {}, order = {} }
end

local function build_trie(files)
  local root = new_node("")
  for _, f in ipairs(files) do
    local path = file_path(f)
    local segs = vim.split(path, "/", { plain = true })
    local node = root
    for i, seg in ipairs(segs) do
      local child = node.children[seg]
      if not child then
        child = new_node(seg)
        node.children[seg] = child
        node.order[#node.order + 1] = seg
      end
      node = child
      if i == #segs then
        node.is_file = true
        node.path = path
        node.status = file_status(f)
      end
    end
  end
  return root
end

-- A node is a directory when it has descendants. (A path is a file or a prefix,
-- never both, so a leaf has no children.)
local function is_dir(node)
  return next(node.children) ~= nil
end

-- Sort a node's child segments in place: directories before files, then
-- case-insensitive alphabetical, exact name as a stable tiebreak.
local function sort_children(node)
  table.sort(node.order, function(a, b)
    local ca, cb = node.children[a], node.children[b]
    local da, db = is_dir(ca), is_dir(cb)
    if da ~= db then
      return da
    end
    local la, lb = a:lower(), b:lower()
    if la ~= lb then
      return la < lb
    end
    return a < b
  end)
end

-- ── Name abbreviation ──────────────────────────────────────────────────────
-- Keep the first `w` display cells of s.
local function truncate_width(s, w)
  if w <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(s) <= w then
    return s
  end
  return vim.fn.strcharpart(s, 0, w)
end

-- Shorten `name` to fit `avail` display cells with a "~" marker. A file keeps
-- its extension ("stem~.ext", floor "~.ext"); a directory segment or an
-- extensionless name end-truncates ("prefix~"). Returns the name unchanged when
-- it already fits.
local function abbreviate(name, avail, is_file_name)
  avail = math.max(avail, 1)
  if vim.fn.strdisplaywidth(name) <= avail then
    return name
  end
  if is_file_name then
    -- Extension = the last dot run, but only when the dot is not the first
    -- character (so a dotfile like ".gitignore" has no "extension").
    local dot = name:match("^.+()%.[^.]+$")
    if dot and dot > 1 then
      local ext = name:sub(dot) -- ".ext"
      if avail >= #ext + 1 then -- room for at least "~.ext"
        local budget = avail - 1 - #ext
        return truncate_width(name:sub(1, dot - 1), math.max(budget, 0)) .. "~" .. ext
      end
    end
  end
  return truncate_width(name, math.max(avail - 1, 0)) .. "~"
end

-- ── Tree walk → buffer lines + stash + leaf order ──────────────────────────
local function walk(node, prefix, inner_width, store, lines, paths, leaves)
  sort_children(node)
  local n = #node.order
  for i, seg in ipairs(node.order) do
    local child = node.children[seg]
    local guide = prefix .. (i == n and GUIDE.last or GUIDE.tee)
    local guide_w = vim.fn.strdisplaywidth(guide)
    if is_dir(child) then
      local label = abbreviate(seg, inner_width - guide_w - 1, false) -- -1 for "/"
      lines[#lines + 1] = guide .. label .. "/"
      paths[#paths + 1] = false
      local child_prefix = prefix .. (i == n and GUIDE.blank or GUIDE.vert)
      walk(child, child_prefix, inner_width, store, lines, paths, leaves)
    else
      local status = child.status or "M"
      local count = count_for(store, child.path) or 0
      local suffix = count > 0 and string.format(" (%d)", count) or ""
      -- avail for the basename = inner − guide − len("X ") − len(suffix)
      local avail = inner_width - guide_w - 2 - vim.fn.strdisplaywidth(suffix)
      local base = abbreviate(seg, avail, true)
      lines[#lines + 1] = guide .. status .. " " .. base .. suffix
      paths[#paths + 1] = child.path
      leaves[#leaves + 1] = child.path
    end
  end
end

-- The usable text width of the panel: the configured width minus a 2-column
-- reservation for the sign gutter. Constant (does not read live signcolumn
-- state), so abbreviation is deterministic and does not flicker when a comment
-- is added or removed.
local function inner_width(view)
  return math.max((view.panel_width or 30) - 2, 8)
end

-- Fill the panel buffer with the file tree. Returns the leaf paths in visual
-- (top-to-bottom) order — the order navigation steps through.
function M.render(view, files, store)
  local buf = view.panel_buf
  local root = build_trie(files)
  local lines, paths, leaves = {}, {}, {}
  walk(root, "", inner_width(view), store, lines, paths, leaves)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- File-comment indicator: a 📄 in the gutter next to each leaf whose file
  -- carries a file-level comment (REQ-UIX-0006). Rebuilt every render so it
  -- tracks add/delete. Directory rows hold `false`, so the guard skips them.
  local ns = vim.api.nvim_create_namespace(PANEL_NS)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, path in ipairs(paths) do
    if path and has_file_comment(store, path) then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        sign_text = vim.g.code_review_file_sign or "📄",
        sign_hl_group = "CodeReviewFileSign",
      })
    end
  end

  state[buf] = { paths = paths, view = view }
  return leaves
end

-- The full paths of the file leaves in visual (tree-walk) order. Pure (no view),
-- so the orchestrator can keep next/previous navigation in lockstep with the
-- tree. Uses the same build + sort as render, so the orders cannot drift.
function M.leaf_order(files)
  local root = build_trie(files)
  local leaves = {}
  local function collect(node)
    sort_children(node)
    for _, seg in ipairs(node.order) do
      local child = node.children[seg]
      if is_dir(child) then
        collect(child)
      else
        leaves[#leaves + 1] = child.path
      end
    end
  end
  collect(root)
  return leaves
end

-- Highlight the current file's row and move the panel cursor to it, so the tree
-- shows which file the diff is displaying even while focus is in a diff window,
-- and returning to the panel lands on that file (REQ-RND-0011). Clear-then-set
-- in CURRENT_NS so only one row is ever marked.
function M.set_current(view, path)
  local buf = view and view.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local ns = vim.api.nvim_create_namespace(CURRENT_NS)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local st = state[buf]
  local paths = st and st.paths
  if not paths then
    return
  end
  local row
  for i, p in ipairs(paths) do
    if p == path then -- directory rows hold `false`, never a path
      row = i
      break
    end
  end
  if not row then
    return
  end
  vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
    line_hl_group = "CodeReviewPanelCurrent",
  })
  local win = view.panel_win
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
  end
end

-- The path under the cursor, from the stash. nil on a directory row (and on any
-- miss), so <CR> on a directory is a no-op. The stash is the single source of
-- truth: the rendered text may be abbreviated and cannot be parsed back.
function M.path_at_cursor(view)
  local buf = view.panel_buf
  local win = view.panel_win
  if not (buf and win and vim.api.nvim_win_is_valid(win)) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local st = state[buf]
  return (st and st.paths[row]) or nil
end

-- Wire j/k/<CR> on the panel buffer. <CR> resolves the path under the cursor
-- and calls on_select(path); on a directory row path_at_cursor is nil, so the
-- guard makes it a no-op.
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
