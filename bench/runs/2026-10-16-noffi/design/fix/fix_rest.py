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

# ---------------------------------------------------------------- oclj_features.h
patch(R + "native/luajit/oclj_features.h", [
(r''' *       the way.  Cdata cannot be persisted, so one such literal alive at
 *       save time costs the machine its state.  Without FFI they are a
 *       syntax error, "malformed number", as in PUC Lua 5.2 and 5.3.
 *       docs/ffi-decision.md.
''',
r''' *       the way.  Cdata cannot be persisted, so one such value alive at
 *       save time would cost the machine its state (by reading the save
 *       path; a function that merely holds the constant persists).  Without
 *       FFI they are a syntax error, "malformed number".
 *       docs/ffi-decision.md.
'''),
(r''' * EVERY OTHER LuaJIT BUILD OPTION THAT CHANGES A STRUCTURE, THE BYTECODE
 * THE PARSER EMITS, OR WHAT A BUILD GATE MEASURES IS REFUSED BELOW, in the
 * archive and in our translation units alike.''',
r''' * EVERY OTHER OPTION THE PINNED LuaJIT TESTS (a census of its LUAJIT_*
 * conditionals, 2026-10-16) THAT CHANGES A STRUCTURE, THE BYTECODE THE
 * PARSER EMITS, THE UNWINDER, OR WHAT A BUILD GATE MEASURES IS REFUSED
 * BELOW, in the archive and in our translation units alike.'''),
(r'''#if defined(LUAJIT_SECURITY_STRID) || defined(LUAJIT_SECURITY_MCODE)
#error "OC-LuaJIT (oclj_features.h): the VM security knobs stay at LuaJIT's defaults (lj_arch.h); lj52shim.c seeds each arena with lj_prng_seed_secure"
#endif
''',
r'''#if defined(LUAJIT_SECURITY_STRID) || defined(LUAJIT_SECURITY_MCODE)
#error "OC-LuaJIT (oclj_features.h): the VM security knobs stay at LuaJIT's defaults (lj_arch.h); lj52shim.c seeds each arena with lj_prng_seed_secure"
#endif
#if defined(LUAJIT_NO_UNWIND) || defined(LUAJIT_UNWIND_INTERNAL)
#error "OC-LuaJIT (oclj_features.h): with internal unwinding an error raised in a helper called from JIT-compiled code (mainly out-of-memory, which the RAM cap raises) goes to the panic handler, not to pcall (lj_err.c:54-56); LJ_NO_UNWIND also changes CFRAME_SIZE (lj_frame.h:173-177)"
#endif
'''),
])

# ---------------------------------------------------------------- lj52shim.c (comment only)
patch(R + "native/lj52shim.c", [
(r''' * touches an internal.  build-native.sh's stage 1b proves the same at
 * build time; this catches what a build cannot see -- a shim or serializer
 * object, or an archive, from somewhere else (OCLJ_SHIMOBJ, a hand link). */''',
r''' * touches an internal.  build-native.sh's stage 1b proves the same at
 * build time; this catches what a build cannot see: a serializer object or
 * an archive from somewhere else (a hand link), or a shim object compiled
 * from this source or later for another layout.  NOT caught: a shim object
 * from before 2026-10-16, which carries no gate (run-mem.sh and run-vgc.sh
 * refuse the one dangerous OCLJ_SHIMOBJ pairing), and an archive that takes
 * no foreign allocator at all (non-GC64): its lua_newstate returns NULL
 * without calling lj52_alloc, and the luaL_newstate fallback below runs
 * (the roadmap's "Loose ends the allocator change turned up", item 1). */'''),
])

