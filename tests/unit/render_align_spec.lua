-- Headless tests for render/align.lua: wrapped side-by-side rows stay level.
-- Covers: TST-RND-0019 (wrap + padding + plugin-owned scroll sync).
--
-- Alignment is asserted through Neovim's own height accounting rather than
-- the screen grid: for every line the cumulative screen height of lines 1..i
-- must be equal on both sides, and after a sync both windows must show the
-- same (topline, topfill), with topfill == 0 wherever the sides' fills differ.
-- Those two facts imply row-for-row alignment.
--
-- WinScrolled/WinResized do not fire under `nvim -l` (no main loop), so the
-- autocmd path is exercised by tests/e2e/test_44_wrap_align.sh. Here the main
-- loop is emulated around each scroll command: cursorbind copies the cursor to
-- the sibling before the sync, and the source window re-validates its cursor
-- (update_topline) after it.

local H = ...
local describe, it = H.describe, H.it
local eq, ok = H.assert.eq, H.assert.ok

local view = require("code-review.render.view")
local align = require("code-review.render.align")
local paint = require("code-review.render.paint")

local NS = vim.api.nvim_create_namespace(align.NS)
local NS_COMMENTS = vim.api.nvim_create_namespace(paint.NS_COMMENTS)

-- Fixed fixture: 40 rows, long lines on both sides at different rows, one on
-- the very last row.
local function fixture()
  local old, new = {}, {}
  for i = 1, 40 do
    old[i] = ("old %d"):format(i)
    new[i] = ("new %d"):format(i)
  end
  old[1] = ("t"):rep(70)
  new[5] = ("x"):rep(120)
  old[12] = ("z"):rep(90)
  new[20] = ("y"):rep(200)
  old[30] = ("v"):rep(150)
  new[40] = ("w"):rep(100)
  return old, new
end

local function open_view(files, opts)
  local function provider(path)
    local f = files[path]
    if not f then
      return {}, {}
    end
    return f.old, f.new
  end
  local file_list = {}
  for path in pairs(files) do
    file_list[#file_list + 1] = { path = path, status = "M" }
  end
  table.sort(file_list, function(a, b)
    return a.path < b.path
  end)
  local o = { content_provider = provider, first_file = file_list[1].path }
  for k, val in pairs(opts or {}) do
    o[k] = val
  end
  return view.open({ files = file_list }, o)
end

local function view_of(win)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview()
  end)
end

-- Cumulative screen heights per line, from the window's real accounting.
local function cumulative(win)
  local text, fill = align.measure(win)
  local cum, acc = {}, fill[1]
  for i = 1, #text do
    acc = acc + text[i] + fill[i + 1]
    cum[i] = acc
  end
  return cum, fill
end

