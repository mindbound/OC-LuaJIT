-- test/native/bitop/t_cnt33.lua -- a bit-operator result used as a VARIABLE
-- shift count, at the table-index fold's bound.  oclj_bitop_rec.c converts
-- a variable count with CONV int.num CHECK and guards it with ULT 64; the
-- fold (patch-bitop-fold.sh, hunk 11) turns that conversion of a result
-- bounded at 32 bits into the unguarded CONV int.i64.  At 33 bits the fold
-- would keep only the low 32 bits, and a count of -(2^32 - 5) (5 in its low
-- 32 bits) would pass ULT 64 and shift by 5, where 5.3.6 shifts the other
-- way by 2^32 - 5 and gives 0.  Found by round 3's review
-- (verify:tablefold:0, r3/review/verify-tablefold-0/suites/t_cnt33.lua,
-- md5 ac6597e6...); rebuilt for U1-B with a PUC twin by proto-folda
-- (2026-10-20).  test/native/run-bitjit.sh runs it (part idx).
--
--   <vm> t_cnt33.lua [iterations]      (default 400)
--
-- Each case cycles its count's operand y through its own list: mostly
-- values whose count is in [0, 63], so that the loop records (a variable
-- count outside [0, 63] at record time aborts the trace) and compiles, and
-- at intervals values whose count has 33 significant bits and low 32 bits
-- in [0, 63].  Only a negative 33-bit count can do that (a non-negative one
-- below 2^32 is its own low 32 bits), so the 33-bit shapes are x ~>> 31 and
-- ~(x ~>> 31); x ~>> 32 and x & 0x7fffffff (32 bits) must fold and stay
-- right.  The twin, the output and the #cov line are t_idx.lua's
-- (bitop/twin.lua).
local dir = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
local TW = dofile(dir .. "twin.lua")
local N = tonumber(arg and arg[1]) or 400
local fmt = string.format

-- y ~>> 31: 0 for small y; -(2^32 - 5) and -(2^32 - 40) (low bits 5, 40);
-- -2^32 (low bits 0).
local YS = { 3, 5, -(2^32 - 5) * 2^31, 7, -2^63, 1, -(2^32 - 40) * 2^31, 2 }
-- ~(y ~>> 31): 0 for small negative y; -2^32 + 5 and -2^32 + 49 (low bits
-- 5, 49); 2^32 - 6 (an int32 of -6: the ULT guard exits).
local YN = { -3, -5, -7, 2^63 - 6 * 2^31, -1, -9, -2^31, 2^63 - 50 * 2^31,
  -(2^32 - 5) * 2^31 }
local CASES = {
  { "shr-sar31",    "X(0x7fffffff >> X(y ~>> 31))", YS },
  { "shl-sar31",    "X(3 << X(y ~>> 31))", YS },
  { "sar-sar31",    "X(-0x40000000 ~>> X(y ~>> 31))", YS },
  { "shr-notsar31", "X(0x7fffffff >> X(~X(y ~>> 31)))", YN },
  { "shl-notsar31", "X(3 << X(~X(y ~>> 31)))", YN },
  { "shr-sar32",    "X(0x7fffffff >> X(y ~>> 32))", YS },
  { "shl-sar32",    "X(3 << X(y ~>> 32))", YS },
  { "shl-and31",    "X(3 << X(y & 0x7fffffff))", YS },
}

local instr = {}
for _, c in ipairs(CASES) do
  local p = TW.check(c[1], c[2]); if p then instr[#instr + 1] = p end
end
if #instr > 0 then
  print("INSTRUMENT: t_cnt33's X-wrapped texts are wrong:\n  " .. table.concat(instr, "\n  "))
  os.exit(2)
end

local cov, watch = TW.coverage()
local lines, ncases = {}, 0
for _, c in ipairs(CASES) do
  for _, off in ipairs({ 0, 5 }) do
    local src = "local Y, n, off, out = ...\nlocal ny = #Y\nfor i = 1, n do\n" ..
      "  local y = Y[(i + off) % ny + 1]\n" ..
      "  out[#out+1] = " .. TW.text(c[2]) .. "\nend\n"
    local name = c[1] .. "-o" .. off
    local f = assert(load(src, "=" .. name))
    local out = {}
    watch(f)
    local ok, e = pcall(f, c[3], N, off, out)
    watch(nil)
    ncases = ncases + 1
    local parts = {}
    for k = 1, #out do parts[k] = fmt("%.17g", out[k]) end
    if not ok then parts[#parts + 1] = "ERR@" .. (#out + 1) .. ":" .. TW.KIND(e) end
    lines[#lines + 1] = name .. "\t" .. table.concat(parts, ",")
  end
end
io.write(table.concat(lines, "\n"), "\n")
io.stderr:write(fmt("#cov cases %d traced %d convs %d jit %s\n", ncases, cov.cases, cov.convs, cov.jit))
