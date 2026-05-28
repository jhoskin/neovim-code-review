local diff = require("code-review.diff")

local M = {}

function M.serialize(store, diff_info)
  local id = os.date("!%Y%m%dT%H%M%S")
  local created_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

  local store_data = store:to_table()

  return {
    version = 1,
    id = id,
    created_at = created_at,
    diff_spec = {
      type = diff_info.type,
      base = diff_info.base_sha,
      head = diff_info.head_sha,
    },
    verdict = store_data.verdict,
    files = store_data.files,
  }
end

function M.save(review_data)
  local json = vim.json.encode(review_data)
  local dir = M._audit_trail_dir()
  if not dir then
    return nil, "cannot determine audit trail directory"
  end

  vim.fn.mkdir(dir, "p")

  local filename = review_data.id .. ".json"
  local filepath = dir .. "/" .. filename

  local file, err = io.open(filepath, "w")
  if not file then
    return nil, "cannot write review file: " .. (err or "unknown error")
  end
  file:write(json)
  file:close()

  return filepath
end

function M.write_result(review_path)
  local result_path = M._result_file_path()
  local file, err = io.open(result_path, "w")
  if not file then
    return false, "cannot write result file: " .. (err or "unknown error")
  end
  file:write(review_path)
  file:close()
  return true
end

function M.exit_submit(review_path)
  local ok, err = M.write_result(review_path)
  if not ok then
    M.exit_error("storage_error", err)
    return
  end
  -- Use quitall! to discard any modified diff buffers (the spec forbids
  -- editing source files during a review, so no real data is lost).
  vim.cmd("quitall!")
end

function M.exit_cancel()
  vim.cmd("cquit 2")
end

function M.exit_error(error_type, message)
  io.stderr:write("code-review: " .. error_type .. ": " .. message .. "\n")
  vim.cmd("cquit 1")
end

function M._audit_trail_dir()
  local root = diff.git_root()
  if not root then
    return nil
  end
  local hash = vim.fn.sha256(root):sub(1, 8)
  local base = vim.fn.stdpath("data") .. "/code-review"
  return base .. "/" .. hash
end

function M._result_file_path()
  local env = vim.env.NVIM_CODE_REVIEW_RESULT
  if env and env ~= "" then
    return env
  end
  local tmpdir = vim.env.TMPDIR or "/tmp"
  return tmpdir .. "/nvim-code-review-result"
end

return M
