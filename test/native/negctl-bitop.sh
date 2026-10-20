#!/bin/sh
# =====================================================================
# negctl-bitop.sh -- PROVE that round 3's tests of the 64-bit bitwise
# operators have teeth: run-bitop.sh, run-bitjit.sh, run-bitfuzz.sh,
# run-security.sh's FF12, and build-native.sh's bitops gate and stage-4
# VM-features word check.
#
#   OCLJ_BUILD=<build dir used by build-native.sh>  sh test/native/negctl-bitop.sh
#
# Requires build-native.sh to have run first, on THIS platform (x86_64: the
# interpreter is patched in vm_x64.dasc only), a built PUC Lua 5.3.6
# (OCLJ_LUA53: run-bitfuzz.sh's reference and the PUC twins) and a JDK's
# include directory (OCLJ_JNI, which run-bitop.sh and run-security.sh need).
# It copies the build's LuaJIT tree and objects into a fresh work directory
# ($OCLJ_BUILD/negctl-bitop/<stamp>-<pid>; nothing else is written), after
# checking that the copy holds what the repo ships: native/luajit's five
# round-3 files byte for byte, each of the seven patched LuaJIT files equal to
# what its patch-bitop-*.sh makes of the pristine file, and an eris_lj.o that
# carries the hash of OCLJ_SER's eris_lj.[ch].  The pristine files are the
# ones the build compiled: $OCLJ_BUILD/luajit-export-<platform>/src, the pin's
# export, when it exists (the last build was pinned, and build-native.sh
# checked it against the pin), and OCLJ_LUAJIT's src otherwise (an unpinned
# build removes the export and copies that working tree); the run says
# which.  Until 2026-10-20 it was always OCLJ_LUAJIT's working tree, so one
# uncommitted line there failed the setup with "rebuild with
# build-native.sh", which a pinned rebuild could not cure.  The seventh,
# lib_jit.c (patch-bitop-jitlib.sh: jit.util's words unsigned for LuaJIT's
# own tools), changes no operator and has no arm here: its catcher is
# build-native.sh's jit tools gate, which this script does not run; it is
# reproduced, put back and rebuilt (lib_jit.o) like the others.
# Then, one arm at a time, it changes ONE line of one of the other eleven
# files, or of serializer/eris_lj.c, at the fix's own site -- anchored, asserted to
# occur exactly once, and asserted to leave every other line as it was --
# rebuilds only the objects that file reaches (a vm_x64.dasc arm through
# DynASM and buildvm: `make` regenerates host/buildvm_arch.h), relinks
# luajit.exe, and runs the arm's catchers:
#
#   canon       nothing changed, every round-3 object rebuilt: every catcher
#               must PASS (the positive control)
#   each other  must be CAUGHT by EVERY catcher listed for it
#
# THE BUILD IS FINGERPRINTED.  After each build every object (src/*.o and
# src/host/*.o) is compared with the shipped build's.  The objects the arm's
# file reaches must not all be unchanged (the sabotage reached the code), and
# every other object must be byte-identical (the previous arm's file was put
# back, and nothing else changed); canon must reproduce every object exactly,
# and after the last arm every file is put back and the same is required
# again.  A vm_x64.dasc arm's line must also appear in host/buildvm_arch.h,
# where DynASM echoes each line of the .dasc it assembled.  An arm that fails
# any of this is BROKEN, which fails the run: it proves nothing either way.
#
# THE CATCHERS (an arm lists them as suite or suite:check; the check must
# fail):
#   bitop:t_ops, :t_fold, :t_sar   run-bitop.sh's matrix: that script's FAIL
#                 line, JIT on or -joff (t_fold is the literal operands, "K")
#   bitop:coerce  run-bitop.sh's coerce_agree.lua on luajit.exe
#   bitop:t_ops-str  a t_ops case with a string operand differs from
#                 t_ops.expect (strings reach only the slow path)
#   fuzz:K, :V, :U   run-bitfuzz.sh (seed 1, NEGCTL_FUZZ_CASES cases), and
#                 MISMATCHes in that mode: K literals (the parser's folding), V
#                 arguments (the interpreter), U literals stored inside a hot
#                 loop (the JIT's fold engine); bare fuzz: any MISMATCH
#   gen           run-bitjit.sh's generator (seeds 1..NEGCTL_GEN_SEEDS of 2000
#                 loops): a seed FAILs
#   floor:t_rec, :t_rec-counts, :t_jit2, :t_jit2/<loop>   run-bitjit.sh's
#                 floor: t_rec in any seed, in its counts seeds (3 and 4),
#                 t_jit2 against -joff, and that one t_jit2 loop's line
#   fix1          run-bitjit.sh's p4 check
#   security:FF12 run-security.sh's FF12 (a version-2 dump is refused)
#   gate:dump     build-native.sh's bitops gate, its own text, run on the arm's
#                 luajit.exe: the line differs from build-native.sh's wanted
#                 line in its dump field
#   stage4        build-native.sh's stage-4 word check, its own text (from
#                 OBS= to the line that reports the word), on eris_lj.c
#                 compiled as build-native.sh compiles it
#
# THE ARMS (round 3's list, decided 2026-10-17; the catchers in brackets):
#   from the first design:
#     WRAP32-INTERP   vm_x64.dasc        [bitop:t_ops fuzz:V]
#     WRAP32-FOLD     lj_parse.c         [bitop:t_fold fuzz:K]
#     SHIFTMASK       vm_x64.dasc        [bitop:t_ops fuzz]
#     NEGSHIFT        oclj_bitop.h       [bitop:t_ops]
#     SARSHR          oclj_bitop.h       [bitop:t_sar]
#     NOINT-FOLD      lj_parse.c         [bitop:t_fold]
#     NOINT-JIT       oclj_bitop_rec.c   [floor:t_jit2/guard-exit]
#     RANGE-HI        oclj_num53.h       [bitop:t_ops fuzz]
#     STRCOERCE       oclj_bitop_meta.c  [bitop:t_ops bitop:coerce]
#     ERROPERAND      oclj_bitop_meta.c  [bitop:t_ops]
#     NARROW          lj_opt_fold.c      [floor:t_rec floor:t_jit2]
#     KFOLD64         lj_opt_fold.c      [fuzz:U floor:t_rec]
#     SARCONST        oclj_bitop_rec.c   [floor:t_rec-counts bitop:t_sar]
#     BCDUMP          lj_bcdump.h        [security:FF12 gate:dump]
#     WORDTOKEN       eris_lj.c          [stage4]
#   new for U1-B (a result of more than 53 significant bits raises):
#     INEXACT-INTERP  vm_x64.dasc        [bitop:t_ops fuzz:V]
#     INEXACT-BNOT    vm_x64.dasc        [bitop:t_ops bitop:t_fold fuzz:V]
#     INEXACT-SLOW    oclj_bitop_meta.c  [bitop:t_ops-str]
#     INEXACT-FOLD    lj_parse.c         [bitop:t_fold fuzz:K]
#     INEXACT-JIT     oclj_bitop_rec.c   [gen]
#     SELFGUARD       lj_opt_fold.c      [gen]
#   the width rule's, from its review, and fix1:
#     WIDTH55         lj_opt_fold.c      [gen]
#     WSHR, WBAND, WADD0, WSHL0   oclj_bitop_fold.c   [gen]
#     FIX1            lj_opt_fold.c      [fix1]
# Each arm's line, below, says what it breaks.  Not arms: the first design's
# ROUNDTRUNC and TIESAWAY (nothing rounds under U1-B), and INEXACT-RECABORT,
# the recorder's record-time abort of an inexact result removed (either of
# its two lines, oclj_bitop_rec.c): run against every catcher above, it is
# caught by none, and none can see it.  The interpreter executes the
# instruction just recorded and raises; lj_err_throw stops the recording
# (lj_err.c:771, lj_trace.h:45), which is then aborted as LJ_TRERR_RECERR
# (lj_trace.c:751-752) and penalised as the BADTYPE abort is
# (lj_trace.c:604-611).  Measured 2026-10-17 on a hot pcall loop whose >> and
# ~ always raise: the same raises, 26 trace starts and 26 aborts on both
# builds; only the abort's reason differs, and no test reads it.
#
# THE MARGINS, measured 2026-10-17 in three runs of every arm on round 3's
# build (the JIT catchers vary from run to run: LuaJIT randomises its hot
# counters).  gen, the fewest differing cases in a seed (every seed differed
# in every run): WBAND 11, WADD0 11, WSHL0 24, WSHR 70, WIDTH55 168,
# INEXACT-JIT 511, SELFGUARD 516.  NARROW: t_rec 27-55 lines a seed, every
# seed and option set; t_jit2 under 4 of its 6 option sets.  KFOLD64: t_rec
# 4-14 a seed, fuzz U 431-436.  SARCONST: t_rec 6 lines in each counts seed.
# NOINT-JIT: guard-exit under all 6.  INEXACT-SLOW fails every inexact case of the matrix (550 in
# t_ops), string or not, because the fast path leaves an inexact result to the
# slow path to raise; its check asks for a string case among them.
# INEXACT-BNOT (BC_BNOT's own result check, which INEXACT-INTERP's ins_bitop
# site does not reach; review of 2026-10-17), measured twice, by hand on a
# one-line copy of round 3's build and by this script (canon and that arm),
# with the same counts (it changes lj_vm.o and host/buildvm.o): t_ops 7
# lines (the six inexact ~u cases and a naming case), t_fold 2, fuzz 1323
# tuples in each of K, V, P and H and 246 in U, JIT on and -joff alike.  A full run
# took 7.6 minutes, 5.1 of them in canon and the seven gen arms; a rebuild
# takes 1-3 s, a vm_x64.dasc one included.  It leaves about 445 MB in its
# work directory, most of it the generator's loops (about 40 MB a gen run:
# 38.6-41.2 MB measured in the 2026-10-17 runs, 41.6 MB with the hint), and
# deletes nothing.
#
# Every sabotage is memory-safe by construction: each computes a different
# value, raises a different message or none, writes a different version
# byte or word token, or (FIX1) only blacklists loops.  None touches a bound
# that guards a read or a write.  The JIT arms change int64 IR whose results
# become doubles; a table index made from one is still converted by a checked
# IRCONV_INDEX conversion and bounds-checked (lj_record.c:2046), since no fold
# removes that conversion from an int64 source (simplify_conv_int_num,
# lj_opt_fold.c:1128-1136).  NOINT-JIT's unguarded conversion is cvttsd2si,
# which yields INT64_MIN for what it cannot convert.
#
# OCLJ_NEGCTL_ARMS (default empty: every arm) runs only the arms it names,
# separated by spaces or commas; canon always runs.  A name that is no arm is
# a setup failure (exit 2).  A selected run proves only the arms it ran, and
# its last line says so.  NEGCTL_GEN_SEEDS (default 4, run-bitjit.sh's own
# default) and NEGCTL_FUZZ_CASES (default 1000, run-bitfuzz.sh's) size the
# generator and the fuzzer; every other knob of the three runners is pinned
# here, so a run does not depend on the caller's environment.
#
# Exit 0 iff canon passes, every selected arm is caught, and the tree comes
# back byte-identical; 1 otherwise; 2 if the control could not be set up.
# =====================================================================
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${OCLJ_LUAJIT:=$OCLJ_REPO/prototype/watchdog/luajit}"
: "${OCLJ_SER:=$OCLJ_REPO/serializer}"
: "${OCLJ_LUA53:=$OCLJ_REPO/bench/vendor/lua-5.3.6/src/lua.exe}"
: "${OCLJ_JNI:=}"
: "${CC:=gcc}"
: "${NEGCTL_GEN_SEEDS:=4}"
: "${NEGCTL_FUZZ_CASES:=1000}"
: "${OCLJ_NEGCTL_ARMS:=}"
: "${JOBS:=4}"

