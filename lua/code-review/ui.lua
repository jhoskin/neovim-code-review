local config = require("code-review.config")

local M = {}

M.ns = nil

function M.create_namespace()
  if not M.ns then
    M.ns = vim.api.nvim_create_namespace("code_review")
  end
  return M.ns
end

function M.render_line_comment(bufnr, line, body)
  local ns = M.create_namespace()
  local virt_lines = {}
  for _, text_line in ipairs(vim.split(body, "\n")) do
    table.insert(virt_lines, { { config.values.sign_text .. " " .. text_line, "CodeReviewComment" } })
  end

  return vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
    sign_text = config.values.sign_text,
    sign_hl_group = "CodeReviewSign",
  })
end

function M.render_file_comment(bufnr, body)
  local ns = M.create_namespace()
  local sign_text = config.values.file_sign_text or "📄"
  local virt_lines = {}
  for _, text_line in ipairs(vim.split(body, "\n")) do
    table.insert(virt_lines, { { sign_text .. " " .. text_line, "CodeReviewFileComment" } })
  end

  return vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
    virt_lines = virt_lines,
    virt_lines_above = true,
    sign_text = sign_text,
    sign_hl_group = "CodeReviewFileSign",
  })
end

function M.clear_extmarks(bufnr)
  local ns = M.create_namespace()
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

function M.reapply_from_store(bufnr, file_path, store, side)
  M.clear_extmarks(bufnr)
  local file_data = store:get_comments_for_file(file_path)
  if not file_data then
    return
  end

  if file_data.comment then
    M.render_file_comment(bufnr, file_data.comment)
  end

  for _, comment in pairs(file_data.lines) do
    if comment.side == side then
      local line = side == "old" and comment.old_lineno or comment.new_lineno
      if line then
        M.render_line_comment(bufnr, line, comment.body)
      end
    end
  end
end

-- Detach every LSP client currently attached to bufnr. Also register an
-- LspAttach autocmd so any client that attaches later is detached
-- immediately. This protects transient scratch buffers (comment input,
-- summary) from third-party LSPs that match on filetype heuristics or
-- syntax even when our custom filetype is set.
function M._detach_any_lsp(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local clients = (vim.lsp.get_clients or vim.lsp.get_active_clients)({ bufnr = bufnr })
  for _, client in ipairs(clients) do
    pcall(vim.lsp.buf_detach_client, bufnr, client.id)
  end
  vim.api.nvim_create_autocmd("LspAttach", {
    buffer = bufnr,
    callback = function(args)
      pcall(vim.lsp.buf_detach_client, bufnr, args.data.client_id)
    end,
  })
end

function M.open_comment_float(opts)
  opts = opts or {}
  local prefill = opts.prefill or ""
  local on_confirm = opts.on_confirm
  local on_cancel = opts.on_cancel

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  -- Use a non-standard filetype so third-party markdown LSPs (Marksman,
  -- etc.) don't attach to the transient scratch buffer.
  vim.bo[buf].filetype = "codereview"
  M._detach_any_lsp(buf)
  -- Apply markdown syntax highlighting manually (does not trigger LSP).
  pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("setlocal syntax=markdown")
  end)
  M._detach_any_lsp(buf)

  if prefill ~= "" then
    local lines = vim.split(prefill, "\n")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end

  local width = math.min(80, math.floor(vim.o.columns * 0.6))
  local height = math.max(3, math.min(10, #vim.split(prefill, "\n") + 2))

  local title = string.format(
    " Comment — %s save · q cancel · <C-w>w leave (text preserved) ",
    config.values.keymaps.confirm_comment
  )
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })

  vim.cmd("startinsert!")

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  local function confirm()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    close()
    if text == "" then
      if on_cancel then
        on_cancel()
      end
      return
    end
    if on_confirm then
      on_confirm(text)
    end
  end

  local function cancel()
    close()
    if on_cancel then
      on_cancel()
    end
  end

  vim.keymap.set({ "n", "i" }, config.values.keymaps.confirm_comment, confirm, {
    buffer = buf, nowait = true, desc = "Code review: confirm comment",
  })
  vim.keymap.set("n", "q", cancel, {
    buffer = buf, nowait = true, desc = "Code review: cancel comment",
  })

  -- Treat any other close (e.g. :q, <C-w>c) as cancel so we don't leak buffers
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      if on_cancel then
        on_cancel()
      end
    end,
  })
end

function M.open_summary_float(store, on_confirm, on_cancel, preview_lines)
  local lines = preview_lines or M._build_summary_lines(store)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  -- Custom filetype prevents markdown LSPs from attaching (see comment
  -- in open_comment_float).
  vim.bo[buf].filetype = "codereview"
  M._detach_any_lsp(buf)
  pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("setlocal syntax=markdown")
  end)
  M._detach_any_lsp(buf)

  local width = math.min(100, math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Review Summary — <CR> submit, q cancel ",
    title_pos = "center",
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  vim.keymap.set("n", "<CR>", function()
    close()
    if on_confirm then
      on_confirm()
    end
  end, { buffer = buf, nowait = true, desc = "Code review: confirm submit" })

  vim.keymap.set("n", "q", function()
    close()
    if on_cancel then
      on_cancel()
    end
  end, { buffer = buf, nowait = true, desc = "Code review: cancel summary" })

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end,
  })
end

function M._build_summary_lines(store)
  local lines = {}
  local function add(s)
    table.insert(lines, s)
  end

  local count = store:comment_count()
  add("# Review Summary")
  add("")
  add("Comments: " .. count)
  add("")

  for _, file_data in ipairs(store:get_all()) do
    add("## " .. file_data.path)

    if file_data.comment then
      add("  File: " .. file_data.comment)
    end

    for _, comment in ipairs(file_data.lines) do
      local lineno = comment.new_lineno or comment.old_lineno
      add("  L" .. tostring(lineno) .. " (" .. comment.side .. "): " .. comment.body:gsub("\n", " "))
    end
    add("")
  end

  if count == 0 then
    add("(empty review — no comments)")
  end

  return lines
end

return M
