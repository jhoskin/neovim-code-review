local M = {}

M.defaults = {
  keymaps = {
    add_comment = "<leader>cc",
    file_comment = "<leader>cf",
    verdict = "<leader>cv",
    delete_comment = "<leader>cd",
    summary = "<leader>cs",
    cancel = "<leader>cq",
    pause = "<leader>cp",
    confirm_comment = "<C-s>",
  },
  highlights = {
    comment = { link = "Comment" },
    sign = { link = "DiagnosticInfo" },
    file_comment = { link = "Comment" },
  },
  sign_text = "●",
}

M.values = vim.deepcopy(M.defaults)

function M.setup(user_opts)
  M.values = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
  M._define_highlights()
end

function M._define_highlights()
  local hl = M.values.highlights
  vim.api.nvim_set_hl(0, "CodeReviewComment", vim.tbl_extend("force", { default = true }, hl.comment))
  vim.api.nvim_set_hl(0, "CodeReviewSign", vim.tbl_extend("force", { default = true }, hl.sign))
  vim.api.nvim_set_hl(0, "CodeReviewFileComment", vim.tbl_extend("force", { default = true }, hl.file_comment))
end

return M