local function assert_level(v, tag)
  local co, fo = cumulative(v.old_win)
  local cn, fn = cumulative(v.new_win)
  eq(#co, #cn, tag .. ": both sides have the same line count")
  for i = 1, #co do
    if co[i] ~= cn[i] then
      error(("%s: cumulative height differs at line %d (old %d, new %d)"):format(tag, i, co[i], cn[i]))
    end
  end
  -- The cached fills equalize computed analytically must match reality.
  eq(align._fill(v.old_win), fo, tag .. ": cached old fills match measured")
  eq(align._fill(v.new_win), fn, tag .. ": cached new fills match measured")
end

local function assert_synced(v, tag)
  local vo, vn = view_of(v.old_win), view_of(v.new_win)
  eq({ vo.topline, vo.topfill }, { vn.topline, vn.topfill }, tag .. ": same (topline, topfill)")
  local fo, fn = align._fill(v.old_win), align._fill(v.new_win)
  if fo[vo.topline] ~= fn[vo.topline] then
    eq(vo.topfill, 0, tag .. ": topfill is 0 where the sides' fills differ")
  end
end

-- Run a normal-mode command in `win`, then emulate the main loop around the
-- WinScrolled sync. Asserts the source window's view survives cursor
-- validation (no ping-pong between the sync and update_topline).
local function drive(v, win, cmd, lnum)
  local other = win == v.old_win and v.new_win or v.old_win
  vim.api.nvim_set_current_win(win)
  if lnum then
    vim.api.nvim_win_set_cursor(win, { lnum, 0 })
  end
  vim.cmd("normal! " .. cmd)
  local cur = vim.api.nvim_win_get_cursor(win)
  pcall(vim.api.nvim_win_set_cursor, other, { cur[1], 0 }) -- cursorbind
  ok(align.sync(v, win), "sync ran for " .. cmd)
  local before = view_of(win)
  vim.api.nvim_win_set_cursor(win, vim.api.nvim_win_get_cursor(win)) -- update_topline
  local after = view_of(win)
  eq({ after.topline, after.topfill }, { before.topline, before.topfill }, "view stable after cursor validation (" .. cmd .. ")")
end

local CTRL_E, CTRL_Y, CTRL_D, CTRL_U, CTRL_F, CTRL_B = "\5", "\25", "\4", "\21", "\6", "\2"

local function scenario(v)
  local nw, ow = v.new_win, v.old_win
  local steps = {
    { nw, "zt", 18 }, { nw, "zt", 20 }, { nw, "zt", 21 }, { nw, "zz", 30 }, { nw, "gg" },
    { nw, CTRL_D }, { nw, CTRL_D }, { nw, CTRL_E }, { nw, CTRL_E }, { nw, CTRL_E },
    { nw, CTRL_Y }, { nw, CTRL_Y }, { nw, CTRL_Y }, { nw, "G" },
    { ow, "zt", 12 }, { ow, "zt", 13 }, { ow, "zz", 25 }, { ow, "10j" }, { ow, "30k" },
    { ow, CTRL_F }, { ow, CTRL_B }, { ow, "zb", 30 }, { ow, "G" }, { ow, "gg" },
  }
  for _, s in ipairs(steps) do
    drive(v, s[1], s[2], s[3])
    assert_synced(v, s[2] .. (s[3] or ""))
    assert_level(v, s[2] .. (s[3] or ""))
  end
  for _, w in ipairs({ nw, ow }) do
    drive(v, w, "gg")
    for _ = 1, 39 do
      drive(v, w, "j")
      assert_synced(v, "walk j")
    end
    for _ = 1, 39 do
      drive(v, w, "k")
      assert_synced(v, "walk k")
    end
    drive(v, w, "gg")
    for _ = 1, 50 do
      drive(v, w, CTRL_E)
      assert_synced(v, "ctrl-e walk")
    end
    for _ = 1, 50 do
      drive(v, w, CTRL_Y)
      assert_synced(v, "ctrl-y walk")
    end
    drive(v, w, "gg")
    for _ = 1, 6 do
      drive(v, w, CTRL_D)
      assert_synced(v, "ctrl-d walk")
    end
    for _ = 1, 6 do
      drive(v, w, CTRL_U)
      assert_synced(v, "ctrl-u walk")
    end
  end
end

describe("render/align equalize", function()
  it("pads the shorter side so cumulative heights match (TST-RND-0019)", function()
    local old, new = fixture()
    local v = open_view({ ["long.txt"] = { old = old, new = new } })
    -- The fixture must actually wrap in these windows, or the test is vacuous.
    local tn = align.measure(v.new_win)
    ok(tn[5] > 1, "new line 5 wraps (" .. tn[5] .. " rows)")
    ok(align.equalize(v), "equalize ran")
    assert_level(v, "after equalize")
    local old_pads = vim.api.nvim_buf_get_extmarks(v.old_buf, NS, 0, -1, {})
    local new_pads = vim.api.nvim_buf_get_extmarks(v.new_buf, NS, 0, -1, {})
    ok(#old_pads > 0, "old side padded where new lines wrap")
    ok(#new_pads > 0, "new side padded where old lines wrap")
    -- Idempotent: a second pass yields the same fills.
    local fo1, fn1 = align._fill(v.old_win), align._fill(v.new_win)
    align.equalize(v)
    eq(align._fill(v.old_win), fo1, "old fills stable on re-equalize")
    eq(align._fill(v.new_win), fn1, "new fills stable on re-equalize")
    v:close()
  end)

  it("mirrors one-sided comment virt_lines, above row 1 and below a row", function()
    local old, new = fixture()
    local v = open_view({ ["long.txt"] = { old = old, new = new } })
    vim.api.nvim_buf_set_extmark(v.new_buf, NS_COMMENTS, 9, 0, {
      virt_lines = { { { "comment 1", "Comment" } }, { { "comment 2", "Comment" } } },
    })
    vim.api.nvim_buf_set_extmark(v.new_buf, NS_COMMENTS, 0, 0, {
      virt_lines = { { { "file comment", "Comment" } } },
      virt_lines_above = true,
    })
    align.equalize(v)
    assert_level(v, "with comments")
    local fo, fn = align._fill(v.old_win), align._fill(v.new_win)
    eq(fo[1], 1, "old row 1 padded above for the file comment")
    eq(fn[1], 1, "new row 1 carries the file comment")
    eq(fo[11], fn[11], "fills equal below the commented row (mirrored)")
    -- Equal fills: a partial fill is shared verbatim, no snap needed. Neovim
    -- scrolls onto a block of virtual lines by showing the whole block above
    -- the new topline (topfill = block height), then eats it row by row.
    drive(v, v.new_win, "zt", 10)
    drive(v, v.new_win, CTRL_E)
    local vn = view_of(v.new_win)
    eq({ vn.topline, vn.topfill }, { 11, 2 }, "Ctrl-E lands on the comment block")
    assert_synced(v, "partial fill over a comment")
    drive(v, v.new_win, CTRL_E)
    vn = view_of(v.new_win)
    eq({ vn.topline, vn.topfill }, { 11, 1 }, "Ctrl-E steps through the block one row at a time")
    assert_synced(v, "partial fill over a comment, second row")
    v:close()
  end)

  it("re-equalizes after a width change", function()
    local old, new = fixture()
    local v = open_view({ ["long.txt"] = { old = old, new = new } })
    align.equalize(v)
    local before = vim.deepcopy(align._fill(v.old_win))
    vim.api.nvim_win_set_width(v.old_win, 14)
    align.equalize(v)
    assert_level(v, "narrow old window")
    ok(not vim.deep_equal(align._fill(v.old_win), before), "fills changed with the width")
    drive(v, v.new_win, "zt", 20)
    assert_synced(v, "after resize")
    v:close()
  end)

  it("is a no-op while zoomed and in no-wrap mode; clear drops the pads", function()
    local old, new = fixture()
    local v = open_view({ ["long.txt"] = { old = old, new = new } })
    align.equalize(v)
    v:zoom("new")
    eq(align.equalize(v), false, "equalize refuses while zoomed")
    eq(align.sync(v), false, "sync refuses while zoomed")
    align.clear(v)
    eq(#vim.api.nvim_buf_get_extmarks(v.old_buf, NS, 0, -1, {}), 0, "old pads cleared")
    eq(#vim.api.nvim_buf_get_extmarks(v.new_buf, NS, 0, -1, {}), 0, "new pads cleared")
    v:unzoom()
    ok(align.equalize(v), "equalize resumes after unzoom")
    v:close()

    local nv = open_view({ ["long.txt"] = { old = old, new = new } }, { wrap = false })
    eq(align.equalize(nv), false, "no-wrap mode leaves scrollbind to Neovim")
    eq(vim.wo[nv.old_win].scrollbind, true, "native scrollbind on")
    nv:close()
  end)

  it("attach installs the watchers and a resize re-equalizes", function()
    local old, new = fixture()
    local v = open_view({ ["long.txt"] = { old = old, new = new } })
    align.attach(v)
    local aus = vim.api.nvim_get_autocmds({ group = "code_review_align" })
    local events = {}
    for _, a in ipairs(aus) do
      events[a.event] = true
    end
    eq(events, { WinScrolled = true, WinResized = true }, "WinScrolled + WinResized watched")
    -- Simulate the resize burst: one scheduled pass re-pads the buffers.
    align.clear(v)
    align.on_resized()
    align.on_resized()
    vim.wait(100, function()
      return #vim.api.nvim_buf_get_extmarks(v.old_buf, NS, 0, -1, {}) > 0
    end)
    ok(#vim.api.nvim_buf_get_extmarks(v.old_buf, NS, 0, -1, {}) > 0, "resize pass re-padded")
    assert_level(v, "after resize pass")
    align.detach()
    local found, res = pcall(vim.api.nvim_get_autocmds, { group = "code_review_align" })
    ok(not found or #res == 0, "detach removes the watchers (group gone or empty)")
    v:close()
  end)
end)

describe("render/align sync", function()
  it("keeps both windows on the same rows across scroll commands (TST-RND-0019)", function()
    local old, new = fixture()
    local v = open_view({ ["long.txt"] = { old = old, new = new } })
    align.equalize(v)
    align.sync(v, v.new_win)
    assert_synced(v, "initial")
    scenario(v)
    v:close()
  end)

  it("snaps to a line start where one side wraps and the other is padded", function()
    local old, new = fixture()
    local v = open_view({ ["long.txt"] = { old = old, new = new } })
    align.equalize(v)
    -- old line 12 wraps; new line 12 is padded below. Scroll the new side
    -- one row past line 12: Neovim shows a pad row (topfill 1), the sync snaps.
    drive(v, v.new_win, "zt", 12)
    drive(v, v.new_win, CTRL_E)
    local vn = view_of(v.new_win)
    eq({ vn.topline, vn.topfill }, { 13, 0 }, "down: snapped to the next line start")
    assert_synced(v, "snap down")
    drive(v, v.new_win, CTRL_Y)
    vn = view_of(v.new_win)
    eq({ vn.topline, vn.topfill }, { 12, 0 }, "up: snapped to the previous line start")
    assert_synced(v, "snap up")
    v:close()
  end)

  -- Random files, widths, and scroll sequences: the invariants must hold after
  -- every step.
  H.property("alignment invariants hold over random files and scroll ops", function()
    local n = math.random(5, 45)
    local old, new = {}, {}
    for i = 1, n do
      old[i] = ("o%d"):format(i)
      new[i] = ("n%d"):format(i)
      local r = math.random()
      if r < 0.15 then
        old[i] = ("a"):rep(math.random(10, 220))
      elseif r < 0.30 then
        new[i] = ("b"):rep(math.random(10, 220))
      elseif r < 0.35 then
        old[i] = ("c"):rep(math.random(10, 220))
        new[i] = ("d"):rep(math.random(10, 220))
      end
    end
    local ops = {}
    local menu = { "j", "k", "5j", "5k", CTRL_E, CTRL_Y, CTRL_D, CTRL_U, "zt", "zz", "zb", "G", "gg" }
    for _ = 1, 12 do
      ops[#ops + 1] = { side = math.random(2) == 1 and "old" or "new", cmd = menu[math.random(#menu)] }
    end
    return { old = old, new = new, ops = ops, width = math.random(12, 30) }
  end, function(input)
    local v = open_view({ ["p.txt"] = { old = input.old, new = input.new } })
    vim.api.nvim_win_set_width(v.old_win, input.width)
    align.equalize(v)
    assert_level(v, "equalize")
    align.sync(v, v.new_win)
    assert_synced(v, "initial")
    for k, op in ipairs(input.ops) do
      drive(v, v[op.side .. "_win"], op.cmd)
      assert_synced(v, ("op %d %s %s"):format(k, op.side, op.cmd))
    end
    v:close()
  end, 60)
end)