fail() { echo "NEGCTL-BITOP SETUP FAIL: $*" >&2; exit 2; }

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) OCLJ_OS=windows ; PICFLAG= ; EXE=.exe ;;
  Linux)   OCLJ_OS=linux  ; PICFLAG=-fPIC ; EXE= ;;
  Darwin)  OCLJ_OS=darwin ; PICFLAG=-fPIC ; EXE= ;;
  *) fail "unsupported host system $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  OCLJ_ARCH=x86_64  ;;
  *) fail "unsupported machine $(uname -m): round 3's interpreter is patched in vm_x64.dasc only" ;;
esac
PLATFORM="$OCLJ_OS-$OCLJ_ARCH"
SRCTREE=$OCLJ_BUILD/luajit-$PLATFORM
SRCOBJ=$OCLJ_BUILD/obj-$PLATFORM
# THE PRISTINE FILES are the ones the build compiled (the header).
if [ -d "$OCLJ_BUILD/luajit-export-$PLATFORM/src" ]; then
  PRISTINE=$OCLJ_BUILD/luajit-export-$PLATFORM
  PRISTINE_WHAT="the pin's export, which the last build (pinned) compiled"
else
  PRISTINE=$OCLJ_LUAJIT
  PRISTINE_WHAT="OCLJ_LUAJIT's working tree: no export in $OCLJ_BUILD, so the last build was unpinned"
fi
BN=$OCLJ_REPO/native/build-native.sh
# The files the copy is checked against and an arm may change: native/luajit's
# five (copied into the build copy as they are), the seven that
# patch-bitop-<x>.sh patches (lib_jit.c, the seventh, has no arm), and the
# serializer's eris_lj.c (compiled here for stage 4 only).
NATIVE_FILES='oclj_bitop.h oclj_bitop_meta.c oclj_bitop_rec.c oclj_bitop_fold.c oclj_num53.h'
PATCHED='lj_parse.c:parse vm_x64.dasc:vm lj_meta.c:meta lj_record.c:record lj_opt_fold.c:fold lj_bcdump.h:bcdump lib_jit.c:jitlib'
ALLFILES="$NATIVE_FILES lj_parse.c vm_x64.dasc lj_meta.c lj_record.c lj_opt_fold.c lj_bcdump.h lib_jit.c eris_lj.c"

