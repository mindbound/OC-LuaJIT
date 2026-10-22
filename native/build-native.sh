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
#   OCLJ_SER    dir holding eris_lj.c and eris_lj.h    (default $OCLJ_REPO/serializer)
#   OCLJ_LUAJIT LuaJIT source tree      (default $OCLJ_REPO/prototype/watchdog/luajit),
#               a git checkout whose HEAD is THE PIN: the commit
#               native/luajit/upstream.commit names (the one file every reader
#               of the pin reads; THE PIN, in the preflight).  A pinned build
#               needs git and refuses any other HEAD.  The LuaJIT source it
#               starts from is exactly the tree the pin's 40 digits name, exported
#               from the checkout's .git with git archive and checked object by
#               object against them (the commit object must hash to the pin,
#               every tree object to its name, every exported file to its blob
#               id), then changed by the twelve patch scripts below, and
#               compiled with this script's flags only (THE BUILD ENVIRONMENT);
#               never the checkout's working tree: a local edit there is named
#               in a WARNING and is not built (THE BUILD COPY, step 1).
#               Anything that would change the export (a filter, ident, eol or
#               export attribute, a forged object, GIT_* variables) is a BUILD
#               FAIL; replace refs are ignored.  The toolchain is not pinned.
#   OCLJ_LUAJIT_UNPINNED  1 builds the checkout's WORKING TREE instead, at
#               whatever commit and with whatever edits, for a local
#               experiment, with a warning at the check and at the end.  Its
#               blob fingerprint names the commit "unpinned", so gradle's
#               verifyModAssets refuses to package it, its blobs do not restore
#               on a pinned native, nor a pinned native's on it, and it is not
#               collected into $OCLJ_BUILD/dist.  Unset or empty (default),
#               the build is pinned; any other value is refused.
#   OCLJ_BUILD  scratch build dir       (default $OCLJ_REPO/build/native).  It
#               may not lie inside OCLJ_LUAJIT, nor inside OCLJ_REPO or the
#               repository this script lives in except under its build/, and
#               OCLJ_LUAJIT may not be, or lie inside, a directory this script
#               removes in it (THE DIRECTORIES THIS SCRIPT REMOVES, in the
#               preflight).
#   OCLJ_OUT    where the library lands (default $OCLJ_BUILD/libdir, or
#                                      libdir-additive for OCLJ_VARIANT=additive).
#               Never $OCLJ_BUILD/dist, nor build/native/dist of OCLJ_REPO or
#               of the repository this script lives in, nor inside one: dist is
#               the collection point the jar is packaged from.
#   Every directory above is taken at its physical path, once, before anything
#   reads it (THE INPUT DIRECTORIES, in the preflight), and on Windows one
#   whose path has a name ending in a dot or a space is refused.
#   CC          C compiler              (default gcc; MinGW-w64 on Windows) for
#               our three translation units and the probes; LuaJIT's Makefile
#               calls gcc whatever CC says.  Not pinned (THE BUILD ENVIRONMENT).
#   JOBS        make -j                 (default 4)
#   The environment's compiler and linker variables (CFLAGS, CPATH, MAKEFLAGS
#   and the rest) are NOT inputs: they are dropped (THE BUILD ENVIRONMENT).
#   OCLJ_GLIBC_MAX  Linux only: the newest glibc symbol version the .so may
#               need, as x.y (2.28).  Set, a .so that needs a newer GLIBC_x.y,
#               or any version outside the GLIBC_x.y family, is a BUILD FAIL.
#               Unset (default), step 6 reports the highest version needed and
#               whether it is within the release floor, 2.28, and goes on, so a
#               development build on a newer distribution still finishes.  The
#               release build sets 2.28 (PREREQUISITES 7).
#
# USAGE
#   OCLJ_JNLUA=/path/to/OC-JNLua OCLJ_JNI="/c/Program Files/Java/jdk1.8.0_211/include" \
#     sh build-native.sh
#
#   The release Linux .so, in AlmaLinux 8 (glibc 2.28; PREREQUISITES 7):
#     OCLJ_GLIBC_MAX=2.28 OCLJ_VARIANT=additive OCLJ_JNLUA=/path/to/OC-JNLua \
#       OCLJ_JNI=/usr/lib/jvm/java-1.8.0-openjdk/include sh build-native.sh
#   A Linux build on a newer distribution (Ubuntu 26.04: GLIBC_2.38) is a
#   development build.  Give it its own OCLJ_BUILD: the additive variant
#   collects into $OCLJ_BUILD/dist, which gradle packages and which must hold
#   the release .so.
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

# THE BUILD ENVIRONMENT CANNOT ADD FLAGS, HEADERS OR LIBRARIES.  make takes
# every environment variable as a make variable, and LuaJIT's src/Makefile uses
# its flag and path variables without assigning them, so a value set in the
# shell reached the compile and link lines as it was: with CFLAGS='-include
# <header>' in the environment a pinned build put the header into 76 of the 77
# LuaJIT compile lines, stamped the DLL 1ee778a4, collected it into dist, and
# gradle accepted it (measured 2026-10-20, the export-check round's review).
# So the variables below, the ones make, gcc and ld were measured, or read in
# their manuals and LuaJIT's Makefiles, to take from the environment and change
# what is compiled or linked, are removed here, before anything reads one, in
# both modes:
#   the conventions     CFLAGS CPPFLAGS CXXFLAGS LDFLAGS LDLIBS LIBS
#   LuaJIT's Makefiles  every variable the pin's src/Makefile and top Makefile
#                       use without assigning it, or assign with ?= or only in
#                       some branches (a census of the two files, 2026-10-20):
#                       HOST_CFLAGS HOST_LDFLAGS HOST_LIBS TARGET_CFLAGS
#                       TARGET_FLAGS TARGET_LDFLAGS TARGET_SHLDFLAGS TARGET_LIBS
#                       TARGET_ARCH TARGET_SYS CROSS PREFIX MULTILIB LMULTILIB
#                       INSTALL_LJLIBD DESTDIR HOST_MSYS HOST_RM MAKE, and
#                       CFLAGS LDFLAGS LIBS.  Set one at a time, 17 of them
#                       changed what `make -n` runs for this build, on Windows
#                       and in AlmaLinux 8, HOST_RM what `make clean` runs, and
#                       MAKE what the amalg target runs
#   make's own          MAKEFLAGS MAKEFILES GNUMAKEFLAGS MFLAGS MAKEOVERRIDES
#                       (MAKEFLAGS, GNUMAKEFLAGS and MAKEFILES each added a
#                       flag to every compile line; MAKEOVERRIDES=CFLAGS=-O0
#                       put -O0 on 76 of them with mingw32-make 4.4.1, and
#                       nothing with AlmaLinux 8's make 4.2.1: pin round 4's
#                       review)
#   gcc's               CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH
#                       LIBRARY_PATH GCC_EXEC_PREFIX COMPILER_PATH
#                       DEPENDENCIES_OUTPUT SUNPRO_DEPENDENCIES
#   ld's                LD_RUN_PATH (it gave a shared object an RPATH) and
#                       GNUTARGET (it changed the object's layout; AlmaLinux 8,
#                       2026-10-20)
# whatever the case of the name: MinGW gcc reads its variables through the
# Windows C runtime, whose getenv ignores case, and found a header through
# cpath and Cpath as through CPATH, and through cpath after the shell's
# `unset CPATH` (measured 2026-10-20).  The names that were set are printed in
# the preflight ("ignored from the environment"), never their values.  Kept:
# this script's own inputs (EXTERNAL INPUTS: CC, JOBS, OCLJ_* and the rest),
# PATH, and OS, MSYSTEM and TERM, which src/Makefile reads only to tell a
# cmd.exe host from an MSYS or POSIX one (~:157), which Windows and the
# terminal set on every host, and none of which changed the dry run alone.
# The list is what was found, not a proof that nothing else reaches the build:
# a name that is not a shell identifier cannot be unset by sh (none of these is
# one), and make takes such names from the environment too (its own
# -*-command-variables-*- is one, not measured).  THE TOOLCHAIN IS NOT PINNED:
# CC, and the make, gcc and binutils that PATH finds, compile the pin's tree
# with this script's flags (PREREQUISITES 1 and 7 name the compilers the
# release is built with).
OCLJ_ENV_DROP="CFLAGS CPPFLAGS CXXFLAGS LDFLAGS LDLIBS LIBS"
OCLJ_ENV_DROP="$OCLJ_ENV_DROP HOST_CFLAGS HOST_LDFLAGS HOST_LIBS TARGET_CFLAGS TARGET_FLAGS"
OCLJ_ENV_DROP="$OCLJ_ENV_DROP TARGET_LDFLAGS TARGET_SHLDFLAGS TARGET_LIBS TARGET_ARCH TARGET_SYS"
OCLJ_ENV_DROP="$OCLJ_ENV_DROP CROSS PREFIX MULTILIB LMULTILIB INSTALL_LJLIBD DESTDIR HOST_MSYS"
OCLJ_ENV_DROP="$OCLJ_ENV_DROP HOST_RM MAKE MAKEFLAGS MAKEFILES GNUMAKEFLAGS MFLAGS MAKEOVERRIDES"
OCLJ_ENV_DROP="$OCLJ_ENV_DROP CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH"
OCLJ_ENV_DROP="$OCLJ_ENV_DROP LIBRARY_PATH GCC_EXEC_PREFIX COMPILER_PATH DEPENDENCIES_OUTPUT"
OCLJ_ENV_DROP="$OCLJ_ENV_DROP SUNPRO_DEPENDENCIES LD_RUN_PATH GNUTARGET"
OCLJ_ENV_DROPPED=
# env lists the names (a value holding a newline can fake a line, so each name
# must also be a set variable); awk's toupper, under LC_ALL=C, folds A-Z only.
for oclj_n in $(env | cut -d= -f1 | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | sort -u \
    | awk -v drop="$OCLJ_ENV_DROP" 'BEGIN { n = split(drop, d, " "); for (i = 1; i <= n; i++) w[d[i]] = 1 }
      toupper($0) in w'); do
  eval 'oclj_v=${'"$oclj_n"'+set}'
  [ "$oclj_v" = set ] || continue
  unset "$oclj_n"
  OCLJ_ENV_DROPPED="${OCLJ_ENV_DROPPED:+$OCLJ_ENV_DROPPED }$oclj_n"
done
unset oclj_n oclj_v

SELF_DIR=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd -P)
# The repository this script lives in: OCLJ_REPO's default, and guarded as
# OCLJ_REPO is when OCLJ_REPO names another (THE DIRECTORIES THIS SCRIPT
# REMOVES).
SELF_REPO=$(CDPATH= cd -P -- "$SELF_DIR/.." && pwd -P)

