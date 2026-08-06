--[[
  Levititas v3.1 — Integration Tests
  test/integration/test_integration.lua

  Full pipeline tests: source → parse → compile → serialize → run
  Every test script must produce identical output to standard Lua execution.
  Run: lua test/integration/test_integration.lua
]]

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local Parser   = require("parser.parser")
local Compiler = require("compiler.compiler")
local Opcodes  = require("vm.opcodes")
local ProtoVal = require("validation.proto_validator")
local Spec     = require("spec")

local passed, failed, total = 0, 0, 0
local SEED = 31337  -- fixed seed for reproducible integration tests

local function log(msg) io.write(msg .. "\n") end

local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    log(string.format("  [PASS] %s", name))
  else
    failed = failed + 1
    log(string.format("  [FAIL] %s\n         %s", name, tostring(err)))
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

-- Capture stdout from a function
local function capture(fn)
  local out = {}
  local origPrint = print
  print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do
      parts[#parts+1] = tostring(select(i, ...))
    end
    out[#out+1] = table.concat(parts, "\t")
  end
  local ok, err = pcall(fn)
  print = origPrint
  return ok, table.concat(out, "\n"), err
end

-- Run source through the full pipeline and return output
local function runObfuscated(source)
  -- Parse
  local ast, parseErr = Parser.parse(source)
  if not ast then return nil, "parse: " .. tostring(parseErr) end

  -- Compile
  local nm, rv = Opcodes.generateMap(SEED)
  local proto, compErr = Compiler.compile(ast, nm, SEED)
  if not proto then return nil, "compile: " .. tostring(compErr) end

  -- Validate
  local valOk, valErr = ProtoVal.validate(proto, rv)
  if not valOk then return nil, "validate: " .. tostring(valErr) end

  -- Execute via VM core directly
  local VMCore = require("vm.core")
  local vm = VMCore.new(nm, SEED, { maxInstructions = 1000000 })
  local results, runErr = vm:run(proto)
  if not results then return nil, "run: " .. tostring(runErr) end

  return results, nil
end

-- Compare output of plain Lua execution vs obfuscated execution
local function compareOutput(source)
  -- Run plain
  local plainOk, plainOut, plainErr = capture(function()
    local fn = assert(load(source, "@test", "t", _G))
    fn()
  end)

  -- Run obfuscated
  local obfOut = {}
  local obfOk = false
  local obfErr = nil

  local origPrint = print
  print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts+1] = tostring(select(i, ...)) end
    obfOut[#obfOut+1] = table.concat(parts, "\t")
  end
  local results, runErr = runObfuscated(source)
  print = origPrint

  if runErr then
    return false, "obfuscated run failed: " .. runErr
  end

  local obfOutStr = table.concat(obfOut, "\n")

  if plainOut ~= obfOutStr then
    return false, string.format(
      "output mismatch:\n  plain:  %q\n  obfusc: %q",
      plainOut, obfOutStr)
  end

  return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  BASIC LANGUAGE FEATURES
-- ─────────────────────────────────────────────────────────────────────────────

log("\n── Basic Language Features ─────────────────────────────────")

test("INT-001: arithmetic operators", function()
  local ok, err = compareOutput([[
local a = 10
local b = 3
print(a + b)
print(a - b)
print(a * b)
print(a // b)
print(a % b)
]])
  assert(ok, err)
end)

test("INT-002: string concatenation", function()
  local ok, err = compareOutput([[
local s = "hello" .. " " .. "world"
print(s)
print("count: " .. tostring(42))
]])
  assert(ok, err)
end)

test("INT-003: boolean logic", function()
  local ok, err = compareOutput([[
print(true and "yes" or "no")
print(false and "yes" or "no")
print(not true)
print(not false)
print(1 == 1)
print(1 ~= 2)
]])
  assert(ok, err)
end)

test("INT-004: local variables and scope", function()
  local ok, err = compareOutput([[
local x = 10
do
  local x = 20
  print(x)
end
print(x)
]])
  assert(ok, err)
end)

test("INT-005: multiple assignment", function()
  local ok, err = compareOutput([[
local a, b, c = 1, 2, 3
print(a, b, c)
a, b = b, a
print(a, b)
]])
  assert(ok, err)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- §2  CONTROL FLOW
-- ─────────────────────────────────────────────────────────────────────────────

log("\n── Control Flow ────────────────────────────────────────────")

test("INT-010: if/elseif/else", function()
  local ok, err = compareOutput([[
local function grade(n)
  if n >= 90 then return "A"
  elseif n >= 80 then return "B"
  elseif n >= 70 then return "C"
  else return "F"
  end
end
print(grade(95))
print(grade(85))
print(grade(75))
print(grade(50))
]])
  assert(ok, err)
end)

test("INT-011: while loop", function()
  local ok, err = compareOutput([[
local i = 1
local sum = 0
while i <= 10 do
  sum = sum + i
  i = i + 1
end
print(sum)
]])
  assert(ok, err)
end)

test("INT-012: repeat/until", function()
  local ok, err = compareOutput([[
local i = 0
repeat
  i = i + 1
until i >= 5
print(i)
]])
  assert(ok, err)
end)

test("INT-013: numeric for basic", function()
  local ok, err = compareOutput([[
local sum = 0
for i = 1, 5 do
  sum = sum + i
end
print(sum)
]])
  assert(ok, err)
end)

test("INT-014: numeric for with step", function()
  local ok, err = compareOutput([[
local result = {}
for i = 10, 1, -2 do
  result[#result+1] = i
end
print(table.concat(result, ","))
]])
  assert(ok, err)
end)

test("INT-015: break in loop", function()
  local ok, err = compareOutput([[
local found = nil
for i = 1, 100 do
  if i * i > 50 then
    found = i
    break
  end
end
print(found)
]])
  assert(ok, err)
end)

test("INT-016: nested loops", function()
  local ok, err = compareOutput([[
local count = 0
for i = 1, 3 do
  for j = 1, 3 do
    count = count + 1
  end
end
print(count)
]])
  assert(ok, err)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- §3  FUNCTIONS
-- ─────────────────────────────────────────────────────────────────────────────

log("\n── Functions ───────────────────────────────────────────────")

test("INT-020: basic function call", function()
  local ok, err = compareOutput([[
local function add(a, b) return a + b end
print(add(3, 4))
]])
  assert(ok, err)
end)

test("INT-021: multiple return values", function()
  local ok, err = compareOutput([[
local function minmax(a, b)
  if a < b then return a, b
  else return b, a end
end
local lo, hi = minmax(7, 3)
print(lo, hi)
]])
  assert(ok, err)
end)

test("INT-022: recursive function", function()
  local ok, err = compareOutput([[
local function fib(n)
  if n <= 1 then return n end
  return fib(n-1) + fib(n-2)
end
print(fib(10))
]])
  assert(ok, err)
end)

test("INT-023: closures", function()
  local ok, err = compareOutput([[
local function counter(start)
  local n = start
  return function()
    n = n + 1
    return n
  end
end
local c = counter(0)
print(c())
print(c())
print(c())
]])
  assert(ok, err)
end)

test("INT-024: varargs", function()
  local ok, err = compareOutput([[
local function sum(...)
  local total = 0
  for _, v in ipairs({...}) do
    total = total + v
  end
  return total
end
print(sum(1, 2, 3, 4, 5))
]])
  assert(ok, err)
end)

test("INT-025: higher-order functions", function()
  local ok, err = compareOutput([[
local function map(t, fn)
  local result = {}
  for i, v in ipairs(t) do result[i] = fn(v) end
  return result
end
local doubled = map({1,2,3,4}, function(x) return x*2 end)
print(table.concat(doubled, ","))
]])
  assert(ok, err)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- §4  TABLES
-- ─────────────────────────────────────────────────────────────────────────────

log("\n── Tables ──────────────────────────────────────────────────")

test("INT-030: table constructor", function()
  local ok, err = compareOutput([[
local t = {10, 20, 30, key="value"}
print(t[1], t[2], t[3], t.key)
]])
  assert(ok, err)
end)

test("INT-031: table field access", function()
  local ok, err = compareOutput([[
local person = {}
person.name = "Alice"
person.age  = 30
print(person.name, person.age)
]])
  assert(ok, err)
end)

test("INT-032: generic for with pairs", function()
  local ok, err = compareOutput([[
local t = {a=1, b=2, c=3}
local keys = {}
for k in pairs(t) do keys[#keys+1] = k end
table.sort(keys)
for _, k in ipairs(keys) do print(k, t[k]) end
]])
  assert(ok, err)
end)

test("INT-033: generic for with ipairs", function()
  local ok, err = compareOutput([[
local t = {10, 20, 30, 40, 50}
for i, v in ipairs(t) do
  print(i, v)
end
]])
  assert(ok, err)
end)

test("INT-034: nested tables", function()
  local ok, err = compareOutput([[
local matrix = {{1,2,3},{4,5,6},{7,8,9}}
print(matrix[2][2])
print(matrix[3][1])
]])
  assert(ok, err)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- §5  METATABLES
-- ─────────────────────────────────────────────────────────────────────────────

log("\n── Metatables ──────────────────────────────────────────────")

test("INT-040: __index metamethod", function()
  local ok, err = compareOutput([[
local defaults = {color="red", size=10}
local obj = setmetatable({}, {__index=defaults})
print(obj.color)
print(obj.size)
obj.color = "blue"
print(obj.color)
]])
  assert(ok, err)
end)

test("INT-041: __tostring metamethod", function()
  local ok, err = compareOutput([[
local Point = {}
Point.__index = Point
Point.__tostring = function(p) return "("..p.x..","..p.y..")" end
function Point.new(x,y) return setmetatable({x=x,y=y},Point) end
local p = Point.new(3,4)
print(tostring(p))
]])
  assert(ok, err)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- §6  STRING OPERATIONS
-- ─────────────────────────────────────────────────────────────────────────────

log("\n── Strings ─────────────────────────────────────────────────")

test("INT-050: string methods", function()
  local ok, err = compareOutput([[
local s = "Hello, World!"
print(#s)
print(string.upper(s))
print(string.lower(s))
print(string.sub(s, 1, 5))
print(string.rep("ab", 3))
]])
  assert(ok, err)
end)

test("INT-051: string format", function()
  local ok, err = compareOutput([[
print(string.format("%d + %d = %d", 3, 4, 7))
print(string.format("%.2f", 3.14159))
print(string.format("%q", "hello \"world\""))
]])
  assert(ok, err)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- §7  ERROR HANDLING
-- ─────────────────────────────────────────────────────────────────────────────

log("\n── Error Handling ──────────────────────────────────────────")

test("INT-060: pcall catches error", function()
  local ok, err = compareOutput([[
local ok, msg = pcall(function()
  error("test error")
end)
print(ok)
print(type(msg))
]])
  assert(ok, err)
end)

test("INT-061: pcall success", function()
  local ok, err = compareOutput([[
local ok, val = pcall(function()
  return 42
end)
print(ok, val)
]])
  assert(ok, err)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- §8  PIPELINE INTEGRITY
-- ─────────────────────────────────────────────────────────────────────────────

log("\n── Pipeline Integrity ──────────────────────────────────────")

test("INT-070: deterministic build (same seed = same output)", function()
  local source = "local x = 1 + 2; print(x)"
  local ast1 = Parser.parse(source)
  local ast2 = Parser.parse(source)
  local nm1  = Opcodes.generateMap(42)
  local nm2  = Opcodes.generateMap(42)
  local p1   = Compiler.compile(ast1, nm1, 42)
  local p2   = Compiler.compile(ast2, nm2, 42)
  -- Same seed = same number of instructions
  assert(#p1.i == #p2.i,
    string.format("instruction count differs: %d vs %d", #p1.i, #p2.i))
  assert(#p1.k == #p2.k,
    string.format("constant count differs: %d vs %d", #p1.k, #p2.k))
end)

test("INT-071: different seeds produce different opcode values", function()
  local source = "local x = 1"
  local ast = Parser.parse(source)
  local nm1 = Opcodes.generateMap(1)
  local nm2 = Opcodes.generateMap(2)
  local p1  = Compiler.compile(ast, nm1, 1)
  local p2  = Compiler.compile(ast, nm2, 2)
  -- First opcode value should differ (different shuffle)
  if #p1.i > 0 and #p2.i > 0 then
    assert(p1.i[1][1] ~= p2.i[1][1],
      "different seeds produced same opcode value")
  end
end)

test("INT-072: proto version field is correct", function()
  local ast = Parser.parse("local x = 1")
  local nm  = Opcodes.generateMap(1)
  local p   = Compiler.compile(ast, nm, 1)
  assert(p.v == Spec.BYTECODE_VERSION,
    string.format("expected version %d, got %d", Spec.BYTECODE_VERSION, p.v))
end)

test("INT-073: constants are byte arrays not plaintext", function()
  local source = 'local s = "my_secret_value"'
  local ast = Parser.parse(source)
  local nm  = Opcodes.generateMap(1)
  local p   = Compiler.compile(ast, nm, 1)
  for _, c in ipairs(p.k) do
    if c.t == "s" then
      -- v must be a table of numbers, not a string
      assert(type(c.v) == "table", "string constant v must be byte array")
      local reconstructed = ""
      for _, b in ipairs(c.v) do
        assert(type(b) == "number" and b >= 0 and b <= 255,
          "byte out of range: " .. tostring(b))
        reconstructed = reconstructed .. string.char(b)
      end
      -- Must NOT equal the plaintext
      assert(reconstructed ~= "my_secret_value",
        "constant appears to be stored unencrypted")
    end
  end
end)

test("INT-074: coverage at 100% for well-formed source", function()
  local _, _, cov = Parser.parse([[
local function greet(name)
  return "Hello, " .. name .. "!"
end
print(greet("World"))
]])
  assert(cov.pct == 100,
    string.format("expected 100%% coverage, got %d%%", cov.pct))
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- SUMMARY
-- ─────────────────────────────────────────────────────────────────────────────

log(string.rep("─", 60))
log(string.format("Integration Results: %d/%d passed", passed, total))
if failed > 0 then
  log(string.format("FAILED: %d tests", failed))
  os.exit(1)
else
  log("All integration tests passed.")
  os.exit(0)
end
