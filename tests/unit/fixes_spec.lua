-- Regression tests for the code-review-max review fixes. Each test pins one
-- corrected behavior so it does not silently regress. Invoked by
-- tests/unit/run.lua, which passes the harness as the argument.

local H = ...
local describe, it = H.describe, H.it
local eq, ok = H.assert.eq, H.assert.ok

local diff = require("code-review.diff")
local render_diff = require("code-review.render.diff")
local paint = require("code-review.render.paint")
local Store = require("code-review.store")

-- ── git fixture helpers (mirrors git_read_spec) ────────────────────────────
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

local function new_repo()
  local base = vim.fn.resolve(vim.fn.tempname())
  assert(vim.fn.mkdir(base, "p") == 1)
  git(base, { "init", "-q" })
  git(base, { "config", "user.email", "test@example.com" })
  git(base, { "config", "user.name", "Test" })
  git(base, { "config", "commit.gpgsign", "false" })
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

local function scratch_buf()
  return vim.api.nvim_create_buf(false, true)
end

local function has_file_comment(buf, ns)
  for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mk[4] and mk[4].virt_lines then
      return true
    end
  end
  return false
end

-- ── store:count_for (panel per-file count) ─────────────────────────────────
describe("store:count_for", function()
  it("counts only the given file, while comment_count is the whole store", function()
    local s = Store.new()
    s:add_line_comment("a.lua", nil, 1, "new", "one")
    s:add_line_comment("a.lua", nil, 2, "new", "two")
    s:add_file_comment("a.lua", "file note")
    s:add_line_comment("b.lua", nil, 1, "new", "other")

    eq(s:count_for("a.lua"), 3, "a.lua: two line comments + one file comment")
    eq(s:count_for("b.lua"), 1, "b.lua: one line comment")
    eq(s:count_for("missing.lua"), 0, "unknown file: zero")
    eq(s:comment_count(), 4, "whole-store total is the sum")
  end)
end)