: "${OCLJ_REPO:=$SELF_REPO}"
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
: "${OCLJ_GLIBC_MAX:=}"
: "${OCLJ_LUAJIT_UNPINNED:=}"

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
#              Linux adds -pthread and -Wl,--no-undefined.  Before glibc 2.34
#              the watchdog's pthread_create, pthread_join,
#              pthread_condattr_setclock, pthread_setname_np, pthread_sigmask
#              and pthread_attr_setstacksize live in libpthread, and a link
#              without -pthread left all six undefined with NO symbol version
#              and no NEEDED libpthread: they resolved only because the JVM
#              had libpthread loaded already (AlmaLinux 8, glibc 2.28,
#              2026-10-19).  With it they are pthread_create@GLIBC_2.2.5 and
#              so on, and the highest version needed stays GLIBC_2.17; from
#              2.34 they are in libc and the .so is byte-identical with or
#              without it.  --no-undefined makes any such gap a link error
#              (without -pthread the AlmaLinux 8 link fails, naming the six).
#              A JNI library may use it: jnlua.c reaches the JVM only through
#              the JNIEnv tables (javavm.c is not linked), so every undefined
#              symbol must come from a library this line or -lm names.  NOT
#              -ldl: nothing we link reaches lib_package's dlopen (the .so
#              imports none of libdl's functions; its one dl_ import,
#              dl_iterate_phdr from libgcc's unwinder, is libc's), and
#              before 2.34 -ldl would only add a
#              NEEDED libdl.so.2.  The test runners need -ldl (luaL_openlibs);
#              this library does not.  Step 6 checks the artifact itself.
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
  *)       LIBEXT=.so    ; JNI_MD=$OCLJ_OS ; LINK_EXTRA="-static-libgcc -pthread -Wl,--no-undefined" ; PICFLAG=-fPIC ;;
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

# --------------------------------------------------------------- 0
say "=============== 0. preflight ==============="
say "host    = $PLATFORM   (lib*$LIBEXT, jni_md in $JNI_MD/)"
say "ignored from the environment: ${OCLJ_ENV_DROPPED:-none} (THE BUILD ENVIRONMENT)"
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
# THE GLIBC FLOOR, which step 6 measures a Linux library against (OCLJ_GLIBC_MAX
# under EXTERNAL INPUTS).  A malformed limit is refused here, before the build.
GLIBC_FLOOR=2.28   # the release floor; gradle's verifyModAssets refuses a .so above it
if [ -n "$OCLJ_GLIBC_MAX" ]; then
  awk -v v="$OCLJ_GLIBC_MAX" 'BEGIN { exit !(v ~ /^[0-9]+([.][0-9]+)+$/) }' \
    || fail "OCLJ_GLIBC_MAX='$OCLJ_GLIBC_MAX' is not a glibc version written x.y, such as 2.28"
  if [ "$OCLJ_OS" = linux ]; then
    say "glibc   = the library may need at most GLIBC_$OCLJ_GLIBC_MAX (OCLJ_GLIBC_MAX; checked in step 6)"
  else
    say "glibc   = OCLJ_GLIBC_MAX=$OCLJ_GLIBC_MAX does not apply: a $OCLJ_OS library imports no glibc"
  fi
elif [ "$OCLJ_OS" = linux ]; then
  say "glibc   = reported against the release floor GLIBC_$GLIBC_FLOOR in step 6, not enforced (OCLJ_GLIBC_MAX unset)"
