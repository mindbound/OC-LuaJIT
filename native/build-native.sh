#!/bin/sh
# =====================================================================
# build-native.sh -- clean checkout -> libjnlua[jit]52-<os>-<arch>.<so|dll|dylib>
#
# Builds the OC-compatible native that makes OpenComputers' OWN repackaged
# JNLua drive LuaJIT 2.1. Nothing in OC-JNLua, in the OC Java layer, or in
# ocelot-brain is modified; the whole compatibility layer is lj52shim.{c,h}.
#
# The DLL is three translation units plus static LuaJIT:
#   jnlua.o    OC-JNLua's own native/src/jnlua.c, unmodified except for ONE
#              diagnostic line, compiled with -include lj52shim.h so the 5.2
#              C API it calls resolves to us.  The line: lua_1resume's error
#              path throws from the top of L, where the coroutine object sits,
#              instead of from the error object lua_resume left on T -- so
#              every kernel panic logged "LuaRuntimeException: thread: 0x..."
#              and never the kernel's message.  native/jnlua/patch-resume-
#              error.sh moves T's error object onto L first, on a build-dir
#              COPY (both variants), anchored to occur exactly once; the
#              checkout itself stays pristine and is asserted so below.
#   lj52shim.o the compatibility layer (5.2 surface on the 5.1 ABI)
#   eris_lj.o  our Eris-API-compatible serializer (serializer/eris_lj.c)
#   libluajit.a  LuaJIT 2.1 static, LUA52COMPAT + CHECKHOOK, plus ONE
#              function patched on the build copy: lj_func_freeproto scrubs
#              the trace-abort penalty cache of the dying prototype's loop
#              heads (native/luajit/patch-penalty-scrub.sh).  The cache is
#              keyed by bytecode ADDRESS and upstream never clears it when a
#              prototype dies, so on our CRT heap a program re-loaded from
#              source inherits its predecessor's penalties and is blacklisted
#              to the interpreter on the ~9th re-load (2026-09-22;
#              test/native/penalty_test.c).  Same shape as the jnlua patch:
#              anchored, applied to the copy, asserted by content before make
#              -- and the copy's lj_func.c is re-taken from the pristine
#              checkout every build first, so the patched file is always a
#              fresh patch of upstream, never a verified-and-kept old one.
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
#   OCLJ_JNI    a JDK's include/ dir    any JDK 8+ (jni.h + <os>/jni_md.h, where
#                                      <os> is win32, linux or darwin to match the HOST)
#   OCLJ_SHIM   dir holding lj52shim.c and lj52shim.h  (default $OCLJ_REPO/native)
#   OCLJ_LUAJIT LuaJIT source tree      (default $OCLJ_REPO/prototype/watchdog/luajit)
#   OCLJ_BUILD  scratch build dir       (default $OCLJ_REPO/build/native)
#   OCLJ_OUT    where the library lands (default $OCLJ_BUILD/libdir, or
#                                      libdir-additive for OCLJ_VARIANT=additive)
#   CC          C compiler              (default gcc; MinGW-w64 on Windows)
#   JOBS        make -j                 (default 4)
#
# USAGE
#   OCLJ_JNLUA=/path/to/OC-JNLua OCLJ_JNI="/c/Program Files/Java/jdk1.8.0_211/include" \
#     sh build-native.sh
#
# OUTPUT
#   $OCLJ_OUT/libjnlua52-<os>-<arch><ext>       e.g. -windows-x86_64.dll
#   That exact basename is what ocelot-brain looks for.  LuaStateFactory
#   builds it as  "libjnlua" + version + "-" + platformName + libExtension
#   (version="52", platformName from its own table) and finds it by scanning
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

# THE TOOLS MUST SPEAK ONE LANGUAGE, because this script matches on what they
# say.  Two places depend on it and both broke on the first Linux build:
#   * the jnlua warning allowlist pins warning TEXT by line, and gcc quotes
#     identifiers with Unicode directional marks in a UTF-8 locale and with
#     ASCII apostrophes otherwise -- so the allowlist matched on MinGW and
#     missed the identical warning on Ubuntu, failing the build for a warning
#     it was written to permit;
#   * the postflight sorts exported symbol names, and collation order is
#     locale-dependent, which would make the comparison platform-dependent too.
# Pinning the locale is what makes the INSTRUMENT the same on both platforms.
LC_ALL=C
export LC_ALL

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)}"
: "${OCLJ_LUAJIT:=$OCLJ_REPO/prototype/watchdog/luajit}"
: "${OCLJ_SHIM:=$OCLJ_REPO/native}"
: "${OCLJ_SER:=$OCLJ_REPO/serializer}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
# OCLJ_OUT is defaulted BELOW, once the variant is known: the two variants must
# land in DIFFERENT directories.  See the OCLJ_VARIANT block.
: "${OCLJ_OUT:=}"
: "${OCLJ_JNLUA:=}"
: "${OCLJ_JNI:=}"
: "${CC:=gcc}"
: "${JOBS:=4}"

