-- Headless unit-test runner. Invoke with:
--   nvim --headless -l tests/unit/run.lua
-- Discovers tests/unit/**/*_spec.lua, runs them, prints a summary, and
-- exits non-zero if any test failed.

-- Make the plugin and the test tree requirable.
local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":h:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

local H = require("unit.harness")

local function find_specs(dir)
  local specs = {}
  local function scan(d)
    local handle = vim.uv.fs_scandir(d)
    if not handle then
      return
    end
    while true do
      local name, typ = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local full = d .. "/" .. name
      if typ == "directory" then
        scan(full)
      elseif name:match("_spec%.lua$") then
        specs[#specs + 1] = full
      end
    end
  end
  scan(dir)
  table.sort(specs)
  return specs
end

local spec_dir = root .. "/tests/unit"
local specs = find_specs(spec_dir)

-- Optional filter: `nvim --headless -l tests/unit/run.lua <substring>` runs
-- only spec files whose path contains <substring>. Lets parallel builders
-- run just their own spec without picking up siblings' in-progress files.
local filter = arg and arg[1]
if filter and filter ~= "" then
  local kept = {}
  for _, s in ipairs(specs) do
    if s:find(filter, 1, true) then
      kept[#kept + 1] = s
    end
  end
  specs = kept
end

for _, spec in ipairs(specs) do
  local rel = spec:sub(#root + 2)
  print("\n" .. rel)
  local chunk, load_err = loadfile(spec)
  if not chunk then
    H._stats.fail = H._stats.fail + 1
    table.insert(H._stats.failures, rel .. " [load error] " .. tostring(load_err))
    print("  FAIL [load error] " .. tostring(load_err))
  else
    local ok, run_err = pcall(chunk, H)
    if not ok then
      H._stats.fail = H._stats.fail + 1
      table.insert(H._stats.failures, rel .. " [run error] " .. tostring(run_err))
      print("  FAIL [run error] " .. tostring(run_err))
    end
  end
end

print("\n================================================================")
print(string.format("Unit results: %d passed, %d failed", H._stats.pass, H._stats.fail))
if H._stats.fail > 0 then
  print("Failures:")
  for _, f in ipairs(H._stats.failures) do
    print("  - " .. f)
  end
  vim.cmd("cquit 1")
else
  vim.cmd("quitall")
end
