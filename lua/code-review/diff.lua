local M = {}

function M.parse_range(range_str)
  if not range_str or range_str == "" then
    return {
      type = "working_tree",
      base = nil,
      head = nil,
    }
  end

  local a, b = range_str:match("^(.+)%.%.%.(.+)$")
  if a and b then
    return {
      type = "branch",
      base = a,
      head = b,
    }
  end

  a, b = range_str:match("^(.+)%.%.(.+)$")
  if a and b then
    return {
      type = "commit_range",
      base = a,
      head = b,
    }
  end

  return {
    type = "commit_range",
    base = range_str .. "^",
    head = range_str,
  }
end

function M.resolve_shas(parsed)
  if parsed.type == "working_tree" then
    local head_sha = M._git({ "rev-parse", "HEAD" })
    if not head_sha then
      return nil, "cannot resolve HEAD"
    end
    parsed.base_sha = head_sha
    parsed.head_sha = nil
    return parsed
  end

  if parsed.type == "branch" then
    local merge_base = M._git({ "merge-base", parsed.base, parsed.head })
    if not merge_base then
      return nil, "cannot resolve merge-base for " .. parsed.base .. "..." .. parsed.head
    end
    local head_sha = M._git({ "rev-parse", parsed.head })
    if not head_sha then
      return nil, "cannot resolve revision: " .. parsed.head
    end
    parsed.base_sha = merge_base
    parsed.head_sha = head_sha
    return parsed
  end

  local base_sha = M._git({ "rev-parse", parsed.base })
  if not base_sha then
    return nil, "cannot resolve revision: " .. parsed.base
  end
  local head_sha = M._git({ "rev-parse", parsed.head })
  if not head_sha then
    return nil, "cannot resolve revision: " .. parsed.head
  end
  parsed.base_sha = base_sha
  parsed.head_sha = head_sha
  return parsed
end

-- Run git and return raw stdout (untrimmed) plus a success flag. Used where
-- exact byte content matters (file_contents), unlike M._git which trims.
function M._git_raw(args)
  -- core.quotePath=false: git defaults to octal-escaping and double-quoting any
  -- path with non-ASCII bytes (e.g. café.lua, 数据.md). That quoted form would
  -- be split wrong and fed back into `git show <sha>:<path>`, which then fails
  -- and renders the file blank. Forcing it off keeps UTF-8 paths literal.
  local cmd = { "git", "-c", "core.quotePath=false" }
  for _, arg in ipairs(args) do
    table.insert(cmd, arg)
  end
  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 then
    return nil
  end
  return result.stdout or ""
end

-- Split a string into lines, dropping the single trailing newline a file/blob
-- carries. "" -> {}; "a\nb\n" -> {"a","b"}; "a\nb" -> {"a","b"}.
local function split_lines(s)
  if s == "" then
    return {}
  end
  -- Drop exactly one trailing newline (POSIX final-newline), not blank lines.
  if s:sub(-1) == "\n" then
    s = s:sub(1, -2)
  end
  local lines = {}
  local start = 1
  while true do
    local nl = s:find("\n", start, true)
    if not nl then
      lines[#lines + 1] = s:sub(start)
      break
    end
    lines[#lines + 1] = s:sub(start, nl - 1)
    start = nl + 1
  end
  return lines
end

-- Map a git --name-status letter to the renderer's M/A/D vocabulary.
-- R (rename) and C (copy) are treated as M on the new path.
local function map_status(letter)
  if letter == "A" then
    return "A"
  elseif letter == "D" then
    return "D"
  else
    -- M, R, C, T, U → modified on the resolved path
    return "M"
  end
end

-- changed_files(diff_info) -> FileEntry[]  where FileEntry = { path, status }.
-- working_tree: `git diff --name-status HEAD` plus untracked files (status A).
-- commit_range/branch: `git diff --name-status <base_sha> <head_sha>`.
function M.changed_files(diff_info)
  local entries = {}
  local seen = {}

  local function add(path, status, old_path)
    if not seen[path] then
      seen[path] = true
      entries[#entries + 1] = { path = path, status = status, old_path = old_path }
    end
  end

  local out
  if diff_info.type == "working_tree" then
    out = M._git_raw({ "diff", "--name-status", "HEAD" })
  else
    out = M._git_raw({ "diff", "--name-status", diff_info.base_sha, diff_info.head_sha })
  end

  for _, line in ipairs(split_lines(out or "")) do
    if line ~= "" then
      -- Fields are tab-separated: STATUS\tPATH  (rename: R100\tOLD\tNEW).
      local fields = vim.split(line, "\t", { plain = true })
      local letter = fields[1]:sub(1, 1)
      local path, old_path
      if letter == "R" or letter == "C" then
        -- Rename/copy: fields = STATUS, OLD, NEW. The diff is OLD -> NEW, so the
        -- old side must be read from the OLD path; without it `git show
        -- base:NEW` fails and the whole file renders as an addition.
        path = fields[3] or fields[2]
        old_path = fields[2]
      else
        path = fields[2]
      end
      if path and path ~= "" then
        add(path, map_status(letter), old_path)
      end
    end
  end

  if diff_info.type == "working_tree" then
    local untracked = M._git_raw({ "ls-files", "--others", "--exclude-standard" })
    for _, path in ipairs(split_lines(untracked or "")) do
      if path ~= "" then
        add(path, "A")
      end
    end
  end

  return entries
end

-- file_contents(diff_info, path[, old_path]) -> old_lines, new_lines.
-- old: `git show <base_sha>:<old_path>`, or {} if the file did not exist in
--      base. old_path defaults to path; for a rename it is the pre-rename name.
-- new: working_tree reads the working-tree file; ranges use
--      `git show <head_sha>:<path>`. {} if the file is absent on the new side.
function M.file_contents(diff_info, path, old_path)
  old_path = old_path or path
  local old_lines
  local base = diff_info.base_sha or diff_info.base
  if base then
    local old_out = M._git_raw({ "show", base .. ":" .. old_path })
    old_lines = old_out and split_lines(old_out) or {}
  else
    old_lines = {}
  end

  local new_lines
  if diff_info.type == "working_tree" then
    local root = M.git_root()
    local full = (root and (root .. "/" .. path)) or path
    local fd = io.open(full, "r")
    if fd then
      local content = fd:read("*a") or ""
      fd:close()
      new_lines = split_lines(content)
    else
      new_lines = {}
    end
  else
    local head = diff_info.head_sha or diff_info.head
    local new_out = head and M._git_raw({ "show", head .. ":" .. path }) or nil
    new_lines = new_out and split_lines(new_out) or {}
  end

  return old_lines, new_lines
end

function M.validate_range(range_str)
  if not range_str or range_str == "" then
    return true
  end

  local parsed = M.parse_range(range_str)
  local revs = {}
  if parsed.base and parsed.base ~= "" then
    table.insert(revs, parsed.base)
  end
  if parsed.head and parsed.head ~= "" then
    table.insert(revs, parsed.head)
  end

  for _, rev in ipairs(revs) do
    local result = M._git({ "rev-parse", "--verify", rev })
    if not result then
      return false, rev
    end
  end
  return true
end

function M._git(args)
  local cmd = { "git", "-c", "core.quotePath=false" }
  for _, arg in ipairs(args) do
    table.insert(cmd, arg)
  end
  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 then
    return nil
  end
  return vim.trim(result.stdout)
end

function M.git_root()
  return M._git({ "rev-parse", "--show-toplevel" })
end

function M.is_inside_work_tree()
  return M._git({ "rev-parse", "--is-inside-work-tree" }) == "true"
end

return M
