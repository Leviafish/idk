--[[
================================================================================
  LEVITITAS v3.3 — MODULE SYSTEM & WORKSPACE AUDIT
  docs/workspace_audit.md (embedded as Lua for programmatic access)

  Reviews: require(), import/export, dependency graph,
  circular dependency detection, symbol consistency,
  module identity stability, incremental rebuild safety.
================================================================================
]]

local WorkspaceAudit = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  REQUIRE() BEHAVIOR IN LEVITITAS
-- ─────────────────────────────────────────────────────────────────────────────

WorkspaceAudit.REQUIRE_ANALYSIS = {

  --[[
    How require() works in obfuscated scripts:

    When a script calls require('module'), the call goes through the VM's
    CALL opcode to the 'require' function in ENV. ENV.__index points to _G,
    so the standard require function is called.

    This means:
    - require() works correctly in obfuscated scripts
    - The module loading mechanism is NOT obfuscated
    - Module paths are visible as string constants in the proto

    Risk: An attacker can read the constant pool and see all require() paths,
    revealing the dependency structure of the obfuscated script.

    Recommendation: Obfuscate module paths if they are sensitive.
    The string encryption layer handles this automatically.
  ]]

  {
    id     = "WS-REQ-01",
    topic  = "require() path visibility",
    status = "MITIGATED",
    detail = "require() paths are string constants and are encrypted " ..
             "by the rolling XOR layer. An attacker cannot read them " ..
             "from the serialized proto without the decryption key.",
  },

  --[[
    Multiple calls to require('x') return the same module object.
    This is handled by Lua's package.loaded cache, which the VM
    does not interfere with.
  ]]
  {
    id     = "WS-REQ-02",
    topic  = "Module identity (package.loaded cache)",
    status = "CORRECT",
    detail = "The VM calls the real require() function, which uses " ..
             "package.loaded. Module identity is stable: require('x') " ..
             "always returns the same object within a Lua process.",
  },

  --[[
    Circular dependencies: A requires B, B requires A.
    Standard Lua handles this by returning whatever is in package.loaded
    at the time of the second require() call (which may be incomplete).
    The VM does not change this behavior.
  ]]
  {
    id     = "WS-REQ-03",
    topic  = "Circular dependency behavior",
    status = "INHERITED",
    detail = "Circular dependencies behave exactly as in standard Lua: " ..
             "the second require() returns the incomplete module table. " ..
             "No special handling needed. No VM changes required.",
    risk   = "If a circular dependency exists in obfuscated code, " ..
             "it will fail in the same way as unobfuscated code.",
  },

  --[[
    require() is called through the ENV proxy, not directly.
    If the user's ENV does not have require, it will look it up in _G.__index.
    This works correctly as long as _G.require is available.
  ]]
  {
    id     = "WS-REQ-04",
    topic  = "require() through ENV proxy",
    status = "CORRECT",
    detail = "ENV = setmetatable({}, {__index=_G}). " ..
             "require() lookup: ENV.require → _G.require. " ..
             "Works correctly in all standard Lua environments.",
    risk   = "In sandboxed environments (Roblox, restricted servers) " ..
             "where require() is not in _G or is replaced, the lookup " ..
             "will find the sandbox's require(), not standard Lua's. " ..
             "This is correct behavior.",
  },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §2  DEPENDENCY GRAPH
-- ─────────────────────────────────────────────────────────────────────────────

WorkspaceAudit.DEPENDENCY_GRAPH = {

  -- Levititas v3.3 internal module dependencies
  -- Format: module → {dependencies}

  ["spec"]              = {},
  ["parser.parser"]     = {"spec"},
  ["validation.ast_validator"] = {"spec"},
  ["validation.proto_validator"] = {"spec"},
  ["compiler.compiler"] = {"spec", "validation.ast_validator", "vm.opcodes"},
  ["vm.opcodes"]        = {"spec"},
  ["vm.core"]           = {"spec", "validation.proto_validator"},
  ["compat.compat"]     = {"spec"},
  ["compat.matrix"]     = {},
  ["levititas"]         = {
    "spec", "parser.parser", "validation.ast_validator",
    "validation.proto_validator", "compiler.compiler",
    "compat.compat", "vm.opcodes", "vm.core",
  },

  -- Analysis:
  -- - No circular dependencies
  -- - spec has no dependencies (safe root)
  -- - vm.opcodes depends only on spec
  -- - compiler depends on vm.opcodes (for opcode map generation)
  -- - levititas is the leaf that depends on everything
}

WorkspaceAudit.CIRCULAR_DEPS = {
  -- Detected: NONE
  -- The dependency graph is a DAG (directed acyclic graph).
  detected = false,
  cycles   = {},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §3  SYMBOL CONSISTENCY
-- ─────────────────────────────────────────────────────────────────────────────

WorkspaceAudit.SYMBOL_CONSISTENCY = {

  {
    id     = "WS-SYM-01",
    topic  = "Opcode names defined exactly once",
    status = "CORRECT",
    detail = "All opcode names are defined in Spec.OPCODE_NAMES. " ..
             "Compiler, VM, and validator all import from Spec. " ..
             "No opcode name is hardcoded outside of Spec.",
  },

  {
    id     = "WS-SYM-02",
    topic  = "Error codes defined exactly once",
    status = "CORRECT",
    detail = "All error codes are in Spec.ERR. " ..
             "All modules use Spec.ERR.XXX, never string literals. " ..
             "A grep for '[A-Z]\\d{3}' outside Spec.ERR would catch violations.",
  },

  {
    id     = "WS-SYM-03",
    topic  = "Runtime limits defined exactly once",
    status = "CORRECT",
    detail = "Spec.LIMITS is the single source for all numeric limits. " ..
             "VM core, CLI, and server all read from Spec.LIMITS.",
    risk   = "The server.py reads MAX_INSTRUCTIONS from Python code, " ..
             "not from Spec. If Spec.LIMITS.MAX_INSTRUCTIONS changes, " ..
             "server.py must be updated manually. RECOMMENDATION: " ..
             "Pass --max-instr from CLI instead of hardcoding in server.",
  },

  {
    id     = "WS-SYM-04",
    topic  = "Bytecode version checked at both compile and validate time",
    status = "CORRECT",
    detail = "Compiler sets proto.v = Spec.BYTECODE_VERSION. " ..
             "ProtoValidator checks proto.v against Spec.MIN_BYTECODE_VERSION " ..
             "and Spec.BYTECODE_VERSION. Version incompatibility is a hard error.",
  },

  {
    id     = "WS-SYM-05",
    topic  = "AST node type strings",
    status = "RISK",
    detail = "AST node types are string literals ('Block', 'Local', etc.) " ..
             "in both the parser output and compiler pattern-matching. " ..
             "A typo in either place causes a silent compile failure " ..
             "(unsupported node error) rather than a clear type error.",
    recommendation = "Define node type constants in Spec (similar to Spec.CONST_TYPE) " ..
                     "and use those constants in both parser and compiler. " ..
                     "This makes typos compile-time detectable.",
  },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §4  INCREMENTAL REBUILD SAFETY
-- ─────────────────────────────────────────────────────────────────────────────

WorkspaceAudit.INCREMENTAL_REBUILD = {

  {
    id     = "WS-INC-01",
    topic  = "Changing Spec.BYTECODE_VERSION",
    impact = "HIGH",
    detail = "Bumping BYTECODE_VERSION invalidates all previously compiled protos. " ..
             "Old obfuscated files will fail with PROTO_BAD_VERSION. " ..
             "This is intentional and correct behavior.",
    action = "When bumping BYTECODE_VERSION, re-obfuscate all production scripts. " ..
             "Document the version bump in CHANGELOG.",
  },

  {
    id     = "WS-INC-02",
    topic  = "Changing opcode names in Spec.OPCODE_NAMES",
    impact = "HIGH",
    detail = "Adding/removing/renaming opcodes requires updating: " ..
             "Spec (name list), compiler (emit calls), VM handlers, " ..
             "and bumping BYTECODE_VERSION. " ..
             "Failure to bump version causes silent wrong behavior.",
    action = "Always bump BYTECODE_VERSION when changing opcodes.",
  },

  {
    id     = "WS-INC-03",
    topic  = "Changing compiler output format",
    impact = "HIGH",
    detail = "Any change to how instructions or constants are serialized " ..
             "must be accompanied by a BYTECODE_VERSION bump.",
    action = "Add a changelog entry for every serialization format change.",
  },

  {
    id     = "WS-INC-04",
    topic  = "Changing Spec.LIMITS",
    impact = "LOW",
    detail = "Runtime limits can be changed without breaking compiled protos. " ..
             "They are runtime parameters, not bytecode-level.",
    action = "No version bump needed for limit changes.",
  },

  {
    id     = "WS-INC-05",
    topic  = "Changing VM handler behavior",
    impact = "MEDIUM",
    detail = "Fixing a bug in a VM handler (e.g. TFORLOOP) changes runtime " ..
             "behavior of previously compiled protos. Old protos may now " ..
             "behave differently (hopefully correctly).",
    action = "Document behavior changes. Add regression tests for the fix.",
  },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §5  ARCHITECTURAL RECOMMENDATIONS
-- ─────────────────────────────────────────────────────────────────────────────

WorkspaceAudit.RECOMMENDATIONS = {

  {
    priority = "HIGH",
    title    = "Define AST node type constants in Spec",
    detail   = "Replace string literals like 'Block', 'Local' with " ..
               "Spec.NODE.BLOCK, Spec.NODE.LOCAL etc. " ..
               "Eliminates silent typo bugs in compiler.",
    effort   = "2 hours — search/replace throughout parser and compiler.",
  },

  {
    priority = "HIGH",
    title    = "Pass runtime limits via CLI, not hardcoded in server.py",
    detail   = "server.py hardcodes max_instructions=10_000_000. " ..
               "Should read from Spec via the CLI --max-instr flag. " ..
               "Currently if Spec.LIMITS changes, server.py is stale.",
    effort   = "30 minutes.",
  },

  {
    priority = "MEDIUM",
    title    = "Add CHANGELOG.md tracking bytecode version changes",
    detail   = "Every BYTECODE_VERSION bump should be documented with: " ..
               "version, date, what changed, migration notes.",
    effort   = "Ongoing — one entry per version.",
  },

  {
    priority = "MEDIUM",
    title    = "Add module dependency validation to test suite",
    detail   = "Automated test that walks the actual require() graph " ..
               "and verifies it matches WorkspaceAudit.DEPENDENCY_GRAPH. " ..
               "Catches accidental new circular dependencies.",
    effort   = "1 hour.",
  },

  {
    priority = "LOW",
    title    = "Consider package.path isolation for test runs",
    detail   = "Tests currently modify package.path globally. " ..
               "In a large test suite, module state leaks between tests. " ..
               "Use a fresh Lua process per test suite category.",
    effort   = "30 minutes — add per-category subprocess runs to run_tests.sh.",
  },
}

return WorkspaceAudit