# ---------------------------------------------------------------- security_test.c
patch(R + "test/native/security_test.c", [
(" * cannot pass it. tests/negative-control.sh proves that claim by building\n",
 " * cannot pass it. test/native/negative-control.sh proves that claim by building\n"),
(r''' * them.  Cdata cannot be persisted: one alive at save time cost the machine
 * its state.  The native is built without FFI (native/luajit/
 * oclj_features.h), so each of those is a syntax error, "malformed number",
 * as in PUC Lua 5.2 and 5.3; an FFI-flagged bytecode dump is refused as
 * "incompatible bytecode" (lj_bcread.c:404-410), the route an
 * allowBytecode=true server or an old eris blob would take; and the registry
''',
r''' * them.  Cdata cannot be persisted: one alive at save time would cost the
 * machine its state (by reading).  The native is built without FFI
 * (native/luajit/oclj_features.h), so each of those is a syntax error,
 * "malformed number"; an FFI-flagged bytecode dump is refused as
 * "incompatible bytecode" (lj_bcread.c:404-410), the route an
 * allowBytecode=true server would take (an eris blob from another build is
 * refused earlier, at its fingerprint); and the registry
'''),
(r''' * Build and run: sh tests/run-security.sh
 * Prove it has teeth: sh tests/negative-control.sh (three sabotaged shims)
''',
r''' * Build and run: sh test/native/run-security.sh
 * Prove it has teeth: sh test/native/negative-control.sh (three sabotaged
 *   shims, and two layout arms: the canonical shim, and then eris_lj.c,
 *   compiled for another LuaJIT layout)
'''),
(r''' * (1ee778a4, GC64): flags byte 0x0E = STRIP|FFI|FR2 (lj_bcdump.h:43-45). */
''',
r''' * (1ee778a4, GC64): flags byte 0x0E = STRIP|FFI|FR2 (lj_bcdump.h:43-45).
 * Byte 3 of both dumps is BCDUMP_VERSION (2): a change to the bytecode must
 * raise it (lj_bcdump.h:36-37), and these fixtures must follow. */
'''),
(r'''  check("FF8", strcmp(buf, "nil/nil") == 0,
        "registry._PRELOAD.ffi is nil (lib_init.c:32-37)", buf);
  /* Bytecode: an allowBytecode=true server, and eris unpersist of an old
   * blob, both reach lua_loadx(..., "b"). */
  {
    BufReader r;
    int top0 = lua_gettop(L), st;
    r.p = (const char *)BC_PLAIN; r.n = sizeof BC_PLAIN; r.done = 0;
    st = lua_loadx(L, bufread, &r, "=bcplain", "b");
''',
r'''  { size_t n = strlen(buf);   /* the _PRELOAD half alone: FF7 has _LOADED */
    check("FF8", n >= 4 && strcmp(buf + n - 4, "/nil") == 0,
          "registry._PRELOAD.ffi is nil (lib_init.c:32-37)", buf); }
  /* Bytecode: an allowBytecode=true server reaches lua_loadx(..., "b"); eris
   * unpersist does too, but only for a blob that already passed the
   * fingerprint. */
  {
    BufReader r;
    int top0 = lua_gettop(L), st, plain_ok;
    r.p = (const char *)BC_PLAIN; r.n = sizeof BC_PLAIN; r.done = 0;
    st = lua_loadx(L, bufread, &r, "=bcplain", "b");
    plain_ok = (st == 0);
'''),
(r'''    check("FF10", st != 0 && strstr(detail, "incompatible bytecode") != NULL,
''',
r'''    /* The loader raises "incompatible bytecode" for four header reasons
     * (lj_bcread.c:394-418).  The two dumps differ only in the FFI flag, so
     * the refusal is the FFI one only while the plain dump (FF9) loads. */
    if (!plain_ok)
      strncat(detail, " (FF9 control failed: the header is refused for another reason)",
              sizeof detail - strlen(detail) - 1);
    check("FF10", plain_ok && st != 0 && strstr(detail, "incompatible bytecode") != NULL,
'''),
])

