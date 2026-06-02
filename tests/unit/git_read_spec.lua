-- Integration-flavored tests for the git-read layer in code-review/diff.lua
-- (changed_files + file_contents). Each test builds a throwaway git repo in a
-- mktemp dir, makes known changes, drives the read layer from inside that repo
-- (cwd is swapped), then asserts the returned paths/statuses/line arrays.
-- Runs headless under `nvim --headless -l tests/unit/run.lua git_read`.

local H = ...
local describe, it = H.describe, H.it
local eq, ok = H.assert.eq, H.assert.ok

local diff = require("code-review.diff")

-- Run a git command inside `dir`. Asserts success so a broken fixture fails
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

local function remove_file(dir, rel)
  assert(os.remove(dir .. "/" .. rel))
end

-- Create a fresh repo with a base commit and return its absolute path.
-- Base tree:
--   keep.txt = "keep line\n"
--   mod.txt  = "old one\nold two\nold three\n"
--   del.txt  = "doomed\n"
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

  write_file(base, "keep.txt", "keep line\n")
  write_file(base, "mod.txt", "old one\nold two\nold three\n")
  write_file(base, "del.txt", "doomed\n")
  git(base, { "add", "-A" })
  git(base, { "commit", "-q", "-m", "base" })

  return base
end

-- Apply the standard set of changes to the working tree (no commit):
--   mod.txt modified, add.txt created (untracked), del.txt deleted.
local function mutate(dir)
  write_file(dir, "mod.txt", "old one\nNEW two\nold three\n")
  write_file(dir, "add.txt", "fresh a\nfresh b\n")
  remove_file(dir, "del.txt")
end

-- Sort FileEntry[] by path for order-independent comparison.
local function by_path(entries)
  local copy = {}
  for _, e in ipairs(entries) do
    copy[#copy + 1] = { path = e.path, status = e.status }
  end
  table.sort(copy, function(a, b)
    return a.path < b.path
  end)
  return copy
end

-- Run `fn` with cwd swapped into `dir`, restoring the original cwd after.
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

describe("code-review/diff git-read: working_tree", function()
  it("changed_files reports M/A/D with untracked as A", function()
    local repo = make_repo()
    mutate(repo)
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(""))
      ok(info ~= nil, "resolve_shas working_tree")
      eq(info.type, "working_tree")

      local files = by_path(diff.changed_files(info))
      eq(files, {
        { path = "add.txt", status = "A" },
        { path = "del.txt", status = "D" },
        { path = "mod.txt", status = "M" },
      })
    end)
    rmrf(repo)
  end)

  it("file_contents returns old/new line arrays for each status", function()
    local repo = make_repo()
    mutate(repo)
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(""))

      -- Modified: old from HEAD, new from working tree.
      local mold, mnew = diff.file_contents(info, "mod.txt")
      eq(mold, { "old one", "old two", "old three" })
      eq(mnew, { "old one", "NEW two", "old three" })

      -- Added (untracked): no base blob, new from working tree.
      local aold, anew = diff.file_contents(info, "add.txt")
      eq(aold, {})
      eq(anew, { "fresh a", "fresh b" })

      -- Deleted: old from HEAD, new file gone.
      local dold, dnew = diff.file_contents(info, "del.txt")
      eq(dold, { "doomed" })
      eq(dnew, {})
    end)
    rmrf(repo)
  end)
end)

