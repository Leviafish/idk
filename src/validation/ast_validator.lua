--[[
  Levititas v3.3 — AST Validator
  src/validation/ast_validator.lua

  Validates that a parsed AST:
    1. Contains only known node types
    2. All required fields are present and correctly typed
    3. Coverage: the parse consumed exactly the full source token stream
    4. No partial parse situations are silently accepted

  This runs BEFORE the compiler sees the AST.
  If validation fails, obfuscation is aborted with a specific error code.
  We NEVER silently downgrade to a weaker protection path.
]]

local Spec = require("spec")

local Validator = {}
Validator.__index = Validator

-- ─────────────────────────────────────────────────────────────────────────────
-- Error builder
-- ─────────────────────────────────────────────────────────────────────────────

local function err(code, msg, ...)
  return nil, string.format("[%s] %s", code, string.format(msg, ...))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Node type validator
-- ─────────────────────────────────────────────────────────────────────────────

local KNOWN_TYPES = {}
for t in pairs(Spec.AST_SCHEMAS) do KNOWN_TYPES[t] = true end
-- FuncBody is produced by parser but not in top-level schema as a statement
KNOWN_TYPES["FuncBody"] = true

local validateField

local function validateNode(node, depth, path)
  depth = depth or 0
  path  = path  or "root"

  if depth > 512 then
    return err(Spec.ERR.VALID_BAD_NODE_TYPE, "AST too deep at %s", path)
  end

  if type(node) ~= "table" then
    return err(Spec.ERR.VALID_BAD_NODE_TYPE,
      "Expected node table at %s, got %s", path, type(node))
  end

  local t = node.type
  if not t then
    -- FuncBody nodes don't have .type — they have .params/.body/.vararg
    if node.params and node.body ~= nil and type(node.vararg) == "boolean" then
      -- valid FuncBody
      local ok, e = validateNode(node.body, depth+1, path..".body")
      if not ok then return nil, e end
      return true
    end
    return err(Spec.ERR.VALID_BAD_NODE_TYPE,
      "Node at %s has no .type field", path)
  end

  if not KNOWN_TYPES[t] then
    return err(Spec.ERR.VALID_BAD_NODE_TYPE,
      "Unknown node type '%s' at %s", t, path)
  end

  local schema = Spec.AST_SCHEMAS[t]
  if not schema then return true end  -- FuncBody handled above

  -- Check required fields
  for field, ftype in pairs(schema) do
    local optional = ftype:sub(1,1) == "?"
    local val = node[field]
    if val == nil and not optional then
      return err(Spec.ERR.VALID_MISSING_FIELD,
        "Node '%s' at %s missing required field '%s'", t, path, field)
    end
    if val ~= nil then
      local ok, e = validateField(val, ftype, depth, path.."."..field)
      if not ok then return nil, e end
    end
  end

  -- Recursively validate known child nodes
  local childFields = {
    body=true, cond=true, func=true, obj=true, left=true,
    right=true, operand=true, key=true, val=true,
  }
  for f, _ in pairs(childFields) do
    if node[f] and type(node[f]) == "table" then
      local ok, e = validateNode(node[f], depth+1, path.."."..f)
      if not ok then return nil, e end
    end
  end

  -- Validate array fields
  local arrayFields = {"body", "targets", "vals", "args", "iters", "fields", "elseifs"}
  for _, f in ipairs(arrayFields) do
    if node[f] and type(node[f]) == "table" then
      for i, child in ipairs(node[f]) do
        if type(child) == "table" then
          local ok, e = validateNode(child, depth+1,
            string.format("%s.%s[%d]", path, f, i))
          if not ok then return nil, e end
        end
      end
    end
  end

  return true
end

local function validateField(val, ftype, depth, path)
  -- Strip optional marker
  local ft = ftype:gsub("^%?", "")

  if ft == "string"  then
    if type(val) ~= "string"  then
      return err(Spec.ERR.VALID_WRONG_FIELD_TYPE,
        "Expected string at %s, got %s", path, type(val))
    end
    return true
  elseif ft == "number" then
    if type(val) ~= "number"  then
      return err(Spec.ERR.VALID_WRONG_FIELD_TYPE,
        "Expected number at %s, got %s", path, type(val))
    end
    return true
  elseif ft == "boolean" then
    if type(val) ~= "boolean" then
      return err(Spec.ERR.VALID_WRONG_FIELD_TYPE,
        "Expected boolean at %s, got %s", path, type(val))
    end
    return true
  elseif ft == "node" or ft:sub(1,5) == "node<" then
    return validateNode(val, depth+1, path)
  elseif ft:sub(1,1) == "[" then
    if type(val) ~= "table" then
      return err(Spec.ERR.VALID_WRONG_FIELD_TYPE,
        "Expected array at %s, got %s", path, type(val))
    end
    return true  -- element validation done in caller
  end
  return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Coverage validator
-- Checks that the parser consumed ALL tokens from the source.
-- A partial parse means some code was silently ignored.
-- ─────────────────────────────────────────────────────────────────────────────

local function validateCoverage(tokenCount, consumedCount)
  if consumedCount < tokenCount then
    return err(Spec.ERR.PARSE_COVERAGE_FAIL,
      "Parser consumed %d of %d tokens. %d tokens ignored. " ..
      "This indicates unsupported syntax. Obfuscation aborted. " ..
      "Use --target to specify your Lua version.",
      consumedCount, tokenCount, tokenCount - consumedCount)
  end
  return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

function Validator.validateAST(ast)
  if not ast then
    return err(Spec.ERR.VALID_BAD_NODE_TYPE, "AST is nil — parse failed")
  end
  return validateNode(ast, 0, "root")
end

function Validator.validateCoverage(tokenCount, consumedCount)
  return validateCoverage(tokenCount, consumedCount)
end

-- Validate that no goto remains unresolved after compilation
function Validator.validateGotoResolution(unresolvedGotos)
  if unresolvedGotos and #unresolvedGotos > 0 then
    local labels = {}
    for _, g in ipairs(unresolvedGotos) do
      labels[#labels+1] = string.format("'%s'", g.label)
    end
    return err(Spec.ERR.COMP_GOTO_UNRESOLVED,
      "Unresolved goto labels: %s", table.concat(labels, ", "))
  end
  return true
end

return Validator
