# LuaJIT'S OWN jit.* TOOLS STILL DECODE BYTECODE (round 3's seventh change,
# native/luajit/patch-bitop-jitlib.sh), on the luajit.exe that links this
# libluajit.a, run in the build copy's src/ with LUA_PATH ./?.lua so that
# require finds jit/*.lua there (the sandbox has none of them).  jit.util
# returned a bytecode word as a signed int32, and jit/bc.lua's
# (ins >> 8) & 0xff raises on a negative word whose A operand is not a
# multiple of 8 (on the others it decodes a wrong jump target, silently):
# `luajit -bl` stopped at the first forward jump, FORI or negative KSHORT,
# and -jdump, whose default modes include 'b', raised in its record handler
# and aborted every trace it recorded through such a word -- the instrument
# made bit-operator loops look uncompilable.  One probe, three runs:
#   plain     the probe's line: f's and hot()'s results (PUC 5.3.6's, with
#             the rule); snapend, the end marker of the first snapshot of
#             hot()'s trace as jit.util.tracesnap returns it, SNAP(255, 0,
#             0) unsigned, 4278190080 (signed it is -16777216; the entries
#             themselves differ only for a slot of 128 or more, which a
#             trace this short has not, so they are left to the patch
#             script's content check); and bc, how many instructions -bl
#             must list (each function's jit.util.funcinfo bytecodes less
#             its header, counted without decoding a word).
#   -bl       bl, the instruction lines listed, must be bc; blerr, the lines
#             on stderr, 0 (luajit -b exits 0 even when the listing raises);
#             bldec, how many of f's three negative words are listed exactly
#             as LuaJIT before round 3 listed them (KSHORT 1 -1, FORI 2 =>
#             0011, JMP 7 => 0010), 3.
#   -jdump=T  the default modes, t b i m (T only picks plain text over the
#             colours TERM would choose), over hot()'s loop, whose JMP has
#             A = 9: jd, the traces started, stopped as a loop, aborted, and
#             the "VM handler failed" lines, 1/1/0/0; jdb, the recorded
#             instructions the dump listed ('b') and of them the JMP decoded
#             exactly, 12/1; jdim, the IR and machine-code dumps, 1/1;
#             jdline, the probe's line printed unchanged under the dump, 1.
# The probe contains no backslashes (heredocs here eat them).
cat > "$OCLJ_BUILD/jitlib.lua" <<'EOF'
local jutil = require("jit.util")
local function f(t)
  local s = -1
  for i = 1, 3 do
    if t[i] then s = s + 1 end
  end
  return s
end
local function hot(n)
  local t, x, y = {}, 0, 3
  for i = 1, n do
    local a = t[1] or y
    x = (((x ~ i) & 0xFFFF) << 3) >> 1
  end
  return x
end
local function count(fn)
  local n = jutil.funcinfo(fn).bytecodes - 1
  for k = -1, -1000000, -1 do
    local c = jutil.funck(fn, k)
    if c == nil then break end
    if type(c) == "proto" then n = n + count(c) end
  end
  return n
end
local function snapend()
  for tr = 1, 100 do
    if jutil.traceinfo(tr) then local s = jutil.tracesnap(tr, 0) return string.format("%.0f", s[#s]) end
  end
  return "none"
end
local fr, hr = f({ true, false, true }), hot(300)
print("jitlib f=" .. fr .. " hot=" .. hr .. " snapend=" .. snapend() .. " bc=" .. count(debug.getinfo(1, "f").func))
EOF
# Absolute paths: the three runs cd into $LJ first.
JL_DIR=$(CDPATH= cd -- "$OCLJ_BUILD" && pwd)
JL_PROBE=$JL_DIR/jitlib.lua
JL_EXE=./$(basename "$LJEXE")
JL_LINE=$(cd "$LJ" && LUA_PATH='./?.lua' "$JL_EXE" "$JL_PROBE" 2>&1 | tr -d '\r')
JL_BL=$(cd "$LJ" && LUA_PATH='./?.lua' "$JL_EXE" -bl "$JL_PROBE" 2>"$JL_DIR/jitlib-bl.err" | tr -d '\r')
JL_JD=$(cd "$LJ" && LUA_PATH='./?.lua' "$JL_EXE" -jdump=T "$JL_PROBE" 2>&1 | tr -d '\r')
jl_n() { printf '%s\n' "$1" | grep -c -E -- "$2" || true; }
jl_x() { printf '%s\n' "$1" | grep -c -x -F -- "$2" || true; }
JL_DEC=$(( $(jl_x "$JL_BL" '0001    KSHORT   1  -1') + $(jl_x "$JL_BL" '0005    FORI     2 => 0011') + $(jl_x "$JL_BL" '0008    JMP      7 => 0010') ))
JL="$JL_LINE bl=$(jl_n "$JL_BL" '^[0-9]{4} ') blerr=$(grep -c . "$JL_DIR/jitlib-bl.err" || true) bldec=$JL_DEC"
JL="$JL jd=$(jl_n "$JL_JD" '^---- TRACE [0-9]+ start ')/$(jl_n "$JL_JD" '^---- TRACE [0-9]+ stop -> loop$')"
JL="$JL/$(jl_n "$JL_JD" '^---- TRACE [0-9]+ abort ')/$(jl_n "$JL_JD" 'VM handler failed')"
JL="$JL jdb=$(jl_n "$JL_JD" '^[0-9]{4}  [A-Z]')/$(jl_x "$JL_JD" '0010  JMP      9 => 0012')"
JL="$JL jdim=$(jl_n "$JL_JD" '^---- TRACE [0-9]+ IR$')/$(jl_n "$JL_JD" '^---- TRACE [0-9]+ mcode [0-9]+$')"
JL="$JL jdline=$(jl_x "$JL_JD" "$JL_LINE")"
say "    jit tools gate (luajit -bl, -jdump): $JL"
JL_WANT='jitlib f=1 hot=206208 snapend=4278190080 bc=118 bl=118 blerr=0 bldec=3 jd=1/1/0/0 jdb=12/1 jdim=1/1 jdline=1'
[ "$JL" = "$JL_WANT" ] || { head -5 "$JL_DIR/jitlib-bl.err"; fail "the jit tools gate read
           $JL
         want
           $JL_WANT
         (stderr of -bl above, if any; the probe is $JL_PROBE, run in $LJ)
         the probe's own fields other than those: f and hot are PUC 5.3.6's values,
           and bc counts the probe's instructions without decoding them; snapend
           -16777216 is jit.util.tracesnap returning snapshot entries signed again
           (native/luajit/patch-bitop-jitlib.sh); an error text means require found
           no jit/*.lua in $LJ, or the probe failed.
         bl other than bc, blerr other than 0, bldec other than 3: luajit -bl did not list
           every instruction, wrote to stderr (jit/bc.lua raising on a word), or decoded
           a negative word wrongly -- jit.util.funcbc returns the word signed again
           (native/luajit/patch-bitop-jitlib.sh did not reach lib_jit.o).
         jd other than 1/1/0/0: under -jdump the loop did not compile once, as a loop,
           without an abort or a failed dump handler: an abort with 'VM handler failed'
           is jit/bc.lua raising in the record handler, the same cause.
         jdb other than 12/1: the dump did not list the twelve recorded instructions, or
           listed the JMP (A = 9, a negative word) with another target.
         jdim other than 1/1: the IR or machine-code dump is missing (jit/dump.lua or
           jit/dis_x64.lua failed).
         jdline other than 1: the probe's line differs under -jdump."; }