-- ── render/diff.word_diff guards ───────────────────────────────────────────
describe("render/diff.word_diff guards", function()
  it("identical strings yield no spans", function()
    local r = render_diff.word_diff("hello world", "hello world")
    eq(r.old, {})
    eq(r.new, {})
  end)

  it("skips intra-line diff on very long lines (no O(n^2) blowup)", function()
    local a = string.rep("x", 5000) .. "a"
    local b = string.rep("x", 5000) .. "b"
    local r = render_diff.word_diff(a, b)
    eq(r.old, {}, "long old line: no spans")
    eq(r.new, {}, "long new line: no spans")
  end)

  it("still diffs normal-length lines", function()
    local r = render_diff.word_diff("local a = 1", "local a = 2")
    ok(#r.new >= 1, "a normal change still produces spans")
  end)
end)

-- ── render/diff uses the locked vim.diff options (TST-RND-0001) ────────────
describe("render/diff vim.diff options", function()
  it("calls vim.diff with histogram/linematch/indices/indent_heuristic", function()
    local captured
    local orig = vim.diff
    vim.diff = function(a, b, opts)
      captured = opts
      return orig(a, b, opts)
    end
    local ok_run, err = pcall(render_diff.compute, { "a", "b" }, { "a", "x", "b" })
    vim.diff = orig
    ok(ok_run, "compute ran: " .. tostring(err))
    ok(captured ~= nil, "vim.diff was called")
    eq(captured.result_type, "indices")
    eq(captured.algorithm, "histogram")
    eq(captured.linematch, 60)
    eq(captured.indent_heuristic, true)
  end)
end)

-- ── render/paint comment edge cases ────────────────────────────────────────
describe("render/paint comment edges", function()
  it("paints a deleted file's file comment on the old side", function()
    local old_buf, new_buf = scratch_buf(), scratch_buf()
    -- Deleted file: empty new side, so every row is a delete (new_lineno nil).
    local m = render_diff.compute({ "gone1", "gone2" }, {})
    local view = { old_buf = old_buf, new_buf = new_buf, path = "gone.lua" }
    local store = {
      get_all = function()
        return { { path = "gone.lua", comment = "why removed?", lines = {} } }
      end,
    }
    paint.apply(view, m, store)
    local ns = vim.api.nvim_create_namespace(paint.NS_COMMENTS)
    ok(has_file_comment(old_buf, ns), "file comment on the old side that shows the file")
    ok(not has_file_comment(new_buf, ns), "not on the empty new side")
  end)

  it("keeps a comment visible when its line is no longer in the model", function()
    local old_buf, new_buf = scratch_buf(), scratch_buf()
    -- Model has new lines 1..2; the stored comment points at new line 99 (the
    -- file shrank since the comment was made on a resumed session).
    local m = render_diff.compute({ "a", "b" }, { "a", "b" })
    local view = { old_buf = old_buf, new_buf = new_buf, path = "f.lua" }
    local store = {
      get_all = function()
        return {
          {
            path = "f.lua",
            comment = nil,
            lines = { { side = "new", old_lineno = 99, new_lineno = 99, body = "drifted" } },
          },
        }
      end,
    }
    paint.apply(view, m, store)
    local ns = vim.api.nvim_create_namespace(paint.NS_COMMENTS)
    ok(has_file_comment(new_buf, ns), "drifted comment still painted (clamped to nearest row)")
  end)
end)

-- ── render/paint: incremental comment repaint keeps diff paint (fix #12) ───
describe("render/paint.apply_comments isolation", function()
  it("repaints only NS_COMMENTS, leaving the diff paint in NS intact", function()
    local old_buf, new_buf = scratch_buf(), scratch_buf()
    -- A change row guarantees diff paint (line bg + signs + intra) lands in NS.
    local m = render_diff.compute({ "local x = 1", "keep" }, { "local x = 2", "keep" })
    local view = { old_buf = old_buf, new_buf = new_buf, lang = "lua", path = "f.lua" }

    paint.apply(view, m, { get_all = function() return {} end })
    local ns = vim.api.nvim_create_namespace(paint.NS)
    local before = #vim.api.nvim_buf_get_extmarks(new_buf, ns, 0, -1, {})
    ok(before >= 1, "diff paint present in NS after apply")

    -- A comment-only repaint must not disturb the NS diff marks.
    paint.apply_comments(view, m, {
      get_all = function()
        return { { path = "f.lua", comment = "note", lines = {} } }
      end,
    }, "f.lua")

    local after = #vim.api.nvim_buf_get_extmarks(new_buf, ns, 0, -1, {})
    eq(after, before, "diff paint in NS is untouched by apply_comments")
    local nsc = vim.api.nvim_create_namespace(paint.NS_COMMENTS)
    ok(#vim.api.nvim_buf_get_extmarks(new_buf, nsc, 0, -1, {}) >= 1, "comment marker in NS_COMMENTS")
  end)
end)

-- ── render/paint: treesitter stop-before-start on reused buffers (fix #6) ───
describe("render/paint treesitter lifecycle", function()
  it("stops the prior highlighter when switching to a no-language file", function()
    local active = vim.treesitter.highlighter and vim.treesitter.highlighter.active
    if not active then
      return -- internal table unavailable on this Neovim; skip
    end
    local old_buf, new_buf = scratch_buf(), scratch_buf()
    local view = { old_buf = old_buf, new_buf = new_buf, lang = "lua", path = "a.lua" }
    paint.apply(view, render_diff.compute({ "local x = 1" }, { "local x = 2" }), { get_all = function() return {} end })
    ok(vim.treesitter.highlighter.active[new_buf] ~= nil, "lua highlighter active after first apply")

    -- Switch the reused buffer to a file with no treesitter language.
    view.lang = nil
    view.path = "b.txt"
    paint.apply(view, render_diff.compute({ "plain" }, { "plain text" }), { get_all = function() return {} end })
    H.assert.is_nil(
      vim.treesitter.highlighter.active[new_buf],
      "prior highlighter stopped when the new file has no language"
    )
  end)
end)

-- ── diff.lua: rename old-side content + non-ASCII paths (quotePath) ─────────
describe("code-review/diff rename and non-ASCII paths", function()
  it("file_contents reads the old side from the pre-rename path", function()
    local repo = new_repo()
    write_file(repo, "keep.txt", "alpha\nbeta\n")
    git(repo, { "add", "-A" })
    git(repo, { "commit", "-q", "-m", "base" })
    local base_sha = git(repo, { "rev-parse", "HEAD" })
    -- Rename with a content tweak so git records R<score> old -> new.
    git(repo, { "mv", "keep.txt", "renamed.txt" })
    write_file(repo, "renamed.txt", "alpha\nbeta\ngamma\n")
    git(repo, { "add", "-A" })
    git(repo, { "commit", "-q", "-m", "rename" })
    local head_sha = git(repo, { "rev-parse", "HEAD" })

    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(base_sha .. ".." .. head_sha))
      local entry
      for _, e in ipairs(diff.changed_files(info)) do
        if e.path == "renamed.txt" then
          entry = e
        end
      end
      ok(entry ~= nil, "renamed.txt reported")
      eq(entry.old_path, "keep.txt", "old_path carries the pre-rename name")

      -- With old_path, the old side is the original keep.txt content (not {}).
      local old_lines, new_lines = diff.file_contents(info, entry.path, entry.old_path)
      eq(old_lines, { "alpha", "beta" }, "old side from the pre-rename blob")
      eq(new_lines, { "alpha", "beta", "gamma" }, "new side from the renamed blob")
    end)
    rmrf(repo)
  end)

  it("changed_files keeps non-ASCII paths literal (core.quotePath=false)", function()
    local repo = new_repo()
    -- CJK name: precomposed, so no macOS NFD-normalization ambiguity.
    write_file(repo, "数据.txt", "one\n")
    git(repo, { "add", "-A" })
    git(repo, { "commit", "-q", "-m", "base" })
    write_file(repo, "数据.txt", "one\ntwo\n")

    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(""))
      local paths = {}
      for _, e in ipairs(diff.changed_files(info)) do
        paths[e.path] = true
      end
      ok(paths["数据.txt"], "path is literal UTF-8, not octal-escaped/quoted")

      local _, new_lines = diff.file_contents(info, "数据.txt")
      eq(new_lines, { "one", "two" }, "file_contents reads the non-ASCII path")
    end)
    rmrf(repo)
  end)
end)

