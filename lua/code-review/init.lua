local config = require("code-review.config")
local diff = require("code-review.diff")
local Store = require("code-review.store")
local review = require("code-review.review")
local export = require("code-review.export")
local session = require("code-review.session")
local ui = require("code-review.ui")

local M = {}

M._session = nil

-- Agent mode is signalled by the result-file env var the launcher sets.
function M._agent_mode()
  return vim.env.NVIM_CODE_REVIEW_RESULT ~= nil and vim.env.NVIM_CODE_REVIEW_RESULT ~= ""
end

function M.setup(opts)
  config.setup(opts)
end

-- Options handed to render.open so the renderer can apply the comment-action
-- keymaps to the buffers it owns. The renderer builds the diff/panel buffers
-- (per render/CONTRACT.md), so it owns *when* keymaps land; init.lua still owns
-- *what* they do, because the maps call back into M.add_comment/M.submit/etc.
-- and the renderer must not depend on init.lua. See note to lead re: contract.
function M._render_opts()
  return {
    keymaps = {
      diff = function(bufnr)
        M._set_keymaps(bufnr)
      end,
      panel = function(bufnr)
        M._set_file_panel_keymaps(bufnr)
      end,
    },
  }
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

  -- REQ-ERR-0001: a non-working_tree range that resolves to zero commits is an
  -- error (there is nothing to review).
  if resolved.type ~= "working_tree" and diff.range_commit_count(resolved) == 0 then
    review.exit_error("empty_range", "range resolves to zero commits: " .. (range_str or ""))
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
  local render = require("code-review.render.init")
  render.open(M._session.diff_info, M._session.store, M._render_opts())
  M._notify_started()
end

function M.diagnose()
  local lines = { "=== code-review diagnose ===" }
  local function add(s) table.insert(lines, s) end

  add("session active: " .. tostring(M._session ~= nil))
  if M._session then
    add("  diff_info: " .. vim.inspect(M._session.diff_info))
    add("  submitted: " .. tostring(M._session.submitted))
  end

  local cur_buf = vim.api.nvim_get_current_buf()
  local cur_name = vim.api.nvim_buf_get_name(cur_buf)
  add("current buffer: " .. cur_buf .. " (" .. cur_name .. ")")
  add("  modifiable: " .. tostring(vim.bo[cur_buf].modifiable))
  add("  readonly: " .. tostring(vim.bo[cur_buf].readonly))

  local maps = vim.api.nvim_buf_get_keymap(cur_buf, "n")
  local r_keys = {}
  for _, m in ipairs(maps) do
    if m.lhs and m.lhs:match("R") then
      table.insert(r_keys, m.lhs .. (m.desc and (" → " .. m.desc) or ""))
    end
  end
  add("R-related keymaps on current buffer:")
  if #r_keys == 0 then
    add("  (none)")
  else
    for _, k in ipairs(r_keys) do
      add("  " .. k)
    end
  end

  local ok_r, render = pcall(require, "code-review.render.init")
  if ok_r and type(render.cursor_context) == "function" then
    local ctx = render.cursor_context()
    if ctx then
      add(string.format("render cursor: %s [%s] L%d", ctx.path, ctx.side, ctx.lineno))
    else
      add("render cursor: (none / filler row / panel)")
    end
  else
    add("render: not loadable")
  end

  for _, l in ipairs(lines) do print(l) end
end

-- A keymap value may be a string, a list of strings, or false. Render the
-- primary key for a human-facing hint.
local function key_label(v)
  if type(v) == "table" then
    return v[1] or "?"
  elseif v == false or v == nil then
    return "(off)"
  end
  return v
end

function M._notify_started()
  local km = config.values.keymaps
  vim.notify(
    string.format(
      "code-review: review started. %s/%s next/prev file · %s/%s next/prev change · %s line · %s file comment · %s submit · %s cancel",
      key_label(km.next_file),
      key_label(km.prev_file),
      key_label(km.next_change),
      key_label(km.prev_change),
      key_label(km.add_comment),
      key_label(km.file_comment),
      key_label(km.summary),
      key_label(km.cancel)
    ),
    vim.log.levels.INFO
  )
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
  local render = require("code-review.render.init")
  render.open(M._session.diff_info, M._session.store, M._render_opts())
  M._notify_started()
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
  require("code-review.render.init").close()
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
  require("code-review.render.init").close()
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

-- Move to the next / previous changed file (focuses the new-side window).
function M.next_file()
  if not M._session then
    return
  end
  require("code-review.render.init").next_file()
end

function M.prev_file()
  if not M._session then
    return
  end
  require("code-review.render.init").prev_file()
end

-- Jump to the next / previous changed hunk within the current file.
function M.next_change()
  if not M._session then
    return
  end
  require("code-review.render.init").next_change()
end

function M.prev_change()
  if not M._session then
    return
  end
  require("code-review.render.init").prev_change()
end

-- Toggle zooming the current diff side to full width (tmux-style).
function M.toggle_zoom()
  if not M._session then
    return
  end
  require("code-review.render.init").toggle_zoom()
end

function M.add_comment()
  if not M._session then
    return
  end

  local render = require("code-review.render.init")
  local ctx = render.cursor_context()
  if not ctx then
    return
  end
  local file_path, side, lineno = ctx.path, ctx.side, ctx.lineno

  local existing = M._session.store:get_line_comment(file_path, lineno, side)
  local prefill = existing and existing.body or ""

  ui.open_comment_float({
    prefill = prefill,
    kind = "line",
    path = file_path,
    on_confirm = function(body)
      -- Store both line numbers from the model row (set for context/modified
      -- lines, one nil for a pure add/delete). The store keys by the anchor
      -- side, so `side` still selects the key.
      M._session.store:add_line_comment(file_path, ctx.old_lineno, ctx.new_lineno, side, body)
      -- Comment-only repaint: just the markers + panel counts, no buffer refill.
      render.repaint_comments()
    end,
  })
