#!/bin/sh
# =====================================================================
# negative-control.sh -- PROVE tests/security_test.c has teeth.
#
# A security test that has never been observed to fail is not evidence.
# This script rebuilds the shim three more times, each time reintroducing
# ONE historical defect verbatim, and requires the security test to fail --
# on exactly the checks that defect corresponds to and no others.
#
#   1. dropmode  the rt variant's
#                  #define lua_load(L,r,d,cn,mode) lua_load((L),(r),(d),(cn))
#                which discards OC's allowBytecode gate silently.
#   2. sniffer   the arm6 / arm7 / work_r1 lj52_load: a hand-rolled 0x1B
#                byte-sniffer that enforced only ONE direction, leaked a
#                stack slot on every refusal, and could be switched off
#                entirely with an environment variable. This is the shim
#                that actually booted OpenOS, so this is not a strawman.
#                Run twice: as shipped, and with its env bypass set.
#   3. le51      the same shim's lua_compare(LUA_OPLE) as
#                  !lua_lessthan(L, idx2, idx1)
#                which is 5.1's rule and raises on an __le-only metatable.
#
# The sabotage is applied to COPIES under the build directory. The canonical
# native/lj52shim.{c,h} are never written to, and no build flag or
# environment variable in the canonical tree can select a broken path -- that
# is the point, and build-native.sh enforces it (see step 5 below, which
# checks that it refuses the sabotaged sources outright).
#
#   OCLJ_BUILD=<build dir used by build-native.sh> sh tests/negative-control.sh
#
# Exit 0 iff: the canonical build PASSES, every sabotaged build FAILS, and
# each failure set is exactly the expected one.
# =====================================================================
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_SHIM:=$SELF_DIR/../native}"
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${CC:=gcc}"
LJ=$OCLJ_BUILD/luajit/src
WORK=$OCLJ_BUILD/negctl

bad=0
fail()  { echo "NEGATIVE CONTROL SETUP FAIL: $*" >&2; exit 2; }
say()   { echo "[negctl] $*"; }
verdict() {  # verdict <ok?> <text>
  if [ "$1" = 0 ]; then echo "  RESULT: PASS  $2"; else echo "  RESULT: FAIL  $2"; bad=1; fi
}

[ -f "$LJ/libluajit.a" ]           || fail "no $LJ/libluajit.a -- run build-native.sh first"
[ -f "$OCLJ_BUILD/obj/eris_lj.o" ] || fail "no eris_lj.o -- run build-native.sh first"
[ -f "$OCLJ_SHIM/lj52shim.c" ]     || fail "no $OCLJ_SHIM/lj52shim.c"

rm -rf "$WORK"
mkdir -p "$WORK" || fail "cannot create $WORK"

# ---------------------------------------------------------------------
# build_variant <name>   -- compile $WORK/<name>/lj52shim.{c,h} into a
#                           security_test.exe of its own.
# ---------------------------------------------------------------------
build_variant() {
  v=$1
  d=$WORK/$v
  "$CC" -c -O2 -I"$LJ" -I"$d" -I"$OCLJ_SER" "$d/lj52shim.c" -o "$d/lj52shim.o" 2>"$d/shim.err" \
    || { sed -n '1,25p' "$d/shim.err"; fail "$v: lj52shim.c did not compile"; }
  "$CC" -O2 -I"$LJ" -I"$d" -include "$d/lj52shim.h" \
    "$SELF_DIR/security_test.c" "$d/lj52shim.o" "$OCLJ_BUILD/obj/eris_lj.o" \
    "$LJ/libluajit.a" -lm -o "$d/security_test.exe" 2>"$d/test.err" \
    || { sed -n '1,25p' "$d/test.err"; fail "$v: security_test.c did not link"; }
}