[ -f "$SRCTREE/src/libluajit.a" ] && [ -x "$SRCTREE/src/luajit$EXE" ] \
  || fail "no $SRCTREE/src/libluajit.a or luajit$EXE -- run build-native.sh first (on THIS platform)"
[ -f "$SRCOBJ/lj52shim.o" ] && [ -f "$SRCOBJ/eris_lj.o" ] || fail "no $SRCOBJ/lj52shim.o or eris_lj.o -- run build-native.sh first"
for f in run-bitop.sh run-bitjit.sh run-bitfuzz.sh run-security.sh bitop/t_ops.expect; do
  [ -f "$SELF_DIR/$f" ] || fail "no $SELF_DIR/$f"
done
[ -f "$BN" ] || fail "no $BN (the bitops gate and stage 4 are read from it)"
[ -f "$OCLJ_SER/eris_lj.c" ] && [ -f "$OCLJ_SER/eris_lj.h" ] || fail "no $OCLJ_SER/eris_lj.c or eris_lj.h (set OCLJ_SER)"
for f in $NATIVE_FILES; do
  [ -f "$OCLJ_REPO/native/luajit/$f" ] || fail "no $OCLJ_REPO/native/luajit/$f"
done
for p in $PATCHED; do
  [ -f "$PRISTINE/src/${p%%:*}" ] || fail "no $PRISTINE/src/${p%%:*} (the pristine file: $PRISTINE_WHAT; set OCLJ_LUAJIT, or rebuild)"
done
echo "[negctl-bitop] pristine files from $PRISTINE/src ($PRISTINE_WHAT)"
command -v make >/dev/null 2>&1 || fail "no make on PATH"
command -v "$CC" >/dev/null 2>&1 || fail "no $CC on PATH"
[ -x "$OCLJ_LUA53" ] || OCLJ_LUA53=${OCLJ_LUA53%.exe}
case "$("$OCLJ_LUA53" -v 2>&1)" in
  "Lua 5.3.6"*) ;;
  *) fail "no PUC Lua 5.3.6 at $OCLJ_LUA53 (run-bitfuzz.sh's reference; build bench/vendor/lua-5.3.6 or set OCLJ_LUA53)" ;;
esac
if [ -z "$OCLJ_JNI" ]; then
  for c in "${JAVA_HOME:-}/include" /usr/lib/jvm/*/include /c/Program\ Files/Java/*/include; do
    [ -f "$c/jni.h" ] && OCLJ_JNI="$c" && break
  done
fi
[ -n "$OCLJ_JNI" ] && [ -f "$OCLJ_JNI/jni.h" ] || fail "OCLJ_JNI must name a JDK include dir containing jni.h
       (run-bitop.sh's bitop_test.c and run-security.sh force-include lj52shim.h, which includes <jni.h>)"
for v in "$NEGCTL_GEN_SEEDS" "$NEGCTL_FUZZ_CASES"; do
  case "$v" in *[!0-9]*|'') fail "NEGCTL_GEN_SEEDS and NEGCTL_FUZZ_CASES must be whole numbers" ;; esac
done
# The runners refuse 0 too; refused here, before anything is copied.
[ "$NEGCTL_GEN_SEEDS" -gt 0 ] && [ "$NEGCTL_FUZZ_CASES" -gt 0 ] \
  || fail "NEGCTL_GEN_SEEDS and NEGCTL_FUZZ_CASES must be at least 1 (0 would size a catcher to nothing)"
# build-native.sh's serializer hash (stage 4 finds the word after it).
serhash() {
  if command -v sha1sum >/dev/null 2>&1; then cat "$@" | sha1sum | cut -c1-8
  elif command -v md5sum >/dev/null 2>&1; then cat "$@" | md5sum | cut -c1-8
  else cat "$@" | cksum | cut -d" " -f1; fi
}