# WHICH LIBRARY THIS BUILD PRODUCES, and it is two different products.
#
#   dropin   (default)  jnlua.c with its macro values as upstream has them, so
#                       LUA_VERSION_NUM 502 makes it export Java_..._LuaState_*
#                       -- it IS OpenComputers' 5.2 native.  The harness
#                       substitutes it wholesale via
#                       debug.forceNativeLibPathFirst.  Every measurement in
#                       bench/runs/ was taken on this, and it can never be the
#                       shipped mod: OC loads its own 5.2 native in preInit and
#                       binds LuaState to it; two libraries cannot back one class.
#
#   additive            native/jnlua/repack.sh rewrites two macro values on a
#                       build-dir COPY so the library exports
#                       Java_..._LuaStateLuaJIT_* instead, backing the fourth
#                       LuaState class gen-luastate-subclass.py emits.  Nothing
#                       of OpenComputers' is replaced.  THIS IS WHAT SHIPS.
#
#   Both variants then get the one-line resume-error patch (see the header)
#   on their copy; the dropin's copy exists only for that.
#
# docs/research/shipping-model.md has the reasoning; test/native/LinkProbe.java
# is the proof a JVM actually binds the additive one (5/5, 2026-09-15).
#
# WHY THE ADDITIVE NAME IS libjnluaJIT52 AND NOT libocluajit52.  The name is a
# JOINT, not a label, and the other side of the joint is not ours to choose.
# Both OC's and ocelot-brain's LuaStateFactory compute
#
#     libraryName = "libjnlua" + version + "-" + platform + ext
#
# as a PRIVATE val, load it in init(), and record the result in two PRIVATE
# fields that createState() reads.  A subclass can override `version` and can
# touch none of the rest.  So `version = "jit52"` is the whole hook: the base
# class's own loader finds OUR library, sets its own private state, and ~110
# lines of sandbox preparation (os.setlocale, killing the 5.1 compat entries,
# the per-state RNG) are INHERITED rather than copied.  Copying them would be a
# second implementation of OpenComputers' sandbox shape, drifting silently the
# first time upstream changed it.
#
# One artifact, one name, and NOBODY of ours computes it.  Both adapters declare
# version() = "jit52" and let the host's own LuaStateFactory derive the filename,
# so there is no second copy of this string to drift:
#   src/main/java/io/github/astronfo/ocluajit/arch/LuaJITStateFactory.java (mod)
#   test/native/OcljArch.scala                                          (harness)
fail() { echo "BUILD FAIL: $*" >&2; exit 1; }
say()  { echo "[build] $*"; }
T0=$(date +%s)
stamp() { echo "[build] +$(( $(date +%s) - T0 ))s  $*"; }

# =====================================================================
# PLATFORM
#
# THE SPELLINGS ARE NOT OURS TO CHOOSE. The host's LuaStateFactory builds
# "libjnlua" + version + "-" + <system> + "-" + <arch> + <ext> from its own
# table and then looks for exactly that file, so `darwin` and not `osx`,
# `x86_64` and not `amd64`, `aarch64` and not `arm64`. A wrong spelling here is
# a file-not-found at runtime, which is indistinguishable from an unsupported
# platform: the library is simply never offered and nothing says why.
# =====================================================================
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) OCLJ_OS=windows ;;
  Linux)   OCLJ_OS=linux   ;;
  Darwin)  OCLJ_OS=darwin  ;;
  FreeBSD) OCLJ_OS=freebsd ;;
  *) fail "unsupported host system '$(uname -s)'.  Add it HERE and to the platform
       table in LuaJITStateFactory.libraryName() together -- one without the other
       builds a file under a name the loader never asks for." ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  OCLJ_ARCH=x86_64  ;;
  aarch64|arm64) OCLJ_ARCH=aarch64 ;;
  *) fail "unsupported machine '$(uname -m)'" ;;
esac

# PER-PLATFORM BUILD DETAILS, each with a reason it cannot be the same everywhere.
#
#   LIBEXT     what the loader appends to the name.
#   JNI_MD     jni_md.h lives in a per-OS subdirectory of a JDK's include/.
#   LINK_EXTRA --enable-stdcall-fixup is a PE/MinGW linker option and an ERROR
#              on ELF.  -static-libgcc keeps us off a libgcc the host may not
#              have, and is wanted wherever gcc is the compiler.
#   PICFLAG    LuaJIT's BUILDMODE=static does NOT compile position-independent
#              code by default, and linking a non-PIC archive into a shared
#              object fails on x86-64 ELF with a relocation error against .text.
#              A Windows DLL needs nothing of the sort.  This single flag is the
#              difference between "builds" and "does not link" on Linux, and it
#              has to reach the LUAJIT build rather than only ours -- which is
#              why it is spliced into LJ_FLAGS -- AND into our own three
#              compiles, because every object entering a shared library needs
#              it, not only the archive.  Missing it on ours produced
#              "relocation R_X86_64_PC32 against symbol stderr can not be used
#              when making a shared object" at link, naming a libc symbol
#              rather than anything that looks like ours.
case $OCLJ_OS in
  windows) LIBEXT=.dll   ; JNI_MD=win32    ; LINK_EXTRA="-static-libgcc -Wl,--enable-stdcall-fixup" ; PICFLAG= ;;
  darwin)  LIBEXT=.dylib ; JNI_MD=darwin   ; LINK_EXTRA=""                ; PICFLAG=-fPIC ;;
  *)       LIBEXT=.so    ; JNI_MD=$OCLJ_OS ; LINK_EXTRA="-static-libgcc"  ; PICFLAG=-fPIC ;;
esac
PLATFORM="$OCLJ_OS-$OCLJ_ARCH"