# ---------------------------------------------------------------------
# expect <name> <label> <expected status> <expected FAIL ids...>
# Runs the variant's test and requires BOTH the exit status and the exact
# set of failing check ids to match.  "Exactly" matters: a sabotage that
# broke everything would prove the test is noisy, not that it is precise.
# ---------------------------------------------------------------------
expect() {
  v=$1; label=$2; want_status=$3; shift 3
  # No expected ids means "nothing may fail"; keep that distinct from " ".
  if [ $# -eq 0 ]; then
    want=""
  else
    want=$(printf '%s\n' "$@" | sort | tr '\n' ' ')
  fi
  d=$WORK/$v
  ( cd "$d" && ./security_test.exe ) >"$d/run.log" 2>&1
  st=$?
  got=$(grep '^FAIL ' "$d/run.log" | awk '{print $2}' | sort | tr '\n' ' ')
  echo
  say "--- $v : $label"
  say "    exit status  want=$want_status got=$st"
  say "    failing ids  want=[$want]"
  say "                 got =[$got]"
  if [ "$st" = "$want_status" ] && [ "$got" = "$want" ]; then
    verdict 0 "$label"
  else
    echo "  ---- test output ----"
    sed -n '1,200p' "$d/run.log" | sed 's/^/  | /'
    verdict 1 "$label"
  fi
}

# lj52shim.c #includes eris_lj.h, so the sabotaged copies need the serializer
# on the include path.  Same default as build-native.sh; when CANON is being
# run from outside the repo (as during the spike), recover the repo root from
# the last build's log, which records the LuaJIT tree it used.
: "${OCLJ_SER:=$OCLJ_REPO/serializer}"
if [ ! -f "$OCLJ_SER/eris_lj.h" ] && [ -f "$SELF_DIR/../build.log" ]; then
  ljdir=$(sed -n 's|^\[build\] luajit  = \(.*\) @ .*|\1|p' "$SELF_DIR/../build.log" | head -1)
  case $ljdir in
    */prototype/watchdog/luajit) OCLJ_SER=${ljdir%/prototype/watchdog/luajit}/serializer ;;
  esac
fi
[ -f "$OCLJ_SER/eris_lj.h" ] || fail "cannot find eris_lj.h -- set OCLJ_SER=<OC-LuaJIT>/serializer"
say "eris_lj.h from $OCLJ_SER"

# =====================================================================
# 0. the canonical shim -- the positive control.
#    Without this, "the sabotaged build fails" would be consistent with the
#    test failing for a reason that has nothing to do with the sabotage.
# =====================================================================
mkdir -p "$WORK/canon"
cp "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" "$WORK/canon/"
build_variant canon
expect canon "canonical shim passes every check" 0

# =====================================================================
# 1. dropmode -- the rt variant's mode-discarding macro, verbatim.
# =====================================================================
mkdir -p "$WORK/dropmode"
cp "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" "$WORK/dropmode/"
sed -i 's|^#define lua_load(L, r, d, cn, mode) lua_loadx((L), (r), (d), (cn), (mode))$|#define lua_load(L, r, d, cn, mode) lua_load((L), (r), (d), (cn))|' \
  "$WORK/dropmode/lj52shim.h"
grep -q 'lua_load((L), (r), (d), (cn))$' "$WORK/dropmode/lj52shim.h" \
  || fail "dropmode: the sabotage patch did not apply -- the macro in lj52shim.h has been reworded"
build_variant dropmode
# MG1  mode "t" + bytecode is ACCEPTED   -> allowBytecode=false is a lie
# MG3  mode "b" + text     is ACCEPTED   -> the gate is gone in both directions
# MG9  there is no refusal, so no refusal message
# Everything else still passes: the sandbox gate (SB*) is LuaJIT's own
# lib_base.c `load` and is NOT on this path, which is exactly why a
# sandbox-only test would MISS this bug.  Recorded here deliberately.
expect dropmode "mode-dropping shim is caught" 1 MG1 MG3 MG9

# =====================================================================
# 2. sniffer -- the arm6/arm7 byte-sniffing lj52_load, verbatim.
# =====================================================================
mkdir -p "$WORK/sniffer"
cp "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" "$WORK/sniffer/"
sed -i 's|^#define lua_load(L, r, d, cn, mode) lua_loadx((L), (r), (d), (cn), (mode))$|int lj52_load(lua_State *L, lua_Reader reader, void *data, const char *chunkname, const char *mode);\n#define lua_load(L, r, d, cn, mode) lj52_load((L), (r), (d), (cn), (mode))|' \
  "$WORK/sniffer/lj52shim.h"
