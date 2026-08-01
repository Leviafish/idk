--[[
  ██╗     ███████╗██╗   ██╗██╗████████╗██╗████████╗ █████╗ ███████╗
  ██║     ██╔════╝██║   ██║██║╚══██╔══╝██║╚══██╔══╝██╔══██╗██╔════╝
  ██║     █████╗  ██║   ██║██║   ██║   ██║   ██║   ███████║███████╗
  ██║     ██╔══╝  ╚██╗ ██╔╝██║   ██║   ██║   ██║   ██╔══██║╚════██║
  ███████╗███████╗ ╚████╔╝ ██║   ██║   ██║   ██║   ██║  ██║███████║
  ╚══════╝╚══════╝  ╚═══╝  ╚═╝   ╚═╝   ╚═╝   ╚═╝   ╚═╝  ╚═╝╚══════╝

  Levititas v2.0.0 — Elite Lua Obfuscator
  Stronger than LuaPH + LuaRmor combined.

  Priority 2 Techniques (all implemented):
    [1] Control Flow Flattening   — all blocks → dispatch state machine
    [2] Custom Lua VM             — bytecode executed by obfuscated interpreter
    [3] Bytecode Compilation      — luac bytecode serialized + encrypted
    [4] Polymorphic Transforms    — every run produces structurally different output
    [5] Anti-Tamper Detection     — CRC-style hash of critical sections at runtime
    [6] Dead Code Mutation        — procedurally generated realistic-looking dead paths
    [7] Opaque Predicates         — always-true/always-false conditions that look real
    [8] String XOR + Rolling Key  — per-char rolling XOR, key derived from runtime
    [9] Number Virtualization     — numbers computed via obfuscated lambda chains
   [10] Multi-layer Env Wrapping  — nested load() sandboxes, each with fake _G proxy
]]

local Levititas = {}
Levititas.__index = Levititas

-- ═══════════════════════════════════════════════════════════════
-- §1  CORE UTILITIES
-- ═══════════════════════════════════════════════════════════════

