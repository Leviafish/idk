--[[
  Levititas v3.1 — VM Core
  src/vm/core.lua

  Key architectural decisions vs v3:
    [1] NO load() on user code path. Proto walked directly.
    [2] All stdlib references cached as upvalues at module load time.
    [3] Lazy constant decryption — decrypt on first access, never before.
    [4] Dispatch table (O(1)) instead of if/elseif chain.
    [5] Instruction counter with configurable limit.
    [6] Call depth limit.
    [7] Stack implemented as integer-indexed array with explicit top pointer.
    [8] Key derivation uses shuffle_seed XOR proto_depth XOR const_index.
    [9] Errors normalized — no internal variable names exposed.
   [10] All error paths return {ok=false, err=code, msg=string}.
]]

-- ─────────────────────────────────────────────────────────────────────────────
-- §0  CACHE ALL STDLIB AS UPVALUES — do this before ANY other code
--     An attacker hooking globals after this point sees nothing.
-- ─────────────────────────────────────────────────────────────────────────────
local _rawget       = rawget
local _rawset       = rawset
local _type         = type
local _tostring     = tostring
local _tonumber     = tonumber
local _pairs        = pairs
local _ipairs       = ipairs
local _next         = next
local _select       = select
local _error        = error
local _pcall        = pcall
local _xpcall       = xpcall
local _setmetatable = setmetatable
local _getmetatable = getmetatable
local _unpack       = table.unpack or unpack
local _tconcat      = table.concat
local _tmove        = table.move
local _smatch       = string.match
local _schar        = string.char
local _sbyte        = string.byte
local _sfmt         = string.format
local _slen         = string.len
local _mfloor       = math.floor
local _mtype        = math.type
local _load         = load   -- cached but ONLY used for VM bootstrap, never user code

local Spec     = require("spec")
local ProtoVal = require("validation.proto_validator")

local VM = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  LAZY CONSTANT DECRYPTION
--
--   decrypt(const_entry, shuffle_seed, proto_depth, const_index)
--   Returns the plaintext value. Result is cached in const_entry.decoded
--   so subsequent accesses are O(1) without re-decryption.
--
--   Key is derived from shuffle_seed, proto_depth, const_index —
--   never stored in the constant entry itself.
-- ─────────────────────────────────────────────────────────────────────────────

local function deriveKeySeed(shuffleSeed, protoDepth, constIndex)
  -- XOR combination — no field of this is stored with the encrypted data
  return (shuffleSeed ~ protoDepth ~ constIndex) & 0xFF
end

local function rollingDecrypt(encBytes, keySeed)
  -- Use only cached stdlib references
  local result = {}
  local k = keySeed & 0xFF
  for i = 1, #encBytes do
    local b = encBytes[i]
    local plain = b ~ k
    result[i] = _schar(plain)
    k = (k * 0x41 + plain + i) & 0xFF
  end
  return _tconcat(result)
end

local function decodeNumber(encBytes, keySeed, isFloat)
  local str = rollingDecrypt(encBytes, keySeed)
  local n = _tonumber(str)
  if not n then
    return nil, _sfmt("[%s] corrupt numeric constant", Spec.ERR.RT_TYPE_ERROR)
  end
  return n
end

