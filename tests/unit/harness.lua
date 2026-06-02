-- Minimal busted-style test harness that runs under `nvim --headless -l`.
-- Zero external dependencies; sees the real vim.* API. Provides
-- describe/it/before_each plus assertions and a property-test helper.
--
-- A spec file requires this, calls describe/it, and returns nothing; the
-- runner (run.lua) aggregates results across spec files.

local H = {}

H._stats = { pass = 0, fail = 0, failures = {} }
H._stack = {}

function H.describe(name, fn)
  table.insert(H._stack, name)
  local ok, err = pcall(fn)
  if not ok then
    H._stats.fail = H._stats.fail + 1
    table.insert(H._stats.failures, table.concat(H._stack, " › ") .. " [describe threw] " .. tostring(err))
  end
  table.remove(H._stack)
end

function H.it(name, fn)
  table.insert(H._stack, name)
  local ok, err = pcall(fn)
  local label = table.concat(H._stack, " › ")
  if ok then
    H._stats.pass = H._stats.pass + 1
    print("  ok   " .. label)
  else
    H._stats.fail = H._stats.fail + 1
    table.insert(H._stats.failures, label .. "\n      " .. tostring(err))
    print("  FAIL " .. label .. "\n      " .. tostring(err))
  end
  table.remove(H._stack)
end

local function fail(msg)
  error(msg, 2)
end

H.assert = {}

function H.assert.eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    fail((msg or "values not equal")
      .. "\n      expected: " .. vim.inspect(b)
      .. "\n      got:      " .. vim.inspect(a))
  end
end

function H.assert.ok(v, msg)
  if not v then
    fail(msg or "expected truthy, got " .. tostring(v))
  end
end

function H.assert.is_nil(v, msg)
  if v ~= nil then
    fail((msg or "expected nil") .. ", got " .. vim.inspect(v))
  end
end

function H.assert.truthy(v, msg)
  H.assert.ok(v, msg)
end

-- Property-test helper: run `gen` N times to produce an input, pass it to
-- `prop` which must not error (use H.assert inside). Seeded for repeatability;
-- on failure the seed + iteration are reported so it can be reproduced.
function H.property(name, gen, prop, n)
  n = n or 200
  H.it(name .. " (property, " .. n .. " cases)", function()
    for i = 1, n do
      math.randomseed(0xC0DE + i)
      local input = gen(i)
      local ok, err = pcall(prop, input)
      if not ok then
        fail("property failed on case " .. i
          .. "\n      input: " .. vim.inspect(input)
          .. "\n      " .. tostring(err))
      end
    end
  end)
end

-- Random helpers for generators.
function H.rand_lines(max_lines, alphabet)
  alphabet = alphabet or { "alpha", "beta", "gamma", "delta", "epsilon", "x", "y", "z" }
  local count = math.random(0, max_lines)
  local lines = {}
  for i = 1, count do
    local parts = {}
    for _ = 1, math.random(1, 4) do
      parts[#parts + 1] = alphabet[math.random(#alphabet)]
    end
    lines[i] = table.concat(parts, " ")
  end
  return lines
end

return H