fi
# THE INPUT DIRECTORIES ARE TAKEN AT THEIR PHYSICAL PATHS, HERE, BEFORE ANYTHING
# READS THEM.  Every directory this script is given -- OCLJ_REPO, OCLJ_LUAJIT,
# OCLJ_SHIM, OCLJ_SER, OCLJ_JNLUA, OCLJ_JNI, OCLJ_BUILD and OCLJ_OUT, and its own
# directory -- becomes the physical path this shell resolves it to (cd -P and
# pwd -P: no symlink or junction, no "." or ".."), and the guards below and
# every tool after them get that one path.  This shell and Windows' own
# programs do not read every spelling alike (measured 2026-10-20, pin round 4's
# review): "<junction>/.." is taken where the junction points by cd -P, rm, cp
# and mkdir, and by its spelling, the junction's own parent, by mingw32-make
# -C, gcc -o, ld -o and git; and a name ending in "." or " " is kept by this
# shell and dropped by them.  In round 4 the guards checked the shell's
# reading and the tools were handed the spelling: an unpinned build replaced
# dist's library through OCLJ_OUT=<build>/<junction>/../dist (which round 3's
# string comparison had refused) and through OCLJ_OUT=<build>/dist., and a
# pinned build ran make clean and the LuaJIT build inside a throwaway clone at
# <dir>/luajit-<platform> through OCLJ_BUILD=<dir>/<junction>/.., which the
# guards had read as the junction's target.  A physical path has no ".." to
# read two ways, and on Windows a name ending in a dot or a space is refused
# (winname), so the shell's gates and the native tools read one file.
# OCLJ_BUILD and OCLJ_OUT need not exist yet: physpath resolves their deepest
# existing ancestor and appends the names below it.  An input that names no
# directory is left as it was given, for the check that reads it to refuse it
# below; OCLJ_JNI gets its default first.
# physpath <path>: the physical absolute path of <path>, which need not exist
# yet.  The deepest ancestor that is a directory is resolved with cd -P and
# pwd -P; the rest is appended name by name, "." skipped, ".." taking the
# parent, and a prefix that then names a directory is resolved again.
physpath() {
  pp_p=$1 pp_t=
  while [ ! -d "$pp_p" ]; do
    pp_t=$(basename -- "$pp_p")/$pp_t
    pp_p=$(dirname -- "$pp_p")
  done
  pp_p=$(CDPATH= cd -P -- "$pp_p" && pwd -P) || return 1
  pp_ifs=$IFS; IFS=/; set -f
  for pp_c in $pp_t; do
    case $pp_c in
      ''|.) ;;
      ..) pp_p=$(dirname -- "$pp_p") ;;
      *) pp_p=${pp_p%/}/$pp_c
         if [ -d "$pp_p" ]; then pp_p=$(CDPATH= cd -P -- "$pp_p" && pwd -P) || pp_p=; fi ;;
    esac
    [ -n "$pp_p" ] || break
  done
  IFS=$pp_ifs; set +f
  [ -n "$pp_p" ] || return 1
  printf '%s\n' "$pp_p"
}
# winname <physical path> <what>: on Windows, refuse a path one of whose names
# ends in a dot or a space.  This shell keeps such a name as written, and
# Windows' own programs drop the dot or the space and act on the name without
# it: an unpinned build replaced dist's library through OCLJ_OUT=<build>/dist.
# (pin round 4's review).
winname() {
  [ "$OCLJ_OS" = windows ] || return 0
  case "$1/" in
    *./*|*' /'*) fail "$2 is $1, one of whose names ends in a dot or a space.
         This shell keeps such a name as written, and Windows' own programs
         (make, gcc, ld, git) drop the dot or the space, so they would act on
         another directory than the one this script checks.  Use a path without
         such a name; nothing has been created." ;;
  esac
}
# physdir <variable>: when the variable names a directory, its value becomes
# that directory's physical path, checked by winname.  What was given is kept
# in <variable>_GIVEN, for the messages.
physdir() {
  eval 'pd_g=$'"$1"
  eval "$1"'_GIVEN=$pd_g'
  [ -d "$pd_g" ] || return 0
  pd_p=$(CDPATH= cd -P -- "$pd_g" && pwd -P) || fail "cannot enter $1=$pd_g"
  winname "$pd_p" "$1"
  eval "$1"'=$pd_p'
}
if [ -z "$OCLJ_JNI" ]; then
  for c in "$JAVA_HOME/include" "/c/Program Files/Java/jdk1.8.0_211/include"; do
    [ -f "$c/jni.h" ] && OCLJ_JNI="$c" && break
  done
fi
winname "$SELF_DIR" "this script's directory"
for oclj_n in OCLJ_REPO OCLJ_LUAJIT OCLJ_SHIM OCLJ_SER OCLJ_JNLUA OCLJ_JNI; do
  physdir "$oclj_n"
done
unset oclj_n
OCLJ_BUILD_GIVEN=$OCLJ_BUILD
OCLJ_BUILD=$(physpath "$OCLJ_BUILD_GIVEN") || fail "cannot resolve OCLJ_BUILD=$OCLJ_BUILD_GIVEN"
winname "$OCLJ_BUILD" OCLJ_BUILD
OCLJ_OUT_GIVEN=$OCLJ_OUT
OCLJ_OUT=$(physpath "$OCLJ_OUT_GIVEN") || fail "cannot resolve OCLJ_OUT=$OCLJ_OUT_GIVEN"
winname "$OCLJ_OUT" OCLJ_OUT
LJ_FEATURES_H=$OCLJ_REPO/native/luajit/oclj_features.h
# THE PIN.  Our LuaJIT is upstream LuaJIT 2.1 at ONE commit, and that commit is
# ONE file, native/luajit/upstream.commit: the full 40-digit hash and a newline.
# Every reader reads it.  prototype/watchdog/Makefile (and the older build.bat)
# check the pristine checkout out at it; serializer/Makefile stamps all 40
# digits into its test host's blob fingerprint; this script refuses a checkout
# whose HEAD is not the pin, all 40 digits, and compiles the tree the pin's 40
# digits name, checked object by object, with the twelve changes and this
# script's flags only, not the checkout's working tree (THE CHECKOUT MUST BE AT
# THE PIN, right after git_head below, THE BUILD COPY, step 1, and THE BUILD
# ENVIRONMENT, at the top); and build.gradle.kts
# refuses a native whose fingerprint names another commit.  Until 2026-10-20
# the hash was written out in the three build files and nothing compared the
# checkout with it: a checkout at another commit built a native stamped with
# that commit, and the jar build packaged it.
# The file is held to one spelling here, byte for byte, before anything reads
# it: exactly 40 lowercase hex digits, then one LF or nothing.  One spelling,
# so that every reader reads the same value: make and cmd drop a CR, build.bat
# reads only the first line, and the Makefiles refuse a short or upper-case
# hash.
LJ_PIN_FILE=$OCLJ_REPO/native/luajit/upstream.commit
[ -f "$LJ_PIN_FILE" ] || fail "no $LJ_PIN_FILE: the pinned LuaJIT commit, 40 lowercase hex
         digits and a newline, which every reader of the pin reads"
LJ_PIN=$(cat "$LJ_PIN_FILE") || fail "cannot read $LJ_PIN_FILE"
LJ_PIN_BYTES=$(wc -c < "$LJ_PIN_FILE" | tr -d ' ')
LJ_PIN_OK=
case $LJ_PIN in
  *[!0-9a-f]*) ;;
  *) if [ "${#LJ_PIN}" = 40 ]; then
       # $(cat) dropped the trailing newlines; the byte count and the last byte
       # say there was at most one, and that it was an LF.
       case $LJ_PIN_BYTES in
         40) LJ_PIN_OK=1 ;;
         41) [ "$(tail -c 1 "$LJ_PIN_FILE" | od -An -tx1 | tr -d ' ')" = 0a ] && LJ_PIN_OK=1 ;;
       esac
     fi ;;
esac
[ -n "$LJ_PIN_OK" ] || fail "$LJ_PIN_FILE is not one LuaJIT commit.  It must hold exactly 40
         lowercase hex digits and an optional newline (LF), the full hash
         prototype/watchdog/Makefile checks out; it holds $LJ_PIN_BYTES bytes:
$(od -An -c "$LJ_PIN_FILE" | head -4)"
LJ_PIN8=$(printf '%s' "$LJ_PIN" | cut -c1-8)
case $OCLJ_LUAJIT_UNPINNED in
  ''|1) ;;
  *) fail "OCLJ_LUAJIT_UNPINNED='$OCLJ_LUAJIT_UNPINNED' must be 1 (build the LuaJIT checkout's
         working tree, whatever its commit and edits, instead of the pin, for a
         local experiment) or unset" ;;
esac
say "pin     = $LJ_PIN ($LJ_PIN_FILE)${OCLJ_LUAJIT_UNPINNED:+, OCLJ_LUAJIT_UNPINNED=1}"
# THE DIRECTORIES THIS SCRIPT REMOVES, AND WHERE THE LIBRARY LANDS.  Every run
# removes three directories in $OCLJ_BUILD before it remakes them: the build
# copy LJ_WORK and the pin's export LJ_EXPORT (THE BUILD COPY, step 1), and the
# layout gate's header copy NEGI (stage 1b).  rm -rf follows no symlink at the
# end of the path it is given, but it does follow one in the middle, and a ".."
# after a symlink or a Windows junction goes where the link points, so what it
# deletes is a PHYSICAL directory, whatever spelling named it.  Measured
# 2026-10-20 (the build-copy round's review): an unpinned build whose
# OCLJ_LUAJIT was $OCLJ_BUILD/luajit-<platform> deleted that checkout before
# copying it.  So the checkout may not be, or lie inside, any of the three, and
# $OCLJ_BUILD may not be, or lie inside, the checkout, whose working tree it
# would then copy into itself and build in.  The same review measured an
# unpinned build with OCLJ_OUT set to $OCLJ_BUILD/dist replacing the release
# library there while it printed "dist left as it was": OCLJ_OUT is where the
# link writes, and dist is the collection point build.gradle.kts packages, so
# OCLJ_OUT may not be, or lie inside, $OCLJ_BUILD/dist or build/native/dist, in
# either mode.  And $OCLJ_BUILD may not be, or lie inside, $OCLJ_REPO, except
# under $OCLJ_REPO/build: the build writes files of fixed names into
# $OCLJ_BUILD (strpack.lua, bitops.lua, luajit_build.log and more), and the
# repository tracks files of those names, so an OCLJ_BUILD of serializer/tests
# would overwrite serializer/tests/strpack.lua (the export-check round's
# review).  The repository this script lives in, SELF_REPO, is guarded the
# same way when OCLJ_REPO names another: neither OCLJ_BUILD outside its build/
# nor OCLJ_OUT in its build/native/dist (since pin round 5).  All of this is
# refused here, before anything is created, removed or built.
# THE COMPARISON IS BY IDENTITY, NOT BY SPELLING.  Until the export-check round
# it compared strings, the physical paths that a plain cd and pwd -P gave, with
# A-Z folded on Windows, and its review got past both refusals two ways: an
# OCLJ_BUILD written <dir>/<junction>/.. (a plain cd takes ".." by the
# spelling, every other call goes where the junction points) and a
# different-case spelling of a non-ASCII letter (Bäu and BÄU are one directory
# on NTFS, and tr folds A-Z only).  The build then deleted the throwaway
# checkout at the copy's real path, and replaced dist's DLL with one stamped
# unpinned (measured 2026-10-20).  Since round 4 every path compared is a
# physical one (THE INPUT DIRECTORIES, above), and two directories that exist
# are compared with test -ef, which is true only for one file: through a
# symlink, a junction, and other case, ASCII or not, it held in Git Bash's
# bash, AlmaLinux 8's sh (bash 4.4 in POSIX mode) and Ubuntu's dash
# (2026-10-20).  Only a path that does not exist yet is compared by spelling,
# on every host (/mnt/c, where the AlmaLinux 8 release build runs, is NTFS),
# with A-Z folded and every byte outside printable ASCII read as "?": the
# folding alone let OCLJ_BUILD=<dir>/Bäu and OCLJ_OUT=<dir>/BÄU/dist, neither
# made yet and one directory on NTFS, through, and the unpinned library landed
# in that dist (pin round 4's review).  Read so, two different names compare
# equal when they differ only in bytes outside printable ASCII, as many of
# them, or only in A-Z case on a case-sensitive file system: that can refuse a
# path that was in fact elsewhere, and never passes one that was not.
# pathkey <path>: the spelling compared where a directory does not exist yet.
pathkey() { printf '%s\n' "$1" | tr 'A-Z' 'a-z' | tr -c '[:print:][:space:]' '?'; }
# inside <a> <b>: true when the directory at the physical path <a> is the one at
# <b>, or lies inside it, whether or not either exists yet.  <b> is split into
# its deepest existing ancestor E and the names below E.  Each ancestor of <a>,
# <a> itself first, that exists is compared with E by test -ef; when they are
# one directory, <a> lies inside <b> if the names below that ancestor begin
# with <b>'s names below E (pathkey).  An ancestor of <a> that does not exist
# is compared with <b> by spelling (pathkey).
inside() {
  in_b=${2%/} in_bt=
  in_be=$in_b
  while [ -n "$in_be" ] && [ ! -e "$in_be" ]; do
    in_bt=/${in_be##*/}$in_bt
    in_be=${in_be%/*}
  done
  in_a=${1%/} in_at=
  while [ -n "$in_a" ]; do
    if [ -e "$in_a" ]; then
      if [ -n "$in_be" ] && [ "$in_a" -ef "$in_be" ]; then
        case "$(pathkey "$in_at")/" in "$(pathkey "$in_bt")/"*) return 0 ;; esac
      fi
    elif [ "$(pathkey "$in_a")" = "$(pathkey "$in_b")" ]; then
      return 0
    fi
    in_at=/${in_a##*/}$in_at
    in_a=${in_a%/*}
  done
  return 1
}
[ -d "$OCLJ_LUAJIT" ] || fail "no LuaJIT checkout at $OCLJ_LUAJIT (OCLJ_LUAJIT must be a directory:
         make -C prototype/watchdog luajit-src clones the default one)"
LJ_CHECKOUT=$OCLJ_LUAJIT
for r in "$OCLJ_REPO" "$SELF_REPO"; do
  if inside "$OCLJ_BUILD" "$r" && ! inside "$OCLJ_BUILD" "$r/build"; then
    fail "OCLJ_BUILD=$OCLJ_BUILD_GIVEN ($OCLJ_BUILD) is, or lies inside, the repository
         $r, outside its build/ directory (OCLJ_REPO is $OCLJ_REPO, and this
         script lives in $SELF_REPO).  The build writes files of fixed names into
         OCLJ_BUILD (strpack.lua, bitops.lua, luajit_build.log and more), and the
         repository tracks files of such names (serializer/tests/strpack.lua),
         which it would overwrite.  Leave OCLJ_BUILD unset (build/native), or set it
         under $r/build or outside the repository; nothing has been created."
  fi
done
LJ_WORK=$OCLJ_BUILD/luajit-$PLATFORM
LJ_EXPORT=$OCLJ_BUILD/luajit-export-$PLATFORM
NEGI=$OCLJ_BUILD/layoutneg-$PLATFORM
for d in "luajit-$PLATFORM" "luajit-export-$PLATFORM" "layoutneg-$PLATFORM"; do
  inside "$LJ_CHECKOUT" "$OCLJ_BUILD/$d" && fail "the LuaJIT checkout $OCLJ_LUAJIT_GIVEN ($LJ_CHECKOUT)
         is, or lies inside, $OCLJ_BUILD/$d, a directory this script
         removes and remakes on every run.  Move the checkout, or set OCLJ_BUILD to
         another directory; nothing has been removed."
done
inside "$OCLJ_BUILD" "$LJ_CHECKOUT" && fail "OCLJ_BUILD=$OCLJ_BUILD_GIVEN ($OCLJ_BUILD) is, or lies inside, the LuaJIT
         checkout $OCLJ_LUAJIT_GIVEN ($LJ_CHECKOUT): the build would write, remove and
         copy inside the tree it reads.  Set OCLJ_BUILD to a directory outside it."
for d in "$OCLJ_BUILD/dist" "$OCLJ_REPO/build/native/dist" "$SELF_REPO/build/native/dist"; do
  inside "$OCLJ_OUT" "$d" && fail "OCLJ_OUT=$OCLJ_OUT_GIVEN ($OCLJ_OUT) is, or lies inside, $d,
         the collection point build.gradle.kts packages the jar from.  OCLJ_OUT is
         where the link writes the library, and a build that wrote there would
         replace the release library whatever it is.  Leave OCLJ_OUT unset, or point
         it elsewhere; an additive pinned build collects into dist by itself."
done
command -v "$CC" >/dev/null 2>&1 || fail "no C compiler '$CC' on PATH (MinGW-w64 gcc on Windows, gcc or clang elsewhere)"
say "cc      = $("$CC" --version | head -1)"
[ -n "$OCLJ_JNLUA" ] || fail "OCLJ_JNLUA is unset: point it at an OC-JNLua checkout (git clone https://github.com/MightyPirates/OC-JNLua.git)"
[ -f "$OCLJ_JNLUA/native/src/jnlua.c" ] || fail "no $OCLJ_JNLUA/native/src/jnlua.c"
[ -n "$OCLJ_JNI" ] && [ -f "$OCLJ_JNI/jni.h" ] || fail "OCLJ_JNI must name a JDK include dir containing jni.h"
[ -f "$OCLJ_JNI/$JNI_MD/jni_md.h" ] || fail "no $OCLJ_JNI/$JNI_MD/jni_md.h -- that JDK include
       directory belongs to a different platform than this build ($PLATFORM)"
[ -f "$OCLJ_SHIM/lj52shim.c" ] || fail "no $OCLJ_SHIM/lj52shim.c"
[ -f "$OCLJ_SHIM/lj52shim.h" ] || fail "no $OCLJ_SHIM/lj52shim.h"
[ -f "$OCLJ_SER/eris_lj.c" ]   || fail "no $OCLJ_SER/eris_lj.c"
[ -f "$LJ_FEATURES_H" ]        || fail "no $LJ_FEATURES_H: the LuaJIT feature set"
# (The checkout's CHECKHOOK option is checked in step 1, in the tree that is
# compiled: the pin's export, or the working tree when unpinned.  Here the
# checkout need only be a directory, checked above.)
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
# (THE COLLECTOR-STATE ENUM check, which reads lj_gc.h, runs in step 1 on the
# build copy, the tree that is compiled: see THE BUILD COPY.)

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

# THE CHECKOUT'S COMMIT.  git_head prints a checkout's HEAD, all 40 digits, or
# nothing when git cannot read it.  git is pointed at the checkout's OWN .git
# (--git-dir, which also takes a worktree's "gitdir:" file): with -C it would
# walk up from a tree that has no .git of its own into an enclosing repository,
# and an exported GIT_DIR (as in a git hook) would override -C, either way
# reading some other repository's commit (measured 2026-10-20, review of the
# glibc round).  Until 2026-10-20 it fell back to reading .git/HEAD by hand when
# git could not run, because the commit it read was stamped into the blob
# fingerprint and AlmaLinux 8 had no git; that fallback is gone.  A pinned
# build needs git anyway (it exports the pin's tree with git archive) and
# stamps the pin, an unpinned build stamps "unpinned", and what is left is
# reporting: an unpinned checkout's and OC-JNLua's commits, "unknown" without
# git.  The pinned path reads the checkout's HEAD through ljgit, below.
git_head() {
  # git_head <checkout> -- the checkout's HEAD commit, 40 hex digits, or nothing
  gh_h=$(git --git-dir="$1/.git" rev-parse HEAD 2>/dev/null) || gh_h=
  case $gh_h in
    *[!0-9a-f]*|'') ;;
    *) [ "${#gh_h}" = 40 ] && printf '%s\n' "$gh_h" ;;
  esac
}
# EVERY GIT CALL ON THE PINNED PATH GOES THROUGH ljgit: the HEAD comparison,
# the commit, tree and blob checks, ls-tree, archive and hash-object.  The
# review of the build-copy round (2026-10-20) shipped another commit's code
# under the stamp 1ee778a4, and gradle accepted it, through the export itself:
# a replace ref on the pin (refs/replace; rev-parse, cat-file, ls-tree and
# archive all honour it) exported the parent's tree; a smudge filter, set
# through .git/info/attributes, the repo's config or the environment alone
# (GIT_CONFIG_COUNT), was applied by git archive; and a forged loose blob or
# subtree object exported the parent's file.  So ljgit turns replace objects
# off, reads the checkout's own .git by its physical path (--git-dir: never an
# enclosing repository, never an exported GIT_DIR), and archives with no
# line-ending conversion, and the export is then checked against the pin's 40
# digits link by link, so that whatever git or its configuration does, the
# source tree the build copy is made from is exactly the tree the pin names,
# up to a SHA-1 collision, or the build fails (what is then compiled is that
# tree with the twelve changes, under this script's flags: THE BUILD
# ENVIRONMENT):
#   1. the pin's commit object hashes to the pin (cat-file | hash-object);
#   2. the root tree is the one that commit object names on its "tree" line,
#      and rev-parse <pin>^{tree} agrees;
#   3. every tree object under it hashes to its name (step 1), so ls-tree's
#      list of paths and blob ids is the pin's;
#   4. every exported file's bytes hash to the blob id that list gives it
#      (hash-object --no-filters), and the export holds exactly as many files.
# Not compared: the exported files' modes (the tree records 100644 or 100755
# and tar applies them; nothing compiled depends on the executable bit) and
# their timestamps (a tree records none).
ljgit() {
  git --no-replace-objects --git-dir="$LJ_CHECKOUT/.git" -c core.autocrlf=false -c core.eol=lf "$@"
}
# ljgitenv: the names (never the values) of the GIT_* variables set now, for
# the messages below.
ljgitenv() {
  lge=$(env | cut -d= -f1 | grep -E '^GIT_[A-Za-z0-9_]+$' | sort -u | tr '\n' ' ')
  lge=${lge% }
  printf '%s' "${lge:-none}"
}
# THE CHECKOUT MUST BE AT THE PIN (THE PIN, above).  LJ_COMMIT is the first
# field of the blob fingerprint (ERIS_LJ_COMMIT, step 4): two natives restore
# each other's blobs only when they agree on it, and build.gradle.kts packages
# a native only when it is the pin's first 8 digits.  So it must name what was
# compiled, and a commit name is only as good as the tree behind it.  Until
# 2026-10-20 it was the checkout's HEAD, 8 digits, and the tree compiled was the
# checkout's working tree, copied once into the build copy and then kept: a
# checkout at the pin with uncommitted edits, and a build copy left from an
# earlier build of another commit, both shipped another commit's code stamped
# 1ee778a4, and gradle accepted it (measured 2026-10-20, the pin round's
# review).  Now:
#   PINNED (OCLJ_LUAJIT_UNPINNED unset or empty): git must run, the checkout's
#     HEAD must be the pin, all 40 digits (an 8-digit prefix can be forged into
#     .git/HEAD and git rev-parse prints it back), the pin's commit must be in
#     the checkout's .git, and its commit object must hash to the pin and name
#     the root tree (links 1 and 2 of ljgit's chain, above).  Step 1 exports
#     that tree with git archive, checks it (links 3 and 4) and compiles it with
#     the twelve changes (THE BUILD COPY), so the stamp, LJ_PIN8, names the
#     source tree that is compiled; the working tree only feeds a WARNING.
#   UNPINNED (OCLJ_LUAJIT_UNPINNED=1): step 1 copies the checkout's working
#     tree, at whatever commit and with whatever edits, and the stamp is the
#     literal "unpinned": gradle refuses it whatever the checkout's commit, and
#     its blobs never pass for the pin's.  How far such a build gets is up to
#     the twelve patch scripts' exactly-once anchors and the gates below: they
#     refuse a tree that changed shape, and a tree that kept its shape builds.
#     The native is not collected into $OCLJ_BUILD/dist.
LJ_UNPINNED_NOTE=
if [ -z "$OCLJ_LUAJIT_UNPINNED" ]; then
  command -v git >/dev/null 2>&1 || fail "no git on PATH.  A pinned build compiles the pin's committed tree, which
         it exports from the LuaJIT checkout's .git ($OCLJ_LUAJIT/.git) with git
         archive, and it checks that the checkout's HEAD is the pin.  Install git
         (AlmaLinux 8: dnf install git).  OCLJ_LUAJIT_UNPINNED=1 builds the
         working tree without git, for a local experiment whose native never ships."
  LJ_HEAD=$(ljgit rev-parse HEAD 2>/dev/null) || LJ_HEAD=
  case $LJ_HEAD in *[!0-9a-f]*) LJ_HEAD= ;; esac
  [ "${#LJ_HEAD}" = 40 ] || LJ_HEAD=
  [ -n "$LJ_HEAD" ] || fail "git cannot read the HEAD of the LuaJIT checkout $OCLJ_LUAJIT
         (git --git-dir=$LJ_CHECKOUT/.git rev-parse HEAD).  A pinned build needs the
         checkout's own .git: make -C prototype/watchdog luajit-src clones it."
  [ "$LJ_HEAD" = "$LJ_PIN" ] || fail "the LuaJIT checkout $OCLJ_LUAJIT is at $LJ_HEAD,
         and the pin is $LJ_PIN ($LJ_PIN_FILE).
         Check the pin out (make -C prototype/watchdog luajit-src does, for the
         default checkout), or bump the pin deliberately (docs/jit-guide.md 8.2a).
         For a local experiment only, OCLJ_LUAJIT_UNPINNED=1 builds the checkout's
         working tree anyway: such a native carries 'unpinned' in its blob
         fingerprint, gradle refuses to package it, and its blobs do not restore
         on a pinned native."
  ljgit cat-file -e "$LJ_PIN^{commit}" \
    || fail "the LuaJIT checkout $OCLJ_LUAJIT names the pin $LJ_PIN as its HEAD, but its .git
         holds no such commit (git --no-replace-objects cat-file -e $LJ_PIN^{commit}).
         Likely causes: HEAD written by hand, the pin's commit pruned, a replace
         ref standing in for it (this build ignores replace refs), a shallow or
         partial clone, or a forged commit object (git's own error above, if any,
         says hash mismatch).  Re-clone it (move it aside, then make -C
         prototype/watchdog luajit-src)."
  # Link 1: the commit object hashes to the pin.  A pipeline's status is its
  # last command's, so a cat-file that fails hashes nothing and cannot match.
  LJ_CHASH=$(ljgit cat-file commit "$LJ_PIN" | ljgit hash-object -t commit --stdin 2>/dev/null) || LJ_CHASH=
  [ "$LJ_CHASH" = "$LJ_PIN" ] || fail "the commit object $LJ_PIN in $LJ_CHECKOUT/.git hashes to
         '$LJ_CHASH', not to its name: git does not hold the pin's commit there.
         Likely causes: a forged or corrupted object in that .git, or GIT_*
         variables that point git at other objects (GIT_OBJECT_DIRECTORY,
         GIT_ALTERNATE_OBJECT_DIRECTORIES, GIT_COMMON_DIR; set now: $(ljgitenv)).
         Re-clone the checkout (move it aside, then make -C prototype/watchdog
         luajit-src)."
  # Link 2: the root tree is the one the commit object names on its first line,
  # "tree <40 digits>", and git's own resolution of <pin>^{tree} agrees.
  LJ_TREE_LINE=$(ljgit cat-file commit "$LJ_PIN" | head -n 1)
  LJ_TREE=${LJ_TREE_LINE#tree }
  case $LJ_TREE_LINE in "tree "*) ;; *) LJ_TREE= ;; esac
  case $LJ_TREE in *[!0-9a-f]*) LJ_TREE= ;; esac
  [ "${#LJ_TREE}" = 40 ] || fail "the pin's commit object does not begin with a tree line
         ('$LJ_TREE_LINE')"
  LJ_TREE_RP=$(ljgit rev-parse --verify -q "$LJ_PIN^{tree}") || LJ_TREE_RP=
  [ "$LJ_TREE_RP" = "$LJ_TREE" ] || fail "git resolves $LJ_PIN^{tree} to '$LJ_TREE_RP', and the pin's commit object
         names the tree $LJ_TREE.  Likely causes: a forged or corrupted tree
         object in $LJ_CHECKOUT/.git (git's own error above, if any, names it),
         or GIT_* variables in the environment (set now: $(ljgitenv)).
         Re-clone the checkout."
  LJ_COMMIT=$LJ_PIN8
  say "pin     = met: the checkout's HEAD is the pin, whose commit object hashes to it and names the tree $LJ_TREE; step 1 compiles that tree (git archive, checked), not the working tree"
else
  LJ_HEAD=$(git_head "$OCLJ_LUAJIT")
  LJ_COMMIT=unpinned
  LJ_UNPINNED_NOTE="OCLJ_LUAJIT_UNPINNED=1: this native is the working tree of $OCLJ_LUAJIT (HEAD ${LJ_HEAD:-unknown, git cannot read it}), NOT the pin $LJ_PIN8 ($LJ_PIN_FILE)"
  {
    echo "WARNING: =========================================================="
    echo "WARNING: $LJ_UNPINNED_NOTE."
    echo "WARNING: Its blob fingerprint names the commit 'unpinned': gradle's verifyModAssets"
    echo "WARNING: refuses to package it, its blobs do not restore on a pinned native, nor a"
    echo "WARNING: pinned native's blobs on it, and it is not collected into $OCLJ_BUILD/dist."
    echo "WARNING: A local experiment only; never ship it."
    echo "WARNING: =========================================================="
  } >&2
  say "pin     = NOT MET: OCLJ_LUAJIT_UNPINNED=1 builds the checkout's working tree (HEAD ${LJ_HEAD:-unknown}), stamped 'unpinned'"
fi
JNLUA_COMMIT=$(git_head "$OCLJ_JNLUA" | cut -c1-8)
say "luajit  = $OCLJ_LUAJIT @ $LJ_COMMIT (feature set: native/luajit/oclj_features.h)"
say "jnlua   = $OCLJ_JNLUA @ ${JNLUA_COMMIT:-unknown}"
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
# (LJ_WORK, LJ_EXPORT and NEGI are set in the preflight's THE DIRECTORIES THIS
# SCRIPT REMOVES, which refuses a checkout inside any of them.)
# THE BUILD COPY IS MADE AFRESH ON EVERY RUN, from the tree this build names.
# Until 2026-10-20 it was copied from the checkout once, when missing, and kept:
# only the twelve patched files and our seven were re-taken, so every other
# file stayed whatever the first build (or a hand edit) left there.  After an
# OCLJ_LUAJIT_UNPINNED=1 build of the pin's parent 8c23d6aa, the next pinned
# build in the same OCLJ_BUILD compiled the parent's lj_opt_mem.c under the
# stamp 1ee778a4; and a checkout at the pin with an uncommitted edit compiled
# the edit (both measured 2026-10-20; gradle accepted both natives).  Keeping
# the copy saved nothing worth that: `make clean` below rebuilds every object
# on every run anyway, so it saved one copy of an ~8 MB tree.  So:
#   PINNED: the tree the pin's commit object names (LJ_TREE, links 1 and 2 in
#     the preflight's ljgit chain) is exported from the checkout's .git with
#     git archive into a fresh $LJ_EXPORT, checked (links 3 and 4: every tree
#     object hashes to its name, every exported file to its blob id, and the
#     export holds as many files as the tree lists), the build copy is made
#     from it, and every pristine re-take below reads it.  It is a TREE that
#     is archived, not the commit: archiving a commit applies the tree's
#     export-subst attribute, and LuaJIT's .gitattributes sets it on .relver,
#     which then holds the commit's date where the committed file holds
#     "$Format:%ct$" -- src/Makefile copies that into luajit_relver.txt, and
#     host/genversion.lua into LUAJIT_VERSION, so the version string, and the
#     blob fingerprint's second field with it, would change from "LuaJIT
#     2.1.ROLLING" (measured 2026-10-20).  A tree carries no commit, so nothing
#     is substituted.  ljgit archives with core.autocrlf=false and core.eol=lf,
#     so the export is the committed bytes on every host: every source file
#     and Makefile LF, as committed (only src/*build.bat, CRLF, and one PNG
#     hold a CR); until the build-copy round's review it followed the host's
#     git (CRLF under Windows' core.autocrlf=true, LF in AlmaLinux 8).  Any
#     conversion that is left -- a filter, ident, eol or working-tree-encoding
#     attribute, from the tree, .git/info/attributes, a user or system
#     attributes file, or configuration in the environment -- changes a
#     file's bytes, so its hash, and is a BUILD FAIL naming the file; an
#     export-ignore attribute drops a file, and is one too.  Then the
#     checkout's working tree is compared with
#     the export: a tracked file that differs or is missing is named in a
#     WARNING and is NOT built; files only in the checkout (build products,
#     .git) and line-ending differences do not count.
#   UNPINNED: the build copy is the checkout's working tree: a fresh directory
#     the checkout's contents are copied into (never the checkout's path
#     itself: GNU cp -r copies a symlinked source as the symlink, and the copy's
#     .git, removed next, was then the checkout's own, measured 2026-10-20 in
#     AlmaLinux 8).  It may hold no symlink either: cp -R copies a symlink in
#     the tree as a symlink, and the rm -f src/host/*.o that make clean runs,
#     run in a copy whose src/host was one, deleted the files of the directory
#     it named (a probe, 2026-10-20, AlmaLinux 8); make, the re-takes and the
#     patch scripts would write through one the same way.  The re-takes read
#     the checkout.
# Either way the previous copy and export are removed first.  They are build
# products of this script, never results: no runner writes into them.
LJ_DIRTY_NOTE=
rm -rf "$LJ_WORK" "$LJ_EXPORT"
rm -f "$LJ_EXPORT.tar" "$LJ_EXPORT.ls" "$LJ_EXPORT.got"
[ -e "$LJ_WORK" ] || [ -e "$LJ_EXPORT" ] && fail "cannot remove the previous build copy $LJ_WORK or $LJ_EXPORT"
if [ -z "$LJ_UNPINNED_NOTE" ]; then
  LJ_SRC=$LJ_EXPORT
  mkdir -p "$LJ_EXPORT" || fail "cannot create $LJ_EXPORT"
  # Link 3: every tree object under the root hashes to its name.  ls-tree's
  # list is written to a file first, so that its own failure is seen.
  ljgit ls-tree -r -d "$LJ_TREE" > "$LJ_EXPORT.ls" || fail "git ls-tree -r -d $LJ_TREE (the pin's tree) failed in $LJ_CHECKOUT/.git"
  LJ_TREES="$LJ_TREE $(cut -f1 "$LJ_EXPORT.ls" | cut -d' ' -f3 | tr '\n' ' ')"
  N_TREES=0
  for t in $LJ_TREES; do
    h=$(ljgit cat-file tree "$t" | ljgit hash-object -t tree --stdin 2>/dev/null) || h=
    [ "$h" = "$t" ] || fail "the tree object $t in $LJ_CHECKOUT/.git, which the pin's tree
         $LJ_TREE names, hashes to '$h', not to its name: git does not hold the
         pin's tree there.  Likely causes: a forged or corrupted object in that
         .git, or GIT_* variables that point git at other objects
         (GIT_OBJECT_DIRECTORY, GIT_ALTERNATE_OBJECT_DIRECTORIES, GIT_COMMON_DIR;
         set now: $(ljgitenv)).  Re-clone the checkout."
    N_TREES=$((N_TREES + 1))
  done
  ljgit archive --format=tar "$LJ_TREE" > "$LJ_EXPORT.tar" \
    || fail "git archive of the pin's tree $LJ_TREE from $LJ_CHECKOUT/.git failed"
  tar -x -C "$LJ_EXPORT" < "$LJ_EXPORT.tar" || fail "cannot unpack the pin's tree into $LJ_EXPORT"
  rm -f "$LJ_EXPORT.tar"
  # Link 4: the export holds exactly the files the tree lists, and each one's
  # bytes hash to the blob id the tree gives it.  hash-object reads the paths
  # relative to the export (--work-tree=. after the cd) and applies no filter.
  ljgit ls-tree -r "$LJ_TREE" > "$LJ_EXPORT.ls" || fail "git ls-tree -r $LJ_TREE (the pin's tree) failed in $LJ_CHECKOUT/.git"
  N_TREE=$(wc -l < "$LJ_EXPORT.ls" | tr -d ' ')
  N_EXP=$(find "$LJ_EXPORT" -type f -o -type l | wc -l | tr -d ' ')
  [ "$N_TREE" -gt 0 ] && [ "$N_EXP" = "$N_TREE" ] \
    || fail "the export $LJ_EXPORT holds $N_EXP files, and the pin's tree lists $N_TREE
         (git ls-tree -r $LJ_TREE): it is not the pin's committed tree.  Likely
         cause: an export-ignore attribute (the tree's .gitattributes,
         $LJ_CHECKOUT/.git/info/attributes, core.attributesFile, the system
         gitattributes, or configuration from the environment, GIT_* set now:
         $(ljgitenv)).  A pin whose tree sets one needs this step changed
         deliberately."
  cut -f2- "$LJ_EXPORT.ls" | ( CDPATH= cd -P -- "$LJ_EXPORT" && ljgit --work-tree=. hash-object --no-filters --stdin-paths ) \
    > "$LJ_EXPORT.got" || fail "cannot hash the files of the export $LJ_EXPORT (git hash-object --no-filters)"
  # paste: the id the tree lists, the id of the exported bytes, the ls-tree
  # line ("<mode> blob <id>", then a tab and the path).
  LJ_BAD=$(cut -f1 "$LJ_EXPORT.ls" | cut -d' ' -f3 | paste - "$LJ_EXPORT.got" "$LJ_EXPORT.ls" \
    | awk -F '\t' '$1 != $2 { print $4 }')
  N_GOT=$(wc -l < "$LJ_EXPORT.got" | tr -d ' ')
  if [ -n "$LJ_BAD" ] || [ "$N_GOT" != "$N_TREE" ]; then
    printf '%s\n' "$LJ_BAD" | head -20 | sed 's/^/    not the pin'"'"'s bytes: /'
    fail "the export $LJ_EXPORT is not the pin's committed tree byte for byte:
         $N_GOT of $N_TREE files hashed, and the files above do not hash to the
         blob ids the pin's tree gives them.  Likely causes: a filter, ident, eol
         or working-tree-encoding attribute (the tree's .gitattributes,
         $LJ_CHECKOUT/.git/info/attributes, core.attributesFile, the system
         gitattributes), configuration from the environment (GIT_CONFIG_COUNT,
         GIT_CONFIG_PARAMETERS, GIT_ATTR_SOURCE; GIT_* set now: $(ljgitenv)), or a
         forged or corrupted blob in $LJ_CHECKOUT/.git.  Re-clone the checkout, or
         remove the attribute or variable."
  fi
  rm -f "$LJ_EXPORT.ls" "$LJ_EXPORT.got"
  say "    export verified: the commit object hashes to the pin, $N_TREES trees to their names, $N_GOT files to the pin's blob ids"
  say "copying the pin's tree ($N_EXP files, git archive $LJ_TREE) -> $LJ_EXPORT -> $LJ_WORK"
  LJ_DIRTY=$(diff -rq --strip-trailing-cr "$LJ_EXPORT" "$LJ_CHECKOUT" 2>&1 | while IFS= read -r l; do
      case $l in
        "Only in $LJ_CHECKOUT: "*|"Only in $LJ_CHECKOUT/"*) ;;
        *) printf '%s\n' "$l" ;;
      esac
    done)
  if [ -n "$LJ_DIRTY" ]; then
    LJ_NDIRTY=$(printf '%s\n' "$LJ_DIRTY" | wc -l | tr -d ' ')
    LJ_DIRTY_NOTE="the LuaJIT checkout's working tree differs from the pin's committed tree in $LJ_NDIRTY tracked path(s), and those edits are NOT built"
    {
      echo "WARNING: =========================================================="
      echo "WARNING: $LJ_DIRTY_NOTE."
      echo "WARNING: This build compiles the pin's committed tree (git archive, checked against"
      echo "WARNING: the pin's 40 digits), and $OCLJ_LUAJIT's working tree differs from it here:"
      printf '%s\n' "$LJ_DIRTY" | head -20 | sed 's/^/WARNING:   /'
      [ "$LJ_NDIRTY" -le 20 ] || echo "WARNING:   ... and $((LJ_NDIRTY - 20)) more"
      echo "WARNING: To build the edits, for a local experiment whose native never ships,"
      echo "WARNING: set OCLJ_LUAJIT_UNPINNED=1."
      echo "WARNING: =========================================================="
    } >&2
    say "    working tree: $LJ_NDIRTY tracked path(s) differ from the pin's tree; NOT built (WARNING above)"
  else
    say "    working tree: no tracked file differs from the pin's tree (diff -rq --strip-trailing-cr)"
  fi
  cp -r "$LJ_EXPORT" "$LJ_WORK" || fail "cannot copy $LJ_EXPORT to $LJ_WORK"
else
  LJ_SRC=$OCLJ_LUAJIT
  say "copying the working tree $OCLJ_LUAJIT -> $LJ_WORK (OCLJ_LUAJIT_UNPINNED=1; the checkout itself is never built in or dirtied)"
  mkdir "$LJ_WORK" || fail "cannot create $LJ_WORK"
  cp -R "$OCLJ_LUAJIT/." "$LJ_WORK/" || fail "cannot copy the contents of $OCLJ_LUAJIT into $LJ_WORK"
  [ -L "$LJ_WORK" ] && fail "$LJ_WORK is a symlink after the copy: removing its .git could
         delete the checkout's.  Nothing was removed."
  rm -rf "$LJ_WORK/.git"
  LJ_LINKS=$(find "$LJ_WORK" -type l | head -10)
  [ -z "$LJ_LINKS" ] || fail "the copy of $OCLJ_LUAJIT holds symlinks:
$LJ_LINKS
         The build copy is built in: make clean deletes, and make, the re-takes
         and the patch scripts write, inside it, and through a symlink they would
         do it in whatever the link names, the checkout included.  Replace the
         links with the files, in a scratch clone.  Nothing was built."
fi
LJ=$LJ_WORK/src
# THE CHECKHOOK OPTION, in the tree that is compiled (the pin's export, or the
# working tree when unpinned).  It was a preflight check of the checkout's
# working tree until 2026-10-20, so a pinned build of a checkout that had
# lost src/lj_record.c failed "no LuaJIT source", though the export held the
# file; now that file is named in the WARNING above, and the pin builds.
[ -f "$LJ_SRC/src/lj_record.c" ] || fail "no $LJ_SRC/src/lj_record.c: not a LuaJIT source tree"
grep -q LUAJIT_ENABLE_CHECKHOOK "$LJ_SRC/src/lj_record.c" \
  || fail "$LJ_SRC/src/lj_record.c has no LUAJIT_ENABLE_CHECKHOOK option: not a
         LuaJIT 2.x tree.  Use the pinned checkout (prototype/watchdog/luajit, upstream
         $LJ_PIN8, native/luajit/upstream.commit; make -C prototype/watchdog luajit-src)."
# THE COLLECTOR-STATE ENUM MUST STILL BEGIN WITH GCSpause.
# lj52shim.c spells GCSpause as the literal 0 (LJ52_GCS_PAUSE) rather than
# including lj_gc.h, because that header also declares lj_gc_step and
# lj_gc_fullgc and the gate below forbids those from reaching the shim's scope.
# That trade is only safe if the assumption is checked, so check it, in the
# copy that is compiled.  The enum is lj_gc.h:11-14 and its own comment says
# "Order matters."
LJGC_H="$LJ/lj_gc.h"
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
# THE FIRST OF THE TWELVE LUAJIT CHANGES, on the copy, every
# build.  The copy
# persisted between builds until 2026-10-20 (THE BUILD COPY, above), and the
# patch script's "already patched" path
# verifies only four marker lines -- so a stale or hand-edited block on the
# copy (say `pc < bcend` turned into `pc < bc`) would be ACCEPTED and ship
# silently, and a revised block in the script would never reach a copy that
# already carries the old one.  Demonstrated 2026-09-22: the script alone,
# run in place on such a mangling, exits 0 "already carries the penalty
# scrub" and leaves the mangled line in.
#
# So the copy's lj_func.c is never the patch's input.  The PRISTINE source's
# file ($LJ_SRC: the pin's export, or the checkout when unpinned) is re-copied
# over it first, every build, on every platform, and the
# patch is applied to that: the file make compiles is then a pure function of
# (source tree, patch script), byte-identical to a fresh patch of the pristine
# source, and the "already patched" path is never taken here (asserted: the
# scrub must be ABSENT right after the re-copy).  The pre-make content
# assertion and the lj_func.o -nt check below pin the rest.  The copy is now
# fresh on every run as well, so the re-take is a second guard, kept.
SCRUB_LINE='setmref(J->penalty[i].pc, NULL);'
grep -q -F -- "$SCRUB_LINE" "$LJ_SRC/src/lj_func.c" \
  && fail "$LJ_SRC/src/lj_func.c carries the penalty scrub: the LuaJIT
         source must stay pristine.  The patch belongs on the build copy only."
cp -f "$LJ_SRC/src/lj_func.c" "$LJ/lj_func.c" \
  || fail "cannot re-copy the pristine $LJ_SRC/src/lj_func.c over $LJ/lj_func.c"
grep -q -F -- "$SCRUB_LINE" "$LJ/lj_func.c" \
  && fail "$LJ/lj_func.c still carries the penalty scrub right after the pristine
         re-copy -- the copy did not take, and the patch step would have been
         verifying a stale block instead of applying the current one"
say "    lj_func.c: pristine copy re-taken from $LJ_SRC/src (the build copy is never the patch's input)"
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
# pristine source asserted, re-copied, the clamp ABSENT after the copy,
# patched, present exactly twice (once per push) before make, lj_err.o newer
# after.  The absence checks match any form of the guard, so a source tree that a
# different version of the patch dirtied is refused for that reason.
ERRMEM_ANY='L->top < L->base'
ERRMEM_LINE='  if (LJ_UNLIKELY(L->top < L->base))'
grep -q -F -- "$ERRMEM_ANY" "$LJ_SRC/src/lj_err.c" \
  && fail "$LJ_SRC/src/lj_err.c carries the ERRMEM top clamp: the LuaJIT
         source must stay pristine.  The patch belongs on the build copy only."
cp -f "$LJ_SRC/src/lj_err.c" "$LJ/lj_err.c" \
  || fail "cannot re-copy the pristine $LJ_SRC/src/lj_err.c over $LJ/lj_err.c"
grep -q -F -- "$ERRMEM_ANY" "$LJ/lj_err.c" \
  && fail "$LJ/lj_err.c still carries the ERRMEM top clamp right after the
         pristine re-copy -- the copy did not take"
say "    lj_err.c: pristine copy re-taken from $LJ_SRC/src"
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
# pristine source asserted, re-copied, the fallback ABSENT after the copy,
# patched, present exactly once before make, lj_ffrecord.o newer after; the
# FFI / integer-format gate after the CHECKHOOK probe proves the loop compiles
# and prints what the interpreter prints.
FMTX_MARK='OC-LuaJIT (native/luajit/patch-strfmt-xint-noffi.sh)'
grep -q -F -- "$FMTX_MARK" "$LJ_SRC/src/lj_ffrecord.c" \
  && fail "$LJ_SRC/src/lj_ffrecord.c carries the no-FFI integer-format fallback:
         the LuaJIT source must stay pristine.  The patch belongs on the build copy only."
cp -f "$LJ_SRC/src/lj_ffrecord.c" "$LJ/lj_ffrecord.c" \
  || fail "cannot re-copy the pristine $LJ_SRC/src/lj_ffrecord.c over $LJ/lj_ffrecord.c"
grep -q -F -- "$FMTX_MARK" "$LJ/lj_ffrecord.c" \
  && fail "$LJ/lj_ffrecord.c still carries the integer-format fallback right after the
         pristine re-copy -- the copy did not take"
say "    lj_ffrecord.c: pristine copy re-taken from $LJ_SRC/src"
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
# pristine source and patched like the three .c files; and the include must
# be there exactly once, directly after lua.h, before make runs.
FEAT_INC='#include "oclj_features.h"'
grep -q -F -- "$FEAT_INC" "$LJ_SRC/src/lj_arch.h" \
  && fail "$LJ_SRC/src/lj_arch.h includes oclj_features.h: the LuaJIT source must
         stay pristine.  The include belongs on the build copy only."
[ -e "$LJ_SRC/src/oclj_features.h" ] \
  && fail "$LJ_SRC/src/oclj_features.h exists: the LuaJIT source must stay pristine.
         The feature header lives in native/luajit and is copied to the build copy only."
cp -f "$LJ_SRC/src/lj_arch.h" "$LJ/lj_arch.h" \
  || fail "cannot re-copy the pristine $LJ_SRC/src/lj_arch.h over $LJ/lj_arch.h"
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
# pristine source asserted (no registration, no oclj_strpack.c), lib_string.c
# re-copied, the registration ABSENT after the copy, the code copied and
# compared, patched, present exactly once before make; after make,
# lib_string.o newer than both files, the fast-function table naming all
# three, and the luajit.exe gate below.
STRPACK_MARK='OC-LuaJIT (native/luajit/patch-strpack-register.sh)'
STRPACK_C=$OCLJ_REPO/native/luajit/oclj_strpack.c
[ -f "$STRPACK_C" ] || fail "no $STRPACK_C: the code of string.pack/packsize/unpack"
grep -q -F -- "$STRPACK_MARK" "$LJ_SRC/src/lib_string.c" \
  && fail "$LJ_SRC/src/lib_string.c registers string.pack: the LuaJIT source must stay
         pristine.  The registration belongs on the build copy only."
[ -e "$LJ_SRC/src/oclj_strpack.c" ] \
  && fail "$LJ_SRC/src/oclj_strpack.c exists: the LuaJIT source must stay pristine.
         The code lives in native/luajit and is copied to the build copy only."
cp -f "$LJ_SRC/src/lib_string.c" "$LJ/lib_string.c" \
  || fail "cannot re-copy the pristine $LJ_SRC/src/lib_string.c over $LJ/lib_string.c"
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
# above, per file: the pristine source asserted (no round-3 marker, none of
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
  [ -e "$LJ_SRC/src/$f" ] \
    && fail "$LJ_SRC/src/$f exists: the LuaJIT source must stay pristine.
         The file lives in native/luajit and is copied to the build copy only."
  cp -f "$OCLJ_REPO/native/luajit/$f" "$LJ/$f" || fail "cannot copy native/luajit/$f into $LJ"
  cmp -s "$OCLJ_REPO/native/luajit/$f" "$LJ/$f" \
    || fail "$LJ/$f differs from $OCLJ_REPO/native/luajit/$f right after the copy"
done
say "    $BITOP_FILES: copied from native/luajit and compared"
for p in $BITOP_PATCHES; do
  f=${p%%:*}
  s=patch-bitop-${p#*:}.sh
  grep -q -F -- "$BITOP_ANY" "$LJ_SRC/src/$f" \
    && fail "$LJ_SRC/src/$f carries a round-3 bit-operator patch: the LuaJIT source must
         stay pristine.  The patch belongs on the build copy only."
  cp -f "$LJ_SRC/src/$f" "$LJ/$f" \
    || fail "cannot re-copy the pristine $LJ_SRC/src/$f over $LJ/$f"
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
# function that calls their entry points, oclj_bitop_fold.c's two helpers
# (oclj_bitwidth and FIX-NUMCONV's oclj_isnumconv) and oclj_bitop.h's and
# oclj_num53.h's functions (an uncalled static inline function is never
# compiled, so the warnings that need code generation would miss it, and an
# uncalled static function that is not inline fails -Wunused-function).
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
    oclj_isnumconv(J, 0) +
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
# Absolute paths: the three runs cd into $LJ first (cd -P, as everywhere here;
# $OCLJ_BUILD is physical already: THE INPUT DIRECTORIES, in the preflight).
JL_DIR=$(CDPATH= cd -P -- "$OCLJ_BUILD" && pwd -P)
JL_PROBE=$JL_DIR/jitlib.lua
JL_EXE=./$(basename "$LJEXE")
JL_LINE=$(CDPATH= cd -P -- "$LJ" && LUA_PATH='./?.lua' "$JL_EXE" "$JL_PROBE" 2>&1 | tr -d '\r')
JL_BL=$(CDPATH= cd -P -- "$LJ" && LUA_PATH='./?.lua' "$JL_EXE" -bl "$JL_PROBE" 2>"$JL_DIR/jitlib-bl.err" | tr -d '\r')
JL_JD=$(CDPATH= cd -P -- "$LJ" && LUA_PATH='./?.lua' "$JL_EXE" -jdump=T "$JL_PROBE" 2>&1 | tr -d '\r')
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
# NEGI is $OCLJ_BUILD/layoutneg-<platform>, set in the preflight's THE
# DIRECTORIES THIS SCRIPT REMOVES, which refuses a checkout inside it.
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
# above names the LUAJIT tree (the pin), so every edit to eris_lj.c shipped under an
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

# BEGIN ELF IMPORT GATE (the markers let a test run this text on any .so)
# ELF: EVERY IMPORT CARRIES A SYMBOL VERSION, AND THE GLIBC THE LIBRARY NEEDS
# IS MEASURED.
#
# A Linux .so fails to load on an older distribution in one way: it needs a
# symbol version that glibc lacks ("version `GLIBC_2.38' not found").  Each
# import carries the newest version the BUILD host's glibc offered for that
# symbol, so the floor is the build host's: the .so built on Ubuntu 26.04
# needs GLIBC_2.38 and loads on neither Ubuntu 22.04, Debian 12 nor RHEL 9.
# The release floor is GLIBC_2.28, the release .so is built in AlmaLinux 8,
# and gradle's verifyModAssets refuses a .so above the floor.  Here,
# OCLJ_GLIBC_MAX set makes the limit a BUILD FAIL (the release build); unset,
# the verdict against the floor is reported and the build goes on (a
# development build).  A version outside the GLIBC_x.y family counts against
# the limit too: GLIBC_PRIVATE ties the library to one glibc build, and GCC_x.y
# means libgcc_s, which -static-libgcc keeps out (measured: a link without it
# needs GCC_3.0 and GCC_3.3).
#
# An UNVERSIONED import is refused whatever the limit.  It names no library and
# no version, so it binds to whatever the host process has loaded: the six
# pthread functions of a link without -pthread on glibc 2.28 did, inside a JVM,
# and in a host without libpthread the same .so loads lazily, then exits at its
# first pthread_create ("symbol lookup error: undefined symbol: pthread_create";
# ldd -r shows all six, ldd -d none).  LINK_EXTRA's --no-undefined stops that at
# the link; this checks the artifact, so a dropped flag cannot pass silently.
# A WEAK undefined reference (__gmon_start__, the TM clone hooks) is optional
# by definition: listed, not refused.
#
# readelf, not objdump: its "name@GLIBC_x.y" spelling and its columns are the
# same in binutils 2.30 (AlmaLinux 8) and 2.46 (Ubuntu 26.04), and -V prints
# the version NEEDS (.gnu.version_r), which are what the loader checks.
# objdump -T 2.46 puts a reference's version in parentheses and prints an
# unversioned one as "Base" or as nothing, depending on the file.  -W stops
# readelf truncating names.  Versions compare component by component (2.4 <
# 2.17 < 2.38), by the one awk function below, never as strings.
#
# FreeBSD is ELF without glibc and stops at the shim's #error before the
# link, so only Linux is checked.
if [ "$OCLJ_OS" = linux ]; then
  SOF=$OCLJ_OUT/$DLL_NAME
  command -v readelf >/dev/null 2>&1 || fail "no readelf on PATH: it reads the library's imports and the
       glibc versions they need (binutils, the package the linker comes in)"
  VGT='function vgt(a, b,   x, y, na, nb, i, p, q) {
    na = split(a, x, "[.]"); nb = split(b, y, "[.]")
    for (i = 1; i <= na || i <= nb; i++) {
      p = (i <= na) ? x[i] + 0 : 0; q = (i <= nb) ? y[i] + 0 : 0
      if (p != q) return (p > q)
    }
    return 0
  }
'
  DYN=$(readelf --dyn-syms -W "$SOF") || fail "readelf --dyn-syms failed on $SOF"
  UND=$(printf '%s\n' "$DYN" | awk '$1 ~ /^[0-9]+:$/ && $7 == "UND" && NF >= 8')
  # THE READER FIRST.  On a truncated file readelf prints no symbols and exits
  # 0, and an empty list would pass every check below vacuously.
  NUND=$(printf '%s\n' "$UND" | grep -c .)
  [ "$NUND" -gt 0 ] || fail "readelf listed no undefined dynamic symbols in $SOF: the reader is
       not reading, and the import checks would pass vacuously"
  UNV=$(printf '%s\n' "$UND" | awk '$5 != "WEAK" && $8 !~ /@/ {print $8}' | sort -u | tr '\n' ' ')
  [ -z "$UNV" ] || fail "$DLL_NAME imports these symbols with NO version: $UNV
       Each binds to whatever the host process happens to have loaded, and a host
       without it cannot load the library.  The link must name the library that
       defines them (LINK_EXTRA: -pthread, for the pthread functions before glibc 2.34)."
  WEAKU=$(printf '%s\n' "$UND" | awk '$5 == "WEAK" && $8 !~ /@/ {print $8}' | sort -u | tr '\n' ' ' | sed 's/ *$//')
  # The version needs, one "<version> <file>" line each, from the needs section only.
  NEEDS=$(readelf -V -W "$SOF" | awk '/Version needs section/ {s = 1; next} /Version [a-z]+ section/ {s = 0}
    s {for (i = 1; i < NF; i++) {if ($i == "File:") f = $(i + 1); if ($i == "Name:") print $(i + 1), f}}')
  GMAX=$(printf '%s\n' "$NEEDS" | awk "$VGT"'$1 ~ /^GLIBC_[0-9]+([.][0-9]+)+$/ {v = substr($1, 7); if (m == "" || vgt(v, m)) m = v} END {print m}')
  [ -n "$GMAX" ] || fail "readelf -V found no GLIBC_x.y version need in $SOF: no evidence of
       which glibc it needs"
  NEEDED=$(readelf -d -W "$SOF" | awk '$2 == "(NEEDED)" {print $NF}' | tr -d '[]' | tr '\n' ' ' | sed 's/ *$//')
  say "    ELF imports: $NUND undefined, every non-weak one versioned (weak and unversioned: ${WEAKU:-none})"
  say "    NEEDED: $NEEDED"
  LIMIT=${OCLJ_GLIBC_MAX:-$GLIBC_FLOOR}
  ABOVE=$(printf '%s\n' "$NEEDS" | awk -v lim="$LIMIT" "$VGT"'$1 ~ /^GLIBC_[0-9]+([.][0-9]+)+$/ && vgt(substr($1, 7), lim) {print $1 " (" $2 ")"}' | sort -u | tr '\n' ' ' | sed 's/ *$//')
  ODD=$(printf '%s\n' "$NEEDS" | awk 'NF && $1 !~ /^GLIBC_[0-9]+([.][0-9]+)+$/ {print $1 " (" $2 ")"}' | sort -u | tr '\n' ' ' | sed 's/ *$//')
  SYMA=$(printf '%s\n' "$UND" | awk -v lim="$LIMIT" "$VGT"'{n = index($8, "@GLIBC_"); if (n && vgt(substr($8, n + 7), lim)) print $8}' | sort -u)
  NSYMA=$(printf '%s\n' "$SYMA" | grep -c .)
  SYMA=$(printf '%s\n' "$SYMA" | head -12 | tr '\n' ' ' | sed 's/ *$//')
  HA="this host's glibc is too new: the release .so is built in AlmaLinux 8 (glibc 2.28; PREREQUISITES 7)"
  HO="GLIBC_PRIVATE ties it to one glibc build; GCC_x.y is libgcc_s, which LINK_EXTRA's -static-libgcc keeps out"
  if [ -n "$OCLJ_GLIBC_MAX" ]; then
    [ -z "$ABOVE$ODD" ] || fail "$DLL_NAME needs more than OCLJ_GLIBC_MAX=$OCLJ_GLIBC_MAX allows (highest GLIBC_x.y: GLIBC_$GMAX).
       Needs above GLIBC_$LIMIT: ${ABOVE:-none}
       Needs outside GLIBC_x.y: ${ODD:-none}
       $NSYMA imports above GLIBC_$LIMIT${SYMA:+, e.g. }$SYMA${ABOVE:+
       Above: $HA}${ODD:+
       Outside: $HO}"
    say "    glibc: highest version needed GLIBC_$GMAX, within OCLJ_GLIBC_MAX=$OCLJ_GLIBC_MAX"
  elif [ -z "$ABOVE$ODD" ]; then
    say "    glibc: highest version needed GLIBC_$GMAX, within the release floor GLIBC_$GLIBC_FLOOR (OCLJ_GLIBC_MAX unset: not enforced)"
  else
    say "    glibc: highest version needed GLIBC_$GMAX, NOT within the release floor GLIBC_$GLIBC_FLOOR (OCLJ_GLIBC_MAX unset: not enforced)"
    [ -z "$ABOVE" ] || say "        needs above the floor: $ABOVE"
    [ -z "$ABOVE" ] || say "        $NSYMA imports above it, e.g. $SYMA"
    [ -z "$ABOVE" ] || say "        $HA"
    [ -z "$ODD" ]   || say "        needs outside GLIBC_x.y: $ODD"
    [ -z "$ODD" ]   || say "        $HO"
    say "        A development build: gradle's verifyModAssets refuses to package this .so."
  fi
fi
# END ELF IMPORT GATE

SZ=$(wc -c < "$OCLJ_OUT/$DLL_NAME")
SHA=$(sha256sum "$OCLJ_OUT/$DLL_NAME" 2>/dev/null | cut -c1-16)
stamp "OK  $OCLJ_OUT/$DLL_NAME  ${SZ} bytes  sha256:${SHA}..."
[ -z "$LJ_UNPINNED_NOTE" ] || echo "WARNING: $LJ_UNPINNED_NOTE.  gradle refuses to package it, its blobs do not restore on a pinned native, and it is not collected into dist." >&2
[ -z "$LJ_DIRTY_NOTE" ] || echo "WARNING: $LJ_DIRTY_NOTE: this native is the pin's committed tree (see the WARNING in step 1)." >&2

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
#
# Nor is an UNPINNED native (OCLJ_LUAJIT_UNPINNED=1): gradle refuses it, so in
# dist it would only displace the release library, and the next jar build
# would fail until a pinned rebuild.
if [ "$OCLJ_VARIANT" = additive ] && [ -n "$LJ_UNPINNED_NOTE" ]; then
  say "NOT collected into $OCLJ_BUILD/dist: an OCLJ_LUAJIT_UNPINNED=1 native never ships (dist left as it was)"
elif [ "$OCLJ_VARIANT" = additive ]; then
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
# 1. MinGW-w64 x86_64 gcc (msvcrt or ucrt), on PATH.  GNU make comes with it
#    as mingw32-make; this script calls `make`, so put a two-line `make` that
#    runs mingw32-make on PATH too.  THE RELEASE DLL IS BUILT WITH WinLibs'
#    gcc 16.2.0 (x86_64-msvcrt-posix-seh, "built by Brecht Sanders, r1", which
#    the DLL's own GCC strings name), binutils 2.47 and GNU make 4.4.1
#    (2026-10-20).  The toolchain is not pinned (THE BUILD ENVIRONMENT): another
#    gcc builds, and gives other objects.
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
#    prototype/watchdog luajit-src` clones it and checks the pin out), at the
#    upstream commit native/luajit/upstream.commit names (1ee778a4 when this
#    was written; THE PIN, in the preflight, which refuses any other HEAD
#    unless OCLJ_LUAJIT_UNPINNED=1), with git on PATH and the checkout's own
#    .git, from which step 1 exports the pin's committed tree (git archive,
#    checked object by object against the pin's 40 digits: EVERY GIT CALL ON
#    THE PINNED PATH, in the preflight), whose LUAJIT_ENABLE_CHECKHOOK is
#    upstream's own option (lj_record.c:691, :2953).  The checkout stays
#    pristine: this script builds a COPY with
#    native/luajit/oclj_features.h and the twelve changes in native/luajit/
#    (the fifth adds native/luajit/oclj_strpack.c to lib_string.c; the sixth
#    to the twelfth, round 3's seven patch-bitop-*.sh, patch seven files and
#    add oclj_bitop.h, oclj_bitop_meta.c, oclj_bitop_rec.c, oclj_bitop_fold.c
#    and oclj_num53.h to them).  Another LuaJIT commit is untested, and
#    refused unless OCLJ_LUAJIT_UNPINNED=1; past that, the twelve patch
#    scripts' exactly-once anchors and the behaviour gates are what refuse a
#    tree that changed shape.  Bumping the pin: docs/jit-guide.md 8.2a.
#
# 5. For OCLJ_VARIANT=additive only: Python 3 (python3 or python on PATH, or
#    OCLJ_PYTHON), to regenerate LuaStateLuaJIT.java and compare it with the
#    committed copy.  Any Python 3; the generator uses the standard library.
#
# 6. Nothing else.  eris_lj.c and lj52shim.c are in this repo.
#
# 7. On Linux: gcc, GNU make, binutils (readelf, objdump, nm), a JDK's
#    include/ directory (jni.h and linux/jni_md.h), and item 5's Python 3.
#    THE RELEASE .so IS BUILT IN ALMALINUX 8 (glibc 2.28, gcc 8.5.0 20210514
#    "Red Hat 8.5.0-29", which the .so's .comment names, binutils 2.30, GNU
#    make 4.2.1; the JDK from java-1.8.0-openjdk-devel), with
#    OCLJ_GLIBC_MAX=2.28 (the toolchain is not pinned, as on Windows):
#      OCLJ_JNI=/usr/lib/jvm/java-1.8.0-openjdk/include
#    Each import carries the version the LINKING host's glibc offers for it,
#    so the floor is the build host's: Ubuntu 26.04 (glibc 2.43, gcc 15.2)
#    gives a .so that needs GLIBC_2.38 (fmod, __isoc23_strtoul) and does not
#    load on Ubuntu 22.04, Debian 12 or RHEL 9 (2026-10-19).  Step 6 reports
#    it, or enforces OCLJ_GLIBC_MAX.
#    And git (AlmaLinux 8: dnf install git; it has git 2.43.7): a pinned
#    build refuses to run without it ("no git on PATH"), because it exports
#    the pin's tree with git archive and checks the checkout's HEAD.  The
#    blob fingerprint's commit is the pin's first 8 digits, as on Windows; a
#    native that stamped "unknown" (AlmaLinux 8 before 2026-10-19) could
#    never restore a blob another build wrote (eris_lj.c refuses a blob whose
#    fingerprint differs).
#
# The smoke test needs three more things (ocelot-brain, its jar deps, and a
# Scala compiler); see the header of smoke-test.sh.
# =====================================================================