grep -q 'lj52_load((L), (r), (d), (cn), (mode))$' "$WORK/sniffer/lj52shim.h" \
  || fail "sniffer: the sabotage patch did not apply"
cat >>"$WORK/sniffer/lj52shim.c" <<'SNIFFER'

/* ---- REINTRODUCED DEFECT (negative-control.sh) ----------------------
 * arm6/nat/lj52shim.c's lj52_load, byte for byte.  Do not copy this into
 * anything that ships.  Three defects, all exercised by security_test.c:
 *   - getenv("OCLJ_NOMODECHECK") turns the whole gate off at run time;
 *   - only the b-in-t direction is checked: mode "b" against a TEXT chunk
 *     is waved through, where 5.2 and lua_loadx both refuse;
 *   - the reject path leaks a stack slot.  The wrapping reader returns NULL
 *     on its first call, so lua_load compiles an EMPTY chunk and pushes a
 *     function; the error string then goes ON TOP, leaving +2 where 5.2
 *     leaves +1.
 * ------------------------------------------------------------------- */
#undef lua_load
#include <stdlib.h>
#include <string.h>
typedef struct { lua_Reader r; void *ud; int first; int reject; } ModeReader;
static const char *modereader(lua_State *L, void *ud, size_t *size) {
  ModeReader *m = (ModeReader *)ud;
  const char *s = m->r(L, m->ud, size);
  if (m->first) {
    m->first = 0;
    if (s && *size > 0 && (unsigned char)s[0] == 0x1B) m->reject = 1;
  }
  if (m->reject) { *size = 0; return NULL; }
  return s;
}
int lj52_load(lua_State *L, lua_Reader reader, void *data,
              const char *chunkname, const char *mode) {
  int allow_b = (mode == NULL) || (strchr(mode, 'b') != NULL);
  int status;
  ModeReader m;
  if (getenv("OCLJ_NOMODECHECK")) return lua_load(L, reader, data, chunkname);
  if (allow_b) return lua_load(L, reader, data, chunkname);
  m.r = reader; m.ud = data; m.first = 1; m.reject = 0;
  status = lua_load(L, modereader, &m, chunkname);
  if (m.reject) {
    lua_settop(L, lua_gettop(L));
    lua_pushfstring(L, "attempt to load a binary chunk (mode is '%s')", mode);
    return LUA_ERRSYNTAX;
  }
  return status;
}
SNIFFER
build_variant sniffer
# MG3   mode "b" + TEXT is accepted -- the direction the sniffer never checked
# MG1D  the refusal leaves +2 on the stack instead of +1
unset OCLJ_NOMODECHECK 2>/dev/null || true
expect sniffer "byte-sniffer's unchecked direction and stack leak are caught" 1 MG3 MG1D

# ... and with its own environment bypass set, the gate is simply gone.
say ""
say "--- sniffer, with OCLJ_NOMODECHECK=1 in the environment"
d=$WORK/sniffer
( cd "$d" && OCLJ_NOMODECHECK=1 ./security_test.exe ) >"$d/run-bypass.log" 2>&1
st=$?
got=$(grep '^FAIL ' "$d/run-bypass.log" | awk '{print $2}' | sort | tr '\n' ' ')
want="MG1 MG3 MG9 "
say "    exit status  want=1 got=$st"
say "    failing ids  want=[$want]"
say "                 got =[$got]"
if [ "$st" = 1 ] && [ "$got" = "$want" ]; then
  verdict 0 "env bypass is caught"
else
  sed -n '1,80p' "$d/run-bypass.log" | sed 's/^/  | /'
  verdict 1 "env bypass is caught"
fi

