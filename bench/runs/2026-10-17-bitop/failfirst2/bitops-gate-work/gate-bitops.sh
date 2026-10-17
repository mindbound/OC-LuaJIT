# THE BITWISE OPERATORS ARE LUA 5.3.6's, 64-BIT (round 3), functionally, on
# the luajit.exe that links this libluajit.a, in every place that computes
# them: folded constants, the interpreter's fast path (number operands), its
# slow path (strings, out-of-range counts, errors), and a hot loop compiled
# by the JIT, whose exactness guard must exit where the result first has
# more than 53 significant bits (i = 151: (150 - 151) >> 1 is 2^63 - 1) and
# leave the interpreter to raise.  Before that it adds (150 - i) >> 1 and
# the masked remedy (-i & 0xFFFFFFFF) >> 8 & 0xFF for i = 1..150 into a sum
# it keeps in an upvalue every iteration, acc, which the raise does not
# discard: the line carries it, so a compiled loop that computes other
# values but still exits at 151 is seen (the review's catch, 2026-10-17:
# without acc such a loop printed the expected line).  Each field is an
# operator's result as %.17g, or its error's kind: X<op> for "result of
# '<op>' has more than 53 significant bits (mask each operand to 32 bits
# first)", noint, type (the bitwise verb), arith (upstream's verb).  The
# expected line is PUC Lua 5.3.6's on every field the two share, with each
# result passed through the same rule (an exact double or the error); acc is
# PUC's sum for i = 1..150 (43800, measured); dump, bit and jit are LuaJIT's.
# The loop counts loop/stitch/abort traces in hot() as the string.pack gate
# does, so that the gate fails with the JIT off.  The probe contains no
# backslashes (heredocs here eat them).
cat > "$OCLJ_BUILD/bitops.lua" <<'EOF'
local o = tonumber("1")
local function E(f, ...)
  local ok, r = pcall(f, ...)
  if ok then return string.format("%.17g", r) end
  r = tostring(r)
  if r:find("has more than 53 significant bits", 1, true) then
    return "X" .. (r:match("result of '([^']*)'") or "?")
  elseif r:find("no integer representation", 1, true) then return "noint"
  elseif r:find("perform bitwise operation on", 1, true) then return "type"
  elseif r:find("perform arithmetic on", 1, true) then return "arith"
  end
  return "other"
end
local fold = string.format("%.17g/%.17g/%.17g", 1 << 32, ~0, 1 << 64)
local kx = E(load("return -1 >> 1"))
local rt = E(function() return o << 32 end) .. "/" .. E(function() return (-o) >> 1 end) .. "/" ..
  E(function() return ~0 >> o end) .. "/" .. E(function() return (-o) >> 11 end) .. "/" ..
  E(function() return (-o) >> 10 end) .. "/" .. E(function() return o << 64 end) .. "/" ..
  E(function() return ~(2^53 * o) end) .. "/" .. E(function() return (2^60 * o) | 1 end)
local err = E(function() return 1.5 | o end) .. "/" .. E(function() return "3" & o end) .. "/" ..
  E(function() return "0x10" | o end) .. "/" .. E(function() return {} | o end) .. "/" ..
  E(function() return 2^63 & o end) .. "/" .. E(function() return "-1" >> o end)
local sar = E(function() return (-8 * o) ~>> 2 end) .. "/" .. E(function() return (-o) ~>> 64 end) .. "/" ..
  E(function() return (4 * o) ~>> -1 end)
local dump = string.dump(function() end):byte(4)
local bl = bit and bit.lshift(1, 32)
local jutil = require("jit.util")
local st, mine = { loop = 0, stitch = 0, abort = 0 }, {}
local last, acc = 0, 0
local function hot() local s = 0 for i = 1, 300 do last = i s = s + ((150 - i) >> 1) + ((-i & 0xFFFFFFFF) >> 8 & 0xFF) acc = s end return s end
local function cold() local s = 0 for i = 1, 300 do last = i s = s + ((150 - i) >> 1) + ((-i & 0xFFFFFFFF) >> 8 & 0xFF) acc = s end return s end
local function cb(what, tr, func)
  if what == "start" then mine[tr] = (func == hot)
  elseif what == "stop" and mine[tr] then
    local lt = jutil.traceinfo(tr).linktype
    if st[lt] then st[lt] = st[lt] + 1 end
  elseif what == "abort" and mine[tr] then st.abort = st.abort + 1 end
