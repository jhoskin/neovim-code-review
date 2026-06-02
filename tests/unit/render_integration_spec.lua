-- Integration spec for the render/init <-> init.lua reconciliation seams:
--   1. render.open applies opts.keymaps.diff to BOTH diff buffers and
--      opts.keymaps.panel to the panel buffer (so comment keymaps bind).
--   2. render.current_path() returns the shown file (panel-independent anchor
--      for file comments).
--   3. render.diff_hunk(path, side, lineno) builds a unified hunk from the
--      model (replaces the removed diff.get_diff_hunk).
-- Invoked by tests/unit/run.lua; the harness is passed as the argument.

local H = ...
local describe, it = H.describe, H.it
local eq, ok = H.assert.eq, H.assert.ok

local cr_diff = require("code-review.diff")
local render = require("code-review.render.init")

-- Build a temp git repo with a known working-tree change and return its path.
local function make_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function git(args)
    vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
  end
  git({ "init", "-q", "-b", "main" })
  git({ "config", "user.email", "t@example.com" })
  git({ "config", "user.name", "t" })
  git({ "config", "commit.gpgsign", "false" })
  -- committed file, then a working-tree modification (a mid-file insertion).
  vim.fn.writefile({ "local a = 1", "return a" }, dir .. "/a.lua")
  git({ "add", "a.lua" })
  git({ "commit", "-q", "-m", "init" })
  vim.fn.writefile({ "local a = 1", "local b = 2", "return a" }, dir .. "/a.lua")
  return dir
end

describe("render/init integration seams", function()
  it("applies opts.keymaps to both diff buffers and the panel buffer", function()
    local repo = make_repo()
    local cwd = vim.fn.getcwd()
    vim.cmd("cd " .. repo)

    local diff_info = cr_diff.resolve_shas(cr_diff.parse_range(nil))
    local Store = require("code-review.store")
    local store = Store.new()

    local diff_bufs, panel_bufs = {}, {}
    render.open(diff_info, store, {
      keymaps = {
        diff = function(b) diff_bufs[#diff_bufs + 1] = b end,
        panel = function(b) panel_bufs[#panel_bufs + 1] = b end,
      },
    })

    -- Both diff buffers received the diff keymap callback exactly once each.
    eq(#diff_bufs, 2, "diff keymap callback invoked for both diff buffers")
    ok(diff_bufs[1] ~= diff_bufs[2], "the two diff buffers are distinct")
    eq(#panel_bufs, 1, "panel keymap callback invoked once")

    render.close()
    vim.cmd("cd " .. cwd)
    vim.fn.delete(repo, "rf")
  end)

  it("current_path returns the shown file and diff_hunk builds a unified hunk", function()
    local repo = make_repo()
    local cwd = vim.fn.getcwd()
    vim.cmd("cd " .. repo)

    local diff_info = cr_diff.resolve_shas(cr_diff.parse_range(nil))
    local Store = require("code-review.store")
    render.open(diff_info, Store.new(), {})

    eq(render.current_path(), "a.lua", "current_path is the first changed file")

    -- The inserted line "local b = 2" is new_lineno 2 (an add row). diff_hunk
    -- must return a unified hunk that starts with @@ and contains the add.
    local hunk = render.diff_hunk("a.lua", "new", 2)
    ok(type(hunk) == "string" and hunk:sub(1, 2) == "@@", "hunk starts with @@ header")
    ok(hunk:find("+local b = 2", 1, true) ~= nil, "hunk contains the added line with + prefix")

    -- A lineno that is not in the model returns "".
    eq(render.diff_hunk("a.lua", "new", 9999), "", "unknown line yields empty hunk")

    render.close()
    vim.cmd("cd " .. cwd)
    vim.fn.delete(repo, "rf")
  end)
end)