# =====================================================================
# 3. le51 -- lua_compare(LUA_OPLE) the 5.1 way.
# =====================================================================
mkdir -p "$WORK/le51"
cp "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" "$WORK/le51/"
sed -i '/^int lua_compare(lua_State \*L, int idx1, int idx2, int op) {$/{n;s|^  int r;$|  int r;\n  /* REINTRODUCED DEFECT (negative-control.sh): 5.1 spells a <= b as\n   * not (b < a).  On an __le-only metatable this looks up a __lt that is\n   * not there and RAISES. */\n  if (op == LUA_OPLE) return !lua_lessthan(L, idx2, idx1);|}' \
  "$WORK/le51/lj52shim.c"
grep -q 'if (op == LUA_OPLE) return !lua_lessthan(L, idx2, idx1);' "$WORK/le51/lj52shim.c" \
  || fail "le51: the sabotage patch did not apply -- lua_compare has been reshaped"
build_variant le51
# LE1/LE2 raise (no __lt on an __le-only metatable), LE3 answers false where
# 5.2 answers true, LE4 shows __lt fired and __le did not.
expect le51 "5.1 __le semantics are caught" 1 LE1 LE2 LE3 LE4

# =====================================================================
# 4. and the build itself refuses the sabotaged sources.
#    A second, independent tooth.  Even if nobody ever ran the test,
#    build-native.sh's preflight greps lj52shim.{c,h} for the escape hatches
#    and asserts the shape of the lua_load macro, so it will not produce a
#    DLL from these sources at all.
#
#    build-native.sh's preflight validates OCLJ_JNLUA and OCLJ_JNI BEFORE it
#    reaches the gate assertions, so this step needs both.  Without them the
#    build stops on "OCLJ_JNLUA is unset", which proves nothing -- so it is
#    reported as SKIPPED, never as a pass.
# =====================================================================
echo
say "--- build-native.sh must refuse the sabotaged shims"
BN=$SELF_DIR/../build-native.sh
if [ ! -f "$BN" ]; then
  say "    SKIPPED: build-native.sh not found next to tests/"
elif [ -z "${OCLJ_JNLUA:-}" ] || [ ! -d "${OCLJ_JNLUA:-/nonexistent}" ] \
  || [ -z "${OCLJ_JNI:-}" ] || [ ! -f "${OCLJ_JNI:-/nonexistent}/jni.h" ]; then
  say "    SKIPPED: set OCLJ_JNLUA=<OC-JNLua checkout> and OCLJ_JNI=<jdk>/include"
  say "             to also assert that build-native.sh refuses these sources."
else
  for v in dropmode sniffer; do
    out=$(OCLJ_SHIM="$WORK/$v" OCLJ_BUILD="$WORK/$v/bn" \
          OCLJ_JNLUA="$OCLJ_JNLUA" OCLJ_JNI="$OCLJ_JNI" \
          OCLJ_SER="$OCLJ_SER" OCLJ_LUAJIT="${OCLJ_SER%/serializer}/prototype/watchdog/luajit" \
          sh "$BN" 2>&1)
    st=$?
    # It must fail, and it must fail BECAUSE of the gate -- not because some
    # unrelated prerequisite was missing.
    case $out in
      *"lua_load"*|*"escape hatch"*|*"getenv"*) reason=gate ;;
      *)                                        reason=other ;;
    esac
    say "    $v: exit=$st reason=$reason"
    if [ "$st" != 0 ] && [ "$reason" = gate ]; then
      echo "$out" | grep -E '^BUILD FAIL|escape hatch' | sed -n '1,3p' | sed 's/^/      /'
      verdict 0 "build-native.sh refuses '$v'"
    else
      echo "$out" | sed -n '1,20p' | sed 's/^/  | /'
      verdict 1 "build-native.sh refuses '$v'"
    fi
  done
fi

# =====================================================================
echo
if [ "$bad" = 0 ]; then
  echo "NEGATIVE CONTROL: PASS -- security_test.c fails on every reintroduced"
  echo "                  defect, on exactly the checks that name it, and"
  echo "                  passes on the canonical shim."
  exit 0
else
  echo "NEGATIVE CONTROL: FAIL -- see the RESULT lines above."
  echo "                  A security test that does not fail here is not"
  echo "                  evidence of anything."
  exit 1
fi
