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

-- Covers: TST-RND-0017 (tmux-style zoom of one diff side + restore).
describe("render/view zoom", function()
  it("zoom('new') hides old and reconfigures the survivor (TST-RND-0017)", function()
    local v = open_view("a.lua")
    local old_win, old_buf, pw = v.old_win, v.old_buf, v.panel_win
    ok(v:zoom("new"), "zoom returns true")
    eq(v.zoomed_side, "new")
    eq(vim.api.nvim_win_is_valid(old_win), false, "old window hidden/closed")
    H.assert.is_nil(v.old_win, "old_win field nil while zoomed")
    H.assert.is_nil(v.registry[old_win], "no registry entry for the hidden old window")
    eq(vim.wo[v.new_win].wrap, true, "survivor wraps while zoomed")
    eq(vim.wo[v.new_win].scrollbind, false, "survivor scrollbind off")
    eq(vim.wo[v.new_win].cursorbind, false, "survivor cursorbind off")
    ok(vim.api.nvim_buf_is_valid(old_buf), "old buffer survives (not wiped)")
    eq(vim.bo[old_buf].bufhidden, "hide", "hidden buffer flipped to bufhidden=hide")
    ok(vim.api.nvim_win_is_valid(pw), "panel window untouched")
    v:close()
  end)

  it("unzoom restores old|new with binds and synced cursor (TST-RND-0017)", function()
    local v = open_view("a.lua")
    vim.api.nvim_set_current_win(v.new_win)
    vim.api.nvim_win_set_cursor(v.new_win, { 2, 0 })
    v:zoom("new")
    v:unzoom()
    H.assert.is_nil(v.zoomed_side, "no longer zoomed")
    ok(vim.api.nvim_win_is_valid(v.old_win), "old window restored")
    ok(vim.api.nvim_win_is_valid(v.new_win), "new window still valid")
    ok(vim.api.nvim_win_is_valid(v.panel_win), "panel window still valid")
    -- old sits to the LEFT of new (compare start columns).
    local old_col = vim.api.nvim_win_get_position(v.old_win)[2]
    local new_col = vim.api.nvim_win_get_position(v.new_win)[2]
    ok(old_col < new_col, "old is left of new (" .. old_col .. " < " .. new_col .. ")")
    for _, win in ipairs({ v.old_win, v.new_win }) do
      eq(vim.wo[win].wrap, false, "wrap off after restore")
      eq(vim.wo[win].scrollbind, true, "scrollbind back on")
      eq(vim.wo[win].cursorbind, true, "cursorbind back on")
      eq(vim.wo[win].winfixbuf, true, "winfixbuf back on")
    end
    eq(vim.bo[v.old_buf].bufhidden, "wipe", "hidden buffer bufhidden back to wipe")
    eq(v.registry[v.old_win], { side = "old", path = v.path }, "restored registry entry")
    eq(vim.api.nvim_win_get_cursor(v.old_win)[1], 2, "restored window cursor row matches survivor")
    v:close()
  end)

  it("zoom is idempotent per side (TST-RND-0017)", function()
    local v = open_view("a.lua")
    ok(v:zoom("new"), "first zoom returns true")
    ok(v:zoom("new"), "second zoom on the same side returns true")
    eq(v.zoomed_side, "new")
    ok(vim.api.nvim_win_is_valid(v.new_win), "survivor still valid")
    v:close()
  end)

  it("zoom('old') after zoom('new') swaps sides (TST-RND-0017)", function()
    local v = open_view("a.lua")
    v:zoom("new")
    ok(v:zoom("old"), "swap zoom returns true")
    eq(v.zoomed_side, "old")
    ok(vim.api.nvim_win_is_valid(v.old_win), "old is now the survivor")
    H.assert.is_nil(v.new_win, "new is now hidden")
    ok(vim.api.nvim_buf_is_valid(v.old_buf), "old buffer valid")
    ok(vim.api.nvim_buf_is_valid(v.new_buf), "new buffer valid")
    v:close()
  end)

  it("set_zoom_side swaps only when zoomed on the other side (TST-RND-0017)", function()
    local v = open_view("a.lua")
    -- Not zoomed: no-op.
    v:set_zoom_side("old")
    H.assert.is_nil(v.zoomed_side, "set_zoom_side is a no-op when not zoomed")
    v:zoom("new")
    -- Same side: no-op.
    v:set_zoom_side("new")
    eq(v.zoomed_side, "new", "same-side set_zoom_side is a no-op")
    -- Other side: unzoom + zoom.
    v:set_zoom_side("old")
    eq(v.zoomed_side, "old", "set_zoom_side switched to old")
    H.assert.is_nil(v.new_win, "new hidden after switch")
    v:close()
  end)

  it("show_file while zoomed does not error; restored path is current (TST-RND-0017)", function()
    local v = open_view("a.lua")
    v:zoom("new")
    local okcall = pcall(function()
      v:show_file("b.lua")
    end)
    ok(okcall, "show_file while zoomed did not error")
    eq(v.registry[v.new_win].path, "b.lua", "survivor registry tracks the current file")
    v:unzoom()
    eq(v.registry[v.old_win].path, "b.lua", "restored window registry path is the current file")
    v:close()
  end)

  it("current() resolves the survivor while zoomed (TST-RND-0017)", function()
    local v = open_view("a.lua")
    v:zoom("new")
    vim.api.nvim_set_current_win(v.new_win)
    local cur = v:current()
    eq(cur.side, "new", "current side is the survivor")
    eq(cur.buf, v.new_buf, "current buf is the survivor buffer")
    v:close()
  end)

  it("close while zoomed deletes the hidden buffer too (TST-RND-0017)", function()
    local v = open_view("a.lua")
    local old_buf = v.old_buf
    v:zoom("new")
    ok(vim.api.nvim_buf_is_valid(old_buf), "hidden buffer alive while zoomed")
    v:close()
    eq(vim.api.nvim_buf_is_valid(old_buf), false, "hidden buffer deleted on close (no leak)")
  end)

  it("unzoom after the survivor is :q'd anchors on the panel (TST-RND-0017)", function()
    local v = open_view("a.lua")
    v:zoom("new")
    -- :q the survivor window out from under the view.
    vim.api.nvim_win_close(v.new_win, true)
    local okcall = pcall(function()
      v:unzoom()
    end)
    ok(okcall, "unzoom did not error after the survivor was closed")
    ok(vim.api.nvim_win_is_valid(v.old_win), "hidden side restored, anchored on the panel")
    H.assert.is_nil(v.zoomed_side, "no longer zoomed")
    v:close()
  end)

  -- Property-style invariant sweep: random zoom/unzoom/show_file ops, seeded.
  it("zoom invariants hold over 100 random ops (property, TST-RND-0017)", function()
    local v = open_view("a.lua")
    math.randomseed(42)
    local ops = {
      function()
        v:zoom("old")
      end,
      function()
        v:zoom("new")
      end,
      function()
        v:unzoom()
      end,
      function()
        v:show_file("a.lua")
      end,
      function()
        v:show_file("b.lua")
      end,
    }
    for i = 1, 100 do
      ops[math.random(#ops)]()

      -- Valid diff-window count matches the zoom state.
      local wins = {}
      if v.old_win then
        wins[v.old_win] = true
      end
      if v.new_win then
        wins[v.new_win] = true
      end
      local nwin = 0
      for win in pairs(wins) do
        ok(vim.api.nvim_win_is_valid(win), "tracked diff win valid @ op " .. i)
        nwin = nwin + 1
      end
      eq(nwin, v.zoomed_side and 1 or 2, "diff window count matches zoom state @ op " .. i)

      -- Registry keys are exactly the currently tracked diff windows.
      local nreg = 0
      for win in pairs(v.registry) do
        ok(wins[win], "registry key is a tracked diff win @ op " .. i)
        nreg = nreg + 1
      end
      eq(nreg, nwin, "registry key count matches diff window count @ op " .. i)

      -- Survivor wraps iff zoomed; both diff buffers stay valid.
      if v.zoomed_side then
        local surv = v[v.zoomed_side .. "_win"]
        eq(vim.wo[surv].wrap, true, "survivor wraps while zoomed @ op " .. i)
      else
        eq(vim.wo[v.old_win].wrap, false, "old wrap off when unzoomed @ op " .. i)
        eq(vim.wo[v.new_win].wrap, false, "new wrap off when unzoomed @ op " .. i)
      end
      ok(vim.api.nvim_buf_is_valid(v.old_buf), "old buffer valid @ op " .. i)
      ok(vim.api.nvim_buf_is_valid(v.new_buf), "new buffer valid @ op " .. i)

      -- bufhidden is "hide" exactly for the hidden side while zoomed, else "wipe".
      if v.zoomed_side then
        local hidden = v.zoomed_side == "old" and "new" or "old"
        eq(vim.bo[v[hidden .. "_buf"]].bufhidden, "hide", "hidden buf is bufhidden=hide @ op " .. i)
        eq(vim.bo[v[v.zoomed_side .. "_buf"]].bufhidden, "wipe", "survivor buf is bufhidden=wipe @ op " .. i)
      else
        eq(vim.bo[v.old_buf].bufhidden, "wipe", "old buf wipe when unzoomed @ op " .. i)
        eq(vim.bo[v.new_buf].bufhidden, "wipe", "new buf wipe when unzoomed @ op " .. i)
      end
    end
    v:close()
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
