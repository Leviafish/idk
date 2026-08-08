--[[
================================================================================
  LEVITITAS v3.2 — CLOSURE & UPVALUE AUDIT
  src/vm/closure_audit.lua

  Complete analysis of closure and upvalue correctness.
  Every edge case documented. Every risk identified.
  
  This module:
    1. Documents the correct Lua semantics for closures
    2. Identifies where the v3.1 VM deviates
    3. Provides test cases for each edge case
    4. Flags known incorrect behaviors
================================================================================
]]

local ClosureAudit = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  CORRECT LUA CLOSURE SEMANTICS (reference)
-- ─────────────────────────────────────────────────────────────────────────────

ClosureAudit.SEMANTICS = {

  --[[
    RULE-1: Upvalues are SHARED CELLS, not value copies.
    
    When multiple closures share an upvalue (same local variable in enclosing
    scope), they share a single cell. Mutating through one closure is visible
    in all others.
    
    Correct behavior:
      local x = 0
      local function inc() x = x + 1 end
      local function get() return x end
      inc(); inc()
      assert(get() == 2)  -- must be true
  ]]
  {
    id       = "CLOSURE-SEM-01",
    rule     = "Upvalues are shared mutable cells",
    status   = "PARTIALLY-IMPLEMENTED",
    risk     = "HIGH",
    detail   = "The v3.1 VM captures upvals as table references ({value}) " ..
               "when creating closures via MAKE_CLOSURE. " ..
               "However, the upvalue cells are created from st.upvals at " ..
               "closure creation time, not from the live local slots. " ..
               "If a local variable has not yet been promoted to an upvalue " ..
               "cell at the time MAKE_CLOSURE executes, sharing is broken.",
    testCase = [[
-- This must print 2, not 0:
local x = 0
local function inc() x = x + 1 end
local function get() return x end
inc(); inc()
print(get())  -- expected: 2
]],
  },

  --[[
    RULE-2: Closing upvalues (CLOSE opcode).
    
    When a local variable goes out of scope but is captured by a closure,
    the upvalue must be "closed" — its value copied into the upvalue cell
    and the cell detached from the stack slot.
    
    In the v3.1 VM, CLOSE is a no-op. This means:
    - If a closure captures a local that goes out of scope, it may read
      stale or nil values.
    - The cell is never properly detached from the stack frame.
  ]]
  {
    id       = "CLOSURE-SEM-02",
    rule     = "Upvalue closing at scope exit",
    status   = "NOT-IMPLEMENTED",
    risk     = "CRITICAL",
    detail   = "CLOSE opcode is emitted but is a no-op. Closures that " ..
               "capture locals from an inner scope that has exited will " ..
               "reference a dead stack slot, producing nil or wrong values.",
    testCase = [[
-- This must print 10 after the inner block exits:
local getX
do
  local x = 10
  getX = function() return x end
end  -- x goes out of scope here; upvalue must be closed
print(getX())  -- expected: 10, may get nil in v3.1
]],
  },

  --[[
    RULE-3: Multiple closures from the same scope share upvalue cells.
    
    Two closures created in the same scope, both capturing the same local,
    must share ONE upvalue cell, not create separate copies.
  ]]
  {
    id       = "CLOSURE-SEM-03",
    rule     = "Shared upvalue cell between co-closures",
    status   = "PARTIALLY-IMPLEMENTED",
    risk     = "HIGH",
    detail   = "Co-closures created in the same scope share upvals via " ..
               "the parent's st.upvals table. However if MAKE_CLOSURE " ..
               "passes a snapshot of upvals rather than a reference, " ..
               "sharing is broken for co-closures.",
    testCase = [[
-- Both closures must see the same x:
local x = 0
local function inc() x = x + 1 end
local function dec() x = x - 1 end
inc(); inc(); dec()
print(x)  -- expected: 1
]],
  },

  --[[
    RULE-4: Recursive closures (self-reference).
    
    A function that calls itself recursively must see its own local name
    as an upvalue if defined with local function f() ... end.
  ]]
  {
    id       = "CLOSURE-SEM-04",
    rule     = "Recursive closure self-reference",
    status   = "IMPLEMENTED",
    risk     = "LOW",
    detail   = "local function f() ... f() ... end compiles to: " ..
               "defineLocal('f'), compileFuncBody(), STORE_LOCAL(slot_f). " ..
               "The recursive call inside uses LOAD_LOCAL(slot_f), which " ..
               "works correctly because the slot is defined before the body.",
    testCase = [[
local function fib(n)
  if n <= 1 then return n end
  return fib(n-1) + fib(n-2)
end
print(fib(10))  -- expected: 55
]],
  },

  --[[
    RULE-5: Nested closure chains.
    
    Closures nested 3+ levels deep must correctly thread upvalues through
    each level without copying or losing them.
  ]]
  {
    id       = "CLOSURE-SEM-05",
    rule     = "Nested closure upvalue threading",
    status   = "PARTIALLY-IMPLEMENTED",
    risk     = "HIGH",
    detail   = "The v3.1 compiler does not implement upvalue threading for " ..
               "variables captured from grandparent scopes. Only the immediate " ..
               "parent scope's upvals are passed to MAKE_CLOSURE. " ..
               "A 3-level deep closure capturing a 3-levels-up local will " ..
               "see nil instead of the correct value.",
    testCase = [[
-- Three levels of nesting:
local function outer()
  local x = 42
  local function middle()
    local function inner()
      return x  -- x is 3 levels up
    end
    return inner
  end
  return middle
end
local get = outer()()
print(get())  -- expected: 42, may get nil in v3.1
]],
  },

  --[[
    RULE-6: Upvalue modification across closure boundaries.
    
    Modifying an upvalue in one closure must be visible in all other
    closures that share the same cell, including the enclosing function.
  ]]
  {
    id       = "CLOSURE-SEM-06",
    rule     = "Upvalue mutation visibility",
    status   = "PARTIALLY-IMPLEMENTED",
    risk     = "HIGH",
    detail   = "Mutation works if upvalues are properly shared cells. " ..
               "The risk is that MAKE_CLOSURE may snapshot rather than " ..
               "reference, breaking mutation visibility.",
    testCase = [[
local function makeCounter()
  local count = 0
  return {
    inc = function() count = count + 1 end,
    get = function() return count end,
  }
end
local c = makeCounter()
c.inc(); c.inc(); c.inc()
print(c.get())  -- expected: 3
]],
  },

  --[[
    RULE-7: Upvalue lifetime.
    
    An upvalue cell must stay alive as long as any closure references it,
    even after the enclosing function returns.
  ]]
  {
    id       = "CLOSURE-SEM-07",
    rule     = "Upvalue lifetime past enclosing function",
    status   = "IMPLEMENTED",
    risk     = "LOW",
    detail   = "Lua's GC handles this correctly since the closure holds a " ..
               "reference to the upvalue cell. As long as the closure is " ..
               "alive, the cell stays alive. No action needed in the VM.",
    testCase = [[
local function makeAdder(n)
  return function(x) return x + n end
end
local add5 = makeAdder(5)
print(add5(10))  -- expected: 15
]],
  },

  --[[
    RULE-8: for loop variable capture.
    
    Each iteration of a for loop creates a NEW binding for the loop variable.
    Closures created inside the loop each capture their own copy.
  ]]
  {
    id       = "CLOSURE-SEM-08",
    rule     = "for loop variable capture creates new binding per iteration",
    status   = "NOT-IMPLEMENTED",
    risk     = "CRITICAL",
    detail   = "The v3.1 VM uses a single local slot for the for loop variable. " ..
               "Closures created inside the loop all capture the same slot. " ..
               "After the loop ends, all closures see the final value of i, " ..
               "not their respective values.",
    testCase = [[
-- Classic for-loop closure capture:
local funcs = {}
for i = 1, 5 do
  funcs[i] = function() return i end
end
-- Standard Lua: each closure captures its own i
for i = 1, 5 do
  print(funcs[i]())  -- expected: 1 2 3 4 5 (each different)
end
-- v3.1 VM will likely print: 6 6 6 6 6 (all see loop variable's final value)
]],
  },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §2  RISK SUMMARY
-- ─────────────────────────────────────────────────────────────────────────────

ClosureAudit.RISKS = {
  {
    id       = "RISK-CLOSE-01",
    severity = "CRITICAL",
    title    = "CLOSE opcode is a no-op",
    impact   = "Closures capturing locals from exited scopes return nil " ..
               "or wrong values. Affects any script using closures that " ..
               "outlive their enclosing block.",
    fix      = "Implement proper upvalue closing: when a local goes out of " ..
               "scope and is captured, copy its value into the upvalue cell " ..
               "and detach the cell from the stack slot.",
    affectedRule = "CLOSURE-SEM-02",
  },
  {
    id       = "RISK-FORLOOP-01",
    severity = "CRITICAL",
    title    = "for loop variable not re-bound per iteration",
    impact   = "Classic Lua for-loop closure pattern produces wrong results. " ..
               "All closures created inside a for loop share the loop " ..
               "variable's final value.",
    fix      = "For each loop iteration, create a fresh local binding for " ..
               "the loop variable by adding a STORE_LOCAL to a new slot " ..
               "before the closure creation.",
    affectedRule = "CLOSURE-SEM-08",
  },
  {
    id       = "RISK-UPVAL-THREAD-01",
    severity = "HIGH",
    title    = "Upvalue threading missing for nested closures",
    impact   = "Closures nested 3+ levels cannot access variables from " ..
               "grandparent scopes. Only immediate parent upvalues work.",
    fix      = "Implement a proper upvalue index table in the proto format " ..
               "(as in standard Lua compiler). Each upvalue in a closure " ..
               "either comes from the enclosing function's locals or from " ..
               "its own upvalues.",
    affectedRule = "CLOSURE-SEM-05",
  },
  {
    id       = "RISK-UPVAL-SHARE-01",
    severity = "HIGH",
    title    = "MAKE_CLOSURE may snapshot upvalues instead of sharing cells",
    impact   = "Co-closures in the same scope may not share mutation. " ..
               "Counter patterns (inc/get closure pairs) may produce " ..
               "incorrect results.",
    fix      = "Ensure MAKE_CLOSURE passes upvalue cell references, not " ..
               "copies of their current values.",
    affectedRule = "CLOSURE-SEM-03,CLOSURE-SEM-06",
  },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §3  IMPLEMENTATION STATUS SUMMARY
-- ─────────────────────────────────────────────────────────────────────────────

ClosureAudit.STATUS_SUMMARY = {
  total        = 8,
  implemented  = 2,  -- RULE-4 (recursion), RULE-7 (lifetime)
  partial      = 3,  -- RULE-1, RULE-3, RULE-5, RULE-6
  not_impl     = 2,  -- RULE-2 (CLOSE), RULE-8 (for-loop re-bind)
  critical_bugs= 2,  -- RISK-CLOSE-01, RISK-FORLOOP-01
  high_bugs    = 2,  -- RISK-UPVAL-THREAD-01, RISK-UPVAL-SHARE-01
}

-- ─────────────────────────────────────────────────────────────────────────────
-- §4  TEST CASES (as executable Lua strings for the test runner)
-- ─────────────────────────────────────────────────────────────────────────────

ClosureAudit.TEST_CASES = {}
for _, sem in ipairs(ClosureAudit.SEMANTICS) do
  ClosureAudit.TEST_CASES[#ClosureAudit.TEST_CASES+1] = {
    id       = sem.id,
    rule     = sem.rule,
    status   = sem.status,
    source   = sem.testCase,
    skip     = sem.status == "NOT-IMPLEMENTED",
    xfail    = sem.status == "PARTIALLY-IMPLEMENTED",
  }
end

return ClosureAudit
