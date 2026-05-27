if vim.g.loaded_code_review then
  return
end
vim.g.loaded_code_review = true

vim.api.nvim_create_user_command("CodeReview", function(opts)
  require("code-review").start(opts.args ~= "" and opts.args or nil)
end, {
  nargs = "?",
  desc = "Start a code review session",
})

vim.api.nvim_create_user_command("CodeReviewSessions", function()
  require("code-review").show_sessions()
end, {
  desc = "List and resume saved review sessions",
})
