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
#   libluajit.a  LuaJIT 2.1 static, with the feature set native/luajit/
#              oclj_features.h names (LUA52COMPAT + CHECKHOOK + DISABLE_FFI),
#              plus TWELVE changes made on the build copy: three to
#              functions, one including that header, one adding three
#              functions, and round 3's seven, six of which give the bitwise
#              operators Lua 5.3.6's 64-bit results and one of which keeps
#              LuaJIT's own jit.* tools exact under them.
#              lj_func_freeproto scrubs the trace-abort penalty cache of the
#              dying prototype's loop heads
#              (native/luajit/patch-penalty-scrub.sh).  The cache is
#              keyed by bytecode ADDRESS and upstream never clears it when a
#              prototype dies, so on a heap that hands a freed block straight
#              back -- the machine's was the C library's until 2026-10-02,
#              and is each state's own lj_alloc arena since, which usually
#              does the same (docs/research/luajit-penalty-cache-report.md)
#              -- a program re-loaded from source inherits its
#              predecessor's penalties and is blacklisted to the interpreter
#              on the ~9th re-load (2026-09-22;
#              test/native/penalty_test.c).  Same shape as the jnlua patch:
#              anchored, applied to the copy, asserted by content before make
#              -- and the copy's lj_func.c is re-taken from the pristine
#              checkout every build first, so the patched file is always a
#              fresh patch of upstream, never a verified-and-kept old one.
#              And lj_err_mem and lj_err_err never push their message below
#              the current frame (native/luajit/patch-fastfunc-errmem-top.sh):
#              a fast function that stores L->base but not L->top before an
#              allocating C call (tostring of a number, string.char/sub/
#              reverse/lower/upper) left L->top below its frame, and a
#              refusal there overwrote the frame link that LuaJIT's unwinder
#              then dereferenced -- the process died (2026-10-05;
#              bench/runs/2026-10-05-errmem/).  Inside an xpcall message
#              handler lj_err_mem hands to lj_err_err, which pushes with no
#              refresh at all.  Same steps as the scrub.
#              recff_format keeps string.format's integer conversions
#              compiled without FFI (native/luajit/patch-strfmt-xint-noffi.sh):
#              upstream's no-FFI branch is a NYI for %x %X %o %u, and for %d
#              with a flag or a width, on an int-typed operand, so the trace
#              stitches around the call and a hot loop runs 1.6-2.1x slower
#              when its strings repeat, 1.2x when each is new (2026-10-16);
#              the patch formats the int as the double the
#              interpreter formats, through the same C function.
#              lj_arch.h includes oclj_features.h
#              (native/luajit/patch-features-include.sh): THE LUAJIT FEATURE
#              SET below.  And lib_string.c registers Lua 5.3.6's
#              string.pack, string.packsize and string.unpack
#              (native/luajit/patch-strpack-register.sh), whose code is
#              native/luajit/oclj_strpack.c, copied next to it: our LuaJIT is
#              a fork that may take 5.3 functions (decided 2026-10-13), and
#              luaopen_string is the one opener jnlua, luajit.exe and every
#              test reach.  Same steps as the scrub, all three.
#              And round 3's seven (native/luajit/patch-bitop-*.sh, decided
#              2026-10-17): & | ~ << >> ~>> and unary ~ compute Lua 5.3.6's
#              64-bit integer results -- 1 << 32 is 4294967296, no longer 1
#              -- in the parser's constant folding (lj_parse.c), the
#              interpreter's fast path (vm_x64.dasc) and slow path
#              (lj_meta.c), the trace recorder (lj_record.c) and the fold
#              engine (lj_opt_fold.c), with the rules in native/luajit/
#              oclj_bitop.h and the code in oclj_bitop_meta.c,
#              oclj_bitop_rec.c, oclj_bitop_fold.c and oclj_num53.h (5.3.6's
#              number readers, which oclj_strpack.c shares), all copied next
#              to them.  A result with more than 53 significant bits has no
#              double and raises; every other result is 5.3.6's.  The same
#              bytecode now computes something else, so lj_bcdump.h's
#              BCDUMP_VERSION becomes 0x80 and each build refuses the other's
#              dumps.  The seventh (patch-bitop-jitlib.sh) makes jit.util
#              (lib_jit.c) return bytecode words and snapshot entries
#              unsigned: LuaJIT's own jit/bc.lua decodes them with these
#              operators, and a negative word made `luajit -bl` raise and
#              -jdump abort the traces it recorded.  Same steps as the
#              scrub, all seven; vm_x64.dasc also because make regenerates
#              host/buildvm_arch.h from it.
#
# THE LUAJIT FEATURE SET is native/luajit/oclj_features.h, with the reason
# for each flag: LUAJIT_ENABLE_LUA52COMPAT (OC's platform is Lua 5.2 source),
# LUAJIT_ENABLE_CHECKHOOK (machine.lua cannot boot with the JIT on without
# it) and LUAJIT_DISABLE_FFI (with FFI the lexer mints unpersistable cdata
# from `1LL`), and an #error for every other option the pinned LuaJIT tests
# that changes a structure, the bytecode, the unwinder or what a gate here
# measures (a census of its LUAJIT_* conditionals, 2026-10-16).  It is ONE
# file, read
# by the LuaJIT archive and by every translation unit of ours that includes a
# LuaJIT internal header, because those macros change LuaJIT's structures:
# GG_State is 6376 bytes without FFI and 6384 with it, and the shim and the
# serializer read jit_State at an offset that moves with it.  Step 1 copies it
# into the build copy and makes lj_arch.h include it, refuses a feature -D on
# any LuaJIT compile line, and checks the preprocessor's verdict through
# -I"$LJ"; stage 1b compares the archive's GG_State with the one our headers
# describe, and lj52_newstate does the same at run time.
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
# NO FEATURE MACRO TRAVELS AS A FLAG: they are all in native/luajit/
# oclj_features.h (THE LUAJIT FEATURE SET, above).  PICFLAG is codegen only and
# changes no structure, so it alone still reaches XCFLAGS.
LJ_FLAGS="$PICFLAG"
LJ_FEATURES_H=$OCLJ_REPO/native/luajit/oclj_features.h

# --------------------------------------------------------------- 0
say "=============== 0. preflight ==============="
say "host    = $PLATFORM   (lib*$LIBEXT, jni_md in $JNI_MD/)"
if [ "$OCLJ_OS" != windows ] && [ "$OCLJ_OS" != linux ]; then
  # NOT A REFUSAL -- the build script is portable and everything up to the shim
  # works here (LuaJIT with -fPIC, the naming, the ELF postflight).  What is not
  # portable is lj52shim.c's deadline watchdog: it has a Win32 timer-queue
  # backend and a Linux pthread one, and on any other host the shim REFUSES with
  # an #error rather than silently building an untested backend.  Saying so now
  # means the cause is named before the twenty seconds of LuaJIT, instead of
  # being inferred from the cascade of errors that gcc emits after an #error it
  # has already reported.
  say "    NOTE: on $OCLJ_OS this build is expected to stop in step 2 at lj52shim.c's"
  say "          #error \"lj52 watchdog: only the Win32 and Linux backends exist\"."
  say "          Everything before it works here."
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
[ -f "$LJ_FEATURES_H" ]        || fail "no $LJ_FEATURES_H: the LuaJIT feature set"
[ -f "$OCLJ_LUAJIT/src/lj_record.c" ] || fail "no LuaJIT source at $OCLJ_LUAJIT"
grep -q LUAJIT_ENABLE_CHECKHOOK "$OCLJ_LUAJIT/src/lj_record.c" \
  || fail "$OCLJ_LUAJIT/src/lj_record.c has no LUAJIT_ENABLE_CHECKHOOK option: not a
         LuaJIT 2.x tree.  Use the pinned checkout (prototype/watchdog/luajit, upstream
         1ee778a4; make -C prototype/watchdog luajit-src)."
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
# THE VALUE FINALIZER'S KEY, pinned on both sides (lj52shim.c, THE VALUE
# FINALIZER).  The shim finds jnlua's shared Java-object metatable at
# registry[LJ52_JNLUA_OBJECT], and that is a COPY of jnlua.c's JNLUA_OBJECT:
# lj52shim.c is its own translation unit and cannot borrow jnlua's macro the
# way the lua_setallocf macro borrows JNLUA_JAVASTATE.  A copy can drift, so
# both spellings are asserted here, exactly.  Drifted, every install answers
# LJ52_VGC_ENOMT: machines still start, LuaJITArchitecture logs the refusal,
# and dropped file handles and AE2 iterators leak until reboot again -- the
# defect the finalizer exists to remove, back behind one log line.
grep -qE '^#define[[:space:]]+JNLUA_OBJECT[[:space:]]+"jnlua\.Object"[[:space:]]*$' "$JN" \
  || fail "OC-JNLua no longer defines JNLUA_OBJECT as \"jnlua.Object\" (jnlua.c:31
         at da3d4d45).  lj52shim.h's LJ52_JNLUA_OBJECT is a copy of that key: the
         Value finalizer would find no metatable to install on, and Values would
         never be disposed.  Re-read jnlua.c's Java-object metatable and update
         lj52shim.h DELIBERATELY, then this pattern."
