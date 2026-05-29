if vim.g.loaded_code_review then
  return
end
vim.g.loaded_code_review = true

vim.api.nvim_create_user_command("CodeReview", function(opts)
  local arg = opts.args ~= "" and opts.args or nil
  -- When invoked via `nvim -c 'CodeReview'` (e.g. from the agent
  -- launch script), this command fires during startup before VimEnter
  -- and before diffview's autocmd machinery is fully initialized. In
  -- that case defer until VimEnter so diffview's User events reach
  -- our handlers. When invoked from a running session, run immediately.
  if vim.v.vim_did_enter == 1 then
    require("code-review").start(arg)
  else
    vim.api.nvim_create_autocmd("VimEnter", {
      once = true,
      callback = function()
        require("code-review").start(arg)
      end,
    })
  end
end, {
  nargs = "?",
  desc = "Start a code review session",
})

vim.api.nvim_create_user_command("CodeReviewSessions", function()
  require("code-review").show_sessions()
end, {
  desc = "List and resume saved review sessions",
})

vim.api.nvim_create_user_command("CodeReviewDiagnose", function()
  require("code-review").diagnose()
end, {
  desc = "Print code-review session and buffer state to :messages",
})
