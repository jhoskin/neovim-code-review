local M = {}

function M.parse_range(range_str)
  if not range_str or range_str == "" then
    return {
      type = "working_tree",
      base = nil,
      head = nil,
      diffview_args = "",
    }
  end

  local a, b = range_str:match("^(.+)%.%.%.(.+)$")
  if a and b then
    return {
      type = "branch",
      base = a,
      head = b,
      diffview_args = a .. "..." .. b,
    }
  end

  a, b = range_str:match("^(.+)%.%.(.+)$")
  if a and b then
    return {
      type = "commit_range",
      base = a,
      head = b,
      diffview_args = a .. ".." .. b,
    }
  end

  return {
    type = "commit_range",
    base = range_str .. "^",
    head = range_str,
    diffview_args = range_str .. "^.." .. range_str,
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

function M.open(parsed)
  if parsed.diffview_args == "" then
    vim.cmd("DiffviewOpen")
  else
    vim.cmd("DiffviewOpen " .. parsed.diffview_args)
  end
end

function M.get_diff_hunk(file_path, lineno, side, parsed)
  local args = { "diff", "--unified=3", "--no-color" }
  if parsed.type == "working_tree" then
    table.insert(args, "HEAD")
  else
    table.insert(args, (parsed.base_sha or parsed.base))
    if parsed.head_sha or parsed.head then
      table.insert(args, (parsed.head_sha or parsed.head))
    end
  end
  table.insert(args, "--")
  table.insert(args, file_path)

  local diff_output = M._git(args)
  if not diff_output then
    return ""
  end

  return M._extract_hunk(diff_output, lineno, side)
end

function M._extract_hunk(diff_text, target_line, side)
  local current_hunk_lines = {}
  local in_hunk = false
  local old_line, new_line

  for line in diff_text:gmatch("[^\n]+") do
    local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if old_start then
      if in_hunk and M._hunk_contains(current_hunk_lines, target_line, side) then
        return table.concat(current_hunk_lines, "\n")
      end
      current_hunk_lines = { line }
      in_hunk = true
      old_line = tonumber(old_start)
      new_line = tonumber(new_start)
    elseif in_hunk then
      table.insert(current_hunk_lines, line)
      local prefix = line:sub(1, 1)
      if prefix == " " then
        old_line = old_line + 1
        new_line = new_line + 1
      elseif prefix == "-" then
        old_line = old_line + 1
      elseif prefix == "+" then
        new_line = new_line + 1
      end
    end
  end

  if in_hunk and M._hunk_contains(current_hunk_lines, target_line, side) then
    return table.concat(current_hunk_lines, "\n")
  end

  return ""
end

function M._hunk_contains(hunk_lines, target_line, side)
  if #hunk_lines == 0 then
    return false
  end
  local header = hunk_lines[1]
  local old_start, old_count, new_start, new_count = header:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not old_start then
    return false
  end

  old_start = tonumber(old_start)
  old_count = tonumber(old_count) or 1
  new_start = tonumber(new_start)
  new_count = tonumber(new_count) or 1

  if side == "old" then
    return target_line >= old_start and target_line < old_start + old_count
  else
    return target_line >= new_start and target_line < new_start + new_count
  end
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
  local cmd = { "git" }
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
