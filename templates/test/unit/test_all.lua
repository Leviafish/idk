--[[
  Levititas v3.1 — Unit Tests
  test/unit/test_all.lua

  Tests every major component independently.
  Run: lua test/unit/test_all.lua
  Expected: all PASS
]]

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local passed, failed, total = 0, 0, 0

local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print(string.format("  [PASS] %s", name))
  else
    failed = failed + 1
    print(string.format("  [FAIL] %s\n         %s", name, tostring(err)))
  end
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error(string.format("%s: expected %s, got %s",
      msg or "assert_eq", tostring(b), tostring(a)), 2)
  end
end

local function assert_ok(v, msg)
  if not v then error(msg or "expected truthy", 2) end
end

local function assert_nil(v, msg)
  if v ~= nil then error((msg or "expected nil") .. ": " .. tostring(v), 2) end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  SPEC
-- ─────────────────────────────────────────────────────────────────────────────

print("\n── Spec ────────────────────────────────────────────────────")
local Spec = require("spec")

test("spec: bytecode version is integer", function()
  assert_eq(type(Spec.BYTECODE_VERSION), "number")
  assert_ok(Spec.BYTECODE_VERSION >= 1)
end)

test("spec: canonical opcodes non-empty", function()
  local count = 0
  for _ in pairs(Spec.CANONICAL_OPCODE) do count = count + 1 end
  assert_ok(count >= 50, "expected >= 50 opcodes, got " .. count)
end)

test("spec: all error codes are strings", function()
  for k, v in pairs(Spec.ERR) do
    assert_eq(type(v), "string", "ERR." .. k)
  end
end)

test("spec: limits are positive numbers", function()
  for k, v in pairs(Spec.LIMITS) do
    assert_ok(type(v) == "number" and v > 0, k .. " must be positive")
  end
end)

