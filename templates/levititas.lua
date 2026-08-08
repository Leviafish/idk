#!/usr/bin/env lua
--[[
  Levititas v3.1 — CLI
  levititas.lua

  Usage: lua levititas.lua <input.lua> [options]
]]

local DIR = (debug.getinfo(1,"S").source:match("@(.*)") or ""):match("(.*[/\\])") or "./"
package.path = DIR.."src/?.lua;"..DIR.."src/?/init.lua;"..package.path

-- patch require for submodules
local _req = require
require = function(mod)
  local ok, r = pcall(_req, mod)
  if ok then return r end
  -- try with directory prefix
  local paths = {
    DIR.."src/"..mod:gsub("%.","/")..".lua",
    DIR.."src/"..mod..".lua",
  }
  for _, p in ipairs(paths) do
    local f = io.open(p)
    if f then f:close()
      local chunk = assert(loadfile(p))
      return chunk()
    end
  end
  error("module '"..mod.."' not found\n"..r)
end

local Levititas = require("levititas")
local Spec      = require("spec")
local Compat    = require("compat.compat")

-- ─────────────────────────────────────────────────────────────────────────────
-- Help
-- ─────────────────────────────────────────────────────────────────────────────

local function showHelp()
  print([[
╔═══════════════════════════════════════════════════════════════╗
║        LEVITITAS v3.1 — Stability & Hardening Update         ║
║        Production-grade Lua obfuscator                       ║
╚═══════════════════════════════════════════════════════════════╝

Usage:
  lua levititas.lua <input.lua> [options]

Core options:
  -o <file>            Output file (default: <input>_obf.lua)
  --target <version>   Target Lua version (default: lua54)
                       Supported: lua54, lua53, luajit, luau
                       Unsupported: lua51, lua52 (hard error)
  --seed <N>           Deterministic build (reproducible output)
  --max-instr <N>      Instruction limit (default: 10000000)
  --protect <name>     Protect identifier from mangling (repeatable)

Diagnostic options:
  --compat-report      Print compatibility report for all targets
  --dry-run            Parse + validate only, do not write output
  --verbose            Print detailed pipeline stages

Info:
  --help               This message
  --version            Version info

Targets explained:
  lua54   Full support. All features. Recommended.
  lua53   No <const>/<close>. Integer semantics differ.
  lua52   UNSUPPORTED. Missing bitwise, goto, integer subtype.
  lua51   UNSUPPORTED. Missing bitwise, goto, //, table.unpack.
  luajit  Partial. 5.1 semantics. No bitwise syntax.
  luau    Partial. Roblox dialect. Type annotations stripped.

Examples:
  lua levititas.lua game.lua
  lua levititas.lua game.lua -o protected.lua
  lua levititas.lua game.lua --target luajit --protect PlayerData
  lua levititas.lua game.lua --seed 12345678  (reproducible build)
  lua levititas.lua game.lua --dry-run --verbose
]])
end

local function showVersion()
  print("Levititas v3.1.0")
  print("Bytecode version: " .. Spec.BYTECODE_VERSION)
  print("Lua: " .. (_VERSION or "unknown"))
end

local function showCompatReport()
  print("\nCompatibility Matrix:")
  print(string.rep("─", 70))
  print(string.format("%-10s %-10s %s", "TARGET", "STATUS", "NOTES"))
  print(string.rep("─", 70))
  for _, row in ipairs(Compat.supportMatrix()) do
    print(string.format("%-10s %-10s %s", row.target, row.status, row.notes))
  end
  print(string.rep("─", 70))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Arg parsing
-- ─────────────────────────────────────────────────────────────────────────────

local args = arg or {}
if #args == 0 then showHelp(); os.exit(0) end

local input, output, fixedSeed = nil, nil, nil
local protect = {}
local cfg = { target = "lua54" }
local dryRun, verbose = false, false

