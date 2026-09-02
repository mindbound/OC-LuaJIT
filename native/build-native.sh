#!/bin/sh
# =====================================================================
# build-native.sh -- clean checkout -> libjnlua52-windows-x86_64.dll
#
# Builds the OC-compatible native that makes OpenComputers' OWN repackaged
# JNLua drive LuaJIT 2.1. Nothing in OC-JNLua, in the OC Java layer, or in
# ocelot-brain is modified; the whole compatibility layer is lj52shim.{c,h}.
#
# The DLL is three translation units plus static LuaJIT:
#   jnlua.o    OC-JNLua's own native/src/jnlua.c, UNMODIFIED, compiled with
#              -include lj52shim.h so the 5.2 C API it calls resolves to us
#   lj52shim.o the compatibility layer (5.2 surface on the 5.1 ABI)
#   eris_lj.o  our Eris-API-compatible serializer (serializer/eris_lj.c)
#   libluajit.a  LuaJIT 2.1 static, LUA52COMPAT + CHECKHOOK
#
# WHY THOSE TWO LUAJIT FLAGS (both are mandatory, not tuning):
#   LUAJIT_ENABLE_LUA52COMPAT -- OC's platform (machine.lua, OpenOS, the
#       sandbox) is Lua 5.2 source. Without it table.unpack, __pairs,
#       goto/labels-adjacent behaviour and 5.2 coroutine semantics differ.
#   LUAJIT_ENABLE_CHECKHOOK   -- REQUIRED TO BOOT with the JIT on.
#       machine.lua's first statement spins waiting for a count hook.  A stock
#       LuaJIT never delivers a count hook from inside a compiled trace, so
#       the kernel hangs before the sandbox is ever built.  CHECKHOOK makes
#       the recorder emit hook checks.  It is NOT an upstream LuaJIT option:
#       it exists only in the pinned tree (see LUAJIT_SRC below).
#
# ---------------------------------------------------------------------
# EXTERNAL INPUTS (none of them live in this repo; see PREREQUISITES at
# the bottom of this header for exactly how each is obtained)
#   OCLJ_REPO   OC-LuaJIT checkout      (default: parent dir of this script's dir)
#   OCLJ_JNLUA  OC-JNLua checkout       git clone https://github.com/MightyPirates/OC-JNLua.git
#   OCLJ_JNI    a JDK's include/ dir    any JDK 8+ (jni.h + win32/jni_md.h)
#   OCLJ_SHIM   dir holding lj52shim.c and lj52shim.h  (default $OCLJ_REPO/native)
#   OCLJ_LUAJIT LuaJIT source tree      (default $OCLJ_REPO/prototype/watchdog/luajit)
#   OCLJ_BUILD  scratch build dir       (default $OCLJ_REPO/build/native)
#   OCLJ_OUT    where the DLL lands     (default $OCLJ_BUILD/libdir)
#   CC          C compiler              (default gcc; MinGW-w64 x86_64 on Windows)
#   JOBS        make -j                 (default 4)
#
# USAGE
#   OCLJ_JNLUA=/path/to/OC-JNLua OCLJ_JNI="/c/Program Files/Java/jdk1.8.0_211/include" \
#     sh build-native.sh
#
# OUTPUT
#   $OCLJ_OUT/libjnlua52-windows-x86_64.dll
#   That exact basename is what ocelot-brain looks for.  LuaStateFactory
#   builds it as  "libjnlua" + version + "-" + platformName + libExtension
#   (version="52", platformName="windows-x86_64") and finds it by scanning
#   the directory named in the config key
#       opencomputers.debug.forceNativeLibPathFirst
#   BEFORE the natives bundled in OC-JNLua-Natives.  Point that key at
#   $OCLJ_OUT and ocelot-brain loads this DLL instead of the stock PUC-Lua
#   5.2 one.  smoke-test.sh does exactly that.
#
# EXIT STATUS: 0 only if every stage produced its artifact and every
# postflight assertion held.  Any failure is fatal and named.
# =====================================================================
set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)}"
: "${OCLJ_LUAJIT:=$OCLJ_REPO/prototype/watchdog/luajit}"
: "${OCLJ_SHIM:=$OCLJ_REPO/native}"
: "${OCLJ_SER:=$OCLJ_REPO/serializer}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${OCLJ_OUT:=$OCLJ_BUILD/libdir}"
: "${OCLJ_JNLUA:=}"
: "${OCLJ_JNI:=}"
: "${CC:=gcc}"
: "${JOBS:=4}"

