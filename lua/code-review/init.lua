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

  ui.open_summary_float(M._session.store, function()
    M._do_submit()
  end, nil)
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

function M.set_verdict()
  if not M._session then
    return
  end

  local prefill = M._session.store.verdict or ""

  ui.open_comment_float({
    prefill = prefill,
    on_confirm = function(body)
      M._session.store:set_verdict(body)
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
  review.exit_submit(filepath)
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
    callback = function(ev)
      M._on_diff_buf_read(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewDiffBufWinEnter",
    callback = function(ev)
      M._on_diff_buf_win_enter(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewViewClosed",
    callback = function()
      if M._session and not M._session.submitted then
        M._cleanup()
        vim.schedule(function()
          review.exit_cancel()
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      if M._session and not M._session.submitted then
        M._cleanup()
        vim.schedule(function()
          review.exit_cancel()
        end)
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
end

function M._cleanup()
  vim.api.nvim_del_augroup_by_name("code_review_session")
  pcall(vim.api.nvim_del_user_command, "CodeReviewSubmit")
  pcall(vim.api.nvim_del_user_command, "CodeReviewPause")
  pcall(vim.api.nvim_del_user_command, "CodeReviewCopy")
  M._session = nil
end

function M._on_diff_buf_read(bufnr)
  if not M._session then
    return
  end
  M._set_keymaps(bufnr)
  M._apply_extmarks(bufnr)
end

function M._on_diff_buf_win_enter(bufnr)
  if not M._session then
    return
  end
  M._apply_extmarks(bufnr)
end

function M._set_keymaps(bufnr)
  local km = config.values.keymaps
  local opts = { buffer = bufnr, nowait = true }

  vim.keymap.set("n", km.add_comment, function()
    M.add_comment()
  end, opts)
  vim.keymap.set("n", km.delete_comment, function()
    M.delete_comment()
  end, opts)
  vim.keymap.set("n", km.verdict, function()
    M.set_verdict()
  end, opts)
  vim.keymap.set("n", km.summary, function()
    M.submit()
  end, opts)
  vim.keymap.set("n", km.file_comment, function()
    M.add_file_comment()
  end, opts)
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

  local side
  if view.cur_layout.a and view.cur_layout.a.bufnr == bufnr then
    side = "old"
  elseif view.cur_layout.b and view.cur_layout.b.bufnr == bufnr then
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