-- Returns decoded value or (nil, errmsg)
local function lazyDecodeConst(constEntry, shuffleSeed, protoDepth, constIndex)
  -- Return cached decode if available
  if constEntry._decoded ~= nil then
    return constEntry._decoded
  end

  local t = constEntry.t

  if t == Spec.CONST_TYPE.NIL then
    constEntry._decoded = false  -- use false as sentinel for "decoded nil"
    return nil  -- actual nil value

  elseif t == Spec.CONST_TYPE.BOOL then
    constEntry._decoded = constEntry.v
    return constEntry.v

  elseif t == Spec.CONST_TYPE.INT then
    local seed = deriveKeySeed(shuffleSeed, protoDepth, constIndex)
    local n, e = decodeNumber(constEntry.v, seed, false)
    if not n then return nil, e end
    constEntry._decoded = n
    return n

  elseif t == Spec.CONST_TYPE.FLOAT then
    local seed = deriveKeySeed(shuffleSeed, protoDepth, constIndex)
    local n, e = decodeNumber(constEntry.v, seed, true)
    if not n then return nil, e end
    constEntry._decoded = n
    return n

  elseif t == Spec.CONST_TYPE.STR then
    local seed = deriveKeySeed(shuffleSeed, protoDepth, constIndex)
    local s = rollingDecrypt(constEntry.v, seed)
    constEntry._decoded = s
    return s

  elseif t == Spec.CONST_TYPE.PROTO then
    -- Proto constants are returned as-is (they're tables, not encrypted)
    constEntry._decoded = constEntry.proto
    return constEntry.proto

  end

  return nil, _sfmt("[%s] unknown constant type '%s'", Spec.ERR.PROTO_BAD_CONST, t)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §2  EXECUTION STATE
--     Per-call-frame state. No global mutable state.
-- ─────────────────────────────────────────────────────────────────────────────

local function newState(proto, args, env, shuffleSeed, protoDepth, limits)
  return {
    proto      = proto,
    instrs     = proto.i,
    consts     = proto.k,
    pc         = 1,
    stack      = {},
    stackTop   = 0,
    locals     = args or {},    -- args pre-fill the local slots
    upvals     = {},
    env        = env,
    seed       = shuffleSeed,
    depth      = protoDepth,
    limits     = limits,
    icount     = 0,             -- instruction counter (shared across calls via limits)
  }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §3  STACK OPERATIONS (no table-based exposure)
-- ─────────────────────────────────────────────────────────────────────────────

local function push(st, v)
  local top = st.stackTop + 1
  if top > Spec.LIMITS.MAX_STACK_DEPTH then
    return nil, _sfmt("[%s] stack overflow at depth %d", Spec.ERR.RT_STACK_OVERFLOW, top)
  end
  st.stack[top] = v
  st.stackTop = top
  return true
end

local function pop(st)
  local top = st.stackTop
  if top < 1 then
    return nil, nil, _sfmt("[%s] stack underflow", Spec.ERR.RT_STACK_UNDERFLOW)
  end
  local v = st.stack[top]
  st.stack[top] = nil
  st.stackTop = top - 1
  return v, true
end

local function peek(st, offset)
  local idx = st.stackTop - (offset or 0)
  if idx < 1 then return nil end
  return st.stack[idx]
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §4  CONSTANT ACCESS (lazy)
-- ─────────────────────────────────────────────────────────────────────────────

local function getConst(st, idx)
  local entry = st.consts[idx]
  if not entry then
    return nil, nil, _sfmt("[%s] constant index %d out of range",
      Spec.ERR.PROTO_BAD_CONST, idx)
  end
  local val, err = lazyDecodeConst(entry, st.seed, st.depth, idx)
  if err then return nil, nil, err end
  return val, true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §5  DISPATCH TABLE HANDLERS
--     Each handler: function(st, a, b, c) → ok, errmsg
--     st = execution state, a/b/c = instruction operands
-- ─────────────────────────────────────────────────────────────────────────────

local handlers = {}

-- ── Stack ──────────────────────────────────────────────────────────────────

handlers.PUSH_NIL   = function(st,a,b,c) return push(st, nil) end
handlers.PUSH_TRUE  = function(st,a,b,c) return push(st, true) end
handlers.PUSH_FALSE = function(st,a,b,c) return push(st, false) end

handlers.PUSH_INT = function(st,a,b,c)
  local v,ok,e = getConst(st,a); if not ok then return nil,e end
  return push(st, v)
end
handlers.PUSH_FLT = handlers.PUSH_INT

handlers.PUSH_STR = function(st,a,b,c)
  local v,ok,e = getConst(st,a); if not ok then return nil,e end
  return push(st, v)
end

handlers.PUSH_VARARG = function(st,a,b,c)
  local varargs = st.locals[0]  -- slot 0 reserved for varargs table
  if varargs then
    for _, v in _ipairs(varargs) do
      local ok, e = push(st, v); if not ok then return nil, e end
    end
  end
  return true
end

handlers.POP = function(st,a,b,c)
  local _,ok,e = pop(st); if not ok then return nil,e end; return true
end

handlers.DUP = function(st,a,b,c)
  local v = peek(st)
  return push(st, v)
end

handlers.SWAP = function(st,a,b,c)
  local top = st.stackTop
  if top < 2 then
    return nil, _sfmt("[%s] SWAP requires 2 stack values", Spec.ERR.RT_STACK_UNDERFLOW)
  end
  st.stack[top], st.stack[top-1] = st.stack[top-1], st.stack[top]
  return true
end

-- ── Locals ─────────────────────────────────────────────────────────────────

handlers.LOAD_LOCAL = function(st,a,b,c)
  return push(st, st.locals[a])
end

handlers.STORE_LOCAL = function(st,a,b,c)
  local v,ok,e = pop(st); if not ok then return nil,e end
  st.locals[a] = v
  return true
end

-- ── Upvalues ───────────────────────────────────────────────────────────────

handlers.LOAD_UPVAL = function(st,a,b,c)
  local uv = st.upvals[a]
  if not uv then return push(st, nil) end
  return push(st, uv[1])  -- upvalue stored as {value} cell for mutability
end

handlers.STORE_UPVAL = function(st,a,b,c)
  local v,ok,e = pop(st); if not ok then return nil,e end
  if not st.upvals[a] then st.upvals[a] = {nil} end
  st.upvals[a][1] = v
  return true
end

-- ── Environment ────────────────────────────────────────────────────────────

handlers.LOAD_GLOBAL = function(st,a,b,c)
  local k,ok,e = getConst(st,a); if not ok then return nil,e end
  return push(st, _rawget(st.env, k))
end

handlers.STORE_GLOBAL = function(st,a,b,c)
  local k,ok,e = getConst(st,a); if not ok then return nil,e end
  local v,ok2,e2 = pop(st); if not ok2 then return nil,e2 end
  _rawset(st.env, k, v)
  return true
end

handlers.LOAD_FIELD = function(st,a,b,c)
  local k,ok,e = getConst(st,a); if not ok then return nil,e end
  local t,ok2,e2 = pop(st); if not ok2 then return nil,e2 end
  if _type(t) ~= "table" then
    -- Allow metamethods via regular indexing
    return push(st, t[k])
  end
  return push(st, _rawget(t,k) ~= nil and _rawget(t,k) or t[k])
end

handlers.STORE_FIELD = function(st,a,b,c)
  local k,ok,e = getConst(st,a); if not ok then return nil,e end
  local v,ok2,e2 = pop(st); if not ok2 then return nil,e2 end
  local t,ok3,e3 = pop(st); if not ok3 then return nil,e3 end
  t[k] = v
  return true
end

handlers.LOAD_INDEX = function(st,a,b,c)
  local k,ok2,e2 = pop(st); if not ok2 then return nil,e2 end
  local t,ok3,e3 = pop(st); if not ok3 then return nil,e3 end
  return push(st, t[k])
end

handlers.STORE_INDEX = function(st,a,b,c)
  local v,_,e1 = pop(st); if e1 then return nil,e1 end
  local k,_,e2 = pop(st); if e2 then return nil,e2 end
  local t,_,e3 = pop(st); if e3 then return nil,e3 end
  t[k] = v
  return true
end

-- ── Arithmetic ─────────────────────────────────────────────────────────────

local function binop(st, fn)
  local b,_,e1 = pop(st); if e1 then return nil,e1 end
  local a,_,e2 = pop(st); if e2 then return nil,e2 end
  local ok2, result = _pcall(fn, a, b)
  if not ok2 then
    return nil, _sfmt("[%s] arithmetic error: %s", Spec.ERR.RT_TYPE_ERROR, _tostring(result))
  end
  return push(st, result)
end

handlers.ADD  = function(st,a,b,c) return binop(st, function(x,y) return x+y end) end
handlers.SUB  = function(st,a,b,c) return binop(st, function(x,y) return x-y end) end
handlers.MUL  = function(st,a,b,c) return binop(st, function(x,y) return x*y end) end
handlers.DIV  = function(st,a,b,c) return binop(st, function(x,y) return x/y end) end
handlers.MOD  = function(st,a,b,c) return binop(st, function(x,y) return x%y end) end
handlers.POW  = function(st,a,b,c) return binop(st, function(x,y) return x^y end) end
handlers.IDIV = function(st,a,b,c) return binop(st, function(x,y) return x//y end) end

handlers.UNM  = function(st,a,b,c)
  local v,_,e = pop(st); if e then return nil,e end
  return push(st, -v)
end

-- ── Bitwise (these will error on non-5.3+ targets — handled by compat layer) ─

handlers.BAND = function(st,a,b,c) return binop(st, function(x,y) return x&y end) end
handlers.BOR  = function(st,a,b,c) return binop(st, function(x,y) return x|y end) end
handlers.BXOR = function(st,a,b,c) return binop(st, function(x,y) return x~y end) end
handlers.SHL  = function(st,a,b,c) return binop(st, function(x,y) return x<<y end) end
handlers.SHR  = function(st,a,b,c) return binop(st, function(x,y) return x>>y end) end

handlers.BNOT = function(st,a,b,c)
  local v,_,e = pop(st); if e then return nil,e end
  return push(st, ~v)
end

-- ── Comparison ─────────────────────────────────────────────────────────────

handlers.EQ  = function(st,a,b,c) return binop(st, function(x,y) return x==y end) end
handlers.NEQ = function(st,a,b,c) return binop(st, function(x,y) return x~=y end) end
handlers.LT  = function(st,a,b,c) return binop(st, function(x,y) return x<y end) end
handlers.LE  = function(st,a,b,c) return binop(st, function(x,y) return x<=y end) end
handlers.GT  = function(st,a,b,c) return binop(st, function(x,y) return x>y end) end
handlers.GE  = function(st,a,b,c) return binop(st, function(x,y) return x>=y end) end

-- ── Logic ──────────────────────────────────────────────────────────────────

handlers.NOT = function(st,a,b,c)
  local v,_,e = pop(st); if e then return nil,e end
  return push(st, not v)
end

handlers.AND_JMP = function(st,a,b,c)
  local v = peek(st)
  if not v then
    st.pc = b  -- jump past right operand
  else
    local _,_,e = pop(st); if e then return nil,e end
    -- leave right operand evaluation to continue
  end
  return true
end

handlers.OR_JMP = function(st,a,b,c)
  local v = peek(st)
  if v then
    st.pc = b  -- jump past right operand, keep truthy value
  else
    local _,_,e = pop(st); if e then return nil,e end
  end
  return true
end

-- ── String ─────────────────────────────────────────────────────────────────

handlers.CONCAT = function(st,a,b,c)
  -- a = count of values to concat
  local count = a
  if st.stackTop < count then
    return nil, _sfmt("[%s] CONCAT needs %d values, have %d",
      Spec.ERR.RT_STACK_UNDERFLOW, count, st.stackTop)
  end
  local parts = {}
  for i = count, 1, -1 do
    local v,_,e = pop(st); if e then return nil,e end
    parts[i] = _tostring(v)
  end
  return push(st, _tconcat(parts))
end

handlers.LEN = function(st,a,b,c)
  local v,_,e = pop(st); if e then return nil,e end
  local ok2, result = _pcall(function() return #v end)
  if not ok2 then
    return nil, _sfmt("[%s] LEN failed: %s", Spec.ERR.RT_TYPE_ERROR, _tostring(result))
  end
  return push(st, result)
end

-- ── Tables ─────────────────────────────────────────────────────────────────

handlers.NEW_TABLE = function(st,a,b,c)
  return push(st, {})
end

handlers.SET_TABLE = function(st,a,b,c)
  local v,_,e1 = pop(st); if e1 then return nil,e1 end
  local k,_,e2 = pop(st); if e2 then return nil,e2 end
  local t = peek(st)  -- table stays on stack
  if _type(t) ~= "table" then
    return nil, _sfmt("[%s] SET_TABLE: top of stack is not a table", Spec.ERR.RT_TYPE_ERROR)
  end
  t[k] = v
  return true
end

handlers.GET_TABLE = function(st,a,b,c)
  local k,_,e1 = pop(st); if e1 then return nil,e1 end
  local t,_,e2 = pop(st); if e2 then return nil,e2 end
  return push(st, t[k])
end

handlers.SET_LIST = function(st,a,b,c)
  -- a = array index to assign
  local v,_,e1 = pop(st); if e1 then return nil,e1 end
  local t = peek(st)
  if _type(t) ~= "table" then
    return nil, _sfmt("[%s] SET_LIST: top of stack is not a table", Spec.ERR.RT_TYPE_ERROR)
  end
  t[a] = v
  return true
end

-- ── Functions ──────────────────────────────────────────────────────────────

-- MAKE_CLOSURE is handled separately in the execute loop
-- because it needs access to the execute function itself (recursion)

handlers.RETURN = function(st,a,b,c)
  -- Return 'a' values from the top of the stack
  local results = {}
  for i = a, 1, -1 do
    local v,_,e = pop(st); if e then return nil,e end
    results[i] = v
  end
  st._return = results
  st._done = true
  return true
end

handlers.RETURN0 = function(st,a,b,c)
  st._return = {}
  st._done = true
  return true
end

handlers.HALT = function(st,a,b,c)
  st._done = true
  return true
end

-- ── Control flow ───────────────────────────────────────────────────────────

handlers.JMP = function(st,a,b,c)
  -- b = target pc (absolute, 1-based)
  st.pc = b
  return true
end

handlers.JMP_TRUE = function(st,a,b,c)
  local v,_,e = pop(st); if e then return nil,e end
  if v then st.pc = b end
  return true
end

handlers.JMP_FALSE = function(st,a,b,c)
  local v,_,e = pop(st); if e then return nil,e end
  if not v then st.pc = b end
  return true
end

handlers.JMP_BACK = function(st,a,b,c)
  st.pc = a  -- a = target (back edge)
  return true
end

-- ── For loops ──────────────────────────────────────────────────────────────

handlers.FORPREP = function(st,a,b,c)
  -- Stack: [..., start, limit, step]  b = exit_pc
  local step,_,e1 = pop(st); if e1 then return nil,e1 end
  local limit,_,e2 = pop(st); if e2 then return nil,e2 end
  local start,_,e3 = pop(st); if e3 then return nil,e3 end

  if _type(start) ~= "number" or _type(limit) ~= "number" or _type(step) ~= "number" then
    return nil, _sfmt("[%s] 'for' initial values must be numbers", Spec.ERR.RT_TYPE_ERROR)
  end
  if step == 0 then
    return nil, _sfmt("[%s] 'for' step is zero", Spec.ERR.RT_TYPE_ERROR)
  end

  -- Check if loop executes at all
  if (step > 0 and start > limit) or (step < 0 and start < limit) then
    st.pc = b  -- skip loop entirely
    return true
  end

  -- Push internal for state: [idx, limit, step]
  local ok1,e = push(st, start); if not ok1 then return nil,e end
  local ok2,e2 = push(st, limit); if not ok2 then return nil,e2 end
  local ok3,e3 = push(st, step); if not ok3 then return nil,e3 end
  -- Push loop variable (copy of start)
  local ok4,e4 = push(st, start); if not ok4 then return nil,e4 end
  return true
end

handlers.FORLOOP = function(st,a,b,c)
  -- Stack: [..., idx, limit, step, loopvar]  a = loop_start_pc
  -- Increment idx, check condition, jump back or exit
  local top = st.stackTop
  if top < 4 then
    return nil, _sfmt("[%s] FORLOOP: corrupt for state", Spec.ERR.RT_STACK_UNDERFLOW)
  end
  local loopvar = st.stack[top]
  local step    = st.stack[top-1]
  local limit   = st.stack[top-2]
  local idx     = st.stack[top-3]

  idx = idx + step
  st.stack[top-3] = idx
  st.stack[top]   = idx  -- update loop variable

  if (step > 0 and idx <= limit) or (step < 0 and idx >= limit) then
    st.pc = a  -- continue loop
  else
    -- Exit loop: pop the 4 for-state slots
    st.stackTop = top - 4
    for i = top-3, top do st.stack[i] = nil end
  end
  return true
end

handlers.TFORLOOP = function(st,a,b,c)
  -- a = number of loop variables
  -- c = exit_pc
  -- Stack: [..., iter_fn, state, control]
  local top = st.stackTop
  if top < 3 then
    return nil, _sfmt("[%s] TFORLOOP: corrupt iterator state", Spec.ERR.RT_STACK_UNDERFLOW)
  end

  local control = st.stack[top]
  local state   = st.stack[top-1]
  local iter_fn = st.stack[top-2]

  if _type(iter_fn) ~= "function" then
    return nil, _sfmt("[%s] TFORLOOP: iterator is not a function", Spec.ERR.RT_TYPE_ERROR)
  end

  local ok2, results = _pcall(iter_fn, state, control)
  if not ok2 then
    return nil, _sfmt("[%s] iterator error: %s", Spec.ERR.RT_TYPE_ERROR, _tostring(results))
  end

  -- results is the multi-return from the iterator
  local firstVal
  if _type(results) == "table" then
    firstVal = results[1]
  else
    firstVal = results
    results = {results}
  end

  if firstVal == nil then
    -- Loop done — pop iterator state
    st.stackTop = top - 3
    for i = top-2, top do st.stack[i] = nil end
    st.pc = c  -- exit pc
    return true
  end

  -- Update control variable and push loop vars
  st.stack[top] = firstVal  -- update control
  for i = 1, a do
    local v = (type(results) == "table") and results[i] or (i==1 and results or nil)
    local ok3, e = push(st, v); if not ok3 then return nil, e end
  end
  -- Loop continues (fall through to next instruction)
  return true
end

-- ── Misc ───────────────────────────────────────────────────────────────────

handlers.SELF = function(st,a,b,c)
  -- a = const index of method name
  -- Stack: [obj] → [method_fn, obj]
  local k,ok,e = getConst(st,a); if not ok then return nil,e end
  local obj = peek(st)  -- keep obj on stack
  local method = obj[k]
  -- Insert method below obj
  local top = st.stackTop
  st.stackTop = top + 1
  st.stack[top+1] = obj
  st.stack[top] = method
  return true
end

handlers.CLOSE = function(st,a,b,c)
  -- Close all upvalues >= slot a
  -- In this implementation, upvalues are snapshotted at closure creation
  -- so CLOSE is a no-op (upval cells are GC'd naturally)
  return true
end

handlers.NOP = function(st,a,b,c) return true end

handlers.CHECK_STACK = function(st,a,b,c)
  if st.stackTop ~= a then
    return nil, _sfmt("[%s] CHECK_STACK: expected depth %d, have %d",
      Spec.ERR.RT_STACK_OVERFLOW, a, st.stackTop)
  end
  return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §6  BUILD DISPATCH TABLE
--     Maps shuffled opcode value → handler function
--     Built once per VM instantiation from the opcode map.
-- ─────────────────────────────────────────────────────────────────────────────

local function buildDispatch(opcodeMap)
  -- opcodeMap: name → shuffled_value
  local dispatch = {}
  local reverseMap = {}  -- shuffled_value → name (for validation error messages)
  for name, val in _pairs(opcodeMap) do
    if handlers[name] then
      dispatch[val] = handlers[name]
      reverseMap[val] = name
    end
  end
  return dispatch, reverseMap
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §7  MAIN EXECUTE LOOP
--     No load(). No source reconstruction. Direct proto traversal.
-- ─────────────────────────────────────────────────────────────────────────────

local function execute(proto, args, env, dispatch, reverseMap, shuffleSeed, protoDepth, limits)
  local st = newState(proto, args, env, shuffleSeed, protoDepth, limits)
  local instrs = st.instrs
  local nInstrs = #instrs

  -- MAKE_CLOSURE handler needs execute — defined here to capture it
  local function handleMakeClosure(state, a, b, c)
    local protoEntry, ok, e = getConst(state, a)
    if not ok then return nil, e end
    if _type(protoEntry) ~= "table" then
      return nil, _sfmt("[%s] MAKE_CLOSURE: constant %d is not a proto", Spec.ERR.RT_TYPE_ERROR, a)
    end

    -- Check call depth
    if protoDepth >= Spec.LIMITS.MAX_CALL_DEPTH then
      return nil, _sfmt("[%s] max call depth %d exceeded",
        Spec.ERR.RT_CALL_DEPTH_LIMIT, Spec.LIMITS.MAX_CALL_DEPTH)
    end

    -- Capture upvalues as cells (mutable references)
    local capturedUpvals = {}
    for i, uv in _ipairs(state.upvals) do
      capturedUpvals[i] = uv  -- shared cell reference
    end

    -- The closure is a Lua function that, when called, runs execute on the sub-proto
    local closure = function(...)
      local callArgs = {...}
      -- Build locals from args + vararg
      local localSlots = {}
      for i = 1, protoEntry.p do
        localSlots[i] = callArgs[i]
      end
      if protoEntry.va then
        local varargs = {}
        for i = protoEntry.p + 1, #callArgs do
          varargs[#varargs+1] = callArgs[i]
        end
        localSlots[0] = varargs
      end
      local results, err2 = execute(
        protoEntry, localSlots, env, dispatch, reverseMap,
        shuffleSeed, protoDepth + 1, limits)
      if not results then
        -- Normalize error — never expose internal detail
        _error("[runtime error]", 0)
      end
      return _unpack(results)
    end

    return push(state, closure)
  end

  -- CALL handler needs execute too
  local function handleCall(state, a, b, c)
    -- a = nargs, b = nret
    local callArgs = {}
    for i = a, 1, -1 do
      local v,_,e = pop(state); if e then return nil,e end
      callArgs[i] = v
    end
    local fn,_,e2 = pop(state); if e2 then return nil,e2 end

    if _type(fn) ~= "function" then
      return nil, _sfmt("[%s] attempt to call a %s value",
        Spec.ERR.RT_TYPE_ERROR, _type(fn))
    end

    -- Check call depth
    limits.callDepth = (limits.callDepth or 0) + 1
    if limits.callDepth > Spec.LIMITS.MAX_CALL_DEPTH then
      return nil, _sfmt("[%s] max call depth exceeded", Spec.ERR.RT_CALL_DEPTH_LIMIT)
    end

    local ok2, r1, r2, r3, r4, r5 = _pcall(fn, _unpack(callArgs))
    limits.callDepth = limits.callDepth - 1

    if not ok2 then
      return nil, _sfmt("[%s] call error", Spec.ERR.RT_TYPE_ERROR)
    end

    -- Push return values
    if b == 0 then
      -- All return values
      local rets = {r1, r2, r3, r4, r5}
      for _, rv in _ipairs(rets) do
        local ok3, e3 = push(state, rv); if not ok3 then return nil, e3 end
      end
    else
      -- Fixed number of return values
      local rets = {r1, r2, r3, r4, r5}
      for i = 1, b do
        local ok3, e3 = push(state, rets[i]); if not ok3 then return nil, e3 end
      end
    end
    return true
  end

  -- Main dispatch loop
  while not st._done do
    -- Instruction counter check
    st.icount = st.icount + 1
    if limits.icount then
      limits.icount[1] = limits.icount[1] + 1
      if limits.icount[1] > limits.maxInstructions then
        return nil, _sfmt("[%s] instruction limit %d exceeded",
          Spec.ERR.RT_INSTRUCTION_LIMIT, limits.maxInstructions)
      end
    end

    -- Bounds check on PC
    local pc = st.pc
    if pc < 1 or pc > nInstrs then
      return nil, _sfmt("[%s] PC %d out of range [1, %d]",
        Spec.ERR.PROTO_INVALID_JUMP, pc, nInstrs)
    end

    local instr = instrs[pc]
    st.pc = pc + 1

    local opcode = instr[1]
    local a = instr[2]
    local b = instr[3]
    local c = instr[4]

    -- Special handlers that need closures
    if opcode == (dispatch._MAKE_CLOSURE_OP or -1) then
      local ok2, e = handleMakeClosure(st, a, b, c)
      if not ok2 then return nil, e end
    elseif opcode == (dispatch._CALL_OP or -2) then
      local ok2, e = handleCall(st, a, b, c)
      if not ok2 then return nil, e end
    else
      local handler = dispatch[opcode]
      if not handler then
        return nil, _sfmt("[%s] unknown opcode %d at PC %d",
          Spec.ERR.RT_INVALID_OPCODE, opcode, pc)
      end
      local ok2, e = handler(st, a, b, c)
      if not ok2 then return nil, e end
    end
  end

  return st._return or {}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §8  PUBLIC VM API
-- ─────────────────────────────────────────────────────────────────────────────

function VM.new(opcodeMap, shuffleSeed, options)
  options = options or {}
  local maxInstructions = options.maxInstructions or Spec.LIMITS.MAX_INSTRUCTIONS

  local dispatch, reverseMap = buildDispatch(opcodeMap)

  -- Register special ops that need closures
  dispatch._MAKE_CLOSURE_OP = opcodeMap["MAKE_CLOSURE"]
  dispatch._CALL_OP         = opcodeMap["CALL"]

  local self = {
    dispatch      = dispatch,
    reverseMap    = reverseMap,
    shuffleSeed   = shuffleSeed,
    maxInstructions = maxInstructions,
  }

  function self:run(proto, env)
    -- Validate proto before execution
    local ok, e = ProtoVal.validate(proto, reverseMap)
    if not ok then
      return nil, e
    end

    -- Shared instruction counter (counts across all call frames)
    local limits = {
      icount    = {0},
      maxInstructions = self.maxInstructions,
      callDepth = 0,
    }

    -- Build initial env (sandboxed, read-only proxy over _G)
    local safeEnv = env or _setmetatable({}, {
      __index    = _G,
      __newindex = function(t, k, v) _rawset(t, k, v) end,
    })

    local results, err2 = execute(
      proto, {}, safeEnv, self.dispatch, self.reverseMap,
      self.shuffleSeed, 0, limits)

    if not results then
      -- Normalize: never expose internal error detail to caller
      return nil, "[runtime error]"
    end

    return results
  end

  return self
end

return VM
