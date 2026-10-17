-- test/native/bitop/p4v.lua -- the fix1 check: a value set from the int loop
-- index through an identity bit operation, carried, and used by a bit
-- operator the next iteration, must compile.  The loops are the round-3
-- width-fold reviewer's (r3/review/widthfold/probes/p4/p4v.lua, 2026-10-17);
-- the check from trace events and bytecode, instead of a timing, by role C2
-- of the round-3 implementation.  test/native/run-bitjit.sh runs it.
--
--   luajit p4v.lua          (LUA_PATH must reach the build's src/jit/vmdef.lua)
--
-- THE BUG fix1 removes (lj_opt_fold.c simplify_conv_i64_num): x = i | 0 is
-- CONV num.i64 (BOR (CONV i64.int i) 0); folded, that is the sign-extended
-- int loop index, and simplify_conv_sext's x64 LEFTFOLD hands the int itself
-- to the next iteration's int64 use.  Across the PHI the carried slot is then
-- an int where the pre-roll had an int64, loop_unroll raises "persistent type
-- instability" (LJ_TRERR_TYPEINS), and after enough aborts the loop is
-- blacklisted: its FORL becomes IFORL (lj_trace.c blacklist_pc) and it runs
-- interpreted for good.  fix1 folds across a PHI only to an int64-typed y.
-- Measured (reviewer, p4v-results.txt): without fix1 seven of the eight
-- variants ran at -joff's speed; mask, not an identity, compiled on both.
--
-- For each variant this runs the loop three times, 100000 iterations each,
-- and prints
--   <variant>\tx=<x> y=<y>\ttraces=<n> typeins=<n> loop=<FORL|JFORL|IFORL> <verdict>
-- traces counts the traces that completed in the loop's function, typeins
-- the "persistent type instability" aborts anywhere, and loop is the loop's
-- opcode afterwards (JFORL: a trace is attached; IFORL: blacklisted).  With
-- the JIT on, a variant is ok when traces >= 1, typeins = 0 and loop = JFORL;
-- with -joff every verdict is "-".  The x= y= field must equal -joff's
-- (run-bitjit.sh compares it).
-- Exit 0 every variant ok (or the JIT off), 1 a variant FAILED, 2 the
-- instrument is missing (no jit.vmdef or jit.util, or no TYPEINS message).
local VARIANTS = { "or0", "xor0", "andm1", "shl0", "shr0", "sar0", "notnot", "mask" }
local BODY = {
  or0 = "x = i | 0", xor0 = "x = i ~ 0", andm1 = "x = i & -1", shl0 = "x = i << 0",
  shr0 = "x = i >> 0", sar0 = "x = i ~>> 0", notnot = "x = ~~i",
  mask = "x = i & 0xffffffff",  -- not an identity: the control, compiles with or without fix1
}
local hasjit = type(jit) == "table" and jit.status and jit.status()
local okv, vmdef = pcall(require, "jit.vmdef")
local oku, jutil = pcall(require, "jit.util")
local function instrument(msg) print("p4v: INSTRUMENT: " .. msg); os.exit(2) end
if hasjit and not (okv and oku) then instrument("no jit.vmdef or jit.util (set LUA_PATH to the build's src/?.lua)") end
local TYPEINS
if okv then
  for code, msg in pairs(vmdef.traceerr) do
    if msg == "persistent type instability" then TYPEINS = code end
  end
  if not TYPEINS then instrument("jit.vmdef has no \"persistent type instability\" trace error") end
end
local cur, stops, typeins = nil, 0, 0
if hasjit then
  jit.attach(function(what, tr, func, pc, code)
    if what == "stop" and func == cur then stops = stops + 1
    elseif what == "abort" and code == TYPEINS then typeins = typeins + 1 end
  end, "trace")
end
-- The name of f's loop opcode (the only FORL family instruction in f).
local function loopop(f)
  for pc = 1, 10000 do
    local ins = jutil.funcbc(f, pc)
    if not ins then break end
    local op = ins % 256
    local name = vmdef.bcnames:sub(op * 6 + 1, op * 6 + 6):gsub(" +$", "")
    if name:match("FORL$") then return name end
  end
  return "none"
end

local nbad = 0
for _, v in ipairs(VARIANTS) do
  local f = assert(load([[
    local n, x0 = ...
    local x, y = x0, 0
    for i = 1, n do y = y ~ ((x & 255) << 45); ]] .. BODY[v] .. [[ end
    return x, y
  ]], "=p4v-" .. v))
  cur, stops, typeins = f, 0, 0
  local a, b
  for _ = 1, 3 do a, b = f(100000, 1) end
  cur = nil
  local line = string.format("%s\tx=%.17g y=%.17g", v, a, b)
  if hasjit then
    local op = loopop(f)
    local ok = stops >= 1 and typeins == 0 and op == "JFORL"
    if not ok then nbad = nbad + 1 end
    line = line .. string.format("\ttraces=%d typeins=%d loop=%s %s", stops, typeins, op, ok and "ok" or "FAILED")
  else
    line = line .. "\t-"
  end
  print(line)
end
if hasjit then
  print(string.format("p4v: %d of %d variants compiled without type instability or blacklisting", #VARIANTS - nbad, #VARIANTS))
end
os.exit(nbad == 0 and 0 or 1)
