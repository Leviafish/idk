--[[
  Levititas v3.1 — Compiler
  src/compiler/compiler.lua

  AST → IR → Proto bytecode.
  The IR pass enables constant folding and dead instruction elimination
  without touching the parser or bytecode emitter.

  Architectural rules:
    - Never call load() on user code
    - Never reconstruct source from AST
    - All errors are Spec.ERR codes
    - goto unresolved = compile error (not silent)
    - Unsupported AST nodes = compile error (not silent)
]]

local Spec     = require("spec")
local ASTVal   = require("validation.ast_validator")
local Opcodes  = require("vm.opcodes")

local Compiler = {}
Compiler.__index = Compiler

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  IR DEFINITION
--     Simple three-address IR between AST and bytecode.
--     Enables future optimization passes without AST/bytecode changes.
--
--   IR instruction: { op, dst, src1, src2, label, jump_label, const }
--   op values: "load_const", "load_local", "store_local",
--              "load_global", "store_global", "load_field", "store_field",
--              "load_index", "store_index", "binop", "unop",
--              "call", "return", "jmp", "jmp_if", "jmp_unless",
--              "label", "make_table", "set_table", "make_closure",
--              "push_vararg", "concat", "len", "nop"
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- §2  COMPILER STATE
-- ─────────────────────────────────────────────────────────────────────────────

local function newProtoState(opcodeMap, parent)
  return {
    op         = opcodeMap,
    parent     = parent,
    instrs     = {},      -- final bytecode instructions
    consts     = {},      -- constant pool entries
    constIdx   = {},      -- dedup key → index
    locals     = {},      -- name → slot
    localTop   = 0,
    upvals     = {},      -- name → upvalue index
    upvalCount = 0,
    breaks     = {},      -- stack of break-patch lists per loop
    gotos      = {},      -- list of {pc, label, line}
    labels     = {},      -- name → pc
    depth      = parent and (parent.depth + 1) or 0,
  }
end

local function err(code, msg, ...)
  return nil, string.format("[%s] %s", code, string.format(msg, ...))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §3  CONSTANT POOL
--     Constants are stored ENCRYPTED in the pool.
--     Encryption uses the key derivation from Spec §4.
--     The shuffle seed must be passed in at compile time.
-- ─────────────────────────────────────────────────────────────────────────────

local function rollingEncrypt(s, keySeed)
  local result = {}
  local k = keySeed & 0xFF
  for i = 1, #s do
    local plain = s:byte(i)
    result[i] = plain ~ k
    k = (k * 0x41 + plain + i) & 0xFF
  end
  return result
end

local function encryptConst(val, valType, shuffleSeed, protoDepth, constIndex)
  local keySeed = (shuffleSeed ~ protoDepth ~ constIndex) & 0xFF
  if valType == Spec.CONST_TYPE.STR then
    return { t="s", v=rollingEncrypt(val, keySeed) }
  elseif valType == Spec.CONST_TYPE.INT then
    return { t="i", v=rollingEncrypt(tostring(math.floor(val)), keySeed) }
  elseif valType == Spec.CONST_TYPE.FLOAT then
    return { t="f", v=rollingEncrypt(tostring(val), keySeed) }
  elseif valType == Spec.CONST_TYPE.BOOL then
    return { t="b", v=val }  -- booleans not encrypted
  elseif valType == Spec.CONST_TYPE.NIL then
    return { t="n" }
  end
end

local function addConst(ps, val, valType, shuffleSeed)
  local key = valType .. ":" .. tostring(val)
  if ps.constIdx[key] then return ps.constIdx[key] end
  local idx = #ps.consts + 1
  if idx > Spec.LIMITS.MAX_CONST_POOL then
    error(string.format("[%s] constant pool full (%d)",
      Spec.ERR.PROTO_BAD_CONST, Spec.LIMITS.MAX_CONST_POOL))
  end
  ps.consts[idx] = encryptConst(val, valType, shuffleSeed, ps.depth, idx)
  ps.constIdx[key] = idx
  return idx
