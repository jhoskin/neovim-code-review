if vim.g.loaded_code_review then
  return
end
vim.g.loaded_code_review = true

vim.api.nvim_create_user_command("CodeReview", function(opts)
  local arg = opts.args ~= "" and opts.args or nil
  -- When invoked via `nvim -c 'CodeReview'` (e.g. from the agent
  -- launch script), this command fires during startup before VimEnter,
  -- when the UI is not yet ready and the renderer's tab/window/keymap
  -- setup misbehaves. In that case defer until VimEnter; when invoked
  -- from a running session, run immediately.
  if vim.v.vim_did_enter == 1 then
    require("code-review").start(arg)
  else
    vim.api.nvim_create_autocmd("VimEnter", {
      once = true,
      callback = function()
        -- VimEnter still fires mid-startup. Window/cursor changes made now can
        -- be undone when Neovim draws the first screen, which would reset focus
        -- to the file panel instead of the new-side diff buffer (REQ-RND-0012).
        -- Defer one event-loop tick so the renderer's focus lands after startup
        -- settles.
        vim.schedule(function()
          require("code-review").start(arg)
        end)
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
