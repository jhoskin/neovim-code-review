-- Headless API tests for render/view.lua and render/panel.lua.
-- These exercise real Neovim windows/buffers (like the Stage A spike); they
-- do not require git, diff, or paint. Content is supplied through the view's
-- content provider so the test fully controls the line arrays.
-- Covers: TST-RND-0005 (nofile/buflisted/bufhidden/modifiable + winfixbuf
--         buffer-and-window contract).

local H = ...
local describe, it = H.describe, H.it
local eq, ok = H.assert.eq, H.assert.ok

local view = require("code-review.render.view")
local panel = require("code-review.render.panel")

-- A fake content provider: maps a path to fixed old/new line arrays. Both
-- sides have equal length (the model guarantees this; the view just trusts
-- what it is handed).
local FILES = {
  ["a.lua"] = {
    old = { "local a = 1", "return a" },
    new = { "local a = 2", "return a" },
  },
  ["b.lua"] = {
    old = { "x", "y", "z" },
    new = { "x", "Y", "z" },
  },
}

local function provider(path)
  local f = FILES[path]
  if not f then
    return {}, {}
  end
  return f.old, f.new
end

local function open_view(first)
  return view.open(
    { files = { { path = "a.lua", status = "M" }, { path = "b.lua", status = "M" } } },
    { content_provider = provider, first_file = first or "a.lua" }
  )
end

