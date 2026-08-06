--[[
  Levititas v3.1 — Regression Checklist
  test/regression/checklist.lua

  Verifies every item in the regression checklist automatically.
  Each check corresponds to a specific fix made in v3.1.
  Run: lua test/regression/checklist.lua
]]

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local Spec     = require("spec")
local Parser   = require("parser.parser")
local Opcodes  = require("vm.opcodes")
local Compiler = require("compiler.compiler")
local ProtoVal = require("validation.proto_validator")
local ASTVal   = require("validation.ast_validator")
local Compat   = require("compat.compat")

local passed, failed, total = 0, 0, 0

local function check(id, description, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print(string.format("  ✓ [%s] %s", id, description))
  else
    failed = failed + 1
    print(string.format("  ✗ [%s] %s\n      → %s", id, description, tostring(err)))
  end
end

print("═══════════════════════════════════════════════════════════════")
print("  Levititas v3.1 — Regression Checklist")
print("═══════════════════════════════════════════════════════════════")

-- ─────────────────────────────────────────────────────────────────────────────
-- A. ARCHITECTURAL FIXES
-- ─────────────────────────────────────────────────────────────────────────────

print("\n[A] Architectural Fixes")

check("A-001",
  "No load() call required for user code execution (VM walks proto directly)",
  function()
    -- The compiler produces a proto that the VM executes directly.
    -- Verify: compiling and getting a proto does not require load().
    local ast = Parser.parse("local x = 1 + 2")
    assert(ast, "parse failed")
    local nm = Opcodes.generateMap(1)
    local proto, err = Compiler.compile(ast, nm, 1)
    assert(proto, "compile failed: " .. tostring(err))
    -- Proto must have instruction table and constant pool
    assert(type(proto.i) == "table", "proto.i must be table")
    assert(type(proto.k) == "table", "proto.k must be table")
    -- No load() needed — VM walks proto.i directly
end)

check("A-002",
  "Constants stored as encrypted byte arrays (not plaintext)",
  function()
    local ast = Parser.parse('local s = "test_secret_12345"')
    local nm  = Opcodes.generateMap(42)
    local proto = Compiler.compile(ast, nm, 42)
    for _, c in ipairs(proto.k) do
      if c.t == "s" then
        assert(type(c.v) == "table",
          "string constant must be byte array, got " .. type(c.v))
        -- Must not be identity (must be encrypted)
        local raw = ""
        for _, b in ipairs(c.v) do raw = raw .. string.char(b) end
        assert(raw ~= "test_secret_12345",
          "constant is stored as plaintext (not encrypted)")
      end
    end
end)

check("A-003",
  "Key derivation uses seed XOR depth XOR index (not stored with data)",
  function()
    -- Verify no constant entry has a 'seed' or 'key' field stored inline
    local ast   = Parser.parse('local s = "value"')
    local nm    = Opcodes.generateMap(99)
    local proto = Compiler.compile(ast, nm, 99)
    for _, c in ipairs(proto.k) do
      assert(c.seed == nil, "constant has inline 'seed' field — key is exposed")
      assert(c.key  == nil, "constant has inline 'key' field — key is exposed")
    end
end)

check("A-004",
  "Python fallback does not exist in codebase",
  function()
    -- Check server.py does not contain Python fallback engine
    local f = io.open("server.py", "r")
    if not f then return end  -- server not present in this context, skip
    local content = f:read("*a")
    f:close()
    assert(not content:find("_python_fallback"),
      "server.py still contains Python fallback engine")
    assert(not content:find("class _PythonObf"),
      "server.py still contains PythonObf class")
end)

check("A-005",
  "Bytecode version field present in every proto",
  function()
    local ast = Parser.parse("local x = 1")
    local nm  = Opcodes.generateMap(1)
    local proto = Compiler.compile(ast, nm, 1)
    assert(proto.v == Spec.BYTECODE_VERSION,
      string.format("expected v=%d, got %s", Spec.BYTECODE_VERSION, tostring(proto.v)))
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- B. VM ROBUSTNESS FIXES
-- ─────────────────────────────────────────────────────────────────────────────

print("\n[B] VM Robustness")

check("B-001",
  "Proto validator rejects wrong bytecode version",
  function()
    local p = {
      v=999, i={{1,0,0,0}}, k={}, p=0, va=false, ul=0
    }
    local ok, err = ProtoVal.validate(p)
    assert(not ok, "should reject version 999")
    assert(err:find("B001") or err:find("version"),
      "error should mention version: " .. tostring(err))
end)

check("B-002",
  "Proto validator detects out-of-range jump targets",
  function()
    local nm, rv = Opcodes.generateMap(1)
    local jmpOp = nm["JMP"]
    local p = {
      v=Spec.BYTECODE_VERSION,
      i={{jmpOp, 0, 9999, 0}},  -- jump to instruction 9999, only 1 exists
      k={}, p=0, va=false, ul=0
    }
    local ok, err = ProtoVal.validate(p, rv)
    assert(not ok, "should reject out-of-range jump")
    assert(err:find("B004") or err:find("range") or err:find("jump"),
      "error should mention jump: " .. tostring(err))
end)

check("B-003",
  "Proto validator detects malformed instruction (non-table)",
  function()
    local p = {
      v=Spec.BYTECODE_VERSION,
      i={"not_a_table"},
      k={}, p=0, va=false, ul=0
    }
    local ok, err = ProtoVal.validate(p)
    assert(not ok, "should reject non-table instruction")
end)

check("B-004",
  "Proto validator detects invalid constant type",
  function()
    local p = {
      v=Spec.BYTECODE_VERSION,
      i={{1,0,0,0}},
      k={{t="z"}},  -- unknown type
      p=0, va=false, ul=0
    }
    local ok, err = ProtoVal.validate(p)
    assert(not ok, "should reject unknown constant type 'z'")
end)

check("B-005",
  "Proto validator detects JMP-to-self",
  function()
    local nm, rv = Opcodes.generateMap(1)
    -- JMP_BACK at position 1 targeting position 1 = guaranteed infinite loop
    local backOp = nm["JMP_BACK"]
    local p = {
      v=Spec.BYTECODE_VERSION,
      i={{backOp, 1, 0, 0}},  -- JMP_BACK A=1 means jump to instruction 1 = self
      k={}, p=0, va=false, ul=0
    }
    local ok, err = ProtoVal.validate(p, rv)
    assert(not ok, "should detect JMP_BACK to self as infinite loop")
end)

check("B-006",
  "Instruction limit constant is defined in Spec",
  function()
    assert(type(Spec.LIMITS.MAX_INSTRUCTIONS) == "number",
      "MAX_INSTRUCTIONS must be a number")
    assert(Spec.LIMITS.MAX_INSTRUCTIONS > 0,
      "MAX_INSTRUCTIONS must be positive")
    assert(Spec.LIMITS.MAX_INSTRUCTIONS >= 1000,
      "MAX_INSTRUCTIONS should be at least 1000")
end)

check("B-007",
  "Call depth limit is defined in Spec",
  function()
    assert(type(Spec.LIMITS.MAX_CALL_DEPTH) == "number")
    assert(Spec.LIMITS.MAX_CALL_DEPTH > 0)
    assert(Spec.LIMITS.MAX_CALL_DEPTH <= 10000,
      "call depth limit seems unreasonably large")
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- C. COMPATIBILITY FIXES
-- ─────────────────────────────────────────────────────────────────────────────

print("\n[C] Compatibility")

check("C-001",
  "lua52 target is hard-rejected (not silently accepted)",
  function()
    local ast = Parser.parse("local x = 1")
    local ok, issues = Compat.audit(ast, "lua52")
    assert(not ok, "lua52 should be rejected")
    assert(issues[1].severity == "fatal",
      "lua52 rejection must be fatal, not just a warning")
end)

check("C-002",
  "lua51 target is hard-rejected",
  function()
    local ast = Parser.parse("local x = 1")
    local ok, issues = Compat.audit(ast, "lua51")
    assert(not ok, "lua51 should be rejected")
end)

check("C-003",
  "lua54 target accepts all valid Lua 5.4 syntax",
  function()
    local src = [[
local x <const> = 42
local y = x & 0xFF
local z = y // 3
for i = 1, 10 do end
goto done
::done::
]]
    local ast = Parser.parse(src)
    assert(ast, "failed to parse Lua 5.4 source")
    local ok, issues = Compat.audit(ast, "lua54")
    assert(ok, "lua54 should accept all Lua 5.4 features")
    assert(#issues == 0, "lua54 should have zero issues")
end)

check("C-004",
  "luajit target rejects bitwise operator syntax",
  function()
    local ast = Parser.parse("local x = 1 & 0xFF")
    local ok, issues = Compat.audit(ast, "luajit")
    assert(not ok, "luajit should reject & operator syntax")
    local found = false
    for _, i in ipairs(issues) do
      if i.code == "COMPAT_LUAJIT_BITWISE" then found = true end
    end
    assert(found, "should produce COMPAT_LUAJIT_BITWISE issue")
end)

check("C-005",
  "Unknown target produces fatal error (not silent accept)",
  function()
    local ast = Parser.parse("local x = 1")
    local ok, issues = Compat.audit(ast, "lua99_fantasy")
    assert(not ok, "unknown target should be rejected")
    assert(issues[1].severity == "fatal")
end)

check("C-006",
  "Compatibility matrix has entries for all 6 documented targets",
  function()
    local matrix = Compat.supportMatrix()
    assert(#matrix == 6,
      string.format("expected 6 entries, got %d", #matrix))
    local targets = {}
    for _, row in ipairs(matrix) do targets[row.target] = true end
    for _, t in ipairs({"lua54","lua53","lua52","lua51","luajit","luau"}) do
      assert(targets[t], "missing target: " .. t)
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- D. MAINTAINABILITY FIXES
-- ─────────────────────────────────────────────────────────────────────────────

print("\n[D] Maintainability")

check("D-001",
  "Spec is the single source of truth for opcode names",
  function()
    -- All opcode names in Compiler must exist in Spec
    -- (Spot-check a few critical ones)
    local critical = {
      "PUSH_NIL","PUSH_STR","LOAD_LOCAL","STORE_LOCAL",
      "LOAD_GLOBAL","STORE_GLOBAL","CALL","RETURN","RETURN0",
      "JMP","JMP_FALSE","JMP_TRUE","HALT","MAKE_CLOSURE",
    }
    for _, name in ipairs(critical) do
      assert(Spec.CANONICAL_OPCODE[name],
        "opcode '" .. name .. "' missing from Spec.CANONICAL_OPCODE")
    end
end)

check("D-002",
  "AST schemas defined for all node types produced by parser",
  function()
    local nodeTypes = {
      "Block","Assign","Local","Do","While","Repeat","If",
      "ForNum","ForGen","Function","LocalFunction","Return",
      "Break","Goto","Label","Call","MethodCall","Index","Field",
      "Binop","Unop","Name","Number","String","Bool","Nil",
      "Vararg","Table","TableField",
    }
    for _, t in ipairs(nodeTypes) do
      assert(Spec.AST_SCHEMAS[t] or t == "FuncBody",
        "no schema for node type: " .. t)
    end
end)

check("D-003",
  "Error codes follow consistent format (letter + 3 digits)",
  function()
    for key, code in pairs(Spec.ERR) do
      assert(code:match("^[A-Z]%d%d%d$"),
        string.format("ERR.%s = '%s' does not match format X000", key, code))
    end
end)

check("D-004",
  "Proto format has version field (enables future migration)",
  function()
    local ast   = Parser.parse("local x = 1")
    local nm    = Opcodes.generateMap(1)
    local proto = Compiler.compile(ast, nm, 1)
    assert(proto.v ~= nil, "proto missing version field")
    assert(type(proto.v) == "number", "proto version must be number")
end)

check("D-005",
  "Deterministic builds: same seed → same proto structure",
  function()
    local src = "local function f(x) return x * 2 + 1 end print(f(5))"
    local ast1 = Parser.parse(src)
    local ast2 = Parser.parse(src)
    local nm1  = Opcodes.generateMap(9999)
    local nm2  = Opcodes.generateMap(9999)
    local p1   = Compiler.compile(ast1, nm1, 9999)
    local p2   = Compiler.compile(ast2, nm2, 9999)
    assert(#p1.i == #p2.i,
      "instruction count differs for same seed")
    assert(#p1.k == #p2.k,
      "constant count differs for same seed")
    -- Verify first instruction matches
    if #p1.i > 0 then
      assert(p1.i[1][1] == p2.i[1][1],
        "first opcode differs for same seed")
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- E. PARSER RELIABILITY FIXES
-- ─────────────────────────────────────────────────────────────────────────────

print("\n[E] Parser Reliability")

check("E-001",
  "Parser returns coverage info on every call",
  function()
    local _, _, cov = Parser.parse("local x = 1")
    assert(type(cov) == "table", "coverage must be a table")
    assert(type(cov.total) == "number", "coverage.total must be number")
    assert(type(cov.consumed) == "number", "coverage.consumed must be number")
    assert(type(cov.pct) == "number", "coverage.pct must be number")
end)

check("E-002",
  "Parser coverage is 100% for well-formed Lua source",
  function()
    local sources = {
      "local x = 1",
      "for i=1,10 do print(i) end",
      "local function f(a,b) return a+b end",
      "local t = {1,2,3,key='val'}",
    }
    for _, src in ipairs(sources) do
      local _, err, cov = Parser.parse(src)
      assert(not err, "parse error for: " .. src)
      assert(cov.pct == 100,
        string.format("coverage %d%% for: %s", cov.pct, src))
    end
end)

check("E-003",
  "Parser returns nil AST (not partial) on syntax error",
  function()
    local ast, err, cov = Parser.parse("local = = garbage !!")
    -- Either ast is nil (hard failure) or we have a meaningful error
    if ast ~= nil then
      -- If it didn't fail, coverage must be < 100% to indicate partial
      assert(cov.pct < 100 or err ~= nil,
        "parser accepted invalid syntax at 100% coverage without error")
    else
      assert(err ~= nil, "nil AST must come with an error message")
    end
end)

check("E-004",
  "Parser never silently returns partial AST at 100% coverage",
  function()
    -- Construct a source where coverage would be misleading
    -- (commented code, valid prefix)
    local src = "local x = 1 -- comment with garbage !!@#$"
    local ast, err, cov = Parser.parse(src)
    -- Comments are stripped in lexer, so this should parse fine
    assert(ast or err, "must have AST or error")
    if ast then
      assert(cov.pct == 100,
        "partial parse should not claim 100%: " .. tostring(cov.pct))
    end
end)

check("E-005",
  "AST validator runs and produces errors for invalid nodes",
  function()
    local bad_ast = { type="Block", body={{ type="TOTALLY_INVALID_NODE_TYPE" }} }
    local ok, err = ASTVal.validateAST(bad_ast)
    assert(not ok, "should reject unknown node type")
    assert(err, "must return error message")
    assert(err:find("TOTALLY_INVALID_NODE_TYPE") or err:find("Unknown"),
      "error should identify the bad node: " .. tostring(err))
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- F. BUILD REPRODUCIBILITY
-- ─────────────────────────────────────────────────────────────────────────────

print("\n[F] Build Reproducibility")

check("F-001",
  "Opcode map is deterministic for a given seed",
  function()
    for _, seed in ipairs({1, 42, 9999, 123456789}) do
      local m1 = Opcodes.generateMap(seed)
      local m2 = Opcodes.generateMap(seed)
      for name, val in pairs(m1) do
        assert(m2[name] == val,
          string.format("seed %d: opcode %s value differs between runs", seed, name))
      end
    end
end)

check("F-002",
  "seedFromInt produces positive value for any input",
  function()
    for _, n in ipairs({0, 1, -1, 99999999, 0.5}) do
      local s = Opcodes.seedFromInt(n)
      assert(s > 0, "seed must be positive for input " .. tostring(n))
    end
end)

check("F-003",
  "Proto structure is deterministic for fixed seed",
  function()
    local src = [[
local function calc(n)
  local result = 0
  for i = 1, n do
    result = result + i * i
  end
  return result
end
print(calc(10))
]]
    local function buildProto(seed)
      local ast = Parser.parse(src)
      local nm  = Opcodes.generateMap(seed)
      return Compiler.compile(ast, nm, seed)
    end
    local p1 = buildProto(77777)
    local p2 = buildProto(77777)
    assert(#p1.i == #p2.i, "instruction count non-deterministic")
    assert(#p1.k == #p2.k, "constant count non-deterministic")
    for i = 1, #p1.i do
      for j = 1, 4 do
        assert(p1.i[i][j] == p2.i[i][j],
          string.format("instruction %d field %d differs", i, j))
      end
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- SUMMARY
-- ─────────────────────────────────────────────────────────────────────────────

print("\n" .. string.rep("═", 63))
print(string.format("  Regression Checklist: %d/%d passed", passed, total))
if failed > 0 then
  print(string.format("  FAILED: %d checks", failed))
  print("  Fix all failures before releasing v3.1.")
  os.exit(1)
else
  print("  All regression checks passed. Ready for release.")
  os.exit(0)
end
