local M = {}

function M.to_markdown(review_data)
  local lines = {}
  local function add(s)
    table.insert(lines, s)
  end

  add("# Code Review Comments")
  add("")
  add("A human reviewer left the following comments on a code change. Each")
  add("comment is anchored to either a file or a specific line within a")
  add("file. File paths are relative to the repository root. Line-level")
  add("comments include the line number and the side of the diff:")
  add("")
  add("- **new** — line in the post-change version of the file")
  add("- **old** — line in the pre-change version of the file")
  add("")
  add("Use these comments to understand what the reviewer wants changed,")
  add("clarified, or kept as-is in the next iteration.")
  add("")

  if #review_data.files == 0 then
    add("(The reviewer left no comments.)")
    return table.concat(lines, "\n")
  end

  for _, file in ipairs(review_data.files) do
    add("## `" .. file.path .. "`")
    add("")

    if file.comment then
      for _, body_line in ipairs(M._split_body(file.comment)) do
        add(body_line)
      end
      add("")
    end

    for _, line in ipairs(file.lines or {}) do
      local lineno = line.new_lineno or line.old_lineno
      add("- **Line " .. tostring(lineno) .. " (" .. line.side .. ")**")
      for _, body_line in ipairs(M._split_body(line.body)) do
        add("  " .. body_line)
      end
    end
    add("")
  end

  return table.concat(lines, "\n")
end

function M._split_body(text)
  local out = {}
  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    table.insert(out, line)
  end
  return out
end

function M.to_clipboard(review_data)
  local markdown = M.to_markdown(review_data)
  vim.fn.setreg("+", markdown)
  return markdown
end

return M
