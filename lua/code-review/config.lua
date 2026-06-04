local M = {}

M.defaults = {
  keymaps = {
    -- A value may be a string, a list of strings (binds several keys to the
    -- same action), or false to disable. Buffer-local to the review buffers.
    next_file = "<leader>Rn",
    prev_file = "<leader>RN",
    add_comment = "<leader>Rc",
    file_comment = "<leader>Rf",
    delete_comment = "<leader>Rd",
    summary = "<leader>Rs",
    cancel = "<leader>Rq",
    pause = "<leader>Rp",
    confirm_comment = "<C-s>",
  },
  highlights = {
    comment = { link = "Comment" },
    sign = { link = "DiagnosticInfo" },
    file_comment = { link = "Comment" },
    file_sign = { link = "DiagnosticHint" },
  },
  sign_text = "●",
  file_sign_text = "📄",
  -- Width (columns) of the file-tree panel. Slim by default so the side-by-side
  -- diff gets the space; the indented tree keeps rows short (REQ-RND-0014).
  panel_width = 20,
}

M.values = vim.deepcopy(M.defaults)

function M.setup(user_opts)
  M.values = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
  M._define_highlights()
end

function M._define_highlights()
  local hl = M.values.highlights

  -- default = true so a user colorscheme always wins; `override` (a value the
  -- user passed in setup{ highlights = {...} }) wins over our built-in default.
  local function set(name, default_spec, override)
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = true }, override or default_spec))
  end

  -- Comment markers (colorscheme links, background-independent).
  set("CodeReviewComment", hl.comment)
  set("CodeReviewSign", hl.sign)
  set("CodeReviewFileComment", hl.file_comment)
  set("CodeReviewFileSign", hl.file_sign)

  -- High-contrast diff accents. Line backgrounds stay linked to the
  -- colorscheme's Diff* groups (see render/paint.lua); these add the vivid
  -- word-level highlights and brightly coloured gutter signs. Defaults pick a
  -- dark or light palette by &background; each is overridable via
  -- config.values.highlights.{intra_add,intra_delete,add_sign,change_sign,
  -- delete_sign,panel_current}.
  local p = (vim.o.background == "light") and {
    intra_add = { bg = "#aceebb", fg = "#04260f", bold = true },
    intra_delete = { bg = "#ffc1c0", fg = "#4d0c0c", bold = true },
    add_sign = { fg = "#1a7f37", bold = true },
    change_sign = { fg = "#9a6700", bold = true },
    delete_sign = { fg = "#cf222e", bold = true },
    panel_current = { link = "Visual" },
  } or {
    intra_add = { bg = "#1f6f3f", fg = "#ffffff", bold = true },
    intra_delete = { bg = "#7a2c33", fg = "#ffffff", bold = true },
    add_sign = { fg = "#3fb950", bold = true },
    change_sign = { fg = "#d29922", bold = true },
    delete_sign = { fg = "#f85149", bold = true },
    panel_current = { link = "Visual" },
  }
  set("CodeReviewIntraAdd", p.intra_add, hl.intra_add)
  set("CodeReviewIntraDelete", p.intra_delete, hl.intra_delete)
  set("CodeReviewAddSign", p.add_sign, hl.add_sign)
  set("CodeReviewChangeSign", p.change_sign, hl.change_sign)
  set("CodeReviewDeleteSign", p.delete_sign, hl.delete_sign)
  set("CodeReviewPanelCurrent", p.panel_current, hl.panel_current)
end

return M
