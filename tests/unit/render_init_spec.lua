-- Headless integration tests for render/init.lua, the renderer orchestrator.
-- Builds a throwaway git repo, resolves a working_tree diff_info, opens the
-- renderer against a fresh store, and asserts the view opened, cursor_context
-- maps real rows / rejects filler rows, and switch_file moves the current file.
-- Runs under `nvim --headless -l tests/unit/run.lua render_init`.

local H = ...
local describe, it = H.describe, H.it
local eq, ok = H.assert.eq, H.assert.ok

local render = require("code-review.render")
local diff = require("code-review.diff")
local Store = require("code-review.store")

-- Run a git command inside `dir`, asserting success so a broken fixture fails
-- loudly instead of silently producing an empty diff.
local function git(dir, args)
  local cmd = { "git" }
  for _, a in ipairs(args) do
    cmd[#cmd + 1] = a
  end
  local r = vim.system(cmd, { cwd = dir, text = true }):wait()
  ok(r.code == 0, "git " .. table.concat(args, " ") .. " failed: " .. tostring(r.stderr))
  return vim.trim(r.stdout or "")
end

local function write_file(dir, rel, content)
  local fd = assert(io.open(dir .. "/" .. rel, "w"))
  fd:write(content)
  fd:close()
end

-- Build a repo with a base commit, then mutate the working tree:
--   a.txt: a pure mid-file insertion (yields an `add` row -> old-side filler).
--   b.txt: a brand new untracked file (status A).
local function make_repo()
  local base = vim.fn.tempname()
  assert(vim.fn.mkdir(base, "p") == 1)
  -- tempname may resolve through symlinks (/var -> /private/var on macOS);
  -- canonicalize so git_root comparisons line up.
  base = vim.fn.resolve(base)

  git(base, { "init", "-q" })
  git(base, { "config", "user.email", "test@example.com" })
  git(base, { "config", "user.name", "Test" })
  git(base, { "config", "commit.gpgsign", "false" })

  write_file(base, "a.txt", "line1\nline2\n")
  git(base, { "add", "-A" })
  git(base, { "commit", "-q", "-m", "base" })

  -- Insert a line in the middle of a.txt: old={line1,line2},
  -- new={line1,INSERTED,line2}. Model rows: context, add(old filler), context.
  write_file(base, "a.txt", "line1\nINSERTED\nline2\n")
  write_file(base, "b.txt", "new file\n")

  return base
end

local function in_dir(dir, fn)
  local prev = vim.uv.cwd()
  assert(vim.uv.chdir(dir))
  local okp, err = pcall(fn)
  vim.uv.chdir(prev)
  if not okp then
    error(err, 0)
  end
end

local function rmrf(dir)
  vim.fn.delete(dir, "rf")
end

describe("render/init orchestration", function()
  it("open builds the view, cursor_context maps rows, switch_file moves files", function()
    local repo = make_repo()
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      ok(info ~= nil, "resolve_shas working_tree")
      eq(info.type, "working_tree")

      local store = Store.new()
      local view = render.open(info, store)

      -- View opened: three distinct, valid windows.
      ok(view ~= nil, "open returned a view")
      ok(vim.api.nvim_win_is_valid(view.panel_win), "panel win valid")
      ok(vim.api.nvim_win_is_valid(view.old_win), "old win valid")
      ok(vim.api.nvim_win_is_valid(view.new_win), "new win valid")

      -- Drive to a known file so the assertions don't depend on changed_files
      -- ordering. a.txt has a mid-file insertion.
      render.switch_file("a.txt")
      eq(view.path, "a.txt", "a.txt is the current file")

      -- Cursor in the panel -> no diff context.
      vim.api.nvim_set_current_win(view.panel_win)
      H.assert.is_nil(render.cursor_context(), "no context from the panel")

      -- New side, row 2 holds the inserted line (new_lineno == 2).
      vim.api.nvim_set_current_win(view.new_win)
      vim.api.nvim_win_set_cursor(view.new_win, { 2, 0 })
      local ctx = render.cursor_context()
      ok(ctx ~= nil, "cursor_context on a real new-side row")
      eq(ctx.path, "a.txt")
      eq(ctx.side, "new")
      eq(ctx.lineno, 2)

      -- Old side, row 2 is the filler opposite the insertion -> nil.
      vim.api.nvim_set_current_win(view.old_win)
      vim.api.nvim_win_set_cursor(view.old_win, { 2, 0 })
      H.assert.is_nil(render.cursor_context(), "filler row yields no context")

      -- Old side, row 1 is real context (old_lineno == 1).
      vim.api.nvim_win_set_cursor(view.old_win, { 1, 0 })
      local octx = render.cursor_context()
      ok(octx ~= nil, "cursor_context on a real old-side row")
      eq(octx.side, "old")
      eq(octx.lineno, 1)

      -- switch_file changes the current path.
      render.switch_file("b.txt")
      eq(view:current().path, "b.txt", "switch_file moved to b.txt")

      local old_win = view.old_win
      render.close()
      ok(not vim.api.nvim_win_is_valid(old_win), "close tore down the view")
    end)
    rmrf(repo)
  end)
end)