# ---------------------------------------------------------------- negative-control.sh
patch(R + "test/native/negative-control.sh", [
("# negative-control.sh -- PROVE tests/security_test.c has teeth.\n",
 "# negative-control.sh -- PROVE test/native/security_test.c has teeth.\n"),
(r'''# on exactly the checks that defect corresponds to and no others.
''',
r'''# on exactly the checks that defect corresponds to and no others.  Two more
# arms (3b, 3c) compile the canonical sources for another LuaJIT layout and
# require that no state is made at all.
'''),
(r'''#                state, so security_test.c exits 2 and stderr says LJ52 LAYOUT.
''',
r'''#                state, so security_test.c exits 2 and stderr says LJ52 LAYOUT.
#   3c. layout-eris  the canonical shim, linked with an eris_lj.c compiled
#                against that same header copy: the gate's other comparison
#                (eris_lj_ggsize()) must refuse the state, the same way.
'''),
("#   OCLJ_BUILD=<build dir used by build-native.sh> sh tests/negative-control.sh\n",
 "#   OCLJ_BUILD=<build dir used by build-native.sh> sh test/native/negative-control.sh\n"),
(r'''expect layout "a shim compiled for another LuaJIT layout gets no state (exit 2, no check runs)" 2
if grep -q '^LJ52 LAYOUT: refusing the state' "$d/run.log" && grep -q 'luaL_newstate returned NULL' "$d/run.log"; then
  verdict 0 "... and lj52_newstate names the layout on stderr"
else
  verdict 1 "... and lj52_newstate names the layout on stderr"
fi
''',
r'''expect layout "a shim compiled for another LuaJIT layout gets no state (exit 2, no check runs)" 2
# The message's three numbers: the archive's GG_State, the shim's, eris_lj's.
# Here the SHIM is the one that differs (archive == eris != shim).
gg3() { grep '^LJ52 LAYOUT' "$1" | awk '{ for (i = 1; i <= NF; i++) { if ($i ~ /^[0-9]+-byte$/) a = $i + 0; if ($i == "compiled" && $(i+1) == "for") s = $(i+2) + 0; if ($i == "eris_lj.c" && $(i+1) == "for") r = $(i+2) + 0 } } END { print a + 0, s + 0, r + 0 }'; }
set -- $(gg3 "$d/run.log")
if grep -q 'luaL_newstate returned NULL' "$d/run.log" && [ "$1" -gt 0 ] && [ "$1" = "$3" ] && [ "$1" != "$2" ]; then
  verdict 0 "... and lj52_newstate names the shim's layout as the one that differs ($*)"
else
  verdict 1 "... and lj52_newstate names the shim's layout as the one that differs ($*)"
fi

# =====================================================================
# 3c. layout-eris -- the canonical shim, linked with an eris_lj.c compiled
# for ANOTHER LuaJIT layout: lj52_layout_ok's second comparison,
# eris_lj_ggsize() against the shim's own sizeof(GG_State).  The shim and
# the archive agree here, so only the serializer's view can refuse the
# state, and the verdict requires the message to say exactly that
# (archive == shim != eris).
# =====================================================================
e=$WORK/layout-eris
mkdir -p "$e"
"$CC" -c -O2 -I"$WORK/layout/inc" -I"$OCLJ_SER" -DERIS_LJ_COMMIT='"negctl"' "$OCLJ_SER/eris_lj.c" -o "$e/eris_lj.o" 2>"$e/eris.err" \
  || { sed -n '1,25p' "$e/eris.err"; fail "layout-eris: eris_lj.c did not compile"; }
"$CC" -O2 -I"$LJ" -I"$WORK/canon" -I"$OCLJ_JNI" -I"$OCLJ_JNI/$JNI_MD" -include "$WORK/canon/lj52shim.h" \
  "$SELF_DIR/security_test.c" "$WORK/canon/lj52shim.o" "$e/eris_lj.o" \
  "$LJ/libluajit.a" -lm -o "$e/security_test.exe" 2>"$e/test.err" \
  || { sed -n '1,25p' "$e/test.err"; fail "layout-eris: security_test.c did not link"; }
expect layout-eris "a serializer compiled for another LuaJIT layout gets no state (exit 2, no check runs)" 2
set -- $(gg3 "$e/run.log")
if grep -q 'luaL_newstate returned NULL' "$e/run.log" && [ "$1" -gt 0 ] && [ "$1" = "$2" ] && [ "$1" != "$3" ]; then
  verdict 0 "... and lj52_newstate names the serializer's layout as the one that differs ($*)"
else
  verdict 1 "... and lj52_newstate names the serializer's layout as the one that differs ($*)"
fi
'''),
])

