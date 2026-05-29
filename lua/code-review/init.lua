local config = require("code-review.config")
local diff = require("code-review.diff")
local Store = require("code-review.store")
local review = require("code-review.review")
local export = require("code-review.export")
local session = require("code-review.session")
local ui = require("code-review.ui")

local M = {}

M._session = nil

function M.setup(opts)
  config.setup(opts)
end

function M.start(range_str)
  if M._session then
    vim.notify("code-review: a review session is already active", vim.log.levels.WARN)
    return
  end

  local err = M._preflight()
  if err then
    return
  end

  local parsed = diff.parse_range(range_str)
  local resolved, resolve_err = diff.resolve_shas(parsed)
  if not resolved then
    review.exit_error("invalid_range", resolve_err)
    return
  end

  M._session = {
    store = Store.new(),
    diff_info = resolved,
    range_str = range_str,
    submitted = false,
    session_id = nil,
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }

  M._register_autocmds()
  M._register_commands()
  diff.open(resolved)
end

function M.start_from_session(session_id)
  if M._session then
    vim.notify("code-review: a review session is already active", vim.log.levels.WARN)
    return
  end

  local err = M._preflight()
  if err then
    return
  end

  local data, load_err = session.load(session_id)
  if not data then
    vim.notify("code-review: " .. load_err, vim.log.levels.ERROR)
    return
  end

  M._session = {
    store = data.store,
    diff_info = data.diff_info,
    range_str = data.range_str,
    submitted = false,
    session_id = data.session_id,
    created_at = data.created_at,
  }

  M._register_autocmds()
  M._register_commands()
  diff.open(data.diff_info)
end

function M.submit()
  if not M._session then
    return
  end

  -- Build a preview of the exact markdown that will be exported on confirm.
  local data = review.serialize(M._session.store, M._session.diff_info)
  M._populate_hunks(data)
  local agent_mode = vim.env.NVIM_CODE_REVIEW_RESULT ~= nil
    and vim.env.NVIM_CODE_REVIEW_RESULT ~= ""
  local mode_note = agent_mode
      and "Confirming will write to the result file and exit Neovim."
    or "Confirming will copy the markdown below to your clipboard and close the review."

  local markdown = export.to_markdown(data)
  local preview = { "Submit review?", "", mode_note, "" }
  for _, line in ipairs(vim.split(markdown, "\n", { plain = true })) do
    table.insert(preview, line)
  end

  ui.open_summary_float(M._session.store, function()
    M._do_submit()
  end, nil, preview)
end

function M.cancel()
  if not M._session then
    return
  end
  local agent_mode = vim.env.NVIM_CODE_REVIEW_RESULT ~= nil
    and vim.env.NVIM_CODE_REVIEW_RESULT ~= ""
  M._cleanup()
  pcall(vim.cmd, "DiffviewClose")
  if agent_mode then
    review.exit_cancel()
  else
    vim.notify("code-review: review cancelled")
  end
end

function M.pause()
  if not M._session then
    return
  end

  local s = M._session
  s.diff_info.session_id = s.session_id
  s.diff_info.created_at = s.created_at
  s.diff_info.range_str = s.range_str

  local sid, err = session.save(s.store, s.diff_info)
  if not sid then
    vim.notify("code-review: " .. err, vim.log.levels.ERROR)
    return
  end

  M._cleanup()
  vim.cmd("DiffviewClose")
  vim.notify("code-review: session paused (" .. sid .. ")")
end

function M.show_sessions()
  local sessions = session.list()
  if #sessions == 0 then
    vim.notify("code-review: no saved sessions")
    return
  end

  local items = {}
  for _, s in ipairs(sessions) do
    local label = string.format(
      "%s | %s | %d comments | %s",
      s.session_id:sub(1, 8),
      s.range_str or "working tree",
      s.comment_count,
      s.updated_at
    )
    table.insert(items, label)
  end

  vim.ui.select(items, { prompt = "Resume session:" }, function(_, idx)
    if not idx then
      return
    end
    M.start_from_session(sessions[idx].session_id)
  end)