DLL_NAME=libjnlua52-windows-x86_64.dll
LJ_FLAGS="-DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_CHECKHOOK"

fail() { echo "BUILD FAIL: $*" >&2; exit 1; }
say()  { echo "[build] $*"; }
T0=$(date +%s)
stamp() { echo "[build] +$(( $(date +%s) - T0 ))s  $*"; }

# --------------------------------------------------------------- 0
say "=============== 0. preflight ==============="
command -v "$CC" >/dev/null 2>&1 || fail "no C compiler '$CC' on PATH (need MinGW-w64 x86_64 gcc)"
say "cc      = $("$CC" --version | head -1)"
[ -n "$OCLJ_JNLUA" ] || fail "OCLJ_JNLUA is unset: point it at an OC-JNLua checkout (git clone https://github.com/MightyPirates/OC-JNLua.git)"
[ -f "$OCLJ_JNLUA/native/src/jnlua.c" ] || fail "no $OCLJ_JNLUA/native/src/jnlua.c"
if [ -z "$OCLJ_JNI" ]; then
  for c in "$JAVA_HOME/include" "/c/Program Files/Java/jdk1.8.0_211/include"; do
    [ -f "$c/jni.h" ] && OCLJ_JNI="$c" && break
  done
fi
[ -n "$OCLJ_JNI" ] && [ -f "$OCLJ_JNI/jni.h" ] || fail "OCLJ_JNI must name a JDK include dir containing jni.h"
[ -f "$OCLJ_JNI/win32/jni_md.h" ] || fail "no $OCLJ_JNI/win32/jni_md.h (need a Windows JDK's include dir)"
[ -f "$OCLJ_SHIM/lj52shim.c" ] || fail "no $OCLJ_SHIM/lj52shim.c"
[ -f "$OCLJ_SHIM/lj52shim.h" ] || fail "no $OCLJ_SHIM/lj52shim.h"
[ -f "$OCLJ_SER/eris_lj.c" ]   || fail "no $OCLJ_SER/eris_lj.c"
[ -f "$OCLJ_LUAJIT/src/lj_record.c" ] || fail "no LuaJIT source at $OCLJ_LUAJIT"
grep -q LUAJIT_ENABLE_CHECKHOOK "$OCLJ_LUAJIT/src/lj_record.c" \
  || fail "$OCLJ_LUAJIT is a STOCK LuaJIT: lj_record.c has no LUAJIT_ENABLE_CHECKHOOK.
         Machine.lua cannot boot with the JIT on against a stock tree.
         Use the pinned tree in this repo (prototype/watchdog/luajit)."
# --- ONE BEHAVIOUR, NO ESCAPE HATCHES -------------------------------------
# The abandoned shim variants each carried a switch that selected a known-
# broken path: OCLJ_NOMODECHECK disabled the chunk-mode (allowBytecode) gate,
# LJ52_DROP_LOAD_MODE compiled it out, OCLJ_TRACE installed a LUA_MASKCOUNT
# hook in the slot OC's deadline watchdog owns, OCLJ_JITOPT / OCLJ_JITATTACH
# let the environment reconfigure the JIT, and LJ52_MEMLIMIT replaced OC's
# per-machine RAM cap with an env var defaulting to unlimited.  Refuse to
# build if any of them comes back.  Comment lines are excluded so the shim can
# still NAME the hatches it removed.
codegrep() {   # codegrep <pattern> -> prints only non-comment matches
  grep -n "$1" "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" 2>/dev/null \
    # NOTE: no ^ anchor and no [^:]* prefix. With a Windows drive-letter path
    # (C:/Users/...) the character class stops at the drive colon, no comment
    # line is ever stripped, and this gate then fails on the shim's own prose
    # DESCRIBING the escape hatches it removed -- accusing the shim of exactly
    # the regression it exists to prevent. Measured: 3 false matches under
    # C:/..., 0 under /c/....
    | grep -vE ':[0-9]+: *([*]|/[*]|//)'
}
for tok in OCLJ_NOMODECHECK LJ52_DROP_LOAD_MODE OCLJ_TRACE OCLJ_JITOFF OCLJ_JITOPT \
           OCLJ_JITATTACH LJ52_MEMLIMIT LJ52_NO_ALLOC_FIX LJ52_NO_RIDX \
           LJ52_NO_CFCACHE SHIM_ALLOC_NEUTERED SHIM_ALLOC_FAITHFUL LJ52_NOJIT; do
  if codegrep "$tok" | grep -q .; then
    codegrep "$tok"
    fail "escape hatch '$tok' is back in the shim (line above).  The canonical"
  fi
