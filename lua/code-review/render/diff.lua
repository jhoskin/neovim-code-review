-- render/diff.lua — pure diff model for the side-by-side renderer.
--
-- compute(old_lines, new_lines) returns an aligned row model where every
-- row maps to exactly one visual line on each side (real text or filler).
-- This is the locked data contract the renderer (paint/view) consumes and
-- the comment layer maps cursor positions against. See render/CONTRACT.md.
--
-- Pure data, no Neovim UI calls. Depends only on vim.diff (C xdiff builtin)
-- and string ops, so it is fully unit- and property-testable headless.

local M = {}

-- A row record:
--   {
--     kind       = "context" | "add" | "delete" | "change",
--     old_lineno = integer | nil,   -- 1-based line in old_lines, nil = filler
--     new_lineno = integer | nil,   -- 1-based line in new_lines, nil = filler
--     old_text   = string | nil,    -- nil when old side is filler
--     new_text   = string | nil,    -- nil when new side is filler
--     intra      = nil | {          -- only on kind == "change"
--       old = { {first, last}, ... },  -- byte ranges (1-based, inclusive) changed in old_text
--       new = { {first, last}, ... },  -- byte ranges changed in new_text
--     },
--   }

-- vim.diff opts locked by REQ-RND-0001.
local DIFF_OPTS = {
  result_type = "indices",
  algorithm = "histogram",
  linematch = 60,
  indent_heuristic = true,
}

-- Tokenize a line into words + separators for word-level diffing. Each token
-- carries its byte span so we can map matched/changed tokens back to columns.
-- Tokens partition the whole string (concatenation reproduces it exactly).
local function tokenize(s)
  local toks = {}
  local i = 1
  local n = #s
  while i <= n do
    local first = i
    local c = s:sub(i, i)
    local is_word = c:match("[%w_]") ~= nil
    if is_word then
      while i <= n and s:sub(i, i):match("[%w_]") do
        i = i + 1
      end
    else
      -- a run of identical non-word chars groups together; otherwise single
      while i <= n and not s:sub(i, i):match("[%w_]") and s:sub(i, i) == c do
        i = i + 1
      end
    end
    toks[#toks + 1] = { text = s:sub(first, i - 1), first = first, last = i - 1 }
  end
  return toks
end

-- Longest common subsequence over token text (classic DP). Returns a boolean
-- match array for a-tokens and b-tokens. O(len_a * len_b) — fine for a line.
local function lcs_match(a, b)
  local la, lb = #a, #b
  local dp = {}
  for x = 0, la do
    dp[x] = {}
    for y = 0, lb do
      dp[x][y] = 0
    end
  end
  for x = 1, la do
    for y = 1, lb do
      if a[x].text == b[y].text then
        dp[x][y] = dp[x - 1][y - 1] + 1
      else
        dp[x][y] = math.max(dp[x - 1][y], dp[x][y - 1])
      end
    end
  end
  local a_matched, b_matched = {}, {}
  for x = 1, la do
    a_matched[x] = false
  end
  for y = 1, lb do
    b_matched[y] = false
  end
  local x, y = la, lb
  while x > 0 and y > 0 do
    if a[x].text == b[y].text then
      a_matched[x] = true
      b_matched[y] = true
      x = x - 1
      y = y - 1
    elseif dp[x - 1][y] >= dp[x][y - 1] then
      x = x - 1
    else
      y = y - 1
    end
  end
  return a_matched, b_matched
end

-- Merge adjacent unmatched tokens into byte-range spans.
local function spans_from_unmatched(toks, matched)
  local spans = {}
  local cur = nil
  for idx, tok in ipairs(toks) do
    if not matched[idx] then
      if cur and cur.last == tok.first - 1 then
        cur.last = tok.last
      else
        cur = { tok.first, tok.last }
        spans[#spans + 1] = cur
      end
    else
      cur = nil
    end
  end
  return spans
end

-- Word-level intra-line diff between two strings. Returns { old = spans,
-- new = spans } of changed byte ranges.
function M.word_diff(old_text, new_text)
  local a = tokenize(old_text)
  local b = tokenize(new_text)
  local am, bm = lcs_match(a, b)
  return {
    old = spans_from_unmatched(a, am),
    new = spans_from_unmatched(b, bm),
  }
end

-- Build the aligned row model from two line arrays.
function M.compute(old_lines, new_lines)
  local rows = {}

  local function emit_context(o, n)
    rows[#rows + 1] = {
      kind = "context",
      old_lineno = o,
      new_lineno = n,
      old_text = old_lines[o],
      new_text = new_lines[n],
    }
  end

  local function emit_change(o, n)
    rows[#rows + 1] = {
      kind = "change",
      old_lineno = o,
      new_lineno = n,
      old_text = old_lines[o],
      new_text = new_lines[n],
      intra = M.word_diff(old_lines[o], new_lines[n]),
    }
  end

  local function emit_delete(o)
    rows[#rows + 1] = {
      kind = "delete",
      old_lineno = o,
      new_lineno = nil,
      old_text = old_lines[o],
      new_text = nil,
    }
  end

  local function emit_add(n)
    rows[#rows + 1] = {
      kind = "add",
      old_lineno = nil,
      new_lineno = n,
      old_text = nil,
      new_text = new_lines[n],
    }
  end

  -- Join into newline-terminated text. Empty array must be "" (zero lines),
  -- NOT "\n" (which vim.diff reads as one empty line and corrupts the line
  -- accounting). Caught by the reconstruction property test.
  local function join(lines)
    if #lines == 0 then
      return ""
    end
    return table.concat(lines, "\n") .. "\n"
  end
  local hunks = vim.diff(join(old_lines), join(new_lines), DIFF_OPTS)

  -- hunks: list of { start_a, count_a, start_b, count_b } (1-based; when a
  -- count is 0, start is the line AFTER which the change applies).
  local oi, ni = 1, 1 -- next unprocessed old / new line (1-based)
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    -- Context before this hunk: old lines [oi .. sa-1] pair with new
    -- lines [ni .. sb-1] one-to-one (equal length by construction).
    local ctx_old_start = oi
    local pre = (ca == 0 and sa + 1 or sa) - ctx_old_start
    for k = 0, pre - 1 do
      emit_context(oi + k, ni + k)
    end
    oi = oi + pre
    ni = ni + pre

    -- The changed block: ca old lines, cb new lines.
    local paired = math.min(ca, cb)
    for k = 0, paired - 1 do
      emit_change(oi + k, ni + k)
    end
    -- surplus deletes
    for k = paired, ca - 1 do
      emit_delete(oi + k)
    end
    -- surplus adds
    for k = paired, cb - 1 do
      emit_add(ni + k)
    end
    oi = oi + ca
    ni = ni + cb
  end

  -- Trailing context after the last hunk.
  while oi <= #old_lines and ni <= #new_lines do
    emit_context(oi, ni)
    oi = oi + 1
    ni = ni + 1
  end

  return { rows = rows }
end

return M