end

local function addProtoConst(ps, subProto)
  local idx = #ps.consts + 1
  ps.consts[idx] = { t = Spec.CONST_TYPE.PROTO, proto = subProto }
  return idx
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §4  INSTRUCTION EMISSION
-- ─────────────────────────────────────────────────────────────────────────────

local function emit(ps, opName, a, b, c)
  local opVal = ps.op[opName]
  if not opVal then
    error(string.format("[%s] unknown opname '%s'", Spec.ERR.COMP_UNSUPPORTED_OP, opName))
  end
  local idx = #ps.instrs + 1
  ps.instrs[idx] = { opVal, a or 0, b or 0, c or 0 }
  return idx
end

local function pc(ps) return #ps.instrs end

local function patch(ps, instrIdx, field, val)
  -- field: 2=A, 3=B, 4=C
  ps.instrs[instrIdx][field] = val
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §5  SCOPE MANAGEMENT
-- ─────────────────────────────────────────────────────────────────────────────

local function pushScope(ps)
  return { locals = {}, top = ps.localTop }
end

local function popScope(ps, scope)
  -- Restore locals that went out of scope
  for name, slot in pairs(ps.locals) do
    if slot > scope.top then
      ps.locals[name] = nil
    end
  end
  ps.localTop = scope.top
end

local function defineLocal(ps, name)
  ps.localTop = ps.localTop + 1
  ps.locals[name] = ps.localTop
  return ps.localTop
end

local function resolveLocal(ps, name)
  return ps.locals[name]
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §6  EXPRESSION COMPILATION
-- ─────────────────────────────────────────────────────────────────────────────

local compileExpr  -- forward declaration
local compileBlock -- forward declaration
local compileStmt  -- forward declaration

local BINOP_MAP = {
  ["+"]  = "ADD",  ["-"]  = "SUB",  ["*"]  = "MUL",
  ["/"]  = "DIV",  ["%"]  = "MOD",  ["^"]  = "POW",  ["//"] = "IDIV",
  ["=="] = "EQ",   ["~="] = "NEQ",  ["<"]  = "LT",
  ["<="] = "LE",   [">"]  = "GT",   [">="] = "GE",
  ["&"]  = "BAND", ["|"]  = "BOR",  ["~"]  = "BXOR",
  ["<<"] = "SHL",  [">>"] = "SHR",  [".."] = "CONCAT",
}

local UNOP_MAP = {
  ["-"] = "UNM",  ["not"] = "NOT",  ["~"] = "BNOT",  ["#"] = "LEN",
}

