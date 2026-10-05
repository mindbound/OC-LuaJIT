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
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
# OCLJ_SHIM is derived from the REPO root, not from $SELF_DIR/../native.
# These tests used to live in tests/ at the top level, where ../native was
# right; after the consolidation moved them to test/native/ the same string
# resolves back to test/native/ and the build fails with
#   fatal error: .../test/native/../native/lj52shim.h: No such file
# -- but only when OCLJ_SHIM is not already set in the environment, which is
# why it survived every run during development.
: "${OCLJ_SHIM:=$OCLJ_REPO/native}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${CC:=gcc}"
# THE SAME PLATFORM FACTS build-native.sh DERIVES (run-mem.sh, run-wd.sh):
# the objects live in per-platform directories.  This script still named
# $OCLJ_BUILD/luajit/src and $OCLJ_BUILD/obj after the per-platform move, so
# it stopped at "run build-native.sh first" against a complete build and ran
# only through a scratch mirror of the old layout (2026-10-03); fixed
# 2026-10-04, before the collector-at-the-wall sabotages joined its memory
# half.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) OCLJ_OS=windows ;;
  Linux)   OCLJ_OS=linux   ;;
  Darwin)  OCLJ_OS=darwin  ;;
  *) echo "NEGATIVE CONTROL SETUP FAIL: unsupported host system $(uname -s)" >&2; exit 2 ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  OCLJ_ARCH=x86_64  ;;
  aarch64|arm64) OCLJ_ARCH=aarch64 ;;
  *) echo "NEGATIVE CONTROL SETUP FAIL: unsupported machine $(uname -m)" >&2; exit 2 ;;
esac
PLATFORM="$OCLJ_OS-$OCLJ_ARCH"
case $OCLJ_OS in
  windows) JNI_MD=win32 ;;
  darwin)  JNI_MD=darwin ;;
  *)       JNI_MD=$OCLJ_OS ;;
esac
: "${OCLJ_JNI:=}"
LJ=$OCLJ_BUILD/luajit-$PLATFORM/src
OBJ=$OCLJ_BUILD/obj-$PLATFORM
WORK=$OCLJ_BUILD/negctl

bad=0
fail()  { echo "NEGATIVE CONTROL SETUP FAIL: $*" >&2; exit 2; }
say()   { echo "[negctl] $*"; }
verdict() {  # verdict <ok?> <text>
  if [ "$1" = 0 ]; then echo "  RESULT: PASS  $2"; else echo "  RESULT: FAIL  $2"; bad=1; fi
}

[ -f "$LJ/libluajit.a" ]           || fail "no $LJ/libluajit.a -- run build-native.sh first"
[ -f "$OBJ/eris_lj.o" ]            || fail "no $OBJ/eris_lj.o -- run build-native.sh first"
[ -n "$OCLJ_JNI" ] && [ -f "$OCLJ_JNI/jni.h" ] || fail "OCLJ_JNI must name a JDK include dir containing jni.h"
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
  "$CC" -c -O2 -I"$LJ" -I"$d" -I"$OCLJ_SER" -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" "$d/lj52shim.c" -o "$d/lj52shim.o" 2>"$d/shim.err" \
    || { sed -n '1,25p' "$d/shim.err"; fail "$v: lj52shim.c did not compile"; }
  "$CC" -O2 -I"$LJ" -I"$d" -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" -include "$d/lj52shim.h" \
    "$SELF_DIR/security_test.c" "$d/lj52shim.o" "$OBJ/eris_lj.o" \
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
# 4. THE MEMORY HALF.  Same discipline, a different test binary: these
#    sabotages are invisible to security_test.c and are caught only by
#    mem_test.c, so they get their own builder and their own expectations.
# =====================================================================
build_variant_mem() {
  v=$1
  d=$WORK/$v
  "$CC" -c -O2 -I"$LJ" -I"$d" -I"$OCLJ_SER" -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" "$d/lj52shim.c" -o "$d/lj52shim.o" 2>"$d/shim.err" \
    || { sed -n '1,25p' "$d/shim.err"; fail "$v: lj52shim.c did not compile"; }
  # MEMTEST_CFLAGS: set for one variant only, when a sabotage makes the W16
  # sweeps cost thousands of cycles a cap (nohyst, unbounded): -DW16_N=8 -DW16R_N=8.
  "$CC" -O2 -I"$LJ" -I"$d" -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" -include "$d/lj52shim.h" \
    ${MEMTEST_CFLAGS:-} "$SELF_DIR/mem_test.c" "$d/lj52shim.o" "$OBJ/eris_lj.o" \
    "$LJ/libluajit.a" -lm -o "$d/mem_test.exe" 2>"$d/test.err" \
    || { sed -n '1,25p' "$d/test.err"; fail "$v: mem_test.c did not link"; }
}