# --- the arms' machinery ---------------------------------------------------
# fileof <file>: where the work tree holds it.
fileof() { case $1 in eris_lj.c) echo "$WORK/ser/$1" ;; *) echo "$W/$1" ;; esac; }
# objs_of <file>: the objects it reaches -- deleted before make, and the only
# ones its arm may change.  native/luajit's files are #included by the build
# copy's lj_*.c (and oclj_num53.h by lib_string.c), which LuaJIT's
# Makefile.dep does not know, so the objects are named here.  vm_x64.dasc
# reaches lj_bc.o too: buildvm writes each bytecode's offset into the
# interpreter to lj_bcdef.h (lj_bc_ofs, host/buildvm.c), and an instruction
# of another length moves them (2026-10-17: WRAP32-INTERP's 32-bit `and` has
# no REX.W prefix).
objs_of() {
  case $1 in
    vm_x64.dasc) echo "lj_vm.o lj_bc.o host/buildvm.o" ;;
    lj_parse.c) echo "lj_parse.o" ;;
    lj_meta.c|oclj_bitop_meta.c) echo "lj_meta.o" ;;
    lj_record.c|oclj_bitop_rec.c) echo "lj_record.o" ;;
    lj_opt_fold.c|oclj_bitop_fold.c) echo "lj_opt_fold.o" ;;
    oclj_bitop.h) echo "lj_parse.o lj_meta.o lj_record.o lj_opt_fold.o" ;;
    oclj_num53.h) echo "lj_parse.o lj_meta.o lj_record.o lj_opt_fold.o lib_string.o" ;;
    lj_bcdump.h) echo "lib_string.o lj_bcread.o lj_bcwrite.o lj_lib.o lj_load.o" ;;
    lib_jit.c) echo "lib_jit.o" ;;
    *) echo "" ;;
  esac
}
# dirty <file>: its objects are rebuilt by the next make; a vm_x64.dasc is
# reassembled (host/buildvm_arch.h deleted: make regenerates it with DynASM).
dirty() {
  DIRTY="$DIRTY $(objs_of "$1")"
  [ "$1" = vm_x64.dasc ] && rm -f "$W/host/buildvm_arch.h"
  return 0
}
# restore: every file back to its canonical copy (a fresh mtime) and dirty.
restore() {
  for f in $ALLFILES; do
    t=$(fileof "$f")
    cmp -s "$WORK/canon/$f" "$t" && continue
    cp -f "$WORK/canon/$f" "$t" || fail "cannot put $t back"
    dirty "$f"
  done
}
rebuild() {  # rebuild <log>: the dirty objects, the archive and luajit.exe
  for o in $DIRTY; do rm -f "$W/$o"; done
  make -C "$W" BUILDMODE=static XCFLAGS="$PICFLAG" Q= -j"$JOBS" > "$1" 2>&1
}
objmd5() { ( cd "$W" && md5sum *.o host/*.o ) | tr -d '*'; }
# objcheck <dir> <allowed objects>: CHANGED, the objects that differ from the
# shipped build's; STRAY, those of them not allowed.
objcheck() {
  objmd5 > "$1/obj.md5"
  CHANGED=$(awk 'NR == FNR { m[$2] = $1; next }
    { s[$2] = 1; if (m[$2] != $1) print $2 }
    END { for (k in m) if (!(k in s)) print k "(missing)" }' "$WORK/canon-obj.md5" "$1/obj.md5" | tr '\n' ' ')
  CHANGED=${CHANGED% }
  STRAY=
  for o in $CHANGED; do
    case " $2 " in *" $o "*) ;; *) STRAY="$STRAY $o" ;; esac
  done
}
# sabotage <canonical> <old> <new> <out>: <old> is one line, or consecutive
# lines, of <canonical>, which must occur exactly once; it is replaced by
# <new>.  @T@ stands for a tab in both.  ENVIRON, so no awk escape processing.
sabotage() {
  OLD=$2 NEW=$3 awk '
    BEGIN {
      NL = sprintf("%c", 10); TAB = sprintf("%c", 9)
      no = split(ENVIRON["OLD"], O, NL); nn = split(ENVIRON["NEW"], N, NL)
      for (k = 1; k <= no; k++) gsub(/@T@/, TAB, O[k])
      for (k = 1; k <= nn; k++) gsub(/@T@/, TAB, N[k])
    }
    { L[++nl] = $0 }
    END {
      c = 0
      for (i = 1; i + no - 1 <= nl; i++) {
        for (j = 1; j <= no; j++) if (L[i + j - 1] != O[j]) break
        if (j > no) { c++; at = i }
      }
      if (no < 1 || c != 1) exit 1
      for (i = 1; i < at; i++) print L[i]
      for (k = 1; k <= nn; k++) print N[k]
      for (i = at + no; i <= nl; i++) print L[i]
    }' "$1" > "$4"
}

# --- the catchers -----------------------------------------------------------
run_bitop() {
  OCLJ_BUILD=$WB OCLJ_REPO=$OCLJ_REPO OCLJ_JNI=$OCLJ_JNI OCLJ_LUA53=$OCLJ_LUA53 CC=$CC \
    OCLJ_BITOP_OUT=$1/bitop sh "$SELF_DIR/run-bitop.sh" > "$1/bitop.log" 2>&1
}
run_fuzz() {
  OCLJ_BUILD=$WB OCLJ_REPO=$OCLJ_REPO OCLJ_LUA53=$OCLJ_LUA53 OCLJ_BITFUZZ_SEED=1 OCLJ_BITFUZZ_SEEDS=1 \
    OCLJ_BITFUZZ_CASES=$NEGCTL_FUZZ_CASES OCLJ_BITFUZZ_TUPLES=16 OCLJ_BITFUZZ_HOTMIN=0.25 \
    OCLJ_BITFUZZ_STRICT=0 OCLJ_BITFUZZ_PRUNE=0 OCLJ_BITFUZZ_OUT=$1/fuzz \
    sh "$SELF_DIR/run-bitfuzz.sh" > "$1/fuzz.log" 2>&1
}
run_bitjit() {  # run_bitjit <dir> <parts>
  OCLJ_BUILD=$WB OCLJ_REPO=$OCLJ_REPO OCLJ_LUA53=$OCLJ_LUA53 OCLJ_BITJIT_PARTS=$2 \
    OCLJ_BITJIT_SEED=1 OCLJ_BITJIT_SEEDS=$NEGCTL_GEN_SEEDS OCLJ_BITJIT_CASES=2000 OCLJ_BITJIT_GENMODE= \
    OCLJ_BITJIT_HOTMIN=0.25 OCLJ_BITJIT_OUT=$1/bitjit sh "$SELF_DIR/run-bitjit.sh" > "$1/bitjit.log" 2>&1
}
run_security() {
  OCLJ_BUILD=$WB OCLJ_REPO=$OCLJ_REPO OCLJ_JNI=$OCLJ_JNI CC=$CC \
    sh "$SELF_DIR/run-security.sh" > "$1/security.log" 2>&1
}
run_gate() {  # build-native.sh's bitops gate: 0 if the line is the wanted one
  "$W/luajit$EXE" "$WORK/bitops.lua" > "$1/gate.raw" 2>&1
  tr -d '\r' < "$1/gate.raw" > "$1/gate.txt"
  [ "$(cat "$1/gate.txt")" = "$BO_WANT" ]
}
run_stage4() {  # eris_lj.c compiled as build-native.sh's stage 4 does, then its word check
  mkdir -p "$1/stage4"
  h=$(serhash "$WORK/ser/eris_lj.c" "$WORK/ser/eris_lj.h")
  rm -f "$1/stage4/eris_lj.o"
  "$CC" -c -O2 $PICFLAG -I"$W" -I"$WORK/ser" -DERIS_LJ_COMMIT='"negctl-bitop"' '-DERIS_LJ_SERHASH="'"$h"'"' \
    "$WORK/ser/eris_lj.c" -o "$1/stage4/eris_lj.o" 2> "$1/stage4/eris.err"
  if [ ! -f "$1/stage4/eris_lj.o" ]; then
    { echo "eris_lj.c did not compile:"; head -20 "$1/stage4/eris.err"; } > "$1/stage4.log"
    return 2
  fi
  ( LJEXE=$W/luajit$EXE OBJ=$1/stage4 SER_HASH=$h
    fail() { echo "STAGE 4 FAIL: $*"; exit 1; }
    say() { echo "$*"; }
    . "$WORK/stage4.sh"
    exit 0 ) > "$1/stage4.log" 2>&1
}
# rcof <suite>: the exit status of the run that suite is part of ('-': not run).
rcof() {
  case $1 in
    bitop) echo "$R_bitop" ;; fuzz) echo "$R_fuzz" ;; gen|floor|fix1) echo "$R_bitjit" ;;
    security) echo "$R_security" ;; gate) echo "$R_gate" ;; stage4) echo "$R_stage4" ;; *) echo - ;;
  esac
}
# runcatchers <dir> <catchers>: each suite they name runs once (run-bitjit.sh
# once, with the parts they name).
runcatchers() {
  R_bitop=- R_fuzz=- R_bitjit=- R_security=- R_gate=- R_stage4=-
  parts=
  for tk in $2; do
    case ${tk%%:*} in
      bitop) [ "$R_bitop" = - ] && { run_bitop "$1"; R_bitop=$?; } ;;
      fuzz) [ "$R_fuzz" = - ] && { run_fuzz "$1"; R_fuzz=$?; } ;;
      security) [ "$R_security" = - ] && { run_security "$1"; R_security=$?; } ;;
      gate) [ "$R_gate" = - ] && { run_gate "$1"; R_gate=$?; } ;;
      stage4) [ "$R_stage4" = - ] && { run_stage4 "$1"; R_stage4=$?; } ;;
      gen|floor|fix1) case " $parts " in *" ${tk%%:*} "*) ;; *) parts="$parts ${tk%%:*}" ;; esac ;;
      *) fail "arm $name: unknown catcher '$tk'" ;;
    esac
  done
  if [ -n "$parts" ]; then run_bitjit "$1" "${parts# }"; R_bitjit=$?; fi
  return 0
}
# The checks behind suite:check.
fuzzmode() {  # fuzzmode <dir> <K|V|P|H|U>: 0 if that mode MISMATCHed, JIT on or -joff
  awk -v m="$2" '/tuples, MISMATCH .* by mode / {
      s = $0; sub(/^.* by mode /, "", s); n = split(s, f, " ")
      for (i = 1; i < n; i += 2) if (f[i] == m && f[i + 1] + 0 > 0) hit = 1 }
    END { exit hit ? 0 : 1 }' "$1/fuzz/cmp-ours-1.txt" 2>/dev/null
}
strcase() {  # strcase <dir>: 0 if a t_ops case with a string operand differs
  for m in jit joff; do
    [ -f "$1/bitop/t_ops.$m.txt" ] || continue
    awk -F'\t' -v q="'" 'NR == FNR { a[FNR] = $0; next }
      a[FNR] != $0 && index($1, q) { hit = 1 } END { exit hit ? 0 : 1 }' \
      "$SELF_DIR/bitop/t_ops.expect" "$1/bitop/t_ops.$m.txt" && return 0
  done
  return 1
}
jit2loop() {  # jit2loop <floor dir> <loop>: 0 if that loop's line differs from -joff's under some option set
  [ -f "$1/jit2-joff.txt" ] || return 1
  want=$(awk -F'\t' -v n="$2" '$1 == n' "$1/jit2-joff.txt")
  [ -n "$want" ] || return 1
  for f in "$1"/jit2-*.txt; do
    case $f in */jit2-joff.txt|*/jit2-puc.txt|*/jit2-joff-nosar.txt) continue ;; esac
    [ "$(awk -F'\t' -v n="$2" '$1 == n' "$f")" = "$want" ] || return 0
  done
  return 1
}
gatedump() {  # gatedump <dir>: 0 if the gate printed a dump field other than the wanted one
  awk -v w="$BO_WANT" 'function dump(s) { if (match(s, / dump=[^ ]*/)) return substr(s, RSTART, RLENGTH); return "" }
    { d = dump($0); if (d != "" && d != dump(w)) hit = 1 } END { exit hit ? 0 : 1 }' "$1/gate.txt"
}
# check <dir> <catcher>: 0 caught, 1 not caught, 2 its suite proved nothing.
check() {
  rc=$(rcof "${2%%:*}")
  [ "$rc" = 2 ] && return 2
  [ "$rc" = 1 ] || return 1
  case $2 in
    bitop|fuzz|stage4) return 0 ;;
    bitop:t_ops|bitop:t_fold|bitop:t_sar) grep -q "^FAIL ${2#bitop:} (j" "$1/bitop.log" ;;
    bitop:coerce) grep -q '^FAIL coerce_agree (' "$1/bitop.log" ;;
    bitop:t_ops-str) strcase "$1" ;;
    fuzz:[KVPHU]) fuzzmode "$1" "${2#fuzz:}" ;;
    gen) grep -q '^seed [0-9]*: FAIL' "$1/bitjit.log" ;;
    floor:t_rec) grep -q '^FAIL t_rec seed' "$1/bitjit.log" ;;
    floor:t_rec-counts) grep -q '^FAIL t_rec seed [0-9]* (counts)' "$1/bitjit.log" ;;
    floor:t_jit2) grep -q '^FAIL t_jit2 (' "$1/bitjit.log" ;;
    floor:t_jit2/*) jit2loop "$1/bitjit/floor" "${2#floor:t_jit2/}" ;;
    fix1) grep -q '^FAIL fix1' "$1/bitjit.log" ;;
    security:FF12) grep -q '^FAIL FF12 ' "$1/security.log" ;;
    gate:dump) gatedump "$1" ;;
    *) return 1 ;;
  esac
}
# info <dir>: what each suite that ran saw, for the summary.
failids() {  # failids <log>: " [id,id]" of its "FAIL <id>" lines, or nothing
  awk '/^FAIL / { if (!($2 in s)) { s[$2] = 1; out = out sep $2; sep = "," } }
    END { if (out != "") printf " [%s]", out }' "$1" 2>/dev/null
}
info() {
  s=
  [ "$R_bitop" = - ] || s="$s; bitop $R_bitop$(failids "$1/bitop.log")"
  [ "$R_fuzz" = - ] || s="$s; fuzz $R_fuzz [$(awk '/tuples, MISMATCH .* by mode / { m = $0; sub(/^.* by mode /, "", m)
      printf "%s%s %s", sep, ($0 ~ /ours-jon/) ? "jon" : "joff", m; sep = "; " }' "$1/fuzz/cmp-ours-1.txt" 2>/dev/null)]"
  if [ "$R_bitjit" != - ]; then
    # gen: per seed, the most cases any of its JIT comparisons found different.
    g=$(awk '/^seed [0-9]+: shared[/]/ { m = 0
        for (i = 3; i <= NF; i++) if ($i !~ /puc=/) { v = $i; sub(/^.*=/, "", v); if (v + 0 > m) m = v + 0 }
        n++; if (m > 0) c++; if (n == 1 || m < lo) lo = m; if (m > hi) hi = m }
      END { if (n) printf " (gen: %d/%d seeds differ, %d-%d cases a seed)", c, n, lo, hi }' "$1/bitjit.log")
    fl=$(awk '/^FAIL t_rec seed/ { v = $4; sub(/:$/, "", v); x = "t_rec-s" v; if ($5 == "(counts):") x = x "c"; out = out sep x; sep = "," }
      /^FAIL t_jit2 [(]/ { out = out sep "t_jit2"; sep = "," }
      /^FAIL t_jit2: PUC/ { out = out sep "t_jit2-PUC"; sep = "," }
      /^FAIL fix1/ { out = out sep "fix1"; sep = "," }
      END { print out }' "$1/bitjit.log")
    s="$s; bitjit[${parts# }] $R_bitjit$g${fl:+ failed: $fl}"
  fi
  [ "$R_security" = - ] || s="$s; security $R_security$(failids "$1/security.log")"
  [ "$R_gate" = - ] || s="$s; gate $R_gate"
  [ "$R_stage4" = - ] || s="$s; stage4 $R_stage4"
  echo "${s#; }"
}
# wanted <name>: true when no selection was given, or it names the arm.
wanted() {
  [ -z "$NSEL" ] && return 0
  case " $NSEL " in *" $1 "*) return 0 ;; esac
  return 1
}
broken() {  # broken <why>
  echo "[negctl-bitop] $name: BROKEN ARM -- $1"
  printf '%-15s %-18s %s\n' "$name" "$file" "BROKEN ($1)" >> "$SUMMARY"
  bad=1
}
# arm <name> <file> <catchers> <old line(s)> <new line(s)>   (canon: no sabotage)
arm() {
  name=$1 file=$2 catchers=$3
  if [ "$LISTONLY" = 1 ]; then ALLARMS="$ALLARMS $name"; return 0; fi
  [ "$name" = canon ] || wanted "$name" || return 0
  d=$WORK/$name
  mkdir -p "$d" || fail "cannot create $d"
  t0=$(date +%s)
  DIRTY=
  restore
  if [ "$name" = canon ]; then
    allowed=
    for f in $ALLFILES; do dirty "$f"; done
  else
    allowed=$(objs_of "$file")
    t=$(fileof "$file")
    if ! sabotage "$WORK/canon/$file" "$4" "$5" "$d/$file"; then
      broken "its anchor does not occur exactly once in $file"; return
    fi
    nold=$(diff "$WORK/canon/$file" "$d/$file" | grep -c '^<')
    nnew=$(diff "$WORK/canon/$file" "$d/$file" | grep -c '^>')
    if [ "$nold" != 1 ] || [ "$nnew" != 1 ] || [ "$(grep -c -F "SABOTAGE $name:" "$d/$file")" != 1 ]; then
      broken "it changes $nold line(s) into $nnew, or its line does not say 'SABOTAGE $name:'"; return
    fi
    cp -f "$d/$file" "$t" || fail "cannot write $t"
    dirty "$file"
  fi
  if ! rebuild "$d/build.log"; then
    broken "the build failed (log: $d/build.log)"
    tail -5 "$d/build.log" | sed 's/^/  | /'
    return
  fi
  objcheck "$d" "$allowed"
  if [ "$name" = canon ]; then
    [ -z "$CHANGED" ] || { broken "the rebuild does not reproduce the shipped build: $CHANGED differ"; return; }
  else
    [ -z "$STRAY" ] || { broken "objects it does not reach changed:$STRAY"; return; }
    if [ "$file" != eris_lj.c ]; then
      [ -n "$CHANGED" ] || { broken "no object changed: the sabotage did not reach the code ($allowed)"; return; }
      [ -f "$t" ] && [ "$W/luajit$EXE" -nt "$t" ] || { broken "luajit$EXE is not newer than the sabotaged $file"; return; }
    fi
    if [ "$file" = vm_x64.dasc ] && ! grep -q -F "SABOTAGE $name:" "$W/host/buildvm_arch.h"; then
      broken "host/buildvm_arch.h does not echo the sabotaged line: DynASM did not assemble it"; return
    fi
  fi
  runcatchers "$d" "$catchers"
  missed= nothing=
  for tk in $catchers; do
    if [ "$name" = canon ]; then
      [ "$(rcof "${tk%%:*}")" = 0 ] || missed="$missed $tk"
    else
      check "$d" "$tk"
      case $? in 0) ;; 2) nothing="$nothing $tk" ;; *) missed="$missed $tk" ;; esac
    fi
  done
  if [ "$name" = canon ]; then
    if [ -z "$missed" ]; then v="PASS (every catcher passes; every object reproduced)"
    else v="FAIL (the canonical tree must pass:$missed did not)"; bad=1; fi
  elif [ -n "$nothing" ]; then
    v="FAIL (proved nothing:$nothing)"; bad=1
  elif [ -n "$missed" ]; then
    v="FAIL (NOT CAUGHT by$missed)"; bad=1
  else
    v="PASS (caught by $catchers)"
  fi
  sec=$(( $(date +%s) - t0 ))
  echo "[negctl-bitop] $name ($file, ${sec}s; objects changed: ${CHANGED:-none}): $v"
  echo "    $(info "$d")"
  printf '%-15s %-18s %s\n' "$name" "$file" "$v" >> "$SUMMARY"
  printf '%-15s %-18s     %s\n' '' '' "$(info "$d")" >> "$SUMMARY"
}

armlist() {
arm canon - 'bitop fuzz gen floor fix1 security gate stage4' '' ''
arm WRAP32-INTERP vm_x64.dasc 'bitop:t_ops fuzz:V' \
  '    |  ins RC, RA' \
  '    |  ins RCd, RAd@T@@T@// SABOTAGE WRAP32-INTERP: and/or/xor in 32 bits, as BitOp computed them'
arm WRAP32-FOLD lj_parse.c 'bitop:t_fold fuzz:K' \
  '      if (!oclj_bit2num(oclj_bitop64((int)opr-OPR_BAND+BC_BAND, k1, k2), &d))' \
  '      if (!oclj_bit2num((uint64_t)(int64_t)(int32_t)oclj_bitop64((int)opr-OPR_BAND+BC_BAND, k1, k2), &d))  /* SABOTAGE WRAP32-FOLD: a folded result wraps to 32 bits */'
