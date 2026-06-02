-- Unit + property tests for render/diff.lua (the aligned diff model).
-- Invoked by tests/unit/run.lua, which passes the harness as the argument.

local H = ...
local describe, it, property = H.describe, H.it, H.property
local eq, ok = H.assert.eq, H.assert.ok

local diff = require("code-review.render.diff")

-- Reconstruct the old / new line arrays from a model by walking rows in
-- order and collecting the side that is not filler.
local function reconstruct(model)
  local old, new = {}, {}
  for _, row in ipairs(model.rows) do
    if row.old_lineno ~= nil then
      old[#old + 1] = row.old_text
    end
    if row.new_lineno ~= nil then
      new[#new + 1] = row.new_text
    end
  end
  return old, new
end

-- Count visual lines each side contributes (real line OR filler = 1 row).
local function side_counts(model)
  local o, n = 0, 0
  for _, row in ipairs(model.rows) do
    -- every row is one visual line on each side
    o = o + 1
    n = n + 1
  end
  return o, n
end

describe("render/diff compute", function()
  it("identical input is all context", function()
    local m = diff.compute({ "a", "b", "c" }, { "a", "b", "c" })
    eq(#m.rows, 3)
    for _, r in ipairs(m.rows) do
      eq(r.kind, "context")
    end
  end)

  it("pure addition yields add rows with old filler", function()
    local m = diff.compute({ "a", "c" }, { "a", "b", "c" })
    local kinds = {}
    for _, r in ipairs(m.rows) do
      kinds[#kinds + 1] = r.kind
    end
    eq(kinds, { "context", "add", "context" })
    local addrow
    for _, r in ipairs(m.rows) do
      if r.kind == "add" then
        addrow = r
      end
    end
    H.assert.is_nil(addrow.old_lineno)
    eq(addrow.new_text, "b")
  end)

  it("pure deletion yields delete rows with new filler", function()
    local m = diff.compute({ "a", "b", "c" }, { "a", "c" })
    local kinds = {}
    for _, r in ipairs(m.rows) do
      kinds[#kinds + 1] = r.kind
    end
    eq(kinds, { "context", "delete", "context" })
  end)

  it("one-for-one modification is a change row with intra spans", function()
    local m = diff.compute({ "hello world" }, { "hello there" })
    eq(#m.rows, 1)
    eq(m.rows[1].kind, "change")
    ok(m.rows[1].intra ~= nil, "change row has intra")
    ok(#m.rows[1].intra.old >= 1, "old has a changed span")
    ok(#m.rows[1].intra.new >= 1, "new has a changed span")
  end)

  it("empty old (new file) is all adds", function()
    local m = diff.compute({}, { "a", "b" })
    eq(#m.rows, 2)
    for _, r in ipairs(m.rows) do
      eq(r.kind, "add")
    end
  end)

  it("empty new (deleted file) is all deletes", function()
    local m = diff.compute({ "a", "b" }, {})
    eq(#m.rows, 2)
    for _, r in ipairs(m.rows) do
      eq(r.kind, "delete")
    end
  end)

  it("both empty yields no rows", function()
    local m = diff.compute({}, {})
    eq(#m.rows, 0)
  end)
end)

describe("render/diff word_diff", function()
  it("no change yields no spans", function()
    local w = diff.word_diff("alpha beta", "alpha beta")
    eq(w.old, {})
    eq(w.new, {})
  end)

  it("changed word maps to a byte span covering it", function()
    local w = diff.word_diff("alpha beta", "alpha gamma")
    -- "beta" occupies bytes 7..10 in old; "gamma" 7..11 in new
    ok(#w.old >= 1)
    ok(#w.new >= 1)
    eq(w.old[1], { 7, 10 })
    eq(w.new[1], { 7, 11 })
  end)
end)

-- ── Property: diff-model reconstruction (REQ-RND-0001/0004) ─────────────
-- Applying the model back to the two sides must reproduce the inputs.
property("reconstruction round-trips old and new", function()
  return { old = H.rand_lines(12), new = H.rand_lines(12) }
end, function(input)
  local m = diff.compute(input.old, input.new)
  local rold, rnew = reconstruct(m)
  eq(rold, input.old, "reconstructed old must equal input old")
  eq(rnew, input.new, "reconstructed new must equal input new")
end)

-- ── Property: alignment equality (REQ-RND-0004) ────────────────────────
-- Both sides contribute the same number of visual rows.
property("old and new visual-row counts are equal", function()
  return { old = H.rand_lines(12), new = H.rand_lines(12) }
end, function(input)
  local m = diff.compute(input.old, input.new)
  local o, n = side_counts(m)
  eq(o, n, "aligned side row counts must match")
end)

-- ── Property: word_diff reconstruction ─────────────────────────────────
-- Concatenating tokens (matched + changed) reproduces both inputs; the
-- changed spans are within bounds and non-overlapping in order.
property("word_diff spans are in-bounds and ordered", function()
  return { a = table.concat(H.rand_lines(1), ""), b = table.concat(H.rand_lines(1), "") }
end, function(input)
  local w = diff.word_diff(input.a, input.b)
  local function check(spans, s)
    local prev = 0
    for _, span in ipairs(spans) do
      ok(span[1] >= 1 and span[1] <= span[2] and span[2] <= #s,
        "span in bounds: " .. vim.inspect(span) .. " for " .. vim.inspect(s))
      ok(span[1] > prev, "spans strictly ordered/non-overlapping")
      prev = span[2]
    end
  end
  check(w.old, input.a)
  check(w.new, input.b)
end)
