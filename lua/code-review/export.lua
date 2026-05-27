local M = {}

function M.to_markdown(review_data)
  local lines = {}
  local function add(s)
    table.insert(lines, s)
  end

  local range_str = M._format_range(review_data.diff_spec)
  add("# Code Review: " .. range_str)
  add("")
  add("- Base: `" .. (review_data.diff_spec.base or "working tree") .. "`")
  if review_data.diff_spec.head then
    add("- Compare: `" .. review_data.diff_spec.head .. "`")
  end
  add("- Date: " .. M._format_date(review_data.created_at))

  local files_with_comments = #review_data.files
  add("- Files with comments: " .. files_with_comments)
  add("")

  for _, file in ipairs(review_data.files) do
    add("## " .. file.path)
    add("")

    if file.comment then
      add("**File comment:** " .. file.comment)
      add("")
    end

    for _, line in ipairs(file.lines or {}) do
      local lineno = line.new_lineno or line.old_lineno
      add("### Line " .. tostring(lineno) .. " (" .. line.side .. ")")
      add("")

      if line.diff_hunk and line.diff_hunk ~= "" then
        add("```diff")
        add(line.diff_hunk)
        add("```")
        add("")
      end

      add("**Comment:** " .. line.body)
      add("")
      add("---")
      add("")
    end
  end

  if review_data.verdict then
    add("## Verdict")
    add("")
    add(review_data.verdict)
    add("")
  end

  add("## Summary")
  add("")
  local total = 0
  for _, file in ipairs(review_data.files) do
    total = total + #(file.lines or {})
    if file.comment then
      total = total + 1
    end
  end
  add("- Total comments: " .. total)
  add("- Verdict: " .. (review_data.verdict or "None"))

  return table.concat(lines, "\n")
end

function M.to_clipboard(review_data)
  local markdown = M.to_markdown(review_data)
  vim.fn.setreg("+", markdown)
  return markdown
end

function M._format_range(diff_spec)
  if diff_spec.type == "working_tree" then
    return "working tree"
  end
  local base = diff_spec.base or "?"
  local head = diff_spec.head or "?"
  if #base > 12 then
    base = base:sub(1, 12)
  end
  if #head > 12 then
    head = head:sub(1, 12)
  end
  if diff_spec.type == "branch" then
    return base .. "..." .. head
  end
  return base .. ".." .. head
end

function M._format_date(iso_str)
  if not iso_str then
    return "unknown"
  end
  return iso_str:gsub("T", " "):gsub("Z$", " UTC")
end

return M
