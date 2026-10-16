import sys

def patch(path, pairs):
    s = open(path, "r", encoding="utf-8", newline="").read()
    for old, new in pairs:
        n = s.count(old)
        if n != 1:
            sys.exit("%s: anchor found %d times: %r" % (path, n, old[:90]))
        s = s.replace(old, new)
    if "\r" in s:
        sys.exit("%s: CR present" % path)
    open(path, "w", encoding="utf-8", newline="").write(s)
    print("patched", path, len(pairs))

R = "C:/Users/astro/Downloads/OC-LuaJIT/"
P = []
# E4: the %x slowdown with its condition (header)
P.append((
"#              stitches around the call and a hot loop runs 1.6-2.1x slower\n"
"#              (2026-10-16); the patch formats",
"#              stitches around the call and a hot loop runs 1.6-2.1x slower\n"
"#              when its strings repeat, 1.2x when each is new (2026-10-16);\n"
"#              the patch formats"))
# A-build-3 (missed): the header's claim, scoped to the census
P.append((
"# from `1LL`), and an #error for every other LuaJIT option that changes a\n"
"# structure, the bytecode or what a gate here measures.  It is ONE file, read",
"# from `1LL`), and an #error for every other option the pinned LuaJIT tests\n"
"# that changes a structure, the bytecode, the unwinder or what a gate here\n"
"# measures (a census of its LUAJIT_* conditionals, 2026-10-16).  It is ONE\n"
"# file, read"))
# A-build-6: the Linux NOTE is stale (the shim has a pthread watchdog backend)
P.append((
'if [ "$OCLJ_OS" != windows ]; then\n'
"  # NOT A REFUSAL -- the build script is portable and everything up to the shim\n"
"  # works here (LuaJIT with -fPIC, the naming, the ELF postflight).  What is not\n"
"  # portable yet is lj52shim.c's deadline watchdog, which is a Win32 timer queue;\n"
"  # the shim REFUSES rather than silently building an untested backend, at\n"
"  # lj52shim.c:498.  Saying so now means the cause is named before the twenty\n"
"  # seconds of LuaJIT, instead of being inferred from the cascade of errors that\n"
"  # gcc emits after an #error it has already reported.\n"
'  say "    NOTE: on $OCLJ_OS this build is expected to stop in step 2 at"\n'
'  say "          lj52shim.c:498 -- the deadline watchdog has only a Win32 backend."\n'
'  say "          A POSIX one is a roadmap item; everything before it works here."\n'
"fi\n",
'if [ "$OCLJ_OS" != windows ] && [ "$OCLJ_OS" != linux ]; then\n'
"  # NOT A REFUSAL -- the build script is portable and everything up to the shim\n"
"  # works here (LuaJIT with -fPIC, the naming, the ELF postflight).  What is not\n"
"  # portable is lj52shim.c's deadline watchdog: it has a Win32 timer-queue\n"
"  # backend and a Linux pthread one, and on any other host the shim REFUSES with\n"
"  # an #error rather than silently building an untested backend.  Saying so now\n"
"  # means the cause is named before the twenty seconds of LuaJIT, instead of\n"
"  # being inferred from the cascade of errors that gcc emits after an #error it\n"
"  # has already reported.\n"
'  say "    NOTE: on $OCLJ_OS this build is expected to stop in step 2 at lj52shim.c\'s"\n'
'  say "          #error \\"lj52 watchdog: only the Win32 and Linux backends exist\\"."\n'
'  say "          Everything before it works here."\n'
"fi\n"))
# A-build-2 / E3 / X3: the preflight cannot tell a stock clone; say what it does test
P.append((
'  || fail "$OCLJ_LUAJIT is a STOCK LuaJIT: lj_record.c has no LUAJIT_ENABLE_CHECKHOOK.\n'
"         Machine.lua cannot boot with the JIT on against a stock tree.\n"
'         Use the pinned tree in this repo (prototype/watchdog/luajit)."\n',
'  || fail "$OCLJ_LUAJIT/src/lj_record.c has no LUAJIT_ENABLE_CHECKHOOK option: not a\n'
"         LuaJIT 2.x tree.  Use the pinned checkout (prototype/watchdog/luajit, upstream\n"
'         1ee778a4; make -C prototype/watchdog luajit-src)."\n'))
# E4: the third change's comment
P.append((
"# on an int-typed operand: the trace stitches around the call, and a hot loop\n"
"# runs 1.6-2.1x slower (2026-10-16).  Same steps as the scrub and the clamp:\n",
"# on an int-typed operand: the trace stitches around the call, and a hot loop\n"
"# runs 1.6-2.1x slower when its strings repeat, 1.2x when each is new\n"
"# (2026-10-16).  Same steps as the scrub and the clamp:\n"))
# A-build-3: G3 as an allowlist (also catches -D LUAJIT_x with a space, NO_UNWIND, UNWIND_INTERNAL)
P.append((
"# Makefile's own -DLUAJIT_TARGET, and LUAJIT_UNWIND_EXTERNAL on Linux, are\n"
"# platform facts, not features, and are allowed.\n"
"if grep -qE -- '-DLUAJIT_(ENABLE|DISABLE|USE|SECURITY)_|-DLUAJIT_NUMMODE' \"$OCLJ_BUILD/luajit_build.log\"; then\n"
"  grep -oE -- '-DLUAJIT_(ENABLE|DISABLE|USE|SECURITY)_[A-Z0-9_]*|-DLUAJIT_NUMMODE[^ ]*' \"$OCLJ_BUILD/luajit_build.log\" | sort | uniq -c\n"
'  fail "a LuaJIT feature macro reached the compiler command line (counted above).  The\n',
"# Makefile's own -DLUAJIT_TARGET, and LUAJIT_UNWIND_EXTERNAL on Linux, are\n"
"# platform facts, not features, and are allowed.  An ALLOWLIST: every other\n"
"# LUAJIT_* on a compile line is refused, with or without a space after -D,\n"
"# including the ones the header does not name.\n"
"G3BAD=$(grep -oE -- '-D *LUAJIT_[A-Za-z0-9_]+' \"$OCLJ_BUILD/luajit_build.log\" | tr -d ' ' \\\n"
"  | grep -vxE -- '-DLUAJIT_(TARGET|UNWIND_EXTERNAL)' | sort | uniq -c)\n"
'if [ -n "$G3BAD" ]; then\n'
'  echo "$G3BAD"\n'
'  fail "a LuaJIT feature macro reached the compiler command line (counted above).  The\n'))
# E4: the gate's failure text
P.append((
"of compiling (native/luajit/patch-strfmt-xint-noffi.sh is not in effect): every\n"
"           hot %x, %o, %u or %5d of an int runs about 2x slower.\n",
"of compiling (native/luajit/patch-strfmt-xint-noffi.sh is not in effect): a\n"
"           hot %x, %o, %u or %5d of an int runs up to about 2x slower.\n"))
# E2: stage 1b's history sentence
P.append((
"# and fails unless sizeof(GG_State) there is the same number.  Until\n"
"# 2026-10-16 it included only <lua.h>, and it printed FOREIGN-ALLOC-OK\n"
"# against an archive whose layout the shim did not share.  The NEGATIVE ARM\n",
"# and fails unless sizeof(GG_State) there is the same number.  Until\n"
"# 2026-10-16 it included only <lua.h>, so it could not see layout: linked\n"
"# against a no-FFI archive it still printed FOREIGN-ALLOC-OK (measured\n"
"# 2026-10-16; HEAD's own archive and shim agreed, 6384 both).  The NEGATIVE ARM\n"))
# A-build-5 (a): LJ_GG must be digits only
P.append((
"    fail \"the allocator/layout probe said '$PROBE'\" ;;\n"
"esac\n"
"NEGI=$OCLJ_BUILD/layoutneg-$PLATFORM\n",
"    fail \"the allocator/layout probe said '$PROBE'\" ;;\n"
"esac\n"
"case $LJ_GG in ''|*[!0-9]*) fail \"the allocator/layout probe said '$PROBE'\" ;; esac\n"
"NEGI=$OCLJ_BUILD/layoutneg-$PLATFORM\n"))
# A-build-5 (b): keep the negative arm's compiler output
P.append((
"  -o \"$OCLJ_BUILD/allocprobe-neg.exe\" >/dev/null 2>&1 \\\n"
"  || fail \"the layout gate's negative arm would not compile or link\"\n",
"  -o \"$OCLJ_BUILD/allocprobe-neg.exe\" >\"$OCLJ_BUILD/allocprobe-neg.err\" 2>&1 \\\n"
"  || { head -5 \"$OCLJ_BUILD/allocprobe-neg.err\"; fail \"the layout gate's negative arm would not compile or link\"; }\n"))
# A-build-1: a failed eris compile must not leave the last build's object
P.append((
"# carries the feature set here too; eris_lj.c refuses to compile without it.\n"
"\"$CC\" -c -O2 $PICFLAG -I\"$LJ\" -I\"$OCLJ_SER\"",
"# carries the feature set here too; eris_lj.c refuses to compile without it.\n"
"# The object is judged by [ -f ] below, so the last build's must go first: gcc\n"
"# leaves an existing -o target in place when a compile fails, and the word\n"
"# check and the link would take it.\n"
"rm -f \"$OBJ/eris_lj.o\"\n"
"\"$CC\" -c -O2 $PICFLAG -I\"$LJ\" -I\"$OCLJ_SER\""))
# A-build-4: OBS shape, and an exact WORD shape
P.append((
"WORD=$(grep -a -o -E \"[|]$SER_HASH[|]ffi[01][.][a-z0-9.]+\" \"$OBJ/eris_lj.o\" | head -1)\n"
"WORD=${WORD##*|}\n"
"case \"$WORD\" in\n"
"  ffi[01].lua5[12].gc[36][24].fr[12].dn[01].[lb]e.p[36][24]) : ;;\n",
"case \"$OBS\" in\n"
"  \"ffi\"[01]\" lua5\"[12]\" fr\"[12]\" \"[lb]e) : ;;\n"
"  *) fail \"luajit.exe's feature observation is malformed: '$OBS'\" ;;\n"
"esac\n"
"WORD=$(grep -a -o -E \"[|]$SER_HASH[|]ffi[01][.][a-z0-9.]+\" \"$OBJ/eris_lj.o\" | head -1)\n"
"WORD=${WORD##*|}\n"
"case \"$WORD\" in\n"
"  ffi[01].lua5[12].gc64.fr[12].dn[01].[lb]e.p64|ffi[01].lua5[12].gc32.fr[12].dn[01].[lb]e.p64|ffi[01].lua5[12].gc32.fr[12].dn[01].[lb]e.p32) : ;;\n"))
# A-build-1 (missed): the same for the link
P.append((
"\"$CC\" -shared -o \"$OCLJ_OUT/$DLL_NAME\" \\\n",
"rm -f \"$OCLJ_OUT/$DLL_NAME\"   # judged by [ -f ] below: a failed link must not leave the last library\n"
"\"$CC\" -shared -o \"$OCLJ_OUT/$DLL_NAME\" \\\n"))
# E3 / A-build-2 / X3: PREREQUISITES 4
P.append((
"# 4. LuaJIT: already vendored in this repo at prototype/watchdog/luajit,\n"
"#    pinned to upstream 1ee778a4, whose LUAJIT_ENABLE_CHECKHOOK is upstream's\n"
"#    own option (lj_record.c:691, :2953).  The checkout stays pristine: this\n"
"#    script builds a COPY with native/luajit/oclj_features.h and the four\n"
"#    changes in native/luajit/.\n"
"#    A stock LuaJIT clone will NOT work -- the preflight rejects it.\n",
"# 4. LuaJIT: a checkout at prototype/watchdog/luajit (gitignored; `make -C\n"
"#    prototype/watchdog luajit-src` clones it), pinned to upstream 1ee778a4,\n"
"#    whose LUAJIT_ENABLE_CHECKHOOK is upstream's own option (lj_record.c:691,\n"
"#    :2953).  The checkout stays pristine: this script builds a COPY with\n"
"#    native/luajit/oclj_features.h and the four changes in native/luajit/.\n"
"#    Another LuaJIT commit is untested: the four patch scripts' exactly-once\n"
"#    anchors and the behaviour gates are what refuse a tree that changed shape.\n"))
patch(R + "native/build-native.sh", P)