: "${OCLJ_VARIANT:=dropin}"
case $OCLJ_VARIANT in
  dropin)   DLL_NAME=libjnlua52-$PLATFORM$LIBEXT    ; : "${OCLJ_OUT:=$OCLJ_BUILD/libdir}"          ;;
  additive) DLL_NAME=libjnluajit52-$PLATFORM$LIBEXT ; : "${OCLJ_OUT:=$OCLJ_BUILD/libdir-additive}" ;;
  *) fail "OCLJ_VARIANT must be dropin or additive" ;;
esac

# WHY SEPARATE DIRECTORIES AND NOT ONE, GIVEN THE FILENAMES ALREADY DIFFER.
# Because the directory is itself a switch.  ocelot-brain (and OC) check
# debug.forceNativeLibPathFirst for EVERY factory, each looking for its own
# filename, so a directory holding both variants makes "Lua 5.2" resolve to the
# DROPIN -- our LuaJIT wearing OpenComputers' 5.2 name -- at the very moment we
# are trying to prove our additive library coexists with the REAL PUC 5.2.  The
# test would pass while measuring LuaJIT against itself.
#
# With libdir-additive holding only libjnluajit52-*, the 5.2 factory misses,
# falls back to the bundled PUC native, and one JVM ends up running both VMs at
# once -- which is the shipped configuration, and a far stronger check of the
# no-collision claim than any symbol count.
LJ_FLAGS="-DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_CHECKHOOK $PICFLAG"

# --------------------------------------------------------------- 0
say "=============== 0. preflight ==============="
say "host    = $PLATFORM   (lib*$LIBEXT, jni_md in $JNI_MD/)"
if [ "$OCLJ_OS" != windows ]; then
  # NOT A REFUSAL -- the build script is portable and everything up to the shim
  # works here (LuaJIT with -fPIC, the naming, the ELF postflight).  What is not
  # portable yet is lj52shim.c's deadline watchdog, which is a Win32 timer queue;
  # the shim REFUSES rather than silently building an untested backend, at
  # lj52shim.c:498.  Saying so now means the cause is named before the twenty
  # seconds of LuaJIT, instead of being inferred from the cascade of errors that
  # gcc emits after an #error it has already reported.
  say "    NOTE: on $OCLJ_OS this build is expected to stop in step 2 at"
  say "          lj52shim.c:498 -- the deadline watchdog has only a Win32 backend."
  say "          A POSIX one is a roadmap item; everything before it works here."
fi
command -v "$CC" >/dev/null 2>&1 || fail "no C compiler '$CC' on PATH (MinGW-w64 gcc on Windows, gcc or clang elsewhere)"
say "cc      = $("$CC" --version | head -1)"
[ -n "$OCLJ_JNLUA" ] || fail "OCLJ_JNLUA is unset: point it at an OC-JNLua checkout (git clone https://github.com/MightyPirates/OC-JNLua.git)"
[ -f "$OCLJ_JNLUA/native/src/jnlua.c" ] || fail "no $OCLJ_JNLUA/native/src/jnlua.c"
if [ -z "$OCLJ_JNI" ]; then
  for c in "$JAVA_HOME/include" "/c/Program Files/Java/jdk1.8.0_211/include"; do
    [ -f "$c/jni.h" ] && OCLJ_JNI="$c" && break
  done