expect_mem() {  # expect_mem <name> <label> <expected status> <expected FAIL ids...>
  v=$1; label=$2; want_status=$3; shift 3
  if [ $# -eq 0 ]; then want=""; else want=$(printf '%s\n' "$@" | sort | tr '\n' ' '); fi
  d=$WORK/$v
  ( cd "$d" && ./mem_test.exe ) >"$d/run.log" 2>&1
  st=$?
  got=$(grep '^  FAIL ' "$d/run.log" | awk '{print $2}' | sort | tr '\n' ' ')
  echo
  say "--- $v : $label"
  say "    exit status  want=$want_status got=$st"
  say "    failing ids  want=[$want]"
  say "                 got =[$got]"
  if [ "$st" = "$want_status" ] && [ "$got" = "$want" ]; then
    verdict 0 "$label"
  else
    echo "  ---- test output ----"; sed -n '1,200p' "$d/run.log" | sed 's/^/  | /'
    verdict 1 "$label"
  fi
}

# The one control that cannot be expressed as a failing check id: the build
# under test does not FAIL, it DIES.  That is the whole claim about the
# pushcfunction window, so it is asserted directly rather than described.
expect_death() {  # expect_death <name> <label>
  v=$1; label=$2
  d=$WORK/$v
  ( cd "$d" && ./mem_test.exe ) >"$d/run.log" 2>&1
  st=$?
  summary=$(grep -c '^checks=' "$d/run.log" || true)
  reached=$(grep -c '^  PASS  M5 ' "$d/run.log" || true)
  echo
  say "--- $v : $label"
  say "    exit status      = $st  (want non-zero)"
  say "    got as far as M5 = $reached  (want 1 -- so we know WHERE it died)"
  say "    reached summary  = $summary  (want 0 -- it must not get that far)"
  # Deliberately NO assertion on lua_atpanic firing.  Measured on Win x64: it
  # does not.  With LJ_UNWIND_EXT the throw becomes a RaiseException nothing
  # catches and the OS terminates the process, so the shim's panic handler --
  # its "at least name it on the way down" -- is never reached.  That is
  # exactly why the JVM death this window prevents had no diagnostic of any
  # kind.  See docs/research/memory-accounting.md.
  if [ "$st" != "0" ] && [ "$summary" = "0" ] && [ "$reached" = "1" ]; then
    verdict 0 "$label"
  else
    echo "  ---- test output ----"; sed -n '1,60p' "$d/run.log" | sed 's/^/  | /'
    verdict 1 "$label"
  fi
}

# --- 4.0 positive control for the memory half ------------------------
mkdir -p "$WORK/memcanon"
cp "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" "$WORK/memcanon/"
build_variant_mem memcanon
expect_mem memcanon "canonical shim passes every memory check" 0

# --- 4.1 stopgap: the shipped-before behaviour, where the allocator swap
#     was discarded and OC's RAM cap was reported but never enforced.
#     The defect shipped as a no-op lua_setallocf MACRO; it is reintroduced
#     here one layer lower, as lj52_setallocf refusing to arm, because that
#     is a single line and behaviourally the same thing -- the state keeps
#     an allocator that charges nobody.  Not a strawman: this is exactly
#     what native/lj52shim.h carried until this change.  Note what still
#     PASSES: the pushes all work.  That is why it went unnoticed for so
#     long, and why M6 asserts both halves rather than just the one.
mkdir -p "$WORK/stopgap"
cp "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" "$WORK/stopgap/"
sed -i 's|^  M->accounting = ud != NULL;$|  M->accounting = 0;  /* sabotage: the swap is discarded */|'   "$WORK/stopgap/lj52shim.c"
grep -q 'sabotage: the swap is discarded' "$WORK/stopgap/lj52shim.c"   || fail "stopgap: the sabotage patch did not apply -- lj52_setallocf has been reworded"
build_variant_mem stopgap
# M3   nothing is charged, so `used` never rises
# M3b  and LuaJIT's own counter says so: we charge 0 where it counted +1.8 MB
# M4   nothing is credited back either
# M4c  same, against the counter, on the way down
# M5   the cap never refuses
# M6b  a RAW push is NOT refused -- which makes M6a vacuous, and saying so is
#      the point of asserting both halves rather than one
# M7   the push is not charged
# P1a, P2a-c, P2e-h  (since the trace flush, 2026-09-22; this list predated
#      them and the script had not run since) no emergency cycle can arm
#      against a cap nobody charges, so nothing downstream of the arm happens
# M3c, M9, C0b, C0d, C3a, C4b, C5a, C5b, C6  (since the accounting's C side,
#      2026-10-03) the native figure and Java's no longer agree, nothing crosses
#      JNI, and in C mode too nothing is refused and no cycle arms
# W1-W15 but W2c  (since the collector at the wall, 2026-10-04) the same: an
#      uncharged state never arms, refuses or lends, so there is no cycle to
#      park, restart or prove and no wall to recover at; W2c's retry succeeds
#      anyway when nothing is ever refused
# C6b W7k W16 W16R W16Rj W17 W19  (THE WINDOW, 2026-10-05) nothing is refused,
#      so no fill stops inside a handler, no window opens, no kernel bound is met;
#      W18 still passes: with nothing refused the kernel is never refused either
expect_mem stopgap "a discarded allocator swap is caught" 1 \
  M3 M3b M3c M4 M4c M5 M6b M7 M9 P1a P2a P2b P2c P2e P2f P2g P2h C0b C0d C3a C4b C5a C5b C6 C6b \
  W1 W1L W1j W2b W2d W3 W4 W5a W5b W5c W7 W7k W8 W10 W11 W11w W11wL W12 W13 W14 W15 \
  W16 W16L W16R W16RL W16Rj W16RjL W17 W19


# --- 4.2 nopending: drop the pre-binding bytes instead of banking them
mkdir -p "$WORK/nopending"
cp "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" "$WORK/nopending/"
# The banking line sits in a block since the accounting's C side (2026-10-03):
# the bank is dropped, the native figure (M->used) on the line after it kept.
sed -i 's|^      M->pending += delta;$|      /* sabotage: the bytes are dropped */|' \
  "$WORK/nopending/lj52shim.c"
grep -q 'sabotage: the bytes are dropped' "$WORK/nopending/lj52shim.c" \
  || fail "nopending: the sabotage patch did not apply"
build_variant_mem nopending
# M4b `used` crosses zero once the pre-binding blocks are freed under a live
#     binding, and M5's cap -- derived from `used`, exactly as OC derives
#     totalMemory from the kernelMemory it measures this way -- then goes
#     negative, which our allocator and jnlua's both read as "unlimited".
# M4b `used` crosses zero once the pre-binding blocks are freed under a live
#     binding.
# M5  and the cap derived from it -- exactly as OC derives totalMemory from the
#     kernelMemory it measures this way -- goes NEGATIVE, which our allocator
#     and jnlua's both read as "unlimited".  The allocation then runs away to a
#     gigabyte.
# M6b still PASSES, and that is worth reading twice: by then `used` is huge and
#     positive again, so the cap taken from it is tight and the raw push really
#     is refused.  A control that expected everything downstream to fail would
#     be asserting noise rather than the defect.
# M7  failed here until 2026-10-04: by M7 the runaway M5 had left about a
#     gigabyte of garbage, and the check measures the push's NET effect on
#     `used`.  The reading then, not verified: a collector step inside the
#     push frees more than the push charges.  Verified since: M6 now collects
#     M5's garbage before it exhausts the cap (a refusal arms the collector,
#     lj52shim.c THE CREDIT), and with nothing left to free M7 passes here.
# M3c, C0b  (since 2026-10-03) the native figure keeps the bytes Java's drops:
#     the two disagree, in the M state and at the C state's handover.
expect_mem nopending "dropping pre-binding bytes is caught" 1 M4b M5 M3c C0b

# --- 4.3 norefuse: remove the pushcfunction window.  MUST DIE. -------
mkdir -p "$WORK/norefuse"
cp "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" "$WORK/norefuse/"
sed -i 's|^  if (M != NULL) M->norefuse++;$|  (void)M;|; s|^  if (M != NULL) M->norefuse--;$||' \
  "$WORK/norefuse/lj52shim.c"
grep -q '^  (void)M;$' "$WORK/norefuse/lj52shim.c" \
  || fail "norefuse: the sabotage patch did not apply"
build_variant_mem norefuse
expect_death norefuse "without the window, a bare-frame push KILLS THE PROCESS"

# --- 4.4 nopark: the collector at the wall's park reset removed (P3,
#     2026-10-04).  An arm that lands in the sweep is honoured only to the
#     end of the old cycle, and the record stays armed with the threshold at
#     2 x estimate: parked.
mkdir -p "$WORK/nopark"
cp "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" "$WORK/nopark/"
sed -i 's|^      if (M->gc_moved \&\& g->gc.state == LJ52_GCS_PAUSE \&\& g->gc.threshold > g->gc.total) {$|      if (0) {  /* sabotage: no park reset */|' \
  "$WORK/nopark/lj52shim.c"
grep -q 'sabotage: no park reset' "$WORK/nopark/lj52shim.c" \
  || fail "nopark: the sabotage patch did not apply -- the park reset has been reworded"
build_variant_mem nopark
# W5a the record stays armed at the pause, threshold twice gc.total
# W5b and the churn after it is refused with no collection at all
expect_mem nopark "a parked collector is caught" 1 W5a W5b

# --- 4.5 freescount: the safety valve counting frees again (P3).  An armed
#     sweep that frees more than LJ52_GC_ARMCAP blocks trips it on its own.
mkdir -p "$WORK/freescount"
cp "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" "$WORK/freescount/"
sed -i 's|^      if (kind != LJ52_GP_FREE \&\& ++M->gc_armedcalls > LJ52_GC_ARMCAP) {$|      if (++M->gc_armedcalls > LJ52_GC_ARMCAP) {  /* sabotage: frees counted */|' \
  "$WORK/freescount/lj52shim.c"
grep -q 'sabotage: frees counted' "$WORK/freescount/lj52shim.c" \
  || fail "freescount: the sabotage patch did not apply -- the valve has been reworded"
build_variant_mem freescount
# W5c 100 000 dead blocks swept by one armed cycle: a bailout, no collect
expect_mem freescount "a valve that counts the sweep's frees is caught" 1 W5c

# --- 4.6-4.12: the collector at the wall's credit and cadence (P1, P2,
#     2026-10-04).  One line each, in lj52shim.c's THE CREDIT / THE CADENCE.
# sabotage_mem <name> <sed expression> <marker the expression leaves>
sabotage_mem() {
  mkdir -p "$WORK/$1"
  cp "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" "$WORK/$1/"
  sed -i "$2" "$WORK/$1/lj52shim.c"
  grep -q "$3" "$WORK/$1/lj52shim.c" || fail "$1: the sabotage patch did not apply -- its line has been reworded"
  build_variant_mem "$1"
}

# 4.6 nocredit: refuse at the cap, as before the change.  Every recovery
# fails (W1 x3, W8), the lent request (W2d), the trace exit's restore (W3),
# the kernel after the sandbox (W10), the reload (W11).
# Since THE WINDOW (2026-10-05): its tops are the credit's, so the W16 family
# and W17 lose them; and the kernel's slice is part of the credit, so W7k, W18
# and W19 (the kernel's room) go with it.
sabotage_mem nocredit 's|^  c = lj52_gc_odmax(total);$|  return 0;  /* sabotage: no credit */|' 'sabotage: no credit'
expect_mem nocredit "refusing at the cap again is caught" 1 W1 W1L W1j W2d W3 W8 W10 W11 W16 W16L W16R W16RL W16Rj W16RjL W17 W18 W19 W7k

# 4.7 norefusedarm: a refusal that does not arm -- the request bigger than
# the headroom, refused with the garbage that would cover it uncollected.
sabotage_mem norefusedarm 's|^  else lj52_gc_arm(M, g, LJ52_ARM_WALL);$|  else (void)0;  /* sabotage: a refusal does not arm */|' 'sabotage: a refusal does not arm'
expect_mem norefusedarm "a refusal that does not arm is caught" 1 W2b W2c

# 4.8 nohyst: re-arm at the watermark after every proven cycle, the old
# cadence: a full cycle per checkpoint pair near the wall (W4), and a fill
# that costs ~1840 cycles a round (W12).
# The W16 family at 8 caps: a cycle per checkpoint makes the full sweeps ~3 min.
MEMTEST_CFLAGS="-DW16_N=8 -DW16R_N=8" sabotage_mem nohyst 's|^  if (!M->gc_hyst) {$|  if (1) {  /* sabotage: no hysteresis */|' 'sabotage: no hysteresis'
expect_mem nohyst "the per-checkpoint re-arm is caught" 1 W4 W12

# 4.9 unbounded: credit = the whole cap.  The bound is what fails: the
# sandbox past cap + G (W7), the cap checks re-scoped to cap + credit (M5,
# C3a), the cases that need a refusal where the credit would have run out
# (W1 x3, W2b, W11), and the fill's cost: the whole cap lent past the cap is
# a band of total bytes to halve through, 2921 cycles a round (W12).
# Since THE WINDOW: the kernel's burst top is past the whole cap (C6b), the
# kernel's bound (W7k) and the live fill's refusal near the top (W17) go too.
# The W16 family at 8 caps: under a credit of the whole cap each sweep cap
# costs thousands of cycles (d2-lend: past 300 s at 96 caps).
MEMTEST_CFLAGS="-DW16_N=8 -DW16R_N=8" sabotage_mem unbounded 's|^  c = lj52_gc_odmax(total);$|  c = total;  /* sabotage: credit = total */|' 'sabotage: credit = total'
expect_mem unbounded "an unbounded credit is caught" 1 C3a C6b M5 W1 W11 W12 W17 W1L W1j W2b W7 W7k

# 4.10 nokslice: the kernel's slice gone; the kernel's table.pack after the
# sandbox spent both tiers is refused.
# Since THE WINDOW: after the sandbox's second refusal the kernel's per-resume
# pack has no room (W16R, W16Rj), the kernel's bound and its room are gone
# (W7k, W19).
sabotage_mem nokslice 's|^  if (lj52_gc_kernel(M, g)) c += LJ52_GC_KSLICE;$|  /* sabotage: no kernel slice */|' 'sabotage: no kernel slice'
expect_mem nokslice "the kernel without its slice is caught" 1 W10 W16 W16L W16R W16RL W16Rj W16RjL W19 W7k

# 4.11 nofresh: a fresh record past total + G/2 takes the burst tier, so the
# first allocation after a reload is refused.
sabotage_mem nofresh 's|^  if (!M->gc_hyst \&\& !M->gc_win \&\& used > total + (lj52_gc_odmax(total) >> 1)) {$|  if (0) {  /* sabotage: no fresh-record reserve */|' 'sabotage: no fresh-record reserve'
expect_mem nofresh "a reload refused for history it never saw is caught" 1 W11

# 4.12 closereserve: every proof closes the reserve tier, the safe-point
# design's rule.  A program that allocates between the catch and the drop
# (W8) is refused again; the reload's derived reserve is lost too (W11).
sabotage_mem closereserve 's|^      if (used <= total) M->gc_odstate = LJ52_OD_BURST;   /\* repaid \*/$|      M->gc_odstate = LJ52_OD_BURST;  /* sabotage: every proof closes the reserve */|' 'sabotage: every proof closes the reserve'
# Since THE WINDOW: the first refusal's room is lost to the next proof, so the
# reserve-tier sweep with the JIT on lands outside (W16Rj), and neither the
# sandbox (W19) nor the kernel (W7k) reaches the reserve top they are checked at.
expect_mem closereserve "a reserve that every proof closes is caught" 1 W8 W11 W16Rj W16RjL W19 W7k

# 4.13 flushwhole: the flush asked for inside the whole watermark again, as
# until stage C.  A machine holding live data with 100 KB free of a 300 KB
# cap -- the shape a 192 KB machine idles in, kernelMemory trace-free --
# throws away its compiled code at every proven cycle (W15).
sabotage_mem flushwhole 's|^#define LJ52_GC_FLUSHSHIFT 1 |#define LJ52_GC_FLUSHSHIFT 0 /* sabotage: the whole watermark */ |' 'sabotage: the whole watermark'
expect_mem flushwhole "a flush asked for at the whole watermark is caught" 1 W15

# --- 4.14-4.21: THE WINDOW (2026-10-05; lj52shim.c THE WINDOW) ---------
# 4.14 nowindow: refuse at the tier's top again, as stage C did: the
# garbage-covered refusals outside the handler come back (W16, W16R, W16Rj),
# a live fill is refused AT the top (W17), and the sandbox no longer reaches
# its ceiling, which W19 asserts before it measures the kernel's room.
sabotage_mem nowindow 's|^  if (used + delta > top + LJ52_GC_LEND) return 0;      /\* the ceiling \*/$|  return 0;  /* sabotage: no window */|' 'sabotage: no window'
expect_mem nowindow "a tier top that lends nothing is caught" 1 W16 W16L W16R W16RL W16Rj W16RjL W17 W19

# 4.15 noceiling: the window lends without a ceiling -- the bound (W7), the
# reload's 32 KB request past the reserve top (W11), the kernel refused for
# the sandbox's lent data (W18) and left no room (W19).
sabotage_mem noceiling 's|^  if (used + delta > top + LJ52_GC_LEND) return 0;      /\* the ceiling \*/$|  /* sabotage: no ceiling */|' 'sabotage: no ceiling'
expect_mem noceiling "a window without a ceiling is caught" 1 W7 W11 W11w W11wL W18 W19

# 4.16 slicewindow: a window as wide as the kernel's slice (what the
# compile-time guard forbids for LJ52_GC_LEND itself): the sandbox's bound
# (W7) and the kernel's room after it (W19).
sabotage_mem slicewindow 's|^  if (used + delta > top + LJ52_GC_LEND) return 0;      /\* the ceiling \*/$|  if (used + delta > top + LJ52_GC_KSLICE) return 0;  /* sabotage: a window as wide as the slice */|' 'sabotage: a window as wide as the slice'
expect_mem slicewindow "a window as wide as the slice is caught" 1 W7 W11w W11wL W19

# 4.17 rawverdict: the verdict on one proof's raw heap, which counts the
# junk the batch's frame still pinned at its last checkpoint.
sabotage_mem rawverdict 's|^        M->gc_win = used <= top ? 0 : used - M->gc_grown > top ? 2 : 1;$|        M->gc_win = used <= top ? 0 : 2;  /* sabotage: the verdict on the raw heap */|' 'sabotage: the verdict on the raw heap'
expect_mem rawverdict "a verdict on one proof is caught" 1 W16 W16L W16R W16RL W16Rj W16RjL

# 4.18 nolook: the proof read one allocator call late: the decision reaches
# the second allocation after the cycle -- event.timer's record (its 64 B
# table, a TDUP) outside the handler.
sabotage_mem nolook 's|^  if (M->gc_armed) lj52_gc_pressure(M, total, used, LJ52_GP_FREE);$|  (void)M; (void)total; (void)used;  /* sabotage: the proof read late */|' 'sabotage: the proof read late'
expect_mem nolook "a proof read late is caught" 1 W16 W16L W16R W16RL

# 4.19 refusalkeeps: a refusal leaves the window's verdict standing, so the
# program's next allocation after a caught refusal is refused before the
# refusal's own cycle can run (W16Rj), and the sandbox never reaches its
# ceiling (W19).
sabotage_mem refusalkeeps 's|^  M->gc_win = 0;                        /\* THE WINDOW: its cycle decides anew \*/$|  /* sabotage: a refusal keeps the window */|' 'sabotage: a refusal keeps the window'
expect_mem refusalkeeps "a refusal that keeps the verdict is caught" 1 W16Rj W16RjL W19

# 4.20 kernelwindow: the kernel lends too -- its burst top is no longer hard
# (C6b) and its bound moves past cap + G + the slice (W7k).
sabotage_mem kernelwindow 's|^  if ((g->hookmask \& HOOK_GC) \|\| g->gc\.threshold == LJ_MAX_MEM \|\| lj52_gc_kernel(M, g))$|  if ((g->hookmask \& HOOK_GC) \|\| g->gc.threshold == LJ_MAX_MEM)  /* sabotage: the kernel lends too */|' 'sabotage: the kernel lends too'
expect_mem kernelwindow "a kernel window is caught" 1 C6b W7k

# 4.21 noarm: nothing arms the window's cycle -- neither its own arm nor THE
# CADENCE past the top (each alone is enough; measured: either removed alone
# fails nothing) -- so a live fill runs on to the window's ceiling (W17).
sabotage_mem noarm 's|^  if (!M->gc_armed) lj52_gc_arm(M, g, LJ52_ARM_WALL);   /\* the window.s cycle \*/$|  /* sabotage: the window arms nothing */|; s|^    arm = top - used < (top - M->gc_low) >> 1;$|    arm = used <= top \&\& top - used < (top - M->gc_low) >> 1;  /* sabotage: nor the cadence past the top */|' 'sabotage: nor the cadence past the top'
expect_mem noarm "a window whose cycle nothing arms is caught" 1 W17

# 4.22 nolegacywindow: THE WINDOW in C mode only -- the legacy (dropin)
# path, the dropin's for ever and every state's before the handover, refuses
# at the tier's top again, as stage C did.  (The code review, 2026-10-05:
# before the W16 family ran on the legacy path, this passed 76/76.)
sabotage_mem nolegacywindow 's#^        || lj52_gc_lend(M, total, used, delta))) {$#        || 0)) {  /* sabotage: no window on the legacy path */#' 'sabotage: no window on the legacy path'
expect_mem nolegacywindow "the legacy path without the window is caught" 1 W16L W16RL W16RjL

# 4.23 noverdict: no verdict -- every crossing that fits under the window's
# ceiling is lent, so live data is refused only at the ceiling.
sabotage_mem noverdict 's#^  if (M->gc_win == 2 \&\& M->gc_low > top) return 0;      /\* the verdict \*/$#  /* sabotage: no verdict */#' 'sabotage: no verdict'
expect_mem noverdict "a window with no verdict is caught" 1 W17

# 4.24 nogrownreset: the bytes granted since the last proof are never reset,
# so the two-cycle test subtracts every growth ever granted and never finds
# data that survived two cycles: no verdict either.
sabotage_mem nogrownreset 's#^      M->gc_grown = 0;$#      /* sabotage: grown never reset */#' 'sabotage: grown never reset'
expect_mem nogrownreset "a growth count never reset is caught" 1 W17

# =====================================================================
# 6. THE WATCHDOG.  Two sabotages, each the design's own "before" picture:
#    one keeps OC's standing hook (the JIT thrashes), one removes the async
#    injection (the deadline is never enforced).  wd_test.c carries a 10 s
#    process alarm precisely so the second one terminates.
# =====================================================================
build_variant_wd() {
  v=$1
  d=$WORK/$v
  "$CC" -c -O2 -I"$LJ" -I"$d" -I"$OCLJ_SER" -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" "$d/lj52shim.c" -o "$d/lj52shim.o" 2>"$d/shim.err" \
    || { sed -n '1,25p' "$d/shim.err"; fail "$v: lj52shim.c did not compile"; }
  "$CC" -O2 -I"$LJ" -I"$d" -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" -include "$d/lj52shim.h" \
    "$SELF_DIR/wd_test.c" "$d/lj52shim.o" "$OBJ/eris_lj.o" \
    "$LJ/libluajit.a" -lm -o "$d/wd_test.exe" 2>"$d/test.err" \
    || { sed -n '1,25p' "$d/test.err"; fail "$v: wd_test.c did not link"; }
}

expect_wd() {  # expect_wd <name> <label> <expected status> <expected FAIL ids...>
  v=$1; label=$2; want_status=$3; shift 3
  if [ $# -eq 0 ]; then want=""; else want=$(printf '%s\n' "$@" | sort | tr '\n' ' '); fi
  d=$WORK/$v
  ( cd "$d" && ./wd_test.exe ) >"$d/run.log" 2>&1
  st=$?
  got=$(grep '^  FAIL ' "$d/run.log" | awk '{print $2}' | sort | tr '\n' ' ')
  echo
  say "--- $v : $label"
  say "    exit status  want=$want_status got=$st"
  say "    failing ids  want=[$want]"
  say "                 got =[$got]"
  if [ "$st" = "$want_status" ] && [ "$got" = "$want" ]; then
    verdict 0 "$label"
  else
    echo "  ---- test output ----"; sed -n '1,200p' "$d/run.log" | sed 's/^/  | /'
    verdict 1 "$label"
  fi
}

expect_wd_alarm() {  # expect_wd_alarm <name> <label> -- the test's own alarm must end it
  v=$1; label=$2
  d=$WORK/$v
  ( cd "$d" && ./wd_test.exe ) >"$d/run.log" 2>&1
  st=$?
  summary=$(grep -c '^checks=' "$d/run.log" || true)
  alarm=$(grep -c '^  ALARM ' "$d/run.log" || true)
  reached=$(grep -c '^  PASS  W1 ' "$d/run.log" || true)
  echo
  say "--- $v : $label"
  say "    exit status      = $st  (want 99, the alarm's code)"
  say "    got as far as W1 = $reached  (want 1)"
  say "    ALARM line       = $alarm  (want 1)"
  say "    reached summary  = $summary  (want 0)"
  if [ "$st" = "99" ] && [ "$alarm" = "1" ] && [ "$summary" = "0" ] && [ "$reached" = "1" ]; then
    verdict 0 "$label"
  else
    echo "  ---- test output ----"; sed -n '1,60p' "$d/run.log" | sed 's/^/  | /'
    verdict 1 "$label"
  fi
}

# --- 6.0 positive control ---------------------------------------------
mkdir -p "$WORK/wdcanon"
cp "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" "$WORK/wdcanon/"
build_variant_wd wdcanon
expect_wd wdcanon "canonical shim passes every watchdog check" 0

# --- 6.1 standinghook: arm() ALSO installs OC's standing count hook -------
# This is the "before" this whole change exists to remove.  The deadline still
# fires (the standing hook sees to that) and disarm still clears it, so every
# check passes EXCEPT two: W6b, because the hot loop thrashes -- hundreds of
# traces, hundreds of ms -- exactly as measured in a real machine with OC's
# stock kernel; and W8c, because the outermost arm's promise is "no hook is
# set when a resume starts" and a standing hook is, by construction, a hook
# that is set; and W12, because the standing hook the sabotage installs is
# exactly the immediate hook W12 says a huge timeout must NOT produce.  And
# W10g (added to wd_test after this script last ran; found when it was revived
# on 2026-10-04, and failing the same way on that day's HEAD shim): the
# standing hook keeps calling the parent's deadline callback -- thousands of
# calls -- where the normal path promises the parent's callback is never
# called.  All four are the sabotage doing what it says, nothing else.
mkdir -p "$WORK/standinghook"
cp "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" "$WORK/standinghook/"
sed -i 's|^  M->wd_stack\[M->wd_depth\] = lj52_wd_now() + secs \* 1000.0;$|&\n  lua_sethook(M->L, lj52_wd_hook, LUA_MASKCOUNT, 1000); /* sabotage: OC standing hook */|' \
  "$WORK/standinghook/lj52shim.c"
grep -q 'sabotage: OC standing hook' "$WORK/standinghook/lj52shim.c" \
  || fail "standinghook: the sabotage patch did not apply -- lj52_wd_arm has been reworded"
build_variant_wd standinghook
expect_wd standinghook "a standing hook is caught by W6b, W8c, W10g and W12" 1 W6b W8c W10g W12

# --- 6.2 notimer: the timer callback never installs the hook -------------
# Remove the asynchronous injection and nothing ever interrupts
# `while true do end`: the deadline is simply not enforced.  The only thing
# that ends W2 is wd_test's own 10 s alarm, and that is what is asserted.
mkdir -p "$WORK/notimer"
cp "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" "$WORK/notimer/"
sed -i 's|^  (void)timedOut;$|  (void)timedOut; (void)M; return; /* sabotage: the timer never hooks */|' \
  "$WORK/notimer/lj52shim.c"
grep -q 'sabotage: the timer never hooks' "$WORK/notimer/lj52shim.c" \
  || fail "notimer: the sabotage patch did not apply -- lj52_wd_fire has been reworded"
build_variant_wd notimer
expect_wd_alarm notimer "without the async injection, the deadline is NEVER enforced (the test's alarm ends it)"

# =====================================================================
# 5. and the build itself refuses the sabotaged sources.
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
# The consolidation moved these apart: the tests live in test/native/ and the
# build script in native/.  Keep the old location as a fallback so a checkout
# that still has them side by side is not silently SKIPPED -- a skipped gate
# reads like a passing one in a log.
BN=$OCLJ_REPO/native/build-native.sh
[ -f "$BN" ] || BN=$SELF_DIR/../build-native.sh
if [ ! -f "$BN" ]; then
  say "    SKIPPED: no build-native.sh at $OCLJ_REPO/native/ or beside this script"
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
