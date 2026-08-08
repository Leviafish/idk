#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
LUA=$(which lua || which lua5.4 || echo "")
[ -z "$LUA" ] && { echo "Lua not found"; exit 1; }
echo "Levititas v3.3 — Test Suite"
echo "Using: $($LUA -v 2>&1)"
$LUA test/unit/test_all.lua
$LUA test/integration/test_integration.lua
$LUA test/regression/checklist.lua
$LUA test/vm/test_vm_correctness.lua
$LUA test/compiler/test_compiler_regression.lua
echo "All suites passed."
