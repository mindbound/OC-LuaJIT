-- test/native/bitop/t_idx.lua -- bit-operator results used where LuaJIT
-- converts a number to an int32, at the table-index fold's bound.  The fold
-- (native/luajit/patch-bitop-fold.sh, hunk 11: simplify_conv_int_num, the
-- CRC32 follow-up, roadmap row 209) turns CONV int.num (CONV num.i64 y) into
-- the unguarded CONV int.i64 y when oclj_bitwidth(y) is 32 or less, and
-- never across a PHI.  Written by the round-3 table-fold reviewer against
-- the U1-A prototype (r3/review/tablefold/t_idx.lua, md5 6bd23113...,
-- 2026-10-17); rebuilt for U1-B with a PUC twin by proto-folda (2026-10-20).
-- test/native/run-bitjit.sh runs it (part idx).
--
--   <vm> t_idx.lua [iterations]        (default 400)
--
-- THE CONSUMERS of an index e (each a different conversion site):
--   get   T[e]           rec_idx_key -> lj_opt_narrow_index, CONV int.num INDEX
--   set   T2[e] = i      the same, on a store
--   byte  s:byte(e)      lj_opt_narrow_toint, CONV int.num ANY
--   sub   s:sub(e, e)    the same, string.sub
--   get1  T[e + 1]       narrowing's backpropagation, a CHECK leaf
--   phi   T[ep]; ep = e  the index carried across the loop's PHI: no fold
--   shl   3 << e         round 3's variable shift count, CONV int.num CHECK
--   shr   0x7fffffff >> e   the same, with ULT 64 then a right shift
--   fori  for j = 1, e     fori_conv's CONV int.num CHECK of the stop: the
--                          start is an int, so rec_for records an int loop;
--                          the first version's `for j = e, e + 1` had a
--                          double start, so a number loop and no conversion
--                          at all (verify-folda F1, crc/combine 2026-10-20);
--                          the break keeps the trip count at 3
-- bitop/t_idx2.lua adds the consumers this list lacks (rawget, the string
-- and table library's integer arguments, side traces, carried keys).
--
-- THE INDEX EXPRESSIONS straddle the bound: oclj_bitwidth 32 (fold) next to
-- 33 (no fold), with operands at and past +-2^31 and +-2^32, so that a fold
-- at 33 gives a wrong key, argument or count (w33e: x ~>> 31 with
-- x = -(2^32 - 5) * 2^31 is -(2^32 - 5), whose low 32 bits are 5).  w10
-- raises under U1-B once x has more than 53 significant bits (x ~ 0x55,
-- before the mask); w10b masks first, the user's remedy, and stays exact.
--
-- ONE TEXT, TWO DIALECTS (bitop/twin.lua): every operator's result is
-- wrapped in X(...); our text drops each X, PUC 5.3.6's applies U1-B's rule
-- there, and ~>> becomes SAR on PUC.  run-bitjit.sh compares JIT on with
-- -joff under several option sets, and PUC's output with -joff's.
--
-- Prints one line per case, "<expr>-<consumer>-o<offset>\t<results>", each
-- number as %.17g; a raise ends the list with ERR@<iteration>:<kind>.  On
-- stderr, one line:
--   #cov cases <n> traced <n> convs <n> jit <on|off>
-- traced: the cases in which a trace completed in the case's function;
-- convs: the CONV int.i64 instructions (the fold's) in those traces.
-- Exit 2 (INSTRUMENT) if a text is not what it says.
local dir = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
local TW = dofile(dir .. "twin.lua")
local N = tonumber(arg and arg[1]) or 400
local fmt = string.format

local E = {  -- index expressions in x, with oclj_bitwidth's bound
  { "w9",   "X(x & 0xff)" },
  { "w32a", "X(x & 0x7fffffff)" },
  { "w33a", "X(x & 0xffffffff)" },
  { "w32b", "X(~X(x & 0x7fffffff))" },
  { "w33b", "X(~X(x & 0xffffffff))" },
  { "w32c", "X(X(x & 0xffff) << 15)" },
  { "w33c", "X(X(x & 0xffff) << 16)" },
  { "w32d", "X(x >> 33)" },
  { "w33d", "X(x >> 32)" },
  { "w32e", "X(x ~>> 32)" },
  { "w33e", "X(x ~>> 31)" },
  { "w32f", "X(X(x & 0xff) | X(x & 0x7f000000))" },
  { "w32g", "X(X(x & 0x3fffffff) << 1)" },
  { "w33g", "X(X(x & 0x7fffffff) << 1)" },
  { "w24",  "X(X(x << 40) ~>> 40)" },
  { "w31",  "X(x ~>> 33)" },
  { "w10",  "X(X(x ~ 0x55) & 0x1ff)" },
  { "w10b", "X(X(X(x & 0xffffffff) ~ 0x55) & 0x1ff)" },
  { "w32h", "X(~X(~X(x & 0x7fffffff)))" },
}

local C = {  -- consumers of the index e
  { "get",  "local v = T[e]; out[#out+1] = v == nil and 'n' or v" },
  { "set",  "T2[e] = i; out[#out+1] = T2[e]" },
  { "byte", "local v = s:byte(e); out[#out+1] = v == nil and 'n' or v" },
  { "sub",  "out[#out+1] = '<' .. s:sub(e, e) .. '>'" },
  { "get1", "local v = T[e + 1]; out[#out+1] = v == nil and 'n' or v" },
  { "phi",  "local v = T[ep]; out[#out+1] = v == nil and 'n' or v; ep = e" },
  { "shl",  "out[#out+1] = X(3 << e)" },
  { "shr",  "out[#out+1] = X(0x7fffffff >> e)" },
  { "fori", "local c = 0; for j = 1, e do c = c + j; if j >= 3 then break end end; out[#out+1] = c" },
}

-- Operands: mostly array indices, with values at and past the int32 and
-- uint32 bounds, negatives, and large values (all exact int64 doubles).
local VALS = { 0, 1, 2, 3, 5, 7, 8, 13, 21, 34, 55, 89, 100, 144, 200, 233, 250,
  255, 256, 299,
  2^31 - 1, 2^31, 2^31 + 5, 2^32 - 6, 2^32, 2^32 + 5, -1, -5, -2^31, -2^31 - 1,
  -2^32 + 5, -(2^32 - 5) * 2^31, 2^40 + 7, 2^53, -2^53, 2^62 + 2^40, -2^62,
  -2^63, 0x7ffffffffffffc00, -0.0, 2^33 + 3, 2^31 * 3 + 2, 2^47 + 2^31 + 9,
  -(2^30 + 7) * 2^32 }

local function newT()
  local T = {}
  for k = 0, 299 do T[k] = 1000 + k end
  local H = { -1, -5, 2^31, 2^31 + 5, 2^32 - 6, -2^31, -2^31 - 1, -2^32 + 5,
    2^32 + 5, 2^31 - 1, 2^32, -2^32, 2^31 * 3 + 2 }
  for j, k in ipairs(H) do T[k] = -j end
  return T
end
local s = string.rep("abcdefghijklmnopqrstuvwxyz0123456789", 9):sub(1, 300)

local instr = {}
for _, ex in ipairs(E) do
  local p = TW.check(ex[1], ex[2]); if p then instr[#instr + 1] = p end
end
for _, co in ipairs(C) do
  local p = TW.check(co[1], co[2]); if p then instr[#instr + 1] = p end
end
if #instr > 0 then
  print("INSTRUMENT: t_idx's X-wrapped texts are wrong:\n  " .. table.concat(instr, "\n  "))
  os.exit(2)
end

local cov, watch = TW.coverage()
local lines, ncases = {}, 0
for _, ex in ipairs(E) do
  for _, co in ipairs(C) do
    for _, off in ipairs({ 0, 7, 19, 31 }) do
      local src = "local T, T2, s, VALS, n, off, out = ...\n" ..
        "local ep, nv = 0, #VALS\n" ..
        "for i = 1, n do\n" ..
        "  local x = VALS[(i + off) % nv + 1]\n" ..
        "  local e = " .. TW.text(ex[2]) .. "\n" ..
        "  " .. TW.text(co[2]) .. "\n" ..
        "end\n"
      local name = ex[1] .. "-" .. co[1] .. "-o" .. off
      local f = assert(load(src, "=" .. name))
      local out = {}
      watch(f)
      local ok, e = pcall(f, newT(), {}, s, VALS, N, off, out)
      watch(nil)
      ncases = ncases + 1
      local parts = {}
      for k = 1, #out do
        local v = out[k]
        parts[k] = type(v) == "number" and fmt("%.17g", v) or tostring(v)
      end
      if not ok then parts[#parts + 1] = "ERR@" .. (#out + 1) .. ":" .. TW.KIND(e) end
      lines[#lines + 1] = name .. "\t" .. table.concat(parts, ",")
    end
  end
end
io.write(table.concat(lines, "\n"), "\n")
io.stderr:write(fmt("#cov cases %d traced %d convs %d jit %s\n", ncases, cov.cases, cov.convs, cov.jit))
