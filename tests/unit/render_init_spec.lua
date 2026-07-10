-- Headless integration tests for render/init.lua, the renderer orchestrator.
-- Builds a throwaway git repo, resolves a working_tree diff_info, opens the
-- renderer against a fresh store, and asserts the view opened, cursor_context
-- maps real rows / rejects filler rows, and switch_file moves the current file.
-- Runs under `nvim --headless -l tests/unit/run.lua render_init`.
-- Covers: TST-RND-0009 (cursor row -> {path, side, lineno} mapping).

local H = ...
local describe, it = H.describe, H.it
local eq, ok = H.assert.eq, H.assert.ok

local render = require("code-review.render")
local diff = require("code-review.diff")
local Store = require("code-review.store")
local config = require("code-review.config")
local paint = require("code-review.render.paint")

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

-- Count the structural-diff extmarks on a buffer (paint's NS: line backgrounds,
-- gutter signs, intra spans), separate from the comment markers (NS_COMMENTS).
local function diff_mark_count(buf)
  local ns = vim.api.nvim_create_namespace(paint.NS)
  return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
end

local function comment_mark_count(buf)
  local ns = vim.api.nvim_create_namespace(paint.NS_COMMENTS)
  return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
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
      -- A context row carries BOTH line numbers (spec 3.2 invariant: both
      -- populated for context/modified lines), not just the anchor side.
      eq(octx.old_lineno, 1, "context row carries old_lineno")
      eq(octx.new_lineno, 1, "context row carries new_lineno")

      -- The add row (new line 2) is a pure addition: old_lineno stays nil.
      vim.api.nvim_set_current_win(view.new_win)
      vim.api.nvim_win_set_cursor(view.new_win, { 2, 0 })
      local actx = render.cursor_context()
      eq(actx.new_lineno, 2, "add row carries new_lineno")
      H.assert.is_nil(actx.old_lineno, "add row has no old_lineno")

      -- switch_file changes the current path.
      render.switch_file("b.txt")
      eq(view:current().path, "b.txt", "switch_file moved to b.txt")

      local old_win = view.old_win
      render.close()
      ok(not vim.api.nvim_win_is_valid(old_win), "close tore down the view")
    end)
    rmrf(repo)
  end)

  it("repaint_comments refreshes the panel per-file comment count", function()
    -- Fix #4: adding a comment then repainting must update the panel marker.
    local repo = make_repo()
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local store = Store.new()
      local view = render.open(info, store)

      render.switch_file("a.txt")
      -- The panel line for a.txt starts with no count marker.
      local function panel_line()
        for _, l in ipairs(vim.api.nvim_buf_get_lines(view.panel_buf, 0, -1, false)) do
          if l:find("a.txt", 1, true) then
            return l
          end
        end
      end
      ok(panel_line() and not panel_line():find("(1)", 1, true), "no count before commenting: " .. tostring(panel_line()))

      store:add_line_comment("a.txt", nil, 2, "new", "note")
      render.repaint_comments()
      ok(panel_line() and panel_line():find("(1)", 1, true), "panel shows (1) after comment: " .. tostring(panel_line()))

      render.close()
    end)
    rmrf(repo)
  end)

  -- Covers: TST-RND-0010 (next/previous-file navigation focusing the new side).
  it("next_file/prev_file cycle changed files and focus the new-side window", function()
    local repo = make_repo()
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local view = render.open(info, Store.new())
      -- Files in git order: a.txt (modified), b.txt (untracked add).
      eq(render.current_path(), "a.txt", "opens on the first file")

      render.next_file()
      eq(render.current_path(), "b.txt", "next_file advances to the second file")
      eq(vim.api.nvim_get_current_win(), view.new_win, "focus moved into the new-side window")

      render.next_file()
      eq(render.current_path(), "a.txt", "next_file wraps from last back to first")

      render.prev_file()
      eq(render.current_path(), "b.txt", "prev_file wraps from first back to last")

      render.prev_file()
      eq(render.current_path(), "a.txt", "prev_file steps back")

      render.close()
    end)
    rmrf(repo)
  end)

  -- Covers: TST-RND-0012 (focus the new-side buffer on load).
  it("open drops the cursor into the new-side window, not the panel", function()
    local repo = make_repo()
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local view = render.open(info, Store.new())
      eq(render.current_path(), "a.txt", "opens on the first file")
      eq(vim.api.nvim_get_current_win(), view.new_win,
        "cursor starts in the new-side diff window, not the file panel")
      render.close()
    end)
    rmrf(repo)
  end)

  -- Covers: TST-RND-0011 (panel selection follows the current file).
  it("switch_file marks the current file in the panel and moves the panel cursor", function()
    local repo = make_repo()
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local view = render.open(info, Store.new())
      local ns = vim.api.nvim_create_namespace("code_review_panel_current")

      -- 0-based panel rows carrying the current-file highlight.
      local function current_rows()
        local rows = {}
        for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(view.panel_buf, ns, 0, -1, { details = true })) do
          if mk[4] and mk[4].line_hl_group == "CodeReviewPanelCurrent" then
            rows[#rows + 1] = mk[2]
          end
        end
        return rows
      end

      -- 0-based panel line index for a path. Tree leaf rows show the basename
      -- (the directory segments are separate rows), so match on the basename.
      local function panel_row(path)
        local base = vim.fs.basename(path)
        for i, l in ipairs(vim.api.nvim_buf_get_lines(view.panel_buf, 0, -1, false)) do
          if l:find(base, 1, true) then
            return i - 1
          end
        end
      end

      render.switch_file("a.txt")
      eq(current_rows(), { panel_row("a.txt") }, "exactly a.txt's row is highlighted")
      eq(vim.api.nvim_win_get_cursor(view.panel_win)[1] - 1, panel_row("a.txt"),
        "panel cursor sits on a.txt")

      render.switch_file("b.txt")
      eq(current_rows(), { panel_row("b.txt") },
        "highlight moved to b.txt and only one row is marked")
      eq(vim.api.nvim_win_get_cursor(view.panel_win)[1] - 1, panel_row("b.txt"),
        "panel cursor followed to b.txt")

      render.close()
    end)
    rmrf(repo)
  end)

  it("focuses the old side when the file is a pure deletion (no new content)", function()
    local base = vim.fn.resolve(vim.fn.tempname())
    assert(vim.fn.mkdir(base, "p") == 1)
    git(base, { "init", "-q" })
    git(base, { "config", "user.email", "t@example.com" })
    git(base, { "config", "user.name", "t" })
    git(base, { "config", "commit.gpgsign", "false" })
    write_file(base, "del.txt", "gone1\ngone2\n")
    git(base, { "add", "-A" })
    git(base, { "commit", "-q", "-m", "base" })
    assert(os.remove(base .. "/del.txt"))

    in_dir(base, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local view = render.open(info, Store.new())
      eq(render.current_path(), "del.txt", "the deleted file is the only changed file")
      render.next_file() -- single file: re-renders and focuses; new side is empty
      eq(vim.api.nvim_get_current_win(), view.old_win, "pure-deletion file focuses the old side")
      render.close()
    end)
    rmrf(base)
  end)

  -- Covers: TST-RND-0014 (panel width configurable via config.values.panel_width).
  it("sizes the panel window to config.values.panel_width", function()
    local repo = make_repo()
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      eq(config.defaults.panel_width, 40, "default panel width is 40")
      local saved = config.values.panel_width
      config.values.panel_width = 18
      local view = render.open(info, Store.new())
      eq(vim.api.nvim_win_get_width(view.panel_win), 18,
        "panel window sized to the configured panel_width")
      render.close()
      config.values.panel_width = saved
    end)
    rmrf(repo)
  end)

  -- Covers: TST-RND-0016 (jump to next/previous change; wrap within file; count).
  it("next_change/prev_change jump between hunks, wrap, and honor a count", function()
    -- hunk_starts is pure: a hunk is a maximal run of non-context rows.
    eq(render._hunk_starts({ rows = {
      { kind = "context" }, { kind = "add" }, { kind = "context" },
      { kind = "context" }, { kind = "add" }, { kind = "context" },
    } }), { 2, 5 }, "hunk_starts marks each run's first row")

    local base = vim.fn.resolve(vim.fn.tempname())
    assert(vim.fn.mkdir(base, "p") == 1)
    git(base, { "init", "-q" })
    git(base, { "config", "user.email", "t@example.com" })
    git(base, { "config", "user.name", "t" })
    git(base, { "config", "commit.gpgsign", "false" })
    write_file(base, "f.txt", "1\n2\n3\n4\n")
    git(base, { "add", "-A" })
    git(base, { "commit", "-q", "-m", "base" })
    -- Two pure insertions (unambiguous single add rows): NEW after line 1, ALSO
    -- after line 3. Visual rows: ctx, add, ctx, ctx, add, ctx -> hunks at 2 and 5.
    write_file(base, "f.txt", "1\nNEW\n2\n3\nALSO\n4\n")

    in_dir(base, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local view = render.open(info, Store.new())
      eq(render.current_path(), "f.txt", "single changed file")

      vim.api.nvim_set_current_win(view.new_win)
      local function cur_row()
        return vim.api.nvim_win_get_cursor(view.new_win)[1]
      end
      vim.api.nvim_win_set_cursor(view.new_win, { 1, 0 })

      render.next_change()
      eq(cur_row(), 2, "next_change -> first hunk")
      render.next_change()
      eq(cur_row(), 5, "next_change -> second hunk")
      render.next_change()
      eq(cur_row(), 2, "next_change wraps to the first hunk")

      render.prev_change()
      eq(cur_row(), 5, "prev_change from the first hunk wraps to the last")

      vim.api.nvim_win_set_cursor(view.new_win, { 1, 0 })
      render.next_change(2)
      eq(cur_row(), 5, "next_change with count 2 steps two hunks")

      -- Both diff windows stay aligned on the same row after a jump.
      eq(vim.api.nvim_win_get_cursor(view.old_win)[1], cur_row(),
        "old and new windows sit on the same row after a jump")

      render.close()
    end)
    rmrf(base)
  end)

  -- ── Zoom (tmux-style current-side toggle) ─────────────────────────────────
  -- Covers: TST-RND-0017.

  -- Repo with two modified files that each keep both-side content (a mid-file
  -- insertion leaves context rows on both sides). Lets zoom persist across a
  -- file switch without the pure-add/delete swap kicking in. Files order x, y.
  local function make_two_modified()
    local base = vim.fn.resolve(vim.fn.tempname())
    assert(vim.fn.mkdir(base, "p") == 1)
    git(base, { "init", "-q" })
    git(base, { "config", "user.email", "t@example.com" })
    git(base, { "config", "user.name", "t" })
    git(base, { "config", "commit.gpgsign", "false" })
    write_file(base, "x.txt", "x1\nx2\n")
    write_file(base, "y.txt", "y1\ny2\n")
    git(base, { "add", "-A" })
    git(base, { "commit", "-q", "-m", "base" })
    write_file(base, "x.txt", "x1\nXNEW\nx2\n")
    write_file(base, "y.txt", "y1\nYNEW\ny2\n")
    return base
  end

  -- Repo with a single file whose one line is modified in place (shared prefix,
  -- so it diffs as a `change` row that paints BOTH sides). Lets an unzoom assert
  -- the diff paint returns on the old buffer too, not just the new.
  local function make_one_change()
    local base = vim.fn.resolve(vim.fn.tempname())
    assert(vim.fn.mkdir(base, "p") == 1)
    git(base, { "init", "-q" })
    git(base, { "config", "user.email", "t@example.com" })
    git(base, { "config", "user.name", "t" })
    git(base, { "config", "commit.gpgsign", "false" })
    write_file(base, "m.txt", "keep\nvalue = 1\n")
    git(base, { "add", "-A" })
    git(base, { "commit", "-q", "-m", "base" })
    write_file(base, "m.txt", "keep\nvalue = 2\n")
    return base
  end

  -- Covers: TST-RND-0017 (zoom the current side; survivor keeps comment mapping).
  it("toggle_zoom from the new window keeps only the new side and still maps rows", function()
    local repo = make_repo()
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local view = render.open(info, Store.new())
      render.switch_file("a.txt")
      vim.api.nvim_set_current_win(view.new_win)

      render.toggle_zoom()
      eq(view.zoomed_side, "new", "zoomed onto the new side")
      ok(vim.api.nvim_win_is_valid(view.new_win), "new window survives")
      H.assert.is_nil(view.old_win, "old window is hidden (win field cleared)")

      -- The surviving new window still anchors comments: row 2 is the insertion.
      vim.api.nvim_win_set_cursor(view.new_win, { 2, 0 })
      local ctx = render.cursor_context()
      ok(ctx ~= nil, "cursor_context resolves on the zoomed new side")
      eq(ctx.path, "a.txt")
      eq(ctx.side, "new")
      eq(ctx.lineno, 2)

      render.close()
    end)
    rmrf(repo)
  end)

  -- Covers: TST-RND-0017 (zoom persists across a same-content file switch).
  it("next_file while zoomed keeps the zoomed side", function()
    local repo = make_two_modified()
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local view = render.open(info, Store.new())
      eq(render.current_path(), "x.txt", "opens on the first modified file")

      vim.api.nvim_set_current_win(view.new_win)
      render.toggle_zoom()
      eq(view.zoomed_side, "new", "zoomed onto the new side")

      render.next_file()
      eq(render.current_path(), "y.txt", "next_file advanced to the second file")
      eq(view.zoomed_side, "new", "zoom stays on the new side across the switch")
      H.assert.is_nil(view.old_win, "old window stays hidden")
      eq(vim.api.nvim_get_current_win(), view.new_win, "focus stays in the new side")

      render.close()
    end)
    rmrf(repo)
  end)

  -- Covers: TST-RND-0017 (zoom swaps to the side with content on a pure diff).
  it("next_file into a pure-deletion file while zoomed on new swaps zoom to old", function()
    local base = vim.fn.resolve(vim.fn.tempname())
    assert(vim.fn.mkdir(base, "p") == 1)
    git(base, { "init", "-q" })
    git(base, { "config", "user.email", "t@example.com" })
    git(base, { "config", "user.name", "t" })
    git(base, { "config", "commit.gpgsign", "false" })
    write_file(base, "keep.txt", "k1\nk2\n")
    write_file(base, "del.txt", "d1\nd2\n")
    git(base, { "add", "-A" })
    git(base, { "commit", "-q", "-m", "base" })
    write_file(base, "keep.txt", "k1\nKNEW\nk2\n") -- modified: both-side content
    assert(os.remove(base .. "/del.txt")) -- pure deletion: no new-side content

    in_dir(base, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local view = render.open(info, Store.new())

      -- Start zoomed on keep.txt's new side (del.txt sorts first, so switch).
      render.switch_file("keep.txt")
      vim.api.nvim_set_current_win(view.new_win)
      render.toggle_zoom()
      eq(view.zoomed_side, "new", "zoomed onto keep.txt's new side")

      -- next_file wraps to del.txt (a pure deletion): zoom must swap to old.
      render.next_file()
      eq(render.current_path(), "del.txt", "advanced to the deleted file")
      eq(view.zoomed_side, "old", "zoom swapped to the side with content")
      H.assert.is_nil(view.new_win, "new window is hidden after the swap")
      ok(vim.api.nvim_win_is_valid(view.old_win), "old window is the survivor")
      eq(vim.api.nvim_get_current_win(), view.old_win, "focus followed to the old side")

      render.close()
    end)
    rmrf(base)
  end)

  -- Covers: TST-RND-0017 (unzoom re-syncs both windows onto the same row).
  it("next_change while zoomed then unzoom leaves both windows on the same row", function()
    local base = vim.fn.resolve(vim.fn.tempname())
    assert(vim.fn.mkdir(base, "p") == 1)
    git(base, { "init", "-q" })
    git(base, { "config", "user.email", "t@example.com" })
    git(base, { "config", "user.name", "t" })
    git(base, { "config", "commit.gpgsign", "false" })
    write_file(base, "f.txt", "1\n2\n3\n4\n")
    git(base, { "add", "-A" })
    git(base, { "commit", "-q", "-m", "base" })
    write_file(base, "f.txt", "1\nNEW\n2\n3\nALSO\n4\n") -- hunks at rows 2 and 5

    in_dir(base, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local view = render.open(info, Store.new())
      eq(render.current_path(), "f.txt", "single changed file")

      vim.api.nvim_set_current_win(view.new_win)
      render.toggle_zoom()
      eq(view.zoomed_side, "new", "zoomed onto the new side")

      render.next_change()
      eq(vim.api.nvim_win_get_cursor(view.new_win)[1], 2, "next_change moved to the first hunk")

      view:unzoom()
      H.assert.is_nil(view.zoomed_side, "no longer zoomed")
      ok(vim.api.nvim_win_is_valid(view.old_win), "old window restored")
      eq(vim.api.nvim_win_get_cursor(view.old_win)[1], vim.api.nvim_win_get_cursor(view.new_win)[1],
        "old and new windows re-synced onto the same row")

      render.close()
    end)
    rmrf(base)
  end)

  -- Covers: TST-RND-0017 (zoom from the panel keeps panel focus; toggle restores).
  it("toggle_zoom from the panel zooms new, keeps panel focus, and restores", function()
    local repo = make_repo()
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local view = render.open(info, Store.new())
      render.switch_file("a.txt")

      vim.api.nvim_set_current_win(view.panel_win)
      render.toggle_zoom()
      eq(view.zoomed_side, "new", "panel zoom targets the primary (new) side")
      H.assert.is_nil(view.old_win, "old window hidden")
      ok(vim.api.nvim_win_is_valid(view.new_win), "new window survives")
      eq(vim.api.nvim_get_current_win(), view.panel_win, "focus stays in the panel")

      render.toggle_zoom()
      H.assert.is_nil(view.zoomed_side, "toggle again unzoomed")
      ok(vim.api.nvim_win_is_valid(view.old_win), "old window restored")
      ok(vim.api.nvim_win_is_valid(view.new_win), "new window still valid")
      ok(vim.api.nvim_win_is_valid(view.panel_win), "panel still valid")
      eq(vim.api.nvim_get_current_win(), view.panel_win, "focus still in the panel")

      render.close()
    end)
    rmrf(repo)
  end)

  -- Covers: TST-RND-0017 (review_windows counts the survivors while zoomed).
  it("review_windows returns two windows while zoomed and three unzoomed", function()
    local repo = make_repo()
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local view = render.open(info, Store.new())
      render.switch_file("a.txt")
      eq(#render.review_windows(), 3, "three windows before zooming")

      vim.api.nvim_set_current_win(view.new_win)
      render.toggle_zoom()
      eq(view.zoomed_side, "new", "zoomed onto the new side")
      -- The hidden old side's win field is nil; review_windows must not stop at
      -- that nil hole and drop the surviving new + panel windows.
      eq(#render.review_windows(), 2, "panel + new side survive the zoom")

      render.toggle_zoom()
      H.assert.is_nil(view.zoomed_side, "unzoomed")
      eq(#render.review_windows(), 3, "all three windows back after unzoom")

      render.close()
    end)
    rmrf(repo)
  end)

  -- Covers: TST-RND-0017 (_side_has_content over only-old, only-new, mixed rows).
  it("_side_has_content detects per-side content in a model", function()
    local only_old = { rows = { { old_lineno = 1, new_lineno = nil } } }
    ok(render._side_has_content(only_old, "old"), "only-old model has old content")
    ok(not render._side_has_content(only_old, "new"), "only-old model has no new content")

    local only_new = { rows = { { old_lineno = nil, new_lineno = 1 } } }
    ok(render._side_has_content(only_new, "new"), "only-new model has new content")
    ok(not render._side_has_content(only_new, "old"), "only-new model has no old content")

    local mixed = { rows = {
      { old_lineno = 1, new_lineno = 1 },
      { old_lineno = nil, new_lineno = 2 },
      { old_lineno = 2, new_lineno = nil },
    } }
    ok(render._side_has_content(mixed, "old"), "mixed model has old content")
    ok(render._side_has_content(mixed, "new"), "mixed model has new content")
  end)

  -- ── Zoom shows plain syntax on the survivor (REQ-RND-0018) ────────────────
  -- Covers: TST-RND-0018.

  -- Covers: TST-RND-0018 (zoom strips the survivor's diff paint; comments stay).
  it("toggle_zoom clears the survivor's diff paint but keeps comment markers", function()
    local repo = make_repo()
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local store = Store.new()
      local view = render.open(info, store)
      render.switch_file("a.txt")

      -- A comment on the new side (row 2 is the insertion) lives in the comments
      -- namespace and must outlive the zoom.
      store:add_line_comment("a.txt", nil, 2, "new", "note")
      render.repaint_comments()
      ok(diff_mark_count(view.new_buf) >= 1, "diff paint present before zoom")
      ok(comment_mark_count(view.new_buf) >= 1, "comment marker present before zoom")

      vim.api.nvim_set_current_win(view.new_win)
      render.toggle_zoom()
      eq(view.zoomed_side, "new", "zoomed onto the new side")

      eq(diff_mark_count(view.new_buf), 0, "survivor has no diff paint while zoomed")
      ok(comment_mark_count(view.new_buf) >= 1, "comment marker still shown while zoomed")

      render.close()
    end)
    rmrf(repo)
  end)

  -- Covers: TST-RND-0018 (unzoom restores the full diff paint on both buffers).
  it("toggle_zoom twice restores diff paint on both buffers", function()
    local repo = make_one_change()
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local view = render.open(info, Store.new())
      eq(render.current_path(), "m.txt", "single changed file")
      -- The in-place change paints both sides before any zoom.
      ok(diff_mark_count(view.old_buf) >= 1, "old buffer painted before zoom")
      ok(diff_mark_count(view.new_buf) >= 1, "new buffer painted before zoom")

      vim.api.nvim_set_current_win(view.new_win)
      render.toggle_zoom()
      eq(view.zoomed_side, "new", "zoomed onto the new side")
      eq(diff_mark_count(view.new_buf), 0, "survivor cleared while zoomed")

      render.toggle_zoom()
      H.assert.is_nil(view.zoomed_side, "unzoomed")
      ok(diff_mark_count(view.new_buf) >= 1, "new buffer diff paint restored after unzoom")
      ok(diff_mark_count(view.old_buf) >= 1, "old buffer diff paint restored after unzoom")

      render.close()
    end)
    rmrf(repo)
  end)

  -- Covers: TST-RND-0018 (a file switch while zoomed re-clears the survivor).
  it("next_file while zoomed re-clears the new file's survivor buffer", function()
    local repo = make_two_modified()
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local view = render.open(info, Store.new())
      eq(render.current_path(), "x.txt", "opens on x.txt")

      vim.api.nvim_set_current_win(view.new_win)
      render.toggle_zoom()
      eq(view.zoomed_side, "new", "zoomed onto the new side")
      eq(diff_mark_count(view.new_buf), 0, "survivor cleared on x.txt")

      render.next_file()
      eq(render.current_path(), "y.txt", "advanced to y.txt")
      eq(view.zoomed_side, "new", "zoom persists across the switch")
      eq(diff_mark_count(view.new_buf), 0, "survivor re-cleared on y.txt after the switch")

      render.close()
    end)
    rmrf(repo)
  end)

  -- Covers: TST-RND-0018 (a zoom-side swap on a pure-diff file clears the new
  -- survivor buffer, not the one that was zoomed before the switch).
  it("next_file into a pure-deletion file while zoomed clears the swapped survivor", function()
    local base = vim.fn.resolve(vim.fn.tempname())
    assert(vim.fn.mkdir(base, "p") == 1)
    git(base, { "init", "-q" })
    git(base, { "config", "user.email", "t@example.com" })
    git(base, { "config", "user.name", "t" })
    git(base, { "config", "commit.gpgsign", "false" })
    write_file(base, "keep.txt", "k1\nk2\n")
    write_file(base, "del.txt", "d1\nd2\n")
    git(base, { "add", "-A" })
    git(base, { "commit", "-q", "-m", "base" })
    write_file(base, "keep.txt", "k1\nKNEW\nk2\n") -- modified: both-side content
    assert(os.remove(base .. "/del.txt")) -- pure deletion: no new-side content

    in_dir(base, function()
      local info = diff.resolve_shas(diff.parse_range(nil))
      local view = render.open(info, Store.new())

      render.switch_file("keep.txt")
      vim.api.nvim_set_current_win(view.new_win)
      render.toggle_zoom()
      eq(view.zoomed_side, "new", "zoomed onto keep.txt's new side")

      render.next_file()
      eq(render.current_path(), "del.txt", "advanced to the deleted file")
      eq(view.zoomed_side, "old", "zoom swapped to the side with content")
      -- The old buffer is the new survivor; it carries del.txt's delete-row paint
      -- until the swap re-clears it.
      eq(diff_mark_count(view.old_buf), 0, "swapped survivor has no diff paint")

      render.close()
    end)
    rmrf(base)
  end)
end)
