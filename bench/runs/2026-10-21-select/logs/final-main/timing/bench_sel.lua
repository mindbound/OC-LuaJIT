-- fc-bench_sel.lua [N] [check]: select-heavy vararg loops for the select
-- fix's smoke timing (final-check.sh's timing part), one line per row:
--   <row> TAB <ns per iteration, best of 3> TAB <result>
-- The select round's fixer's version (2026-10-21) of the implementer's
-- sel/impl/bench/bench_sel.lua (md5 6256ef5f): the same five rows, and a
-- sixth, vbeyond, whose k changes every iteration, so path C's guards (the
-- fix's among them) run in the loop body; in beyond, konst and count the
-- recorded select is loop-invariant and the loop optimizer hoists it, so
-- they read about the bare loop (0.3-0.4 ns, sizing runs on the fixer's
-- build).  The final check runs it at N = 1e8, where os.clock's 1 ms steps
-- are 0.01 ns of a row; at 1e7 the rows read in steps of 0.1 ns.  With
-- "check", the time column is printed as "-" (a run that only proves the
-- rows compute).  Rows (the path rec_varg records, lj_record.c):
--   idx      for i = 1, select('#', ...) do s = s + select(i, ...) end  (B, '#')
--   cycle    s = s + select(i % 7 + 1, ...)                             (B)
--   beyond   select(k, ...) with k = 9 > 7 varargs from a table         (C, hoisted)
--   vbeyond  select(i % 7 + 8, ...), k from 8 to 14 > 7 varargs         (C, in the body)
--   konst    s = s + select(3, ...)                                     (A)
--   count    s = s + select('#', ...)                                   ('#')
-- No backslash in this file.
local N = tonumber(arg and arg[1]) or 1e8
local CHECK = arg and arg[2] == "check"
local clock = os.clock
local TAB = string.char(9)

local function idx(n, ...)
  local s = 0
  for r = 1, n do
    for i = 1, select('#', ...) do s = s + select(i, ...) end
  end
  return s
end
local function cycle(n, ...)
  local s = 0
  for i = 1, n do s = s + select(i % 7 + 1, ...) end
  return s
end
local K = { 9 }
local function beyond(n, ...)
  local c = 0
  for i = 1, n do
    if select(K[1], ...) == nil then c = c + 1 end
  end
  return c
end
local function vbeyond(n, ...)
  local c = 0
  for i = 1, n do
    if select(i % 7 + 8, ...) == nil then c = c + 1 end
  end
  return c
end
local function konst(n, ...)
  local s = 0
  for i = 1, n do s = s + select(3, ...) end
  return s
end
local function count(n, ...)
  local s = 0
  for i = 1, n do s = s + select('#', ...) end
  return s
end

local ROWS = {
  { "idx", idx, 7 }, { "cycle", cycle, 1 }, { "beyond", beyond, 1 },
  { "vbeyond", vbeyond, 1 }, { "konst", konst, 1 }, { "count", count, 1 },
}
for _, row in ipairs(ROWS) do
  local name, f, per = row[1], row[2], row[3]
  local n = math.floor(N / per)
  local best, res = math.huge, nil
  for _ = 1, 3 do
    local t0 = clock()
    res = f(n, 1, 2, 3, 4, 5, 6, 7)
    local t = clock() - t0
    if t < best then best = t end
  end
  local ns = best * 1e9 / (n * per)
  print(name .. TAB .. (CHECK and "-" or string.format("%.3f", ns)) .. TAB .. string.format("%.17g", res))
end