fi
[ -n "$OCLJ_JNI" ] && [ -f "$OCLJ_JNI/jni.h" ] || fail "OCLJ_JNI must name a JDK include dir containing jni.h"
[ -f "$OCLJ_JNI/$JNI_MD/jni_md.h" ] || fail "no $OCLJ_JNI/$JNI_MD/jni_md.h -- that JDK include
       directory belongs to a different platform than this build ($PLATFORM)"
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
# The comment-stripping filter deliberately carries NO ^ anchor and no [^:]*
# prefix.  With a Windows drive-letter path (C:/Users/...) such a character
# class stops at the DRIVE colon, so no comment line is ever stripped and the
# gate then fails on the shim's own prose DESCRIBING the escape hatches it
# removed -- accusing the shim of exactly the regression it exists to prevent.
# Measured: 3 false matches under C:/..., 0 under /c/....
#
# Keep the pipeline on physically ADJACENT lines.  A line-continuation
# followed by comment lines and then a line beginning with '|' is a syntax
# error, not a commented pipeline: the backslash-newline is spliced away
# before tokenising, the '#' then comments to end of line, and the next line
# starts with a bare '|'.  That shipped once and killed this script at
# stage 0 -- every gate below it silently never ran.
# -E, AND IT MATTERS: the collector gate below hands this an alternation with
# a `\(` in it.  Under plain grep (BRE) `|` is a literal and `\(` opens a
# group that is never closed, so grep printed "Unmatched ( or \(" to the
# stderr this function discards and matched NOTHING -- the gate passed on
# every build from the day it was written (2026-09-15) until 2026-09-22,
# when the trace-flush phase replicated it by hand and watched it error.
# Under -E the same pattern means what it says.  The escape-hatch tokens are
# plain words and read the same either way.
codegrep() {   # codegrep <pattern> -> prints only non-comment matches
  grep -nE "$1" "$OCLJ_SHIM/lj52shim.c" "$OCLJ_SHIM/lj52shim.h" 2>/dev/null \
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
# THE COLLECTOR-STATE ENUM MUST STILL BEGIN WITH GCSpause.
# lj52shim.c spells GCSpause as the literal 0 (LJ52_GCS_PAUSE) rather than
# including lj_gc.h, because that header also declares lj_gc_step and
# lj_gc_fullgc and the gate below forbids those from reaching the shim's scope.
# That trade is only safe if the assumption is checked, so check it.  The enum
# is lj_gc.h:11-14 and its own comment says "Order matters."
LJGC_H="$OCLJ_LUAJIT/src/lj_gc.h"
if [ -f "$LJGC_H" ]; then
  if ! tr -d ' 	' < "$LJGC_H" | grep -q '^GCSpause,GCSpropagate,'; then
    grep -n -A3 'Garbage collector states' "$LJGC_H"
    fail "lj_gc.h's collector-state enum no longer begins 'GCSpause, GCSpropagate'
         (see above).  lj52shim.c hardcodes GCSpause as 0 via LJ52_GCS_PAUSE and
         that is now wrong -- the emergency collector would disarm on the wrong
         state and hand the collector an unbounded budget it never gives back."
  fi
else
  fail "cannot find $LJGC_H to verify the collector-state enum that
         lj52shim.c's LJ52_GCS_PAUSE depends on."
fi

# THE SHIM MUST NEVER DRIVE THE COLLECTOR DIRECTLY.  lj52_gc_pressure writes
# two scalars (gc.threshold, gc.stepmul) and latches a third (gc.currentwhite);
# it calls nothing.  That is the whole safety argument, and three verified
# constraints say why a collect from inside the allocator is unsound:
# lj_gc_fullgc hangs on-trace unconditionally (lj_gc.c:673-677 + :799-800), a
# collect at lj_tab.c:123-124 frees the table under construction, and L->top is
# stale at arbitrary allocation points (memory-accounting.md section 11, C1/C5/C6).
# Including lj_gc.h to reach LJ_GC_WHITES would also drag these declarations
# into scope, which is why the shim compares the whole currentwhite byte.
if codegrep 'lj_gc_fullgc|lj_gc_step|luaC_|lua_gc *\(|LUA_GCCOLLECT|LUA_GCSTEP' | grep -q .; then
  codegrep 'lj_gc_fullgc|lj_gc_step|luaC_|lua_gc *\(|LUA_GCCOLLECT|LUA_GCSTEP'
  fail "the shim drives the collector directly (line above).  It must not: a
         collection from inside the allocator hangs on-trace, can free the
         object under construction, and runs with a stale L->top.  The shim
         ARMS the VM's own trip-wire and lets a safepoint do the work -- see
         lj52_gc_pressure and docs/research/memory-accounting.md section 11."
fi
if codegrep getenv | grep -q .; then
  codegrep getenv
  fail "the shim calls getenv().  Security- and scheduling-relevant behaviour
         must not be taken from the process environment, where no server
         operator would ever see it."
fi
# The mode gate itself, asserted by shape rather than trusted.
# THE ALLOCATOR CONVENTION, pinned.  lj52_setallocf decides whether accounting
# is armed from jnlua's own encoding of intent: l_alloc_checked is always
# installed with ud == L, l_alloc_unchecked always with ud == NULL.  A RENAME or
# RETYPE of the four names the lua_setallocf macro borrows is a compile error,
# which is the failure mode we want -- but a change to this CONVENTION would
# compile silently and go one of two bad ways: enforcement never arms (the very
# defect this change removes, quietly restored), or it stays armed through
# lua_close, where a __gc metamethod can then OOM in a bare JNI frame.  So count
# the sites rather than trusting them.
JN=$OCLJ_JNLUA/native/src/jnlua.c
N_CHK=$(grep -c 'lua_setallocf(L, l_alloc_checked, L)' "$JN" || true)
N_UNC=$(grep -c 'lua_setallocf(L, l_alloc_unchecked, NULL)' "$JN" || true)
N_ALL=$(grep -c 'lua_setallocf' "$JN" || true)
say "    jnlua lua_setallocf: $N_CHK checked(ud==L)  $N_UNC unchecked(ud==NULL)  $N_ALL total"
[ "$N_CHK" = "2" ] && [ "$N_UNC" = "3" ] && [ "$N_ALL" = "5" ] \
  || fail "OC-JNLua's lua_setallocf convention has changed: expected 2 checked
         (ud == L), 3 unchecked (ud == NULL), 5 total; got $N_CHK/$N_UNC/$N_ALL.
         lj52_setallocf keys the memory cap on exactly that encoding.  Re-read
         jnlua.c's allocator section and update lj52shim.c DELIBERATELY before
         touching these numbers."
grep -q 'define JNLUA_JAVASTATE' "$JN" \
  || fail "OC-JNLua no longer defines JNLUA_JAVASTATE.  The shim caches the Java
         LuaState by watching the lua_setfield that binds it under that key, and
         takes the key from jnlua's own macro; without it the cap stops
         enforcing silently."

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

OBJ=$OCLJ_BUILD/obj-$PLATFORM
mkdir -p "$OBJ" "$OCLJ_OUT" || fail "cannot create $OCLJ_BUILD"

# --------------------------------------------------------------- 1
say "=============== 1. LuaJIT 2.1 (static) ==============="
say "    XCFLAGS=$LJ_FLAGS   BUILDMODE=static"
# PER-PLATFORM INTERMEDIATE TREES, for the same reason the output directories
# are split. These were one shared directory, which is fine while only one
# platform ever builds and wrong the moment a second does: the Windows build
# leaves luajit.exe here and BOTH the harness and build-kernel.sh run it, so a
# Linux build in the same tree would replace it with an ELF binary and the next
# kernel patch would fail with a format error a long way from its cause.
LJ_WORK=$OCLJ_BUILD/luajit-$PLATFORM
if [ ! -d "$LJ_WORK" ]; then
  say "copying $OCLJ_LUAJIT -> $LJ_WORK (the source tree is built in place; we never dirty the checkout)"
  cp -r "$OCLJ_LUAJIT" "$LJ_WORK" || fail "copy failed"
  rm -rf "$LJ_WORK/.git"
fi
LJ=$LJ_WORK/src
# THE ONE FUNCTION OF LUAJIT WE CHANGE, on the copy, every build.  The copy
# persists between builds, and the patch script's "already patched" path
# verifies only four marker lines -- so a stale or hand-edited block on the
# copy (say `pc < bcend` turned into `pc < bc`) would be ACCEPTED and ship
# silently, and a revised block in the script would never reach a copy that
# already carries the old one.  Demonstrated 2026-09-22: the script alone,
# run in place on such a mangling, exits 0 "already carries the penalty
# scrub" and leaves the mangled line in.
#
# So the copy's lj_func.c is never the patch's input.  The PRISTINE checkout's
# file is re-copied over it first, every build, on every platform, and the
# patch is applied to that: the file make compiles is then a pure function of
# (checkout, patch script), byte-identical to a fresh patch of the pristine
# source, and the "already patched" path is never taken here (asserted: the
# scrub must be ABSENT right after the re-copy).  The pre-make content
# assertion and the lj_func.o -nt check below pin the rest.
SCRUB_LINE='setmref(J->penalty[i].pc, NULL);'
grep -q -F -- "$SCRUB_LINE" "$OCLJ_LUAJIT/src/lj_func.c" \
  && fail "$OCLJ_LUAJIT/src/lj_func.c carries the penalty scrub: the pinned
         checkout must stay pristine.  The patch belongs on the build copy only."
cp -f "$OCLJ_LUAJIT/src/lj_func.c" "$LJ/lj_func.c" \
  || fail "cannot re-copy the pristine $OCLJ_LUAJIT/src/lj_func.c over $LJ/lj_func.c"
grep -q -F -- "$SCRUB_LINE" "$LJ/lj_func.c" \
  && fail "$LJ/lj_func.c still carries the penalty scrub right after the pristine
         re-copy -- the copy did not take, and the patch step would have been
         verifying a stale block instead of applying the current one"
say "    lj_func.c: pristine copy re-taken from $OCLJ_LUAJIT/src (the build copy is never the patch's input)"
sh "$OCLJ_REPO/native/luajit/patch-penalty-scrub.sh" "$LJ/lj_func.c" "$LJ/lj_func.c" \
  || fail "the penalty-scrub patch refused (see above)"
# And it must be IN THE FILE MAKE IS ABOUT TO COMPILE, asserted by content
# rather than by the step's exit status, for the same reason the jnlua patch
# is: a build that compiled an unpatched copy would blacklist every re-loaded
# program again, with nothing to say so.
[ "$(grep -c -F -- "$SCRUB_LINE" "$LJ/lj_func.c")" = "1" ] \
  || fail "$LJ/lj_func.c does not carry the penalty scrub exactly once -- the
         copy make is about to compile is not the patched one"
say "    lj_func.c: penalty scrub present in the freshly re-derived build copy (asserted by content before make)"
make -C "$LJ" clean >/dev/null 2>&1
# Q= makes the Makefile echo full compiler command lines, so the flags can be
# asserted rather than assumed.
make -C "$LJ" BUILDMODE=static XCFLAGS="$LJ_FLAGS" Q= -j"$JOBS" \
  > "$OCLJ_BUILD/luajit_build.log" 2>&1 \
  || { tail -30 "$OCLJ_BUILD/luajit_build.log"; fail "LuaJIT build failed (log: $OCLJ_BUILD/luajit_build.log)"; }
[ -f "$LJ/libluajit.a" ] || fail "no $LJ/libluajit.a after make"
stamp "libluajit.a built ($(wc -c < "$LJ/libluajit.a") bytes)"
# The patched lj_func.c must be what went into the archive.  `make clean`
# above removes every object, so this holds by construction -- but say so
# with evidence: the object is newer than the (possibly just rewritten)
# source, and the compile line for it is in the log.
[ -f "$LJ/lj_func.o" ] || fail "no $LJ/lj_func.o after make"
[ "$LJ/lj_func.o" -nt "$LJ/lj_func.c" ] \
  || fail "lj_func.o is not newer than the patched lj_func.c -- make did not recompile it"
grep -q 'lj_func\.c' "$OCLJ_BUILD/luajit_build.log" \
  || fail "lj_func.c never reached the compiler command line (log: $OCLJ_BUILD/luajit_build.log)"
say "    lj_func.o recompiled from the patched lj_func.c ($(date -r "$LJ/lj_func.o" +%H:%M:%S) > $(date -r "$LJ/lj_func.c" +%H:%M:%S))"

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
rm -f "$OBJ/lj52shim.o"
# -I the JDK headers: the shim includes <jni.h> so its allocator can use
# jnlua's own getluamemory/setluamemory to publish the machine's RAM use.
"$CC" -c -O2 $PICFLAG -Wall -Wextra -I"$LJ" -I"$OCLJ_SHIM" -I"$OCLJ_SER" \
  -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" \
  "$OCLJ_SHIM/lj52shim.c" -o "$OBJ/lj52shim.o" 2>"$OCLJ_BUILD/shim.err"
[ -f "$OBJ/lj52shim.o" ] || { cat "$OCLJ_BUILD/shim.err"; fail "shim did not compile"; }
SW=$(grep -c 'warning:' "$OCLJ_BUILD/shim.err" || true)
say "    -Wall -Wextra warnings = $SW"
[ "$SW" = "0" ] || { grep -E 'warning:' "$OCLJ_BUILD/shim.err" | head -20; fail "the shim must compile warning-clean"; }

# --------------------------------------------------------------- 3
say "=============== 3. OC-JNLua jnlua.c (checkout unmodified; one diagnostic line patched on a copy; shim force-included) ==============="
# -include lj52shim.h is the whole trick: jnlua.c's 5.2 calls bind to the shim
# before jnlua.c's own first line is read.  The CHECKOUT's jnlua.c is
# byte-identical to upstream OC-JNLua -- verified below.  What we compile is a
# build-dir copy that differs from it by the macro values repack.sh rewrites
# (additive only) plus the ONE line patch-resume-error.sh replaces (both
# variants): lua_1resume's throw, which otherwise reports the coroutine object
# instead of the error the coroutine died with.  Each step refuses unless it
# changes exactly what it says, so neither can quietly become a fork of
# jnlua.c's logic, and neither moves a line number (the warning allowlist
# below pins two of them).
rm -f "$OBJ/jnlua.o"
PATCH_IN="$OCLJ_JNLUA/native/src/jnlua.c"
if [ "$OCLJ_VARIANT" = additive ]; then
  # repack.sh refuses unless it changes EXACTLY two lines.
  sh "$OCLJ_REPO/native/jnlua/repack.sh" "$OCLJ_JNLUA" "$OCLJ_BUILD/jnlua-luajit.repack.c" \
    || fail "the jnlua repack refused (see above)"
  PATCH_IN="$OCLJ_BUILD/jnlua-luajit.repack.c"
  JNLUA_SRC="$OCLJ_BUILD/jnlua-luajit.c"
else
  JNLUA_SRC="$OCLJ_BUILD/jnlua-dropin.c"
fi
# patch-resume-error.sh refuses unless its anchor matches EXACTLY once and the
# result differs from its input by exactly one line.
sh "$OCLJ_REPO/native/jnlua/patch-resume-error.sh" "$PATCH_IN" "$JNLUA_SRC" \
  || fail "the jnlua resume-error patch refused (see above)"
# And the fix must be IN THE FILE WE COMPILE, asserted by content rather than
# by the step's exit status: a future reshuffle of the two steps that left
# JNLUA_SRC pointing at an unpatched copy would otherwise build a native that
# logs "thread: 0x..." for every kernel panic again, with nothing to say so.
[ "$(grep -c -F '{ lua_xmove(T, L, 1); } throw(L, status);' "$JNLUA_SRC")" = "1" ] \
  || fail "$JNLUA_SRC does not carry the resume-error fix exactly once -- the
         compiled copy is not the patched one"
"$CC" -c -O2 $PICFLAG -Wall -DNDEBUG -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" -I"$LJ" -I"$OCLJ_SHIM" \
  -include "$OCLJ_SHIM/lj52shim.h" \
  "$JNLUA_SRC" -o "$OBJ/jnlua.o" \
  > "$OCLJ_BUILD/jnlua.err" 2>&1
NERR=$(grep -c 'error:' "$OCLJ_BUILD/jnlua.err" || true)
NWARN=$(grep -c 'warning:' "$OCLJ_BUILD/jnlua.err" || true)
say "    errors=$NERR  warnings=$NWARN   (-Wall; the checkout's jnlua.c is byte-identical to upstream, the copy differs by the lines named above)"
[ "$NERR" = "0" ] && [ -f "$OBJ/jnlua.o" ] \
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
#
# THE FILENAME IS VARIABLE BUT THE LINE NUMBERS ARE NOT.  The additive variant
# compiles build/native/jnlua-luajit.c, a repack.sh copy, so warnings arrive as
# jnlua-luajit.c:623 rather than jnlua.c:623 and the allowlist missed them --
# the gate correctly refused an otherwise fine build.  The dropin now compiles
# a copy too, jnlua-dropin.c.  repack.sh changes two lines IN PLACE and
# patch-resume-error.sh one, and neither inserts anything, so :623 and :1666
# still point at the same statements in every one of these files; that is
# precisely why each verifies its diff by line count.
grep -E 'warning:' "$OCLJ_BUILD/jnlua.err" \
  | grep -vE 'jnlua(-luajit|-dropin)?\.c:623:[0-9]+: warning: pointer targets in passing argument 2' \
  | grep -vE "jnlua(-luajit|-dropin)?\.c:1666:[0-9]+: warning: .tablesize_result. may be used uninitialized" \
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

# THE BLOB FINGERPRINT HAS TO COVER THE SERIALIZER, and it did not.  LJ_COMMIT
# above is the LUAJIT tree's HEAD, so every edit to eris_lj.c shipped under an
# unchanged fingerprint: a blob written by the old restore code loaded silently
# under the new one, which is precisely the failure the fingerprint exists to
# refuse.  Hash the sources rather than trust a commit id -- this repo is built
# dirty constantly, so a git id would not have moved either.
if command -v sha1sum >/dev/null 2>&1; then
  SER_HASH=$(cat "$OCLJ_SER/eris_lj.c" "$OCLJ_SER/eris_lj.h" | sha1sum | cut -c1-8)
elif command -v md5sum >/dev/null 2>&1; then
  SER_HASH=$(cat "$OCLJ_SER/eris_lj.c" "$OCLJ_SER/eris_lj.h" | md5sum | cut -c1-8)
else
  SER_HASH=$(cat "$OCLJ_SER/eris_lj.c" "$OCLJ_SER/eris_lj.h" | cksum | cut -d" " -f1)
fi
[ -n "$SER_HASH" ] || fail "could not hash the serializer sources for the blob fingerprint"
say "    serializer hash = $SER_HASH  (blobs are pinned to this)"

# Compiled WITHOUT -include lj52shim.h on purpose: the serializer must reach
# the genuine LuaJIT lua_load/lua_loadx so it can load the LuaJIT bytecode it
# writes with lj_bcwrite.  The 'b' path stays open INTERNALLY to eris_lj while
# lj52_load keeps it shut to sandbox code (allowBytecode=false).
"$CC" -c -O2 $PICFLAG -I"$LJ" -I"$OCLJ_SER" -DERIS_LJ_COMMIT="\"$LJ_COMMIT\"" \
  -DERIS_LJ_SERHASH="\"$SER_HASH\"" \
  "$OCLJ_SER/eris_lj.c" -o "$OBJ/eris_lj.o" 2>"$OCLJ_BUILD/eris.err"
[ -f "$OBJ/eris_lj.o" ] || { grep -oE 'error: .*' "$OCLJ_BUILD/eris.err" | head -20; fail "eris_lj.c did not compile"; }

# --------------------------------------------------------------- 5
say "=============== 5. link ==============="
# javavm.c is deliberately NOT linked: it is OC-JNLua's "start a JVM from Lua"
# entry point, which the embedded (JVM-hosted) direction never uses.
"$CC" -shared -o "$OCLJ_OUT/$DLL_NAME" \
  "$OBJ/jnlua.o" "$OBJ/lj52shim.o" "$OBJ/eris_lj.o" \
  "$LJ/libluajit.a" -lm $LINK_EXTRA \
  > "$OCLJ_BUILD/link.err" 2>&1
[ -f "$OCLJ_OUT/$DLL_NAME" ] || { head -30 "$OCLJ_BUILD/link.err"; fail "link failed"; }

# --------------------------------------------------------------- 6
say "=============== 6. postflight ==============="

# ONE READER, TWO BACKENDS, AND THE SAME ASSERTIONS ON BOTH.
#
# No single command lists exported symbols on both object formats, and the
# failure is silent in the direction that matters: `nm -D` on a PE DLL prints
# "no symbols" and exits 0, so a naive port would have counted zero
# LuaState_* symbols on Windows and concluded the additive build was clean.
# Measured, on the real artifacts: objdump -p finds 87 Java_* in the DLL and
# nm -D finds 0; on ELF objdump -p prints program headers and no symbols at all.
#
# So the reader branches and NOTHING ELSE DOES. Every assertion below runs on
# its output, which means a Linux build cannot be waved through on weaker checks
# than the Windows one gets -- the thing most likely to go wrong in a port of a
# guard is that the new platform quietly asserts less.
#
#   PE   objdump -p lists each export as
#          [   2] +base[   3]  0002 Java_li_cil_..._lua_1debugfree
#        so the name is the last field of the +base[ lines.
#   ELF  nm -D --defined-only prints  <addr> <type> <name>.
exported_symbols() {
  case $OCLJ_OS in
    # The [0-9a-f]{4} ordinal field is load-bearing, not decoration: objdump
    # prints a COLUMN HEADER line that also contains "+base[", whose last field
    # is the word RVA. Matching on "+base[" alone therefore yields 90 names for
    # an 89-export DLL -- which the count assertion below caught on its first
    # run, before this reader had shipped anywhere.
    windows) objdump -p "$1" | grep -E '[+]base[[][ 0-9]+[]][ ]+[0-9a-f]{4} ' | awk '{print $NF}' ;;
    *)       nm -D --defined-only "$1" | awk '{print $NF}' ;;
  esac
}

