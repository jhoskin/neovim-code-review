local M = {}

function M.check()
  vim.health.start("code-review")

  -- Neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 required", { "Upgrade Neovim to 0.10 or later" })
  end

  -- git
  if vim.fn.executable("git") == 1 then
    local result = vim.system({ "git", "--version" }, { text = true }):wait()
    vim.health.ok("git available: " .. vim.trim(result.stdout))
  else
    vim.health.error("git not found on PATH", { "Install git" })
  end

  -- Inside git repo
  local in_repo = vim.system({ "git", "rev-parse", "--is-inside-work-tree" }, { text = true }):wait()
  if in_repo.code == 0 then
    local root = vim.system({ "git", "rev-parse", "--show-toplevel" }, { text = true }):wait()
    vim.health.ok("Inside git repo: " .. vim.trim(root.stdout))
  else
    vim.health.warn("Not inside a git repository (run :checkhealth from a repo)")
  end

  -- Audit trail directory
  local data_dir = vim.fn.stdpath("data") .. "/code-review"
  if vim.fn.isdirectory(data_dir) == 1 then
    vim.health.ok("Audit trail directory exists: " .. data_dir)
  else
    local ok = vim.fn.mkdir(data_dir, "p")
    if ok == 1 then
      vim.health.ok("Audit trail directory created: " .. data_dir)
    else
      vim.health.error("Cannot create audit trail directory: " .. data_dir)
    end
  end
end

return M
