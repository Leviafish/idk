--[[
  Levititas v3.1 — Opcode Map Generator
  src/vm/opcodes.lua

  Generates a shuffled opcode mapping per build.
  Uses bias-free Fisher-Yates (rejection sampling).
  Opcode values are stable within a build but differ between builds.
]]

local Spec = require("spec")

local Opcodes = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  RNG (xorshift64)
-- ─────────────────────────────────────────────────────────────────────────────

local function makeRNG(seed)
  local state = seed & 0x7FFFFFFFFFFFFFFF
  if state == 0 then state = 1 end
  return function()
    state = state ~ (state << 13)
    state = state ~ (state >> 7)
    state = state ~ (state << 17)
    state = state & 0x7FFFFFFFFFFFFFFF
    return state
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §2  BIAS-FREE FISHER-YATES
--     Rejection sampling: discard draws that would create modulo bias.
-- ─────────────────────────────────────────────────────────────────────────────

local MAX_RAND = 0x7FFFFFFFFFFFFFFF

local function shuffle(t, rng)
  for i = #t, 2, -1 do
    -- Rejection sampling for unbiased random in [1, i]
    local limit = MAX_RAND - (MAX_RAND % i)
    local r
    repeat r = rng() until r < limit
    local j = (r % i) + 1
    t[i], t[j] = t[j], t[i]
  end
  return t
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §3  BUILD OPCODE MAP
-- ─────────────────────────────────────────────────────────────────────────────

-- Extract only the opcode name entries (filter out comment strings)
local function getOpcodeNames()
  local names = {}
  for _, entry in ipairs(Spec.OPCODE_NAMES) do
    if type(entry) == "string" and not entry:match("^%-%-") and
       Spec.CANONICAL_OPCODE[entry] then
      names[#names+1] = entry
    end
  end
  return names
end

function Opcodes.generateMap(seed)
  local rng   = makeRNG(seed)
  local names = getOpcodeNames()

  -- Assign sequential values 1..N
  local values = {}
  for i = 1, #names do values[i] = i end

  -- Shuffle values (not names — names stay in canonical order)
  shuffle(values, rng)

  local nameToVal = {}
  local valToName = {}
  for i, name in ipairs(names) do
    nameToVal[name] = values[i]
    valToName[values[i]] = name
  end

  return nameToVal, valToName
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §4  SEED GENERATION
--     Combines multiple entropy sources to avoid same-second collisions
--     and make seed guessing impractical.
-- ─────────────────────────────────────────────────────────────────────────────

function Opcodes.generateSeed(sourceHash)
  local t1 = os.time()
  local t2 = math.floor(os.clock() * 1000000)
  -- Address of a freshly allocated table (varies per process/run)
  local t3 = tonumber(tostring({}):match("0x(.+)") or "0", 16) or 0
  local t4 = sourceHash or 0
  -- XOR all together
  local seed = t1 ~ t2 ~ t3 ~ t4
  return seed & 0x7FFFFFFFFFFFFFFF
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §5  DETERMINISTIC MODE
--     When --seed N is passed, use N directly (for reproducible builds).
-- ─────────────────────────────────────────────────────────────────────────────

function Opcodes.seedFromInt(n)
  local seed = math.floor(n) & 0x7FFFFFFFFFFFFFFF
  if seed == 0 then seed = 1 end
  return seed
end

return Opcodes