# ---------------------------------------------------------------- penalty_test.c, run-penalty.sh, run-security.sh
patch(R + "test/native/penalty_test.c", [
(r''' * pass; see run-penalty.sh's OCLJ_LJLIB for pointing it at another archive.
''',
r''' * pass; see run-penalty.sh's OCLJ_LJLIB for pointing it at another archive.
 * That archive must have this build's feature set (native/luajit/
 * oclj_features.h, FFI off), through the header or as
 * -DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_CHECKHOOK -DLUAJIT_DISABLE_FFI
 * on a pristine tree's make; otherwise THE LAYOUT GATE in main() exits 2,
 * "proved nothing", before P1 (an FFI-on archive, as every one before
 * 2026-10-16 was, lays out 6384 bytes to this file's 6376 on Windows x64).
'''),
])
patch(R + "test/native/run-penalty.sh", [
(r'''#                           the fail-first A/B: the headers still come from the
#                           build copy (the patch changes no header)
''',
r'''#                           the fail-first A/B: the headers still come from the
#                           build copy (the patch changes no header), so the
#                           archive must have this build's feature set
#                           (native/luajit/oclj_features.h, FFI off), or
#                           penalty_test exits 2, "proved nothing"
'''),
])
patch(R + "test/native/run-security.sh", [
("# run-security.sh -- build and run tests/security_test.c against the\n",
 "# run-security.sh -- build and run test/native/security_test.c against the\n"),
("#   OCLJ_BUILD=<build dir used by build-native.sh>  sh tests/run-security.sh\n",
 "#   OCLJ_BUILD=<build dir used by build-native.sh>  sh test/native/run-security.sh\n"),
])

# ---------------------------------------------------------------- run-mem.sh / run-vgc.sh: the pre-gate shim pairing
GATE = r'''# A shim object from before 2026-10-16 carries no layout gate (lj52_layout_ok)
# and was compiled for the FFI-on GG_State; linked with an archive without
# FFI nothing would refuse it, and it would read jit_State 8 bytes off.
# Refuse that one pairing; a pre-gate object with its own build is fine.
if ! grep -a -q 'LJ52 LAYOUT: refusing the state' "$OCLJ_SHIMOBJ" \
   && ! nm "$LJ/libluajit.a" 2>/dev/null | grep -q ' T luaopen_ffi$'; then
  fail "$OCLJ_SHIMOBJ predates the layout gate (2026-10-16) and reads the FFI-on GG_State,
       but $LJ/libluajit.a has no FFI: point OCLJ_BUILD at the build it came from"
fi
'''
patch(R + "test/native/run-mem.sh", [
('[ -f "$OCLJ_SHIMOBJ" ]   || fail "no $OCLJ_SHIMOBJ -- run build-native.sh first (on THIS platform)"\n',
 '[ -f "$OCLJ_SHIMOBJ" ]   || fail "no $OCLJ_SHIMOBJ -- run build-native.sh first (on THIS platform)"\n' + GATE),
])
patch(R + "test/native/run-vgc.sh", [
('[ -f "$OCLJ_SHIMOBJ" ]   || fail "no $OCLJ_SHIMOBJ -- run build-native.sh first (on THIS platform)"\n',
 '[ -f "$OCLJ_SHIMOBJ" ]   || fail "no $OCLJ_SHIMOBJ -- run build-native.sh first (on THIS platform)"\n' + GATE),
])

