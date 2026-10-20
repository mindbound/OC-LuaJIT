-- test/native/bitop/t_idx2.lua -- the table-index fold's consumers beyond
-- t_idx.lua: bit results bounded at 32 bits (the fold, patch-bitop-fold.sh
-- hunk 11: CONV int.num (CONV num.i64 y) ==> CONV int.i64 y) and at 33 bits
-- (no fold: a fold would keep only y's low 32 bits) used by every consumer
-- the recorder converts from a double to an int32, in plain loops, in
-- branches (side traces record the consumer) and with the key carried to
-- the next iteration (across the loop's PHI).  Written by verify-folda as
-- vf_idx.lua (crc/verify-folda/suites, md5 12accdeab41a..., 2026-10-20);
-- shipped for the CRC32 follow-up (roadmap row 209) without its select
-- part.  test/native/run-bitjit.sh runs it (part idx).
--
--   <vm> t_idx2.lua [iterations] [part]   (default 400, all)
--
-- THE CONSUMERS of an index e, and the conversion each one meets:
--   get, set     T[e], T2[e] = i      rec_idx_key, CONV int.num INDEX
--   rawget       rawget(T, e)         the same, through recff_rawget
--   get3, getm1  T[e + 3], T[e - 1]   narrowing's leaves (CHECK)
--   byte         s:byte(e)            lj_opt_narrow_toint, CONV int.num ANY
--   sub1, sub2   #s:sub(e), #s:sub(-e, e)   the same; -e reaches the
--                string's negative indices.  Under WIDTHIDX33 only the
--                x ~>> 31 expressions differed here (three runs, 2026-10-20):
--                x & 0xffffffff's truncation to a negative int32 showed
--                through the narrowed keys, the loop stop and concat's i, j
--   find         s:find('a', e, true)       find's init
--   char, rep    string.char(e), #string.rep('ab', e)
--   concat       #table.concat(T, ',', e, e + 2)   i and j
--   unpack       unpack(T, e, e + 1)              i and j
--   shl, sar     3 << e, -0x40000000 ~>> e        round 3's variable count
--                (CHECK, then ULT 64)
--   fori         for j = 1, e ... break at 3      fori_conv's CHECK of the
--                stop (an int start, so an int loop)
-- The library calls that can raise run under pcall through helpers made
-- outside the loop, so a raise is a result and the case goes on.  rep runs
-- only for e below 40 (and above -100, or below -2^32 + 40, whose low 32
-- bits are small), so that no case builds a large string under any build.
--
-- THE WRAPS: p (the consumer as it is), s (in both arms of a branch taken
-- by i % 3, so a side trace records it), k (the consumer reads the key the
-- previous iteration made: ep, carried across the PHI, where the fold must
-- not fire).
--
-- NOT HERE: select(e, ...).  When this file was written, upstream's
-- rec_varg computed select's bound in 32 bits, so compiled code returned
-- nil for a large negative index where the interpreter raises "index out
-- of range", with no bit operator involved (verify-folda,
-- probes/selbug.lua, 2026-10-20; the shipped build and the 2026-09-01
-- upstream binary alike), and a select consumer here would have reported
-- that, not the fold.  The select fix (roadmap row 213, JIT guide P54)
-- bounds select's index since, and t_select.lua's bx source feeds select a
-- 32-bit bit result through this fold; whether select joins this file is
-- open.
--
-- ONE TEXT, TWO DIALECTS (bitop/twin.lua).  The reference is -joff.  Part
-- "puc" prints only the consumers whose meaning is the same on PUC 5.3.6
-- for every value (tables, shifts, the loop stop; a library's integer
-- arguments differ, twin.lua's header): run-bitjit.sh compares PUC's "puc"
-- output with -joff's.
--
-- Prints one line per case, "<expr>-<consumer>-<wrap>-o<off>\t<results>",
-- each number as %.17g; a raise ends the list with ERR@<iteration>:<kind>.
-- On stderr, twin.lua's "#cov cases <n> traced <n> convs <n> jit <on|off>".
-- Exit 2 (INSTRUMENT) if a text is not what it says.
local dir = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
local TW = dofile(dir .. "twin.lua")
local N = tonumber(arg and arg[1]) or 400
local PART = arg and arg[2] or "all"
local fmt = string.format
if PART ~= "all" and PART ~= "puc" then
  print("INSTRUMENT: t_idx2's part is all or puc, not " .. tostring(PART))
  os.exit(2)
end

local E = {  -- index expressions in x and z, with oclj_bitwidth's bound
  { "a32", "X(x ~>> 32)" },
  { "b32", "X(x >> 33)" },
  { "c32", "X(x & 0x7fffffff)" },
  { "d32", "X(~X(x & 0x7fffffff))" },
  { "e32", "X(X(x ~>> 32) ~ X(z ~>> 32))" },
  { "f32", "X(X(x ~>> 40) | X(z & 0x7fff0000))" },
  { "g32", "X(X(x & 0x3fffffff) << 1)" },
  { "h32", "X(X(X(x ~>> 32) & -0x100) ~ 0x7f)" },
  { "i32", "X(X(X(x << 40) ~>> 40) ~ X(z ~>> 33))" },
  { "a33", "X(x ~>> 31)" },
  { "b33", "X(x >> 32)" },
  { "c33", "X(x & 0xffffffff)" },
  { "d33", "X(~X(x ~>> 31))" },
  { "e33", "X(X(x ~>> 31) ~ X(z ~>> 32))" },
  { "g33", "X(X(x & 0x7fffffff) << 1)" },
}

-- Consumers: { name, statement, puc } -- the statement uses e, i, T, T2, s,
-- out and the CF_* helpers; puc: the same meaning on PUC 5.3.6.
local C = {
  { "get",   "local v = T[e]; out[#out+1] = v == nil and 'n' or v", true },
  { "set",   "T2[e] = i; out[#out+1] = T2[e]", true },
  { "rawget","local v = rawget(T, e); out[#out+1] = v == nil and 'n' or v", true },
  { "get3",  "local v = T[e + 3]; out[#out+1] = v == nil and 'n' or v", true },
  { "getm1", "local v = T[e - 1]; out[#out+1] = v == nil and 'n' or v", true },
  { "byte",  "local v = s:byte(e); out[#out+1] = v == nil and 'n' or v", false },
  { "sub1",  "out[#out+1] = #s:sub(e)", false },
  { "sub2",  "out[#out+1] = #s:sub(-e, e)", false },
  { "find",  "out[#out+1] = s:find('a', e, true) or 'n'", false },
  { "char",  "local ok, v = pcall(CF_char, e); out[#out+1] = ok and v or KIND(v)", false },
  { "rep",   "if e < 40 and (e > -100 or e < -2^32 + 40) then local ok, v = pcall(CF_rep, e); out[#out+1] = ok and v or KIND(v) else out[#out+1] = 'x' end", false },
  { "concat","local ok, v = pcall(CF_concat, e); out[#out+1] = ok and v or KIND(v)", false },
  { "unpack","local ok, v = pcall(CF_unpack, e); out[#out+1] = ok and v or KIND(v)", false },
  { "shl",   "local ok, v = pcall(CF_shl, e); out[#out+1] = ok and v or KIND(v)", true },
  { "sar",   "local ok, v = pcall(CF_sar, e); out[#out+1] = ok and v or KIND(v)", true },
  { "fori",  "local c = 0; for j = 1, e do c = c + j; if j >= 3 then break end end; out[#out+1] = c", true },
}
local WRAPS = {
  { "p", function(st) return st end },
  { "s", function(st) return "if i % 3 == 0 then " .. st .. " else " .. st .. " end" end },
  { "k", function(st) return "do local e = ep; " .. st .. " end; ep = e" end },
}

-- x and z values: a warm-up of small ones, then the edges.  For each 33-bit
-- shape there are x whose y has 33 bits and small low 32 bits (a 33-bit
-- fold's wrong key, argument, count or stop), and for each 32-bit shape x
-- giving y = -2^31 and 2^31 - 1.
local VALS = { 1, 2, 3, 5, 8, 13, 3 * 2^32, 7 * 2^32, 5 * 2^33, 9 * 2^33,
  -(2^32 - 5) * 2^31, -(2^32 - 40) * 2^31, -5 * 2^32, -40 * 2^32, 2^32 - 5, -5,
  (2^32 - 6) * 2^31, (2^32 - 41) * 2^31,
  -2^63, 2^63 - 2^32, -1, 2^31 - 1, 2^31 + 5, 2^31, -2^31, 2^32, -2^32,
  2^53, -2^53, 2^62 + 2^40, 0x7ffffffffffffc00, -(2^30 + 7) * 2^32, 0, 4, 6, 7, 11, 2^40 + 3,
  2^53 - 1, 2^53 + 2, -2^53 - 2, -2^53 + 1, 2^63 - 2^11, -2^63 + 2^11, 2^62 - 2^31 }

local T0 = {}
for k = 0, 299 do T0[k] = 1000 + k end
local H = { -1, -5, 2^31, 2^31 + 5, 2^32 - 6, 2^32 - 5, -2^31, -2^31 - 1, -2^32 + 5,
  -2^32 + 40, 2^32 + 5, 2^31 - 1, 2^32, -2^32, 2^31 * 3 + 2, -2^32 + 2, -2^32 + 3 }
local function newT()
  local T = {}
  for k = 0, 299 do T[k] = T0[k] end
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
  print("INSTRUMENT: t_idx2's X-wrapped texts are wrong:\n  " .. table.concat(instr, "\n  "))
  os.exit(2)
end

local HELP = [[
local T, T2, s, VALS, n, off, out, KIND = ...
local unpack = unpack or table.unpack
local CF_char = function(e) return #string.char(e) end
local CF_rep = function(e) return #string.rep('ab', e) end
local CF_concat = function(e) return #table.concat(T, ',', e, e + 2) end
local CF_unpack = function(e) local a, b = unpack(T, e, e + 1); return (a or 0) + (b or 0) end
local CF_shl = function(e) return ]] .. TW.text("X(3 << e)") .. [[ end
local CF_sar = function(e) return ]] .. TW.text("X(-0x40000000 ~>> e)") .. [[ end
local ep, nv = 0, #VALS
]]

local cov, watch = TW.coverage()
local lines, ncases = {}, 0
for _, ex in ipairs(E) do
  for _, co in ipairs(C) do
    if PART == "all" or co[3] then
      for _, w in ipairs(WRAPS) do
        for _, off in ipairs({ 0, 17 }) do
          local name = ex[1] .. "-" .. co[1] .. "-" .. w[1] .. "-o" .. off
          local src = HELP ..
            "for i = 1, n do\n" ..
            "  local x = VALS[(i + off) % nv + 1]\n" ..
            "  local z = VALS[(i * 3 + off) % nv + 1]\n" ..
            "  local e = " .. TW.text(ex[2]) .. "\n" ..
            "  " .. w[2](TW.text(co[2])) .. "\n" ..
            "end\n"
          local f = assert(load(src, "=" .. name))
          local out = {}
          watch(f)
          local ok, e = pcall(f, newT(), {}, s, VALS, N, off, out, TW.KIND)
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
  end
end
io.write(table.concat(lines, "\n"), "\n")
io.stderr:write(fmt("#cov cases %d traced %d convs %d jit %s\n", ncases, cov.cases, cov.convs, cov.jit))