done
if codegrep getenv | grep -q .; then
  codegrep getenv
  fail "the shim calls getenv().  Security- and scheduling-relevant behaviour
         must not be taken from the process environment, where no server
         operator would ever see it."
fi
# The mode gate itself, asserted by shape rather than trusted.
grep -q 'define lua_load(L, r, d, cn, mode) lua_loadx' "$OCLJ_SHIM/lj52shim.h" \
  || fail "lj52shim.h does not map lua_load onto lua_loadx.  The chunk-mode
         argument -- OC's computer.lua.allowBytecode gate -- would be dropped
         or only half enforced."
# And the serializer must NOT be able to see that macro: its own lua_loadx(...,
# "b") call is what keeps unpersist working.
grep -q 'lj52shim.h' "$OCLJ_SER/eris_lj.c" \
  && fail "serializer/eris_lj.c includes the shim header.  Its internal
         bytecode load path must reach the genuine lua_loadx directly."

LJ_COMMIT=$(git -C "$OCLJ_LUAJIT" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)
say "luajit  = $OCLJ_LUAJIT @ $LJ_COMMIT (CHECKHOOK patch present)"
say "jnlua   = $OCLJ_JNLUA @ $(git -C "$OCLJ_JNLUA" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
say "shim    = $OCLJ_SHIM"
say "out     = $OCLJ_OUT/$DLL_NAME"

mkdir -p "$OCLJ_BUILD/obj" "$OCLJ_OUT" || fail "cannot create $OCLJ_BUILD"

# --------------------------------------------------------------- 1
say "=============== 1. LuaJIT 2.1 (static) ==============="
say "    XCFLAGS=$LJ_FLAGS   BUILDMODE=static"
LJ_WORK=$OCLJ_BUILD/luajit
if [ ! -d "$LJ_WORK" ]; then
  say "copying $OCLJ_LUAJIT -> $LJ_WORK (the source tree is built in place; we never dirty the checkout)"
  cp -r "$OCLJ_LUAJIT" "$LJ_WORK" || fail "copy failed"
  rm -rf "$LJ_WORK/.git"
fi
LJ=$LJ_WORK/src
make -C "$LJ" clean >/dev/null 2>&1
# Q= makes the Makefile echo full compiler command lines, so the flags can be
# asserted rather than assumed.
make -C "$LJ" BUILDMODE=static XCFLAGS="$LJ_FLAGS" Q= -j"$JOBS" \
  > "$OCLJ_BUILD/luajit_build.log" 2>&1 \
  || { tail -30 "$OCLJ_BUILD/luajit_build.log"; fail "LuaJIT build failed (log: $OCLJ_BUILD/luajit_build.log)"; }
[ -f "$LJ/libluajit.a" ] || fail "no $LJ/libluajit.a after make"
stamp "libluajit.a built ($(wc -c < "$LJ/libluajit.a") bytes)"

# The two flags must be OBSERVABLE, not merely passed.
grep -q -- "-DLUAJIT_ENABLE_LUA52COMPAT" "$OCLJ_BUILD/luajit_build.log" \
  || fail "LUA52COMPAT never reached the compiler command line"
grep -q -- "-DLUAJIT_ENABLE_CHECKHOOK" "$OCLJ_BUILD/luajit_build.log" \
  || fail "CHECKHOOK never reached the compiler command line"

LJEXE=$LJ/luajit.exe; [ -x "$LJEXE" ] || LJEXE=$LJ/luajit
[ -x "$LJEXE" ] || fail "no luajit interpreter was produced"
V=$("$LJEXE" -e 'io.write(tostring(table.unpack ~= nil), "|", _VERSION, "|", jit.version, "|", jit.arch)' 2>&1)
say "    luajit says: $V"
case "$V" in
  true\|*) : ;;
  *) fail "LUA52COMPAT is NOT in effect: table.unpack missing ($V)" ;;
esac