grep -qE '^#define[[:space:]]+LJ52_JNLUA_OBJECT[[:space:]]+"jnlua\.Object"([[:space:]]|$)' "$OCLJ_SHIM/lj52shim.h" \
  || fail "lj52shim.h's LJ52_JNLUA_OBJECT is no longer \"jnlua.Object\", the key
         jnlua.c's JNLUA_OBJECT registers its Java-object metatable under.  The
         Value finalizer would install on nothing (LJ52_VGC_ENOMT at every
         machine start).  The two spellings must be equal."

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
say "luajit  = $OCLJ_LUAJIT @ $LJ_COMMIT (feature set: native/luajit/oclj_features.h)"
say "jnlua   = $OCLJ_JNLUA @ $(git -C "$OCLJ_JNLUA" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
say "shim    = $OCLJ_SHIM"
say "out     = $OCLJ_OUT/$DLL_NAME"

OBJ=$OCLJ_BUILD/obj-$PLATFORM
mkdir -p "$OBJ" "$OCLJ_OUT" || fail "cannot create $OCLJ_BUILD"

# --------------------------------------------------------------- 1
say "=============== 1. LuaJIT 2.1 (static) ==============="
say "    XCFLAGS=$LJ_FLAGS   BUILDMODE=static"
say "    features (native/luajit/oclj_features.h): $(grep -E '^#define LUAJIT_' "$LJ_FEATURES_H" | awk '{printf "%s ", $2}')"
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
# THE FIRST OF THE TWELVE LUAJIT CHANGES, on the copy, every
# build.  The copy
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
# THE SECOND: lj_err_mem and lj_err_err must never push their message below
# the current frame (native/luajit/patch-fastfunc-errmem-top.sh;
# bench/runs/2026-10-05-errmem/).  A fast function that stores L->base but not
# L->top before an allocating C call -- tostring of a number,
# string.char/sub/reverse/lower/upper -- leaves L->top stale below its frame;
# when that allocation is refused, the message overwrote the frame link and
# LuaJIT's unwinder dereferenced it: the process died, in a game the JVM.
# Inside an xpcall message handler lj_err_mem hands to lj_err_err, which pushes
# with no refresh at all.  Same steps as the scrub, for the same reasons:
# pristine checkout asserted, re-copied, the clamp ABSENT after the copy,
# patched, present exactly twice (once per push) before make, lj_err.o newer
# after.  The absence checks match any form of the guard, so a checkout that a
# different version of the patch dirtied is refused for that reason.
ERRMEM_ANY='L->top < L->base'
ERRMEM_LINE='  if (LJ_UNLIKELY(L->top < L->base))'
grep -q -F -- "$ERRMEM_ANY" "$OCLJ_LUAJIT/src/lj_err.c" \
  && fail "$OCLJ_LUAJIT/src/lj_err.c carries the ERRMEM top clamp: the pinned
         checkout must stay pristine.  The patch belongs on the build copy only."
cp -f "$OCLJ_LUAJIT/src/lj_err.c" "$LJ/lj_err.c" \
  || fail "cannot re-copy the pristine $OCLJ_LUAJIT/src/lj_err.c over $LJ/lj_err.c"
grep -q -F -- "$ERRMEM_ANY" "$LJ/lj_err.c" \
  && fail "$LJ/lj_err.c still carries the ERRMEM top clamp right after the
         pristine re-copy -- the copy did not take"
say "    lj_err.c: pristine copy re-taken from $OCLJ_LUAJIT/src"
sh "$OCLJ_REPO/native/luajit/patch-fastfunc-errmem-top.sh" "$LJ/lj_err.c" "$LJ/lj_err.c" \
  || fail "the ERRMEM top-clamp patch refused (see above)"
[ "$(grep -c -F -- "$ERRMEM_LINE" "$LJ/lj_err.c")" = "2" ] \
  || fail "$LJ/lj_err.c does not carry the ERRMEM top clamp exactly twice -- the
         copy make is about to compile is not the patched one"
say "    lj_err.c: ERRMEM top clamp present twice in the freshly re-derived build copy (asserted by content before make)"
# THE THIRD: recff_format must keep string.format's integer conversions
# compiled without FFI (native/luajit/patch-strfmt-xint-noffi.sh).  Upstream's
# no-FFI branch is a NYI for %x %X %o %u, and for %d with a flag or a width,
# on an int-typed operand: the trace stitches around the call, and a hot loop
# runs 1.6-2.1x slower when its strings repeat, 1.2x when each is new
# (2026-10-16).  Same steps as the scrub and the clamp:
# pristine checkout asserted, re-copied, the fallback ABSENT after the copy,
# patched, present exactly once before make, lj_ffrecord.o newer after; the
# FFI / integer-format gate after the CHECKHOOK probe proves the loop compiles
# and prints what the interpreter prints.
FMTX_MARK='OC-LuaJIT (native/luajit/patch-strfmt-xint-noffi.sh)'
grep -q -F -- "$FMTX_MARK" "$OCLJ_LUAJIT/src/lj_ffrecord.c" \
  && fail "$OCLJ_LUAJIT/src/lj_ffrecord.c carries the no-FFI integer-format fallback:
         the pinned checkout must stay pristine.  The patch belongs on the build copy only."
cp -f "$OCLJ_LUAJIT/src/lj_ffrecord.c" "$LJ/lj_ffrecord.c" \
  || fail "cannot re-copy the pristine $OCLJ_LUAJIT/src/lj_ffrecord.c over $LJ/lj_ffrecord.c"
grep -q -F -- "$FMTX_MARK" "$LJ/lj_ffrecord.c" \
  && fail "$LJ/lj_ffrecord.c still carries the integer-format fallback right after the
         pristine re-copy -- the copy did not take"
say "    lj_ffrecord.c: pristine copy re-taken from $OCLJ_LUAJIT/src"
sh "$OCLJ_REPO/native/luajit/patch-strfmt-xint-noffi.sh" "$LJ/lj_ffrecord.c" "$LJ/lj_ffrecord.c" \
  || fail "the no-FFI integer-format patch refused (see above)"
[ "$(grep -c -F -- "$FMTX_MARK" "$LJ/lj_ffrecord.c")" = "1" ] \
  || fail "$LJ/lj_ffrecord.c does not carry the integer-format fallback exactly once -- the
         copy make is about to compile is not the patched one"
say "    lj_ffrecord.c: no-FFI integer-format fallback present in the freshly re-derived build copy (asserted by content before make)"
# THE FOURTH, AND THE ONLY HEADER: lj_arch.h includes oclj_features.h
# (native/luajit/patch-features-include.sh), the one file that names the
# feature set (THE LUAJIT FEATURE SET, in this script's header).  The header
# is copied in from native/luajit and compared; lj_arch.h is re-taken from the
# pristine checkout and patched like the three .c files; and the include must
# be there exactly once, directly after lua.h, before make runs.
FEAT_INC='#include "oclj_features.h"'
grep -q -F -- "$FEAT_INC" "$OCLJ_LUAJIT/src/lj_arch.h" \
  && fail "$OCLJ_LUAJIT/src/lj_arch.h includes oclj_features.h: the pinned checkout must
         stay pristine.  The include belongs on the build copy only."
[ -e "$OCLJ_LUAJIT/src/oclj_features.h" ] \
  && fail "$OCLJ_LUAJIT/src/oclj_features.h exists: the pinned checkout must stay pristine.
         The feature header lives in native/luajit and is copied to the build copy only."
cp -f "$OCLJ_LUAJIT/src/lj_arch.h" "$LJ/lj_arch.h" \
  || fail "cannot re-copy the pristine $OCLJ_LUAJIT/src/lj_arch.h over $LJ/lj_arch.h"
grep -q -F -- "$FEAT_INC" "$LJ/lj_arch.h" \
  && fail "$LJ/lj_arch.h still includes oclj_features.h right after the pristine re-copy --
         the copy did not take"
cp -f "$LJ_FEATURES_H" "$LJ/oclj_features.h" \
  || fail "cannot copy $LJ_FEATURES_H into $LJ"
cmp -s "$LJ_FEATURES_H" "$LJ/oclj_features.h" \
  || fail "$LJ/oclj_features.h differs from $LJ_FEATURES_H right after the copy"
say "    lj_arch.h: pristine copy re-taken; oclj_features.h copied from native/luajit"
sh "$OCLJ_REPO/native/luajit/patch-features-include.sh" "$LJ/lj_arch.h" "$LJ/lj_arch.h" \
  || fail "the feature-header include patch refused (see above)"
FEAT_AT=$(awk -v a='#include "lua.h"' -v b="$FEAT_INC" \
  'prev == a && index($0, b) == 1 { n++ } { prev = $0 } END { print n + 0 }' "$LJ/lj_arch.h")
[ "$(grep -c -F -- "$FEAT_INC" "$LJ/lj_arch.h")" = "1" ] && [ "$FEAT_AT" = "1" ] \
  || fail "$LJ/lj_arch.h does not include oclj_features.h exactly once, directly after
         lua.h -- the copy make is about to compile does not carry the feature set"