end

function M.copy()
  if not M._session then
    vim.notify("code-review: no active review session", vim.log.levels.WARN)
    return
  end
  local data = review.serialize(M._session.store, M._session.diff_info)
  M._populate_hunks(data)
  export.to_clipboard(data)
  vim.notify("code-review: review copied to clipboard")
end

function M.add_comment()
  if not M._session then
    return
  end

  local view = M._get_view()
  if not view then
    return
  end

  local file_path, side, lineno = M._cursor_context(view)
  if not file_path then
    return
  end

  local existing = M._session.store:get_line_comment(file_path, lineno, side)
  local prefill = existing and existing.body or ""

  ui.open_comment_float({
    prefill = prefill,
    on_confirm = function(body)
      local old_lineno = side == "old" and lineno or nil
      local new_lineno = side == "new" and lineno or nil
      M._session.store:add_line_comment(file_path, old_lineno, new_lineno, side, body)
      local bufnr = vim.api.nvim_get_current_buf()
      ui.reapply_from_store(bufnr, file_path, M._session.store, side)
    end,
  })
end

function M.add_file_comment()
  if not M._session then
    return
  end

  local view = M._get_view()
  if not view then
    return
  end

  local file_path = M._file_under_cursor(view)
  if not file_path then
    return
  end

  local existing = M._session.store:get_comments_for_file(file_path)
  local prefill = existing and existing.comment or ""

  ui.open_comment_float({
    prefill = prefill,
    on_confirm = function(body)
      M._session.store:add_file_comment(file_path, body)
    end,
  })
end

function M.delete_comment()
  if not M._session then
    return
  end

  local view = M._get_view()
  if not view then
    return
  end

  local file_path, side, lineno = M._cursor_context(view)
  if not file_path then
    return
  end

  if M._session.store:delete_line_comment(file_path, lineno, side) then
    local bufnr = vim.api.nvim_get_current_buf()
    ui.reapply_from_store(bufnr, file_path, M._session.store, side)
  end
end

function M._do_submit()
  if not M._session then
    return
  end

  local s = M._session
  local data = review.serialize(s.store, s.diff_info)
  M._populate_hunks(data)

  local filepath, err = review.save(data)
  if not filepath then
    review.exit_error("storage_error", err)
    return
  end

  if s.session_id then
    session.delete(s.session_id)
  end

  s.submitted = true
  M._cleanup()

  local agent_mode = vim.env.NVIM_CODE_REVIEW_RESULT ~= nil
    and vim.env.NVIM_CODE_REVIEW_RESULT ~= ""

  if agent_mode then
    review.exit_submit(filepath)
  else
    export.to_clipboard(data)
    pcall(vim.cmd, "DiffviewClose")
    vim.notify(
      "code-review: submitted (saved to " .. filepath .. "; markdown copied to clipboard)",
      vim.log.levels.INFO
    )
  end
end

function M._populate_hunks(data)
  if not M._session then
    return
  end
  for _, file in ipairs(data.files) do
    for _, line in ipairs(file.lines) do
      if (not line.diff_hunk or line.diff_hunk == "") then
        local lineno = line.new_lineno or line.old_lineno
        line.diff_hunk = diff.get_diff_hunk(file.path, lineno, line.side, M._session.diff_info)
      end
    end
  end
end