describe("render/view layout", function()
  it("open creates three windows (panel + old + new)", function()
    local v = open_view()
    ok(vim.api.nvim_win_is_valid(v.panel_win), "panel win valid")
    ok(vim.api.nvim_win_is_valid(v.old_win), "old win valid")
    ok(vim.api.nvim_win_is_valid(v.new_win), "new win valid")
    -- Three distinct windows.
    local set = {}
    set[v.panel_win] = true
    set[v.old_win] = true
    set[v.new_win] = true
    local n = 0
    for _ in pairs(set) do
      n = n + 1
    end
    eq(n, 3, "three distinct windows")
    v:close()
  end)

  it("diff buffers honor the buffer contract", function()
    local v = open_view()
    for _, buf in ipairs({ v.old_buf, v.new_buf }) do
      eq(vim.bo[buf].buftype, "nofile", "buftype nofile")
      eq(vim.bo[buf].buflisted, false, "buflisted false")
      eq(vim.bo[buf].bufhidden, "wipe", "bufhidden wipe")
      eq(vim.bo[buf].modifiable, false, "modifiable false after fill")
    end
    v:close()
  end)

  it("diff buffer names follow code-review://<side>/<path>", function()
    local v = open_view("a.lua")
    eq(vim.api.nvim_buf_get_name(v.old_buf):match("code%-review://old/a%.lua$") ~= nil, true)
    eq(vim.api.nvim_buf_get_name(v.new_buf):match("code%-review://new/a%.lua$") ~= nil, true)
    v:close()
  end)

  it("diff windows are locked: winfixbuf + scrollbind", function()
    local v = open_view()
    for _, win in ipairs({ v.old_win, v.new_win }) do
      eq(vim.wo[win].winfixbuf, true, "winfixbuf true")
      eq(vim.wo[win].scrollbind, true, "scrollbind true")
      eq(vim.wo[win].cursorbind, true, "cursorbind true")
    end
    v:close()
  end)

  -- Covers: TST-RND-0015 (trimmed window gutters across the review windows).
  it("reserves only necessary gutter columns (TST-RND-0015)", function()
    local v = open_view()
    -- File tree: no line numbers and no fold column; sign column on demand.
    eq(vim.wo[v.panel_win].number, false, "panel has no line numbers")
    eq(vim.wo[v.panel_win].relativenumber, false, "panel has no relative numbers")
    eq(vim.wo[v.panel_win].foldcolumn, "0", "panel has no fold column")
    eq(vim.wo[v.panel_win].signcolumn, "auto", "panel sign column is on demand")
    -- Diff windows: keep absolute line numbers, drop the rest of the gutter.
    for _, win in ipairs({ v.old_win, v.new_win }) do
      eq(vim.wo[win].number, true, "diff keeps line numbers")
      eq(vim.wo[win].relativenumber, false, "diff numbers are absolute")
      eq(vim.wo[win].numberwidth, 2, "diff number column is tight")
      eq(vim.wo[win].foldcolumn, "0", "diff has no fold column")
      eq(vim.wo[win].signcolumn, "auto", "diff sign column is on demand")
    end
    v:close()
  end)

  it("registry resolves win -> side correctly", function()
    local v = open_view()
    eq(v.registry[v.old_win].side, "old")
    eq(v.registry[v.new_win].side, "new")
    eq(v:side_of(v.old_win), "old")
    eq(v:side_of(v.new_win), "new")
    H.assert.is_nil(v:side_of(v.panel_win), "panel win is not a diff side")
    v:close()
  end)

  it("current() reports side/path/win/buf for the active diff window", function()
    local v = open_view("a.lua")
    vim.api.nvim_set_current_win(v.old_win)
    local cur = v:current()
    eq(cur.side, "old")
    eq(cur.path, "a.lua")
    eq(cur.win, v.old_win)
    eq(cur.buf, v.old_buf)

    vim.api.nvim_set_current_win(v.new_win)
    local cur2 = v:current()
    eq(cur2.side, "new")
    eq(cur2.buf, v.new_buf)
    v:close()
  end)

  it("current() returns nil when the cursor is in the panel", function()
    local v = open_view()
    vim.api.nvim_set_current_win(v.panel_win)
    H.assert.is_nil(v:current(), "panel is not a diff window")
    v:close()
  end)

  it("show_file swaps content and keeps line counts equal", function()
    local v = open_view("a.lua")
    eq(vim.api.nvim_buf_get_lines(v.old_buf, 0, -1, false), FILES["a.lua"].old)
    eq(vim.api.nvim_buf_get_lines(v.new_buf, 0, -1, false), FILES["a.lua"].new)

    v:show_file("b.lua")
    local o = vim.api.nvim_buf_get_lines(v.old_buf, 0, -1, false)
    local n = vim.api.nvim_buf_get_lines(v.new_buf, 0, -1, false)
    eq(o, FILES["b.lua"].old, "old buffer shows b.lua content")
    eq(n, FILES["b.lua"].new, "new buffer shows b.lua content")
    eq(#o, #n, "old and new line counts equal after swap")

    -- The path tracked on the view and in the registry updated.
    eq(v.path, "b.lua")
    eq(v.registry[v.old_win].path, "b.lua")
    eq(v.registry[v.new_win].path, "b.lua")
    -- Buffers were reused, not recreated.
    eq(v.old_buf, v.old_buf)
    v:close()
  end)

  it("current() reflects the new path after show_file swaps files", function()
    -- current() is the contract-facing accessor (CONTRACT "View"). A bug that
    -- updates the registry but leaves current() stale must be caught here, not
    -- only via the raw registry table.
    local v = open_view("a.lua")
    vim.api.nvim_set_current_win(v.old_win)
    eq(v:current().path, "a.lua")
    v:show_file("b.lua")
    eq(v:current().path, "b.lua", "current() old side tracks the swapped file")
    vim.api.nvim_set_current_win(v.new_win)
    eq(v:current().path, "b.lua", "current() new side tracks the swapped file")
    v:close()
  end)

  it("show_file resets the diff windows to the top of the new file", function()
    -- Fix #11: after a file switch the diff windows return to line 1, so a
    -- comment added right after a switch anchors to a visible row, not one
    -- clamped down from the previous (longer) file.
    local v = open_view("b.lua") -- 3 lines
    vim.api.nvim_set_current_win(v.old_win)
    vim.api.nvim_win_set_cursor(v.old_win, { 3, 0 })
    v:show_file("a.lua") -- 2 lines
    eq(vim.api.nvim_win_get_cursor(v.old_win)[1], 1, "old win reset to line 1")
    eq(vim.api.nvim_win_get_cursor(v.new_win)[1], 1, "new win reset to line 1")
    v:close()
  end)

  it("show_file reuses the same buffer ids across files", function()
    local v = open_view("a.lua")
    local ob, nb = v.old_buf, v.new_buf
    v:show_file("b.lua")
    eq(v.old_buf, ob, "old buffer id stable")
    eq(v.new_buf, nb, "new buffer id stable")
    -- And modifiable is locked back off after the swap.
    eq(vim.bo[v.old_buf].modifiable, false)
    eq(vim.bo[v.new_buf].modifiable, false)
    v:close()
  end)

  it("winfixbuf blocks a buffer swap in a diff window", function()
    local v = open_view()
    vim.api.nvim_set_current_win(v.old_win)
    -- enew tries to put a new buffer into the window; winfixbuf must reject it.
    local swapped = pcall(vim.cmd, "enew")
    eq(swapped, false, "winfixbuf blocks enew in a diff window")
    -- The diff buffer is still in the window.
    eq(vim.api.nvim_win_get_buf(v.old_win), v.old_buf)
    v:close()
  end)

  it("close tears down windows and buffers", function()
    local v = open_view()
    local pw, ow, nw = v.panel_win, v.old_win, v.new_win
    local ob, nb = v.old_buf, v.new_buf
    v:close()
    eq(vim.api.nvim_win_is_valid(pw), false)
    eq(vim.api.nvim_win_is_valid(ow), false)
    eq(vim.api.nvim_win_is_valid(nw), false)
    eq(vim.api.nvim_buf_is_valid(ob), false)
    eq(vim.api.nvim_buf_is_valid(nb), false)
  end)
end)

describe("render/panel", function()
  -- A fake store: per-path comment counts via count_for(self, path).
  local function fake_store(counts)
    return {
      count_for = function(_, path)
        return counts[path] or 0
      end,
    }
  end

  -- One subdirectory + two root files. open_view leaves panel_width at the
  -- default (30 -> inner 28), so nothing here abbreviates.
  local files = {
    { path = "a.lua", status = "M" },
    { path = "src/new.lua", status = "A" },
    { path = "gone.lua", status = "D" },
  }

  it("render writes an indented tree with status/count on leaf rows", function()
    local v = open_view()
    local store = fake_store({ ["a.lua"] = 3, ["gone.lua"] = 1 })
    -- render returns the leaf paths in visual (tree-walk) order: the src/ subtree
    -- first (directories sort before files), then the root files alphabetically.
    local leaves = panel.render(v, files, store)
    eq(leaves, { "src/new.lua", "a.lua", "gone.lua" })

    local lines = vim.api.nvim_buf_get_lines(v.panel_buf, 0, -1, false)
    eq(lines, {
      "├ src/",
      "│ └ A new.lua",
      "├ M a.lua (3)",
      "└ D gone.lua (1)",
    })
    v:close()
  end)

  it("render tolerates an empty file list", function()
    -- An empty review is valid (spec 3.2 "Empty review"). render must not crash
    -- and must report no leaves.
    local v = open_view()
    local leaves = panel.render(v, {}, fake_store({}))
    eq(leaves, {}, "no leaves for empty file list")
    vim.api.nvim_set_current_win(v.panel_win)
    vim.api.nvim_win_set_cursor(v.panel_win, { 1, 0 })
    H.assert.is_nil(panel.path_at_cursor(v), "no path under cursor when empty")
    v:close()
  end)

  it("path_at_cursor returns the full path on a leaf and nil on a directory row", function()
    local v = open_view()
    panel.render(v, files, fake_store({ ["a.lua"] = 3, ["gone.lua"] = 1 }))
    vim.api.nvim_set_current_win(v.panel_win)
    -- Row 1 is the "src/" directory row -> no path.
    vim.api.nvim_win_set_cursor(v.panel_win, { 1, 0 })
    H.assert.is_nil(panel.path_at_cursor(v), "directory row has no path")
    -- Rows 2..4 are leaves carrying their full path.
    local leaf_at = { [2] = "src/new.lua", [3] = "a.lua", [4] = "gone.lua" }
    for row, expected in pairs(leaf_at) do
      vim.api.nvim_win_set_cursor(v.panel_win, { row, 0 })
      eq(panel.path_at_cursor(v), expected, "leaf row " .. row)
    end
    -- A row past the stash is a miss -> nil. The text-parse fallback is gone:
    -- abbreviated tree text cannot reconstruct a full path, so the stash is the
    -- single source of truth.
    vim.bo[v.panel_buf].modifiable = true
    vim.api.nvim_buf_set_lines(v.panel_buf, -1, -1, false, { "M plain/file.lua" })
    vim.bo[v.panel_buf].modifiable = false
    vim.api.nvim_win_set_cursor(v.panel_win, { 5, 0 })
    H.assert.is_nil(panel.path_at_cursor(v), "stash miss returns nil, not a parsed path")
    v:close()
  end)

  it("<CR> selects the leaf under the cursor; a directory row is a no-op", function()
    local v = open_view()
    panel.render(v, files, fake_store({}))
    local selected
    panel.setup_keymaps(v, function(p)
      selected = p
    end)
    vim.api.nvim_set_current_win(v.panel_win)
    local function press_cr()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    end
    -- Row 2 is the "src/new.lua" leaf.
    vim.api.nvim_win_set_cursor(v.panel_win, { 2, 0 })
    press_cr()
    eq(selected, "src/new.lua", "on_select fired with the leaf path")
    -- Row 1 is the "src/" directory row -> nothing happens.
    selected = nil
    vim.api.nvim_win_set_cursor(v.panel_win, { 1, 0 })
    press_cr()
    H.assert.is_nil(selected, "<CR> on a directory row does nothing")
    v:close()
  end)

  it("j/k navigation moves the cursor within bounds", function()
    local v = open_view()
    panel.render(v, files, fake_store({}))
    panel.setup_keymaps(v, function() end)
    vim.api.nvim_set_current_win(v.panel_win)
    vim.api.nvim_win_set_cursor(v.panel_win, { 1, 0 })
    local function press(key)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
    end
    press("j")
    eq(vim.api.nvim_win_get_cursor(v.panel_win)[1], 2, "j moved down")
    press("j")
    press("j")
    press("j")
    eq(vim.api.nvim_win_get_cursor(v.panel_win)[1], 4, "j clamps at last line")
    press("k")
    eq(vim.api.nvim_win_get_cursor(v.panel_win)[1], 3, "k moved up")
    v:close()
  end)

  -- Covers: TST-RND-0013 (tree guides + full per-level nesting + ordering).
  it("nests one segment per level with guides, directories first (TST-RND-0013)", function()
    local v = open_view()
    local nested = {
      { path = "lua/code-review/render/panel.lua", status = "M" },
      { path = "lua/code-review/render/view.lua", status = "M" },
      { path = "lua/code-review/init.lua", status = "M" },
      { path = "zebra.txt", status = "A" },
    }
    panel.render(v, nested, fake_store({}))
    local lines = vim.api.nvim_buf_get_lines(v.panel_buf, 0, -1, false)
    -- Each directory segment is its own indented row (no chain collapsing); the
    -- render/ subdirectory sorts before the init.lua file inside code-review/;
    -- the root file zebra.txt comes after the whole lua/ subtree.
    eq(lines, {
      "├ lua/",
      "│ └ code-review/",
      "│   ├ render/",
      "│   │ ├ M panel.lua",
      "│   │ └ M view.lua",
      "│   └ M init.lua",
      "└ A zebra.txt",
    })
    v:close()
  end)

  -- Covers: TST-RND-0013 (~ abbreviation keeping a file's extension).
  it("abbreviates an over-long basename keeping its extension (TST-RND-0013)", function()
    local v = view.open(
      { files = { { path = "x", status = "M" } } },
      { content_provider = provider, first_file = "x", panel_width = 16 }
    )
    panel.render(v, { { path = "a_very_long_filename.lua", status = "M" } }, fake_store({}))
    local line = vim.api.nvim_buf_get_lines(v.panel_buf, 0, -1, false)[1]
    -- panel_width 16 -> inner 14. The name is shortened with a "~" but keeps the
    -- ".lua" extension, and the row fits the inner width.
    ok(line:match("~%.lua$") ~= nil, "abbreviated, extension kept: " .. line)
    ok(vim.fn.strdisplaywidth(line) <= 14, "fits inner width: " .. line)
    -- The stash still resolves the full path (abbreviation is display-only).
    vim.api.nvim_set_current_win(v.panel_win)
    vim.api.nvim_win_set_cursor(v.panel_win, { 1, 0 })
    eq(panel.path_at_cursor(v), "a_very_long_filename.lua", "full path preserved")
    v:close()
  end)
end)
