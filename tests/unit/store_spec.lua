-- Unit + property tests for store.lua (the comment store).
-- Invoked by tests/unit/run.lua, which passes the harness as the argument.
--
-- The store keys line comments by {path, side, lineno} where lineno is the
-- old_lineno for side=="old" and the new_lineno for side=="new" (see
-- render/CONTRACT.md "Comment-layer integration"). These tests pin that
-- contract plus the serialization round-trip and the count invariants.

local H = ...
local describe, it, property = H.describe, H.it, H.property
local eq, ok = H.assert.eq, H.assert.ok
local is_nil = H.assert.is_nil

local Store = require("code-review.store")

-- ── Generators ─────────────────────────────────────────────────────────
-- A random comment record. Side picks which lineno is the key; we keep both
-- linenos populated so the round-trip has to preserve them faithfully.
local PATHS = { "a.lua", "b.lua", "src/c.lua", "src/deep/d.txt", "x", "y/z" }
local WORDS = { "alpha", "beta", "gamma", "delta", "fix", "typo", "nit", "wat" }

local function rand_body()
  local parts = {}
  for _ = 1, math.random(1, 5) do
    parts[#parts + 1] = WORDS[math.random(#WORDS)]
  end
  return table.concat(parts, " ")
end

-- Build a set of random line comments with no key collisions, so we can
-- reason about exact counts. Returns an array of {path, old_lineno,
-- new_lineno, side, body} plus the count of distinct keys.
local function rand_comment_set(max)
  local count = math.random(1, max or 12)
  local seen = {}
  local out = {}
  local attempts = 0
  while #out < count and attempts < count * 10 do
    attempts = attempts + 1
    local path = PATHS[math.random(#PATHS)]
    local side = math.random(2) == 1 and "old" or "new"
    local old_lineno = math.random(1, 50)
    local new_lineno = math.random(1, 50)
    local key = path .. "|" .. side .. "|" .. tostring(side == "old" and old_lineno or new_lineno)
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = {
        path = path,
        old_lineno = old_lineno,
        new_lineno = new_lineno,
        side = side,
        body = rand_body(),
      }
    end
  end
  return out
end

local function add_all(store, set)
  for _, c in ipairs(set) do
    store:add_line_comment(c.path, c.old_lineno, c.new_lineno, c.side, c.body)
  end
end

-- The lineno the store uses as the key for a comment record.
local function key_lineno(c)
  return c.side == "old" and c.old_lineno or c.new_lineno
end

-- ── Unit: construction ─────────────────────────────────────────────────
describe("store construction", function()
  it("new store is empty", function()
    local s = Store.new()
    ok(s:is_empty(), "fresh store is empty")
    eq(s:comment_count(), 0)
    eq(s:get_all(), {})
    eq(s:file_paths_with_comments(), {})
  end)
end)

-- ── Unit: add_line_comment ─────────────────────────────────────────────
describe("store add_line_comment", function()
  it("adds a new-side comment and gets it back", function()
    local s = Store.new()
    ok(s:add_line_comment("a.lua", 3, 5, "new", "hello"))
    local c = s:get_line_comment("a.lua", 5, "new")
    ok(c ~= nil, "comment present")
    eq(c.body, "hello")
    eq(c.side, "new")
    eq(c.old_lineno, 3)
    eq(c.new_lineno, 5)
  end)

  it("adds an old-side comment keyed by old_lineno", function()
    local s = Store.new()
    ok(s:add_line_comment("a.lua", 7, 9, "old", "world"))
    -- old-side keys on old_lineno (7), not new_lineno (9).
    local c = s:get_line_comment("a.lua", 7, "old")
    ok(c ~= nil, "old comment found by old_lineno")
    eq(c.body, "world")
    is_nil(s:get_line_comment("a.lua", 9, "old"), "not found by new_lineno")
  end)

  it("trims the body and rejects whitespace-only", function()
    local s = Store.new()
    ok(s:add_line_comment("a.lua", 1, 1, "new", "  padded  "))
    eq(s:get_line_comment("a.lua", 1, "new").body, "padded")
    ok(not s:add_line_comment("a.lua", 2, 2, "new", "   "), "blank rejected")
    ok(not s:add_line_comment("a.lua", 2, 2, "new", nil), "nil rejected")
    eq(s:comment_count(), 1)
  end)

  it("re-adding the same key overwrites the body", function()
    local s = Store.new()
    s:add_line_comment("a.lua", 1, 4, "new", "first")
    s:add_line_comment("a.lua", 1, 4, "new", "second")
    eq(s:get_line_comment("a.lua", 4, "new").body, "second")
    eq(s:comment_count(), 1)
  end)
end)

-- ── Unit: add_file_comment ─────────────────────────────────────────────
describe("store add_file_comment", function()
  it("adds and reads a file comment", function()
    local s = Store.new()
    ok(s:add_file_comment("a.lua", "file note"))
    eq(s:get_comments_for_file("a.lua").comment, "file note")
    eq(s:comment_count(), 1)
  end)

  it("trims and rejects blank file comments", function()
    local s = Store.new()
    ok(s:add_file_comment("a.lua", "  note "))
    eq(s:get_comments_for_file("a.lua").comment, "note")
    ok(not s:add_file_comment("b.lua", "   "), "blank rejected")
    ok(not s:add_file_comment("b.lua", nil), "nil rejected")
  end)
end)

-- ── Unit: delete ───────────────────────────────────────────────────────
describe("store delete_line_comment", function()
  it("deletes an existing comment", function()
    local s = Store.new()
    s:add_line_comment("a.lua", 1, 2, "new", "x")
    ok(s:delete_line_comment("a.lua", 2, "new"))
    is_nil(s:get_line_comment("a.lua", 2, "new"))
    ok(s:is_empty(), "store empty after deleting the only comment")
  end)

  it("deleting a missing comment is a no-op (false)", function()
    local s = Store.new()
    ok(not s:delete_line_comment("nope.lua", 1, "new"), "no file")
    s:add_line_comment("a.lua", 1, 2, "new", "x")
    ok(not s:delete_line_comment("a.lua", 99, "new"), "no such line")
    ok(not s:delete_line_comment("a.lua", 2, "old"), "wrong side")
    eq(s:comment_count(), 1, "no-op did not change the store")
  end)

  it("deleting twice is safe (idempotent)", function()
    local s = Store.new()
    s:add_line_comment("a.lua", 1, 2, "new", "x")
    ok(s:delete_line_comment("a.lua", 2, "new"), "first delete")
    ok(not s:delete_line_comment("a.lua", 2, "new"), "second delete is no-op")
  end)

  it("deleting one of two comments leaves the file present", function()
    local s = Store.new()
    s:add_line_comment("a.lua", 1, 2, "new", "x")
    s:add_line_comment("a.lua", 3, 4, "new", "y")
    s:delete_line_comment("a.lua", 2, "new")
    ok(s:get_comments_for_file("a.lua") ~= nil, "file still present")
    eq(s:comment_count(), 1)
  end)
end)

describe("store delete_file_comment", function()
  it("deletes a file comment", function()
    local s = Store.new()
    s:add_file_comment("a.lua", "note")
    ok(s:delete_file_comment("a.lua"))
    ok(s:is_empty(), "empty after delete")
  end)

  it("missing file returns false", function()
    local s = Store.new()
    ok(not s:delete_file_comment("nope.lua"))
  end)

  it("file with line comments survives file-comment deletion", function()
    local s = Store.new()
    s:add_file_comment("a.lua", "note")
    s:add_line_comment("a.lua", 1, 2, "new", "x")
    s:delete_file_comment("a.lua")
    is_nil(s:get_comments_for_file("a.lua").comment, "file comment gone")
    ok(s:get_line_comment("a.lua", 2, "new") ~= nil, "line comment kept")
  end)
end)

-- ── Unit: side independence (CONTRACT key separation) ──────────────────
describe("store side keys do not collide", function()
  it("old:5 and new:5 on the same file are distinct", function()
    local s = Store.new()
    s:add_line_comment("a.lua", 5, 8, "old", "on old 5")
    s:add_line_comment("a.lua", 2, 5, "new", "on new 5")
    eq(s:comment_count(), 2, "two distinct comments")
    eq(s:get_line_comment("a.lua", 5, "old").body, "on old 5")
    eq(s:get_line_comment("a.lua", 5, "new").body, "on new 5")
    -- Deleting one side must not touch the other.
    s:delete_line_comment("a.lua", 5, "old")
    is_nil(s:get_line_comment("a.lua", 5, "old"))
    eq(s:get_line_comment("a.lua", 5, "new").body, "on new 5")
  end)
end)

-- ── Unit: get_all / get_all_line_comments / paths ──────────────────────
describe("store aggregation", function()
  it("get_all sorts by path and includes file + line comments", function()
    local s = Store.new()
    s:add_line_comment("b.lua", 1, 1, "new", "b1")
    s:add_file_comment("a.lua", "afile")
    s:add_line_comment("a.lua", 2, 2, "new", "a2")
    local all = s:get_all()
    eq(#all, 2)
    eq(all[1].path, "a.lua")
    eq(all[1].comment, "afile")
    eq(all[2].path, "b.lua")
  end)

  it("get_all_line_comments sorts by line and returns {} for unknown file", function()
    local s = Store.new()
    eq(s:get_all_line_comments("nope.lua"), {})
    s:add_line_comment("a.lua", 1, 9, "new", "nine")
    s:add_line_comment("a.lua", 1, 3, "new", "three")
    local lines = s:get_all_line_comments("a.lua")
    eq(#lines, 2)
    eq(lines[1].new_lineno, 3, "sorted ascending")
    eq(lines[2].new_lineno, 9)
  end)

  it("file_paths_with_comments returns sorted unique paths", function()
    local s = Store.new()
    s:add_line_comment("z.lua", 1, 1, "new", "z")
    s:add_line_comment("a.lua", 1, 1, "new", "a")
    s:add_line_comment("a.lua", 2, 2, "new", "a2")
    eq(s:file_paths_with_comments(), { "a.lua", "z.lua" })
  end)
end)

-- ── Unit: set_diff_hunk ────────────────────────────────────────────────
describe("store set_diff_hunk", function()
  it("attaches a hunk to an existing comment", function()
    local s = Store.new()
    s:add_line_comment("a.lua", 1, 2, "new", "x")
    s:set_diff_hunk("a.lua", 2, "new", "@@ -1 +2 @@")
    eq(s:get_line_comment("a.lua", 2, "new").diff_hunk, "@@ -1 +2 @@")
  end)

  it("is a no-op for a missing comment", function()
    local s = Store.new()
    s:set_diff_hunk("a.lua", 2, "new", "@@") -- must not error or create
    ok(s:is_empty())
  end)
end)

-- ── Unit: serialization edge cases the properties don't reach ──────────
-- The round-trip property always attaches a hunk to every comment and always
-- has at least one comment, so these two edges are otherwise untested.
describe("store to_table/from_table edges", function()
  it("empty store round-trips to an empty file list", function()
    local s = Store.new()
    eq(s:to_table(), { files = {} })
    local s2 = Store.new()
    s2:from_table(s:to_table())
    ok(s2:is_empty(), "empty after rehydrating an empty table")
    eq(s2:to_table(), { files = {} })
  end)

  it("a hunkless comment serializes as \"\" and rehydrates as nil", function()
    local s = Store.new()
    s:add_line_comment("a.lua", 3, 5, "new", "no hunk")
    local t = s:to_table()
    eq(t.files[1].lines[1].diff_hunk, "", "absent hunk serializes as empty string")
    local s2 = Store.new()
    s2:from_table(t)
    -- The store representation uses nil for "no hunk"; from_table must not
    -- store the empty-string sentinel as a real hunk.
    is_nil(s2:get_line_comment("a.lua", 5, "new").diff_hunk, "no hunk after round-trip")
    eq(s2:to_table(), t, "second to_table matches the first")
  end)

  it("from_table tolerates missing files/lines keys", function()
    local s = Store.new()
    s:from_table({}) -- no files key
    ok(s:is_empty())
    s:from_table({ files = { { path = "z.lua" } } }) -- file with no lines key
    ok(s:is_empty(), "a file entry with no lines and no comment adds nothing")
  end)
end)

-- ── Property 1: add then get round-trips body/side/lineno ──────────────
property("add then get round-trips body, side and lineno", function()
  return rand_comment_set(10)
end, function(set)
  local s = Store.new()
  add_all(s, set)
  for _, c in ipairs(set) do
    local got = s:get_line_comment(c.path, key_lineno(c), c.side)
    ok(got ~= nil, "comment retrievable by its key")
    eq(got.body, c.body, "body preserved")
    eq(got.side, c.side, "side preserved")
    eq(got.old_lineno, c.old_lineno, "old_lineno preserved")
    eq(got.new_lineno, c.new_lineno, "new_lineno preserved")
  end
end)

-- ── Property 2: delete is idempotent ───────────────────────────────────
property("delete is idempotent and safe for missing comments", function()
  return rand_comment_set(10)
end, function(set)
  local s = Store.new()
  add_all(s, set)
  for _, c in ipairs(set) do
    local ln = key_lineno(c)
    ok(s:delete_line_comment(c.path, ln, c.side), "first delete succeeds")
    ok(not s:delete_line_comment(c.path, ln, c.side), "second delete is no-op")
    is_nil(s:get_line_comment(c.path, ln, c.side), "gone after delete")
  end
  ok(s:is_empty(), "store empty after deleting all")
  -- Deleting from a now-empty store is still safe.
  for _, c in ipairs(set) do
    ok(not s:delete_line_comment(c.path, key_lineno(c), c.side), "no-op on empty")
  end
end)

-- ── Property 3: to_table -> from_table -> to_table round-trips ─────────
property("to_table/from_table is a faithful round-trip", function()
  local set = rand_comment_set(10)
  -- Mix in some file comments and some diff hunks for fuller coverage.
  return set
end, function(set)
  local s = Store.new()
  add_all(s, set)
  -- Attach diff hunks and file comments deterministically from the set.
  local file_seen = {}
  for i, c in ipairs(set) do
    -- Leave roughly half the comments hunkless so the round-trip exercises
    -- the nil-hunk path (table "" <-> store nil) as well as the hunk path.
    if math.random(2) == 1 then
      s:set_diff_hunk(c.path, key_lineno(c), c.side, "@@ hunk " .. i .. " @@")
    end
    if not file_seen[c.path] then
      file_seen[c.path] = true
      s:add_file_comment(c.path, "filenote " .. c.path)
    end
  end

  local t1 = s:to_table()
  local s2 = Store.new()
  s2:from_table(t1)
  local t2 = s2:to_table()
  eq(t2, t1, "to_table is stable across a from_table round-trip")

  -- And the rehydrated store answers gets identically.
  for _, c in ipairs(set) do
    local a = s:get_line_comment(c.path, key_lineno(c), c.side)
    local b = s2:get_line_comment(c.path, key_lineno(c), c.side)
    eq(b.body, a.body, "body survives round-trip")
    eq(b.diff_hunk, a.diff_hunk, "diff_hunk survives round-trip")
  end
end)

-- ── Property 4: line-number keys never collide across sides ────────────
property("old and new comments on the same lineno stay distinct", function()
  local n = math.random(1, 12)
  local path = PATHS[math.random(#PATHS)]
  local linenos = {}
  local seen = {}
  while #linenos < n do
    local ln = math.random(1, 30)
    if not seen[ln] then
      seen[ln] = true
      linenos[#linenos + 1] = ln
    end
  end
  return { path = path, linenos = linenos }
end, function(input)
  local s = Store.new()
  for _, ln in ipairs(input.linenos) do
    -- Same numeric lineno on both sides; keying on old_lineno vs new_lineno.
    s:add_line_comment(input.path, ln, ln, "old", "old@" .. ln)
    s:add_line_comment(input.path, ln, ln, "new", "new@" .. ln)
  end
  -- Two distinct comments per lineno.
  eq(s:comment_count(), #input.linenos * 2)
  for _, ln in ipairs(input.linenos) do
    eq(s:get_line_comment(input.path, ln, "old").body, "old@" .. ln)
    eq(s:get_line_comment(input.path, ln, "new").body, "new@" .. ln)
  end
end)

-- ── Property 5: comment_count equals distinct added comments ───────────
property("comment_count equals distinct line + file comments", function()
  local set = rand_comment_set(12)
  local files = {}
  for _, c in ipairs(set) do
    if math.random(2) == 1 then
      files[c.path] = true
    end
  end
  return { set = set, files = files }
end, function(input)
  local s = Store.new()
  add_all(s, input.set)
  local file_count = 0
  for path in pairs(input.files) do
    s:add_file_comment(path, "note " .. path)
    file_count = file_count + 1
  end
  -- rand_comment_set guarantees distinct keys, so #set line comments + the
  -- file comments is the exact total.
  eq(s:comment_count(), #input.set + file_count)
  ok(not s:is_empty(), "non-empty when comments exist")
end)
