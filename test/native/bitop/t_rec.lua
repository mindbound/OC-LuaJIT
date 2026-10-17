-- test/native/bitop/t_rec.lua -- loop-carried recurrences for the JIT's
-- recording of Lua 5.3's bitwise operators.  Written by the round-3 designer
-- (r3/synth/probes, 2026-10-17); re-checked under U1-B by role C2 of the
-- round-3 implementation (below).  test/native/run-bitjit.sh runs it.
--
-- The fuzzer (bitfuzz.lua) recomputes each tuple from fresh table values, so
-- no value crosses a loop iteration through a PHI, and no arithmetic feeds a
-- bit operator: two places where the fold engine's changes act (the width
-- and exact-mark rules across PHIs; the narrow_convert skip, lj_opt_fold.c).
-- This generates recurrences
--   x, y = F(x, y, i), G(x, y, i)
-- from bitwise templates mixed with double arithmetic on the loop index, runs
-- each 300 iterations from several starting values, and prints one line per
-- recurrence: id, the two expressions, and per start the final x and y
-- (%.17g) and a position-weighted sum of every intermediate x (fmod 2^53,
-- exact), or ERR@<iteration>:<message> -- under U1-B a result with more than
-- 53 significant bits raises, and many recurrences do within a few
-- iterations; a JIT that raises at another iteration, or for another reason,
-- or not at all, prints a different line.
-- Run under our luajit.exe with the JIT on and with -joff: the outputs must be
-- identical.  (Not run on PUC: the interpreter's agreement with 5.3.6 is the
-- matrix's, the fuzzer's and the generator's job.)
--   luajit t_rec.lua [count] [seed] [counts]
-- "counts" adds shift counts that are negative, >= 64 and -2^63, constant and
-- variable.
--
-- Re-checked under U1-B (2026-10-17, 400 recurrences, seeds 1 and 2, and
-- "counts" seeds 3 and 4; lines differing JIT on against -joff): the
-- reference build r3/b/bB 0 0 0 0; the one-line sabotages of a copy of it:
-- no narrow_convert skip for an i64 CONV (NARROW) 52 37 35 29, the int64
-- BAND constant fold left FFI-only (KFOLD64) 7 6 4 14, no exactness guard
-- after a recorded result 134 131 96 104, the exact-mark rule folding its own
-- guard (SELFGUARD) 134 130 94 101.  It catches none of the width rule's
-- off-by-ones (WIDTH55, WSHR, WBAND, WADD0, WSHL0: 0 everywhere); the
-- generator (bitop/gen.lua) does.
local COUNT = tonumber(arg and arg[1]) or 400
local seed = tonumber(arg and arg[2]) or 1
local st = (seed * 7919 + 12345) % 2147483646 + 1
local function rnd(n) st = (st * 48271) % 2147483647; return st % n + 1 end
local function pick(t) return t[rnd(#t)] end

local K = { "1", "3", "7", "11", "12", "21", "31", "32", "33", "40", "52", "53", "54", "63" }
-- MODE "counts" (arg 3): shift counts also negative, >= 64, and -2^63, constant and variable
if arg and arg[3] == "counts" then
  for _, k in ipairs({ "(-1)", "(-7)", "(-63)", "(-64)", "(-65)", "64", "65", "100", "(-0x1p63)", "0x1p62" }) do K[#K + 1] = k end
end
local M = { "0xff", "0xffff", "0xffffffff", "0x1fffffffffffff", "0x3fffffffffffff",
  "0x7fffffffffffff", "0x7fffffffffffffff", "-256", "0xfffffffffffff000" }
local ATOM = { "x", "y", "x", "y", "i", "(i * 4096)", "(i * 2^45 - i)", "(x + i)",
  "(y - i)", "(2^53 + i)", "(i * 2^40)" }
local function expr(d)
  if d == 0 then return pick(ATOM) end
  local r = rnd(10)
  local a = expr(d - 1)
  if r == 1 then return "(" .. a .. " >> " .. pick(K) .. ")" end
  if r == 2 then return "(" .. a .. " << " .. pick(K) .. ")" end
  if r == 3 then return "(" .. a .. " & " .. pick(M) .. ")" end
  if r == 4 then return "(~" .. a .. ")" end
  if r == 5 then return "(" .. a .. " ~>> " .. pick(K) .. ")" end
  if r == 6 then return "((" .. a .. " >> " .. pick(K) .. ") | (" .. a .. " << " .. pick(K) .. "))" end
  local b = expr(d - 1)
  if r == 7 then return "(" .. a .. " ~ " .. b .. ")" end
  if r == 8 then return "(" .. a .. " | " .. b .. ")" end
  if r == 9 then return "(" .. a .. " & " .. b .. ")" end
  if arg and arg[3] == "counts" and rnd(2) == 1 then
    return "(" .. a .. " " .. pick({ "<<", ">>", "~>>" }) .. " " .. "((" .. b .. ") % 141 - 70))"
  end
  return "(" .. a .. " >> " .. "((" .. b .. ") & 63))"
end
local STARTS = { { "1", "2" }, { "2^52", "3" }, { "2^62", "-2^63" }, { "-1", "0x7ffffffffffffc00" },
  { "12345", "-987654321" } }

local TWO53 = 2 ^ 53
for id = 1, COUNT do
  local fx, fy = expr(rnd(3)), expr(rnd(3))
  local src = "local x0, y0, n = ...\n" ..
    "local x, y, h, i0 = x0, y0, 0, 0\n" ..
    "local ok, e = pcall(function()\n" ..
    "  for i = 1, n do\n" ..
    "    i0 = i\n" ..
    "    x, y = " .. fx .. ", " .. fy .. "\n" ..
    "    h = (h + (x % TWO53) * i) % TWO53\n" ..
    "  end\n" ..
    "end)\n" ..
    "if not ok then return 'ERR@' .. i0 .. ':' .. tostring(e):gsub('^.-:%d+: ', '') end\n" ..
    "return string.format('%.17g %.17g %.17g', x, y, h)\n"
  local f = assert(load(src, "=rec" .. id, "t", { pcall = pcall, string = string, tostring = tostring, TWO53 = TWO53 }))
  local res = {}
  for s, xy in ipairs(STARTS) do
    local x0 = assert(load("return " .. xy[1]))()
    local y0 = assert(load("return " .. xy[2]))()
    res[s] = f(x0, y0, 300)
  end
  io.write(id, "\t", fx, "\t", fy, "\t", table.concat(res, " | "), "\n")
end