# ---------------------------------------------------------------- OcljSmoke.scala
patch(R + "test/native/OcljSmoke.scala", [
(r'''      |-- native is built without FFI, and the lexer then says "malformed
      |-- number", as PUC 5.2 does -- so the stock cell is the reference.
''',
r'''      |-- native is built without FFI, and the lexer then says "malformed
      |-- number".  PUC 5.2 refuses it too, but as the number 1 and a stray
      |-- name ("<eof> expected near 'LL'"): the stock cell paints refused-puc.
'''),
(r'''      |  local f, e = load("return 1LL", "=litprobe")
      |  litRow = f and "ACCEPTED" or
      |    (tostring(e):find("malformed number", 1, true) and "refused" or "other")
''',
r'''      |  local f, e = load("return 1LL", "=litprobe")
      |  local m = tostring(e)
      |  litRow = f and "ACCEPTED" or
      |    (m:find("malformed number", 1, true) and "refused" or
      |     m:find("expected near 'LL'", 1, true) and "refused-puc" or "other")
'''),
(r'''        "symptom: rebuild LuaJIT with -DLUAJIT_ENABLE_CHECKHOOK.")
''',
r'''        "symptom: rebuild with native/build-native.sh (LUAJIT_ENABLE_CHECKHOOK is set in " +
        "native/luajit/oclj_features.h).")
'''),
(r'''    // is built without FFI (native/luajit/oclj_features.h), and the lexer then
    // answers "malformed number" exactly as PUC 5.2 does -- so every cell, the
    // stock one included, wants "refused", and the stock cell is the reference.
    val lit = parse(txtA2, "OCLJLIT")
    milestone("d3-sandbox-ffi-literal-refused", lit == "refused",
      "load('return 1LL') in the sandbox -> " + lit +
        (if (lit == "refused") ""
         else if (lit == "<missing>") "   <- no OCLJLIT on screen -- the in-sandbox probe never ran"
         else if (lit == "ACCEPTED") "   <- the lexer made a cdata: this native was built WITH FFI"
         else "   <- refused, but not as a malformed number"))
''',
r'''    // is built without FFI (native/luajit/oclj_features.h), and the lexer then
    // answers "malformed number".  PUC 5.2's read_numeral stops at the first
    // character that is not a hex digit or '.', so the stock cell refuses
    // `1LL` as the number 1 and the name LL, "<eof> expected near 'LL'"
    // (refused-puc).  Every cell refuses, each in its own lexer's words, and
    // each wants exactly its own.
    val lit = parse(txtA2, "OCLJLIT")
    val litWant = if (nativeMode == "stock") "refused-puc" else "refused"
    milestone("d3-sandbox-ffi-literal-refused", lit == litWant,
      "load('return 1LL') in the sandbox -> " + lit + " (want " + litWant + ")" +
        (if (lit == litWant) ""
         else if (lit == "<missing>") "   <- no OCLJLIT on screen -- the in-sandbox probe never ran"
         else if (lit == "ACCEPTED") "   <- the lexer made a cdata: this native was built WITH FFI"
         else if (lit == "refused-puc") "   <- PUC's refusal on a LuaJIT cell: this lexer is not LuaJIT's"
         else if (lit == "refused") "   <- LuaJIT's refusal on the stock cell: this is not PUC 5.2"
         else "   <- refused, but not by a lexer this suite knows"))
'''),
])