-- ── diff.range_commit_count (REQ-ERR-0001) ─────────────────────────────────
describe("code-review/diff.range_commit_count", function()
  it("counts commits in a range and reports zero for an empty one", function()
    local repo = new_repo()
    write_file(repo, "a.txt", "1\n")
    git(repo, { "add", "-A" })
    git(repo, { "commit", "-q", "-m", "c1" })
    write_file(repo, "a.txt", "2\n")
    git(repo, { "add", "-A" })
    git(repo, { "commit", "-q", "-m", "c2" })

    in_dir(repo, function()
      local one = diff.resolve_shas(diff.parse_range("HEAD~1..HEAD"))
      eq(diff.range_commit_count(one), 1, "one commit in HEAD~1..HEAD")

      local zero = diff.resolve_shas(diff.parse_range("HEAD..HEAD"))
      eq(diff.range_commit_count(zero), 0, "zero commits in HEAD..HEAD")

      local wt = diff.resolve_shas(diff.parse_range(nil))
      H.assert.is_nil(diff.range_commit_count(wt), "working_tree has no commit range")
    end)
    rmrf(repo)
  end)
end)

-- ── render.diff_hunk picks the right row for an old-side comment ────────────
describe("render.diff_hunk old-side row selection", function()
  it("does not match an add row whose new_lineno equals the old lineno", function()
    local render = require("code-review.render")
    local repo = new_repo()
    -- base: A b c d e f ; work inserts X before A so an add row (new_lineno 1)
    -- precedes the context row holding old line 1 (A).
    write_file(repo, "f.txt", "A\nb\nc\nd\ne\nf\n")
    git(repo, { "add", "-A" })
    git(repo, { "commit", "-q", "-m", "base" })
    write_file(repo, "f.txt", "X\nA\nb\nc\nd\ne\nf\n")

    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(""))
      render.open(info, Store.new())
      render.switch_file("f.txt")

      -- Comment on OLD line 1 (A). The add row (X) has new_lineno 1; the buggy
      -- `and/or` idiom would match it. The fixed lookup targets the context row
      -- holding old_lineno 1, giving header @@ -1,4 +1,5 @@ (vs @@ -1,3 +1,4 @@).
      local hunk = render.diff_hunk("f.txt", "old", 1)
      ok(hunk:find("@@ -1,4 +1,5 @@", 1, true) == 1, "hunk header centers on the old-line-1 row: " .. hunk)
      ok(hunk:find("\n A\n", 1, true) ~= nil, "context line A present")
      render.close()
    end)
    rmrf(repo)
  end)
end)