arm SHIFTMASK vm_x64.dasc 'bitop:t_ops fuzz' \
  "    |  ja ->vmeta_bitop_pc@T@@T@// Count < 0 or > 63: 5.3's rules, in C." \
  '    |  // SABOTAGE SHIFTMASK: no count check, so the shift takes the count mod 64'
arm NEGSHIFT oclj_bitop.h 'bitop:t_ops' \
  '  case BC_BSHL: return oclj_shiftl(x, c);' \
  '  case BC_BSHL: return c < 0 ? 0 : oclj_shiftl(x, c);  /* SABOTAGE NEGSHIFT: << by a negative count gives 0, not a right shift */'
arm SARSHR oclj_bitop.h 'bitop:t_sar' \
  '  return (int64_t)x < 0 ? ~(~x >> (unsigned)y) : x >> (unsigned)y;' \
  '  return x >> (unsigned)y;  /* SABOTAGE SARSHR: ~>> shifts zeros in, as >> does */'
arm NOINT-FOLD lj_parse.c 'bitop:t_fold' \
  '    if (!oclj_flt2int(expr_numberV(e1), &k1) ||' \
  '    if (!oclj_flt2int(__builtin_floor(expr_numberV(e1)), &k1) ||  /* SABOTAGE NOINT-FOLD: a fractional left operand is floored and folded */'