if command -v objdump >/dev/null 2>&1 && command -v nm >/dev/null 2>&1; then
  SYMS=$(exported_symbols "$OCLJ_OUT/$DLL_NAME" | sort -u)
  syms() { printf '%s\n' "$SYMS"; }

  # THE READER ITSELF IS CHECKED FIRST. Every count below is a grep over this
  # list, so a reader that returned nothing would make all of them pass
  # vacuously -- exactly the shape of defect this project keeps finding in its
  # own guards. An empty list is not "no forbidden symbols", it is no evidence.
  NSYM=$(syms | grep -c .)
  [ "$NSYM" -gt 0 ] || fail "the symbol reader returned NOTHING for $OCLJ_OS.
       Every assertion below would have passed vacuously.  Check that objdump/nm
       understand this object format before trusting any result from this build."

  EXPORTS=$(syms | grep -c '^Java_')
  ONLOAD=$(syms | grep -cx 'JNI_OnLoad')
  PKG=$(syms | grep -m1 '^Java_li_cil_repack_')
  say "    reader = $OCLJ_OS   total exports = $NSYM   Java_* = $EXPORTS   JNI_OnLoad = $ONLOAD"
  say "    e.g. $PKG"
  [ "$EXPORTS" -gt 50 ] || fail "only $EXPORTS Java_* exports; jnlua did not link in"
  [ -n "$PKG" ] || fail "no Java_li_cil_repack_* export: this is upstream naef/jnlua, not OC's repack.
         ocelot-brain looks up li.cil.repack.com.naef.jnlua.LuaState and would find nothing."

  # THE VARIANT MUST HAVE THE FAMILY IT ASKED FOR.  The failure is silent
  # either way: a dropin exporting LuaStateLuaJIT_* binds nothing in the
  # harness, and an additive exporting LuaState_* COLLIDES with OpenComputers'
  # own 5.2 native in a real game -- the exact thing this variant prevents.
  # Both would look like a perfectly successful build.
  OWN=$(syms | grep -c '^Java_li_cil_repack_com_naef_jnlua_LuaStateLuaJIT_')
  OCS=$(syms | grep -cE '^Java_li_cil_repack_com_naef_jnlua_LuaState_[a-z]')
  say "    symbol family: LuaStateLuaJIT_*=$OWN  LuaState_*=$OCS   (variant=$OCLJ_VARIANT)"
  if [ "$OCLJ_VARIANT" = additive ]; then
    [ "$OWN" -gt 50 ] || fail "additive exports only $OWN LuaStateLuaJIT_* symbols: the repack did not take"
    [ "$OCS" = "0" ]  || fail "additive STILL exports $OCS LuaState_* symbols: it would collide with OC own 5.2 native"
  else
    [ "$OCS" -gt 50 ] || fail "dropin exports only $OCS LuaState_* symbols: it cannot stand in for OC native"
    [ "$OWN" = "0" ]  || fail "dropin exports $OWN LuaStateLuaJIT_* symbols: the harness would bind nothing"
  fi

  # ABI SURFACE, pinned.  ocelot-brain resolves every LuaState native method by
  # JNI name, so the library is ABI-compatible iff the exported NAME SET is the
  # one OC-JNLua declares.  jnlua.c at da3d4d45 exports 87 Java_* methods plus
  # JNI_OnLoad and JNI_OnUnload = 89.
  #
  # THE EXPECTED TOTAL IS PER-FORMAT, and that is not a fudge. A PE DLL exports
  # exactly what is declared JNIEXPORT; an ELF shared object's dynamic symbol
  # table also carries what the C runtime and the linker put there, so the
  # count is not 89 and pinning it to 89 would fail every Linux build. What is
  # invariant across both -- and what actually matters -- is the JNI surface:
  # the 87 Java_* names plus the two JNI_On* hooks. That is asserted on both.
  [ "$EXPORTS" = "87" ] || fail "Java_* export count is $EXPORTS, expected 87.  The ABI surface no
         longer matches OC-JNLua da3d4d45.  Either jnlua.c was bumped (update this
         number deliberately) or a translation unit failed to link in."
  syms | grep -qx JNI_OnLoad   || fail "no JNI_OnLoad export"
  syms | grep -qx JNI_OnUnload || fail "no JNI_OnUnload export"
  if [ "$OCLJ_OS" = windows ]; then
    [ "$NSYM" = "89" ] || fail "PE export table holds $NSYM names, expected exactly 89
         (87 Java_* + JNI_OnLoad + JNI_OnUnload).  Something else became visible."
  fi
