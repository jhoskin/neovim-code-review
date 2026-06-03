-- Spec-traceability gate. Invoke with:
--   nvim --headless -l tests/traceability.lua
--
-- Parses the verification matrix in docs/spec.md and cross-checks it against
-- the test tree. Asserts:
--   1. Every REQ defined in the spec has a row in the verification matrix.
--   2. Every TST id used in the spec body has a matrix row (no dangling ids).
--   3. Every "Auto" TST is referenced (by id) in at least one test artifact
--      under tests/ -- the machine-checkable coverage link.
--   4. No test references a TST id that is not in the matrix (no orphans).
-- "Manual" TSTs are reported but not required to have an artifact.
-- Exits non-zero if any assertion fails.
--
-- Caveat: this is a REFERENCE check, not a behavior check. It verifies a test
-- file names the TST id; it cannot verify the test actually exercises the
-- requirement. Treat a green gate as "every requirement has a claimed test",
-- not "every requirement is proven". The unit/e2e assertions are the proof.

local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":h:h")

local function read_file(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  return content
end

-- ── Parse the verification matrix ──────────────────────────────────────────
local spec = assert(read_file(root .. "/docs/spec.md"), "cannot read docs/spec.md")

local matrix = {} -- { {req=, tst=, method=}, ... } in row order
local tst_method = {} -- tst -> "Auto"|"Manual"
local req_has_row = {} -- req -> true
for line in spec:gmatch("[^\n]+") do
  -- | REQ-XXX-NNNN | TST-XXX-NNNN | Auto/Manual | ... |
  local req, tst, method =
    line:match("^|%s*(REQ%-%u+%-%d+)%s*|%s*(TST%-%u+%-%d+)%s*|%s*(%a+)%s*|")
  if req and tst and (method == "Auto" or method == "Manual") then
    matrix[#matrix + 1] = { req = req, tst = tst, method = method }
    tst_method[tst] = method
    req_has_row[req] = true
  end
end

-- Every REQ id and TST id that appears anywhere in the spec body.
local function unique_ids(text, pat)
  local seen, out = {}, {}
  for id in text:gmatch(pat) do
    if not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end
local all_reqs = unique_ids(spec, "REQ%-%u+%-%d+")
local all_tsts = unique_ids(spec, "TST%-%u+%-%d+")

-- ── Collect TST references from the test tree ──────────────────────────────
local referenced = {} -- tst -> true
local function scan(dir)
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return
  end
  while true do
    local name, typ = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local full = dir .. "/" .. name
    if typ == "directory" then
      scan(full)
    elseif typ == "file" and full ~= root .. "/tests/traceability.lua" then
      local content = read_file(full)
      if content then
        for tst in content:gmatch("TST%-%u+%-%d+") do
          referenced[tst] = true
        end
      end
    end
  end
end
scan(root .. "/tests")

-- ── Compute the report ─────────────────────────────────────────────────────
local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

local reqs_no_row, tst_no_row, auto_uncovered, manual, orphan_refs = {}, {}, {}, {}, {}
for _, req in ipairs(all_reqs) do
  if not req_has_row[req] then
    reqs_no_row[#reqs_no_row + 1] = req
  end
end
for _, tst in ipairs(all_tsts) do
  if not tst_method[tst] then
    tst_no_row[#tst_no_row + 1] = tst
  end
end
for _, tst in ipairs(sorted_keys(tst_method)) do
  if tst_method[tst] == "Auto" then
    if not referenced[tst] then
      auto_uncovered[#auto_uncovered + 1] = tst
    end
  else
    manual[#manual + 1] = tst
  end
end
for _, tst in ipairs(sorted_keys(referenced)) do
  if not tst_method[tst] then
    orphan_refs[#orphan_refs + 1] = tst
  end
end

-- ── Print + gate ───────────────────────────────────────────────────────────
local auto_total = 0
for _, m in pairs(tst_method) do
  if m == "Auto" then
    auto_total = auto_total + 1
  end
end

print("Spec traceability")
print(string.format("  matrix rows:    %d", #matrix))
print(string.format("  requirements:   %d", #all_reqs))
print(string.format("  test ids:       %d (%d Auto, %d Manual)", #all_tsts, auto_total, #manual))
print(string.format("  Auto covered:   %d/%d", auto_total - #auto_uncovered, auto_total))

local function report(label, list)
  if #list > 0 then
    print("\n" .. label .. " (" .. #list .. "):")
    for _, id in ipairs(list) do
      print("  - " .. id)
    end
  end
end

report("REQ with no matrix row", reqs_no_row)
report("TST id in spec but not in matrix", tst_no_row)
report("Auto TST with no test artifact", auto_uncovered)
report("Test references a non-matrix TST", orphan_refs)

local failed = #reqs_no_row + #tst_no_row + #auto_uncovered + #orphan_refs
print("\n================================================================")
if failed > 0 then
  print(string.format("Traceability FAILED: %d gap(s)", failed))
  vim.cmd("cquit 1")
else
  print("Traceability OK: every requirement traces to a test")
  vim.cmd("quitall")
end