arm NOINT-JIT oclj_bitop_rec.c 'floor:t_jit2/guard-exit' \
  '    emitir(IRTG(IR_EQ, IRT_NUM), back, tr);' \
  '    (void)back;  /* SABOTAGE NOINT-JIT: no guard that the operand is an integer */'
arm RANGE-HI oclj_num53.h 'bitop:t_ops fuzz' \
  '  if (!(n >= -9223372036854775808.0 && n < 9223372036854775808.0))' \
  '  if (n == 9223372036854775808.0) { *p = INT64_MAX; return 1; } if (!(n >= -9223372036854775808.0 && n < 9223372036854775808.0))  /* SABOTAGE RANGE-HI: 2^63 reads as math.maxinteger (U2-B) */'
arm STRCOERCE oclj_bitop_meta.c 'bitop:t_ops bitop:coerce' \
  '    if (oclj_str2int(strVdata(o), strV(o)->len, pi)) return 1;' \
  '    if (0 && oclj_str2int(strVdata(o), strV(o)->len, pi)) return 1;  /* SABOTAGE STRCOERCE: a string is read as a float, as LuaJIT arithmetic reads it */'
arm ERROPERAND oclj_bitop_meta.c 'bitop:t_ops' \
  '  ob_err_type(L, ob_tonum(rb, &i, &n) ? rc : rb);' \
  '  ob_err_type(L, ob_tonum(rc, &i, &n) ? rb : rc);  /* SABOTAGE ERROPERAND: the type error blames the second operand first */'