# CHECKHOOK, functionally.  A count hook set over a loop hot enough to be
# recorded must still fire.  On a stock LuaJIT the trace never checks hooks,
# the count stays at 0, and machine.lua's opening spin-wait hangs forever.
cat > "$OCLJ_BUILD/checkhook.lua" <<'EOF'
local n = 0
debug.sethook(function() n = n + 1 end, "", 500)
local s = 0
for i = 1, 20000000 do s = s + i end
debug.sethook()
io.write(n, "|", s == 0 and "?" or "ok", "\n")
EOF
CH=$("$LJEXE" "$OCLJ_BUILD/checkhook.lua" 2>&1)
say "    count-hook ticks over a hot loop: $CH"
CHN=${CH%%|*}
case "$CHN" in ''|*[!0-9]*) fail "checkhook probe produced no number: $CH" ;; esac
[ "$CHN" -gt 100 ] \
  || fail "CHECKHOOK is NOT in effect: a count hook fired $CHN times across 20M
         iterations.  machine.lua's first statement spins waiting for that hook
         and will hang with the JIT on."

# --------------------------------------------------------------- 1b
# The shim creates the state with a libc allocator (lua_newstate) because
# jnlua.c hands LuaJIT-owned blocks to libc free() at close time otherwise.
# Only a GC64 build tolerates a foreign allocator on x64.  Prove it here,
# at build time, rather than discovering it as a JVM-killing heap
# corruption at close time.
say "=============== 1b. GC64 / foreign-allocator gate ==============="
cat > "$OCLJ_BUILD/allocprobe.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <lua.h>
static void *a(void *ud, void *p, size_t o, size_t n) {
  (void)ud; (void)o;
  if (n == 0) { free(p); return NULL; }
  return realloc(p, n);
}
int main(void) {
  lua_State *L = lua_newstate(a, NULL);
  if (!L) { printf("FOREIGN-ALLOC-REFUSED\n"); return 1; }
  lua_close(L);
  printf("FOREIGN-ALLOC-OK\n");
  return 0;
}
EOF
"$CC" -O0 -I"$LJ" "$OCLJ_BUILD/allocprobe.c" "$LJ/libluajit.a" -lm \
  -o "$OCLJ_BUILD/allocprobe.exe" >/dev/null 2>&1 || fail "allocator probe would not link"
PROBE=$("$OCLJ_BUILD/allocprobe.exe" 2>&1)
say "    $PROBE"
[ "$PROBE" = "FOREIGN-ALLOC-OK" ] \
  || fail "this LuaJIT refuses a foreign allocator (non-GC64 x64 build).
         lj52_newstate() would silently fall back to LuaJIT's own allocator and
         jnlua's close-time free() would corrupt the heap and kill the JVM."

# --------------------------------------------------------------- 2
say "=============== 2. lj52shim.c ==============="
rm -f "$OCLJ_BUILD/obj/lj52shim.o"
"$CC" -c -O2 -Wall -Wextra -I"$LJ" -I"$OCLJ_SHIM" -I"$OCLJ_SER" \
  "$OCLJ_SHIM/lj52shim.c" -o "$OCLJ_BUILD/obj/lj52shim.o" 2>"$OCLJ_BUILD/shim.err"
[ -f "$OCLJ_BUILD/obj/lj52shim.o" ] || { cat "$OCLJ_BUILD/shim.err"; fail "shim did not compile"; }
SW=$(grep -c 'warning:' "$OCLJ_BUILD/shim.err" || true)
say "    -Wall -Wextra warnings = $SW"
[ "$SW" = "0" ] || { grep -E 'warning:' "$OCLJ_BUILD/shim.err" | head -20; fail "the shim must compile warning-clean"; }

# --------------------------------------------------------------- 3
say "=============== 3. OC-JNLua jnlua.c (UNMODIFIED, shim force-included) ==============="
# -include lj52shim.h is the whole trick: jnlua.c's 5.2 calls bind to the shim
# before jnlua.c's own first line is read.  jnlua.c itself is byte-identical to
# upstream OC-JNLua -- verified below.
rm -f "$OCLJ_BUILD/obj/jnlua.o"
"$CC" -c -O2 -Wall -DNDEBUG -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" -I"$LJ" -I"$OCLJ_SHIM" \
  -include "$OCLJ_SHIM/lj52shim.h" \
  "$OCLJ_JNLUA/native/src/jnlua.c" -o "$OCLJ_BUILD/obj/jnlua.o" \
  > "$OCLJ_BUILD/jnlua.err" 2>&1
NERR=$(grep -c 'error:' "$OCLJ_BUILD/jnlua.err" || true)
NWARN=$(grep -c 'warning:' "$OCLJ_BUILD/jnlua.err" || true)
say "    errors=$NERR  warnings=$NWARN   (-Wall; jnlua.c is byte-identical to upstream)"
[ "$NERR" = "0" ] && [ -f "$OCLJ_BUILD/obj/jnlua.o" ] \
  || { grep -oE 'error: .*' "$OCLJ_BUILD/jnlua.err" | head -20; fail "jnlua.c did not compile"; }