function M._preflight()
  if vim.fn.has("nvim-0.10") ~= 1 then
    review.exit_error("version_error", "requires Neovim >= 0.10")
    return "version"
  end

  local ok = pcall(require, "diffview")
  if not ok then
    review.exit_error("no_diffview", "diffview.nvim is not installed or cannot be loaded")
    return "diffview"
  end

  local lib_ok, lib = pcall(require, "diffview.lib")
  if not lib_ok or type(lib.get_current_view) ~= "function" then
    review.exit_error("no_diffview", "diffview.nvim API is incompatible (missing get_current_view)")
    return "diffview_api"
  end

  if vim.fn.executable("git") ~= 1 then
    review.exit_error("no_git", "git is not available on PATH")
    return "git"
  end

  if not diff.is_inside_work_tree() then
    review.exit_error("not_a_repo", "current directory is not inside a git repository")
    return "repo"
  end

  return nil
end

function M._register_autocmds()
  local group = vim.api.nvim_create_augroup("code_review_session", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewDiffBufRead",
    callback = function()
      M._on_diff_buf_read()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewDiffBufWinEnter",
    callback = function()
      M._on_diff_buf_win_enter()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewViewClosed",
    callback = function()
      if M._session and not M._session.submitted then
        local agent_mode = vim.env.NVIM_CODE_REVIEW_RESULT ~= nil
          and vim.env.NVIM_CODE_REVIEW_RESULT ~= ""
        M._cleanup()
        if agent_mode then
          vim.schedule(function()
            review.exit_cancel()
          end)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      if M._session and not M._session.submitted then
        local agent_mode = vim.env.NVIM_CODE_REVIEW_RESULT ~= nil
          and vim.env.NVIM_CODE_REVIEW_RESULT ~= ""
        M._cleanup()
        if agent_mode then
          vim.schedule(function()
            review.exit_cancel()
          end)
        end
      end
    end,
  })
end

function M._register_commands()
  vim.api.nvim_create_user_command("CodeReviewSubmit", function()
    M.submit()
  end, {})
  vim.api.nvim_create_user_command("CodeReviewPause", function()
    M.pause()
  end, {})
  vim.api.nvim_create_user_command("CodeReviewCopy", function()
    M.copy()
  end, {})
  vim.api.nvim_create_user_command("CodeReviewCancel", function()
    M.cancel()
  end, {})
end

function M._cleanup()
  vim.api.nvim_del_augroup_by_name("code_review_session")
  pcall(vim.api.nvim_del_user_command, "CodeReviewSubmit")
  pcall(vim.api.nvim_del_user_command, "CodeReviewPause")
  pcall(vim.api.nvim_del_user_command, "CodeReviewCopy")
  pcall(vim.api.nvim_del_user_command, "CodeReviewCancel")
  M._session = nil
end

function M._layout_bufnr(layout_side)
  if not layout_side then
    return nil
  end
  if layout_side.file and layout_side.file.bufnr then
    return layout_side.file.bufnr
  end
  if layout_side.id and vim.api.nvim_win_is_valid(layout_side.id) then
    return vim.api.nvim_win_get_buf(layout_side.id)
  end
  return nil
end

