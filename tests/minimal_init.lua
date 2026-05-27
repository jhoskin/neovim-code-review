-- Minimal init.lua for testing code-review in isolation.
--
-- Usage:
--   nvim -u tests/minimal_init.lua
--   nvim -u tests/minimal_init.lua -c 'CodeReview'
--   nvim -u tests/minimal_init.lua -c 'checkhealth code-review'

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local deps = root .. "/.tests/deps"

-- Bootstrap: clone diffview.nvim if not present
local diffview_path = deps .. "/diffview.nvim"
if vim.fn.isdirectory(diffview_path) == 0 then
  print("Downloading diffview.nvim...")
  vim.fn.system({
    "git", "clone", "--depth", "1",
    "https://github.com/dlyongemallo/diffview.nvim.git",
    diffview_path,
  })
end

-- Set up runtimepath: plugin first, then diffview, then defaults
vim.opt.runtimepath:prepend(diffview_path)
vim.opt.runtimepath:prepend(root)

-- Minimal settings
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.g.mapleader = " "

-- Load plugins
require("diffview").setup({})
require("code-review").setup({})

print("code-review loaded. Try :CodeReview or :checkhealth code-review")
