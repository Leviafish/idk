--[[
  Levititas v3.3 — Main Engine
  src/levititas.lua

  Orchestrates: Parser → Compat → Validator → Compiler → VM
  No Python fallback. No load() on user code. Single engine only.
]]

local Spec     = require("spec")
local Parser   = require("parser.parser")
local ASTVal   = require("validation.ast_validator")
local ProtoVal = require("validation.proto_validator")
local Compiler = require("compiler.compiler")
local Compat   = require("compat.compat")
local Opcodes  = require("vm.opcodes")
local VMCore   = require("vm.core")

local Levititas = {}
Levititas.__index = Levititas

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  CRC32 (for source hash, used in seed derivation)
-- ─────────────────────────────────────────────────────────────────────────────

local CRC_T = (function()
  local t = {}
  for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
      if c & 1 ~= 0 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
    end
    t[i] = c
  end
  return t
end)()

local function crc32(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do
    c = (c >> 8) ~ CRC_T[(c ~ s:byte(i)) & 0xFF]
  end
  return (c ~ 0xFFFFFFFF) & 0xFFFFFFFF
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §2  PROTO SERIALIZER
--     Serializes a compiled proto to a self-contained Lua table literal.
--     The VM interpreter is embedded alongside.
-- ─────────────────────────────────────────────────────────────────────────────

local function serializeBytes(t)
  local parts = {}
  for _, b in ipairs(t) do parts[#parts+1] = tostring(b) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function serializeConst(c)
  local t = c.t
  if t == "n" then
    return '{t="n"}'
  elseif t == "b" then
    return string.format('{t="b",v=%s}', tostring(c.v))
  elseif t == "i" or t == "f" or t == "s" then
    return string.format('{t=%q,v=%s}', t, serializeBytes(c.v))
  elseif t == "p" then
    return string.format('{t="p",proto=%s}', serializeProto(c.proto))
  end
  return '{t="n"}'
end

function serializeProto(proto)
  -- Instructions
  local instrParts = {}
  for _, instr in ipairs(proto.i) do
    instrParts[#instrParts+1] = string.format("{%d,%d,%d,%d}",
      instr[1], instr[2], instr[3], instr[4])
  end

  -- Constants
  local constParts = {}
  for _, c in ipairs(proto.k) do
    constParts[#constParts+1] = serializeConst(c)
  end

  return string.format("{v=%d,i={%s},k={%s},p=%d,va=%s,ul=%d}",
    proto.v,
    table.concat(instrParts, ","),
    table.concat(constParts, ","),
    proto.p,
    tostring(proto.va),
    proto.ul)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §3  INTERPRETER EMITTER
--     Emits the self-contained VM interpreter as Lua source.
--     All internal identifiers are randomized.
--     Uses dispatch table (O(1)), no load() on user code.
-- ─────────────────────────────────────────────────────────────────────────────

local function makeIdGen(rng)
  local style = (rng() % 3)
  return function()
    if style == 0 then
      local s = "_"
      for _ = 1, 8 + (rng() % 6) do
        s = s .. (rng() % 2 == 0 and "l" or "I")
      end
      return s
    elseif style == 1 then
      return "_0x" .. string.format("%08X", rng() & 0xFFFFFFFF)
    else
      local parts = {"_","__","lI","Il","II","ll"}
      local s = parts[(rng() % #parts) + 1]
      for _ = 1, 3 + (rng() % 4) do
        s = s .. parts[(rng() % #parts) + 1]
      end
      return s
    end
  end
end

local function emitInterpreter(opcodeMap, protoLiteral, shuffleSeed, rng)
  local R = makeIdGen(rng)

  -- All the identifiers we need
  local PROTO   = R(); local EXEC    = R(); local STATE   = R()
  local INSTRS  = R(); local CONSTS  = R(); local PC      = R()
  local INSTR   = R(); local OP      = R(); local AA      = R()
  local BB      = R(); local CC      = R(); local STACK   = R()
  local STKTOP  = R(); local LOCALS  = R(); local ENV     = R()
  local ICOUNT  = R(); local MAXIC   = R(); local DISPATCH= R()
  local CACHE   = R(); local SEED    = R(); local DEPTH   = R()
  local CALLDEP = R(); local RESULT  = R(); local DONE    = R()

  -- Stdlib cached at top of generated file
  local lines = {}
  lines[#lines+1] = "-- Levititas v3.3 | build " ..
    string.format("%08X", rng() & 0xFFFFFFFF) ..
    " | seed " .. tostring(shuffleSeed)
  lines[#lines+1] = "do"

  -- Cache stdlib
  local RC = R(); local RG = R(); local TU = R(); local TC = R()
  local SC = R(); local SB = R(); local TY = R(); local TS = R()
  local PC2= R(); local SM = R(); local MT = R(); local GM = R()
  lines[#lines+1] = string.format(
    "local %s,  %s,  %s,  %s,  %s,  %s,  %s,  %s,  %s,  %s,  %s,  %s = " ..
    "rawget,rawset,table.unpack,table.concat,string.char,string.byte," ..
    "type,tostring,pcall,math.floor,setmetatable,getmetatable",
    RC, RG, TU, TC, SC, SB, TY, TS, PC2, SM, MT, GM)

  -- Opcode reverse map (value → name) for dispatch
  local revLines = {}
  for name, val in pairs(opcodeMap) do
    revLines[#revLines+1] = string.format("[%d]=%q", val, name)
  end

  -- The proto
  lines[#lines+1] = string.format("local %s = %s", PROTO, protoLiteral)

  -- Key derivation function
  local KD = R(); local KA = R(); local KB = R(); local KC2 = R()
  local KE = R(); local KF = R(); local KG = R()
  lines[#lines+1] = string.format([[
local function %s(%s, %s, %s)
  return (%s ~ %s ~ %s) & 0xFF
end]], KD, KA, KB, KC2, KA, KB, KC2)

  -- Decrypt function (lazy, caches result)
  local DC = R(); local DA = R(); local DB = R(); local DE = R()
  local DF = R(); local DG = R(); local DH = R(); local DI = R()
  local DJ = R()
  lines[#lines+1] = string.format([[
local function %s(%s, %s, %s, %s)
  if %s._d ~= nil then return %s._d end
  local %s = %s(%s, %s, %s) & 0xFF
  local %s = {}
  for %s = 1, #%s.v do
    local %s = %s.v[%s] ~ (%s & 0xFF)
    %s[%s] = %s(%s)
    %s = (%s * 0x41 + %s + %s) & 0xFF
  end
  local %s = %s(%s)
  %s._d = %s
  return %s
end]],
    DC, DA, DB, DE, DF,  -- function DC(DA, DB, DE, DF)
    DA, DA,              -- if DA._d ~= nil
    DG, KD, DF, DE, DB, -- local DG = KD(DF, DE, DB)
    DH,                  -- local DH = {}
    DI, DA,              -- for DI = 1, #DA.v
    DJ, DA, DI, DG,      -- local DJ = DA.v[DI] ~ (DG & 0xFF)
    DH, DI, SC, DJ,      -- DH[DI] = SC(DJ)
    DG, DG, DJ, DI,      -- DG = (DG * 0x41 + DJ + DI) & 0xFF
    DJ, TC, DH,          -- local DJ = TC(DH)
    DA, DJ,              -- DA._d = DJ
    DJ)                  -- return DJ


  print("EXEC", EXEC)
print("PROTO", PROTO)
print("LOCALS", LOCALS)
print("ENV", ENV)
print("SEED", SEED)
print("DEPTH", DEPTH)
print("MAXIC", MAXIC)
  -- Execution loop
local fmtOk, fmtRes = pcall(string.format,
local function %s(%s, %s, %s, %s, %s, %s)
  local %s = %s.i
  local %s = %s.k
  local %s = {}
  local %s = 0
  local %s = 1
  local %s = false
  local %s = nil
  while not %s do
    %s = %s + 1
    if %s > %s then error("[R001] instruction limit exceeded", 0) end
    if %s < 1 or %s > #%s then error("[R004] invalid PC", 0) end
    %s = %s[%s]
    %s = %s + 1
    local %s = %s[1]
    local %s = %s[2]
    local %s = %s[3]
    local %s = %s[4]
]],

print("FORMAT OK =", ok)
print(res)
lines[#lines+1] = res
    EXEC, PROTO, LOCALS, ENV, SEED, DEPTH, MAXIC,
    INSTRS, PROTO, CONSTS, PROTO,
    STACK, STKTOP, PC, DONE, RESULT,
    DONE,
    ICOUNT, ICOUNT, MAXIC,  -- counter check
    PC, PC, INSTRS,          -- bounds check
    INSTR, INSTRS, PC,
    PC, PC,
    OP, INSTR,
    AA, INSTR,
    BB, INSTR,
    CC, INSTR)

  -- Emit dispatch cases
  local function getConst(idxVar)
    return string.format("%s(%s[%s],%s,%s,%s)",
      DC, CONSTS, idxVar, SEED, DEPTH, idxVar)
  end
  local function push(v)
    return string.format("%s=%s+1;%s[%s]=%s", STKTOP,STKTOP,STACK,STKTOP,v)
  end
  local function pop()
    return string.format("(function()local _v=%s[%s];%s[%s]=nil;%s=%s-1;return _v end)()",
      STACK,STKTOP,STACK,STKTOP,STKTOP,STKTOP)
  end
  local function top(off)
    if off and off ~= 0 then
      return string.format("%s[%s-%s]", STACK, STKTOP, tostring(math.abs(off)))
    end
    return string.format("%s[%s]", STACK, STKTOP)
  end

  local function case(opName, body)
    local val = opcodeMap[opName]
    if not val then return end
    lines[#lines+1] = string.format("    if %s==%d then -- %s", OP, val, opName)
    lines[#lines+1] = "      " .. body
    lines[#lines+1] = "    end"
  end

  -- All opcode cases
  case("PUSH_NIL",    push("nil"))
  case("PUSH_TRUE",   push("true"))
  case("PUSH_FALSE",  push("false"))
  case("PUSH_INT",    push(getConst(AA)))
  case("PUSH_FLT",    push(getConst(AA)))
  case("PUSH_STR",    push(getConst(AA)))
  case("POP",         string.format("%s[%s]=nil;%s=%s-1", STACK,STKTOP,STKTOP,STKTOP))
  case("DUP",         push(top()))
  case("SWAP",        string.format("local _a=%s;%s=%s;%s=_a", top(), top(), top(1), top(1)))

  case("LOAD_LOCAL",  push(string.format("%s[%s]", LOCALS, AA)))
  case("STORE_LOCAL", string.format("%s[%s]=%s", LOCALS, AA, pop()))

  case("LOAD_GLOBAL",  push(string.format("%s[%s]", ENV, getConst(AA))))
  case("STORE_GLOBAL", string.format("%s[%s]=%s", ENV, getConst(AA), pop()))
  case("LOAD_FIELD",   string.format("local _o=%s;%s", pop(), push(string.format("_o[%s]", getConst(AA)))))
  case("STORE_FIELD",  string.format("local _v=%s;local _o=%s;_o[%s]=_v", pop(), pop(), getConst(AA)))
  case("LOAD_INDEX",   string.format("local _k=%s;local _t=%s;%s", pop(), pop(), push("_t[_k]")))
  case("STORE_INDEX",  string.format("local _v=%s;local _k=%s;local _t=%s;_t[_k]=_v", pop(), pop(), pop()))

  -- Arithmetic
  for _, pair in ipairs({
    {"ADD","+"}, {"SUB","-"}, {"MUL","*"}, {"DIV","/"}, {"MOD","%"}, {"POW","^"}, {"IDIV","//"}
  }) do
    case(pair[1], string.format("local _b=%s;local _a=%s;%s", pop(), pop(), push("_a"..pair[2].."_b")))
  end
  case("UNM",  string.format("local _a=%s;%s", pop(), push("-_a")))
  case("BNOT", string.format("local _a=%s;%s", pop(), push("~_a")))

  -- Bitwise
  for _, pair in ipairs({
    {"BAND","&"}, {"BOR","|"}, {"BXOR","~"}, {"SHL","<<"}, {"SHR",">>"}
  }) do
    case(pair[1], string.format("local _b=%s;local _a=%s;%s", pop(), pop(), push("_a"..pair[2].."_b")))
  end

  -- Comparison
  for _, pair in ipairs({
    {"EQ","=="}, {"NEQ","~="}, {"LT","<"}, {"LE","<="}, {"GT",">"}, {"GE",">="}
  }) do
    case(pair[1], string.format("local _b=%s;local _a=%s;%s", pop(), pop(), push("_a"..pair[2].."_b")))
  end
  case("NOT", string.format("local _a=%s;%s", pop(), push("not _a")))
  case("LEN",  string.format("local _a=%s;%s", pop(), push("#_a")))

  -- Logic
  case("AND_JMP", string.format("if not %s then %s=%s end", top(), PC, BB))
  case("OR_JMP",  string.format("if %s then %s=%s end", top(), PC, BB))

  -- Concat
  case("CONCAT", string.format([[
local _parts={} for _i=%s,1,-1 do _parts[_i]=%s[%s] %s[%s]=nil %s=%s-1 end %s]],
    AA, STACK, STKTOP, STACK, STKTOP, STKTOP, STKTOP,
    push(string.format("%s(_parts)", TC))))

  -- Tables
  case("NEW_TABLE",  push("{}"))
  case("SET_TABLE",  string.format("local _v=%s;local _k=%s;local _t=%s;_t[_k]=_v", pop(), pop(), top()))
  case("GET_TABLE",  string.format("local _k=%s;local _t=%s;%s", pop(), pop(), push("_t[_k]")))
  case("SET_LIST",   string.format("local _v=%s;local _t=%s;_t[%s]=_v", pop(), top(), AA))

  -- Control flow
  case("JMP",       string.format("%s=%s", PC, BB))
  case("JMP_TRUE",  string.format("local _c=%s;if _c then %s=%s end", pop(), PC, BB))
  case("JMP_FALSE", string.format("local _c=%s;if not _c then %s=%s end", pop(), PC, BB))
  case("JMP_BACK",  string.format("%s=%s", PC, AA))

  -- CALL
  local CA = R(); local CB = R(); local CC2 = R(); local CD = R(); local CE = R()
  case("CALL", string.format([[
local %s=%s local %s={} for _i=%s,1,-1 do %s[_i]=%s[%s];%s[%s]=nil;%s=%s-1 end
local %s=%s
local %s,_r1,_r2,_r3,_r4,_r5=%s(%s,%s(%s))
if not %s then error("[R005]",0) end
for _,_v in ipairs({_r1,_r2,_r3,_r4,_r5}) do %s end]],
    CA, AA,
    CB,    CA, CB, STACK, STKTOP, STACK, STKTOP, STKTOP, STKTOP,
    CC2, pop(),
    CD, CE, PC2, CC2, TU, CB,
    CD,
    push("_v")))

  -- RETURN
  case("RETURN", string.format([[
local _ret={} for _i=%s,1,-1 do _ret[_i]=%s[%s];%s[%s]=nil;%s=%s-1 end
%s=_ret %s=true]],
    AA, STACK,STKTOP,STACK,STKTOP,STKTOP,STKTOP,
    RESULT, DONE))

  case("RETURN0", string.format("%s={};%s=true", RESULT, DONE))
  case("HALT",    string.format("%s=true", DONE))
  case("NOP",     "-- nop")

  -- MAKE_CLOSURE
  local FC = R(); local FB = R()
  case("MAKE_CLOSURE", string.format([[
local %s=%s(%s[%s],%s,%s,%s+1,%s)
%s]],
    FB, getConst(AA),
    LOCALS, AA, ENV, SEED, DEPTH, MAXIC,
    push(string.format("function(...) local _la={...} local _r,_e=%s(%s,_la,%s,%s,%s+1,%s) if not _r then error('[runtime error]',0) end return %s(_r) end",
      EXEC, FB, ENV, SEED, DEPTH, MAXIC, TU))))

  -- ForNum
  case("FORPREP", string.format([[
local _step=%s;local _lim=%s;local _idx=%s
if type(_step)~="number" or type(_lim)~="number" or type(_idx)~="number" then error("[R005] for values must be numbers",0) end
if _step==0 then error("[R005] for step is zero",0) end
if (_step>0 and _idx>_lim) or (_step<0 and _idx<%s) then %s=%s
else %s %s %s %s end]],
    pop(), pop(), pop(),
    "_lim", PC, BB,
    push("_idx"), push("_lim"), push("_step"), push("_idx")))

  case("FORLOOP", string.format([[
local _top=%s
local _idx=%s[_top-3]+%s[_top-1]
%s[_top-3]=_idx %s[_top]=_idx
if (%s[_top-1]>0 and _idx<=%s[_top-2]) or (%s[_top-1]<0 and _idx>=%s[_top-2]) then %s=%s
else for _i=_top-3,_top do %s[_i]=nil end %s=%s-4 end]],
    STKTOP,
    STACK, STACK,
    STACK, STACK,
    STACK, STACK, STACK, STACK, PC, AA,
    STACK, STKTOP, STKTOP))

  -- TFORLOOP
  case("TFORLOOP", string.format([[
local _top=%s
local _it=%s[_top-2];local _st=%s[_top-1];local _ct=%s[_top]
if type(_it)~="function" then error("[R005] iterator not a function",0) end
local _ok,_r1,_r2,_r3,_r4,_r5=%s(_it,_st,_ct)
if not _ok then error("[R005] iterator error",0) end
if _r1==nil then %s=%s
else %s[_top]=_r1 for _i=1,%s do %s end end]],
    STKTOP,
    STACK, STACK, STACK,
    PC2,
    PC, CC,
    STACK, AA, push("({_r1,_r2,_r3,_r4,_r5})[_i]")))

  case("SELF", string.format([[
local _obj=%s local _mn=%s local _m=_obj[_mn] %s %s]],
    top(), getConst(AA), push("_m"), push("_obj")))

  lines[#lines+1] = "  end"  -- end while
  lines[#lines+1] = string.format("  return %s, %s", RESULT, DONE)
  lines[#lines+1] = "end"   -- end function EXEC
  lines[#lines+1] = ""

  -- Bootstrap call
  local BE = R(); local BF = R()
  local maxIC = Spec.LIMITS.MAX_INSTRUCTIONS
  lines[#lines+1] = string.format(
    "local %s,%s=%s(%s,{}," ..
    "setmetatable({},{__index=_G,__newindex=function(_t,k,v)rawset(_t,k,v)end})," ..
    "%s,0,%s)",
    BE, BF, EXEC, PROTO, tostring(shuffleSeed), tostring(maxIC))
  lines[#lines+1] = string.format("if not %s then error('[runtime error]',0) end", BE)
  lines[#lines+1] = "end"  -- end do

  return table.concat(lines, "\n")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §4  RNG
-- ─────────────────────────────────────────────────────────────────────────────

local function makeRNG(seed)
  local s = seed & 0x7FFFFFFFFFFFFFFF
  if s == 0 then s = 1 end
  return function()
    s = s ~ (s << 13)
    s = s ~ (s >> 7)
    s = s ~ (s << 17)
    s = s & 0x7FFFFFFFFFFFFFFF
    return s
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §5  PUBLIC API
-- ─────────────────────────────────────────────────────────────────────────────

function Levititas.new(cfg)
  local self   = setmetatable({}, Levititas)
  self.cfg     = cfg or {}
  local c      = self.cfg
  c.target     = c.target or "lua54"
  c.maxInstructions = c.maxInstructions or Spec.LIMITS.MAX_INSTRUCTIONS
  return self
end

function Levititas:obfuscate(source, fixedSeed)
  local cfg = self.cfg

  -- ── Step 1: Parse ────────────────────────────────────────────────────────
  local ast, parseErr, coverage = Parser.parse(source)
  if not ast then
    return nil, parseErr, { stage="parse", coverage=coverage }
  end

  -- ── Step 2: Compatibility audit ──────────────────────────────────────────
  local compatOk, compatIssues = Compat.audit(ast, cfg.target)
  if not compatOk then
    return nil,
      "Compatibility check failed:\n" .. Compat.formatIssues(compatIssues),
      { stage="compat", issues=compatIssues }
  end

  -- ── Step 3: AST validation ───────────────────────────────────────────────
  local astOk, astErr = ASTVal.validateAST(ast)
  if not astOk then
    return nil, astErr, { stage="ast_validation" }
  end

  -- ── Step 4: Seed + opcode map ────────────────────────────────────────────
  local srcHash    = crc32(source)
  local seed       = fixedSeed
                     and Opcodes.seedFromInt(fixedSeed)
                     or  Opcodes.generateSeed(srcHash)
  local rng        = makeRNG(seed)
  local opcodeMap, reverseMap = Opcodes.generateMap(seed)

  -- ── Step 5: Compile AST → Proto ──────────────────────────────────────────
  local proto, compErr = Compiler.compile(ast, opcodeMap, seed)
  if not proto then
    return nil, compErr, { stage="compile" }
  end

  -- ── Step 6: Validate proto ───────────────────────────────────────────────
  local protoOk, protoErr = ProtoVal.validate(proto, reverseMap)
  if not protoOk then
    return nil, protoErr, { stage="proto_validation" }
  end

  -- ── Step 7: Serialize + emit interpreter ────────────────────────────────
  local protoLiteral  = serializeProto(proto)
  local interpreterSrc = emitInterpreter(opcodeMap, protoLiteral, seed, rng)

  -- ── Step 8: Build metadata ───────────────────────────────────────────────
  local meta = {
    seed       = seed,
    target     = cfg.target,
    buildDate  = os.date("%Y-%m-%d"),
    sourceHash = string.format("%08X", srcHash),
    protoInstrs= #proto.i,
    protoConsts= #proto.k,
    coverage   = coverage,
    compatWarnings = compatIssues,
  }

  return interpreterSrc, nil, meta
end

return Levititas