end

function M.add_file_comment()
  if not M._session then
    return
  end

  local render = require("code-review.render.init")
  -- File comments apply to the whole current file, so anchor to the file shown
  -- in the diff windows (valid even when the cursor is in the panel), not to a
  -- specific cursor row.
  local file_path = render.current_path()
  if not file_path then
    return
  end

  local existing = M._session.store:get_comments_for_file(file_path)
  local prefill = existing and existing.comment or ""

  ui.open_comment_float({
    prefill = prefill,
    kind = "file",
    path = file_path,
    on_confirm = function(body)
      M._session.store:add_file_comment(file_path, body)
      render.repaint_comments()
    end,
  })
end

function M.delete_comment()
  if not M._session then
    return
  end

  local render = require("code-review.render.init")
  local ctx = render.cursor_context()
  if not ctx then
    return
  end
  local file_path, side, lineno = ctx.path, ctx.side, ctx.lineno

  if M._session.store:delete_line_comment(file_path, lineno, side) then
    render.repaint_comments()
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
    require("code-review.render.init").close()
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
  local render = require("code-review.render.init")
  for _, file in ipairs(data.files) do
    for _, line in ipairs(file.lines) do
      if (not line.diff_hunk or line.diff_hunk == "") then
        local lineno = line.side == "old" and line.old_lineno or line.new_lineno
        line.diff_hunk = render.diff_hunk(file.path, line.side, lineno)
      end
    end
  end
end

function M._preflight()
  if vim.fn.has("nvim-0.10") ~= 1 then
    review.exit_error("version_error", "requires Neovim >= 0.10")
    return "version"
  end

  -- REQ-ERR-0008: the review is interactive, so it needs an attached UI. A
  -- headless Neovim (`--headless`, no UI) cannot take comment input; fail fast
  -- instead of opening an unusable session. (nvim_list_uis is the reliable
  -- signal -- guess_handle(0) flips to "file" whenever stderr is redirected,
  -- even with a UI attached.) The agent launcher runs a real TUI, so this does
  -- not affect agent mode.
  if #vim.api.nvim_list_uis() == 0 then
    review.exit_error("no_ui", "no interactive UI (running headless); the review needs an interactive Neovim")
    return "no_ui"
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

  -- A stray :q on one of the renderer panes just closes that window; nothing
  -- cancels the review (no QuitPre handler). The review ends only on an
  -- explicit submit/cancel/pause, or when Neovim actually exits (below).
  --
  -- Process-exit safety net: Neovim is quitting (any :q/:qall/:wq) with an
  -- unsubmitted review and no explicit submit/cancel/error ran. Treat it as a
  -- cancel; agent mode exits with code 2 (REQ-UIX-0007). This is the reliable
  -- signal -- QuitPre cannot tell a single-pane :q from a full :qall. `cquit`
  -- is a no-op this late in shutdown, so force the exit code with os.exit.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if not (M._session and not M._session.submitted) then
        return
      end
      if review._exit_initiated then
        return
      end
      local agent = M._agent_mode()
      M._cleanup()
      if agent then
        review._exit_initiated = true
        os.exit(2)
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

-- Apply the line-diff comment-action keymaps to a renderer diff buffer. The
-- renderer invokes this (via M._render_opts) when it builds the buffers.
-- Bind one comment-action key buffer-locally. A keymap value may be a string
-- (one key), a list of strings (bind several keys to the same action), or
-- false (skip). nowait so single keys fire immediately.
local function set_map(bufnr, lhs, fn, desc)
  if lhs == nil or lhs == false then
    return
  end
  local keys = type(lhs) == "table" and lhs or { lhs }
  for _, key in ipairs(keys) do
    vim.keymap.set("n", key, fn, { buffer = bufnr, nowait = true, desc = desc })
  end
end

function M._set_keymaps(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local km = config.values.keymaps
  set_map(bufnr, km.next_file, M.next_file, "Code review: next file")
  set_map(bufnr, km.prev_file, M.prev_file, "Code review: previous file")
  set_map(bufnr, km.next_change, M.next_change, "Code review: next change")
  set_map(bufnr, km.prev_change, M.prev_change, "Code review: previous change")
  set_map(bufnr, km.toggle_zoom, M.toggle_zoom, "Code review: zoom current side")
  set_map(bufnr, km.add_comment, M.add_comment, "Code review: add line comment")
  set_map(bufnr, km.delete_comment, M.delete_comment, "Code review: delete comment")
  set_map(bufnr, km.file_comment, M.add_file_comment, "Code review: add file comment")
  set_map(bufnr, km.summary, M.submit, "Code review: submit (show summary)")
  set_map(bufnr, km.cancel, M.cancel, "Code review: cancel review")
  set_map(bufnr, km.pause, M.pause, "Code review: pause session")
end

-- Apply the file-panel comment-action keymaps to the renderer panel buffer.
function M._set_file_panel_keymaps(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local km = config.values.keymaps
  set_map(bufnr, km.next_file, M.next_file, "Code review: next file")
  set_map(bufnr, km.prev_file, M.prev_file, "Code review: previous file")
  set_map(bufnr, km.toggle_zoom, M.toggle_zoom, "Code review: zoom current side")
  set_map(bufnr, km.file_comment, M.add_file_comment, "Code review: add file comment")
  set_map(bufnr, km.summary, M.submit, "Code review: submit (show summary)")
  set_map(bufnr, km.cancel, M.cancel, "Code review: cancel review")
  set_map(bufnr, km.pause, M.pause, "Code review: pause session")
end

return M