# ---------------------------------------------------------------- serializer
patch(R + "serializer/Makefile", [
(r'''# 2026-10-16 this linked ../prototype/watchdog/libluajit_stock.a instead, an
# FFI-on archive with none of those, compiled against headers that saw no
# feature flags at all.
''',
r'''# 2026-10-16 this linked ../prototype/watchdog/libluajit_stock.a instead:
# FFI on, LUA52COMPAT but no CHECKHOOK and none of the patches, with eris_lj.c
# compiled against headers that saw no feature flags at all.
'''),
('\t@echo "Missing $(LJLIB) \u2014 run native/build-native.sh first, on this platform"\n',
 '\t@echo "Missing $(LJLIB) -- run native/build-native.sh first, on this platform ($(OCLJ_OS)-$(OCLJ_ARCH)), or pass OCLJ_BUILD=<the OCLJ_BUILD it used>"\n'),
("\tsh tests/run-forin.sh\n",
 "\tBIN=./$(BIN) sh tests/run-forin.sh\n"),
])
patch(R + "serializer/test_main.c", [
(r''' * Exit status is the number of failing tests (0 = all pass); 2 = the
 * script did not run; 3 = eris_lj.c and libluajit.a disagree on LuaJIT's
 * layout, so nothing this binary reports would mean anything. */
''',
r''' * Exit status is the number of failing tests (0 = all pass); 2 = the
 * script did not run; 3 with a LAYOUT MISMATCH line on stderr and no banner
 * = eris_lj.c and libluajit.a disagree on LuaJIT's layout, so nothing this
 * binary reports would mean anything (a bare 2 or 3 can also be a failure
 * count). */
'''),
])
patch(R + "serializer/README.md", [
(r'''`make negctl CC=gcc` proves the fingerprint test and the layout check can
fail (`tests/negctl-fingerprint.sh`).
''',
r'''If `build-native.sh` ran with a non-default `OCLJ_BUILD`, pass the same one:
`make OCLJ_BUILD=<dir> test CC=gcc`.

`make negctl CC=gcc` proves the fingerprint test and the layout check can
fail (`tests/negctl-fingerprint.sh`).
'''),
])
patch(R + "serializer/eris_lj.c", [
(r''' * That set is native/luajit/oclj_features.h, which build-native.sh's build
 * copy of LuaJIT includes from lj_arch.h; a compile against any other LuaJIT
 * tree stops here. */''',
r''' * That set is native/luajit/oclj_features.h, which build-native.sh's build
 * copy of LuaJIT includes from lj_arch.h.  A compile against a LuaJIT tree
 * without that header stops here; one whose copy of it carries a different
 * set compiles, and is refused at run time by the GG_State check
 * (eris_lj_ggsize below) when the difference moves GG_State. */'''),
])

# ---------------------------------------------------------------- user docs
patch(R + "README.md", [
("are a syntax error, `malformed number`, exactly as in PUC Lua 5.2 and 5.3.",
 "are a syntax error, `malformed number`. (PUC Lua 5.2 and 5.3 have no such literals either: they read `1LL` as the number `1` followed by the name `LL`, which is usually a different syntax error, such as `<eof> expected near 'LL'`.)"),
])
patch(R + "docs/ffi-decision.md", [
("2026-10-16. Built without FFI, `1LL` is a syntax error (`malformed number near\n"
 "'1LL'`), as in PUC Lua 5.2 and 5.3: the program fails when it is loaded, not\n"
 "when the world saves.\n",
 "2026-10-16. Built without FFI, `1LL` is a syntax error (`malformed number near\n"
 "'1LL'`): the program fails when it is loaded, not when the world saves.\n"),
])
patch(R + "docs/research/os-shape-census.md", [
("Both are moot since the native is built without FFI (`native/luajit/oclj_features.h`): `1LL` is a syntax error.",
 "The first is moot since the native is built without FFI (`native/luajit/oclj_features.h`): `1LL` is a syntax error. The second changes nothing below: eris refuses a userdata by value as it does a cdata."),
("done in a stronger form than a `pcall(require,'ffi')` assertion, which a stray `ffi.lua` on a search path could satisfy:",
 "done in a stronger form than a `pcall(require,'ffi')` assertion, which would have passed on HEAD while the lexer still made cdata from `1LL` (and which a stray `ffi.lua` on a search path would trip falsely):"),
])