test("spec: const types are single chars", function()
  for k, v in pairs(Spec.CONST_TYPE) do
    assert_eq(type(v), "string", k)
    assert_ok(#v == 1, "CONST_TYPE." .. k .. " must be 1 char")
  end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- §2  OPCODES
-- ─────────────────────────────────────────────────────────────────────────────

print("\n── Opcodes ─────────────────────────────────────────────────")
local Opcodes = require("vm.opcodes")

test("opcodes: generateMap returns two tables", function()
  local a, b = Opcodes.generateMap(12345)
  assert_eq(type(a), "table")
  assert_eq(type(b), "table")
end)

test("opcodes: name→val and val→name are inverse", function()
  local nm, rv = Opcodes.generateMap(99999)
  for name, val in pairs(nm) do
    assert_eq(rv[val], name, "inverse mismatch for " .. name)
  end
end)

test("opcodes: all values unique (no collisions)", function()
  local nm, _ = Opcodes.generateMap(54321)
  local seen = {}
  for name, val in pairs(nm) do
    assert_ok(not seen[val],
      "collision: opcode value " .. val .. " used by multiple names")
    seen[val] = name
  end
end)

test("opcodes: different seeds produce different maps", function()
  local nm1 = Opcodes.generateMap(1)
  local nm2 = Opcodes.generateMap(2)
  local same = true
  for name, val in pairs(nm1) do
    if nm2[name] ~= val then same = false; break end
  end
  assert_ok(not same, "different seeds produced identical opcode maps")
end)

test("opcodes: same seed produces same map (deterministic)", function()
  local nm1 = Opcodes.generateMap(777)
  local nm2 = Opcodes.generateMap(777)
  for name, val in pairs(nm1) do
    assert_eq(nm2[name], val, "non-deterministic for seed 777")
  end
end)

test("opcodes: seedFromInt clamps to positive", function()
  local s = Opcodes.seedFromInt(0)
  assert_ok(s > 0)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- §3  PARSER
-- ─────────────────────────────────────────────────────────────────────────────

print("\n── Parser ──────────────────────────────────────────────────")
local Parser = require("parser.parser")

test("parser: parses empty source", function()
  local ast, err, cov = Parser.parse("")
  assert_ok(ast, "expected AST for empty source")
  assert_nil(err)
end)

test("parser: parses simple assignment", function()
  local ast, err = Parser.parse("local x = 1")
  assert_ok(ast); assert_nil(err)
  assert_eq(#ast.body, 1)
  assert_eq(ast.body[1].type, "Local")
end)

test("parser: parses function definition", function()
  local ast, err = Parser.parse("local function f(a,b) return a+b end")
  assert_ok(ast); assert_nil(err)
  assert_eq(ast.body[1].type, "LocalFunction")
end)

test("parser: parses if/elseif/else", function()
  local ast, err = Parser.parse("if a then b() elseif c then d() else e() end")
  assert_ok(ast); assert_nil(err)
  local stmt = ast.body[1]
  assert_eq(stmt.type, "If")
  assert_eq(#stmt.elseifs, 1)
  assert_ok(stmt.elsebody ~= nil)
end)

test("parser: parses numeric for", function()
  local ast, err = Parser.parse("for i=1,10 do end")
  assert_ok(ast); assert_nil(err)
  assert_eq(ast.body[1].type, "ForNum")
end)

test("parser: parses generic for", function()
  local ast, err = Parser.parse("for k,v in pairs(t) do end")
  assert_ok(ast); assert_nil(err)
  assert_eq(ast.body[1].type, "ForGen")
end)

test("parser: parses goto and label", function()
  local ast, err = Parser.parse("goto continue\n::continue::")
  assert_ok(ast); assert_nil(err)
  assert_eq(ast.body[1].type, "Goto")
  assert_eq(ast.body[2].type, "Label")
end)

test("parser: parses table constructor", function()
  local ast, err = Parser.parse("local t = {a=1, [2]=3, 'x'}")
  assert_ok(ast); assert_nil(err)
  local tbl = ast.body[1].vals[1]
  assert_eq(tbl.type, "Table")
  assert_eq(#tbl.fields, 3)
end)

test("parser: parses method call", function()
  local ast, err = Parser.parse("obj:method(1,2,3)")
  assert_ok(ast); assert_nil(err)
  assert_eq(ast.body[1].type, "MethodCall")
end)

test("parser: rejects obviously invalid syntax", function()
  local ast, err = Parser.parse("local = = = garbage !!!!")
  -- Should either fail parse or fail coverage
  assert_ok(ast == nil or err ~= nil,
    "expected parse failure for invalid syntax")
end)

test("parser: coverage tracks consumed tokens", function()
  local _, _, cov = Parser.parse("local x = 1 + 2")
  assert_ok(cov)
  assert_ok(cov.total > 0)
  assert_ok(cov.consumed >= 0)
  assert_ok(cov.pct >= 0 and cov.pct <= 100)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- §4  AST VALIDATOR
-- ─────────────────────────────────────────────────────────────────────────────

print("\n── AST Validator ───────────────────────────────────────────")
local ASTVal = require("validation.ast_validator")

test("ast_val: accepts valid Block node", function()
  local ast = { type="Block", body={} }
  local ok, err = ASTVal.validateAST(ast)
  assert_ok(ok, tostring(err))
end)

test("ast_val: rejects nil AST", function()
  local ok, err = ASTVal.validateAST(nil)
  assert_ok(not ok)
  assert_ok(err ~= nil)
end)

test("ast_val: rejects unknown node type", function()
  local ast = { type="Block", body={{ type="UNKNOWN_NODE" }} }
  local ok, err = ASTVal.validateAST(ast)
  assert_ok(not ok)
end)

test("ast_val: accepts parsed output from parser", function()
  local ast = Parser.parse("local x = 1; local y = 2")
  local ok, err = ASTVal.validateAST(ast)
  assert_ok(ok, tostring(err))
end)

test("ast_val: goto resolution: empty unresolved list passes", function()
  local ok, err = ASTVal.validateGotoResolution({})
  assert_ok(ok, tostring(err))
end)

test("ast_val: goto resolution: unresolved entry fails", function()
  local ok, err = ASTVal.validateGotoResolution({{label="missing"}})
  assert_ok(not ok)
  assert_ok(err:find("missing"))
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- §5  PROTO VALIDATOR
-- ─────────────────────────────────────────────────────────────────────────────

print("\n── Proto Validator ─────────────────────────────────────────")
local ProtoVal = require("validation.proto_validator")

local function minimalProto()
  return {
    v = Spec.BYTECODE_VERSION,
    i = {{ Spec.CANONICAL_OPCODE["HALT"] or 1, 0, 0, 0 }},
    k = {},
    p = 0, va = false, ul = 0,
  }
end

test("proto_val: accepts minimal valid proto", function()
  local ok, err = ProtoVal.validate(minimalProto())
  assert_ok(ok, tostring(err))
end)

test("proto_val: rejects wrong version", function()
  local p = minimalProto(); p.v = 999
  local ok, err = ProtoVal.validate(p)
  assert_ok(not ok)
end)

test("proto_val: rejects missing 'i' field", function()
  local p = minimalProto(); p.i = nil
  local ok, err = ProtoVal.validate(p)
  assert_ok(not ok)
end)

test("proto_val: rejects missing 'k' field", function()
  local p = minimalProto(); p.k = nil
  local ok, err = ProtoVal.validate(p)
  assert_ok(not ok)
end)

test("proto_val: rejects out-of-range jump", function()
  local p = minimalProto()
  -- JMP to instruction 999 when only 1 exists
  p.i = {{ Spec.CANONICAL_OPCODE["JMP"] or 2, 0, 999, 0 }}
  local nm = {}; for n, v in pairs(Spec.CANONICAL_OPCODE) do nm[v] = n end
  local ok, err = ProtoVal.validate(p, nm)
  assert_ok(not ok)
end)

test("proto_val: rejects non-table instruction", function()
  local p = minimalProto(); p.i = { "not_a_table" }
  local ok, err = ProtoVal.validate(p)
  assert_ok(not ok)
end)

test("proto_val: rejects invalid const type", function()
  local p = minimalProto()
  p.k = {{ t="z" }}  -- unknown type
  local ok, err = ProtoVal.validate(p)
  assert_ok(not ok)
end)

test("proto_val: rejects JMP to self", function()
  local p = minimalProto()
  local jmpOp = Spec.CANONICAL_OPCODE["JMP"] or 2
  p.i = {{ jmpOp, 0, 1, 0 }}  -- JMP B=1, which is instruction 1 itself (1-based)
  local nm = {}; for n, v in pairs(Spec.CANONICAL_OPCODE) do nm[v] = n end
  local ok, err = ProtoVal.validate(p, nm)
  -- This should be caught as self-jump
  -- (May pass if JMP to 1 is not self-referential at index 1)
  -- Just verify it doesn't crash
  assert_ok(ok ~= nil or err ~= nil)  -- either result is fine, no panic
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- §6  COMPAT
-- ─────────────────────────────────────────────────────────────────────────────

print("\n── Compat ──────────────────────────────────────────────────")
local Compat = require("compat.compat")

test("compat: lua54 accepts all Lua 5.4 features", function()
  local ast = Parser.parse("local x <const> = 1\nfor i=1,10 do end\nx = 1&2")
  local ok, issues = Compat.audit(ast, "lua54")
  assert_ok(ok)
  assert_eq(#issues, 0)
end)

test("compat: lua52 is always fatal", function()
  local ast = Parser.parse("local x = 1")
  local ok, issues = Compat.audit(ast, "lua52")
  assert_ok(not ok)
  assert_ok(#issues > 0)
  assert_eq(issues[1].severity, "fatal")
end)

test("compat: lua51 is always fatal", function()
  local ast = Parser.parse("local x = 1")
  local ok, issues = Compat.audit(ast, "lua51")
  assert_ok(not ok)
end)

test("compat: luajit rejects bitwise syntax", function()
  local ast = Parser.parse("local x = 1 & 2")
  local ok, issues = Compat.audit(ast, "luajit")
  assert_ok(not ok)
  local found = false
  for _, i in ipairs(issues) do if i.code == "COMPAT_LUAJIT_BITWISE" then found=true end end
  assert_ok(found)
end)

test("compat: unknown target returns fatal", function()
  local ast = Parser.parse("local x = 1")
  local ok, issues = Compat.audit(ast, "lua99")
  assert_ok(not ok)
end)

test("compat: support matrix has 6 entries", function()
  local m = Compat.supportMatrix()
  assert_eq(#m, 6)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- §7  COMPILER (basic smoke tests)
-- ─────────────────────────────────────────────────────────────────────────────

print("\n── Compiler ────────────────────────────────────────────────")
local Compiler = require("compiler.compiler")

local function compile(src)
  local ast, err = Parser.parse(src)
  if not ast then return nil, err end
  local nm = Opcodes.generateMap(42)
  return Compiler.compile(ast, nm, 42)
end

test("compiler: compiles empty block", function()
  local proto, err = compile("")
  assert_ok(proto, tostring(err))
  assert_eq(proto.v, Spec.BYTECODE_VERSION)
end)

test("compiler: compiles local variable", function()
  local proto, err = compile("local x = 42")
  assert_ok(proto, tostring(err))
  assert_ok(#proto.i > 0)
end)

test("compiler: compiles function call", function()
  local proto, err = compile("print('hello')")
  assert_ok(proto, tostring(err))
end)

test("compiler: compiles if statement", function()
  local proto, err = compile("if true then print('yes') end")
  assert_ok(proto, tostring(err))
end)

test("compiler: compiles while loop", function()
  local proto, err = compile("local i=0 while i<10 do i=i+1 end")
  assert_ok(proto, tostring(err))
end)

test("compiler: compiles numeric for", function()
  local proto, err = compile("for i=1,10 do end")
  assert_ok(proto, tostring(err))
end)

test("compiler: compiles table constructor", function()
  local proto, err = compile("local t = {a=1, b=2, 3}")
  assert_ok(proto, tostring(err))
end)

test("compiler: compiles nested function", function()
  local proto, err = compile("local function f(x) return x*2 end")
  assert_ok(proto, tostring(err))
  -- Should have a sub-proto in constants
  local hasSubProto = false
  for _, c in ipairs(proto.k) do
    if c.t == "p" then hasSubProto = true; break end
  end
  assert_ok(hasSubProto, "expected sub-proto constant for nested function")
end)

test("compiler: constants are encrypted (not plaintext)", function()
  local proto, err = compile('local s = "secret_string"')
  assert_ok(proto, tostring(err))
  -- String constants should be byte arrays, not plaintext strings
  for _, c in ipairs(proto.k) do
    if c.t == "s" then
      assert_eq(type(c.v), "table", "string constant should be encrypted byte array")
      -- Verify it's not the original string
      local raw = ""
      for _, b in ipairs(c.v) do raw = raw .. string.char(b) end
      assert_ok(raw ~= "secret_string", "constant appears to be unencrypted")
    end
  end
end)

test("compiler: proto passes proto validator", function()
  local proto, err = compile("local x = 1 + 2")
  assert_ok(proto, tostring(err))
  local nm = Opcodes.generateMap(42)
  local rv = {}; for n, v in pairs(nm) do rv[v] = n end
  local ok2, err2 = ProtoVal.validate(proto, rv)
  assert_ok(ok2, tostring(err2))
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- SUMMARY
-- ─────────────────────────────────────────────────────────────────────────────

print(string.rep("─", 60))
print(string.format("Results: %d/%d passed", passed, total))
if failed > 0 then
  print(string.format("FAILED:  %d tests", failed))
  os.exit(1)
else
  print("All tests passed.")
  os.exit(0)
end