# ZERO SHIM-ATTRIBUTABLE WARNINGS.
# jnlua.c carries exactly two warnings of its OWN under -Wall, and both are
# provably nothing to do with this shim:
#   jnlua.c:623  -Wpointer-sign, pushbytearray_protected passes an explicitly
#                cast (jbyte*) where lua_pushlstring wants (const char*).
#                lua_pushlstring has the same prototype in 5.1, 5.2 and 5.3,
#                so this warns against PUC Lua too.  The warning is about
#                argument 2; nothing on that line comes from the shim.
#   jnlua.c:1666 -Wmaybe-uninitialized, lua_1tablesize returns the local
#                tablesize_result without initialising it when checkstack or
#                checktype fails.  A plain local-flow defect in jnlua.c.
# We may not touch jnlua.c, so instead of suppressing the warning classes we
# pin the warning SET: exactly these two lines, nothing else.  Any warning the
# shim introduces -- a wrong arity, a wrong type, a missing declaration -- is
# a line outside the allowlist and fails the build.  If OC-JNLua is bumped and
# these two move or vanish, update the allowlist deliberately.
grep -E 'warning:' "$OCLJ_BUILD/jnlua.err" \
  | grep -vE 'jnlua\.c:623:[0-9]+: warning: pointer targets in passing argument 2' \
  | grep -vE "jnlua\.c:1666:[0-9]+: warning: 'tablesize_result' may be used uninitialized" \
  > "$OCLJ_BUILD/jnlua.unexpected" 2>/dev/null
