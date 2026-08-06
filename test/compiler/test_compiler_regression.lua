--[[
  Levititas v3.2 — Compiler Regression Framework
  test/compiler/test_compiler_regression.lua

  Permanent regression framework.
  Categories: AST, Scope, Symbol, Validation, VM, Compatibility.
  One-command execution. Deterministic. Auto pass/fail.
  Run: lua test/compiler/test_compiler_regression.lua
]]

local function findRoot()
  local paths = {".", "..", "../.."}
  for _, p in ipairs(paths) do
    local f = io.open(p .. "/src/spec.lua")
    if f then f:close(); return p end
  end
  return "."
end
local ROOT = findRoot()
package.path = ROOT.."/src/?.lua;"..ROOT.."/src/?/init.lua;"..package.path

local Parser   = require("parser.parser")
local Opcodes  = require("vm.opcodes")
local Compiler = require("compiler.compiler")
local ProtoVal = require("validation.proto_validator")
local ASTVal   = require("validation.ast_validator")
local Compat   = require("compat.compat")
local Spec     = require("spec")

-- ─────────────────────────────────────────────────────────────────────────────
-- Framework
-- ─────────────────────────────────────────────────────────────────────────────

local SEED = 42
local results = { pass=0, fail=0, skip=0, total=0 }
local failLog = {}
local currentSuite = ""

