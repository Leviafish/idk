--[[
  Levititas v3.1 — Proto Validator
  src/validation/proto_validator.lua

  Validates a compiled proto structure before the VM executes it.
  Catches:
    - Wrong bytecode version
    - Missing required fields
    - Invalid instruction format
    - Out-of-range jump targets
    - Invalid constant pool entries
    - Invalid opcode values
    - Circular proto references (nesting depth)
]]

local Spec = require("spec")

local ProtoValidator = {}

local function err(code, msg, ...)
  return nil, string.format("[%s] %s", code, string.format(msg, ...))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  Proto structure check
-- ─────────────────────────────────────────────────────────────────────────────

local REQUIRED_PROTO_FIELDS = { "v", "i", "k", "p", "va", "ul" }

local function checkProtoFields(proto)
  for _, f in ipairs(REQUIRED_PROTO_FIELDS) do
    if proto[f] == nil then
      return err(Spec.ERR.PROTO_MISSING_FIELD,
        "Proto missing required field '%s'", f)
    end
  end
  if type(proto.i) ~= "table" then
    return err(Spec.ERR.PROTO_MISSING_FIELD, "Proto 'i' (instructions) must be a table")
  end
  if type(proto.k) ~= "table" then
    return err(Spec.ERR.PROTO_MISSING_FIELD, "Proto 'k' (constants) must be a table")
  end
  if type(proto.p) ~= "number" then
    return err(Spec.ERR.PROTO_MISSING_FIELD, "Proto 'p' (params) must be a number")
  end
  if type(proto.va) ~= "boolean" then
    return err(Spec.ERR.PROTO_MISSING_FIELD, "Proto 'va' (vararg) must be a boolean")
  end
  return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §2  Version check
-- ─────────────────────────────────────────────────────────────────────────────

local function checkVersion(proto)
  local v = proto.v
  if type(v) ~= "number" then
    return err(Spec.ERR.PROTO_BAD_VERSION,
      "Bytecode version field must be a number, got %s", type(v))
  end
  if v < Spec.MIN_BYTECODE_VERSION or v > Spec.BYTECODE_VERSION then
    return err(Spec.ERR.PROTO_BAD_VERSION,
      "Bytecode version %d is not supported. This interpreter supports [%d, %d].",
      v, Spec.MIN_BYTECODE_VERSION, Spec.BYTECODE_VERSION)
  end
  return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §3  Instruction validation
-- ─────────────────────────────────────────────────────────────────────────────

local function checkInstructions(proto, validOpcodes)
  local instrs = proto.i
  local nInstrs = #instrs
  local nConsts = #proto.k

  if nInstrs > Spec.LIMITS.MAX_INSTRUCTIONS_PER_PROTO then
    return err(Spec.ERR.PROTO_BAD_INSTRUCTION,
      "Proto has %d instructions, limit is %d",
      nInstrs, Spec.LIMITS.MAX_INSTRUCTIONS_PER_PROTO)
  end

  for idx, instr in ipairs(instrs) do
    -- Must be a table of exactly 4 integers
    if type(instr) ~= "table" then
      return err(Spec.ERR.PROTO_BAD_INSTRUCTION,
        "Instruction %d is not a table (got %s)", idx, type(instr))
    end
    for field = 1, 4 do
      if type(instr[field]) ~= "number" then
        return err(Spec.ERR.PROTO_BAD_INSTRUCTION,
          "Instruction %d field %d is not a number (got %s)",
          idx, field, type(instr[field]))
      end
      if instr[field] < 0 then
        return err(Spec.ERR.PROTO_BAD_INSTRUCTION,
          "Instruction %d field %d is negative (%d)",
          idx, field, instr[field])
      end
    end

    local opcode = instr[1]
    -- Validate opcode is in the valid set
    if validOpcodes and not validOpcodes[opcode] then
      return err(Spec.ERR.PROTO_BAD_INSTRUCTION,
        "Instruction %d has unknown opcode %d", idx, opcode)
    end

    -- Validate jump targets (B and A fields for jump ops)
    -- We check all nonzero B/A values that could be jump targets
    local opName = validOpcodes and validOpcodes[opcode]
    if opName then
      local isJump = opName:match("^JMP") or
                     opName == "FORPREP" or opName == "FORLOOP" or
                     opName == "TFORLOOP" or opName == "AND_JMP" or
                     opName == "OR_JMP"
      if isJump then
        -- A (field 2) and B (field 3) may be jump targets
        for _, fieldIdx in ipairs({2, 3}) do
          local target = instr[fieldIdx]
          if target ~= 0 then
            if target < 1 or target > nInstrs + 1 then
              return err(Spec.ERR.PROTO_INVALID_JUMP,
                "Instruction %d (%s) field %d jump target %d is out of range [1, %d]",
                idx, opName, fieldIdx, target, nInstrs + 1)
            end
          end
        end
      end

      -- Validate constant references
      local usesConst = opName == "PUSH_INT" or opName == "PUSH_FLT" or
                        opName == "PUSH_STR" or opName == "LOAD_GLOBAL" or
                        opName == "STORE_GLOBAL" or opName == "LOAD_FIELD" or
                        opName == "STORE_FIELD" or opName == "SELF" or
                        opName == "MAKE_CLOSURE"
      if usesConst then
        local constIdx = instr[2]  -- A field
        if constIdx < 1 or constIdx > nConsts then
          return err(Spec.ERR.PROTO_BAD_INSTRUCTION,
            "Instruction %d (%s) references constant %d but pool has %d constants",
            idx, opName, constIdx, nConsts)
        end
      end
    end
  end

  return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §4  Constant pool validation
