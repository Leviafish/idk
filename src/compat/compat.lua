--[[
================================================================================
  Levititas v3.3 — COMPATIBILITY FACADE
  src/compat/compat.lua

  Public API consumed by:
    levititas.lua (CLI)     — Compat.supportMatrix()
    src/levititas.lua       — Compat.audit(ast, target)
                              Compat.formatIssues(issues)

  This module wraps compat.matrix and provides the three entry-points
  expected by the rest of the engine.  It does NOT add new checks —
  stability > features.
================================================================================
]]

local Matrix = require("compat.matrix")

local Compat = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  INTERNAL HELPERS
-- ─────────────────────────────────────────────────────────────────────────────

-- Recursively walk an AST node, calling visit(node) for every table node.
-- Avoids infinite loops on circular references by tracking visited tables.
local function walkAST(node, visit, seen)
  if type(node) ~= "table" then return end
  seen = seen or {}
  if seen[node] then return end
  seen[node] = true
  visit(node)
  for _, v in pairs(node) do
    walkAST(v, visit, seen)
  end
end

-- Severity comparator used to decide pass/fail
local SEV_RANK = { fatal = 4, high = 3, medium = 2, low = 1, info = 0 }

local function sevRank(s) return SEV_RANK[s] or 0 end

-- ─────────────────────────────────────────────────────────────────────────────
-- §2  AST-LEVEL COMPATIBILITY CHECKS
--
-- These checks supplement the Matrix data with source-AST observations.
-- Only checks that are relevant to currently-partial targets (lua53, luajit,
-- luau) are included.  lua51/lua52 are rejected by server.py before we run.
-- ─────────────────────────────────────────────────────────────────────────────

-- Binop operators that require Lua 5.3+ integer subtype semantics
local BITWISE_OPS = { ["&"]=true, ["|"]=true, ["~"]=true, ["<<"]=true, [">>"]=true, ["//"]=true }
-- Unary bitwise NOT
local UNARY_BITNOT = "~"

-- Per-target restrictions detected at AST level
local function checkNode(node, target, issues)
  local t = node.type
  if not t then return end

  -- Bitwise operators on targets that do not support them
  if t == "Binop" and BITWISE_OPS[node.op] then
    if target == "luajit" then
      issues[#issues+1] = {
        severity = "high",
        feature  = node.op,
        desc     = string.format(
          "Operator '%s' requires the bit library on LuaJIT (not native syntax). "
          .. "The VM wrapper handles this for VM-mode; source-level output may fail.",
          node.op),
      }
    end
  end

  -- Unary bitwise NOT on LuaJIT
  if t == "Unop" and node.op == UNARY_BITNOT and target == "luajit" then
    issues[#issues+1] = {
      severity = "high",
      feature  = "~(unary)",
      desc     = "Unary bitwise NOT '~' is not valid syntax in LuaJIT.",
    }
  end

  -- load() on Luau — VM wrapper depends on load(); Luau forbids it
  if t == "Call" and target == "luau" then
    local fn = node.func
    if fn and fn.type == "Id" and fn.name == "load" then
      issues[#issues+1] = {
        severity = "fatal",
        feature  = "load()",
        desc     = "load() is not available in Luau/Roblox. "
                .. "The VM wrapper cannot execute in Luau. "
                .. "Use source-level obfuscation only.",
      }
    end
  end

  -- <const> / <close> attributes — 5.4 only, will break lua53
  if t == "Local" and node.attrib then
    local a = node.attrib
    if (a == "const" or a == "close") and target == "lua53" then
      issues[#issues+1] = {
        severity = "fatal",
        feature  = string.format("<%s>", a),
        desc     = string.format(
          "Local attribute <%s> is Lua 5.4 syntax and will not parse on lua53.",
          a),
      }
    end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §3  PUBLIC API
-- ─────────────────────────────────────────────────────────────────────────────

--[[
  Compat.audit(ast, target) → ok:boolean, issues:table

  Runs a two-pass compatibility check:
    Pass 1 — Matrix support status (hard gate for unsupported targets).
    Pass 2 — AST-level walk for partial-target warnings.

  Returns:
    true,  {}        — fully compatible
    true,  {issues}  — compatible with warnings
    false, {issues}  — incompatible; at least one fatal issue present
]]
function Compat.audit(ast, target)
  -- Pass 1: hard support gate
  local supported, status = Matrix.isSupported(target)
  if not supported then
    return false, {
      {
        severity = "fatal",
        feature  = target,
        desc     = string.format(
          "Target '%s' is not supported by Levititas (status: %s). "
          .. "Supported targets: lua53, lua54, luajit (source-level), luau (source-level).",
          target, tostring(status)),
      }
    }
  end

  -- Pass 2: AST walk
  local issues = {}
  if type(ast) == "table" then
    walkAST(ast, function(node)
      checkNode(node, target, issues)
    end)
  end

  -- Determine pass/fail from issue severity
  for _, issue in ipairs(issues) do
    if sevRank(issue.severity) >= sevRank("fatal") then
      return false, issues
    end
  end

  return true, issues
end

--[[
  Compat.formatIssues(issues) → string

  Formats an issues table returned by Compat.audit() into a human-readable
  multi-line string suitable for error messages.
]]
function Compat.formatIssues(issues)
  if not issues or #issues == 0 then
    return "(no issues)"
  end
  local lines = {}
  for _, issue in ipairs(issues) do
    lines[#lines+1] = string.format(
      "  [%s] %s — %s",
      (issue.severity or "?"):upper(),
      tostring(issue.feature or "?"),
      tostring(issue.desc   or ""))
  end
  return table.concat(lines, "\n")
end

--[[
  Compat.supportMatrix() → table of rows

  Returns the support matrix as an array of:
    { target, status, vm, notes }

  Consumed by the CLI --compat-report flag.
]]
function Compat.supportMatrix()
  local result = {}
  for _, row in ipairs(Matrix.LEVITITAS_SUPPORT) do
    result[#result+1] = {
      target = row.target,
      status = row.status,
      vm     = row.vm or "none",
      notes  = row.notes or "",
    }
  end
  return result
end

return Compat