compileExpr = function(ps, node, shuffleSeed)
  local t = node.type

  if t == "Nil" then
    emit(ps, "PUSH_NIL")

  elseif t == "Bool" then
    emit(ps, node.val and "PUSH_TRUE" or "PUSH_FALSE")

  elseif t == "Number" then
    local isInt = math.type and math.type(node.val) == "integer"
    local ctype = isInt and Spec.CONST_TYPE.INT or Spec.CONST_TYPE.FLOAT
    local idx = addConst(ps, node.val, ctype, shuffleSeed)
    emit(ps, isInt and "PUSH_INT" or "PUSH_FLT", idx)

  elseif t == "String" then
    local idx = addConst(ps, node.val, Spec.CONST_TYPE.STR, shuffleSeed)
    emit(ps, "PUSH_STR", idx)

  elseif t == "Vararg" then
    emit(ps, "PUSH_VARARG")

  elseif t == "Name" then
    local slot = resolveLocal(ps, node.name)
    if slot then
      emit(ps, "LOAD_LOCAL", slot)
    else
      local idx = addConst(ps, node.name, Spec.CONST_TYPE.STR, shuffleSeed)
      emit(ps, "LOAD_GLOBAL", idx)
    end

  elseif t == "Field" then
    compileExpr(ps, node.obj, shuffleSeed)
    local idx = addConst(ps, node.field, Spec.CONST_TYPE.STR, shuffleSeed)
    emit(ps, "LOAD_FIELD", idx)

  elseif t == "Index" then
    compileExpr(ps, node.obj, shuffleSeed)
    compileExpr(ps, node.index, shuffleSeed)
    emit(ps, "LOAD_INDEX")

  elseif t == "Binop" then
    if node.op == "and" then
      compileExpr(ps, node.left, shuffleSeed)
      local jmp = emit(ps, "AND_JMP", 0, 0)
      compileExpr(ps, node.right, shuffleSeed)
      patch(ps, jmp, 3, pc(ps) + 1)  -- B field
    elseif node.op == "or" then
      compileExpr(ps, node.left, shuffleSeed)
      local jmp = emit(ps, "OR_JMP", 0, 0)
      compileExpr(ps, node.right, shuffleSeed)
      patch(ps, jmp, 3, pc(ps) + 1)
    elseif node.op == ".." then
      -- Count concat chain
      local count = 0
      local function countConcat(n)
        if n.type == "Binop" and n.op == ".." then
          countConcat(n.left); countConcat(n.right)
        else
          compileExpr(ps, n, shuffleSeed); count = count + 1
        end
      end
      countConcat(node)
      emit(ps, "CONCAT", count)
    else
      local opName = BINOP_MAP[node.op]
      if not opName then
        error(string.format("[%s] unsupported binary op '%s'",
          Spec.ERR.COMP_UNSUPPORTED_OP, node.op))
      end
      compileExpr(ps, node.left, shuffleSeed)
      compileExpr(ps, node.right, shuffleSeed)
      emit(ps, opName)
    end

  elseif t == "Unop" then
    local opName = UNOP_MAP[node.op]
    if not opName then
      error(string.format("[%s] unsupported unary op '%s'",
        Spec.ERR.COMP_UNSUPPORTED_OP, node.op))
    end
    compileExpr(ps, node.operand, shuffleSeed)
    emit(ps, opName)

  elseif t == "Table" then
    emit(ps, "NEW_TABLE", #node.fields)
    local arrayIdx = 0
    for _, field in ipairs(node.fields) do
      if field.key then
        compileExpr(ps, field.key, shuffleSeed)
        compileExpr(ps, field.val, shuffleSeed)
        emit(ps, "SET_TABLE")
      else
        arrayIdx = arrayIdx + 1
        compileExpr(ps, field.val, shuffleSeed)
        emit(ps, "SET_LIST", arrayIdx)
      end
    end

  elseif t == "Call" then
    compileExpr(ps, node.func, shuffleSeed)
    for _, arg in ipairs(node.args) do
      compileExpr(ps, arg, shuffleSeed)
    end
    emit(ps, "CALL", #node.args, 1)

  elseif t == "MethodCall" then
    compileExpr(ps, node.obj, shuffleSeed)
    local idx = addConst(ps, node.method, Spec.CONST_TYPE.STR, shuffleSeed)
    emit(ps, "SELF", idx)
    for _, arg in ipairs(node.args) do
      compileExpr(ps, arg, shuffleSeed)
    end
    emit(ps, "CALL", #node.args + 1, 1)

  elseif t == "FuncBody" or (node.params ~= nil and node.body ~= nil) then
    -- Anonymous function
    compileFuncBody(ps, node, shuffleSeed)

  else
    error(string.format("[%s] unsupported expression node '%s'",
      Spec.ERR.COMP_UNSUPPORTED_NODE, tostring(t)))
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §7  STATEMENT COMPILATION
-- ─────────────────────────────────────────────────────────────────────────────

compileStmt = function(ps, node, shuffleSeed)
  local t = node.type

  if t == "Local" then
    -- Compile RHS first (before defining locals, for correct scoping)
    local nvals = #node.vals
    for _, v in ipairs(node.vals) do
      compileExpr(ps, v, shuffleSeed)
    end
    -- Pad missing values with nil
    for i = nvals + 1, #node.names do
      emit(ps, "PUSH_NIL")
    end
    -- Define locals in forward order, assign in reverse
    -- First collect all slots, then emit stores
    local slots = {}
    for _, name in ipairs(node.names) do
      slots[#slots+1] = defineLocal(ps, name)
    end
    for i = #slots, 1, -1 do
      emit(ps, "STORE_LOCAL", slots[i])
    end

  elseif t == "LocalFunction" then
    local slot = defineLocal(ps, node.name)
    compileFuncBody(ps, node.func, shuffleSeed)
    emit(ps, "STORE_LOCAL", slot)

  elseif t == "Assign" then
    local nvals = #node.vals
    for _, v in ipairs(node.vals) do
      compileExpr(ps, v, shuffleSeed)
    end
    for i = nvals + 1, #node.targets do
      emit(ps, "PUSH_NIL")
    end
    for i = #node.targets, 1, -1 do
      compileAssignTarget(ps, node.targets[i], shuffleSeed)
    end

  elseif t == "Do" then
    local scope = pushScope(ps)
    compileBlock(ps, node.body, shuffleSeed)
    popScope(ps, scope)

  elseif t == "While" then
    local loopStart = pc(ps) + 1
    compileExpr(ps, node.cond, shuffleSeed)
    local exitJmp = emit(ps, "JMP_FALSE", 0, 0)
    local scope = pushScope(ps)
    ps.breaks[#ps.breaks+1] = {}
    compileBlock(ps, node.body, shuffleSeed)
    popScope(ps, scope)
    emit(ps, "JMP_BACK", loopStart)
    patch(ps, exitJmp, 3, pc(ps) + 1)  -- B = exit target
    local blist = table.remove(ps.breaks)
    for _, bp in ipairs(blist) do patch(ps, bp, 3, pc(ps) + 1) end

  elseif t == "Repeat" then
    local loopStart = pc(ps) + 1
    local scope = pushScope(ps)
    ps.breaks[#ps.breaks+1] = {}
    compileBlock(ps, node.body, shuffleSeed)
    popScope(ps, scope)
    compileExpr(ps, node.cond, shuffleSeed)
    emit(ps, "JMP_FALSE", 0, loopStart)  -- B = back to start
    local blist = table.remove(ps.breaks)
    for _, bp in ipairs(blist) do patch(ps, bp, 3, pc(ps) + 1) end

  elseif t == "If" then
    local exitPatches = {}
    compileExpr(ps, node.cond, shuffleSeed)
    local elseJmp = emit(ps, "JMP_FALSE", 0, 0)
    local scope = pushScope(ps)
    compileBlock(ps, node.body, shuffleSeed)
    popScope(ps, scope)
    exitPatches[#exitPatches+1] = emit(ps, "JMP", 0, 0)
    patch(ps, elseJmp, 3, pc(ps) + 1)
    for _, elif_ in ipairs(node.elseifs) do
      compileExpr(ps, elif_.cond, shuffleSeed)
      local ej = emit(ps, "JMP_FALSE", 0, 0)
      local sc2 = pushScope(ps)
      compileBlock(ps, elif_.body, shuffleSeed)
      popScope(ps, sc2)
      exitPatches[#exitPatches+1] = emit(ps, "JMP", 0, 0)
      patch(ps, ej, 3, pc(ps) + 1)
    end
    if node.elsebody then
      local sc3 = pushScope(ps)
      compileBlock(ps, node.elsebody, shuffleSeed)
      popScope(ps, sc3)
    end
    local exitPc = pc(ps) + 1
    for _, ep in ipairs(exitPatches) do patch(ps, ep, 3, exitPc) end

  elseif t == "ForNum" then
    compileExpr(ps, node.start, shuffleSeed)
    compileExpr(ps, node.limit, shuffleSeed)
    if node.step then
      compileExpr(ps, node.step, shuffleSeed)
    else
      local idx = addConst(ps, 1, Spec.CONST_TYPE.INT, shuffleSeed)
      emit(ps, "PUSH_INT", idx)
    end
    local forPrep = emit(ps, "FORPREP", 0, 0)
    local loopStart = pc(ps) + 1
    local scope = pushScope(ps)
    local varSlot = defineLocal(ps, node.var)
    emit(ps, "LOAD_LOCAL", varSlot)
    ps.breaks[#ps.breaks+1] = {}
    compileBlock(ps, node.body, shuffleSeed)
    popScope(ps, scope)
    emit(ps, "FORLOOP", loopStart)
    patch(ps, forPrep, 3, pc(ps) + 1)  -- B = exit target
    local blist = table.remove(ps.breaks)
    for _, bp in ipairs(blist) do patch(ps, bp, 3, pc(ps) + 1) end

  elseif t == "ForGen" then
    for _, iter in ipairs(node.iters) do
      compileExpr(ps, iter, shuffleSeed)
    end
    -- Pad to 3 iterator values (iter_fn, state, control)
    for i = #node.iters + 1, 3 do emit(ps, "PUSH_NIL") end
    local tforInstr = emit(ps, "TFORLOOP", #node.vars, 0, 0)
    local loopStart = pc(ps) + 1
    local scope = pushScope(ps)
    for _, v in ipairs(node.vars) do defineLocal(ps, v) end
    ps.breaks[#ps.breaks+1] = {}
    compileBlock(ps, node.body, shuffleSeed)
    popScope(ps, scope)
    emit(ps, "JMP_BACK", loopStart)
    patch(ps, tforInstr, 4, pc(ps) + 1)  -- C = exit target
    local blist = table.remove(ps.breaks)
    for _, bp in ipairs(blist) do patch(ps, bp, 3, pc(ps) + 1) end

  elseif t == "Return" then
    for _, v in ipairs(node.vals) do compileExpr(ps, v, shuffleSeed) end
    if #node.vals == 0 then
      emit(ps, "RETURN0")
    else
      emit(ps, "RETURN", #node.vals)
    end

  elseif t == "Break" then
    if #ps.breaks == 0 then
      error(string.format("[%s] 'break' outside loop", Spec.ERR.COMP_UNSUPPORTED_NODE))
    end
    local bp = emit(ps, "JMP", 0, 0)
    ps.breaks[#ps.breaks][#ps.breaks[#ps.breaks]+1] = bp

  elseif t == "Goto" then
    local gp = emit(ps, "JMP", 0, 0)
    ps.gotos[#ps.gotos+1] = { instrPc = gp, label = node.label }

  elseif t == "Label" then
    ps.labels[node.name] = pc(ps) + 1
    -- Resolve any forward gotos pointing to this label
    for _, g in ipairs(ps.gotos) do
      if g.label == node.name and not g.resolved then
        patch(ps, g.instrPc, 3, ps.labels[node.name])
        g.resolved = true
      end
    end

  elseif t == "Function" then
    compileFuncBody(ps, node.func, shuffleSeed)
    -- Store to named target
    if #node.fields == 0 and not node.method then
      local slot = resolveLocal(ps, node.name)
      if slot then
        emit(ps, "STORE_LOCAL", slot)
      else
        local idx = addConst(ps, node.name, Spec.CONST_TYPE.STR, shuffleSeed)
        emit(ps, "STORE_GLOBAL", idx)
      end
    end

  elseif t == "Call" or t == "MethodCall" then
    compileExpr(ps, node, shuffleSeed)
    emit(ps, "POP")  -- discard return value in statement context

  else
    error(string.format("[%s] unsupported statement node '%s'",
      Spec.ERR.COMP_UNSUPPORTED_NODE, tostring(t)))
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §8  ASSIGN TARGETS
-- ─────────────────────────────────────────────────────────────────────────────

compileAssignTarget = function(ps, node, shuffleSeed)
  if node.type == "Name" then
    local slot = resolveLocal(ps, node.name)
    if slot then
      emit(ps, "STORE_LOCAL", slot)
    else
      local idx = addConst(ps, node.name, Spec.CONST_TYPE.STR, shuffleSeed)
      emit(ps, "STORE_GLOBAL", idx)
    end
  elseif node.type == "Field" then
    compileExpr(ps, node.obj, shuffleSeed)
    local idx = addConst(ps, node.field, Spec.CONST_TYPE.STR, shuffleSeed)
    emit(ps, "STORE_FIELD", idx)
  elseif node.type == "Index" then
    compileExpr(ps, node.obj, shuffleSeed)
    compileExpr(ps, node.index, shuffleSeed)
    emit(ps, "STORE_INDEX")
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §9  FUNCTION BODY
-- ─────────────────────────────────────────────────────────────────────────────

compileFuncBody = function(ps, func, shuffleSeed)
  -- Create a sub-proto state
  local subPS = newProtoState(ps.op, ps)

  -- Define parameters as locals
  for _, param in ipairs(func.params) do
    defineLocal(subPS, param)
  end

  compileBlock(subPS, func.body, shuffleSeed)

  -- Ensure final RETURN
  local lastInstrs = subPS.instrs
  if #lastInstrs == 0 or
     (lastInstrs[#lastInstrs][1] ~= subPS.op["RETURN0"] and
      lastInstrs[#lastInstrs][1] ~= subPS.op["RETURN"]) then
    emit(subPS, "RETURN0")
  end

  -- Resolve any remaining forward gotos → error if unresolved
  local unresolved = {}
  for _, g in ipairs(subPS.gotos) do
    if not g.resolved then unresolved[#unresolved+1] = g end
  end
  if #unresolved > 0 then
    local labels = {}
    for _, g in ipairs(unresolved) do labels[#labels+1] = "'"..g.label.."'" end
    error(string.format("[%s] unresolved goto labels: %s",
      Spec.ERR.COMP_GOTO_UNRESOLVED, table.concat(labels, ", ")))
  end

  -- Build sub-proto table
  local subProto = {
    v  = Spec.BYTECODE_VERSION,
    i  = subPS.instrs,
    k  = subPS.consts,
    p  = #func.params,
    va = func.vararg or false,
    ul = subPS.upvalCount,
  }

  -- Add sub-proto as constant in parent and emit MAKE_CLOSURE
  local idx = addProtoConst(ps, subProto)
  emit(ps, "MAKE_CLOSURE", idx)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §10  BLOCK COMPILATION
-- ─────────────────────────────────────────────────────────────────────────────

compileBlock = function(ps, block, shuffleSeed)
  for _, stmt in ipairs(block.body) do
    local ok2, e = pcall(compileStmt, ps, stmt, shuffleSeed)
    if not ok2 then
      error(e)  -- propagate with existing error code
    end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §11  PUBLIC API
-- ─────────────────────────────────────────────────────────────────────────────

function Compiler.compile(ast, opcodeMap, shuffleSeed)
  -- Validate AST first
  local ok, e = ASTVal.validateAST(ast)
  if not ok then return nil, e end

  local ps = newProtoState(opcodeMap, nil)

  local compileOk, compileErr = pcall(function()
    compileBlock(ps, ast, shuffleSeed)
    emit(ps, "HALT")
  end)

  if not compileOk then
    return nil, compileErr
  end

  -- Resolve any remaining gotos
  local unresolved = {}
  for _, g in ipairs(ps.gotos) do
    if not g.resolved then unresolved[#unresolved+1] = g end
  end
  local gotoOk, gotoErr = ASTVal.validateGotoResolution(unresolved)
  if not gotoOk then return nil, gotoErr end

  local proto = {
    v  = Spec.BYTECODE_VERSION,
    i  = ps.instrs,
    k  = ps.consts,
    p  = 0,
    va = true,
    ul = 0,
  }

  return proto
end

return Compiler