arm NARROW lj_opt_fold.c 'floor:t_rec floor:t_jit2' \
  '  if (fins->o == IR_CONV && irt_is64(fins->t))' \
  '  if (0 && fins->o == IR_CONV && irt_is64(fins->t))  /* SABOTAGE NARROW: an operand conversion to int64 is narrowed */'
arm KFOLD64 lj_opt_fold.c 'fuzz:U floor:t_rec' \
  '#if 1  /* OC-LuaJIT: the 64-bit bit operators, without FFI. */
  case IR_BAND: k1 &= k2; break;' \
  '#if LJ_HASFFI  /* SABOTAGE KFOLD64: the int64 constant folds are FFI-only again */
  case IR_BAND: k1 &= k2; break;'
arm SARCONST oclj_bitop_rec.c 'floor:t_rec-counts bitop:t_sar' \
  '      if (k >= 64)' \
  '      if (k >= 64 || k <= -64)  /* SABOTAGE SARCONST: a constant ~>> count of -64 or less fills with the sign */'
arm BCDUMP lj_bcdump.h 'security:FF12 gate:dump' \
  '#define BCDUMP_VERSION@T@@T@0x80' \
  '#define BCDUMP_VERSION@T@@T@2  /* SABOTAGE BCDUMP: upstream version 2 */'
arm WORDTOKEN eris_lj.c 'stage4' \
  '#define ELJ_W_BIT "bit64"' \
  '#define ELJ_W_BIT "bit32"  /* SABOTAGE WORDTOKEN: the word says 32-bit operators */'
arm INEXACT-INTERP vm_x64.dasc 'bitop:t_ops fuzz:V' \
  '    |  cmp RA, RC' \
  '    |  cmp RA, RA@T@@T@// SABOTAGE INEXACT-INTERP: the result check always passes'
arm INEXACT-BNOT vm_x64.dasc 'bitop:t_ops bitop:t_fold fuzz:V' \
  '    |  cmp TMPR, RB' \
  '    |  cmp TMPR, TMPR@T@@T@// SABOTAGE INEXACT-BNOT: the result check of unary ~ always passes'
arm INEXACT-SLOW oclj_bitop_meta.c 'bitop:t_ops-str' \
  '      ob_err_inexact(L, op);' \
  '      n = (double)oclj_u2s(oclj_bitop64((int)op, b, c));  /* SABOTAGE INEXACT-SLOW: the slow path stores the rounded double */'
arm INEXACT-FOLD lj_parse.c 'bitop:t_fold fuzz:K' \
  '      if (!oclj_bit2num(oclj_bitop64((int)opr-OPR_BAND+BC_BAND, k1, k2), &d))' \
  '      if (d = (double)oclj_u2s(oclj_bitop64((int)opr-OPR_BAND+BC_BAND, k1, k2)), 0)  /* SABOTAGE INEXACT-FOLD: the parser folds the rounded double */'
arm INEXACT-JIT oclj_bitop_rec.c 'gen' \
  '  if (!tref_isk(res)) {' \
  '  if (0) {  /* SABOTAGE INEXACT-JIT: no guard after a recorded result */'
arm SELFGUARD lj_opt_fold.c 'gen' \
  '@T@!(fins->op2 & OCLJ_IRCONV_EXACT))' \
  "@T@1)  /* SABOTAGE SELFGUARD: the exact-mark rule also folds a result guard's own check */"
arm WIDTH55 lj_opt_fold.c 'gen' \
  '    if (oclj_bitwidth(J, fleft->op1, 0) <= 54)' \
  '    if (oclj_bitwidth(J, fleft->op1, 0) <= 55)  /* SABOTAGE WIDTH55: a bound of 55 bits passes */'
arm WSHR oclj_bitop_fold.c 'gen' \
  '      return 65 - (IR(ir->op2)->i & 63);  /* In [0, 2^(64-k)). */' \
  '      return 64 - (IR(ir->op2)->i & 63);  /* SABOTAGE WSHR: BSHR by k bounded by 64 - k */'
arm WBAND oclj_bitop_fold.c 'gen' \
  '    if (IR(ir->op2)->o == IR_KINT64 && (int64_t)ir_k64(IR(ir->op2))->u64 >= 0)' \
  "    if (IR(ir->op2)->o == IR_KINT64)  /* SABOTAGE WBAND: BAND bounded by its constant's width, whatever the constant's sign */"
arm WADD0 oclj_bitop_fold.c 'gen' \
  '    wa = (wa > wb ? wa : wb) + 1;' \
  '    wa = (wa > wb ? wa : wb) + 0;  /* SABOTAGE WADD0: x + x as wide as x */'
arm WSHL0 oclj_bitop_fold.c 'gen' \
  '      wa = oclj_bitwidth(J, ir->op1, depth+1) + (IR(ir->op2)->i & 63);' \
  '      wa = oclj_bitwidth(J, ir->op1, depth+1) + (IR(ir->op2)->i & 31);  /* SABOTAGE WSHL0: BSHL by k widens by k mod 32 */'
arm FIX1 lj_opt_fold.c 'fix1' \
  '      (irt_isi64(IR(fleft->op1)->t) || !irt_isphi(fleft->t))) {' \
  '      (1 || !irt_isphi(fleft->t))) {  /* SABOTAGE FIX1: across a PHI, the fold takes any y */'
}

# The selection, checked against the arm list before anything is copied: a
# name that is no arm would otherwise select nothing and pass.
LISTONLY=1; ALLARMS=; armlist; LISTONLY=0
NSEL=
set -f
for a in $(printf '%s' "$OCLJ_NEGCTL_ARMS" | tr ',' ' '); do
  case " $ALLARMS " in
    *" $a "*) NSEL="$NSEL $a" ;;
    *) fail "OCLJ_NEGCTL_ARMS names '$a', which is no arm (arms:$ALLARMS)" ;;
  esac
done
set +f
[ -n "$OCLJ_NEGCTL_ARMS" ] && [ -z "$NSEL" ] && fail "OCLJ_NEGCTL_ARMS is set but names no arm"