describe("code-review/diff git-read: commit_range", function()
  it("changed_files reports M/A/D across two commits", function()
    local repo = make_repo()
    local base_sha = git(repo, { "rev-parse", "HEAD" })
    mutate(repo)
    git(repo, { "add", "-A" })
    git(repo, { "commit", "-q", "-m", "change" })
    local head_sha = git(repo, { "rev-parse", "HEAD" })

    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(base_sha .. ".." .. head_sha))
      ok(info ~= nil, "resolve_shas commit_range")
      eq(info.type, "commit_range")
      eq(#info.base_sha, 40, "base SHA resolved to 40 chars")
      eq(#info.head_sha, 40, "head SHA resolved to 40 chars")

      local files = by_path(diff.changed_files(info))
      eq(files, {
        { path = "add.txt", status = "A" },
        { path = "del.txt", status = "D" },
        { path = "mod.txt", status = "M" },
      })
    end)
    rmrf(repo)
  end)

  it("file_contents returns old/new from the two commit blobs", function()
    local repo = make_repo()
    local base_sha = git(repo, { "rev-parse", "HEAD" })
    mutate(repo)
    git(repo, { "add", "-A" })
    git(repo, { "commit", "-q", "-m", "change" })
    local head_sha = git(repo, { "rev-parse", "HEAD" })

    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(base_sha .. ".." .. head_sha))

      -- Modified: both sides from their respective commits.
      local mold, mnew = diff.file_contents(info, "mod.txt")
      eq(mold, { "old one", "old two", "old three" })
      eq(mnew, { "old one", "NEW two", "old three" })

      -- Added: absent in base, present at head.
      local aold, anew = diff.file_contents(info, "add.txt")
      eq(aold, {})
      eq(anew, { "fresh a", "fresh b" })

      -- Deleted: present in base, absent at head.
      local dold, dnew = diff.file_contents(info, "del.txt")
      eq(dold, { "doomed" })
      eq(dnew, {})
    end)
    rmrf(repo)
  end)
end)

describe("code-review/diff git-read: line-splitting edge cases", function()
  -- file_contents must drop exactly one trailing newline (POSIX final-newline),
  -- preserve interior blank lines, and map an empty file to {} (not {""}).
  -- A regression to vim.trim() or to stripping all trailing blanks would pass
  -- the happy-path tests above but break these.
  it("preserves blank lines and distinguishes empty file from one blank line", function()
    local repo = make_repo()
    write_file(repo, "empty.txt", "")
    write_file(repo, "nonl.txt", "no trailing newline")
    write_file(repo, "blanks.txt", "a\n\nb\n") -- interior blank
    write_file(repo, "trail.txt", "x\ny\n\n") -- two trailing blanks: one is the
    -- POSIX final newline, one is a real blank line -> {"x","y",""}
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(""))

      local _, empty_new = diff.file_contents(info, "empty.txt")
      eq(empty_new, {}, "empty file -> {} not {''}")

      local _, nonl_new = diff.file_contents(info, "nonl.txt")
      eq(nonl_new, { "no trailing newline" }, "file without trailing newline")

      local _, blanks_new = diff.file_contents(info, "blanks.txt")
      eq(blanks_new, { "a", "", "b" }, "interior blank preserved")

      local _, trail_new = diff.file_contents(info, "trail.txt")
      eq(trail_new, { "x", "y", "" }, "one trailing blank kept after dropping final newline")
    end)
    rmrf(repo)
  end)

  it("reads commit blobs with the same newline semantics", function()
    local repo = make_repo()
    write_file(repo, "blanks.txt", "a\n\nb\n")
    write_file(repo, "nonl.txt", "no trailing newline")
    git(repo, { "add", "-A" })
    git(repo, { "commit", "-q", "-m", "edge" })
    local head_sha = git(repo, { "rev-parse", "HEAD" })
    local base_sha = git(repo, { "rev-parse", "HEAD~1" })

    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(base_sha .. ".." .. head_sha))
      local _, blanks_new = diff.file_contents(info, "blanks.txt")
      eq(blanks_new, { "a", "", "b" }, "blob interior blank preserved")
      local _, nonl_new = diff.file_contents(info, "nonl.txt")
      eq(nonl_new, { "no trailing newline" }, "blob without trailing newline")
    end)
    rmrf(repo)
  end)
end)