end
jit.off(cold)
jit.flush()
jit.attach(cb, "trace")
local hres = E(hot)
local hlast, hacc = last, acc
jit.attach(cb)
local cres = E(cold)
local clast, cacc = last, acc
print("fold=" .. fold .. " kx=" .. kx .. " rt=" .. rt .. " err=" .. err .. " sar=" .. sar ..
  " dump=" .. dump .. " bit=" .. tostring(bl) .. " hot=" .. hres .. "@" .. hlast .. " acc=" .. hacc ..
  " jit=" .. st.loop .. "/" .. st.stitch .. "/" .. st.abort ..
  " same=" .. tostring(hres == cres and hlast == clast and hacc == cacc))
EOF
BO=$("$LJEXE" "$OCLJ_BUILD/bitops.lua" 2>&1)
say "    bitwise-operator gate: $BO"
BO_WANT='fold=4294967296/-1/0 kx=X>> rt=4294967296/X>>/X>>/9007199254740991/X>>/0/X~/X| err=noint/1/17/type/noint/X>> sar=-2/-1/8 dump=128 bit=1 hot=X>>@151 acc=43800 jit=1/0/0 same=true'
[ "$BO" = "$BO_WANT" ] || fail "the bitwise-operator gate read
           $BO
         want
           $BO_WANT
         fold (1 << 32, ~0, 1 << 64, folded by the parser) other than 4294967296/-1/0:
           lj_parse.c folds by BitOp's 32-bit rules (native/luajit/patch-bitop-parse.sh).
         kx other than X>>: the parser folded -1 >> 1, whose result has 64 significant
           bits, instead of leaving it to the run time to raise.
         rt (o << 32, -o >> 1, ~0 >> o, -o >> 11, -o >> 10, o << 64, ~(2^53 o),
           2^60 o | 1, with o a run-time 1): the interpreter's fast path
           (native/luajit/patch-bitop-vm.sh) is not 5.3.6's 64-bit one, or returns a
           rounded result where it must raise (X); -o >> 11 is 2^53 - 1, the largest
           exact result of a shifted -1.
         err (1.5 | o, '3' & o, '0x10' | o, {} | o, 2^63 & o, '-1' >> o): the slow path
           (native/luajit/oclj_bitop_meta.c) does not coerce strings, raise 5.3.6's
           errors, or check the result of a string operand.
         sar (-8 o ~>> 2, -o ~>> 64, 4 o ~>> -1) other than -2/-1/8: ~>> is not the
           64-bit arithmetic shift (oclj_bitop.h, oclj_shiftar).
         dump other than 128: string.dump's version byte is not 0x80
           (native/luajit/patch-bitop-bcdump.sh).
         bit other than 1: LuaJIT's own bit library changed; it must stay 32-bit.
         hot other than X>>@151: the compiled loop did not raise where the result first
           has more than 53 significant bits (no exactness guard, or a rounded
           result), or raised elsewhere (native/luajit/oclj_bitop_rec.c,
           patch-bitop-fold.sh).
         acc other than 43800: the loop's sum for i = 1..150, before the raise, is not
           PUC 5.3.6's: the compiled loop computes another value for (150 - i) >> 1 or
           (-i & 0xFFFFFFFF) >> 8 & 0xFF while the results fit (native/luajit/
           oclj_bitop_rec.c, oclj_bitop_fold.c, patch-bitop-fold.sh), or, with
           same=true, the interpreter does as well (patch-bitop-vm.sh).
         jit (loop/stitch/abort traces recorded in hot()) other than 1/0/0: a loop count
           of 0 means no trace was recorded, so the gate proved nothing about the JIT;
           an abort means the recorder refuses the operators, which runs such loops
           interpreted.
         same=false: the compiled loop and the interpreted one disagree: in the result,
           in where they raise, or in acc."