-- ─────────────────────────────────────────────────────────────────────────────

local VALID_CONST_TYPES = { i=true, f=true, s=true, b=true, n=true, p=true }

local function checkConstants(proto, depth)
  local consts = proto.k
  if #consts > Spec.LIMITS.MAX_CONST_POOL then
    return err(Spec.ERR.PROTO_BAD_CONST,
      "Constant pool has %d entries, limit is %d",
      #consts, Spec.LIMITS.MAX_CONST_POOL)
  end

  for idx, c in ipairs(consts) do
    if type(c) ~= "table" then
      return err(Spec.ERR.PROTO_BAD_CONST,
        "Constant %d is not a table (got %s)", idx, type(c))
    end
    if not c.t then
      return err(Spec.ERR.PROTO_BAD_CONST,
        "Constant %d missing type field 't'", idx)
    end
    if not VALID_CONST_TYPES[c.t] then
      return err(Spec.ERR.PROTO_BAD_CONST,
        "Constant %d has unknown type '%s'", idx, tostring(c.t))
    end

    -- Type-specific validation
    if c.t == "i" or c.t == "f" or c.t == "s" then
      -- Must have encrypted byte array
      if type(c.v) ~= "table" then
        return err(Spec.ERR.PROTO_BAD_CONST,
          "Constant %d (type '%s') must have 'v' as byte array table", idx, c.t)
      end
      for bi, byte in ipairs(c.v) do
        if type(byte) ~= "number" or byte < 0 or byte > 255 then
          return err(Spec.ERR.PROTO_BAD_CONST,
            "Constant %d byte %d is invalid: %s", idx, bi, tostring(byte))
        end
      end
    elseif c.t == "b" then
      if type(c.v) ~= "boolean" then
        return err(Spec.ERR.PROTO_BAD_CONST,
          "Constant %d (bool) must have boolean 'v'", idx)
      end
    elseif c.t == "p" then
      -- Sub-proto: validate recursively
      if type(c.proto) ~= "table" then
        return err(Spec.ERR.PROTO_BAD_CONST,
          "Constant %d (proto) must have 'proto' table", idx)
      end
      if depth >= Spec.LIMITS.MAX_PROTOS_NESTED then
        return err(Spec.ERR.PROTO_BAD_CONST,
          "Proto nesting at constant %d exceeds limit of %d",
          idx, Spec.LIMITS.MAX_PROTOS_NESTED)
      end
      local ok, e = ProtoValidator.validate(c.proto, nil, depth + 1)
      if not ok then return nil, e end
    end
    -- c.t == "n" : nil constant, no fields required
  end

  return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §5  Control flow reachability check (basic)
--     Detects trivially infinite loops (JMP_BACK to self with no exit)
-- ─────────────────────────────────────────────────────────────────────────────

local function checkReachability(proto, validOpcodes)
  -- Simple check: every instruction must be reachable from instruction 1
  -- via some path that doesn't always loop back.
  -- Full DFA is complex; we do a conservative check:
  -- If any JMP_BACK targets an instruction >= itself with no conditional
  -- between it and the target, that's a guaranteed infinite loop.
  -- We keep this lightweight — the instruction counter handles runtime cases.
  local instrs = proto.i
  for idx, instr in ipairs(instrs) do
    local opName = validOpcodes and validOpcodes[instr[1]]
    if opName == "JMP_BACK" then
      local target = instr[2]
      if target == idx then
        return err(Spec.ERR.PROTO_INVALID_JUMP,
          "Instruction %d: JMP_BACK to self (guaranteed infinite loop)", idx)
      end
    end
    if opName == "JMP" then
      local target = instr[3]  -- B field
      if target == idx then
        return err(Spec.ERR.PROTO_INVALID_JUMP,
          "Instruction %d: JMP to self (guaranteed infinite loop)", idx)
      end
    end
  end
  return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §6  Public API
-- ─────────────────────────────────────────────────────────────────────────────

-- validOpcodes: map of opcode_value → opcode_name (the shuffled map)
-- depth: nesting depth for sub-proto recursion (default 0)
function ProtoValidator.validate(proto, validOpcodes, depth)
  depth = depth or 0

  if type(proto) ~= "table" then
    return err(Spec.ERR.PROTO_MISSING_FIELD, "Proto must be a table, got %s", type(proto))
  end

  local ok, e

  ok, e = checkVersion(proto);           if not ok then return nil, e end
  ok, e = checkProtoFields(proto);       if not ok then return nil, e end
  ok, e = checkConstants(proto, depth);  if not ok then return nil, e end
  ok, e = checkInstructions(proto, validOpcodes)
  if not ok then return nil, e end
  ok, e = checkReachability(proto, validOpcodes)
  if not ok then return nil, e end

  return true
end

return ProtoValidator