UNEXPECTED=$(grep -c . "$OCLJ_BUILD/jnlua.unexpected" || true)
say "    shim-attributable warnings = $UNEXPECTED  (2 pre-existing jnlua.c warnings allowlisted)"
[ "$UNEXPECTED" = "0" ] \
  || { cat "$OCLJ_BUILD/jnlua.unexpected"; fail "jnlua.c produced a warning that is NOT one of its two
         known pre-existing ones (see the allowlist just above this check).
         A new warning here is the SHIM presenting a subtly wrong 5.2 surface
         -- a wrong arity, a wrong type, a missing declaration.  Fix the shim;
         never touch jnlua.c."; }
if git -C "$OCLJ_JNLUA" status --porcelain -- native/src/jnlua.c 2>/dev/null | grep -q .; then
  fail "$OCLJ_JNLUA/native/src/jnlua.c is MODIFIED. The whole claim is that OC's
         own jnlua.c is untouched; refusing to build a DLL that would make a
         patched jnlua.c look like a clean one."
fi

# --------------------------------------------------------------- 4
say "=============== 4. eris_lj.c ==============="
# Compiled WITHOUT -include lj52shim.h on purpose: the serializer must reach
# the genuine LuaJIT lua_load/lua_loadx so it can load the LuaJIT bytecode it
# writes with lj_bcwrite.  The 'b' path stays open INTERNALLY to eris_lj while
# lj52_load keeps it shut to sandbox code (allowBytecode=false).
"$CC" -c -O2 -I"$LJ" -I"$OCLJ_SER" -DERIS_LJ_COMMIT="\"$LJ_COMMIT\"" \
  "$OCLJ_SER/eris_lj.c" -o "$OCLJ_BUILD/obj/eris_lj.o" 2>"$OCLJ_BUILD/eris.err"
[ -f "$OCLJ_BUILD/obj/eris_lj.o" ] || { grep -oE 'error: .*' "$OCLJ_BUILD/eris.err" | head -20; fail "eris_lj.c did not compile"; }

# --------------------------------------------------------------- 5
say "=============== 5. link ==============="
# javavm.c is deliberately NOT linked: it is OC-JNLua's "start a JVM from Lua"
# entry point, which the embedded (JVM-hosted) direction never uses.
"$CC" -shared -o "$OCLJ_OUT/$DLL_NAME" \
  "$OCLJ_BUILD/obj/jnlua.o" "$OCLJ_BUILD/obj/lj52shim.o" "$OCLJ_BUILD/obj/eris_lj.o" \
  "$LJ/libluajit.a" -lm -static-libgcc -Wl,--enable-stdcall-fixup \
  > "$OCLJ_BUILD/link.err" 2>&1
[ -f "$OCLJ_OUT/$DLL_NAME" ] || { head -30 "$OCLJ_BUILD/link.err"; fail "link failed"; }

# --------------------------------------------------------------- 6
say "=============== 6. postflight ==============="
if command -v objdump >/dev/null 2>&1; then
  EXPORTS=$(objdump -p "$OCLJ_OUT/$DLL_NAME" | grep -oE '\bJava_[A-Za-z0-9_]+' | sort -u | wc -l)
  ONLOAD=$(objdump -p "$OCLJ_OUT/$DLL_NAME" | grep -c 'JNI_OnLoad')
  PKG=$(objdump -p "$OCLJ_OUT/$DLL_NAME" | grep -oE '\bJava_li_cil_repack_[A-Za-z0-9_]+' | head -1)
  say "    Java_* exports = $EXPORTS   JNI_OnLoad = $ONLOAD"
  say "    e.g. $PKG"
  [ "$EXPORTS" -gt 50 ] || fail "only $EXPORTS Java_* exports; jnlua did not link in"
  [ -n "$PKG" ] || fail "no Java_li_cil_repack_* export: this is upstream naef/jnlua, not OC's repack.
         ocelot-brain looks up li.cil.repack.com.naef.jnlua.LuaState and would find nothing."
  # ABI SURFACE, pinned.  ocelot-brain resolves every LuaState native method
  # by JNI name, so the DLL is ABI-compatible iff the exported NAME SET is the
  # one OC-JNLua declares.  jnlua.c at da3d4d45 exports 87 Java_* methods plus
  # JNI_OnLoad and JNI_OnUnload = 89.  Verified equal, name for name, to the
  # export table of the arm7 DLL behind the original passing OpenOS runs.
  ALL=$(objdump -p "$OCLJ_OUT/$DLL_NAME" | grep -E '[+]base[[][ 0-9]+[]][ ]+[0-9a-f]{4} ' \
    | sed 's/.*[0-9a-f][0-9a-f][0-9a-f][0-9a-f] //' | sort -u)
  NALL=$(printf %s"\n" "$ALL" | grep -c .)
  say "    total exports  = $NALL  (87 Java_* + JNI_OnLoad + JNI_OnUnload)"
  [ "$NALL" = "89" ] || fail "export count is $NALL, expected 89.  The DLL's ABI surface
         no longer matches OC-JNLua da3d4d45.  Either jnlua.c was bumped (update
         this number deliberately) or a translation unit failed to link in."
  printf %s"\n" "$ALL" | grep -qx JNI_OnLoad   || fail "no JNI_OnLoad export"
  printf %s"\n" "$ALL" | grep -qx JNI_OnUnload || fail "no JNI_OnUnload export"
fi
SZ=$(wc -c < "$OCLJ_OUT/$DLL_NAME")
SHA=$(sha256sum "$OCLJ_OUT/$DLL_NAME" 2>/dev/null | cut -c1-16)
stamp "OK  $OCLJ_OUT/$DLL_NAME  ${SZ} bytes  sha256:${SHA}..."
echo
echo "NEXT: point ocelot-brain at it and boot OpenOS:"
echo "  OCLJ_LIBDIR=$OCLJ_OUT sh $SELF_DIR/smoke-test.sh"

# =====================================================================
# PREREQUISITES -- how to obtain every external input, from nothing
# ---------------------------------------------------------------------
# 1. MinGW-w64 x86_64 gcc (msvcrt or ucrt).  Verified with 15.2.0 at
#    C:/mingw64/bin/gcc.  Add it to PATH.  GNU make comes with it.
#
# 2. A Windows JDK's include/ directory, for jni.h and win32/jni_md.h.
#    Any JDK 8 or newer works; the DLL only uses JNI 1.6 surface.
#      OCLJ_JNI="/c/Program Files/Java/jdk1.8.0_211/include"
#
# 3. OC-JNLua sources -- OpenComputers' repackaged JNLua, the thing whose
#    jnlua.c we compile untouched:
#      git clone https://github.com/MightyPirates/OC-JNLua.git
#    Only native/src/jnlua.c is consumed.  Its gradle build is not used.
#
# 4. LuaJIT: already vendored in this repo at prototype/watchdog/luajit,
#    pinned to upstream 1ee778a4 PLUS the CHECKHOOK patch (lj_record.c).
#    A stock LuaJIT clone will NOT work -- the preflight rejects it.
#
# 5. Nothing else.  eris_lj.c and lj52shim.c are in this repo.
#
# The smoke test needs three more things (ocelot-brain, its jar deps, and a
# Scala compiler); see the header of smoke-test.sh.
# =====================================================================