local function suite(name)
  currentSuite = name
  io.write(string.format("\n── %s %s\n", name, string.rep("─", 48 - #name)))
end

local function pass(id) results.pass=results.pass+1; results.total=results.total+1; io.write(string.format("  [P] %s\n",id)) end
local function fail(id, reason)
  results.fail=results.fail+1; results.total=results.total+1
  io.write(string.format("  [F] %s: %s\n",id,reason:gsub("\n","\\n"):sub(1,80)))
  failLog[#failLog+1]={id=id,suite=currentSuite,reason=reason}
end
local function skip(id, why) results.skip=results.skip+1; results.total=results.total+1; io.write(string.format("  [S] %s: %s\n",id,why)) end

-- Parse source → AST (or nil, err)
local function parse(src) return Parser.parse(src) end

-- Parse + compile → proto (or nil, err)
local function compile(src, seed)
  local ast, e = parse(src)
  if not ast then return nil, "parse: "..tostring(e) end
  local nm = Opcodes.generateMap(seed or SEED)
  local proto, ce = Compiler.compile(ast, nm, seed or SEED)
  if not proto then return nil, "compile: "..tostring(ce) end
  return proto, nil, nm
end

-- Assert helpers
local function assertParse(id, src)
  local ast, e = parse(src)
  if ast then pass(id) else fail(id, tostring(e)) end
end

local function assertParseErr(id, src)
  local ast, e = parse(src)
  if not ast and e then pass(id)
  elseif ast then fail(id, "expected parse error, got AST")
  else fail(id, "no error returned") end
end

local function assertCompile(id, src)
  local proto, e = compile(src)
  if proto then pass(id) else fail(id, tostring(e)) end
end

local function assertCompileErr(id, src)
  local proto, e = compile(src)
  if not proto then pass(id) else fail(id, "expected compile error, got proto") end
end

local function assertProtoValid(id, src)
  local proto, e, nm = compile(src)
  if not proto then fail(id, "compile failed: "..tostring(e)); return end
  local rv = {}; for n,v in pairs(nm) do rv[v]=n end
  local ok, ve = ProtoVal.validate(proto, rv)
  if ok then pass(id) else fail(id, "proto invalid: "..tostring(ve)) end
end

local function assertProtoField(id, src, field, expected)
  local proto, e = compile(src)
  if not proto then fail(id, tostring(e)); return end
  if proto[field] == expected then pass(id)
  else fail(id, string.format("proto.%s = %s, expected %s",
    field, tostring(proto[field]), tostring(expected))) end
end

local function assertConstCount(id, src, expected)
  local proto, e = compile(src)
  if not proto then fail(id, tostring(e)); return end
  if #proto.k == expected then pass(id)
  else fail(id, string.format("#consts = %d, expected %d", #proto.k, expected)) end
end

local function assertInstrCount(id, src, minCount)
  local proto, e = compile(src)
  if not proto then fail(id, tostring(e)); return end
  if #proto.i >= minCount then pass(id)
  else fail(id, string.format("#instrs = %d, need >= %d", #proto.i, minCount)) end
end

local function assertConstEncrypted(id, src)
  local proto, e = compile(src)
  if not proto then fail(id, tostring(e)); return end
  local allEncrypted = true
  for _, c in ipairs(proto.k) do
    if c.t == "s" or c.t == "i" or c.t == "f" then
      if type(c.v) ~= "table" then allEncrypted = false; break end
    end
  end
  if allEncrypted then pass(id) else fail(id, "constant not encrypted") end
end

local function assertDeterministic(id, src)
  local p1, e1 = compile(src, 777)
  local p2, e2 = compile(src, 777)
  if not p1 then fail(id, tostring(e1)); return end
  if #p1.i ~= #p2.i then fail(id, "instruction count non-deterministic"); return end
  for i = 1, #p1.i do
    for j = 1, 4 do
      if p1.i[i][j] ~= p2.i[i][j] then
        fail(id, string.format("instr %d field %d non-deterministic", i, j)); return
      end
    end
  end
  pass(id)
end

local function assertDifferentSeeds(id, src)
  local p1, e1 = compile(src, 1)
  local p2, e2 = compile(src, 2)
  if not p1 or not p2 then fail(id, tostring(e1 or e2)); return end
  -- Different seeds = different opcode values
  for i = 1, math.min(#p1.i, #p2.i) do
    if p1.i[i][1] ~= p2.i[i][1] then
      pass(id); return
    end
  end
  fail(id, "different seeds produced identical opcode values")
end

local function assertNoPlaintextConst(id, src, forbidden)
  local proto, e = compile(src)
  if not proto then fail(id, tostring(e)); return end
  -- Ensure forbidden string doesn't appear as plaintext in any const
  local function checkConst(c)
    if c.t == "s" then
      -- v should be byte array, not string
      if type(c.v) == "string" and c.v:find(forbidden, 1, true) then
        return false
      end
    elseif c.t == "p" then
      for _, sc in ipairs(c.proto.k) do
        if not checkConst(sc) then return false end
      end
    end
    return true
  end
  for _, c in ipairs(proto.k) do
    if not checkConst(c) then
      fail(id, "plaintext '"..forbidden.."' found in constant pool"); return
    end
  end
  pass(id)
end

local function assertSubProto(id, src)
  local proto, e = compile(src)
  if not proto then fail(id, tostring(e)); return end
  for _, c in ipairs(proto.k) do
    if c.t == "p" then pass(id); return end
  end
  fail(id, "no sub-proto found in constant pool")
end

local function assertCompatOk(id, src, target)
  local ast, e = parse(src)
  if not ast then fail(id, "parse: "..tostring(e)); return end
  local ok, issues = Compat.audit(ast, target)
  if ok then pass(id)
  else fail(id, Compat.formatIssues(issues)) end
end

local function assertCompatFail(id, src, target)
  local ast, e = parse(src)
  if not ast then pass(id); return end  -- parse error counts as compat failure
  local ok = Compat.audit(ast, target)
  if not ok then pass(id) else fail(id, "expected compat failure for "..target) end
end

local function assertASTValid(id, src)
  local ast, e = parse(src)
  if not ast then fail(id, "parse: "..tostring(e)); return end
  local ok, ve = ASTVal.validateAST(ast)
  if ok then pass(id) else fail(id, tostring(ve)) end
end

local function assertCoverage(id, src, expectedPct)
  local _, _, cov = parse(src)
  if not cov then fail(id, "no coverage returned"); return end
  if cov.pct >= expectedPct then pass(id)
  else fail(id, string.format("coverage %d%% < expected %d%%", cov.pct, expectedPct)) end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- SUITE A: AST TESTS
-- ═════════════════════════════════════════════════════════════════════════════

suite("AST-A: Parse Coverage")
assertCoverage("AST-A-001","",                         100)
assertCoverage("AST-A-002","local x = 1",              100)
assertCoverage("AST-A-003","print('hello')",           100)
assertCoverage("AST-A-004","local function f() end",   100)
assertCoverage("AST-A-005","for i=1,10 do end",        100)
assertCoverage("AST-A-006","for k,v in pairs(t) do end", 100)
assertCoverage("AST-A-007","while true do break end",  100)
assertCoverage("AST-A-008","repeat until true",        100)
assertCoverage("AST-A-009","if a then b() end",        100)
assertCoverage("AST-A-010","local t = {1,2,3}",        100)
assertCoverage("AST-A-011","goto skip; ::skip::",      100)
assertCoverage("AST-A-012","return 1, 2, 3",           100)
assertCoverage("AST-A-013","local x = a and b or c",   100)
assertCoverage("AST-A-014","local x = -a + b * c",     100)
assertCoverage("AST-A-015","local x = a .. b .. c",    100)
assertCoverage("AST-A-016","local x = a[b][c].d",      100)
assertCoverage("AST-A-017","a:method(1,2,3)",          100)
assertCoverage("AST-A-018","local x = function(...) return ... end", 100)
assertCoverage("AST-A-019","local x <const> = 42",     100)
assertCoverage("AST-A-020","local x = {[1]=a,[b]=c,d=e,f}", 100)

suite("AST-B: Parse Node Types")
assertParse("AST-B-001", "local x = 1")
assertParse("AST-B-002", "local a, b, c = 1, 2, 3")
assertParse("AST-B-003", "x = 1")
assertParse("AST-B-004", "a, b = b, a")
assertParse("AST-B-005", "do local x = 1 end")
assertParse("AST-B-006", "while x do end")
assertParse("AST-B-007", "repeat until x")
assertParse("AST-B-008", "if x then end")
assertParse("AST-B-009", "if x then elseif y then else end")
assertParse("AST-B-010", "for i = 1, 10 do end")
assertParse("AST-B-011", "for i = 1, 10, 2 do end")
assertParse("AST-B-012", "for k, v in pairs(t) do end")
assertParse("AST-B-013", "function f() end")
assertParse("AST-B-014", "function t.f() end")
assertParse("AST-B-015", "function t:f() end")
assertParse("AST-B-016", "local function f() end")
assertParse("AST-B-017", "return")
assertParse("AST-B-018", "return 1")
assertParse("AST-B-019", "return 1, 2, 3")
assertParse("AST-B-020", "break")
assertParse("AST-B-021", "goto label; ::label::")
assertParse("AST-B-022", "f()")
assertParse("AST-B-023", "f(1, 2, 3)")
assertParse("AST-B-024", "f 'string'")
assertParse("AST-B-025", "f {1, 2, 3}")
assertParse("AST-B-026", "t.f()")
assertParse("AST-B-027", "t:method()")
assertParse("AST-B-028", "t[k]()")
assertParse("AST-B-029", "(function() end)()")
assertParse("AST-B-030", "local x = nil")
assertParse("AST-B-031", "local x = true")
assertParse("AST-B-032", "local x = false")
assertParse("AST-B-033", "local x = 42")
assertParse("AST-B-034", "local x = 3.14")
assertParse("AST-B-035", "local x = 'hello'")
assertParse("AST-B-036", "local x = [=[long string]=]")
assertParse("AST-B-037", "local x = ...")
assertParse("AST-B-038", "local x = {}")
assertParse("AST-B-039", "local x = {1, 2, 3}")
assertParse("AST-B-040", "local x = {a=1, b=2}")
assertParse("AST-B-041", "local x = {[1]=a, [b]=c}")
assertParse("AST-B-042", "local x = a + b")
assertParse("AST-B-043", "local x = a - b")
assertParse("AST-B-044", "local x = a * b")
assertParse("AST-B-045", "local x = a / b")
assertParse("AST-B-046", "local x = a // b")
assertParse("AST-B-047", "local x = a % b")
assertParse("AST-B-048", "local x = a ^ b")
assertParse("AST-B-049", "local x = a .. b")
assertParse("AST-B-050", "local x = a & b")
assertParse("AST-B-051", "local x = a | b")
assertParse("AST-B-052", "local x = a ~ b")
assertParse("AST-B-053", "local x = a << b")
assertParse("AST-B-054", "local x = a >> b")
assertParse("AST-B-055", "local x = a == b")
assertParse("AST-B-056", "local x = a ~= b")
assertParse("AST-B-057", "local x = a < b")
assertParse("AST-B-058", "local x = a <= b")
assertParse("AST-B-059", "local x = a > b")
assertParse("AST-B-060", "local x = a >= b")
assertParse("AST-B-061", "local x = a and b")
assertParse("AST-B-062", "local x = a or b")
assertParse("AST-B-063", "local x = not a")
assertParse("AST-B-064", "local x = -a")
assertParse("AST-B-065", "local x = ~a")
assertParse("AST-B-066", "local x = #a")
assertParse("AST-B-067", "local x = a.b.c.d")
assertParse("AST-B-068", "local x = a[b][c][d]")
assertParse("AST-B-069", "local x = a.b[c]:d()")
assertParse("AST-B-070", "local function f(a,b,...) return a,b,... end")

suite("AST-C: AST Validation")
assertASTValid("AST-C-001", "local x = 1")
assertASTValid("AST-C-002", "for i=1,10 do print(i) end")
assertASTValid("AST-C-003", "local function f(a,b) return a+b end")
assertASTValid("AST-C-004", "if true then print('a') elseif false then print('b') else print('c') end")
assertASTValid("AST-C-005", "local t = {a=1, [2]=3, 4}")
assertASTValid("AST-C-006", "goto skip; ::skip::")
assertASTValid("AST-C-007", "for k,v in pairs({}) do end")
assertASTValid("AST-C-008", "local x = (function(...) return ... end)(1,2,3)")
assertASTValid("AST-C-009", "repeat until x > 10")
assertASTValid("AST-C-010", "while x do x = x - 1 end")

suite("AST-D: Parse Error Detection")
assertParseErr("AST-D-001", "local = 1")                          -- missing name
assertParseErr("AST-D-002", "function ()")                        -- missing name and body issues
assertParseErr("AST-D-003", "if then end")                        -- missing condition
assertParseErr("AST-D-004", "for do end")                         -- missing var
assertParseErr("AST-D-005", "end")                                -- unexpected end

-- ═════════════════════════════════════════════════════════════════════════════
-- SUITE B: SCOPE TESTS
-- ═════════════════════════════════════════════════════════════════════════════

suite("SCOPE-A: Local Variable Scoping")
assertCompile("SCOPE-A-001", "local x = 1; print(x)")
assertCompile("SCOPE-A-002", "local x = 1; do local x = 2 end; print(x)")
assertCompile("SCOPE-A-003", "do local x = 1 end")
assertCompile("SCOPE-A-004", "for i=1,10 do local x=i end")
assertCompile("SCOPE-A-005", "local function f() local x=1 end")
assertCompile("SCOPE-A-006", "local x=1; local y=x+1; local z=y+1")
assertCompile("SCOPE-A-007", "local a,b,c = 1,2,3; print(a,b,c)")
assertCompile("SCOPE-A-008", "local x; x = 1; print(x)")
assertCompile("SCOPE-A-009", "local x=1; do local x=2; do local x=3 end end")
assertCompile("SCOPE-A-010", "local function f(a,b,c) return a,b,c end")

suite("SCOPE-B: Upvalue Compilation")
assertCompile("SCOPE-B-001", "local x=1; local function f() return x end; print(f())")
assertCompile("SCOPE-B-002", "local x=1; local function f() x=x+1 end; f()")
assertCompile("SCOPE-B-003", "local x=0; local inc=function() x=x+1 end; local get=function() return x end")
assertCompile("SCOPE-B-004", "local function outer() local x=1; return function() return x end end")
assertCompile("SCOPE-B-005", "local function f() local x=1; local function g() local function h() return x end end end")
assertSubProto("SCOPE-B-006", "local function f() return function() return 1 end end")
assertSubProto("SCOPE-B-007", "local x = function() end")
assertSubProto("SCOPE-B-008", "local t = {f = function() end}")
assertSubProto("SCOPE-B-009", "local function f(x) return function(y) return x+y end end")
assertSubProto("SCOPE-B-010", "for i=1,3 do local j=i; local f=function() return j end end")

suite("SCOPE-C: Global Access")
assertCompile("SCOPE-C-001", "print('hello')")
assertCompile("SCOPE-C-002", "x = 1")
assertCompile("SCOPE-C-003", "x = y + z")
assertCompile("SCOPE-C-004", "math.floor(3.7)")
assertCompile("SCOPE-C-005", "string.format('%d', 42)")
assertCompile("SCOPE-C-006", "table.insert(t, 1)")
assertCompile("SCOPE-C-007", "os.time()")
assertCompile("SCOPE-C-008", "setmetatable({}, {})")
assertCompile("SCOPE-C-009", "type(nil)")
assertCompile("SCOPE-C-010", "tostring(42)")

-- ═════════════════════════════════════════════════════════════════════════════
-- SUITE C: SYMBOL TESTS
-- ═════════════════════════════════════════════════════════════════════════════

suite("SYMBOL-A: Constant Pool Encryption")
assertConstEncrypted("SYM-A-001", 'local s = "hello"')
assertConstEncrypted("SYM-A-002", 'local s = "secret_token_xyz"')
assertConstEncrypted("SYM-A-003", 'local n = 42')
assertConstEncrypted("SYM-A-004", 'local f = 3.14')
assertConstEncrypted("SYM-A-005", 'local s = "a"; local t = "b"; local u = "c"')
assertNoPlaintextConst("SYM-A-006", 'local s = "my_password"', "my_password")
assertNoPlaintextConst("SYM-A-007", 'local k = "api_key_12345"', "api_key_12345")
assertNoPlaintextConst("SYM-A-008", 'print("secret")', "secret")
assertNoPlaintextConst("SYM-A-009", 'local t = {name = "admin"}', "admin")
assertNoPlaintextConst("SYM-A-010", 'local x = "a" .. "b" .. "c"', "abc")

suite("SYMBOL-B: Deterministic Compilation")
assertDeterministic("SYM-B-001", "local x = 1")
assertDeterministic("SYM-B-002", "print('hello')")
assertDeterministic("SYM-B-003", "for i=1,10 do print(i) end")
assertDeterministic("SYM-B-004", "local function f(x) return x*2 end; print(f(5))")
assertDeterministic("SYM-B-005", "local t = {a=1,b=2,c=3}; for k,v in pairs(t) do end")
assertDeterministic("SYM-B-006", "local function fact(n) if n<=1 then return 1 end; return n*fact(n-1) end")
assertDeterministic("SYM-B-007", "local x=0; while x<100 do x=x+1 end; print(x)")
assertDeterministic("SYM-B-008", 'local s="test"; print(s:upper())')
assertDeterministic("SYM-B-009", "local a,b = 1,2; a,b=b,a")
assertDeterministic("SYM-B-010", "if true then print('yes') else print('no') end")

suite("SYMBOL-C: Seed Variation")
assertDifferentSeeds("SYM-C-001", "local x = 1")
assertDifferentSeeds("SYM-C-002", "print('hello')")
assertDifferentSeeds("SYM-C-003", "for i=1,10 do end")
assertDifferentSeeds("SYM-C-004", "local function f() return 42 end")
assertDifferentSeeds("SYM-C-005", "local t = {1,2,3}")

-- ═════════════════════════════════════════════════════════════════════════════
-- SUITE D: VALIDATION TESTS
-- ═════════════════════════════════════════════════════════════════════════════

suite("VALID-A: Proto Structure")
assertProtoValid("VAL-A-001", "local x = 1")
assertProtoValid("VAL-A-002", "print('hello')")
assertProtoValid("VAL-A-003", "for i=1,10 do end")
assertProtoValid("VAL-A-004", "local function f() return 42 end; print(f())")
assertProtoValid("VAL-A-005", "if true then print('a') else print('b') end")
assertProtoValid("VAL-A-006", "while false do end")
assertProtoValid("VAL-A-007", "repeat until true")
assertProtoValid("VAL-A-008", "for k,v in pairs({}) do end")
assertProtoValid("VAL-A-009", "goto skip; ::skip::")
assertProtoValid("VAL-A-010", "local t = {a=1, b=2, c=3}")

assertProtoField("VAL-A-011", "local x = 1",      "v", Spec.BYTECODE_VERSION)
assertProtoField("VAL-A-012", "local function f() end; f()", "p", 0)
assertProtoField("VAL-A-013", "local function f(...) end",   "va", true)
assertProtoField("VAL-A-014", "return",             "va", true)

suite("VALID-B: Proto Field Correctness")
do
  local p,_,nm = compile("local x = 1; local y = 2")
  if p then
    local rv={}; for n,v in pairs(nm) do rv[v]=n end
    local ok,e = ProtoVal.validate(p, rv)
    if ok then pass("VAL-B-001") else fail("VAL-B-001", tostring(e)) end
  else skip("VAL-B-001", "compile failed") end
end

do
  local p,_,nm = compile("local function f(a,b,c) return a+b+c end")
  if p then
    -- f should be a sub-proto constant
    local found = false
    for _, c in ipairs(p.k) do
      if c.t == "p" and c.proto.p == 3 then found = true; break end
    end
    if found then pass("VAL-B-002") else fail("VAL-B-002", "sub-proto with 3 params not found") end
  else skip("VAL-B-002", "compile failed") end
end

do
  local p,e,nm = compile("local function f(...) end")
  if p then
    local found = false
    for _, c in ipairs(p.k) do
      if c.t == "p" and c.proto.va == true then found = true; break end
    end
    if found then pass("VAL-B-003") else fail("VAL-B-003", "vararg sub-proto not found") end
  else skip("VAL-B-003", "compile failed") end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- SUITE E: VM CORRECTNESS (compilation-level)
-- ═════════════════════════════════════════════════════════════════════════════

suite("VM-A: Instruction Generation")
assertInstrCount("VM-A-001", "local x = 1", 1)
assertInstrCount("VM-A-002", "local x = 1; local y = 2", 2)
assertInstrCount("VM-A-003", "print('hello')", 3)  -- LOAD_GLOBAL, PUSH_STR, CALL
assertInstrCount("VM-A-004", "local function f() end", 2)  -- MAKE_CLOSURE, STORE_LOCAL
assertInstrCount("VM-A-005", "if true then print('a') end", 4)
assertInstrCount("VM-A-006", "for i=1,10 do end", 4)
assertInstrCount("VM-A-007", "while true do break end", 3)
assertInstrCount("VM-A-008", "local x = 1 + 2", 4)
assertInstrCount("VM-A-009", "local x = 1; local y = 2; print(x + y)", 7)
assertInstrCount("VM-A-010", "goto skip; ::skip::", 1)  -- JMP + label is resolved

suite("VM-B: Constant Pool Correctness")
assertConstCount("VM-B-001", "", 0)
assertConstCount("VM-B-002", "local x = 1", 1)          -- integer 1
assertConstCount("VM-B-003", "local x = 1; local y = 1", 1)  -- deduped
assertConstCount("VM-B-004", 'print("hello")', 2)        -- "print", "hello"
assertConstCount("VM-B-005", "local x = 1; local y = 2; local z = 3", 3)

suite("VM-C: Control Flow Correctness")
-- Verify jump targets are within range
for i, src in ipairs({
  "if true then end",
  "while false do end",
  "for i=1,1 do end",
  "repeat until true",
  "goto skip; ::skip::",
  "if a then b() elseif c then d() else e() end",
  "for i=1,10 do if i==5 then break end end",
  "local i=0; while i<10 do i=i+1 end",
}) do
  assertProtoValid(string.format("VM-C-%03d",i), src)
end

-- ═════════════════════════════════════════════════════════════════════════════
-- SUITE F: COMPATIBILITY TESTS
-- ═════════════════════════════════════════════════════════════════════════════

suite("COMPAT-A: lua54 accepts all features")
assertCompatOk("COMPAT-A-001", "local x = 1 & 2",               "lua54")
assertCompatOk("COMPAT-A-002", "local x = 1 // 2",              "lua54")
assertCompatOk("COMPAT-A-003", "local x <const> = 1",           "lua54")
assertCompatOk("COMPAT-A-004", "goto skip; ::skip::",           "lua54")
assertCompatOk("COMPAT-A-005", "local x = 1 | 2",               "lua54")
assertCompatOk("COMPAT-A-006", "local x = ~1",                  "lua54")
assertCompatOk("COMPAT-A-007", "local x = 1 << 4",              "lua54")
assertCompatOk("COMPAT-A-008", "local x = 256 >> 4",            "lua54")
assertCompatOk("COMPAT-A-009", "for i=1,10 do end",             "lua54")
assertCompatOk("COMPAT-A-010", "local function f(...) return ... end", "lua54")

suite("COMPAT-B: lua53 rejects 5.4-only features")
assertCompatFail("COMPAT-B-001", "local x <const> = 1",         "lua53")
assertCompatFail("COMPAT-B-002", "local y <close> = f()",       "lua53")
assertCompatOk(  "COMPAT-B-003", "local x = 1 & 2",             "lua53")
assertCompatOk(  "COMPAT-B-004", "local x = 1 // 2",            "lua53")
assertCompatOk(  "COMPAT-B-005", "goto skip; ::skip::",         "lua53")

suite("COMPAT-C: lua52 is fatal")
assertCompatFail("COMPAT-C-001", "local x = 1",                 "lua52")
assertCompatFail("COMPAT-C-002", "print('hello')",              "lua52")
assertCompatFail("COMPAT-C-003", "local x = 1 & 2",             "lua52")

suite("COMPAT-D: lua51 is fatal")
assertCompatFail("COMPAT-D-001", "local x = 1",                 "lua51")
assertCompatFail("COMPAT-D-002", "for i=1,10 do end",           "lua51")

suite("COMPAT-E: luajit rejects modern syntax")
assertCompatFail("COMPAT-E-001", "local x = 1 & 2",             "luajit")
assertCompatFail("COMPAT-E-002", "local x = 1 // 2",            "luajit")
assertCompatFail("COMPAT-E-003", "local x <const> = 1",         "luajit")
assertCompatOk(  "COMPAT-E-004", "local x = 1 + 2",             "luajit")
assertCompatOk(  "COMPAT-E-005", "print('hello')",              "luajit")

suite("COMPAT-F: luau warnings")
assertCompatOk("COMPAT-F-001", "local x = 1",                   "luau")
assertCompatOk("COMPAT-F-002", "print('hello')",               "luau")
-- goto in luau produces warning (not error), so audit returns ok=true
do
  local ast = parse("goto skip; ::skip::")
  if ast then
    local ok, issues = Compat.audit(ast, "luau")
    local hasWarn = false
    for _, i in ipairs(issues) do if i.severity=="warning" then hasWarn=true end end
    if ok and hasWarn then pass("COMPAT-F-003")
    else fail("COMPAT-F-003", "expected ok=true with warning for goto in luau") end
  else skip("COMPAT-F-003", "parse failed") end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- SUMMARY
-- ═════════════════════════════════════════════════════════════════════════════

io.write(string.format([[

%s
  COMPILER REGRESSION RESULTS
  ─────────────────────────────────────────────────────
  Total:    %d
  Pass:     %d (%.0f%%)
  Fail:     %d
  Skip:     %d
%s

]], string.rep("═",60),
    results.total,
    results.pass, results.pass/math.max(1,results.total)*100,
    results.fail, results.skip,
    string.rep("═",60)))

if #failLog > 0 then
  io.write("Failed tests:\n")
  for _, f in ipairs(failLog) do
    io.write(string.format("  [%s] %s / %s\n    → %s\n",
      f.suite, f.id, f.suite, f.reason:sub(1,120)))
  end
  io.write("\n")
end

io.write(string.format("Result: %s\n",
  results.fail == 0 and "ALL PASSED" or
  string.format("%d FAILED — fix before release", results.fail)))

os.exit(results.fail > 0 and 1 or 0)
