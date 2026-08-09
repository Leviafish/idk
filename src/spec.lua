--[[
================================================================================
  LEVITITAS v3.3 — FORMAL SPECIFICATION
  src/spec.lua

  This file is the single source of truth for:
    - Bytecode version
    - Opcode definitions and operand contracts
    - Proto format schema
    - AST node schemas
    - Error codes

  Every other module imports from this file.
  Nothing is defined twice.
================================================================================
]]

local Spec = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  BYTECODE VERSION
-- ─────────────────────────────────────────────────────────────────────────────

Spec.BYTECODE_VERSION = 3   -- increment on any breaking proto format change
Spec.MIN_BYTECODE_VERSION = 3  -- oldest version this interpreter accepts

-- ─────────────────────────────────────────────────────────────────────────────
-- §2  INSTRUCTION FORMAT
--
--   Every instruction is a table of exactly 4 integers: { OP, A, B, C }
--
--   OP  : opcode value (shuffled per build — look up via opcode map)
--   A   : first operand  (semantics defined per opcode below)
--   B   : second operand (semantics defined per opcode below)
--   C   : third operand  (semantics defined per opcode below)
--
--   Unused operands are always 0.
--   Operand types:
--     Kx  = index into the constant pool (1-based)
--     Lx  = local variable slot (1-based)
--     Jx  = absolute instruction index (1-based)
--     Ix  = immediate integer value
--     _   = unused (always 0)
-- ─────────────────────────────────────────────────────────────────────────────