say "    lj_arch.h: includes oclj_features.h once, right after lua.h (asserted by content before make)"
# THE FIFTH, AND THE FIRST THAT ADDS FUNCTIONS: lib_string.c registers Lua
# 5.3.6's string.pack, string.packsize and string.unpack
# (native/luajit/patch-strpack-register.sh), whose code is
# native/luajit/oclj_strpack.c, copied next to it like oclj_features.h.  Our
# LuaJIT is a fork that may take 5.3 functions (decided 2026-10-13), and
# luaopen_string is the one opener that jnlua's openlib(STRING), luajit.exe's
# luaL_openlibs and every native test reach.  Same steps as the four above:
# pristine checkout asserted (no registration, no oclj_strpack.c), lib_string.c
# re-copied, the registration ABSENT after the copy, the code copied and
# compared, patched, present exactly once before make; after make,
# lib_string.o newer than both files, the fast-function table naming all
# three, and the luajit.exe gate below.
STRPACK_MARK='OC-LuaJIT (native/luajit/patch-strpack-register.sh)'
STRPACK_C=$OCLJ_REPO/native/luajit/oclj_strpack.c
[ -f "$STRPACK_C" ] || fail "no $STRPACK_C: the code of string.pack/packsize/unpack"
grep -q -F -- "$STRPACK_MARK" "$OCLJ_LUAJIT/src/lib_string.c" \
  && fail "$OCLJ_LUAJIT/src/lib_string.c registers string.pack: the pinned checkout must stay
         pristine.  The registration belongs on the build copy only."
[ -e "$OCLJ_LUAJIT/src/oclj_strpack.c" ] \
  && fail "$OCLJ_LUAJIT/src/oclj_strpack.c exists: the pinned checkout must stay pristine.
         The code lives in native/luajit and is copied to the build copy only."
cp -f "$OCLJ_LUAJIT/src/lib_string.c" "$LJ/lib_string.c" \
  || fail "cannot re-copy the pristine $OCLJ_LUAJIT/src/lib_string.c over $LJ/lib_string.c"
grep -q -F -- "$STRPACK_MARK" "$LJ/lib_string.c" \
  && fail "$LJ/lib_string.c still registers string.pack right after the pristine re-copy --
         the copy did not take"
cp -f "$STRPACK_C" "$LJ/oclj_strpack.c" || fail "cannot copy $STRPACK_C into $LJ"
cmp -s "$STRPACK_C" "$LJ/oclj_strpack.c" \
  || fail "$LJ/oclj_strpack.c differs from $STRPACK_C right after the copy"
say "    lib_string.c: pristine copy re-taken; oclj_strpack.c copied from native/luajit"
sh "$OCLJ_REPO/native/luajit/patch-strpack-register.sh" "$LJ/lib_string.c" "$LJ/lib_string.c" \
  || fail "the string.pack registration patch refused (see above)"
[ "$(grep -c -F -- "$STRPACK_MARK" "$LJ/lib_string.c")" = "1" ] \
  && [ "$(grep -c -x -F -- '#include "oclj_strpack.c"' "$LJ/lib_string.c")" = "1" ] \
  || fail "$LJ/lib_string.c does not register string.pack exactly once -- the copy make is
         about to compile is not the patched one"
say "    lib_string.c: registers string.pack/packsize/unpack once (asserted by content before make)"
# THE SIXTH TO THE TWELFTH, ROUND 3: Lua 5.3.6's bitwise operators with
# 64-bit results (native/luajit/oclj_features.h, OCLJ_OPS_BIT64).  Seven
# LuaJIT files, each patched by its own script:
#   lj_parse.c     patch-bitop-parse.sh    constant folding
#   vm_x64.dasc    patch-bitop-vm.sh       the interpreter's fast path
#   lj_meta.c      patch-bitop-meta.sh     the slow path, oclj_bitop_meta.c
#   lj_record.c    patch-bitop-record.sh   the recorder, oclj_bitop_rec.c
#   lj_opt_fold.c  patch-bitop-fold.sh     the fold engine, oclj_bitop_fold.c
#   lj_bcdump.h    patch-bitop-bcdump.sh   BCDUMP_VERSION 0x80
#   lib_jit.c      patch-bitop-jitlib.sh   jit.util's words unsigned, for
#                                          LuaJIT's own jit/*.lua tools
# and five tracked files copied next to them: those three, oclj_bitop.h (the
# rules) and oclj_num53.h (5.3.6's number readers, which oclj_strpack.c
# includes too, so it is copied before any make).  Same steps as the five
# above, per file: the pristine checkout asserted (no round-3 marker, none of
# the five files), the file re-copied, no round-3 marker after the copy,
# patched, its own script's marker exactly once and no other script's before
# make, and each include it gained present once; the five files copied and
# compared.  vm_x64.dasc MUST be re-copied for one more reason: `make clean`
# deletes host/buildvm_arch.h, and make regenerates it with DynASM from
# whatever vm_x64.dasc the copy holds.  After make: each object newer than
# its sources, buildvm_arch.h newer than vm_x64.dasc and lj_vm.o newer than
# it, DynASM's command line in the log, the patched comment lines echoed in
# buildvm_arch.h, no warning naming a round-3 file, the bitops gate and the
# jit tools gate.  The fast path is patched in vm_x64.dasc only; on another
# architecture DynASM would assemble an unpatched interpreter.
[ "$OCLJ_ARCH" = x86_64 ] || fail "round 3's interpreter fast path is patched in vm_x64.dasc only (native/luajit/patch-bitop-vm.sh):
         on $OCLJ_ARCH DynASM would assemble upstream's 32-bit bit operators, which the parser,
         the slow path and the JIT no longer agree with.  $OCLJ_ARCH is parked as unsupported."
BITOP_ANY='OC-LuaJIT (native/luajit/patch-bitop-'
BITOP_FILES='oclj_bitop.h oclj_bitop_meta.c oclj_bitop_rec.c oclj_bitop_fold.c oclj_num53.h'
BITOP_PATCHES='lj_parse.c:parse vm_x64.dasc:vm lj_meta.c:meta lj_record.c:record lj_opt_fold.c:fold lj_bcdump.h:bcdump lib_jit.c:jitlib'
for f in $BITOP_FILES; do
  [ -f "$OCLJ_REPO/native/luajit/$f" ] || fail "no $OCLJ_REPO/native/luajit/$f: round 3's bitwise operators"
  [ -e "$OCLJ_LUAJIT/src/$f" ] \
    && fail "$OCLJ_LUAJIT/src/$f exists: the pinned checkout must stay pristine.
         The file lives in native/luajit and is copied to the build copy only."
  cp -f "$OCLJ_REPO/native/luajit/$f" "$LJ/$f" || fail "cannot copy native/luajit/$f into $LJ"
  cmp -s "$OCLJ_REPO/native/luajit/$f" "$LJ/$f" \
    || fail "$LJ/$f differs from $OCLJ_REPO/native/luajit/$f right after the copy"
