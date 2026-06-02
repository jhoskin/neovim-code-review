-- Unit + property tests for render/paint.lua.
-- Invoked by tests/unit/run.lua, which passes the harness as the argument.

local H = ...
local describe, it, property = H.describe, H.it, H.property
local eq, ok = H.assert.eq, H.assert.ok

local diff = require("code-review.render.diff")
local paint = require("code-review.render.paint")

-- Count the rows whose given side is a filler (nil lineno).
local function count_nil(model, side_key)
  local n = 0
  for _, row in ipairs(model.rows) do
    if row[side_key] == nil then
      n = n + 1
    end
  end
  return n
end

-- Exact set of 1-based row indices where the given side is a filler.
local function nil_rows(model, side_key)
  local r = {}
  for i, row in ipairs(model.rows) do
    if row[side_key] == nil then
      r[#r + 1] = i
    end
  end
  return r
end

describe("render/paint filler_lines", function()
  it("identical input has no fillers on either side", function()
    local m = diff.compute({ "a", "b" }, { "a", "b" })
    local f = paint.filler_lines(m)
    eq(f.old, {})
    eq(f.new, {})
  end)

  it("pure addition puts a filler on the old side at the add row", function()
    local m = diff.compute({ "a", "c" }, { "a", "b", "c" })
    local f = paint.filler_lines(m)
    -- rows: context, add, context => old filler at row 2; new has none.
    eq(f.old, { 2 })
    eq(f.new, {})
  end)

  it("pure deletion puts a filler on the new side at the delete row", function()
    local m = diff.compute({ "a", "b", "c" }, { "a", "c" })
    local f = paint.filler_lines(m)
    eq(f.old, {})
    eq(f.new, { 2 })
  end)

  it("new file (empty old) is all old fillers", function()
    local m = diff.compute({}, { "a", "b" })
    local f = paint.filler_lines(m)
    eq(f.old, { 1, 2 })
    eq(f.new, {})
  end)
end)

-- ── Property: filler positions match the nil-lineno rows exactly ────────────
property("filler_lines marks exactly the nil-lineno rows on each side", function()
  return { old = H.rand_lines(12), new = H.rand_lines(12) }
end, function(input)
  local m = diff.compute(input.old, input.new)
  local f = paint.filler_lines(m)

  -- Counts match the number of nil-lineno rows per side.
  eq(#f.old, count_nil(m, "old_lineno"), "old filler count == #nil old_lineno rows")
  eq(#f.new, count_nil(m, "new_lineno"), "new filler count == #nil new_lineno rows")

  -- Positions match exactly (and are in order from ipairs).
  eq(f.old, nil_rows(m, "old_lineno"), "old filler positions match nil rows")
  eq(f.new, nil_rows(m, "new_lineno"), "new filler positions match nil rows")

  -- Every filler index is within [1, #rows].
  local nrows = #m.rows
  for _, i in ipairs(f.old) do
    ok(i >= 1 and i <= nrows, "old filler index in [1,#rows]: " .. tostring(i))
  end
  for _, i in ipairs(f.new) do
    ok(i >= 1 and i <= nrows, "new filler index in [1,#rows]: " .. tostring(i))
  end

  -- Filler imbalance equals the real-line imbalance: a side with more real
  -- lines needs fewer fillers. old_nonfiller = #rows - #old_fillers, so
  -- (#old_fillers) - (#new_fillers) == (#new_real) - (#old_real).
  local old_real = #input.old
  local new_real = #input.new
  eq(#f.old - #f.new, new_real - old_real, "filler imbalance mirrors line imbalance")
end)

-- ── API smoke test ─────────────────────────────────────────────────────────
describe("render/paint apply", function()
  it("fills buffers, starts treesitter, and places extmarks in the namespace", function()
    local old_buf = vim.api.nvim_create_buf(false, true)
    local new_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[old_buf].modifiable = false
    vim.bo[new_buf].modifiable = false

    -- Tiny model: one context, one change (with intra), one add.
    local m = diff.compute({ "local x = 1", "return x" }, { "local x = 2", "return x", "print(x)" })

    -- Light view stub: explicit buffer fields + a lang + current path.
    local view = {
      old_buf = old_buf,
      new_buf = new_buf,
      lang = "lua",
      path = "foo.lua",
    }

    -- Empty store (just needs get_all).
    local store = {
      get_all = function()
        return {}
      end,
    }

    paint.apply(view, m, store)

    -- Buffers filled with one line per row, fillers blank.
    local old_text = vim.api.nvim_buf_get_lines(old_buf, 0, -1, false)
    local new_text = vim.api.nvim_buf_get_lines(new_buf, 0, -1, false)
    eq(#old_text, #m.rows, "old buffer has one line per row")
    eq(#new_text, #m.rows, "new buffer has one line per row")

    -- modifiable was restored to false after fill.
    eq(vim.bo[old_buf].modifiable, false, "old buffer modifiable restored")
    eq(vim.bo[new_buf].modifiable, false, "new buffer modifiable restored")

    -- Extmarks exist in our namespace on both buffers (line bg + signs +
    -- intra spans for the change row).
    local ns = vim.api.nvim_create_namespace(paint.NS)
    local old_marks = vim.api.nvim_buf_get_extmarks(old_buf, ns, 0, -1, {})
    local new_marks = vim.api.nvim_buf_get_extmarks(new_buf, ns, 0, -1, {})
    ok(#old_marks >= 1, "old buffer has extmarks in code_review_render ns")
    ok(#new_marks >= 1, "new buffer has extmarks in code_review_render ns")

    -- TST-RND-0003: treesitter must produce a NON-EMPTY parse tree on the
    -- loaded scratch buffer (a mere get_parser success is not enough — an
    -- unloaded buffer yields an empty tree per Neovim #12550).
    local pok, parser = pcall(vim.treesitter.get_parser, new_buf, "lua")
    ok(pok and parser ~= nil, "treesitter parser obtainable for the loaded buffer")
    local trees = parser:parse()
    ok(trees and trees[1] ~= nil, "parser produced a tree")
    local rootnode = trees[1]:root()
    ok(rootnode ~= nil and rootnode:child_count() > 0,
      "treesitter root is non-empty (real highlighting, not an empty tree)")

    -- Real rows carry the model text; filler rows are blank.
    for i, row in ipairs(m.rows) do
      eq(old_text[i], row.old_text or "", "old line " .. i .. " matches model")
      eq(new_text[i], row.new_text or "", "new line " .. i .. " matches model")
    end
    eq(new_text[3], "print(x)", "added line text present on new side")
    eq(old_text[3], "", "added row is blank on the old (filler) side")

    -- REQ-RND-0002: intra-line word highlight lands on the changed token. Row 1
    -- is a change of `1` -> `2` at byte 11; expect a CodeReviewIntra extmark
    -- spanning that byte on both sides.
    local function intra_spans(marks)
      local out = {}
      for _, mk in ipairs(marks) do
        if mk[4] and mk[4].hl_group == "CodeReviewIntra" then
          out[#out + 1] = { row = mk[2], col = mk[3], end_col = mk[4].end_col }
        end
      end
      return out
    end
    local new_intra = intra_spans(vim.api.nvim_buf_get_extmarks(new_buf, ns, 0, -1, { details = true }))
    local old_intra = intra_spans(vim.api.nvim_buf_get_extmarks(old_buf, ns, 0, -1, { details = true }))
    eq(new_intra, { { row = 0, col = 10, end_col = 11 } }, "new intra span on changed byte")
    eq(old_intra, { { row = 0, col = 10, end_col = 11 } }, "old intra span on changed byte")
  end)

  -- REQ-RND-0006: gutter signs sit on the side that holds the line, never on
  -- the opposite side's filler. This pins the wrong-gutter regression where an
  -- `add` painted a "+" on the old filler and a `delete` a "-" on the new
  -- filler.
  it("places change-indicator signs only on the side that holds the line", function()
    local old_buf = vim.api.nvim_create_buf(false, true)
    local new_buf = vim.api.nvim_create_buf(false, true)
    -- One pure delete (row 2) and one pure add (row 4) plus a change.
    local m = diff.compute({ "keep", "drop", "edit me" }, { "keep", "edit you", "added" })
    local view = { old_buf = old_buf, new_buf = new_buf, path = "f" }
    paint.apply(view, m, { get_all = function() return {} end })

    local ns = vim.api.nvim_create_namespace(paint.NS)

    -- Collect, per buffer, the row->sign_text for line-indicator extmarks
    -- (those carry a line_hl_group; intra marks carry hl_group instead).
    local function sign_rows(buf)
      local out = {}
      for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        if mk[4] and mk[4].line_hl_group then
          out[mk[2]] = mk[4].sign_text
        end
      end
      return out
    end
    local old_signs = sign_rows(old_buf)
    local new_signs = sign_rows(new_buf)

    -- Walk the model: a sign must be present on the content side and absent on
    -- the filler side for every non-context row.
    for i, row in ipairs(m.rows) do
      local r = i - 1
      if row.kind == "add" then
        ok(new_signs[r] ~= nil, "add sign on new side row " .. i)
        ok(old_signs[r] == nil, "no add sign on old filler row " .. i)
        eq(new_signs[r], "+ ", "add sign text on new side")
      elseif row.kind == "delete" then
        ok(old_signs[r] ~= nil, "delete sign on old side row " .. i)
        ok(new_signs[r] == nil, "no delete sign on new filler row " .. i)
        eq(old_signs[r], "- ", "delete sign text on old side")
      elseif row.kind == "change" then
        ok(old_signs[r] ~= nil and new_signs[r] ~= nil, "change sign on both sides row " .. i)
        eq(old_signs[r], "~ ", "change sign text old")
        eq(new_signs[r], "~ ", "change sign text new")
      else -- context: no indicator sign on either side
        ok(old_signs[r] == nil and new_signs[r] == nil, "no sign on context row " .. i)
      end
    end
  end)

  it("paints comment markers from the store", function()
    local old_buf = vim.api.nvim_create_buf(false, true)
    local new_buf = vim.api.nvim_create_buf(false, true)

    local m = diff.compute({ "a", "b" }, { "a", "b" })
    local view = { old_buf = old_buf, new_buf = new_buf, path = "foo.lua" }
    local store = {
      get_all = function()
        return {
          {
            path = "foo.lua",
            comment = "file note",
            lines = {
              { side = "new", old_lineno = 2, new_lineno = 2, body = "line note" },
            },
          },
        }
      end,
    }

    paint.apply(view, m, store)

    local ns = vim.api.nvim_create_namespace(paint.NS)
    -- File comment puts a virt_lines extmark above row 1 on the new buffer.
    local marks = vim.api.nvim_buf_get_extmarks(new_buf, ns, 0, -1, { details = true })
    local has_virt_lines = false
    for _, mk in ipairs(marks) do
      if mk[4] and mk[4].virt_lines then
        has_virt_lines = true
      end
    end
    ok(has_virt_lines, "new buffer has a virt_lines comment marker")
  end)

  -- REQ-RND-0009: a line comment must be painted on the buffer for its side,
  -- at the row its lineno maps to, and NOT on the opposite side. The previous
  -- suite only exercised a new-side comment; this pins old-side routing too.
  it("routes line comments to the correct side's buffer", function()
    local old_buf = vim.api.nvim_create_buf(false, true)
    local new_buf = vim.api.nvim_create_buf(false, true)

    -- old has a line ("gone", old_lineno 2) that new lacks → a delete row, so
    -- the old side genuinely holds a commentable line the new side does not.
    local m = diff.compute({ "keep", "gone", "tail" }, { "keep", "tail" })
    local view = { old_buf = old_buf, new_buf = new_buf, path = "foo.lua" }
    local store = {
      get_all = function()
        return {
          {
            path = "foo.lua",
            comment = nil,
            lines = {
              { side = "old", old_lineno = 2, new_lineno = nil, body = "why removed?" },
            },
          },
        }
      end,
    }

    paint.apply(view, m, store)
    local ns = vim.api.nvim_create_namespace(paint.NS)

    local function comment_rows(buf)
      local rows = {}
      for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        if mk[4] and mk[4].virt_lines then
          for _, vl in ipairs(mk[4].virt_lines) do
            for _, chunk in ipairs(vl) do
              if chunk[2] == "CodeReviewComment" then
                rows[#rows + 1] = mk[2]
              end
            end
          end
        end
      end
      return rows
    end

    -- old_lineno 2 is the delete row; in the model that is visual row index 2
    -- (1-based), extmark row 1 (0-based).
    eq(comment_rows(old_buf), { 1 }, "old-side comment lands on old buffer at the delete row")
    eq(comment_rows(new_buf), {}, "old-side comment must NOT appear on the new buffer")
  end)
end)
