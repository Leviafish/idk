#!/usr/bin/env lua
--[[
  Levititas v2.0.0 — CLI
  Usage: lua levititas.lua <input.lua> [options]

  Options:
    -o <file>            Output file (default: <input>_obf.lua)
    --no-mangle          Skip name mangling
    --no-strings         Skip string encryption
    --no-numbers         Skip number virtualization
    --no-junk            Skip dead code injection
    --no-antidebug       Skip anti-debug layer
    --no-wrap            Skip env wrapping
    --no-strip           Keep comments
    --no-flow            Skip control flow flattening
    --no-vm              Skip VM bytecode wrapping
    --no-polymorphic     Skip polymorphic shuffling
    --protect <name>     Protect a name from mangling
    --help               Show help
]]

local SCRIPT_DIR = debug.getinfo(1,"S").source:match("@(.*)"):match("(.*[/\\])") or "./"
package.path = SCRIPT_DIR .. "src/?.lua;" .. package.path

local ok, Lev = pcall(require, "levititas")
if not ok then
  Lev = dofile(SCRIPT_DIR .. "src/levititas.lua")
end

local function showHelp()
  print([[
╔══════════════════════════════════════════════════════╗
║       LEVITITAS v2.0.0 — Elite Lua Obfuscator        ║
╚══════════════════════════════════════════════════════╝

Usage:
  lua levititas.lua <input.lua> [options]

Layers (all ON by default):
  --no-mangle        Variable/function name mangling
  --no-strings       Rolling-XOR string encryption
  --no-numbers       Lambda-chain number virtualization
  --no-junk          Dead code mutation injection
  --no-antidebug     Multi-layer anti-debug hooks
  --no-wrap          Multi-layer environment wrapping
  --no-strip         Comment stripping
  --no-flow          Control flow flattening (CFG dispatch)
  --no-vm            Custom VM + bytecode encryption
  --no-polymorphic   Polymorphic transform (unique each run)

Other:
  -o <file>          Output path
  --protect <name>   Protect identifier (repeatable)
  --help             This message

Examples:
  lua levititas.lua game.lua
  lua levititas.lua game.lua -o protected.lua --protect PlayerData
  lua levititas.lua game.lua --no-vm   (fastest, still very strong)
]])
end

local args = arg or {}
if #args == 0 or args[1] == "--help" then showHelp(); os.exit(0) end

local input, output, protect = nil, nil, {}
local cfg = {
  mangleNames=true,encryptStrings=true,encodeNumbers=true,injectJunk=true,
  antiDebug=true,wrapEnv=true,stripComments=true,controlFlow=true,
  vmMode=true,polymorphic=true,antiTamper=true,
}

local i = 1
while i <= #args do
  local a = args[i]
  if     a == "-o"               then i=i+1; output=args[i]
  elseif a == "--no-mangle"      then cfg.mangleNames=false
  elseif a == "--no-strings"     then cfg.encryptStrings=false
  elseif a == "--no-numbers"     then cfg.encodeNumbers=false
  elseif a == "--no-junk"        then cfg.injectJunk=false
  elseif a == "--no-antidebug"   then cfg.antiDebug=false
  elseif a == "--no-wrap"        then cfg.wrapEnv=false
  elseif a == "--no-strip"       then cfg.stripComments=false
  elseif a == "--no-flow"        then cfg.controlFlow=false
  elseif a == "--no-vm"          then cfg.vmMode=false
  elseif a == "--no-polymorphic" then cfg.polymorphic=false
  elseif a == "--protect"        then i=i+1; table.insert(protect, args[i])
  elseif not a:match("^%-")      then input=a
  else io.stderr:write("Unknown flag: "..a.."\n"); os.exit(1) end
  i=i+1
end

cfg.protectNames = protect
if not input then io.stderr:write("No input file.\n"); showHelp(); os.exit(1) end
output = output or input:gsub("%.lua$","").."_obf.lua"

local fIn = assert(io.open(input,"r"), "Cannot open: "..input)
local src  = fIn:read("*a"); fIn:close()

print(("[Levititas v2] %s → %s"):format(input, output))
print(("[Levititas v2] VM=%s  CFG=%s  Poly=%s  Strings=%s  Mangle=%s"):format(
  tostring(cfg.vmMode), tostring(cfg.controlFlow), tostring(cfg.polymorphic),
  tostring(cfg.encryptStrings), tostring(cfg.mangleNames)))

local t0  = os.clock()
local obf = Lev.new(cfg)
local ok2, res = pcall(function() return obf:obfuscate(src) end)
if not ok2 then
  io.stderr:write("[ERROR] "..tostring(res).."\n"); os.exit(1)
end
local elapsed = os.clock() - t0

local fOut = assert(io.open(output,"w"), "Cannot write: "..output)
fOut:write(res); fOut:close()

print(("[Levititas v2] ✓ Done in %.3fs | %d bytes → %d bytes"):format(
  elapsed, #src, #res))