# ---------------------------------------------------------------- roadmap
patch(R + "docs/roadmap.md", [
# E7: row 183 item (4)
("since `race_test.c` is Win32-only (`negative-control.sh` was fixed 2026-10-04).",
 "since `race_test.c` is Win32-only (`negative-control.sh` was fixed 2026-10-04). The SYSMALLOC refusal (4) names is gone from `build-native.sh`: `native/luajit/oclj_features.h` now refuses LUAJIT_USE_SYSMALLOC with an `#error`, and the LuaJIT log check refuses any `-DLUAJIT_*` but the Makefile's platform ones. The `#error` fires when a translation unit is preprocessed with the flag; no whole build with it has been run, so (4) stays open in that form."),
# E10: row 196
("(16 checks; HEAD's serializer fails 5 of them, and a copy with the compare removed fails 9,",
 "(16 checks; on HEAD's serializer 9 run, the seven token checks having no word to flip, and 5 fail; a copy with the compare removed fails 9,"),
# E5 + E4 + B1 + E9: row 206
("One such value alive at save time cost the machine its state (`serializer/eris_lj.c` refuses cdata, and `LuaJITArchitecture.java:645-650` then drops the state),",
 "By reading, not run: one such value alive at save time cost the machine its state (`persist_typed` in `serializer/eris_lj.c` refuses a cdata value, and `LuaJITArchitecture.java:645-650` then drops the state; a function that merely holds a `1LL` constant persisted, measured),"),
("LUA52COMPAT, CHECKHOOK, DISABLE_FFI, and an `#error` for every other LuaJIT option that changes a structure, the bytecode or a gate's instrument.",
 "LUA52COMPAT, CHECKHOOK, DISABLE_FFI, and an `#error` for every other option the pinned LuaJIT tests that changes a structure, the bytecode, the unwinder or a gate's instrument."),
("without the patch a hot `%x` of an int stitches and runs 1.6-2.1x slower.",
 "without the patch a hot `%x` of an int stitches and runs 1.6-2.1x slower when the strings repeat, 1.2x when each result is new (unpinned, 2026-10-16)."),
("`build-native.sh` refuses a feature `-D` in the LuaJIT log,",
 "`build-native.sh` refuses any `-DLUAJIT_*` in the LuaJIT log but the Makefile's platform ones,"),
("`lj52_newstate` refuses a state whose GG_State differs from the shim's or eris_lj's (`negative-control.sh` arm `layout`);",
 "`lj52_newstate` refuses a state whose GG_State differs from the shim's or eris_lj's (`negative-control.sh` arms `layout` and `layout-eris`, one per comparison);"),
("**Tests:** `security_test.c` FF and BF, harness `d3-sandbox-ffi-literal-refused`, `serializer/tests/fingerprint.lua` and `negctl-fingerprint.sh`. Evidence: `bench/runs/2026-10-16-noffi/`.",
 "**Tests:** `security_test.c` FF and BF, harness `d3-sandbox-ffi-literal-refused`, `serializer/tests/fingerprint.lua` and `negctl-fingerprint.sh`. Evidence: `bench/runs/2026-10-16-noffi/`. **Found 2026-10-16, not fixed:** `%c` of an int past 2^31 differs between compiled and interpreted code (`lj_opt_narrow.c:474-478`); `string.format(\"%x\", math.huge)` (or of `\"inf\"`, which LuaJIT's `tonumber` accepts and PUC 5.2's does not) returns `8000000000000000` where PUC 5.2 raises; without FFI, `jit.util.tracek` returns an unset value for a KINT64 constant (`lj_ir.c:385-391`; no project code calls it, and the sandbox has no `jit.util`)."),
])

# ---------------------------------------------------------------- bench/oc/run-standalone.sh (X6)
patch(R + "bench/oc/run-standalone.sh", [
('LUAJIT="${OCLJ_LUAJIT:-$OCLJ_REPO/build/native/luajit/src/luajit.exe}"\n',
 '# build-native.sh writes luajit-<os>-<arch>/ since 2026-10-02 (run-wd.sh derives it the same way).\n'
 'case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*|Windows_NT) OCLJ_OS=windows ;; Linux) OCLJ_OS=linux ;; *) OCLJ_OS=unsupported ;; esac\n'
 'LUAJIT="${OCLJ_LUAJIT:-${OCLJ_BUILD:-$OCLJ_REPO/build/native}/luajit-$OCLJ_OS-x86_64/src/luajit.exe}"\n'),
])