else
  say "    SKIPPED: objdump and nm are both needed to verify the symbol surface"
  say "    (this build has NOT been checked for the dropin/additive mix-up)"
fi

SZ=$(wc -c < "$OCLJ_OUT/$DLL_NAME")
SHA=$(sha256sum "$OCLJ_OUT/$DLL_NAME" 2>/dev/null | cut -c1-16)
stamp "OK  $OCLJ_OUT/$DLL_NAME  ${SZ} bytes  sha256:${SHA}..."

# COLLECT ADDITIVE ARTIFACTS FOR PACKAGING.
#
# build.gradle.kts stages this directory into the jar at
# assets/opencomputers/lib/, which is where OpenComputers' own loader looks. It
# is a COLLECTION point, deliberately not cleared: building on Windows and then
# on Linux leaves both libraries here, their filenames differ by platform, and
# one jar carries both. That is the only way a multi-platform release gets
# built, since no single machine can produce them all.
#
# The DROPIN is never collected. It is our LuaJIT wearing OpenComputers 5.2
# name, which is right for the benchmark harness and catastrophic in a jar --
# OC own factory would find it and replace the 5.2 VM for every computer. The
# gradle side refuses it by name as well; this is the first of the two gates.
if [ "$OCLJ_VARIANT" = additive ]; then
  DIST="$OCLJ_BUILD/dist"
  mkdir -p "$DIST" || fail "cannot create $DIST"
  cp "$OCLJ_OUT/$DLL_NAME" "$DIST/$DLL_NAME" || fail "cannot collect $DLL_NAME into $DIST"
  say "collected for packaging: $DIST/$DLL_NAME"
  say "    dist now holds: $(ls "$DIST" | tr '
' ' ')"
fi

echo
echo "NEXT: point ocelot-brain at it and boot OpenOS:"
echo "  OCLJ_LIBDIR=$OCLJ_OUT sh $OCLJ_REPO/test/native/smoke-test.sh"

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
#    jnlua.c we compile from an untouched checkout (a build-dir copy carries
#    the one-line resume-error patch, and the additive variant's macro values):
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