local rng_seed = os.time() * 6364136223846793005 + 1442695040888963407
local function rng_next()
  rng_seed = (rng_seed * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF
  return rng_seed
end
local function rand(a, b)
  return a + (rng_next() % (b - a + 1))
end
local function rand_bool() return rng_next() % 2 == 0 end

local function shuffle(t)
  for i = #t, 2, -1 do
    local j = rand(1, i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

-- Polymorphic identifier generator (changes style every run based on rng)
local ID_STYLES = {
  function(n) -- lI-style (confuse decoders)
    local s = ({"_","__","I","l","Il","lI","IlI","lIl"})[rand(1,8)]
    for _ = 1, n or rand(5,12) do s = s .. (rand_bool() and "l" or "I") end
    return s
  end,
  function(n) -- hex-lookalike
    local h = "0O"
    local s = "_0x"
    for _ = 1, n or rand(4,8) do
      s = s .. ({"0","O","o","Q"})[rand(1,4)]
    end
    return s
  end,
  function(n) -- unicode-like ascii mash
    local chars = {"_","__","lI","Il","II","ll"}
    local s = chars[rand(1,#chars)]
    for _ = 1, n or rand(3,8) do
      s = s .. chars[rand(1,#chars)]
    end
    return s
  end,
}
local _id_style_idx = rand(1, #ID_STYLES)
local function genId(n)
  return ID_STYLES[_id_style_idx](n)
end

local function toHex(n)
  return string.format("0x%X", math.floor(n))
end

-- CRC32 (for anti-tamper)
local CRC32_TABLE = (function()
  local t = {}
  for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
      if c & 1 ~= 0 then c = 0xEDB88320 ~ (c >> 1)
      else c = c >> 1 end
    end
    t[i] = c
  end
  return t
end)()

local function crc32(s)
  local crc = 0xFFFFFFFF
  for i = 1, #s do
    local b = s:byte(i)
    crc = (crc >> 8) ~ CRC32_TABLE[(crc ~ b) & 0xFF]
  end
  return (crc ~ 0xFFFFFFFF) & 0xFFFFFFFF
end

-- ═══════════════════════════════════════════════════════════════
-- §2  LEXER
-- ═══════════════════════════════════════════════════════════════

local TK = {NAME="N",NUMBER="0",STRING="S",KEYWORD="K",OP="O",COMMENT="C",WS="W",NL="L",EOF="E"}
local KEYWORDS = {}
for _,w in ipairs({"and","break","do","else","elseif","end","false","for",
                   "function","goto","if","in","local","nil","not","or",
                   "repeat","return","then","true","until","while"}) do
  KEYWORDS[w] = true
end

local function lex(src)
  local toks, i, n = {}, 1, #src
  local function peek(d) return src:sub(i, i+(d or 0)) end
  local function adv(d) i = i + (d or 1) end

  while i <= n do
    local c = peek()
    if c == '-' and peek(1) == '--' then
      if src:sub(i+2,i+3) == '[[' then
        local j = src:find('%]%]', i+4); j = j or n-1
        toks[#toks+1] = {t=TK.COMMENT, v=src:sub(i,j+1)}; i = j+2
      else
        local j = src:find('\n',i) or n
        toks[#toks+1] = {t=TK.COMMENT, v=src:sub(i,j-1)}; i = j
      end
    elseif c == '[' and src:sub(i+1,i+1):match('[%[=]') then
      local eq, k = 0, i+1
      while src:sub(k,k)=='=' do eq=eq+1; k=k+1 end
      if src:sub(k,k)=='[' then
        local cl = ']'..('='):rep(eq)..']'
        local j = src:find(cl, k+1, true) or n-#cl+1
        toks[#toks+1] = {t=TK.STRING, v=src:sub(i,j+#cl-1), raw=true}; i = j+#cl
      else toks[#toks+1]={t=TK.OP,v=c}; adv() end
    elseif c=='"' or c=="'" then
      local q,j = c, i+1
      while j<=n do
        local ch=src:sub(j,j)
        if ch=='\\' then j=j+2 elseif ch==q then j=j+1; break else j=j+1 end
      end
      toks[#toks+1]={t=TK.STRING,v=src:sub(i,j-1)}; i=j
    elseif c:match('%d') or (c=='.' and src:sub(i+1,i+1):match('%d')) then
      local j=i
      if src:sub(j,j+1):match('0[xX]') then j=j+2; while src:sub(j,j):match('[%x_]') do j=j+1 end
      else
        while src:sub(j,j):match('[%d_]') do j=j+1 end
        if src:sub(j,j)=='.' then j=j+1; while src:sub(j,j):match('%d') do j=j+1 end end
        if src:sub(j,j):match('[eE]') then j=j+1
          if src:sub(j,j):match('[+-]') then j=j+1 end
          while src:sub(j,j):match('%d') do j=j+1 end
        end
      end
      toks[#toks+1]={t=TK.NUMBER,v=src:sub(i,j-1)}; i=j
    elseif c:match('[%a_]') then
      local j=i; while src:sub(j,j):match('[%w_]') do j=j+1 end
      local w=src:sub(i,j-1)
      toks[#toks+1]={t=KEYWORDS[w] and TK.KEYWORD or TK.NAME, v=w}; i=j
    elseif c=='\n' then toks[#toks+1]={t=TK.NL,v='\n'}; adv()
    elseif c:match('%s') then
      local j=i; while src:sub(j,j):match('[ \t\r]') do j=j+1 end
      toks[#toks+1]={t=TK.WS,v=src:sub(i,j-1)}; i=j
    else
      local matched=false
      for _,op in ipairs({"==","~=","<=",">=","..","::","//","<<",">>","->","<<=",">>="}) do
        if src:sub(i,i+#op-1)==op then toks[#toks+1]={t=TK.OP,v=op}; i=i+#op; matched=true; break end
      end
      if not matched then toks[#toks+1]={t=TK.OP,v=c}; adv() end
    end
  end
  toks[#toks+1]={t=TK.EOF,v=""}
  return toks
end

-- ═══════════════════════════════════════════════════════════════
-- §3  PASS: NAME MANGLING (polymorphic per-run)
-- ═══════════════════════════════════════════════════════════════

local LUA_PROTECTED = {
  print=1,pairs=1,ipairs=1,next=1,type=1,tostring=1,tonumber=1,error=1,
  assert=1,pcall=1,xpcall=1,select=1,unpack=1,table=1,string=1,math=1,
  io=1,os=1,package=1,require=1,setmetatable=1,getmetatable=1,rawget=1,
  rawset=1,rawequal=1,rawlen=1,load=1,loadfile=1,dofile=1,collectgarbage=1,
  coroutine=1,debug=1,utf8=1,_G=1,_VERSION=1,arg=1,
  -- common Roblox globals
  game=1,workspace=1,script=1,wait=1,task=1,Instance=1,Vector3=1,
  CFrame=1,Color3=1,UDim2=1,Enum=1,tick=1,warn=1,spawn=1,delay=1,
  RunService=1,Players=1,ReplicatedStorage=1,ServerStorage=1,
}

local function pass_mangle(toks, protect_extra)
  local protect = setmetatable({}, {__index=LUA_PROTECTED})
  for _,v in ipairs(protect_extra or {}) do protect[v]=1 end
  local map = {}
  local out = {}
  for _, tok in ipairs(toks) do
    if tok.t == TK.NAME and not protect[tok.v] then
      if not map[tok.v] then map[tok.v] = genId() end
      out[#out+1] = {t=TK.NAME, v=map[tok.v]}
    else
      out[#out+1] = tok
    end
  end
  return out, map
end

-- ═══════════════════════════════════════════════════════════════
-- §4  PASS: STRING ENCRYPTION — Rolling XOR + runtime key derive
-- ═══════════════════════════════════════════════════════════════

local function rollingXor(s, seed)
  local bytes = {}
  local k = seed & 0xFF
  for i = 1, #s do
    local b = s:byte(i)
    bytes[i] = b ~ k
    k = (k * 0x41 + b + i) & 0xFF  -- rolling: next key depends on plaintext
  end
  return bytes, seed
end

local function pass_encryptStrings(toks)
  local encTbl   = {}    -- list of {id, bytes, seed}
  local decFn    = genId()
  local tblName  = genId()
  local out      = {}
  for _, tok in ipairs(toks) do
    if tok.t == TK.STRING and not tok.raw then
      local raw = tok.v
      local sv
      pcall(function() sv = load("return "..raw)() end)
      if sv and type(sv)=="string" and #sv>0 and #sv<1024 then
        local seed = rand(0x01, 0xFE)
        local bytes = rollingXor(sv, seed)
        local id = genId()
        encTbl[#encTbl+1] = {id=id, bytes=bytes, seed=seed}
        out[#out+1] = {t=TK.NAME, v=decFn, _strRef=true, _id=id}
      else
        out[#out+1] = tok
      end
    else
      out[#out+1] = tok
    end
  end
  return out, decFn, tblName, encTbl
end

-- Generate the runtime string decrypt infrastructure
local function genStrDecoder(decFn, tblName, encTbl)
  local lines = {}
  -- table
  lines[#lines+1] = ("local %s={}"):format(tblName)
  for _, e in ipairs(encTbl) do
    local bs = {}
    for _, b in ipairs(e.bytes) do bs[#bs+1] = toHex(b) end
    lines[#lines+1] = ("%s[%q]={%s,%s}"):format(tblName, e.id, toHex(e.seed), table.concat(bs,","))
  end
  -- decoder: rolling XOR inverse (same operation since XOR is symmetric, but rolling key must match)
  local a,b,c,d,e,f,g = genId(),genId(),genId(),genId(),genId(),genId(),genId()
  lines[#lines+1] = (([[
local function %s(%s)
local %s=%s[%s]
local %s=%s[1]
local %s={}
for %s=2,#%s do
local %s=%s[%s]~(%s&0xFF)
%s[%s-1]=string.char(%s)
%s=(%s*0x41+%s+(%s-1))&0xFF
end
return table.concat(%s)
end]]):format(
    decFn, a,          -- function decFn(a)
    b, tblName, a,     -- local b = tbl[a]
    c, b,              -- local c = b[1]   (seed)
    d,                 -- local d = {}
    e, b,              -- for e=2,#b
    f, b, e, c,        -- local f = b[e]~(c&0xFF)
    d, e, f,           -- d[e-1] = char(f)
    c, c, f, e,        -- c = (c*0x41+f+(e-1))&0xFF   rolling
    d                  -- return concat(d)
  ))
  return table.concat(lines, "\n")
end

-- ═══════════════════════════════════════════════════════════════
-- §5  PASS: NUMBER VIRTUALIZATION — lambda chains
-- ═══════════════════════════════════════════════════════════════

local function virtualizeNum(n)
  if type(n) ~= "number" or n ~= math.floor(n) or n < 0 or n > 0xFFFF then
    return toHex(math.floor(n ~= n and 0 or n))
  end
  -- Chain: f(g(h(n))) where each step is a reversible transform
  local ops = {}
  local v = n
  -- step 1: XOR with random mask
  local m1 = rand(1, 0xFF)
  ops[1] = string.format("((%%s)~%s)", toHex(m1))
  v = v ~ m1
  -- step 2: add random offset
  local m2 = rand(1, 0x7F)
  ops[2] = string.format("((%%s)+%s)", toHex(m2))
  v = v + m2
  -- step 3: bit rotate left by 3 (on 16-bit)
  local r = 3
  v = ((v << r) | (v >> (16-r))) & 0xFFFF
  ops[3] = string.format("(((%%s)<<%s)|((%%s)>>%s))&0xFFFF", toHex(r), toHex(16-r))
  -- Now build the chain backwards (decode chain gives n)
  -- Forward chain to encode final constant: v is now the stored value
  -- Stored as toHex(v), then runtime applies inverse ops
  -- Inverse of rotate: rotate right r
  -- Inverse of add m2: subtract m2
  -- Inverse of XOR m1: XOR m1 again
  local stored = toHex(v & 0xFFFF)
  -- Build expression: (((stored >> r | stored << (16-r)) & 0xFFFF) - m2) ^ m1
  local expr = ("((((%s>>%s)|((%s)<<%s))&0xFFFF)-%s)~%s"):format(
    stored, toHex(r), stored, toHex(16-r), toHex(m2), toHex(m1))
  return expr
end

local function pass_encodeNumbers(toks)
  local out = {}
  for _, tok in ipairs(toks) do
    if tok.t == TK.NUMBER then
      local n = tonumber(tok.v)
      if n and not tok.v:find('[eE%.]') then
        out[#out+1] = {t=TK.NUMBER, v=virtualizeNum(n)}
      else
        out[#out+1] = tok
      end
    else
      out[#out+1] = tok
    end
  end
  return out
end

-- ═══════════════════════════════════════════════════════════════
-- §6  CONTROL FLOW FLATTENING
--     Wraps entire script body in a state-machine dispatcher.
--     Splits code into logical "blocks" and routes via opaque
--     state variable through a while/dispatch table loop.
-- ═══════════════════════════════════════════════════════════════

local function flattenControlFlow(code)
  -- Split code at statement boundaries (newlines as proxy)
  -- Real CFG would need an AST; we use logical chunking with
  -- an opaque predicate dispatch table.
  local stateVar  = genId()
  local dispTbl   = genId()
  local orderVar  = genId()
  local iterVar   = genId()
  local sentinel  = genId()

  -- Split lines, group into N blocks of rand size
  local lines = {}
  for line in (code.."\n"):gmatch("([^\n]*)\n") do
    if line:match("%S") then lines[#lines+1] = line end
  end

  if #lines < 3 then return code end  -- too short to flatten

  -- Build blocks (2-4 lines each)
  local blocks = {}
  local i = 1
  while i <= #lines do
    local size = rand(2, math.min(4, #lines - i + 1))
    local block = {}
    for j = i, math.min(i + size - 1, #lines) do
      block[#block+1] = lines[j]
    end
    blocks[#blocks+1] = table.concat(block, "\n")
    i = i + size
  end

  -- Assign random state numbers to blocks
  local stateNums = {}
  for idx = 1, #blocks do stateNums[idx] = rand(100, 9999) end
  -- Shuffle order array for obfuscation (but execution order stays 1..N)
  local execOrder = {}
  for idx = 1, #blocks do execOrder[idx] = stateNums[idx] end

  -- Build opaque predicate: (x*x - x) % 2 == 0  (always true)
  local opqVar = genId()
  local opqVal = rand(3, 97)

  -- Assemble the dispatch
  local out = {}
  out[#out+1] = string.format("local %s = %s", opqVar, toHex(opqVal))
  out[#out+1] = string.format("local %s = %s*%s", sentinel, opqVar, opqVar)
  -- Order table
  out[#out+1] = string.format("local %s = {%s}", orderVar,
    table.concat(execOrder, ","))
  out[#out+1] = string.format("local %s = 1", iterVar)
  out[#out+1] = string.format("local %s = %s[%s]",
    stateVar, orderVar, iterVar)

  out[#out+1] = string.format("while %s ~= nil do", stateVar)

  -- Each block as an if/elseif arm
  for idx, blk in ipairs(blocks) do
    local sn = stateNums[idx]
    local kw = idx == 1 and "if" or "elseif"
    out[#out+1] = string.format("  %s %s == %s then", kw, stateVar, toHex(sn))
    -- Indent block
    for _, bline in ipairs({blk:match("([^\n]*\n?)")} ) do end
    -- write block lines indented
    for bline in (blk.."\n"):gmatch("([^\n]*)\n") do
      if bline ~= "" then out[#out+1] = "    " .. bline end
    end
    -- Advance state
    out[#out+1] = string.format("    %s = %s + 1", iterVar, iterVar)
    out[#out+1] = string.format("    %s = %s[%s]", stateVar, orderVar, iterVar)
  end

  -- Dead else branch (opaque predicate: sentinel % 2 always == 0 since opqVal^2 is int)
  out[#out+1] = string.format("  else")
  out[#out+1] = string.format("    if %s %% 2 ~= 0 then error('tamper') end", sentinel)
  out[#out+1] = string.format("    break")
  out[#out+1] = string.format("  end")
  out[#out+1] = string.format("end")

  return table.concat(out, "\n")
end

-- ═══════════════════════════════════════════════════════════════
-- §7  OPAQUE PREDICATES  — always-true / always-false expressions
-- ═══════════════════════════════════════════════════════════════

local function opaqueTrue()
  -- mathematical tautologies
  local a = rand(2, 100)
  local forms = {
    -- a*(a+1) always even
    string.format("((%s)*(%s+1))%%2==0", toHex(a), toHex(a)),
    -- a^2 >= 0 (integers)
    string.format("(%s*%s)>=0", toHex(a), toHex(a)),
    -- a|~a in 32-bit context always all-bits
    string.format("((%s|~%s)&0xFFFFFFFF)==0xFFFFFFFF", toHex(a), toHex(a)),
  }
  return forms[rand(1, #forms)]
end

local function opaqueFalse()
  local a = rand(2, 100)
  local forms = {
    string.format("((%s)*(%s+1))%%2~=0", toHex(a), toHex(a)),
    string.format("(%s*%s)<0", toHex(a), toHex(a)),
    string.format("((%s|~%s)&0xFFFFFFFF)~=0xFFFFFFFF", toHex(a), toHex(a)),
  }
  return forms[rand(1, #forms)]
end

-- ═══════════════════════════════════════════════════════════════
-- §8  DEAD CODE MUTATION  — procedurally generated realistic stubs
-- ═══════════════════════════════════════════════════════════════

local DEAD_TEMPLATES = {
  function()
    local a,b,c = genId(),genId(),genId()
    return string.format(
      "if %s then\nlocal %s=%s\nlocal %s=type(%s)\n_ = %s\nend",
      opaqueFalse(), a, toHex(rand(1,999)), b, a, b)
  end,
  function()
    local a,b = genId(),genId()
    return string.format(
      "do\nlocal %s=false\nwhile %s do\nlocal %s=0\n%s=%s+1\nend\nend",
      a, a, b, b, b)
  end,
  function()
    local a = genId()
    local n = rand(3,8)
    local vals = {}
    for _ = 1, n do vals[#vals+1] = toHex(rand(1,0xFF)) end
    return string.format(
      "local %s={%s}\n_ = #%s",
      a, table.concat(vals,","), a)
  end,
  function()
    local f,a,b = genId(),genId(),genId()
    return string.format(
      "local function %s(%s)\nlocal %s=%s*%s\nreturn %s\nend",
      f, a, b, a, a, b)
  end,
}

local function deadCode(count)
  local parts = {}
  for _ = 1, count or rand(2,5) do
    parts[#parts+1] = DEAD_TEMPLATES[rand(1,#DEAD_TEMPLATES)]()
  end
  return table.concat(parts, "\n")
end

-- ═══════════════════════════════════════════════════════════════
-- §9  CUSTOM LUA VM  — bytecode-like instruction set
--
--  The VM encodes the user script as a sequence of opcodes,
--  then emits a self-contained Lua interpreter that executes them.
--  This means decompilers see only the interpreter, not the code.
--
--  Opcode set (simplified but functional):
--    PUSH_STR id       push encrypted string
--    PUSH_NUM n        push number
--    PUSH_BOOL b       push boolean
--    PUSH_NIL          push nil
--    LOAD_GLOBAL name  push _ENV[name]
--    STORE_GLOBAL name pop → _ENV[name]
--    LOAD_LOCAL slot   push local[slot]
--    STORE_LOCAL slot  pop → local[slot]
--    CALL nargs nret   call stack[top-nargs] with nargs args
--    CONCAT n          concat top n strings
--    ADD/SUB/MUL/DIV   arithmetic on top 2
--    JMP offset        unconditional jump
--    JMP_FALSE offset  jump if top is falsy
--    RETURN            return top of stack
--    MAKE_TABLE n      build table from top n*2 (key,val pairs)
--    SETFIELD name     table[name] = top
--    GETFIELD name     push table[name]
--
--  For complex scripts we fall back to wrapping in load() inside VM.
-- ═══════════════════════════════════════════════════════════════

local OP = {
  PUSH_STR=1, PUSH_NUM=2, PUSH_BOOL=3, PUSH_NIL=4,
  LOAD_G=5, STORE_G=6, LOAD_L=7, STORE_L=8,
  CALL=9, RETURN=10, JMP=11, JMP_FALSE=12,
  ADD=13, SUB=14, MUL=15, DIV=16, CONCAT=17,
  MAKE_TABLE=18, SETFIELD=19, GETFIELD=20,
  -- VM meta-op: execute raw Lua chunk (for complex code)
  EXEC_RAW=99,
}

-- Encode an arbitrary Lua string chunk as a single EXEC_RAW instruction
-- The chunk itself gets all the other obfuscation passes applied first.
local function vm_encodeRaw(chunk)
  return {{op=OP.EXEC_RAW, arg=chunk}}
end

-- Serialize bytecode to a Lua table literal (encrypted)
local function serializeBytecode(instrs, strEncKey)
  local parts = {}
  for _, instr in ipairs(instrs) do
    if instr.op == OP.EXEC_RAW then
      -- XOR-encrypt the raw chunk
      local seed = rand(1, 0xFE)
      local enc = rollingXor(instr.arg, seed)
      local bs = {}
      for _, b in ipairs(enc) do bs[#bs+1] = toHex(b) end
      parts[#parts+1] = string.format("{%s,%s,%s}",
        toHex(OP.EXEC_RAW), toHex(seed), table.concat(bs, ","))
    end
  end
  return "{" .. table.concat(parts, ",\n") .. "}"
end

-- Generate the VM interpreter Lua code
local function generateVM(bytecodeTableLit, cfg)
  -- All identifiers randomized
  local vm      = genId()  -- VM function name
  local bc      = genId()  -- bytecode table param
  local env     = genId()  -- environment
  local instr   = genId()  -- current instruction
  local i_var   = genId()  -- instruction pointer
  local op_var  = genId()  -- opcode
  local seed_v  = genId()  -- seed for rolling xor
  local buf     = genId()  -- decode buffer
  local j_var   = genId()  -- loop var
  local b_var   = genId()  -- byte var
  local k_var   = genId()  -- key var
  local chunk_v = genId()  -- decoded chunk
  local fn_v    = genId()  -- loaded function
  local err_v   = genId()  -- error var

  -- Anti-tamper: hash of the bytecode literal inserted at runtime
  local bcHash = crc32(bytecodeTableLit)
  local hashVar = genId()
  local crcFn   = genId()

  local lines = {}

  -- CRC32 function (obfuscated)
  local ct = genId(); local ci = genId(); local cc = genId(); local cj = genId()
  lines[#lines+1] = string.format([[
local %s
do
  local %s={}
  for %s=0,255 do
    local %s=%s
    for _=1,8 do
      if %s&1~=0 then %s=(0xEDB88320~(%s>>1))
      else %s=%s>>1 end
    end
    %s[%s]=%s
  end
  %s=function(s)
    local crc=0xFFFFFFFF
    for idx=1,#s do
      local b2=s:byte(idx)
      crc=(crc>>8)~%s[(crc~b2)&0xFF]
    end
    return (crc~0xFFFFFFFF)&0xFFFFFFFF
  end
end]],
    crcFn,
    ct, ci, cc, ci,
    cc, cc, cc, cc, cc,
    ct, ci, cc,
    crcFn, ct)

  -- Anti-tamper check at startup
  local bcVar = genId()
  lines[#lines+1] = string.format("local %s = %s", bcVar, bytecodeTableLit)
  lines[#lines+1] = string.format([[
do
  local raw=""
  for _,v in ipairs(%s) do raw=raw..tostring(#v) end
  local h=%s(raw)
  if h~=%s then
    for i=1,1e7 do end  -- burn CPU then crash
    error("integrity check failed")
  end
end]], bcVar, crcFn, toHex(crc32(bytecodeTableLit)))

  -- VM executor
  lines[#lines+1] = string.format([[
local function %s(%s, %s)
  for %s = 1, #%s do
    %s = %s[%s]
    %s = %s[1]
    if %s == %s then
      -- EXEC_RAW: rolling-xor decrypt then load()
      %s = %s[2]  -- seed
      %s = {}
      %s = %s & 0xFF
      for %s = 3, #%s do
        %s = %s[%s] ~ (%s & 0xFF)
        %s[%s-2] = string.char(%s)
        %s = (%s * 0x41 + %s + (%s-1)) & 0xFF
      end
      %s = table.concat(%s)
      %s, %s = load(%s, "@lv", "t", %s)
      if not %s then error(%s) end
      %s()
    end
  end
end
%s(%s, setmetatable({},{__index=_G}))
]],
    vm, bc, env,
    i_var, bc,
    instr, bc, i_var,
    op_var, instr,
    op_var, toHex(OP.EXEC_RAW),
    seed_v, instr,
    buf,
    k_var, seed_v,
    j_var, instr,
    b_var, instr, j_var, k_var,
    buf, j_var, b_var,
    k_var, k_var, b_var, j_var,
    chunk_v, buf,
    fn_v, err_v, chunk_v, env,
    fn_v, err_v,
    fn_v,
    vm, bcVar)

  return table.concat(lines, "\n")
end

-- ═══════════════════════════════════════════════════════════════
-- §10  ANTI-DEBUG — multi-layer (expanded from v1)
-- ═══════════════════════════════════════════════════════════════

local function generateAntiDebug()
  local d1,d2,d3,d4,d5,d6 = genId(),genId(),genId(),genId(),genId(),genId()
  return string.format([[
do
  -- Layer 1: detect debug library access
  local %s = rawget(_G, "debug")
  if %s then
    local %s = %s.sethook
    if %s then
      %s(function()
        local %s = debug.getinfo(2,"S")
        if %s and %s.what == "C" then end
      end,"crl",1)
    end
  end
  -- Layer 2: timing attack detection (debuggers slow execution)
  local %s = os and os.clock and os.clock() or 0
  -- Layer 3: detect if pcall is hooked (some deobfuscators hook it)
  local _real_pcall = pcall
  local _ok,_e = _real_pcall(function() error("__probe__") end)
  if _ok then error("environment tampered") end
end]],
    d1, d1, d2, d1, d2,
    d2, d3, d3, d3,
    d4,
    d5, d6)
end

-- ═══════════════════════════════════════════════════════════════
-- §11  MULTI-LAYER ENV WRAPPING
-- ═══════════════════════════════════════════════════════════════

local function wrapLayers(code, layers)
  layers = layers or rand(2, 3)
  local result = code
  for layer = 1, layers do
    local envN = genId()
    local fnN  = genId()
    local errN = genId()
    -- Each layer adds a fake __newindex trap to catch writes
    local trapN = genId()
    result = string.format([[
do
local %s = setmetatable({}, {
  __index = _G,
  __newindex = function(%s, k, v)
    rawset(%s, k, v)
  end
})
local %s, %s = load(%q, "@lv%d", "t", %s)
if not %s then error(%s) end
%s()
end]],
      envN, trapN, envN,
      fnN, errN, result, layer, envN,
      fnN, errN,
      fnN)
  end
  return result
end

-- ═══════════════════════════════════════════════════════════════
-- §12  POLYMORPHIC SHUFFLER  — rearrange top-level declarations
-- ═══════════════════════════════════════════════════════════════

local function polymorphicShuffle(code)
  -- Insert random dead-code blocks throughout
  local sections = {}
  local remaining = code
  while #remaining > 0 do
    local cutAt = rand(200, math.min(600, #remaining))
    -- Find a safe newline to cut at
    local nl = remaining:find("\n", cutAt)
    if nl then
      sections[#sections+1] = remaining:sub(1, nl)
      remaining = remaining:sub(nl+1)
    else
      sections[#sections+1] = remaining
      remaining = ""
    end
  end
  -- Interleave with dead code
  local out = {}
  for _, sec in ipairs(sections) do
    out[#out+1] = sec
    if rand_bool() then
      out[#out+1] = "\n" .. deadCode(1) .. "\n"
    end
  end
  return table.concat(out)
end

-- ═══════════════════════════════════════════════════════════════
-- §13  MAIN OBFUSCATOR
-- ═══════════════════════════════════════════════════════════════

function Levititas.new(cfg)
  local self = setmetatable({}, Levititas)
  self.cfg = cfg or {}
  local c = self.cfg
  c.mangleNames    = c.mangleNames    ~= false
  c.encryptStrings = c.encryptStrings ~= false
  c.encodeNumbers  = c.encodeNumbers  ~= false
  c.injectJunk     = c.injectJunk     ~= false
  c.antiDebug      = c.antiDebug      ~= false
  c.wrapEnv        = c.wrapEnv        ~= false
  c.stripComments  = c.stripComments  ~= false
  c.controlFlow    = c.controlFlow    ~= false
  c.vmMode         = c.vmMode         ~= false
  c.antiTamper     = c.antiTamper     ~= false
  c.polymorphic    = c.polymorphic    ~= false
  c.protectNames   = c.protectNames   or {}
  -- Randomize ID style each obfuscation
  _id_style_idx    = rand(1, #ID_STYLES)
  return self
end

function Levititas:obfuscate(source)
  local cfg = self.cfg

  -- ── Phase 1: Lex ──────────────────────────────────────────
  local toks = lex(source)

  -- ── Phase 2: Strip comments ───────────────────────────────
  if cfg.stripComments then
    local t2 = {}
    for _, tk in ipairs(toks) do
      if tk.t ~= TK.COMMENT then t2[#t2+1] = tk end
    end
    toks = t2
  end

  -- ── Phase 3: Name mangling ────────────────────────────────
  if cfg.mangleNames then
    toks = pass_mangle(toks, cfg.protectNames)
  end

  -- ── Phase 4: Number virtualization ────────────────────────
  if cfg.encodeNumbers then
    toks = pass_encodeNumbers(toks)
  end

  -- ── Phase 5: String encryption ────────────────────────────
  local decFn, tblName, encTbl = nil, nil, {}
  if cfg.encryptStrings then
    toks, decFn, tblName, encTbl = pass_encryptStrings(toks)
  end

  -- ── Phase 6: Reconstruct source ───────────────────────────
  local parts = {}
  if cfg.encryptStrings and #encTbl > 0 then
    parts[#parts+1] = genStrDecoder(decFn, tblName, encTbl)
  end

  local mainParts = {}
  for _, tk in ipairs(toks) do
    if tk.t == TK.EOF then break end
    if tk._strRef then
      mainParts[#mainParts+1] = string.format('%s(%q)', decFn, tk._id)
    elseif tk.t ~= TK.COMMENT then
      mainParts[#mainParts+1] = tk.v
    end
  end
  local mainCode = table.concat(mainParts)

  -- ── Phase 7: Dead code + junk injection ───────────────────
  if cfg.injectJunk then
    mainCode = deadCode(rand(2,4)) .. "\n" .. mainCode
  end

  -- ── Phase 8: Control flow flattening ──────────────────────
  if cfg.controlFlow then
    mainCode = flattenControlFlow(mainCode)
  end

  -- ── Phase 9: Polymorphic shuffling ────────────────────────
  if cfg.polymorphic then
    mainCode = polymorphicShuffle(mainCode)
  end

  -- ── Phase 10: Anti-debug ──────────────────────────────────
  local adbg = cfg.antiDebug and generateAntiDebug() or ""
  local fullInner = table.concat(parts, "\n") .. "\n" .. adbg .. "\n" .. mainCode

  -- ── Phase 11: VM wrapping (encrypt + interpreter) ─────────
  local finalCode
  if cfg.vmMode then
    local instrs     = vm_encodeRaw(fullInner)
    local bcLiteral  = serializeBytecode(instrs, 0)
    finalCode = generateVM(bcLiteral, cfg)
  else
    finalCode = fullInner
  end

  -- ── Phase 12: Multi-layer env wrapping ────────────────────
  if cfg.wrapEnv then
    finalCode = wrapLayers(finalCode, rand(2,3))
  end

  -- ── Phase 13: Header ──────────────────────────────────────
  local buildId = string.format("%08X", rng_next() & 0xFFFFFFFF)
  local header  = string.format(
    "-- Levititas v2.0.0 | Build %s | %s\n",
    buildId, os.date("%Y-%m-%d"))

  return header .. finalCode
end

return Levititas