function M._make_readonly(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = false
end

-- Diffview's diff buffers represent files via synthetic names like
-- `diffview:///path/to/repo/.git/:0:/README.md`. When a third-party LSP
-- like Marksman attaches because the filetype is markdown, then tries
-- to handle the buffer's close event, it errors because the path
-- doesn't exist on disk. Worse: detaching with `buf_detach_client`
-- sends textDocument/didClose, which IS the call that crashes
-- Marksman. So we gracefully stop the client process (sends LSP
-- shutdown+exit, server exits with code 0) on any LSP that attaches
-- to a diff buffer. See ui.stop_lsps (REQ-LSP-0001). Side effect:
-- the user's other markdown buffers lose the LSP until lspconfig
-- re-attaches on the next FileType event.
function M._strip_lsps(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  ui.stop_lsps(bufnr)
end

function M._on_diff_buf_read()
  if not M._session then
    return
  end
  local view = M._get_view()
  if not view or not view.cur_layout then
    return
  end
  local a_buf = M._layout_bufnr(view.cur_layout.a)
  local b_buf = M._layout_bufnr(view.cur_layout.b)
  if a_buf then
    M._set_keymaps(a_buf)
    M._apply_extmarks(a_buf)
    M._make_readonly(a_buf)
    M._strip_lsps(a_buf)
  end
  if b_buf then
    M._set_keymaps(b_buf)
    M._apply_extmarks(b_buf)
    M._make_readonly(b_buf)
    M._strip_lsps(b_buf)
  end
  if view.panel and view.panel.bufid then
    M._set_file_panel_keymaps(view.panel.bufid)
  end
end

function M._on_diff_buf_win_enter()
  if not M._session then
    return
  end
  local view = M._get_view()
  if not view or not view.cur_layout then
    return
  end
  local a_buf = M._layout_bufnr(view.cur_layout.a)
  local b_buf = M._layout_bufnr(view.cur_layout.b)
  if a_buf then
    M._apply_extmarks(a_buf)
    M._make_readonly(a_buf)
    M._strip_lsps(a_buf)
  end
  if b_buf then
    M._apply_extmarks(b_buf)
    M._make_readonly(b_buf)
    M._strip_lsps(b_buf)
  end
end

function M._set_file_panel_keymaps(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local km = config.values.keymaps
  local function map(lhs, fn, desc)
    if lhs == false then
      return
    end
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, nowait = true, desc = desc })
  end

  map(km.file_comment, M.add_file_comment, "Code review: add file comment")
  map(km.summary, M.submit, "Code review: submit (show summary)")
  map(km.cancel, M.cancel, "Code review: cancel review")
  map(km.pause, M.pause, "Code review: pause session")
end

function M._set_keymaps(bufnr)
  local km = config.values.keymaps
  local function map(lhs, fn, desc)
    if lhs == false then
      return
    end
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, nowait = true, desc = desc })
  end

  map(km.add_comment, M.add_comment, "Code review: add line comment")
  map(km.delete_comment, M.delete_comment, "Code review: delete comment")
  map(km.summary, M.submit, "Code review: submit (show summary)")
  map(km.file_comment, M.add_file_comment, "Code review: add file comment")
  map(km.cancel, M.cancel, "Code review: cancel review")
  map(km.pause, M.pause, "Code review: pause session")
end

function M._apply_extmarks(bufnr)
  if not M._session then
    return
  end

  local view = M._get_view()
  if not view then
    return
  end

  local file_path, side = M._buf_context(view, bufnr)
  if not file_path then
    return
  end

  ui.reapply_from_store(bufnr, file_path, M._session.store, side)
end

function M._get_view()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return nil
  end
  return lib.get_current_view()
end

function M._cursor_context(view)
  if not view or not view.cur_layout then
    return nil, nil, nil
  end

  local win = vim.api.nvim_get_current_win()
  local side
  if view.cur_layout.a and win == view.cur_layout.a.id then
    side = "old"
  elseif view.cur_layout.b and win == view.cur_layout.b.id then
    side = "new"
  else
    return nil, nil, nil
  end

  local file = view:infer_cur_file()
  if not file then
    return nil, nil, nil
  end

  local lineno = vim.api.nvim_win_get_cursor(win)[1]
  return file.path, side, lineno
end

function M._buf_context(view, bufnr)
  if not view or not view.cur_layout then
    return nil, nil
  end

  local a_buf = M._layout_bufnr(view.cur_layout.a)
  local b_buf = M._layout_bufnr(view.cur_layout.b)

  local side
  if a_buf == bufnr then
    side = "old"
  elseif b_buf == bufnr then
    side = "new"
  else
    return nil, nil
  end

  local file = view:infer_cur_file()
  if not file then
    return nil, nil
  end

  return file.path, side
end

function M._file_under_cursor(view)
  if not view or not view.panel then
    return nil
  end
  local ok, item = pcall(function()
    return view.panel:get_item_at_cursor()
  end)
  if not ok or not item then
    return nil
  end
  return item.path
end

return M