local i = 1
while i <= #args do
  local a = args[i]
  if     a == "--help"          then showHelp(); os.exit(0)
  elseif a == "--version"       then showVersion(); os.exit(0)
  elseif a == "--compat-report" then showCompatReport(); os.exit(0)
  elseif a == "--dry-run"       then dryRun  = true
  elseif a == "--verbose"       then verbose = true
  elseif a == "-o"              then i=i+1; output = args[i]
  elseif a == "--target"        then i=i+1; cfg.target = args[i]
  elseif a == "--seed"          then i=i+1; fixedSeed = tonumber(args[i])
  elseif a == "--max-instr"     then i=i+1; cfg.maxInstructions = tonumber(args[i])
  elseif a == "--protect"       then i=i+1; protect[#protect+1] = args[i]
  elseif not a:match("^%-")    then input = a
  else io.stderr:write("Unknown option: " .. a .. "\n"); os.exit(1) end
  i = i + 1
end

cfg.protectNames = protect

if not input then
  io.stderr:write("Error: no input file specified.\n"); showHelp(); os.exit(1)
end

output = output or input:gsub("%.lua$", "") .. "_obf.lua"

-- ─────────────────────────────────────────────────────────────────────────────
-- Read source
-- ─────────────────────────────────────────────────────────────────────────────

local fIn, openErr = io.open(input, "r")
if not fIn then
  io.stderr:write("Error: cannot open '" .. input .. "': " .. tostring(openErr) .. "\n")
  os.exit(1)
end
local source = fIn:read("*a")
fIn:close()

-- ─────────────────────────────────────────────────────────────────────────────
-- Run pipeline
-- ─────────────────────────────────────────────────────────────────────────────

if verbose then
  print("[Levititas v3.1]")
  print("  Input:   " .. input)
  print("  Output:  " .. (dryRun and "(dry run)" or output))
  print("  Target:  " .. cfg.target)
  print("  Seed:    " .. (fixedSeed and tostring(fixedSeed) or "auto"))
  print("  Protect: " .. (#protect > 0 and table.concat(protect, ", ") or "none"))
  print("  MaxInstr:" .. tostring(cfg.maxInstructions or Spec.LIMITS.MAX_INSTRUCTIONS))
end

local t0 = os.clock()
local obf  = Levititas.new(cfg)
local result, err, meta = obf:obfuscate(source, fixedSeed)
local elapsed = os.clock() - t0

if not result then
  io.stderr:write("\n[Levititas v3.1] FAILED\n")
  io.stderr:write("  Stage: " .. tostring(meta and meta.stage or "unknown") .. "\n")
  io.stderr:write("  Error: " .. tostring(err) .. "\n")
  if meta and meta.coverage then
    io.stderr:write(string.format("  Coverage: %d/%d tokens (%.0f%%)\n",
      meta.coverage.consumed, meta.coverage.total, meta.coverage.pct))
  end
  os.exit(1)
end

-- Print warnings
if verbose and meta then
  if meta.compatWarnings and #meta.compatWarnings > 0 then
    print("[WARNINGS]")
    for _, w in ipairs(meta.compatWarnings) do
      print("  [" .. w.severity .. "] " .. w.code .. ": " .. w.msg)
    end
  end
  print(string.format("[Pipeline] Parse coverage: %d/%d (%.0f%%)",
    meta.coverage.consumed, meta.coverage.total, meta.coverage.pct))
  print(string.format("[Pipeline] Proto: %d instructions, %d constants",
    meta.protoInstrs, meta.protoConsts))
  print(string.format("[Pipeline] Seed: %d | Build: %s",
    meta.seed, meta.buildDate))
end

if dryRun then
  print("[Levititas v3.1] Dry run complete. No output written.")
  print(string.format("  Source: %d bytes | Would produce: %d bytes | Time: %.3fs",
    #source, #result, elapsed))
  os.exit(0)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Write output
-- ─────────────────────────────────────────────────────────────────────────────

local fOut, writeErr = io.open(output, "w")
if not fOut then
  io.stderr:write("Error: cannot write '" .. output .. "': " .. tostring(writeErr) .. "\n")
  os.exit(1)
end
fOut:write(result)
fOut:close()

print(string.format("[Levititas v3.1] ✓ %s → %s | %d → %d bytes | %.3fs | seed:%d",
  input, output, #source, #result, elapsed, meta and meta.seed or 0))
if fixedSeed then
  print("  [Deterministic build] Reproduce with: --seed " .. tostring(fixedSeed))
end