describe("code-review/diff git-read: branch (three-dot) and renames", function()
  -- Branch reviews resolve base to the merge-base, not the literal base ref.
  -- changed_files / file_contents must work off the resolved SHAs.
  it("branch changed_files uses merge-base and reports M/A/D", function()
    local repo = make_repo()
    -- Capture the default branch name (master vs main varies by git version).
    local main_branch = git(repo, { "rev-parse", "--abbrev-ref", "HEAD" })
    local fork_point = git(repo, { "rev-parse", "HEAD" })
    -- Create a feature branch off the base commit and mutate it.
    git(repo, { "checkout", "-q", "-b", "feature" })
    mutate(repo)
    git(repo, { "add", "-A" })
    git(repo, { "commit", "-q", "-m", "feature work" })
    -- Advance the default branch independently so its tip != the merge-base.
    -- The read must diff against the merge-base, not the default branch tip.
    git(repo, { "checkout", "-q", main_branch })
    write_file(repo, "keep.txt", "keep line\nmain-only change\n")
    git(repo, { "add", "-A" })
    git(repo, { "commit", "-q", "-m", "main advances" })
    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(main_branch .. "...feature"))
      eq(info.base_sha, fork_point, "base resolves to merge-base (fork point), not default-branch tip")
      ok(info ~= nil, "resolve_shas branch")
      eq(info.type, "branch")
      eq(#info.base_sha, 40, "merge-base resolved to 40 chars")
      eq(#info.head_sha, 40, "head resolved to 40 chars")

      local files = by_path(diff.changed_files(info))
      eq(files, {
        { path = "add.txt", status = "A" },
        { path = "del.txt", status = "D" },
        { path = "mod.txt", status = "M" },
      })

      local mold, mnew = diff.file_contents(info, "mod.txt")
      eq(mold, { "old one", "old two", "old three" })
      eq(mnew, { "old one", "NEW two", "old three" })
    end)
    rmrf(repo)
  end)

  it("renames resolve to the new path with status M", function()
    local repo = make_repo()
    local base_sha = git(repo, { "rev-parse", "HEAD" })
    -- Rename keep.txt -> renamed.txt and tweak it so git records a rename.
    git(repo, { "mv", "keep.txt", "renamed.txt" })
    write_file(repo, "renamed.txt", "keep line\nplus one\n")
    git(repo, { "add", "-A" })
    git(repo, { "commit", "-q", "-m", "rename keep" })
    local head_sha = git(repo, { "rev-parse", "HEAD" })

    in_dir(repo, function()
      local info = diff.resolve_shas(diff.parse_range(base_sha .. ".." .. head_sha))
      local files = by_path(diff.changed_files(info))
      -- The new path must appear with status M; the old path must NOT appear.
      local seen = {}
      for _, e in ipairs(files) do
        seen[e.path] = e.status
      end
      eq(seen["renamed.txt"], "M", "rename target reported as M on new path")
      H.assert.is_nil(seen["keep.txt"], "old rename path not reported")
    end)
    rmrf(repo)
  end)
end)

describe("code-review/diff git-read: dead diffview API removed", function()
  it("open and get_diff_hunk no longer exist", function()
    H.assert.is_nil(diff.open, "open should be removed")
    H.assert.is_nil(diff.get_diff_hunk, "get_diff_hunk should be removed")
  end)

  it("parse_range keeps type/base/head and drops diffview_args", function()
    local wt = diff.parse_range("")
    eq(wt.type, "working_tree")
    H.assert.is_nil(wt.diffview_args, "diffview_args dropped")

    local cr = diff.parse_range("aaa..bbb")
    eq(cr.type, "commit_range")
    eq(cr.base, "aaa")
    eq(cr.head, "bbb")
    H.assert.is_nil(cr.diffview_args, "diffview_args dropped")

    local br = diff.parse_range("main...feat")
    eq(br.type, "branch")
    eq(br.base, "main")
    eq(br.head, "feat")
  end)
end)