Spec.OPCODE_NAMES = {
  -- ── Stack manipulation ──────────────────────────────────────────────
  -- Name           A        B        C      Stack effect
  "PUSH_NIL",    -- _        _        _      [] → [nil]
  "PUSH_TRUE",   -- _        _        _      [] → [true]
  "PUSH_FALSE",  -- _        _        _      [] → [false]
  "PUSH_INT",    -- Kx       _        _      [] → [K[A]]       (integer)
  "PUSH_FLT",    -- Kx       _        _      [] → [K[A]]       (float)
  "PUSH_STR",    -- Kx       _        _      [] → [decrypt(K[A])]
  "PUSH_VARARG", -- _        _        _      [] → [...] (spread)
  "POP",         -- _        _        _      [v] → []
  "DUP",         -- _        _        _      [v] → [v, v]
  "SWAP",        -- _        _        _      [a, b] → [b, a]

  -- ── Locals ─────────────────────────────────────────────────────────
  "LOAD_LOCAL",  -- Lx       _        _      [] → [locals[A]]
  "STORE_LOCAL", -- Lx       _        _      [v] → []  locals[A]=v

  -- ── Upvalues ───────────────────────────────────────────────────────
  "LOAD_UPVAL",  -- Ix       _        _      [] → [upvals[A]]
  "STORE_UPVAL", -- Ix       _        _      [v] → []  upvals[A]=v

  -- ── Environment ────────────────────────────────────────────────────
  "LOAD_GLOBAL", -- Kx       _        _      [] → [ENV[K[A]]]
  "STORE_GLOBAL",-- Kx       _        _      [v] → []  ENV[K[A]]=v
  "LOAD_FIELD",  -- Kx       _        _      [t] → [t[K[A]]]
  "STORE_FIELD", -- Kx       _        _      [v,t] → []  t[K[A]]=v
  "LOAD_INDEX",  -- _        _        _      [t,k] → [t[k]]
  "STORE_INDEX", -- _        _        _      [v,t,k] → []  t[k]=v

  -- ── Arithmetic ─────────────────────────────────────────────────────
  "ADD",         -- _        _        _      [a,b] → [a+b]
  "SUB",         -- _        _        _      [a,b] → [a-b]
  "MUL",         -- _        _        _      [a,b] → [a*b]
  "DIV",         -- _        _        _      [a,b] → [a/b]
  "MOD",         -- _        _        _      [a,b] → [a%b]
  "POW",         -- _        _        _      [a,b] → [a^b]
  "IDIV",        -- _        _        _      [a,b] → [a//b]
  "UNM",         -- _        _        _      [a] → [-a]

  -- ── Bitwise (Lua 5.3+ only) ────────────────────────────────────────
  "BAND",        -- _        _        _      [a,b] → [a&b]
  "BOR",         -- _        _        _      [a,b] → [a|b]
  "BXOR",        -- _        _        _      [a,b] → [a~b]
  "BNOT",        -- _        _        _      [a] → [~a]
  "SHL",         -- _        _        _      [a,b] → [a<<b]
  "SHR",         -- _        _        _      [a,b] → [a>>b]

  -- ── Comparison ─────────────────────────────────────────────────────
  "EQ",          -- _        _        _      [a,b] → [a==b]
  "NEQ",         -- _        _        _      [a,b] → [a~=b]
  "LT",          -- _        _        _      [a,b] → [a<b]
  "LE",          -- _        _        _      [a,b] → [a<=b]
  "GT",          -- _        _        _      [a,b] → [a>b]
  "GE",          -- _        _        _      [a,b] → [a>=b]

  -- ── Logic ──────────────────────────────────────────────────────────
  "NOT",         -- _        _        _      [a] → [not a]
  "AND_JMP",     -- _        Jx       _      [a] → [a] if falsy: pc=B, pop
  "OR_JMP",      -- _        Jx       _      [a] → [a] if truthy: pc=B, pop

  -- ── String / Length ────────────────────────────────────────────────
  "CONCAT",      -- Ix       _        _      [s1..sN] → [s1..sN]  A=count
  "LEN",         -- _        _        _      [v] → [#v]

  -- ── Tables ─────────────────────────────────────────────────────────
  "NEW_TABLE",   -- Ix       _        _      [] → [{}]  A=hint size
  "SET_TABLE",   -- _        _        _      [t,k,v] → []  t[k]=v
  "GET_TABLE",   -- _        _        _      [t,k] → [t[k]]
  "SET_LIST",    -- Ix       _        _      [t,v] → []  t[A]=v (array append)

  -- ── Functions ──────────────────────────────────────────────────────
  "MAKE_CLOSURE",-- Kx       _        _      [] → [closure]  proto=K[A]
  "CALL",        -- Ix       Ix       _      [...,fn] → [...]  A=nargs B=nret
  "TAILCALL",    -- Ix       _        _      [...,fn] → tail  A=nargs
  "RETURN",      -- Ix       _        _      pops A values, returns them
  "RETURN0",     -- _        _        _      returns nothing

  -- ── Control flow ───────────────────────────────────────────────────
  "JMP",         -- _        Jx       _      pc = B (unconditional)
  "JMP_TRUE",    -- _        Jx       _      [v] → []  if v then pc=B
  "JMP_FALSE",   -- _        Jx       _      [v] → []  if not v then pc=B
  "JMP_BACK",    -- Jx       _        _      pc = A (back-edge, loop)

  -- ── For loops ──────────────────────────────────────────────────────
  -- FORPREP: pops [start, limit, step], validates, pushes internal state,
  --          jumps to B if loop body should be skipped entirely
  "FORPREP",     -- _        Jx       _
  -- FORLOOP: increments counter, pushes loop var, jumps to A if continuing
  "FORLOOP",     -- Jx       _        _
  -- TFORLOOP: calls iterator, pushes results, jumps to C if done
  "TFORLOOP",    -- Ix       _        Jx    A=nvars  C=exit_pc

  -- ── Upvalue management ─────────────────────────────────────────────
  "CLOSE",       -- Lx       _        _      close upvals >= slot A
  "SELF",        -- Kx       _        _      [t] → [t[K[A]], t] (method call setup)

  -- ── Misc ───────────────────────────────────────────────────────────
  "NOP",         -- _        _        _      no operation
  "HALT",        -- _        _        _      stops execution
  "CHECK_STACK", -- Ix       _        _      assert stack depth == A (debug)
}

-- Build name→index mapping (canonical opcode IDs before shuffle)
Spec.CANONICAL_OPCODE = {}
for i, name in ipairs(Spec.OPCODE_NAMES) do
  if type(name) == "string" and not name:match("^%-") then
    Spec.CANONICAL_OPCODE[name] = i
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §3  PROTO FORMAT SCHEMA
--
--   A proto is the compiled representation of a Lua function.
--
--   {
--     v    : integer   -- bytecode version (must equal Spec.BYTECODE_VERSION)
--     i    : table     -- instruction list: array of {OP, A, B, C}
--     k    : table     -- constant pool: array of encrypted constant entries
--     p    : integer   -- number of fixed parameters
--     va   : boolean   -- accepts varargs
--     ul   : integer   -- number of upvalues
--     dbg  : string?   -- optional: source name for error messages
--   }
--
--   Constant pool entry formats (k[n]):
--     Integer:  { t="i", v=<encrypted_bytes> }
--     Float:    { t="f", v=<encrypted_bytes> }
--     String:   { t="s", v=<encrypted_bytes>, seed=<integer> }
--     Bool:     { t="b", v=true|false }          -- never encrypted
--     Nil:      { t="n" }                         -- never encrypted
--     Proto:    { t="p", proto=<proto_table> }    -- nested function
--
--   Encryption: rolling XOR. Key derived at execution time, NOT stored.
--   See §4 for key derivation.
-- ─────────────────────────────────────────────────────────────────────────────

Spec.CONST_TYPE = {
  INT   = "i",
  FLOAT = "f",
  STR   = "s",
  BOOL  = "b",
  NIL   = "n",
  PROTO = "p",
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §4  KEY DERIVATION
--
--   String constants are encrypted with a rolling XOR key.
--   The base seed is NOT stored with the constant.
--   It is derived at runtime as:
--
--     key_seed = (opcode_shuffle_seed XOR proto_depth XOR const_index) & 0xFF
--
--   Where:
--     opcode_shuffle_seed : integer stored in the file header (not secret,
--                           but makes precomputed rainbow tables useless)
--     proto_depth         : call depth of the proto (0 for root)
--     const_index         : 1-based index of this constant in k[]
--
--   The rolling XOR then proceeds as:
--     k = key_seed
--     for i = 1, #encrypted_bytes:
--       plain[i] = encrypted[i] XOR (k & 0xFF)
--       k = (k * 0x41 + plain[i] + i) & 0xFF
--
--   This means: to decrypt constant k[5] in a proto at depth 2,
--   with shuffle_seed=0x7F3A, the base key is (0x7F3A XOR 2 XOR 5) & 0xFF.
--   An attacker must know the shuffle_seed to precompute any key.
--   The shuffle_seed is in the file but changes every build.
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- §5  AST NODE SCHEMAS
--
--   Every parser output node must conform to one of these schemas.
--   The validator (src/validation/ast_validator.lua) enforces these at runtime.
--
--   Field type notation:
--     string       : Lua string
--     number       : Lua number
--     boolean      : Lua boolean
--     node         : any AST node (validated recursively)
--     node<Type>   : AST node of specific type
--     [node]       : array of nodes
--     [string]     : array of strings
--     ?X           : optional field of type X
-- ─────────────────────────────────────────────────────────────────────────────

Spec.AST_SCHEMAS = {
  Block        = { body = "[node]" },
  Assign       = { targets = "[node]", vals = "[node]" },
  Local        = { names = "[string]", attribs = "[?string]", vals = "[node]" },
  Do           = { body = "node<Block>" },
  While        = { cond = "node", body = "node<Block>" },
  Repeat       = { body = "node<Block>", cond = "node" },
  If           = { cond = "node", body = "node<Block>",
                   elseifs = "[{cond=node,body=node}]",
                   elsebody = "?node<Block>" },
  ForNum       = { var = "string", start = "node", limit = "node",
                   step = "?node", body = "node<Block>" },
  ForGen       = { vars = "[string]", iters = "[node]", body = "node<Block>" },
  Function     = { name = "string", fields = "[string]",
                   method = "?string", func = "node<FuncBody>" },
  LocalFunction= { name = "string", func = "node<FuncBody>" },
  FuncBody     = { params = "[string]", vararg = "boolean", body = "node<Block>" },
  Return       = { vals = "[node]" },
  Break        = {},
  Goto         = { label = "string" },
  Label        = { name = "string" },
  Call         = { func = "node", args = "[node]" },
  MethodCall   = { obj = "node", method = "string", args = "[node]" },
  Index        = { obj = "node", index = "node" },
  Field        = { obj = "node", field = "string" },
  Binop        = { op = "string", left = "node", right = "node" },
  Unop         = { op = "string", operand = "node" },
  Name         = { name = "string" },
  Number       = { val = "number" },
  String       = { val = "string" },
  Bool         = { val = "boolean" },
  Nil          = {},
  Vararg       = {},
  Table        = { fields = "[node<TableField>]" },
  TableField   = { key = "?node", val = "node" },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §6  ERROR CODES
--
--   All VM and compiler errors use these codes.
--   Error messages never expose internal variable names or line numbers
--   from the interpreter source.
-- ─────────────────────────────────────────────────────────────────────────────

Spec.ERR = {
  -- Parse errors
  PARSE_UNEXPECTED_TOKEN  = "P001",
  PARSE_INCOMPLETE        = "P002",
  PARSE_COVERAGE_FAIL     = "P003",

  -- Validation errors
  VALID_BAD_NODE_TYPE     = "V001",
  VALID_MISSING_FIELD     = "V002",
  VALID_WRONG_FIELD_TYPE  = "V003",

  -- Proto errors
  PROTO_BAD_VERSION       = "B001",
  PROTO_MISSING_FIELD     = "B002",
  PROTO_BAD_INSTRUCTION   = "B003",
  PROTO_INVALID_JUMP      = "B004",
  PROTO_BAD_CONST         = "B005",

  -- Runtime errors
  RT_INSTRUCTION_LIMIT    = "R001",
  RT_STACK_OVERFLOW       = "R002",
  RT_STACK_UNDERFLOW      = "R003",
  RT_INVALID_OPCODE       = "R004",
  RT_TYPE_ERROR           = "R005",
  RT_INTEGRITY_FAIL       = "R006",
  RT_CALL_DEPTH_LIMIT     = "R007",

  -- Compiler errors
  COMP_UNSUPPORTED_NODE   = "C001",
  COMP_UNSUPPORTED_OP     = "C002",
  COMP_GOTO_UNRESOLVED    = "C003",
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §7  RUNTIME LIMITS
-- ─────────────────────────────────────────────────────────────────────────────

Spec.LIMITS = {
  MAX_INSTRUCTIONS  = 10000000,  -- per execution; configurable via CLI
  MAX_STACK_DEPTH   = 2048,        -- stack slots
  MAX_CALL_DEPTH    = 200,         -- nested function calls
  MAX_CONST_POOL    = 65535,       -- constants per proto
  MAX_INSTRUCTIONS_PER_PROTO = 65535,
  MAX_PROTOS_NESTED = 64,          -- closure nesting depth
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §8  COMPATIBILITY MATRIX
--   See docs/compatibility.md for full rationale.
--   "full"    = all features supported, tested
--   "partial" = supported with documented exceptions
--   "none"    = not supported; hard error at compile time
-- ─────────────────────────────────────────────────────────────────────────────

Spec.COMPAT = {
  ["lua54"]   = "full",
  ["lua53"]   = "partial",  -- no <const>/<close>, integer semantics differ
  ["lua52"]   = "none",     -- no bitwise, no integer subtype, no goto
  ["lua51"]   = "none",     -- no bitwise, no goto, no integer subtype
  ["luajit"]  = "partial",  -- 5.1 semantics + bit library; no bitwise syntax
  ["luau"]    = "partial",  -- Roblox dialect; type annotations stripped
}

return Spec
