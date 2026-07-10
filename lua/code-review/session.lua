local diff = require("code-review.diff")
local Store = require("code-review.store")

local M = {}

function M.save(store, diff_info)
  local dir = M._sessions_dir()
  if not dir then
    return nil, "cannot determine sessions directory"
  end
  vim.fn.mkdir(dir, "p")

  local session_id = diff_info.session_id or M._generate_id()
  local filepath = dir .. "/" .. session_id .. ".json"

  local data = {
    session_id = session_id,
    created_at = diff_info.created_at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    range_str = diff_info.range_str,
    diff_info = {
      type = diff_info.type,
      base = diff_info.base,
      head = diff_info.head,
      base_sha = diff_info.base_sha,
      head_sha = diff_info.head_sha,
      diffview_args = diff_info.diffview_args,
    },
    store = store:to_table(),
  }

  local json = vim.json.encode(data)
  local file, err = io.open(filepath, "w")
  if not file then
    return nil, "cannot write session file: " .. (err or "unknown error")
  end
  file:write(json)
  file:close()

  return session_id
end

function M.load(session_id)
  local dir = M._sessions_dir()
  if not dir then
    return nil, "cannot determine sessions directory"
  end

  local filepath = dir .. "/" .. session_id .. ".json"
  local file, err = io.open(filepath, "r")
  if not file then
    return nil, "cannot read session file: " .. (err or "unknown error")
  end
  local content = file:read("*a")
  file:close()

  local ok, data = pcall(vim.json.decode, content)
  if not ok then
    return nil, "invalid session JSON"
  end

  local store = Store.new()
  store:from_table(data.store)

  return {
    session_id = data.session_id,
    created_at = data.created_at,
    updated_at = data.updated_at,
    range_str = data.range_str,
    diff_info = data.diff_info,
    store = store,
  }
end

function M.delete(session_id)
  local dir = M._sessions_dir()
  if not dir then
    return false
  end
  local filepath = dir .. "/" .. session_id .. ".json"
  return os.remove(filepath) ~= nil
end

function M.list()
  local dir = M._sessions_dir()
  if not dir then
    return {}
  end

  local sessions = {}
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return {}
  end

  while true do
    local name, type = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if type == "file" and name:match("%.json$") then
      local session_id = name:gsub("%.json$", "")
      local session_data = M.load(session_id)
      if session_data then
        table.insert(sessions, {
          session_id = session_data.session_id,
          range_str = session_data.range_str,
          created_at = session_data.created_at,
          updated_at = session_data.updated_at,
          comment_count = session_data.store:comment_count(),
        })
      end
    end
  end

  table.sort(sessions, function(a, b)
    return a.updated_at > b.updated_at
  end)

  return sessions
end

function M._sessions_dir()
  local root = diff.git_root()
  if not root then
    return nil
  end
  local hash = vim.fn.sha256(root):sub(1, 8)
  local base = vim.fn.stdpath("data") .. "/code-review"
  return base .. "/" .. hash .. "/sessions"
end

function M._generate_id()
  local bytes = {}
  for i = 1, 6 do
    bytes[i] = string.format("%02x", math.random(0, 255))
  end
  return table.concat(bytes)
end

return M