WORK=$OCLJ_BUILD/negctl-bitop/$(date -u +%Y%m%dT%H%M%SZ)-$$
WB=$WORK/build/native
[ -e "$WORK" ] && fail "$WORK exists"
mkdir -p "$WB/obj-$PLATFORM" "$WORK/canon" "$WORK/ser" "$WORK/tmp" || fail "cannot create $WORK"
cp -rp "$SRCTREE" "$WB/" || fail "cannot copy $SRCTREE"
cp -p "$SRCOBJ/lj52shim.o" "$SRCOBJ/eris_lj.o" "$WB/obj-$PLATFORM/" || fail "cannot copy the objects"
W=$WB/luajit-$PLATFORM/src
echo "[negctl-bitop] work dir $WORK"

# THE COPY IS WHAT THE REPO SHIPS, or nothing here is about the repo.
for f in $NATIVE_FILES; do
  cmp -s "$OCLJ_REPO/native/luajit/$f" "$W/$f" \
    || fail "$W/$f is not native/luajit/$f: rebuild with build-native.sh before proving anything about it"
  cp -p "$W/$f" "$WORK/canon/$f" || fail "cannot save $f"
done
for p in $PATCHED; do
  f=${p%%:*}; s=patch-bitop-${p#*:}.sh
  TMPDIR=$WORK/tmp sh "$OCLJ_REPO/native/luajit/$s" "$PRISTINE/src/$f" "$WORK/tmp/$f" > "$WORK/tmp/$s.log" 2>&1 \
    || fail "native/luajit/$s refused the pristine $PRISTINE/src/$f (log: $WORK/tmp/$s.log)"
  cmp -s "$WORK/tmp/$f" "$W/$f" \
    || fail "$W/$f is not what native/luajit/$s makes of the pristine file: rebuild with build-native.sh"
  cp -p "$W/$f" "$WORK/canon/$f" || fail "cannot save $f"
done
cp -p "$OCLJ_SER/eris_lj.c" "$WORK/canon/eris_lj.c" && cp -p "$OCLJ_SER/eris_lj.c" "$WORK/ser/eris_lj.c" \
  && cp -p "$OCLJ_SER/eris_lj.h" "$WORK/ser/eris_lj.h" || fail "cannot copy $OCLJ_SER/eris_lj.[ch]"
# The build's eris_lj.o, which run-bitop.sh's part 3 and run-security.sh
# link, carries the hash of the serializer it was compiled from.
SH=$(serhash "$WORK/ser/eris_lj.c" "$WORK/ser/eris_lj.h")
grep -a -q -F "|$SH|ffi" "$WB/obj-$PLATFORM/eris_lj.o" \
  || fail "$SRCOBJ/eris_lj.o was not compiled from $OCLJ_SER/eris_lj.[ch] (no '|$SH|' word in it): rebuild with build-native.sh"
# An anchor is a whole line; a CR would hide every one.
for f in $ALLFILES; do
  [ "$(tr -cd '\r' < "$WORK/canon/$f" | wc -c | tr -d ' ')" = 0 ] || fail "$WORK/canon/$f carries CR characters"
done
echo "[negctl-bitop] the copy is the repo's: native/luajit's five files, the seven patch scripts' output on $PRISTINE/src, eris_lj.o from $OCLJ_SER (serializer hash $SH)"

# build-native.sh's own gate and stage-4 text, so that a weakened gate there
# is a weakened catcher here.
awk 'index($0, "cat > \"$OCLJ_BUILD/bitops.lua\" <<") == 1 { on = 1; n++; next }
  on && $0 == "EOF" { on = 0; e++; next }
  on { print }
  END { exit (n == 1 && e == 1) ? 0 : 1 }' "$BN" > "$WORK/bitops.lua" \
  || fail "$BN: no single bitops.lua heredoc (cat > \"\$OCLJ_BUILD/bitops.lua\" <<'EOF' ... EOF)"
BO_WANT=$(awk -v q="'" 'index($0, "BO_WANT=" q) == 1 { s = substr($0, 10)
    if (substr(s, length(s)) == q) { print substr(s, 1, length(s) - 1); n++ } }
  END { exit n == 1 ? 0 : 1 }' "$BN") && [ -n "$BO_WANT" ] || fail "$BN: no single BO_WANT='...' line"
awk 'index($0, "OBS=$(\"$LJEXE\" -e ") == 1 { on = 1; n++ }
  on { print }
  on && index($0, "say \"    VM-features word ") == 1 { on = 0; e++ }
  END { exit (n == 1 && e == 1) ? 0 : 1 }' "$BN" > "$WORK/stage4.sh" \
  || fail "$BN: no single stage-4 block from OBS=\$(\"\$LJEXE\" -e to say \"    VM-features word"
grep -q -F 'WORD=$(grep -a -o -E' "$WORK/stage4.sh" && grep -q -F 'for t in $OBS; do' "$WORK/stage4.sh" \
  || fail "$WORK/stage4.sh (from $BN) lacks the WORD extraction or the token loop"
echo "[negctl-bitop] from $BN: the bitops gate ($(grep -c . "$WORK/bitops.lua") lines) and stage 4's word check ($(grep -c . "$WORK/stage4.sh") lines)"
objmd5 > "$WORK/canon-obj.md5"
[ "$(grep -c . "$WORK/canon-obj.md5")" -gt 50 ] || fail "$W holds too few objects ($(grep -c . "$WORK/canon-obj.md5"))"
[ -n "$NSEL" ] && echo "[negctl-bitop] OCLJ_NEGCTL_ARMS:$NSEL, and canon, which always runs -- not the full sweep"

bad=0
SUMMARY=$WORK/summary.txt
printf '%-15s %-18s %s\n' arm file verdict > "$SUMMARY"

armlist

# Every file back, and the tree must be the shipped build again, object for
# object: the arms left nothing behind.
DIRTY=
restore
mkdir -p "$WORK/restore"
if rebuild "$WORK/restore/build.log"; then
  objcheck "$WORK/restore" ""
  if [ -z "$CHANGED" ]; then v="PASS (every file put back; every object byte-identical to the shipped build's)"
  else v="FAIL (objects still differ: $CHANGED)"; bad=1; fi
else
  v="FAIL (the build failed: $WORK/restore/build.log)"; bad=1
fi
echo "[negctl-bitop] restore: $v"
printf '%-15s %-18s %s\n' restore - "$v" >> "$SUMMARY"

echo
cat "$SUMMARY"
if [ -n "$NSEL" ]; then
  if [ "$bad" = 0 ]; then
    echo "NEGCTL-BITOP: PASS FOR THE SELECTED ARMS ONLY (selected:$NSEL; canon passes; each selected sabotage is caught; results: $WORK)"
    exit 0
  fi
  echo "NEGCTL-BITOP: FAIL (selected arms only:$NSEL; results: $WORK)"
  exit 1
fi
if [ "$bad" = 0 ]; then
  echo "NEGCTL-BITOP: PASS (canon passes; every sabotage is caught by its catchers; results: $WORK)"
  exit 0
fi
echo "NEGCTL-BITOP: FAIL (results: $WORK)"
exit 1
