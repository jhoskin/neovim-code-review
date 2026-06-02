-- Headless API tests for render/view.lua and render/panel.lua.
-- These exercise real Neovim windows/buffers (like the Stage A spike); they
-- do not require git, diff, or paint. Content is supplied through the view's
-- content provider so the test fully controls the line arrays.

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

  local files = {
    { path = "a.lua", status = "M" },
    { path = "src/new.lua", status = "A" },
    { path = "gone.lua", status = "D" },
  }

  it("render writes one line per file with status and count", function()
    local v = open_view()
    local store = fake_store({ ["a.lua"] = 3, ["gone.lua"] = 1 })
    local paths = panel.render(v, files, store)
    eq(paths, { "a.lua", "src/new.lua", "gone.lua" })

    local lines = vim.api.nvim_buf_get_lines(v.panel_buf, 0, -1, false)
    eq(#lines, 3, "one line per file")
    -- a.lua has 3 comments -> count marker present.
    ok(lines[1]:match("^M%s+a%.lua%s+%(3%)$") ~= nil, "a.lua line: " .. lines[1])
    -- src/new.lua added, no comments -> no count marker.
    ok(lines[2]:match("^A%s+src/new%.lua$") ~= nil, "new line: " .. lines[2])
    ok(lines[3]:match("^D%s+gone%.lua%s+%(1%)$") ~= nil, "gone line: " .. lines[3])
    v:close()
  end)

  it("render tolerates an empty file list", function()
    -- An empty review is valid (spec 3.2 "Empty review"). render must not crash
    -- and must report no paths.
    local v = open_view()
    local paths = panel.render(v, {}, fake_store({}))
    eq(paths, {}, "no paths for empty file list")
    -- path_at_cursor on the empty panel returns nil rather than erroring.
    vim.api.nvim_set_current_win(v.panel_win)
    vim.api.nvim_win_set_cursor(v.panel_win, { 1, 0 })
    H.assert.is_nil(panel.path_at_cursor(v), "no path under cursor when empty")
    v:close()
  end)

  it("path_at_cursor round-trips every file", function()
    local v = open_view()
    local store = fake_store({ ["a.lua"] = 3, ["gone.lua"] = 1 })
    local paths = panel.render(v, files, store)
    -- Move into the panel and walk each line.
    vim.api.nvim_set_current_win(v.panel_win)
    for row, expected in ipairs(paths) do
      vim.api.nvim_win_set_cursor(v.panel_win, { row, 0 })
      eq(panel.path_at_cursor(v), expected, "cursor row " .. row)
    end
    v:close()
  end)

  it("path_at_cursor falls back to parsing the rendered line when the stash misses", function()
    -- Exercise the real fallback branch in path_at_cursor (not a copy of the
    -- regex in the test): append a panel line whose row index has no stash
    -- entry, so the function must parse the rendered text. If the fallback were
    -- deleted this returns nil and the test fails.
    local v = open_view()
    panel.render(v, files, fake_store({ ["a.lua"] = 2 }))
    -- Row 4 is past the 3 stashed paths -> stash miss -> fallback parse.
    vim.bo[v.panel_buf].modifiable = true
    vim.api.nvim_buf_set_lines(v.panel_buf, -1, -1, false, { "A src/extra.lua (5)" })
    vim.bo[v.panel_buf].modifiable = false
    vim.api.nvim_set_current_win(v.panel_win)
    vim.api.nvim_win_set_cursor(v.panel_win, { 4, 0 })
    eq(panel.path_at_cursor(v), "src/extra.lua", "fallback parsed the count form")

    -- And a no-count line through the same fallback branch.
    vim.bo[v.panel_buf].modifiable = true
    vim.api.nvim_buf_set_lines(v.panel_buf, -1, -1, false, { "M plain/file.lua" })
    vim.bo[v.panel_buf].modifiable = false
    vim.api.nvim_win_set_cursor(v.panel_win, { 5, 0 })
    eq(panel.path_at_cursor(v), "plain/file.lua", "fallback parsed the no-count form")
    v:close()
  end)

  it("<CR> calls on_select with the path under the cursor", function()
    local v = open_view()
    local paths = panel.render(v, files, fake_store({}))
    local selected
    panel.setup_keymaps(v, function(p)
      selected = p
    end)
    vim.api.nvim_set_current_win(v.panel_win)
    vim.api.nvim_win_set_cursor(v.panel_win, { 2, 0 })
    -- Feed <CR> through the mapped key.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    eq(selected, paths[2], "on_select fired with row-2 path")
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
    eq(vim.api.nvim_win_get_cursor(v.panel_win)[1], 3, "j clamps at last line")
    press("k")
    eq(vim.api.nvim_win_get_cursor(v.panel_win)[1], 2, "k moved up")
    v:close()
  end)
end)
