local Store = {}
Store.__index = Store

function Store.new()
  return setmetatable({
    files = {},
  }, Store)
end

function Store:add_line_comment(path, old_lineno, new_lineno, side, body)
  body = vim.trim(body or "")
  if body == "" then
    return false
  end
  local file = self:_ensure_file(path)
  local key = side .. ":" .. tostring(side == "old" and old_lineno or new_lineno)
  file.lines[key] = {
    old_lineno = old_lineno,
    new_lineno = new_lineno,
    side = side,
    body = body,
    diff_hunk = nil,
  }
  return true
end

function Store:add_file_comment(path, body)
  body = vim.trim(body or "")
  if body == "" then
    return false
  end
  local file = self:_ensure_file(path)
  file.comment = body
  return true
end

function Store:delete_line_comment(path, lineno, side)
  local file = self.files[path]
  if not file then
    return false
  end
  local key = side .. ":" .. tostring(lineno)
  if not file.lines[key] then
    return false
  end
  file.lines[key] = nil
  self:_cleanup_file(path)
  return true
end

function Store:delete_file_comment(path)
  local file = self.files[path]
  if not file then
    return false
  end
  file.comment = nil
  self:_cleanup_file(path)
  return true
end

function Store:get_line_comment(path, lineno, side)
  local file = self.files[path]
  if not file then
    return nil
  end
  local key = side .. ":" .. tostring(lineno)
  return file.lines[key]
end

function Store:get_comments_for_file(path)
  return self.files[path]
end

function Store:get_all_line_comments(path)
  local file = self.files[path]
  if not file then
    return {}
  end
  local result = {}
  for _, comment in pairs(file.lines) do
    table.insert(result, comment)
  end
  table.sort(result, function(a, b)
    local a_line = a.new_lineno or a.old_lineno or 0
    local b_line = b.new_lineno or b.old_lineno or 0
    if a_line ~= b_line then
      return a_line < b_line
    end
    -- Total order tie-breakers so serialization is deterministic when two
    -- comments share a primary line number (e.g. an old-side and a new-side
    -- comment whose new_lineno coincides). Otherwise table.sort order is
    -- undefined and to_table output is non-reproducible.
    if a.side ~= b.side then
      return a.side < b.side
    end
    return (a.old_lineno or 0) < (b.old_lineno or 0)
  end)
  return result
end

function Store:get_all()
  local result = {}
  for path, file in pairs(self.files) do
    table.insert(result, {
      path = path,
      comment = file.comment,
      lines = self:get_all_line_comments(path),
    })
  end
  table.sort(result, function(a, b)
    return a.path < b.path
  end)
  return result
end

function Store:file_paths_with_comments()
  local paths = {}
  for path, _ in pairs(self.files) do
    table.insert(paths, path)
  end
  table.sort(paths)
  return paths
end

function Store:comment_count()
  local count = 0
  for _, file in pairs(self.files) do
    if file.comment then
      count = count + 1
    end
    for _ in pairs(file.lines) do
      count = count + 1
    end
  end
  return count
end

function Store:is_empty()
  return self:comment_count() == 0
end

function Store:set_diff_hunk(path, lineno, side, hunk)
  local comment = self:get_line_comment(path, lineno, side)
  if comment then
    comment.diff_hunk = hunk
  end
end

function Store:to_table()
  local files = {}
  for _, file_data in ipairs(self:get_all()) do
    local lines = {}
    for _, line in ipairs(file_data.lines) do
      table.insert(lines, {
        old_lineno = line.old_lineno,
        new_lineno = line.new_lineno,
        side = line.side,
        diff_hunk = line.diff_hunk or "",
        body = line.body,
      })
    end
    table.insert(files, {
      path = file_data.path,
      comment = file_data.comment,
      lines = lines,
    })
  end
  return {
    files = files,
  }
end

function Store:from_table(data)
  self.files = {}
  for _, file_data in ipairs(data.files or {}) do
    for _, line in ipairs(file_data.lines or {}) do
      self:add_line_comment(
        file_data.path,
        line.old_lineno,
        line.new_lineno,
        line.side,
        line.body
      )
      if line.diff_hunk and line.diff_hunk ~= "" then
        -- Key the hunk lookup the same way add_line_comment keys the comment:
        -- old-side comments key on old_lineno, new-side on new_lineno. Using
        -- new_lineno unconditionally dropped hunks on old-side comments whose
        -- old/new linenos differed.
        local key_lineno = line.side == "old" and line.old_lineno or line.new_lineno
        self:set_diff_hunk(file_data.path, key_lineno, line.side, line.diff_hunk)
      end
    end
    if file_data.comment then
      self:add_file_comment(file_data.path, file_data.comment)
    end
  end
end

function Store:_ensure_file(path)
  if not self.files[path] then
    self.files[path] = { comment = nil, lines = {} }
  end
  return self.files[path]
end

function Store:_cleanup_file(path)
  local file = self.files[path]
  if not file then
    return
  end
  if file.comment == nil and next(file.lines) == nil then
    self.files[path] = nil
  end
end

return Store
