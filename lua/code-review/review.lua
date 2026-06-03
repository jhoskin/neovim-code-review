local diff = require("code-review.diff")

local M = {}

-- Set once a submit/cancel/error exit path has run, so the VimLeavePre safety
-- net in init.lua does not double-cancel (e.g. turn a storage-error exit 1 into
-- a cancel exit 2).
M._exit_initiated = false

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
    files = store_data.files,
  }
end

function M.save(review_data)
  local json = vim.json.encode(review_data)
  local dir = M._audit_trail_dir()
  if not dir then
    return nil, "cannot determine audit trail directory"
  end

  -- mkdir raises E739 when a parent is unwritable; catch it so an unwritable
  -- audit dir becomes a clean storage error (exit 1) instead of a stack trace
  -- (REQ-ERR-0004). io.open below is the real gate either way.
  pcall(vim.fn.mkdir, dir, "p")

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
  M._exit_initiated = true
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
  M._exit_initiated = true
  vim.cmd("cquit 2")
end

function M.exit_error(error_type, message)
  M._exit_initiated = true
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
