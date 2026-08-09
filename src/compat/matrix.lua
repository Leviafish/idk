--[[
================================================================================
  LEVITITAS v3.3 — COMPLETE COMPATIBILITY MATRIX
  src/compat/matrix.lua

  Every incompatibility between Lua versions documented.
  No assumptions. No silent degradation.
  This module is the authoritative reference for all compatibility decisions.
================================================================================
]]

local Matrix = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  SUPPORT STATUS
-- ─────────────────────────────────────────────────────────────────────────────

Matrix.SUPPORT = {
  lua51  = "none",     -- See §2.1
  lua52  = "none",     -- See §2.2
  lua53  = "partial",  -- See §2.3
  lua54  = "full",     -- See §2.4
  luajit = "partial",  -- See §2.5
  luau   = "partial",  -- See §2.6
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §2  PER-TARGET INCOMPATIBILITY CATALOG
-- ─────────────────────────────────────────────────────────────────────────────

Matrix.INCOMPATIBILITIES = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- §2.1  Lua 5.1 — UNSUPPORTED
--
-- Lua 5.1 is the oldest version still encountered in the wild (OpenResty,
-- some embedded systems, legacy game engines). The gap from 5.1 to 5.4 is
-- large enough that supporting it would require a separate compiler target
-- with fundamental changes to the VM instruction set.
-- ─────────────────────────────────────────────────────────────────────────────

Matrix.INCOMPATIBILITIES.lua51 = {

  -- SYNTAX DIFFERENCES
  {
    category  = "syntax",
    id        = "LUA51-S01",
    severity  = "fatal",
    feature   = "goto statement",
    desc      = "goto and :: labels do not exist in Lua 5.1. " ..
                "Any use of goto causes a syntax error.",
    example   = "goto done  -- SYNTAX ERROR in 5.1\n::done::",
    workaround= "Restructure control flow without goto.",
  },
  {
    category  = "syntax",
    id        = "LUA51-S02",
    severity  = "fatal",
    feature   = "Bitwise operators",
    desc      = "&, |, ~, <<, >> are not valid syntax in Lua 5.1. " ..
                "The bit library (LuaJIT) or bit32 library (5.2) must be used instead.",
    example   = "local x = a & b  -- SYNTAX ERROR in 5.1",
    workaround= "Use bit.band(a, b) from the LuaJIT bit library.",
  },
  {
    category  = "syntax",
    id        = "LUA51-S03",
    severity  = "fatal",
    feature   = "Floor division operator //",
    desc      = "// is not a valid operator in Lua 5.1.",
    example   = "local x = a // b  -- SYNTAX ERROR in 5.1",
    workaround= "Use math.floor(a / b).",
  },
  {
    category  = "syntax",
    id        = "LUA51-S04",
    severity  = "fatal",
    feature   = "Variable attributes <const> <close>",
    desc      = "local x <const> = v and local y <close> = z are 5.4+ only.",
    example   = "local x <const> = 1  -- SYNTAX ERROR in 5.1",
    workaround= "Remove attributes.",
  },
  {
    category  = "syntax",
    id        = "LUA51-S05",
    severity  = "fatal",
    feature   = "Integer hexadecimal floats",
    desc      = "0x1p4 hex float literals are not supported in 5.1.",
    example   = "local x = 0x1.8p1  -- SYNTAX ERROR in 5.1",
    workaround= "Use decimal literals.",
  },

  -- RUNTIME DIFFERENCES
  {
    category  = "runtime",
    id        = "LUA51-R01",
    severity  = "fatal",
    feature   = "table.unpack",
    desc      = "table.unpack does not exist in Lua 5.1. The global is 'unpack'.",
    example   = "table.unpack({1,2,3})  -- nil error in 5.1",
    workaround= "Use unpack() directly, or polyfill table.unpack = unpack.",
  },
  {
    category  = "runtime",
    id        = "LUA51-R02",
    severity  = "fatal",
    feature   = "math.type",
    desc      = "math.type does not exist in Lua 5.1 (no integer/float distinction).",
    example   = "math.type(1)  -- nil error in 5.1",
    workaround= "Remove math.type calls; all numbers are floats in 5.1.",
  },
  {
    category  = "runtime",
    id        = "LUA51-R03",
    severity  = "high",
    feature   = "string.format %q behavior",
    desc      = "In 5.1, %q may not escape all control characters identically to 5.4.",
    example   = "string.format('%q', '\\0')  -- may differ",
    workaround= "Avoid %q with binary data.",
  },
  {
    category  = "runtime",
    id        = "LUA51-R04",
    severity  = "fatal",
    feature   = "Metamethod __len on non-tables",
    desc      = "In 5.1, __len metamethod is not called for non-table/string values.",
    example   = "-- __len on userdata works in 5.4, not in 5.1",
    workaround= "Avoid __len on non-tables.",
  },
  {
    category  = "runtime",
    id        = "LUA51-R05",
    severity  = "high",
    feature   = "ipairs stops at nil",
    desc      = "In 5.1/5.2, ipairs stops at the first nil (same as 5.4). " ..
                "But the iterator itself is different. " ..
                "Metamethods (__index) are NOT consulted by ipairs in 5.1.",
    example   = "-- __index is not called by ipairs in 5.1",
    workaround= "Use pairs() if __index is needed.",
  },
  {
    category  = "runtime",
    id        = "LUA51-R06",
    severity  = "medium",
    feature   = "Module system (require / package)",
    desc      = "Lua 5.1 uses package.loaders, 5.2+ uses package.searchers. " ..
                "The semantics of require are similar but not identical.",
    example   = "package.loaders  -- nil in 5.2+",
    workaround= "Use package.searchers in 5.2+, package.loaders in 5.1.",
  },
  {
    category  = "runtime",
    id        = "LUA51-R07",
    severity  = "high",
    feature   = "String patterns %g class",
    desc      = "%g (printable non-space) character class added in 5.2.",
    example   = "string.match(s, '%g')  -- error in 5.1",
    workaround= "Use explicit character range instead.",
  },

  -- INTEGER/FLOAT DIFFERENCES
  {
    category  = "numeric",
    id        = "LUA51-N01",
    severity  = "fatal",
    feature   = "No integer subtype",
    desc      = "Lua 5.1 has a single 'number' type (double). " ..
                "There is no integer/float distinction. " ..
                "math.type, integer arithmetic, and integer overflow behavior " ..
                "from 5.3+ do not apply.",
    example   = "type(1) == 'number'  -- true, same as type(1.0)",
    workaround= "Treat all numbers as doubles.",
  },
  {
    category  = "numeric",
    id        = "LUA51-N02",
    severity  = "high",
    feature   = "Large integer precision",
    desc      = "Without integer type, numbers > 2^53 lose precision. " ..
                "5.3+ integers have exact 64-bit arithmetic.",
    example   = "print(2^53 + 1)  -- may print 2^53 in 5.1 (float precision lost)",
    workaround= "Avoid integers > 2^53 in 5.1 targets.",
  },

  -- CLOSURE DIFFERENCES
  {
    category  = "closure",
    id        = "LUA51-C01",
    severity  = "medium",
    feature   = "Upvalue sharing across closures",
    desc      = "Upvalue semantics are the same in 5.1-5.4 for the basic case. " ..
                "The debug library upvalue access API differs.",
    example   = "debug.getupvalue / debug.setupvalue behave differently",
    workaround= "Avoid debug library upvalue manipulation.",
  },

  -- COROUTINE DIFFERENCES
  {
    category  = "coroutine",
    id        = "LUA51-CO01",
    severity  = "medium",
    feature   = "coroutine.isyieldable",
    desc      = "coroutine.isyieldable does not exist in 5.1.",
    example   = "coroutine.isyieldable()  -- nil error in 5.1",
    workaround= "Use pcall to detect yieldability.",
  },
  {
    category  = "coroutine",
    id        = "LUA51-CO02",
    severity  = "medium",
    feature   = "coroutine.wrap error propagation",
    desc      = "Error propagation from wrapped coroutines differs slightly in 5.1.",
    example   = "-- errors in wrapped coroutines may not propagate identically",
    workaround= "Use coroutine.resume/yield directly for error handling.",
  },

  -- METATABLE DIFFERENCES
  {
    category  = "metatable",
    id        = "LUA51-M01",
    severity  = "medium",
    feature   = "__pairs and __ipairs metamethods",
    desc      = "__pairs metamethod was added in 5.2 and removed in 5.3+. " ..
                "Does not exist in 5.1.",
    example   = "setmetatable(t, {__pairs=fn})  -- ignored in 5.1",
    workaround= "Do not rely on __pairs metamethod.",
  },
  {
    category  = "metatable",
    id        = "LUA51-M02",
    severity  = "low",
    feature   = "__gc metamethod on tables",
    desc      = "__gc metamethod for tables is not supported in 5.1 " ..
                "(only userdata). Supported from 5.2+.",
    example   = "setmetatable(t, {__gc=fn})  -- ignored in 5.1",
    workaround= "Use userdata or 5.2+ target.",
  },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §2.2  Lua 5.2 — UNSUPPORTED
-- ─────────────────────────────────────────────────────────────────────────────

Matrix.INCOMPATIBILITIES.lua52 = {

  {
    category  = "syntax",
    id        = "LUA52-S01",
    severity  = "fatal",
    feature   = "Bitwise operators",
    desc      = "&, |, ~, <<, >> not available in 5.2 syntax. " ..
                "bit32 library available instead.",
    example   = "local x = a & b  -- SYNTAX ERROR in 5.2",
    workaround= "Use bit32.band(a, b). Not available in 5.4.",
  },
  {
    category  = "syntax",
    id        = "LUA52-S02",
    severity  = "fatal",
    feature   = "Floor division //",
    desc      = "// operator not in 5.2.",
    workaround= "Use math.floor(a / b).",
  },
  {
    category  = "syntax",
    id        = "LUA52-S03",
    severity  = "fatal",
    feature   = "Variable attributes",
    desc      = "<const> and <close> not in 5.2.",
    workaround= "Remove attributes.",
  },

  {
    category  = "runtime",
    id        = "LUA52-R01",
    severity  = "fatal",
    feature   = "No integer subtype",
    desc      = "Like 5.1, all numbers are doubles. " ..
                "math.type does not exist.",
    workaround= "Treat all numbers as doubles.",
  },
  {
    category  = "runtime",
    id        = "LUA52-R02",
    severity  = "medium",
    feature   = "goto available but limited",
    desc      = "goto was added in 5.2 but behavior with upvalues differs " ..
                "subtly from 5.4 in some edge cases.",
    workaround= "Test goto with upvalue access carefully.",
  },
  {
    category  = "runtime",
    id        = "LUA52-R03",
    severity  = "high",
    feature   = "Global environment model",
    desc      = "5.2 introduced _ENV as a local instead of the implicit " ..
                "global table. Code using _G or the old global model " ..
                "may behave differently.",
    example   = "-- _G is now a table inside _ENV, not the implicit global",
    workaround= "Avoid relying on implicit global semantics.",
  },
  {
    category  = "runtime",
    id        = "LUA52-R04",
    severity  = "medium",
    feature   = "package.searchers vs package.loaders",
    desc      = "5.2 renamed package.loaders to package.searchers.",
    workaround= "Use package.searchers for 5.2+ targets.",
  },
  {
    category  = "runtime",
    id        = "LUA52-R05",
    severity  = "medium",
    feature   = "string.gmatch behavior with empty matches",
    desc      = "Behavior of gmatch with patterns that can match empty " ..
                "strings differs between 5.1/5.2 and 5.3/5.4.",
    workaround= "Avoid patterns that match empty strings.",
  },
  {
    category  = "metatable",
    id        = "LUA52-M01",
    severity  = "low",
    feature   = "__pairs and __ipairs metamethods",
    desc      = "Added in 5.2, removed in 5.3. Only valid for 5.2 targets.",
    workaround= "Do not use if targeting multiple versions.",
  },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §2.3  Lua 5.3 — PARTIAL SUPPORT
-- ─────────────────────────────────────────────────────────────────────────────

Matrix.INCOMPATIBILITIES.lua53 = {

  {
    category  = "syntax",
    id        = "LUA53-S01",
    severity  = "fatal",
    feature   = "Variable attributes <const> <close>",
    desc      = "<const> and <close> are 5.4-only.",
    example   = "local x <const> = 1  -- SYNTAX ERROR in 5.3",
    workaround= "Remove attributes for 5.3 targets.",
  },

  {
    category  = "numeric",
    id        = "LUA53-N01",
    severity  = "medium",
    feature   = "Integer arithmetic overflow",
    desc      = "5.3 and 5.4 both have 64-bit integers, but overflow " ..
                "behavior is identical. Not an issue.",
    example   = "-- No difference between 5.3 and 5.4 integer overflow",
    workaround= "No action needed.",
  },
  {
    category  = "numeric",
    id        = "LUA53-N02",
    severity  = "medium",
    feature   = "Integer division by zero",
    desc      = "5.3 and 5.4 both raise an error for integer //0. " ..
                "Float division by zero produces inf/nan (same both versions).",
    workaround= "Check for zero before division.",
  },

  {
    category  = "runtime",
    id        = "LUA53-R01",
    severity  = "medium",
    feature   = "string.unpack / string.pack",
    desc      = "string.pack/unpack/packsize added in 5.3. Not in 5.1/5.2. " ..
                "Available and identical in 5.3 and 5.4.",
    workaround= "Only use if target is 5.3+.",
  },
  {
    category  = "runtime",
    id        = "LUA53-R02",
    severity  = "low",
    feature   = "utf8 library",
    desc      = "utf8 library added in 5.3. Available and identical in 5.3/5.4.",
    workaround= "Only use if target is 5.3+.",
  },
  {
    category  = "runtime",
    id        = "LUA53-R03",
    severity  = "medium",
    feature   = "tostring on integers",
    desc      = "In 5.3/5.4, tostring(1) == '1' (integer format). " ..
                "In 5.1/5.2, tostring(1) == '1' also, but tostring(1.0) == '1' " ..
                "in 5.1/5.2 whereas in 5.3/5.4 tostring(1.0) == '1.0'.",
    example   = "tostring(1.0)  -- '1' in 5.1, '1.0' in 5.3+",
    workaround= "Do not rely on tostring format for floats.",
  },
  {
    category  = "closure",
    id        = "LUA53-C01",
    severity  = "low",
    feature   = "Upvalue semantics",
    desc      = "Identical between 5.3 and 5.4.",
    workaround= "No action needed.",
  },
  {
    category  = "coroutine",
    id        = "LUA53-CO01",
    severity  = "medium",
    feature   = "coroutine.isyieldable",
    desc      = "Added in 5.3. Not available in 5.1/5.2.",
    workaround= "Only use if target is 5.3+.",
  },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §2.4  Lua 5.4 — FULL SUPPORT
-- ─────────────────────────────────────────────────────────────────────────────

Matrix.INCOMPATIBILITIES.lua54 = {
  {
    category  = "runtime",
    id        = "LUA54-R01",
    severity  = "low",
    feature   = "<close> to-be-closed semantics",
    desc      = "KNOWN LIMITATION: The CLOSE opcode is emitted but __close " ..
                "metamethod is not called at scope exit in the current VM. " ..
                "Tracked as CLOSE-INCOMPLETE. Scheduled for v3.3.",
    workaround= "Avoid <close> variables in scripts obfuscated with v3.2.",
  },
  {
    category  = "runtime",
    id        = "LUA54-R02",
    severity  = "low",
    feature   = "warn() function",
    desc      = "warn() added in 5.4. If used in obfuscated code, it passes " ..
                "through the ENV proxy correctly. No VM changes needed.",
    workaround= "No action needed.",
  },
  {
    category  = "runtime",
    id        = "LUA54-R03",
    severity  = "low",
    feature   = "Generalized for loop (to-be-closed values in for)",
    desc      = "5.4 allows to-be-closed values in numeric for. " ..
                "The compiler does not generate CLOSE in for loop exit paths.",
    workaround= "Avoid <close> in for loop variable lists.",
  },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §2.5  LuaJIT — PARTIAL SUPPORT
-- ─────────────────────────────────────────────────────────────────────────────

Matrix.INCOMPATIBILITIES.luajit = {

  {
    category  = "syntax",
    id        = "LJIT-S01",
    severity  = "fatal",
    feature   = "Bitwise operator syntax",
    desc      = "LuaJIT uses Lua 5.1 semantics. & | ~ << >> are not valid syntax. " ..
                "The 'bit' library provides bit.band(), bit.bor(), etc.",
    example   = "local x = a & b  -- SYNTAX ERROR in LuaJIT",
    workaround= "Rewrite using bit library. Use --target luajit flag.",
  },
  {
    category  = "syntax",
    id        = "LJIT-S02",
    severity  = "fatal",
    feature   = "Floor division //",
    desc      = "// not valid syntax in LuaJIT (5.1 base).",
    workaround= "Use math.floor(a / b) or bit.arshift for power-of-2 division.",
  },
  {
    category  = "syntax",
    id        = "LJIT-S03",
    severity  = "fatal",
    feature   = "Variable attributes",
    desc      = "<const> and <close> not supported.",
    workaround= "Remove attributes.",
  },
  {
    category  = "syntax",
    id        = "LJIT-S04",
    severity  = "medium",
    feature   = "goto statement",
    desc      = "goto is supported in LuaJIT 2.0.3+. Older versions do not support it.",
    workaround= "Avoid goto for maximum LuaJIT compatibility.",
  },

  {
    category  = "runtime",
    id        = "LJIT-R01",
    severity  = "fatal",
    feature   = "No integer subtype",
    desc      = "LuaJIT uses doubles for all numbers (5.1 semantics). " ..
                "math.type does not exist. Integer overflow is double overflow.",
    workaround= "Treat all numbers as doubles for LuaJIT targets.",
  },
  {
    category  = "runtime",
    id        = "LJIT-R02",
    severity  = "high",
    feature   = "FFI library",
    desc      = "LuaJIT provides ffi module not present in standard Lua. " ..
                "Scripts using ffi will fail on standard Lua.",
    workaround= "Wrap ffi usage in pcall(require, 'ffi') checks.",
  },
  {
    category  = "runtime",
    id        = "LJIT-R03",
    severity  = "medium",
    feature   = "table.unpack",
    desc      = "table.unpack does not exist in LuaJIT. Global unpack is available.",
    example   = "table.unpack({1,2,3})  -- nil error in LuaJIT",
    workaround= "Polyfill: table.unpack = table.unpack or unpack",
  },
  {
    category  = "runtime",
    id        = "LJIT-R04",
    severity  = "medium",
    feature   = "JIT compilation effects",
    desc      = "LuaJIT JIT-compiles hot code paths. Some behaviors that " ..
                "work in interpreted mode may not work when JIT-compiled " ..
                "(e.g. some metamethod combinations, coroutine boundaries).",
    workaround= "Test with jit.off() and jit.on() to detect JIT-specific bugs.",
  },
  {
    category  = "runtime",
    id        = "LJIT-R05",
    severity  = "low",
    feature   = "string.format %g behavior",
    desc      = "LuaJIT %g may format differently from 5.4 in edge cases.",
    workaround= "Do not rely on exact %g output format.",
  },
  {
    category  = "closure",
    id        = "LJIT-C01",
    severity  = "low",
    feature   = "Upvalue limit",
    desc      = "LuaJIT has a 60-upvalue limit per function (same as 5.1). " ..
                "Standard Lua 5.4 has 255.",
    workaround= "Keep upvalue count below 60 for LuaJIT compatibility.",
  },
  {
    category  = "coroutine",
    id        = "LJIT-CO01",
    severity  = "medium",
    feature   = "C callback coroutine suspension",
    desc      = "LuaJIT cannot yield across C function boundaries by default. " ..
                "This is a fundamental LuaJIT limitation.",
    workaround= "Avoid yielding from within C functions (e.g. socket callbacks).",
  },
  {
    category  = "numeric",
    id        = "LJIT-N01",
    severity  = "medium",
    feature   = "64-bit integer via FFI",
    desc      = "LuaJIT provides 64-bit integers via ffi.new('int64_t', n). " ..
                "These are not standard Lua numbers and behave differently.",
    workaround= "Use only standard Lua number operations.",
  },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §2.6  Luau (Roblox) — PARTIAL SUPPORT
-- ─────────────────────────────────────────────────────────────────────────────

Matrix.INCOMPATIBILITIES.luau = {

  {
    category  = "syntax",
    id        = "LUAU-S01",
    severity  = "medium",
    feature   = "Type annotations",
    desc      = "Luau adds optional type annotations not present in standard Lua. " ..
                "The Levititas parser does not parse Luau type syntax. " ..
                "Scripts with type annotations will fail to parse.",
    example   = "local x: number = 1  -- PARSE ERROR in Levititas",
    workaround= "Remove type annotations before obfuscation, or pre-process with roblox-ts.",
  },
  {
    category  = "syntax",
    id        = "LUAU-S02",
    severity  = "medium",
    feature   = "Compound assignment operators",
    desc      = "Luau supports +=, -=, *=, /= etc. Not in standard Lua.",
    example   = "x += 1  -- PARSE ERROR in Levititas",
    workaround= "Rewrite as x = x + 1.",
  },
  {
    category  = "syntax",
    id        = "LUAU-S03",
    severity  = "low",
    feature   = "continue statement",
    desc      = "Luau supports 'continue' in loops. Not in standard Lua.",
    example   = "continue  -- PARSE ERROR in Levititas",
    workaround= "Use goto or restructure loop.",
  },
  {
    category  = "syntax",
    id        = "LUAU-S04",
    severity  = "low",
    feature   = "String interpolation",
    desc      = "Luau supports `string {expr}` template syntax. Not in standard Lua.",
    example   = "local s = `hello {name}`  -- PARSE ERROR",
    workaround= "Use string.format or concatenation.",
  },

  {
    category  = "runtime",
    id        = "LUAU-R01",
    severity  = "high",
    feature   = "Sandbox restrictions",
    desc      = "Roblox sandboxes restrict or remove: io, os, debug, load, " ..
                "loadstring, dofile, require (replaced by Roblox require), " ..
                "and standard package system.",
    workaround= "Only use Roblox-compatible APIs. The generated interpreter " ..
                "uses load() internally — this may fail in Roblox sandboxes.",
  },
  {
    category  = "runtime",
    id        = "LUAU-R02",
    severity  = "high",
    feature   = "load() / loadstring() availability",
    desc      = "load() and loadstring() are not available in Roblox by default. " ..
                "The Levititas interpreter bootstrap uses load().",
    workaround= "Luau target currently CANNOT use the full VM. " ..
                "Source-level obfuscation only for Luau/Roblox targets.",
  },
  {
    category  = "runtime",
    id        = "LUAU-R03",
    severity  = "medium",
    feature   = "goto support",
    desc      = "Luau's goto support is limited and not recommended for Roblox scripts.",
    workaround= "Avoid goto for Luau targets.",
  },
  {
    category  = "runtime",
    id        = "LUAU-R04",
    severity  = "low",
    feature   = "coroutine.wrap behavior",
    desc      = "Luau coroutine.wrap propagates errors differently from standard Lua.",
    workaround= "Use coroutine.resume/yield directly for error handling.",
  },
  {
    category  = "numeric",
    id        = "LUAU-N01",
    severity  = "medium",
    feature   = "Integer subtype",
    desc      = "Luau has integer support similar to Lua 5.3+ in some versions, " ..
                "but behavior varies by Roblox platform version. Not guaranteed.",
    workaround= "Treat all numbers as doubles for maximum Luau compatibility.",
  },
  {
    category  = "metatable",
    id        = "LUAU-M01",
    severity  = "medium",
    feature   = "setmetatable restrictions",
    desc      = "Roblox restricts setmetatable on certain userdata types. " ..
                "setmetatable on Roblox Instance objects is not allowed.",
    workaround= "Only use setmetatable on plain Lua tables.",
  },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §3  COMPATIBILITY MATRIX TABLE (machine-readable)
-- ─────────────────────────────────────────────────────────────────────────────

Matrix.TABLE = {
  --[[
    Feature                  5.1   5.2   5.3   5.4   JIT   Luau
  ]]
  { "goto statement",        "no", "yes","yes","yes","yes*","partial" },
  { "Bitwise &|~<<>>",       "no", "no", "yes","yes","no",  "partial" },
  { "Floor division //",     "no", "no", "yes","yes","no",  "yes" },
  { "Integer subtype",       "no", "no", "yes","yes","no",  "partial" },
  { "Variable attributes",   "no", "no", "no", "yes","no",  "no" },
  { "table.unpack",          "no", "yes","yes","yes","no",  "yes" },
  { "math.type",             "no", "no", "yes","yes","no",  "partial" },
  { "string.pack/unpack",    "no", "no", "yes","yes","no",  "yes" },
  { "utf8 library",          "no", "no", "yes","yes","no",  "yes" },
  { "coroutine.isyieldable", "no", "no", "yes","yes","yes", "yes" },
  { "__pairs metamethod",    "no", "yes","no", "no", "no",  "no" },
  { "__gc on tables",        "no", "yes","yes","yes","yes*","yes" },
  { "__close metamethod",    "no", "no", "no", "yes","no",  "no" },
  { "_ENV model",            "no", "yes","yes","yes","no",  "partial" },
  { "package.searchers",     "no", "yes","yes","yes","no",  "no" },
  { "load() available",      "yes","yes","yes","yes","yes", "no" },
  { "Type annotations",      "no", "no", "no", "no", "no",  "yes" },
  { "Compound operators",    "no", "no", "no", "no", "no",  "yes" },
  { "continue keyword",      "no", "no", "no", "no", "no",  "yes" },
  { "String interpolation",  "no", "no", "no", "no", "no",  "yes" },
  -- yes* = with caveats documented above
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §4  SUPPORTED TARGETS FOR LEVITITAS v3.3
-- ─────────────────────────────────────────────────────────────────────────────

Matrix.LEVITITAS_SUPPORT = {
  {
    target      = "lua54",
    status      = "full",
    vm          = "full",
    notes       = "Primary target. All features. Full VM. " ..
                  "Known: <close> scope exit not yet implemented.",
    blocking    = {},
  },
  {
    target      = "lua53",
    status      = "partial",
    vm          = "full",
    notes       = "Full VM supported. No <const>/<close>. " ..
                  "tostring(float) format differs but VM handles correctly.",
    blocking    = {"LUA53-S01"},
  },
  {
    target      = "lua52",
    status      = "none",
    vm          = "none",
    notes       = "No bitwise syntax, no integer subtype. " ..
                  "Compiler target cannot be implemented without separate backend.",
    blocking    = {"LUA52-S01","LUA52-S02","LUA52-R01"},
  },
  {
    target      = "lua51",
    status      = "none",
    vm          = "none",
    notes       = "Too many fundamental incompatibilities. " ..
                  "Requires separate compiler and VM design.",
    blocking    = {"LUA51-S01","LUA51-S02","LUA51-S03","LUA51-R01","LUA51-N01"},
  },
  {
    target      = "luajit",
    status      = "partial",
    vm          = "source-level",
    notes       = "VM interpreter uses 5.4 syntax. For LuaJIT targets, " ..
                  "source-level obfuscation only (no VM wrapper). " ..
                  "Bitwise operators must use bit library.",
    blocking    = {"LJIT-S01","LJIT-S02","LJIT-R01"},
  },
  {
    target      = "luau",
    status      = "partial",
    vm          = "source-level",
    notes       = "load() not available in Roblox. VM cannot run. " ..
                  "Source-level only. Type annotations must be stripped first.",
    blocking    = {"LUAU-R01","LUAU-R02","LUAU-S01"},
  },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §5  QUERY API
-- ─────────────────────────────────────────────────────────────────────────────

function Matrix.getIncompatibilities(target, category, minSeverity)
  local all = Matrix.INCOMPATIBILITIES[target] or {}
  local severityRank = { fatal=4, high=3, medium=2, low=1 }
  local minRank = severityRank[minSeverity] or 0
  local result = {}
  for _, entry in ipairs(all) do
    local sev = severityRank[entry.severity] or 0
    local catMatch = (not category) or entry.category == category
    if catMatch and sev >= minRank then
      result[#result+1] = entry
    end
  end
  return result
end

function Matrix.getFatalIncompatibilities(target)
  return Matrix.getIncompatibilities(target, nil, "fatal")
end

function Matrix.isSupported(target)
  local s = Matrix.SUPPORT[target]
  return s == "full" or s == "partial", s
end

function Matrix.getVMSupport(target)
  for _, row in ipairs(Matrix.LEVITITAS_SUPPORT) do
    if row.target == target then return row.vm end
  end
  return "none"
end

function Matrix.printReport(target)
  print(string.format("\n=== Compatibility Report: %s ===", target))
  local support = Matrix.LEVITITAS_SUPPORT
  for _, row in ipairs(support) do
    if row.target == target then
      print(string.format("Status: %s | VM: %s", row.status, row.vm))
      print("Notes: " .. row.notes)
      if #row.blocking > 0 then
        print("Blocking issues: " .. table.concat(row.blocking, ", "))
      end
    end
  end
  local issues = Matrix.INCOMPATIBILITIES[target] or {}
  if #issues > 0 then
    print(string.format("\nIncompatibilities (%d):", #issues))
    for _, iss in ipairs(issues) do
      print(string.format("  [%s] %s (%s): %s",
        iss.id, iss.feature, iss.severity, iss.desc:sub(1,80)))
    end
  end
end

return Matrix
