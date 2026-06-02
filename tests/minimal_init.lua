-- Minimal init.lua for testing code-review in isolation.
--
-- Usage:
--   nvim -u tests/minimal_init.lua
--   nvim -u tests/minimal_init.lua -c 'CodeReview'
--   nvim -u tests/minimal_init.lua -c 'checkhealth code-review'
--
-- The renderer is self-contained (pure Lua + vim.diff), so there are no
-- plugin dependencies to bootstrap.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

vim.opt.runtimepath:prepend(root)

-- Minimal settings
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.g.mapleader = " "

require("code-review").setup({})

if not vim.g.code_review_silent then
  print("code-review loaded. Try :CodeReview or :checkhealth code-review")
end