done
say "    $BITOP_FILES: copied from native/luajit and compared"
for p in $BITOP_PATCHES; do
  f=${p%%:*}
  s=patch-bitop-${p#*:}.sh
  grep -q -F -- "$BITOP_ANY" "$OCLJ_LUAJIT/src/$f" \
    && fail "$OCLJ_LUAJIT/src/$f carries a round-3 bit-operator patch: the pinned checkout must
         stay pristine.  The patch belongs on the build copy only."
  cp -f "$OCLJ_LUAJIT/src/$f" "$LJ/$f" \
    || fail "cannot re-copy the pristine $OCLJ_LUAJIT/src/$f over $LJ/$f"
  grep -q -F -- "$BITOP_ANY" "$LJ/$f" \
    && fail "$LJ/$f still carries a round-3 patch right after the pristine re-copy -- the copy did not take"
  sh "$OCLJ_REPO/native/luajit/$s" "$LJ/$f" "$LJ/$f" || fail "the round-3 patch $s refused (see above)"
  [ "$(grep -c -F -- "OC-LuaJIT (native/luajit/$s)" "$LJ/$f")" = "1" ] \
    && [ "$(grep -c -F -- "$BITOP_ANY" "$LJ/$f")" = "1" ] \
    || fail "$LJ/$f does not carry $s's marker exactly once and no other round-3 marker -- the
         copy make is about to compile is not the patched one"
done
for p in lj_parse.c:oclj_bitop.h lj_meta.c:oclj_bitop_meta.c lj_record.c:oclj_bitop.h \
         lj_record.c:oclj_bitop_rec.c lj_opt_fold.c:oclj_bitop.h lj_opt_fold.c:oclj_bitop_fold.c; do
  [ "$(grep -c -F -- '#include "'"${p#*:}"'"' "$LJ/${p%%:*}")" = "1" ] \
    || fail "$LJ/${p%%:*} does not include ${p#*:} exactly once -- the copy make is about to
         compile is not the patched one"
done
say "    lj_parse.c vm_x64.dasc lj_meta.c lj_record.c lj_opt_fold.c lj_bcdump.h lib_jit.c: pristine copies re-taken and patched (round 3; markers and includes asserted by content before make)"
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
[ -f "$LJ/lj_err.o" ] || fail "no $LJ/lj_err.o after make"
[ "$LJ/lj_err.o" -nt "$LJ/lj_err.c" ] \
  || fail "lj_err.o is not newer than the patched lj_err.c -- make did not recompile it"
grep -q 'lj_err\.c' "$OCLJ_BUILD/luajit_build.log" \
  || fail "lj_err.c never reached the compiler command line (log: $OCLJ_BUILD/luajit_build.log)"
say "    lj_err.o recompiled from the patched lj_err.c ($(date -r "$LJ/lj_err.o" +%H:%M:%S) > $(date -r "$LJ/lj_err.c" +%H:%M:%S))"
[ -f "$LJ/lj_ffrecord.o" ] || fail "no $LJ/lj_ffrecord.o after make"
[ "$LJ/lj_ffrecord.o" -nt "$LJ/lj_ffrecord.c" ] \
  || fail "lj_ffrecord.o is not newer than the patched lj_ffrecord.c -- make did not recompile it"
grep -q -F 'lj_ffrecord.c' "$OCLJ_BUILD/luajit_build.log" \
  || fail "lj_ffrecord.c never reached the compiler command line (log: $OCLJ_BUILD/luajit_build.log)"
say "    lj_ffrecord.o recompiled from the patched lj_ffrecord.c ($(date -r "$LJ/lj_ffrecord.o" +%H:%M:%S) > $(date -r "$LJ/lj_ffrecord.c" +%H:%M:%S))"
[ -f "$LJ/lib_string.o" ] || fail "no $LJ/lib_string.o after make"
[ "$LJ/lib_string.o" -nt "$LJ/lib_string.c" ] && [ "$LJ/lib_string.o" -nt "$LJ/oclj_strpack.c" ] \
  && [ "$LJ/lib_string.o" -nt "$LJ/oclj_num53.h" ] \
  || fail "lib_string.o is not newer than the patched lib_string.c, oclj_strpack.c and the
         oclj_num53.h it includes -- make did not recompile it"
# Anchored on the compile line itself, which ends '-c -o lib_string.o
# lib_string.c' (BUILDMODE=static: the Makefile's dynamic compile is '@:', so
# this is the only one echoed).  The bare name would not do: buildvm's five
# command lines list every LJLIB_C file, lib_string.c included, on every build.
# On Windows mingw32-make echoes command lines with CRLF (95 of the log's 185
# lines, this one included), so the pattern allows that one CR explicitly
# rather than relying on Git Bash's grep 3.0 dropping it before '$'.
grep -q -E -- '-c -o lib_string[.]o lib_string[.]c[[:cntrl:]]?$' "$OCLJ_BUILD/luajit_build.log" \
  || fail "lib_string.c never reached the compiler command line (log: $OCLJ_BUILD/luajit_build.log)"
# buildvm turned the three registrations into fast functions: one FFDEF each
# in the generated table (lj_ffdef.h is regenerated, `make clean` deletes it).
for ff in string_pack string_packsize string_unpack; do
  [ "$(grep -c -x -F "FFDEF($ff)" "$LJ/lj_ffdef.h" 2>/dev/null)" = "1" ] \
    || fail "$LJ/lj_ffdef.h does not list FFDEF($ff) exactly once: buildvm did not register
         the function (is the registration inside lib_string.c's string module?)"
done
# The LuaJIT compile is -Wall; nothing of ours may warn there either.
if grep -E '(lib_string|oclj_strpack)[.]c:[0-9]+(:[0-9]+)?: warning' "$OCLJ_BUILD/luajit_build.log"; then
  fail "lib_string.c or oclj_strpack.c warned in the LuaJIT build (above)"
fi
say "    lib_string.o recompiled with string.pack/packsize/unpack (FFDEF x3 in lj_ffdef.h, no warnings)"
# Round 3's objects (THE SIXTH TO THE TWELFTH, above): each newer than its
# patched source and every round-3 file it includes, and its compile line in
# the log, anchored as lib_string.c's is.  lj_bcwrite.o writes the dump's
# version byte and lj_bcread.o refuses any other (lj_bcwrite.c:397,
# lj_bcread.c:400), so both must be newer than the patched lj_bcdump.h.
# lib_jit.o is jit.util (patch-bitop-jitlib.sh).
for p in lj_parse:lj_parse.c,oclj_bitop.h,oclj_num53.h \
         lj_meta:lj_meta.c,oclj_bitop_meta.c,oclj_bitop.h,oclj_num53.h \
         lj_record:lj_record.c,oclj_bitop_rec.c,oclj_bitop.h,oclj_num53.h \
         lj_opt_fold:lj_opt_fold.c,oclj_bitop_fold.c,oclj_bitop.h,oclj_num53.h \
         lj_bcwrite:lj_bcwrite.c,lj_bcdump.h lj_bcread:lj_bcread.c,lj_bcdump.h \
         lib_jit:lib_jit.c; do
  o=${p%%:*}
  [ -f "$LJ/$o.o" ] || fail "no $LJ/$o.o after make"
  for src in $(echo "${p#*:}" | tr ',' ' '); do
    # -f first: test's -nt is true when the second file is missing.
    [ -f "$LJ/$src" ] && [ "$LJ/$o.o" -nt "$LJ/$src" ] \
      || fail "$o.o is not newer than $src (or $src is missing) -- make did not recompile it from round 3's sources"
  done
  grep -q -E -- '-c -o '"$o"'[.]o '"$o"'[.]c[[:cntrl:]]?$' "$OCLJ_BUILD/luajit_build.log" \
    || fail "$o.c never reached the compiler command line (log: $OCLJ_BUILD/luajit_build.log)"
done
# And the patched vm_x64.dasc reached the interpreter: DynASM regenerated
# host/buildvm_arch.h from it (its command line in the log, CRLF-tolerant
# like lib_string.c's), buildvm made lj_vm.o from that (on ELF through
# lj_vm.S), and since DynASM echoes every line of the .dasc into
# buildvm_arch.h as a //| comment, the patch's three OC-LuaJIT comment lines
# -- one per hunk, two of them saying "OC-LuaJIT: Lua 5.3's" -- are there.
[ -f "$LJ/host/buildvm_arch.h" ] || fail "no $LJ/host/buildvm_arch.h after make"
[ "$LJ/host/buildvm_arch.h" -nt "$LJ/vm_x64.dasc" ] \
  || fail "host/buildvm_arch.h is not newer than the patched vm_x64.dasc -- DynASM did not regenerate it"
grep -q -E -- '-o host/buildvm_arch[.]h vm_x64[.]dasc[[:cntrl:]]?$' "$OCLJ_BUILD/luajit_build.log" \
  || fail "DynASM's command line for vm_x64.dasc is not in the log (log: $OCLJ_BUILD/luajit_build.log)"
[ "$LJ/lj_vm.o" -nt "$LJ/host/buildvm_arch.h" ] \
  || fail "lj_vm.o is not newer than host/buildvm_arch.h -- buildvm did not rebuild the interpreter"
if [ -f "$LJ/lj_vm.S" ]; then
  [ "$LJ/lj_vm.S" -nt "$LJ/host/buildvm_arch.h" ] && [ "$LJ/lj_vm.o" -nt "$LJ/lj_vm.S" ] \
    || fail "lj_vm.S / lj_vm.o are not newer than host/buildvm_arch.h -- the interpreter was not rebuilt"
fi
VM_OC=$(grep -c -F 'OC-LuaJIT' "$LJ/vm_x64.dasc")
ARCH_OC=$(grep -c -E '^[[:space:]]*//[|].*OC-LuaJIT' "$LJ/host/buildvm_arch.h")
ARCH_53=$(grep -c -E "^[[:space:]]*//[|].*OC-LuaJIT: Lua 5[.]3's" "$LJ/host/buildvm_arch.h")
[ "$VM_OC" = "3" ] && [ "$ARCH_OC" = "3" ] && [ "$ARCH_53" = "2" ] \
  || fail "host/buildvm_arch.h echoes $ARCH_OC OC-LuaJIT comment lines ($ARCH_53 of them
         'OC-LuaJIT: Lua 5.3's'), vm_x64.dasc carries $VM_OC: want 3, 2 and 3.  DynASM did
         not assemble the patched vm_x64.dasc (native/luajit/patch-bitop-vm.sh)."
# The LuaJIT compile is -Wall: no round-3 file may warn there.
if grep -E '(lj_parse|lj_meta|lj_record|lj_opt_fold|lj_bcwrite|lj_bcread|lib_jit|oclj_[a-z0-9_]+)[.][ch]:[0-9]+(:[0-9]+)?: warning' "$OCLJ_BUILD/luajit_build.log"; then
  fail "a file round 3 patched or added warned in the LuaJIT build (above)"
fi
say "    round 3: lj_parse.o lj_meta.o lj_record.o lj_opt_fold.o lj_bcwrite.o lj_bcread.o lib_jit.o recompiled; buildvm_arch.h regenerated from the patched vm_x64.dasc ($ARCH_OC OC-LuaJIT lines echoed); no warnings"

# THE FEATURE SET HAS ONE CHANNEL, AND IT MUST BE OBSERVABLE (THE LUAJIT
# FEATURE SET, in the header).  First: no feature macro may reach a LuaJIT
# compile line -- a second copy of the set on a command line is exactly how
# the archive and our translation units drifted apart (until 2026-10-16 the
# archive had LUA52COMPAT and the shim, compiled without it, did not).  The
# Makefile's own -DLUAJIT_TARGET, and LUAJIT_UNWIND_EXTERNAL on Linux, are
# platform facts, not features, and are allowed.  An ALLOWLIST: every other
# LUAJIT_* on a compile line is refused, with or without a space after -D,
# including the ones the header does not name.
G3BAD=$(grep -oE -- '-D *LUAJIT_[A-Za-z0-9_]+' "$OCLJ_BUILD/luajit_build.log" | tr -d ' ' \
  | grep -vxE -- '-DLUAJIT_(TARGET|UNWIND_EXTERNAL)' | sort | uniq -c)
if [ -n "$G3BAD" ]; then
  echo "$G3BAD"
  fail "a LuaJIT feature macro reached the compiler command line (counted above).  The
         feature set has ONE channel, native/luajit/oclj_features.h; a second copy on a
         command line is how the archive and our translation units drift apart."
fi
# Second: the preprocessor's verdict, through exactly the -I every translation
# unit of ours compiles with.  OCLJ_LUAJIT_FEATURES says the header was read;
# the LJ_* values say what it decided.
LJDM=$("$CC" -I"$LJ" -E -dM "$LJ/lj_arch.h" 2>&1)
for d in 'OCLJ_LUAJIT_FEATURES 1' 'LJ_52 1' 'LJ_HASFFI 0' 'LJ_HASJIT 1' 'LJ_GC64 1' 'OCLJ_LIB_STRPACK 1' 'OCLJ_OPS_BIT64 1'; do
  printf '%s\n' "$LJDM" | grep -qx "#define $d" \
    || fail "through -I$LJ the preprocessor does not say '#define $d'.  Every translation
         unit of ours compiles through exactly that -I: native/luajit/oclj_features.h is
         not reaching lj_arch.h, or it no longer says what this build needs."
done
say "    feature set through -I\$LJ (lj_arch.h -dM): OCLJ_LUAJIT_FEATURES 1, LJ_52 1, LJ_HASFFI 0, LJ_HASJIT 1, LJ_GC64 1, OCLJ_LIB_STRPACK 1, OCLJ_OPS_BIT64 1"
# And the bytecode version every translation unit of ours sees (serializer/
# eris_lj.c refuses to compile with OCLJ_OPS_BIT64 and a version below 0x80):
# native/luajit/patch-bitop-bcdump.sh's 0x80, through the same -I.
LJDMB=$("$CC" -I"$LJ" -E -dM "$LJ/lj_bcdump.h" 2>&1)
printf '%s\n' "$LJDMB" | grep -qx '#define BCDUMP_VERSION 0x80' \
  || fail "through -I$LJ the preprocessor does not say '#define BCDUMP_VERSION 0x80' for
         lj_bcdump.h ($(printf '%s\n' "$LJDMB" | grep 'BCDUMP_VERSION' | head -1)): round 3's
         operators change what bytecode means, and a dump must say so"
say "    lj_bcdump.h -dM: BCDUMP_VERSION 0x80"
# oclj_strpack.c under -Wall -Wextra, as the shim is held to (the LuaJIT
# compile above is -Wall only): a throwaway translation unit that includes it
# and calls its three entry points, compiled through the same -I.
cat > "$OCLJ_BUILD/strpack_wgate.c" <<'EOF'
#include "oclj_strpack.c"
int oclj_strpack_wgate(lua_State *L);
int oclj_strpack_wgate(lua_State *L)
{
  return oclj_strpack_pack(L) + oclj_strpack_packsize(L) + oclj_strpack_unpack(L);
}
EOF
rm -f "$OCLJ_BUILD/strpack_wgate.o"
"$CC" -c -O2 $PICFLAG -Wall -Wextra -I"$LJ" "$OCLJ_BUILD/strpack_wgate.c" \
  -o "$OCLJ_BUILD/strpack_wgate.o" 2>"$OCLJ_BUILD/strpack.err"
[ -f "$OCLJ_BUILD/strpack_wgate.o" ] || { cat "$OCLJ_BUILD/strpack.err"; fail "oclj_strpack.c did not compile on its own"; }
PW=$(grep -c 'warning:' "$OCLJ_BUILD/strpack.err" || true)
say "    oclj_strpack.c -Wall -Wextra warnings = $PW"
[ "$PW" = "0" ] || { grep -E 'warning:' "$OCLJ_BUILD/strpack.err" | head -20; fail "oclj_strpack.c must compile warning-clean"; }
# Round 3's C files under -Wall -Wextra likewise: one throwaway translation
# unit with the union of the headers lj_meta.c, lj_record.c and lj_opt_fold.c
# include, the IR and emitir macros oclj_bitop_rec.c and oclj_bitop_fold.c
# expect from lj_record.c and lj_opt_fold.c, the three .c files, and one
# function that calls their entry points and oclj_bitop.h's and
# oclj_num53.h's functions (an uncalled static inline function is never
# compiled, so the warnings that need code generation would miss it).
cat > "$OCLJ_BUILD/bitop_wgate.c" <<'EOF'
#define LUA_CORE
#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_err.h"
#include "lj_buf.h"
#include "lj_str.h"
#include "lj_tab.h"
#include "lj_meta.h"
#include "lj_frame.h"
#include "lj_bc.h"
#include "lj_ff.h"
#include "lj_debug.h"
#include "lj_ir.h"
#include "lj_jit.h"
#include "lj_ircall.h"
#include "lj_iropt.h"
#include "lj_trace.h"
#include "lj_record.h"
#include "lj_ffrecord.h"
#include "lj_snap.h"
#include "lj_dispatch.h"
#include "lj_vm.h"
#include "lj_strscan.h"
#include "lj_strfmt.h"
#include "lj_lib.h"
#include "oclj_bitop.h"
#define IR(ref) (&J->cur.ir[(ref)])
#define emitir(ot, a, b) (lj_ir_set(J, (ot), (a), (b)), lj_opt_fold(J))
#include "oclj_bitop_meta.c"
#include "oclj_bitop_rec.c"
#include "oclj_bitop_fold.c"
int oclj_bitop_wgate(lua_State *L, jit_State *J, TValue *o);
int oclj_bitop_wgate(lua_State *L, jit_State *J, TValue *o)
{
  int64_t k = 0;
  double d = 0;
  oclj_meta_bitop(L, o, o, o, BC_BAND);
  return (int)oclj_rec_bitop(J, BC_BSHL, 0, 0, o, o) + oclj_bitwidth(J, 0, 0) +
    oclj_bit2num(oclj_bitop64(BC_BSAR, 1, 2), &d) + oclj_flt2int(d, &k) +
    oclj_str2int("1", 1, &k) + oclj_str2d("1", 1, &d) + (int)oclj_u2s(1);
}
EOF
rm -f "$OCLJ_BUILD/bitop_wgate.o"
"$CC" -c -O2 $PICFLAG -Wall -Wextra -I"$LJ" "$OCLJ_BUILD/bitop_wgate.c" \
  -o "$OCLJ_BUILD/bitop_wgate.o" 2>"$OCLJ_BUILD/bitop.err"
[ -f "$OCLJ_BUILD/bitop_wgate.o" ] || { cat "$OCLJ_BUILD/bitop.err"; fail "round 3's oclj_bitop*.{h,c} and oclj_num53.h did not compile on their own"; }
BW=$(grep -c 'warning:' "$OCLJ_BUILD/bitop.err" || true)
say "    oclj_bitop.h, oclj_bitop_meta.c, oclj_bitop_rec.c, oclj_bitop_fold.c, oclj_num53.h -Wall -Wextra warnings = $BW"
[ "$BW" = "0" ] || { grep -E 'warning:' "$OCLJ_BUILD/bitop.err" | head -20; fail "round 3's C files must compile warning-clean"; }

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

# FFI COMPILED OUT, AND string.format's INTEGER CONVERSIONS STILL COMPILED,
# functionally, on the luajit.exe that links this libluajit.a.  The line it
# prints must be exactly NF_WANT (the fail message says what each field
# means).  The probe never calls pcall(require, "ffi"): a stray ffi.lua on a
# search path would answer that.  It checks the lexer (`1LL`), the preload
# luaL_openlibs would register, and the registry entry the lexer's on-demand
# load used to leave.
cat > "$OCLJ_BUILD/noffi.lua" <<'EOF'
local f, e = load("return 1LL", "=lit")
local lit = f and "ACCEPTED" or (tostring(e):find("malformed number", 1, true) and "refused" or "other")
f = nil
local jutil = require("jit.util")
local fmt = string.format
local s = string.rep(string.char(0, 1, 127, 128, 200, 255), 400)
local function arm(hot)
  local st, mine = { loop = 0, stitch = 0, abort = 0 }, {}
  local function cb(what, tr, func)
    if what == "start" then mine[tr] = (func == hot)
    elseif what == "stop" and mine[tr] then
      local lt = jutil.traceinfo(tr).linktype
      if st[lt] then st[lt] = st[lt] + 1 end
    elseif what == "abort" and mine[tr] then st.abort = st.abort + 1 end
  end
  jit.flush()
  jit.attach(cb, "trace")
  local out = hot(s)
  jit.attach(cb)
  return st.loop .. "/" .. st.stitch .. "/" .. st.abort, out
end
local function hs(str) local n = 0 for i = 1, #str do n = n + #fmt("%s", str:byte(i)) end return n end
local function hx(str) local t = {} for i = 1, #str do local v = str:byte(i) - 128
  t[#t + 1] = fmt("%02x|%X|%#o|%u|%5d|%+d|%-4i;", v, v, v, v, v, v, v) end return table.concat(t) end
local function hi(str) local t = {} for i = 1, #str do local v = str:byte(i) - 128
  t[#t + 1] = fmt("%02x|%X|%#o|%u|%5d|%+d|%-4i;", v, v, v, v, v, v, v) end return table.concat(t) end
jit.off(hi)
local sres = arm(hs)
local xres, xout = arm(hx)
print("lit=" .. lit .. " preload=" .. tostring(package.preload.ffi) .. " loaded=" .. tostring(package.loaded.ffi) ..
  " s=" .. sres .. " x=" .. xres .. " same=" .. tostring(xout == hi(s)))
EOF
NF=$("$LJEXE" "$OCLJ_BUILD/noffi.lua" 2>&1)
say "    FFI / integer-format gate: $NF"
NF_WANT='lit=refused preload=nil loaded=nil s=0/1/0 x=1/0/0 same=true'
[ "$NF" = "$NF_WANT" ] || fail "the FFI / integer-format gate read
           $NF
         want
           $NF_WANT
         lit, preload, loaded other than refused, nil, nil: FFI is compiled IN -- the
           lexer mints cdata from 1LL and loads ffi (native/luajit/oclj_features.h did not
           reach the archive).
         s other than 0/1/0: the trace detector did not see the stitch every build makes
           for %s of a number, so this gate proved nothing.
         x other than 1/0/0: string.format's integer conversions stitch or abort instead
           of compiling (native/luajit/patch-strfmt-xint-noffi.sh is not in effect): a
           hot %x, %o, %u or %5d of an int runs up to about 2x slower.
         same=false: the compiled output differs from the interpreter's."
# And no FFI entry point in the archive.  The reader is checked first: an nm
# that printed nothing would make the absence check pass vacuously.
LJSYMS=$(nm "$LJ/libluajit.a" 2>/dev/null)
printf '%s\n' "$LJSYMS" | grep -qE ' T lua_newstate$' \
  || fail "nm lists no 'T lua_newstate' in $LJ/libluajit.a: the symbol reader is not
         working, and the FFI-symbol check below would pass vacuously"
if printf '%s\n' "$LJSYMS" | grep -qE ' T (luaopen_ffi|lj_ccallback_new)$'; then
  printf '%s\n' "$LJSYMS" | grep -E ' T (luaopen_ffi|lj_ccallback_new)$'
  fail "libluajit.a defines FFI entry points (above): FFI is compiled in"
fi
say "    libluajit.a: lua_newstate defined; luaopen_ffi and lj_ccallback_new not (FFI compiled out)"

# string.pack, string.packsize AND string.unpack ARE IN THE STRING LIBRARY,
# functionally, on the luajit.exe that links this libluajit.a: present, reached
# through the string metatable as ("fmt"):pack, the two decided deviations
# (an I8 field of 2^63-1 rounds to 2^63; 'l' and 'L' are 8 bytes), one bounds
# refusal and one argument refusal by message, and a hot loop of pack calls
# that the JIT stitches around without aborting (an abort per call would
# blacklist the caller's loop).  The probe prints the loop/stitch/abort counts
# of the traces recorded in hot() and the gate requires the measured 0/1/0, as
# the FFI gate above requires s=0/1/0: hot= and abort= alone read 14000 and 0
# with the JIT off as well, so without the stitch count the gate would pass
# with no trace recorded at all.  The full conformance and differential tests
# are test/native/run-pack.sh and run-packfuzz.sh.  The probe contains no
# backslashes (heredocs here eat them).
cat > "$OCLJ_BUILD/strpack.lua" <<'EOF'
local P, U, S = string.pack, string.unpack, string.packsize
local fn = type(P) .. "/" .. type(U) .. "/" .. type(S)
if fn ~= "function/function/function" then print("fn=" .. fn) return end
local function hex(s) local t = {} for i = 1, #s do t[i] = string.format("%02x", s:byte(i)) end return table.concat(t) end
local b = P("<i4", -2)
local v, nx = U("<i4", b)
local big = U("<I8", string.rep(string.char(255), 7) .. string.char(127))
local ok1, e1 = pcall(U, "<i4", "abc")
local ok2, e2 = pcall(P, "<j", 1.5)
local jutil = require("jit.util")
local st, mine = { loop = 0, stitch = 0, abort = 0 }, {}
local function hot(n) local acc = 0 for i = 1, n do acc = acc + #P("<i4 z", i, "ab") end return acc end
local function cb(what, tr, func)
  if what == "start" then mine[tr] = (func == hot)
  elseif what == "stop" and mine[tr] then
    local lt = jutil.traceinfo(tr).linktype
    if st[lt] then st[lt] = st[lt] + 1 end
  elseif what == "abort" and mine[tr] then st.abort = st.abort + 1 end
end
jit.flush()
jit.attach(cb, "trace")
local acc = hot(2000)
jit.attach(cb)
print("fn=" .. fn .. " i4=" .. hex(b) .. " method=" .. tostring(("<i4"):pack(-2) == b) ..
  " u=" .. v .. "/" .. nx .. " I8max=" .. tostring(big == 2^63) .. " l=" .. S("l") .. "/" .. S("<L") ..
  " short=" .. tostring(not ok1 and e1:find("data string too short", 1, true) ~= nil) ..
  " int=" .. tostring(not ok2 and e2:find("number has no integer representation", 1, true) ~= nil) ..
  " hot=" .. acc .. " jit=" .. st.loop .. "/" .. st.stitch .. "/" .. st.abort)
EOF
SP=$("$LJEXE" "$OCLJ_BUILD/strpack.lua" 2>&1)
say "    string.pack gate: $SP"
SP_WANT='fn=function/function/function i4=feffffff method=true u=-2/5 I8max=true l=8/8 short=true int=true hot=14000 jit=0/1/0'
[ "$SP" = "$SP_WANT" ] || fail "the string.pack gate read
           $SP
         want
           $SP_WANT
         fn other than function/function/function: lib_string.c does not register them
           (native/luajit/patch-strpack-register.sh did not reach the archive).
         i4, method, u, short, int: native/luajit/oclj_strpack.c is not Lua 5.3.6's pack.
         I8max=false: an unpacked integer beyond 2^53 is refused or not rounded to nearest.
         l other than 8/8: 'l'/'L' follow sizeof(long), 4 on Win64 -- decided: 8 everywhere.
         hot other than 14000: a compiled loop of pack calls computes something else.
         jit (loop/stitch/abort traces recorded in hot()) other than 0/1/0:
           a stitch count of 0 means no trace was recorded in hot(), so the gate
           proved nothing about the JIT; a stitch count above 1 means the trace was
           re-recorded (flushed, or a side exit went hot); an abort count other than 0 means the
           JIT aborts traces at pack calls, which blacklists loops; a loop count
           other than 0 means the recorder no longer stitches at the pack call (the
           three have no LJLIB_REC): re-measure before changing the gate."

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

# --------------------------------------------------------------- 1b
# TWO PROPERTIES OF THE ARCHIVE, ONE PROBE.
#
# THE FOREIGN ALLOCATOR.  The shim creates the state with its OWN allocf,
# lj52_alloc (lua_newstate), and never swaps it, so no block ever changes
# allocators; since 2026-10-02 the blocks underneath live in a per-state
# lj_alloc arena (lj52_back).  Only a GC64 build accepts a caller-supplied
# allocf on x64.  This probe proves that property with a plain realloc/free
# allocf -- the property, not our allocator -- at build time rather than as a
# machine running unaccounted.
#
# THE LAYOUT GATE.  lua_newstate's first allocator call is the GG_State
# (lj_state.c:269), so its size is the archive's own answer to "which feature
# set was I built with?".  The probe includes lj_obj.h and lj_dispatch.h
# through -I"$LJ" -- the exact view lj52shim.c and eris_lj.c compile with --
# and fails unless sizeof(GG_State) there is the same number.  Until
# 2026-10-16 it included only <lua.h>, so it could not see layout: linked
# against a no-FFI archive it still printed FOREIGN-ALLOC-OK (measured
# 2026-10-16; HEAD's own archive and shim agreed, 6384 both).  The NEGATIVE ARM
# compiles the same probe against a copy of those headers whose
# oclj_features.h lacks '#define LUAJIT_DISABLE_FFI 1', and must MISMATCH
# (6384 against 6376 on Windows x64): a gate never seen to fail proves
# nothing, so this one is seen to fail on every build.  lj52_newstate makes
# the same comparison at run time, for objects this script did not compile.
say "=============== 1b. GC64 / foreign-allocator / layout gate ==============="
cat > "$OCLJ_BUILD/allocprobe.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <lua.h>
#include "lj_obj.h"
#include "lj_dispatch.h"
#ifndef OCLJ_LUAJIT_FEATURES
#error "this LuaJIT tree's lj_arch.h does not include oclj_features.h"
#endif
static unsigned long calls = 0;
static size_t first = 0;
static void *a(void *ud, void *p, size_t o, size_t n) {
  (void)ud; (void)o;
  if (calls++ == 0 && p == NULL) first = n;
  if (n == 0) { free(p); return NULL; }
  return realloc(p, n);
}
int main(void) {
  lua_State *L = lua_newstate(a, NULL);
  if (!L) { printf("FOREIGN-ALLOC-REFUSED\n"); return 1; }
  lua_close(L);
  if (first != sizeof(GG_State)) {
    printf("GG-LAYOUT-MISMATCH lib=%lu tu=%lu\n", (unsigned long)first, (unsigned long)sizeof(GG_State));
    return 2;
  }
  printf("FOREIGN-ALLOC-OK GG=%lu\n", (unsigned long)first);
  return 0;
}
EOF
"$CC" -O0 -I"$LJ" "$OCLJ_BUILD/allocprobe.c" "$LJ/libluajit.a" -lm \
  -o "$OCLJ_BUILD/allocprobe.exe" >"$OCLJ_BUILD/allocprobe.err" 2>&1 \
  || { head -5 "$OCLJ_BUILD/allocprobe.err"; fail "allocator/layout probe would not compile or link"; }
PROBE=$("$OCLJ_BUILD/allocprobe.exe" 2>&1)
say "    $PROBE"
case "$PROBE" in
  "FOREIGN-ALLOC-OK GG="[0-9]*)
    LJ_GG=${PROBE#FOREIGN-ALLOC-OK GG=} ;;
  "FOREIGN-ALLOC-REFUSED"*)
    fail "this LuaJIT refuses a foreign allocator (non-GC64 x64 build).
         lj52_newstate() would fall back to luaL_newstate: a state on LuaJIT's
         internal allocator with no accounting record, the RAM cap silently
         unenforced (_OCLJ_GCSTATS heap = -1; the harness's b2 and al-1 fail)." ;;
  "GG-LAYOUT-MISMATCH"*)
    fail "LAYOUT: $PROBE -- libluajit.a laid out a GG_State of a different size than
         the headers every translation unit of ours compiles against (-I$LJ).  The
         shim and the serializer would read jit_State at the wrong offset." ;;
  *)
    fail "the allocator/layout probe said '$PROBE'" ;;
esac
case $LJ_GG in ''|*[!0-9]*) fail "the allocator/layout probe said '$PROBE'" ;; esac
NEGI=$OCLJ_BUILD/layoutneg-$PLATFORM
rm -rf "$NEGI"
mkdir -p "$NEGI" || fail "cannot create $NEGI"
cp "$LJ"/*.h "$NEGI"/ || fail "cannot copy $LJ/*.h for the layout gate's negative arm"
grep -qx '#define LUAJIT_DISABLE_FFI 1' "$LJ/oclj_features.h" \
  || fail "oclj_features.h no longer says '#define LUAJIT_DISABLE_FFI 1'; the layout gate's
         negative arm toggles exactly that line.  Revisit the arm with the feature set."
grep -vx '#define LUAJIT_DISABLE_FFI 1' "$LJ/oclj_features.h" > "$NEGI/oclj_features.h"
cmp -s "$LJ/oclj_features.h" "$NEGI/oclj_features.h" \
  && fail "the layout gate's negative arm: the header toggle did not take"
"$CC" -O0 -I"$NEGI" "$OCLJ_BUILD/allocprobe.c" "$LJ/libluajit.a" -lm \
  -o "$OCLJ_BUILD/allocprobe-neg.exe" >"$OCLJ_BUILD/allocprobe-neg.err" 2>&1 \
  || { head -5 "$OCLJ_BUILD/allocprobe-neg.err"; fail "the layout gate's negative arm would not compile or link"; }
NPROBE=$("$OCLJ_BUILD/allocprobe-neg.exe" 2>&1)
case "$NPROBE" in
  "GG-LAYOUT-MISMATCH lib=$LJ_GG tu="[0-9]*)
    say "    negative arm (FFI toggled back on in a header copy): $NPROBE -- the gate can fail" ;;
  *)
    fail "THE LAYOUT GATE CANNOT FAIL: compiled for a LuaJIT WITH FFI, against this
         archive, the probe said '$NPROBE'" ;;
esac

# --------------------------------------------------------------- 2
say "=============== 2. lj52shim.c ==============="
rm -f "$OBJ/lj52shim.o"
# -I the JDK headers: the shim includes <jni.h> so its allocator can use
# jnlua's own getluamemory/setluamemory to publish the machine's RAM use.
# -DLJ52_ADDITIVE compiles in the four JNI natives LuaStateLuaJIT declares: two
# for the accounting's Java boundary (docs/accounting-sync.md) and two for Value
# disposal (THE VALUE FINALIZER in lj52shim.c).  The dropin backs OpenComputers'
# own LuaState, which declares none of them, so it must not export them.
SHIMDEF=
[ "$OCLJ_VARIANT" = additive ] && SHIMDEF=-DLJ52_ADDITIVE
# -I"$LJ" is also how the shim gets LuaJIT's feature set (THE LUAJIT FEATURE
# SET): no -D here, and lj52shim.c refuses to compile without it.
"$CC" -c -O2 $PICFLAG -Wall -Wextra $SHIMDEF -I"$LJ" -I"$OCLJ_SHIM" -I"$OCLJ_SER" \
  -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" \
  "$OCLJ_SHIM/lj52shim.c" -o "$OBJ/lj52shim.o" 2>"$OCLJ_BUILD/shim.err"
[ -f "$OBJ/lj52shim.o" ] || { cat "$OCLJ_BUILD/shim.err"; fail "shim did not compile"; }
SW=$(grep -c 'warning:' "$OCLJ_BUILD/shim.err" || true)
say "    -Wall -Wextra warnings = $SW"
[ "$SW" = "0" ] || { grep -E 'warning:' "$OCLJ_BUILD/shim.err" | head -20; fail "the shim must compile warning-clean"; }
# The per-state lj_alloc arena (lj52_back) binds to LuaJIT internals.  Prove
# the object references them, so a change that quietly drops every state back
# onto the C library -- measured up to 2.6x slower on allocation-heavy code --
# cannot pass the build.  (The pre-arena object, 8ef84b32, references none.)
for sym in lj_alloc_create lj_alloc_f lj_alloc_destroy lj_alloc_setprng lj_prng_seed_secure; do
  nm -u "$OBJ/lj52shim.o" 2>/dev/null | grep -qw "$sym" \
    || fail "lj52shim.o does not reference $sym: the per-state lj_alloc arena (lj52_back) is gone"
done
say "    lj_alloc arena symbols referenced: lj_alloc_create, lj_alloc_f, lj_alloc_destroy, lj_alloc_setprng, lj_prng_seed_secure"
# THE SHIM'S JAVA BOUNDARY: the accounting's (docs/accounting-sync.md) and Value
# disposal's (THE VALUE FINALIZER in lj52shim.c).  The four cores are in every
# build -- the native tests drive them with no JVM -- and the four JNI natives
# over them only in the additive, the one whose class declares them.  Counted on
# the OBJECT, before any link: a shim that lost them, or a dropin that grew
# them, is named here rather than as an export count.
for sym in lj52_mem_used lj52_mem_settotal; do
  nm --defined-only "$OBJ/lj52shim.o" 2>/dev/null | grep -qw "$sym" \
    || fail "lj52shim.o does not define $sym: the accounting's C side (docs/accounting-sync.md) is gone"
done
for sym in lj52_vgc_install lj52_vgc_counters; do
  nm --defined-only "$OBJ/lj52shim.o" 2>/dev/null | grep -qw "$sym" \
    || fail "lj52shim.o does not define $sym: Value disposal's C side (THE VALUE FINALIZER) is gone"
done
NOCLJ=$(nm --defined-only "$OBJ/lj52shim.o" 2>/dev/null | grep -cE 'Java_li_cil_repack_com_naef_jnlua_LuaStateLuaJIT_oclj(UsedMemory|SetTotalMemory|InstallValueFinalizer|ValueGcCounters)$' || true)
if [ "$OCLJ_VARIANT" = additive ]; then
  [ "$NOCLJ" = "4" ] || fail "the additive lj52shim.o defines $NOCLJ of the 4 oclj natives
         (ocljUsedMemory, ocljSetTotalMemory, ocljInstallValueFinalizer,
         ocljValueGcCounters): LuaStateLuaJIT would throw UnsatisfiedLinkError
         from its capped constructor, or every machine start would log Value
         disposal as uninstalled and leak dropped handles until reboot"
else
  [ "$NOCLJ" = "0" ] || fail "the dropin lj52shim.o defines $NOCLJ oclj natives of LuaStateLuaJIT, a class it does not back"
fi
say "    Java boundary: lj52_mem_used, lj52_mem_settotal, lj52_vgc_install, lj52_vgc_counters defined; LuaStateLuaJIT oclj* natives = $NOCLJ (variant=$OCLJ_VARIANT)"

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
  # THE CLASS THIS LIBRARY BACKS MUST BE THE GENERATOR'S OUTPUT, BYTE FOR BYTE.
  # LuaStateLuaJIT.java declares the natives this build exports -- jnlua's 82,
  # redeclared, the accounting's two and Value disposal's two -- and is
  # generated from this same OC-JNLua checkout.  A hand edit, or a generator change
  # never regenerated, would pair a class and a library that disagree, to be found
  # at best as an UnsatisfiedLinkError in a player's game.
  GEN_PY=
  for c in "${OCLJ_PYTHON:-}" python3 python; do
    [ -n "$c" ] || continue
    [ "$("$c" -c 'print(6*7, end="")' 2>/dev/null)" = "42" ] && { GEN_PY=$c; break; }
  done
  [ -n "$GEN_PY" ] || fail "no working Python (python3 or python; or set OCLJ_PYTHON): the additive
         build regenerates LuaStateLuaJIT.java to check the committed copy"
  GEN_JAVA="$OCLJ_REPO/src/main/java/li/cil/repack/com/naef/jnlua/LuaStateLuaJIT.java"
  rm -f "$OCLJ_BUILD/LuaStateLuaJIT.regen.java"
  "$GEN_PY" "$OCLJ_REPO/native/jnlua/gen-luastate-subclass.py" "$OCLJ_JNLUA" "$OCLJ_BUILD/LuaStateLuaJIT.regen.java" >/dev/null \
    || fail "gen-luastate-subclass.py refused (see above)"
  cmp -s "$OCLJ_BUILD/LuaStateLuaJIT.regen.java" "$GEN_JAVA" \
    || fail "$GEN_JAVA is not what native/jnlua/gen-luastate-subclass.py emits from
         $OCLJ_JNLUA (diff it against $OCLJ_BUILD/LuaStateLuaJIT.regen.java).
         Edit the generator, never the class, and regenerate."
  say "    LuaStateLuaJIT.java == the generator's output ($GEN_PY)"
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
# lj52_load keeps it shut to sandbox code (allowBytecode=false).  -I"$LJ"
# carries the feature set here too; eris_lj.c refuses to compile without it.
# The object is judged by [ -f ] below, so the last build's must go first: gcc
# leaves an existing -o target in place when a compile fails, and the word
# check and the link would take it.
rm -f "$OBJ/eris_lj.o"
"$CC" -c -O2 $PICFLAG -I"$LJ" -I"$OCLJ_SER" -DERIS_LJ_COMMIT="\"$LJ_COMMIT\"" \
  -DERIS_LJ_SERHASH="\"$SER_HASH\"" \
  "$OCLJ_SER/eris_lj.c" -o "$OBJ/eris_lj.o" 2>"$OCLJ_BUILD/eris.err"
[ -f "$OBJ/eris_lj.o" ] || { grep -oE 'error: .*' "$OCLJ_BUILD/eris.err" | head -20; fail "eris_lj.c did not compile"; }
# THE VM-FEATURES WORD, checked against the library rather than trusted.  The
# blob fingerprint ends in a word eris_lj.c derives from the macros it was
# compiled with (THE VM-FEATURES WORD in eris_lj.c: ffi, lua52, gc64, fr2, dn,
# le/be, p64/p32, pack, bit); blobs carry it, and a build that cannot
# interpret a blob refuses it by that word.  Six of its tokens show in the
# behaviour of the luajit.exe that links this libluajit.a: whether `1LL`
# loads (ffi), whether table.unpack exists (lua52), string.dump's flags byte
# (BCDUMP_F_FR2 8, BCDUMP_F_BE 1; lj_bcdump.h:42-45), whether string.pack
# exists (pack: eris_lj.c reads OCLJ_LIB_STRPACK from oclj_features.h, the
# registration is lib_string.c's, and this is where the two are seen to
# agree), and whether 1 << 32 is 4294967296 (bit: eris_lj.c reads
# OCLJ_OPS_BIT64 from oclj_features.h, the operators are six of the seven
# patch-bitop-*.sh scripts', and this is where the two are seen to agree;
# the operands are made at run time, because the parser folds constants).
# gc64, dn and p64 are what stage 1b's GG_State comparison and
# oclj_features.h's refusals cover.
OBS=$("$LJEXE" -e 'local d = string.dump(function() end):byte(5) io.write(load("return 1LL") and "ffi1" or "ffi0", " ", table.unpack and "lua52" or "lua51", " ", d % 16 >= 8 and "fr2" or "fr1", " ", d % 2 == 1 and "be" or "le", " ", string.pack and "pack1" or "pack0", " ", (tonumber("1") << 32 == 4294967296) and "bit64" or "bit32")' 2>&1)
case "$OBS" in
  "ffi"[01]" lua5"[12]" fr"[12]" "[lb]e" pack"[01]" bit32"|"ffi"[01]" lua5"[12]" fr"[12]" "[lb]e" pack"[01]" bit64") : ;;
  *) fail "luajit.exe's feature observation is malformed: '$OBS'" ;;
esac
WORD=$(grep -a -o -E "[|]$SER_HASH[|]ffi[01][.][a-z0-9.]+" "$OBJ/eris_lj.o" | head -1)
WORD=${WORD##*|}
case "$WORD" in
  ffi[01].lua5[12].gc64.fr[12].dn[01].[lb]e.p64.pack[01].bit[36][24]|ffi[01].lua5[12].gc32.fr[12].dn[01].[lb]e.p64.pack[01].bit[36][24]|ffi[01].lua5[12].gc32.fr[12].dn[01].[lb]e.p32.pack[01].bit[36][24]) : ;;
  *) fail "eris_lj.o carries no well-formed VM-features word after '|$SER_HASH|' (got '$WORD')" ;;
esac
case "$WORD" in
  *.bit32|*.bit64) : ;;
  *) fail "eris_lj.o's VM-features word '$WORD' ends in neither bit32 nor bit64" ;;
esac
for t in $OBS; do
  case ".$WORD." in
    *".$t."*) : ;;
    *) fail "eris_lj.o's VM-features word '$WORD' disagrees with libluajit.a, which behaves
         as '$OBS' (token $t): every blob would carry a false description of the VM
         that wrote it" ;;
  esac
done
say "    VM-features word $WORD (luajit.exe agrees: $OBS)"

# --------------------------------------------------------------- 5
say "=============== 5. link ==============="
# javavm.c is deliberately NOT linked: it is OC-JNLua's "start a JVM from Lua"
# entry point, which the embedded (JVM-hosted) direction never uses.
rm -f "$OCLJ_OUT/$DLL_NAME"   # judged by [ -f ] below: a failed link must not leave the last library
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
  #
  # THE ADDITIVE EXPORTS FOUR MORE, LuaStateLuaJIT's own natives, asserted by
  # exact name: the accounting's ocljUsedMemory and ocljSetTotalMemory
  # (docs/accounting-sync.md), and Value disposal's ocljInstallValueFinalizer
  # and ocljValueGcCounters (THE VALUE FINALIZER in lj52shim.c) -- 91 Java_*
  # and 93 PE names.  The dropin exports none of them.
  OCLJN=$(syms | grep -cxE 'Java_li_cil_repack_com_naef_jnlua_LuaStateLuaJIT_oclj(UsedMemory|SetTotalMemory|InstallValueFinalizer|ValueGcCounters)')
  if [ "$OCLJ_VARIANT" = additive ]; then
    WANT_J=91; WANT_PE=93
    [ "$OCLJN" = "4" ] || fail "the additive exports $OCLJN of LuaStateLuaJIT's 4 oclj natives
         (ocljUsedMemory, ocljSetTotalMemory, ocljInstallValueFinalizer,
         ocljValueGcCounters); its capped constructor would throw, or Value
         disposal would never install and dropped handles would leak until reboot"
  else
    WANT_J=87; WANT_PE=89
    [ "$OCLJN" = "0" ] || fail "the dropin exports $OCLJN oclj natives of LuaStateLuaJIT"
  fi
  [ "$EXPORTS" = "$WANT_J" ] || fail "Java_* export count is $EXPORTS, expected $WANT_J ($OCLJ_VARIANT).  The ABI surface no
         longer matches OC-JNLua da3d4d45 plus LuaStateLuaJIT's oclj natives.
         Either jnlua.c was bumped (update this number deliberately) or a
         translation unit failed to link in."
  syms | grep -qx JNI_OnLoad   || fail "no JNI_OnLoad export"
  syms | grep -qx JNI_OnUnload || fail "no JNI_OnUnload export"
  if [ "$OCLJ_OS" = windows ]; then
    [ "$NSYM" = "$WANT_PE" ] || fail "PE export table holds $NSYM names, expected exactly $WANT_PE
         ($WANT_J Java_* + JNI_OnLoad + JNI_OnUnload).  Something else became visible."
  fi
  say "    ABI surface: Java_* = $EXPORTS (want $WANT_J), oclj natives = $OCLJN, total = $NSYM"
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
# 4. LuaJIT: a checkout at prototype/watchdog/luajit (gitignored; `make -C
#    prototype/watchdog luajit-src` clones it), pinned to upstream 1ee778a4,
#    whose LUAJIT_ENABLE_CHECKHOOK is upstream's own option (lj_record.c:691,
#    :2953).  The checkout stays pristine: this script builds a COPY with
#    native/luajit/oclj_features.h and the twelve changes in native/luajit/
#    (the fifth adds native/luajit/oclj_strpack.c to lib_string.c; the sixth
#    to the twelfth, round 3's seven patch-bitop-*.sh, patch seven files and
#    add oclj_bitop.h, oclj_bitop_meta.c, oclj_bitop_rec.c, oclj_bitop_fold.c
#    and oclj_num53.h to them).  Another LuaJIT commit is untested: the
#    twelve patch scripts' exactly-once anchors and the behaviour gates are
#    what refuse a tree that changed shape.
#
# 5. For OCLJ_VARIANT=additive only: Python 3 (python3 or python on PATH, or
#    OCLJ_PYTHON), to regenerate LuaStateLuaJIT.java and compare it with the
#    committed copy.  Any Python 3; the generator uses the standard library.
#
# 6. Nothing else.  eris_lj.c and lj52shim.c are in this repo.
#
# The smoke test needs three more things (ocelot-brain, its jar deps, and a
# Scala compiler); see the header of smoke-test.sh.
# =====================================================================
