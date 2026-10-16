/* =====================================================================
 * security_test.c -- the shim's security regressions, as one runnable test.
 *
 * This file exists to FAIL. It is written so that a shim which drops
 * lua_load's `mode`, or which implements lua_compare(LUA_OPLE) the 5.1 way,
 * cannot pass it. test/native/negative-control.sh proves that claim by building
 * exactly those broken shims and running this binary against them.
 *
 * ---------------------------------------------------------------------
 * REGRESSION 1 -- the chunk-mode (allowBytecode) gate
 *
 * OC reads computer.lua.allowBytecode (Settings.scala:48) and surfaces it to
 * the kernel as system.allowBytecode(). machine.lua's sandboxed `load`
 * (machine.lua:754) is:
 *
 *     load = function(ld, source, mode, env)
 *       if not system.allowBytecode() then mode = "t" end
 *       return load(ld, source, mode, env or sandbox)
 *     end
 *
 * so on a server with allowBytecode = false, sandbox code must not be able to
 * get a precompiled chunk past `load`. There are TWO distinct enforcement
 * points, and only one of them is ours:
 *
 *   GATE A -- the Lua level. machine.lua's wrapper calls the base library
 *     `load`, which on this build is LuaJIT's own lib_base.c:416 -> it
 *     forwards `mode` to luaL_loadbufferx / lua_loadx and lj_load.c enforces
 *     it. Nothing in the shim is on this path, so a mode-dropping shim does
 *     NOT break gate A. Tested anyway (section SB), because the semantics OC
 *     depends on are LuaJIT's here and must be pinned.
 *
 *   GATE B -- the C level. jnlua's LuaState.load(InputStream, chunkname,
 *     mode) calls the 5.2 five-argument lua_load, which on this build is
 *     the shim's macro. ocelot-brain uses it at
 *     NativeLuaArchitecture.scala:319 -- lua.load(machine.lua, "=machine",
 *     "t") -- and it is the entry point any Java-side loader in OC reaches.
 *     THIS is the one the rt variant broke with
 *         #define lua_load(L,r,d,cn,mode) lua_load((L),(r),(d),(cn))
 *     which discards the argument silently: no error, no log line, no
 *     failing test. Section MG is compiled with -include lj52shim.h exactly
 *     as jnlua.c is, so it goes through the macro, not around it.
 *
 * REGRESSION 2 -- the "b" direction must stay OPEN internally
 *
 * serializer/eris_lj.c writes LuaJIT bytecode with lj_bcwrite and reads it
 * back with lua_loadx(..., "b"). It is compiled WITHOUT the shim header, so
 * no macro here can reach it. Section ER asserts both halves in ONE state:
 * eris round-trips a closure through its own bytecode route while, at the
 * same time and in the same state, sandbox-shaped code cannot load bytecode.
 * Do not "fix" the bytecode question by refusing bytecode globally.
 *
 * REGRESSION 3 -- lua_compare(LUA_OPLE)
 *
 * The variant that booted OpenOS spells LUA_OPLE as !lua_lessthan(idx2,idx1),
 * which is 5.1's rule. On a metatable defining only __le that looks up a __lt
 * which is not there and RAISES; with both metamethods present it returns the
 * wrong boolean and fires the wrong one. Section LE runs every probe under
 * lua_pcall so a raise is recorded as a failure instead of unwinding the test.
 * ---------------------------------------------------------------------
 *
 * REGRESSION 4 -- cdata minted by the LEXER (section FF)
 *
 * A LuaJIT built with FFI turns `1LL`, `2ULL`, `0x10ULL` and `3i` into cdata
 * in the lexer, loading the FFI library on demand to do it (lj_lex.c:116,
 * :127) -- no `ffi` in the environment needed, so sandboxed code could make
 * them.  Cdata cannot be persisted: one alive at save time would cost the
 * machine its state (by reading).  The native is built without FFI
 * (native/luajit/oclj_features.h), so each of those is a syntax error,
 * "malformed number"; an FFI-flagged bytecode dump is refused as
 * "incompatible bytecode" (lj_bcread.c:404-410), the route an
 * allowBytecode=true server would take (an eris blob from another build is
 * refused earlier, at its fingerprint); and the registry
 * never gains _LOADED.ffi or _PRELOAD.ffi.  FF0 and FF9 are the controls
 * (plain literals and a plain dump still load), FFP the fixture.  The two
 * dumps below were made on an FFI-on build of the same tree (1ee778a4, GC64)
 * with string.dump(load(<src>), true).
 *
 * REGRESSION 5 -- string.buffer without FFI (section BF)
 *
 * Its FFI-only methods (reserve, commit, ref, putcdata; lib_buffer.c:183-237)
 * are compiled out with FFI, and its objects are USERDATA (BF0) -- not cdata,
 * as docs/ffi-decision.md said until 2026-10-16.  It is reached through
 * registry._PRELOAD, as no sandbox can reach it; it stays unexposed.
 *
 * FF and BF test the ARCHIVE, not the shim, so no sabotaged shim in
 * negative-control.sh flips them: their fail-first is this file against an
 * FFI-on build (HEAD 62970a0: FF1-FF8, FF10, FF11 and BF1-BF4 fail).
 * ---------------------------------------------------------------------
 *
 * Build and run: sh test/native/run-security.sh
 * Prove it has teeth: sh test/native/negative-control.sh (three sabotaged
 *   shims, and two layout arms: the canonical shim, and then eris_lj.c,
 *   compiled for another LuaJIT layout)
 * The same gate, end to end in a booted OpenOS: smoke-test.sh milestone
 *   d2-sandbox-bytecode-gate, whose own negative control is a second run
 *   with OCLJ_ALLOW_BYTECODE=true.
 *
 * Output is one "PASS <id>" / "FAIL <id>" line per check so the negative
 * control can assert WHICH checks flip, not merely that something did.
 * Exit status 0 iff every check passed.
 * ===================================================================== */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include "lj52shim.h"

/* ------------------------------------------------------------------ */
/* reporting                                                           */
/* ------------------------------------------------------------------ */

static int checks = 0, failures = 0;

static void check(const char *id, int cond, const char *what,
                  const char *detail) {
  checks++;
  if (!cond) failures++;
  printf("%s %-6s %-58s %s\n", cond ? "PASS" : "FAIL", id, what,
         detail ? detail : "");
  fflush(stdout);
}

static void section(const char *s) { printf("\n== %s ==\n", s); }

static void fatal(const char *msg, const char *detail) {
  /* A setup failure is NOT a test failure: it means the test proved nothing.
   * Exit 2 so a harness can tell "vacuous" from "the gate is open". */
  printf("SETUP FAILURE: %s%s%s\n", msg, detail ? ": " : "",
         detail ? detail : "");
  printf("SECURITY TESTS: VACUOUS (exit 2)\n");
  exit(2);
}

/* ------------------------------------------------------------------ */
/* helpers                                                             */
/* ------------------------------------------------------------------ */

typedef struct { const char *p; size_t n; int done; } BufReader;
static const char *bufread(lua_State *L, void *ud, size_t *size) {
  BufReader *b = (BufReader *)ud;
  (void)L;
  if (b->done) { *size = 0; return NULL; }
  b->done = 1;
  *size = b->n;
  return b->p;
}

static void dostr(lua_State *L, const char *src) {
  if (luaL_loadstring(L, src) != 0 || lua_pcall(L, 0, 0, 0) != 0)
    fatal("setup chunk failed", lua_tostring(L, -1));
}

/* Run `src`, which must `return` one string, and copy it into `out`.
 * Returns 0 on a raise, leaving the error message in `out`. */
static int evalstr(lua_State *L, const char *src, char *out, size_t outn) {
  int base = lua_gettop(L);
  int okv = 0;
  out[0] = 0;
  if (luaL_loadstring(L, src) != 0) {
    strncpy(out, lua_tostring(L, -1) ? lua_tostring(L, -1) : "?", outn - 1);
  } else if (lua_pcall(L, 0, 1, 0) != 0) {
    strncpy(out, lua_tostring(L, -1) ? lua_tostring(L, -1) : "?", outn - 1);
  } else {
    const char *s = lua_tostring(L, -1);
    strncpy(out, s ? s : "<nil>", outn - 1);
    okv = 1;
  }
  out[outn - 1] = 0;
  lua_settop(L, base);
  return okv;
}

/* string.dump(load("return 1LL"), true) from an FFI-ON build of this tree
 * (1ee778a4, GC64): flags byte 0x0E = STRIP|FFI|FR2 (lj_bcdump.h:43-45).
 * Byte 3 of both dumps is BCDUMP_VERSION (2): a change to the bytecode must
 * raise it (lj_bcdump.h:36-37), and these fixtures must follow. */
static const unsigned char BC_FFI[] = {
  0x1B,0x4C,0x4A,0x02,0x0E,0x12,0x06,0x00,0x01,0x00,0x01,0x00,0x02,0x28,0x00,
  0x00,0x00,0x4C,0x00,0x02,0x00,0x02,0x01,0x00,0x00 };
/* string.dump(load("return 1"), true), same build: flags 0x0A = STRIP|FR2. */
static const unsigned char BC_PLAIN[] = {
  0x1B,0x4C,0x4A,0x02,0x0A,0x0F,0x02,0x00,0x01,0x00,0x00,0x00,0x02,0x29,0x00,
  0x01,0x00,0x4C,0x00,0x02,0x00,0x00 };

/* ------------------------------------------------------------------ */
/* LE probes, run protected                                            */
/* ------------------------------------------------------------------ */

/* upvalues: 1 = a, 2 = b, 3 = op */
static int le_probe(lua_State *L) {
  int op = (int)lua_tointeger(L, lua_upvalueindex(3));
  lua_pushvalue(L, lua_upvalueindex(1));
  lua_pushvalue(L, lua_upvalueindex(2));
  lua_pushboolean(L, lua_compare(L, -2, -1, op));
  return 1;
}

#define LE_RAISED 0
#define LE_FALSE  1
#define LE_TRUE   2

/* Compare two globals under lua_pcall.  The 5.1 spelling of LUA_OPLE RAISES
 * on an __le-only metatable; without this wrapper that error would unwind
 * straight out of main() and the negative control would see a crash instead
 * of a named failing check. */
static int le_try(lua_State *L, const char *ga, const char *gb, int op,
                  char *err, size_t errn) {
  int base = lua_gettop(L), r;
  if (err && errn) err[0] = 0;
  lua_getglobal(L, ga);
  lua_getglobal(L, gb);
  lua_pushinteger(L, op);
  lua_pushcclosure(L, le_probe, 3);
  if (lua_pcall(L, 0, 1, 0) != 0) {
    if (err && errn) {
      strncpy(err, lua_tostring(L, -1) ? lua_tostring(L, -1) : "?", errn - 1);
      err[errn - 1] = 0;
    }
    lua_settop(L, base);
    return LE_RAISED;
  }
  r = lua_toboolean(L, -1) ? LE_TRUE : LE_FALSE;
  lua_settop(L, base);
  return r;
}

static const char *le_name(int r) {
  return r == LE_RAISED ? "RAISED" : (r == LE_TRUE ? "true" : "false");
}

/* ================================================================== */
int main(void) {
  lua_State *L;
  const char *TEXT = "return 'HELLO-FROM-TEXT'";
  char *bc = NULL;
  size_t bclen = 0;
  char buf[512], detail[1024];
  int i;

  /* ---------------------------------------------------------------- FX
   * Fixtures and anti-vacuity guards.  Every one of these is a reason the
   * rest of the file would prove nothing, so they exit 2, not 1. */
  section("FX  fixtures and anti-vacuity guards");

  L = luaL_newstate();                /* == lj52_newstate() via the shim */
  if (!L) fatal("luaL_newstate returned NULL", NULL);
  luaL_openlibs(L);

  /* Are we even on the shim?  If lj52shim.o is not linked, luaL_newstate is
   * LuaJIT's own and every gate below would be testing stock LuaJIT rather
   * than the compatibility layer OC talks to. */
  lua_getglobal(L, "_OCLJ_NATIVE");
  if (!lua_isstring(L, -1) || strncmp(lua_tostring(L, -1), "luajit/", 7) != 0)
    fatal("no _OCLJ_NATIVE marker -- lj52shim.o is not linked into this test",
          lua_typename(L, lua_type(L, -1)));
  snprintf(detail, sizeof detail, "%s", lua_tostring(L, -1));
  lua_pop(L, 1);
  check("FX1", 1, "state came from the shim (_OCLJ_NATIVE present)", detail);

  /* Produce genuine LuaJIT bytecode through Lua's own string.dump -- the
   * exact thing an attacker in the sandbox would type. */
  {
    size_t n;
    const char *p;
    int base = lua_gettop(L);
    if (luaL_loadstring(L, TEXT) != 0) fatal("loadstring(TEXT)", lua_tostring(L, -1));
    lua_getglobal(L, "string");
    lua_getfield(L, -1, "dump");
    lua_remove(L, -2);
    lua_pushvalue(L, -2);
    if (lua_pcall(L, 1, 1, 0) != 0) fatal("string.dump", lua_tostring(L, -1));
    p = lua_tolstring(L, -1, &n);
    if (!p || n == 0) fatal("string.dump returned nothing", NULL);
    bc = (char *)malloc(n);
    if (!bc) fatal("out of memory", NULL);
    memcpy(bc, p, n);
    bclen = n;
    lua_settop(L, base);
  }
  snprintf(detail, sizeof detail, "%d bytes, first byte 0x%02X",
           (int)bclen, (unsigned char)bc[0]);
  if ((unsigned char)bc[0] != 0x1B)
    fatal("string.dump did not produce a binary chunk", detail);
  check("FX2", 1, "string.dump produced a real bytecode chunk", detail);

  /* ---------------------------------------------------------------- MG
   * GATE B: the 5.2 five-argument lua_load, reached through the macro
   * jnlua.c is compiled against.  This is the gate the rt variant dropped. */
  section("MG  C-API chunk-mode gate (jnlua's LuaState.load path)");
  {
    struct {
      const char *id;
      const char *mode;
      int binary;
      int want_ok;
      const char *label;
    } cases[] = {
      { "MG1", "t",  1, 0, "mode \"t\"  + bytecode -> REFUSE (allowBytecode=false)" },
      { "MG2", "t",  0, 1, "mode \"t\"  + text     -> accept" },
      { "MG3", "b",  0, 0, "mode \"b\"  + text     -> REFUSE (the other direction)" },
      { "MG4", "b",  1, 1, "mode \"b\"  + bytecode -> accept" },
      { "MG5", "bt", 1, 1, "mode \"bt\" + bytecode -> accept (allowBytecode=true)" },
      { "MG6", "bt", 0, 1, "mode \"bt\" + text     -> accept" },
      { "MG7", NULL, 1, 1, "mode NULL  + bytecode -> accept (5.2: no check)" },
      { "MG8", NULL, 0, 1, "mode NULL  + text     -> accept (5.2: no check)" }
    };
    for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
      BufReader r;
      int top0, status, delta;
      char id2[8];
      r.p = cases[i].binary ? bc : TEXT;
      r.n = cases[i].binary ? bclen : strlen(TEXT);
      r.done = 0;
      top0 = lua_gettop(L);
      status = lua_load(L, bufread, &r, "=modegate", cases[i].mode);
      delta = lua_gettop(L) - top0;
      snprintf(detail, sizeof detail, "status=%d delta=%+d%s%s", status, delta,
               (status != 0 && lua_isstring(L, -1)) ? " msg=" : "",
               (status != 0 && lua_isstring(L, -1)) ? lua_tostring(L, -1) : "");
      check(cases[i].id, (status == 0) == cases[i].want_ok, cases[i].label,
            detail);
      /* 5.2 leaves exactly ONE value either way: the function on success, the
       * error message on failure.  The byte-sniffer this replaced pushed its
       * message on top of the empty chunk lua_load had already compiled and
       * left +2, leaking a slot per refusal into the state OC's kernel runs
       * in. */
      snprintf(id2, sizeof id2, "%sD", cases[i].id);
      snprintf(detail, sizeof detail, "delta=%+d (5.2 promises exactly +1)", delta);
      check(id2, delta == 1, "  ... stack delta is exactly +1", detail);
      lua_settop(L, top0);
    }
  }
  /* The refusal must be a MODE refusal, not an accidental syntax error on a
   * mangled stream.  Accept LuaJIT's own wording (lj_err.h LJ_ERR_XMODE,
   * "attempt to load chunk with wrong mode") or the sniffer's ("binary"):
   * what is asserted is that the loader refused *because of the mode*. */
  {
    BufReader r;
    int top0 = lua_gettop(L), status;
    const char *msg;
    r.p = bc; r.n = bclen; r.done = 0;
    status = lua_load(L, bufread, &r, "=modegate", "t");
    msg = (status != 0 && lua_isstring(L, -1)) ? lua_tostring(L, -1) : "";
    snprintf(detail, sizeof detail, "\"%s\"", msg);
    check("MG9", status != 0 &&
                 (strstr(msg, "wrong mode") != NULL ||
                  strstr(msg, "binary") != NULL ||
                  strstr(msg, "mode") != NULL),
          "refusal names the MODE, not a stray syntax error", detail);
    lua_settop(L, top0);
  }

  /* ---------------------------------------------------------------- SB
   * GATE A: machine.lua's sandbox `load`, reproduced verbatim, against the
   * base-library `load` this state actually has. */
  section("SB  sandbox `load` (machine.lua:754, verbatim)");
  dostr(L,
    /* machine.lua:754-759, with `sandbox` replaced by the env argument: this
     * state has no OC sandbox table, and env is not what is under test. */
    "function make_sandbox_load(allowBytecode)\n"
    "  return function(ld, source, mode, env)\n"
    "    if not allowBytecode then mode = 't' end\n"
    "    return load(ld, source, mode, env)\n"
    "  end\n"
    "end\n"
    "victim = function() return 42 end\n"
    "dumped = string.dump(victim)\n");

  evalstr(L, "return tostring(#dumped) .. '/' .. string.byte(dumped, 1)",
          buf, sizeof buf);
  check("SB0", strstr(buf, "/27") != NULL,
        "fixture: sandbox sees a 0x1B-leading dump", buf);

  /* The headline case: allowBytecode = false, load(string.dump(f)). */
  evalstr(L,
    "local sl = make_sandbox_load(false)\n"
    "local f, err = sl(dumped, '=attack')\n"
    "if f then return 'ACCEPTED (allowBytecode=false is a lie)' end\n"
    "return 'refused: ' .. tostring(err)\n", buf, sizeof buf);
  check("SB1", strncmp(buf, "refused:", 8) == 0,
        "allowBytecode=false: load(string.dump(f)) is REFUSED", buf);

  /* ... and the refusal must not have been "load is broken". */
  evalstr(L,
    "local sl = make_sandbox_load(false)\n"
    "local f, err = sl('return 6*7', '=ok')\n"
    "if not f then return 'BROKEN: ' .. tostring(err) end\n"
    "return tostring(f())\n", buf, sizeof buf);
  check("SB2", strcmp(buf, "42") == 0,
        "allowBytecode=false: a TEXT chunk still loads and runs", buf);

  /* An attacker naming the mode themselves must not be able to reopen it:
   * machine.lua overwrites `mode`, it does not default it. */
  evalstr(L,
    "local sl = make_sandbox_load(false)\n"
    "local f, err = sl(dumped, '=attack', 'bt')\n"
    "if f then return 'BYPASSED via explicit mode=bt' end\n"
    "return 'refused: ' .. tostring(err)\n", buf, sizeof buf);
  check("SB3", strncmp(buf, "refused:", 8) == 0,
        "allowBytecode=false: caller-supplied mode=\"bt\" does NOT bypass", buf);

  /* The other polarity: with the setting ON, bytecode must load, or the
   * setting would be meaningless in the permissive direction too. */
  evalstr(L,
    "local sl = make_sandbox_load(true)\n"
    "local f, err = sl(dumped, '=allowed')\n"
    "if not f then return 'REFUSED anyway: ' .. tostring(err) end\n"
    "return tostring(f())\n", buf, sizeof buf);
  check("SB4", strcmp(buf, "42") == 0,
        "allowBytecode=true: load(string.dump(f)) is ACCEPTED and runs", buf);

  /* ---------------------------------------------------------------- ER
   * The internal "b" route.  Both halves, in ONE state, so "shut to the
   * sandbox" and "open to eris" are shown to be simultaneously true. */
  section("ER  eris's internal bytecode route stays open");

  /* Direct entry point.  eris_lj.c:1675 calls exactly this, and is compiled
   * without the shim header so no macro above can reach it. */
  {
    BufReader r;
    int top0 = lua_gettop(L);
    r.p = bc; r.n = bclen; r.done = 0;
    check("ER1", lua_loadx(L, bufread, &r, "=erisroute", "b") == 0,
          "lua_loadx(..., \"b\") accepts our own LuaJIT bytecode", NULL);
    check("ER2", lua_pcall(L, 0, 1, 0) == 0 && lua_isstring(L, -1) &&
                 strcmp(lua_tostring(L, -1), "HELLO-FROM-TEXT") == 0,
          "  ... and the bytecode it loaded actually runs",
          lua_tostring(L, -1));
    lua_settop(L, top0);
  }

  /* The real thing: a closure through eris.persist/eris.unpersist, which
   * writes with lj_bcwrite and reads back with lua_loadx(..., "b"). */
  luaL_requiref(L, LUA_ERISLIBNAME, luaopen_eris, 1);
  lua_pop(L, 1);
  lua_getglobal(L, "eris");
  check("ER3", lua_istable(L, -1), "eris library is present in this state",
        lua_typename(L, lua_type(L, -1)));
  lua_pop(L, 1);

  evalstr(L,
    "local t = {1, 2, 'three'} t.self = t\n"
    "local mul = 3\n"
    "local f = function(x) return x * mul end\n"
    "local blob = eris.persist({[_G] = '_G'}, {t = t, f = f})\n"
    "local back = eris.unpersist({['_G'] = _G}, blob)\n"
    "return #blob .. '/' .. tostring(back.t.self == back.t)\n"
    "       .. '/' .. tostring(back.f(14))\n", buf, sizeof buf);
  check("ER4", strstr(buf, "/true/42") != NULL,
        "eris round-trips a CLOSURE through its own bytecode route", buf);

  /* And now, in this same state, immediately after eris used the "b" route:
   * the sandbox still cannot. If a "fix" ever slams the bytecode door shut
   * globally, ER4 breaks; if a "fix" opens it for everyone, SB5 breaks. */
  evalstr(L,
    "local sl = make_sandbox_load(false)\n"
    "local f = sl(dumped, '=attack')\n"
    "return f and 'SANDBOX GOT BYTECODE' or 'still refused'\n", buf, sizeof buf);
  check("SB5", strcmp(buf, "still refused") == 0,
        "sandbox is STILL shut in the same state eris just used", buf);

  /* ---------------------------------------------------------------- LE
   * lua_compare(LUA_OPLE).  Every probe is protected: the 5.1 spelling
   * raises rather than returning, and an unprotected raise would unwind out
   * of main() and hide the failure as a crash. */
  section("LE  lua_compare(LUA_OPLE) follows 5.2's __le rules");
  dostr(L,
    "leTrue   = setmetatable({}, {__le = function() return true  end})\n"
    "leFalse  = setmetatable({}, {__le = function() return false end})\n"
    "leTrue2  = setmetatable({}, getmetatable(leTrue))\n"
    "leFalse2 = setmetatable({}, getmetatable(leFalse))\n"
    "leCalls, ltCalls = 0, 0\n"
    "cntMt = {__le = function() leCalls = leCalls + 1 return true end,\n"
    "         __lt = function() ltCalls = ltCalls + 1 return true end}\n"
    "cnt1 = setmetatable({}, cntMt)\n"
    "cnt2 = setmetatable({}, cntMt)\n"
    "n1, n2 = 1, 2\n");

  /* LE1/LE2: __le is the ONLY comparison metamethod.  The 5.1 spelling looks
   * up a __lt that is not there and raises "attempt to compare two table
   * values" -- for BOTH polarities, so it is not even consistently wrong. */
  i = le_try(L, "leTrue", "leTrue2", LUA_OPLE, buf, sizeof buf);
  snprintf(detail, sizeof detail, "got %s %.300s", le_name(i), buf);
  check("LE1", i == LE_TRUE, "__le-only metatable, __le returns true  -> true",
        detail);

  i = le_try(L, "leFalse", "leFalse2", LUA_OPLE, buf, sizeof buf);
  snprintf(detail, sizeof detail, "got %s %.300s", le_name(i), buf);
  check("LE2", i == LE_FALSE, "__le-only metatable, __le returns false -> false",
        detail);

  /* LE3: both present and both true.  5.2 consults __le and says true; the
   * 5.1 form computes not(__lt(b,a)) = not true = FALSE. */
  i = le_try(L, "cnt1", "cnt2", LUA_OPLE, buf, sizeof buf);
  snprintf(detail, sizeof detail, "got %s %.300s", le_name(i), buf);
  check("LE3", i == LE_TRUE,
        "__le and __lt both true -> true (5.1 form answers false)", detail);

  /* LE4: which metamethod actually fired.  LE3 has just run exactly one
   * comparison, so the counters describe that one call. */
  evalstr(L, "return leCalls .. '/' .. ltCalls", buf, sizeof buf);
  check("LE4", strcmp(buf, "1/0") == 0,
        "LUA_OPLE fired __le once and __lt never (le/lt calls)", buf);

  /* LE5/LE6: plain numbers, so a shim cannot pass LE1-LE4 by refusing to
   * compare anything. */
  i = le_try(L, "n1", "n2", LUA_OPLE, buf, sizeof buf);
  snprintf(detail, sizeof detail, "got %s %.300s", le_name(i), buf);
  check("LE5", i == LE_TRUE, "control: 1 <= 2 is true", detail);
  i = le_try(L, "n2", "n1", LUA_OPLE, buf, sizeof buf);
  snprintf(detail, sizeof detail, "got %s %.300s", le_name(i), buf);
  check("LE6", i == LE_FALSE, "control: 2 <= 1 is false", detail);
  i = le_try(L, "n1", "n2", LUA_OPLT, buf, sizeof buf);
  check("LE7", i == LE_TRUE, "control: LUA_OPLT still works", le_name(i));
  i = le_try(L, "n1", "n2", LUA_OPEQ, buf, sizeof buf);
  check("LE8", i == LE_FALSE, "control: LUA_OPEQ still works", le_name(i));

  /* ---------------------------------------------------------------- FF */
  section("FF  FFI compiled out: no cdata from source or bytecode");
  evalstr(L, "local a, b, c, d = load('return 1, 0x10, 1e3, 0x7fffffff')() "
             "return type(a) .. type(b) .. type(c) .. type(d) .. '/' .. (a + b + c + d)",
          buf, sizeof buf);
  check("FF0", strcmp(buf, "numbernumbernumbernumber/2147484664") == 0,
        "control: plain numeric literals still load as numbers", buf);
  evalstr(L, "return tostring(debug.getregistry()._LOADED.ffi)", buf, sizeof buf);
  check("FFP", strcmp(buf, "nil") == 0,
        "fixture: registry._LOADED.ffi is nil BEFORE any literal", buf);
  {
    struct { const char *id, *src, *near, *label; } lit[] = {
      { "FF1", "return 1LL",                 "'1LL'",    "`1LL` is a syntax error (malformed number)" },
      { "FF2", "return 2ULL",                "'2ULL'",   "`2ULL` is a syntax error" },
      { "FF3", "return 0x10ULL",             "'0x10ULL'","`0x10ULL` is a syntax error" },
      { "FF4", "return 3i",                  "'3i'",     "`3i` (imaginary) is a syntax error" },
      { "FF5", "local m = 1LL << 40 return m","'1LL'",   "`1LL << 40` is a syntax error" }
    };
    for (i = 0; i < (int)(sizeof lit / sizeof lit[0]); i++) {
      int top0 = lua_gettop(L);
      int st = luaL_loadstring(L, lit[i].src);
      const char *msg = (st != 0 && lua_isstring(L, -1)) ? lua_tostring(L, -1) : "";
      if (st == 0) {
        /* HEAD: it compiled.  Say what the chunk evaluates to -- without
         * calling into the value beyond lua_type. */
        if (lua_pcall(L, 0, 1, 0) == 0)
          snprintf(detail, sizeof detail, "LOADED; returns lua_type %d (%s)",
                   lua_type(L, -1), lua_typename(L, lua_type(L, -1)));
        else
          snprintf(detail, sizeof detail, "LOADED; raised %s", lua_tostring(L, -1));
      } else {
        snprintf(detail, sizeof detail, "status=%d \"%s\"", st, msg);
      }
      check(lit[i].id, st == LUA_ERRSYNTAX && strstr(msg, "malformed number") &&
                       strstr(msg, lit[i].near), lit[i].label, detail);
      lua_settop(L, top0);
    }
  }
  /* The sandbox's route: lib_base `load` with mode "t" and an EMPTY env. */
  evalstr(L, "local f, e = load('return 1LL', '=lit', 't', {}) "
             "if f then return 'LOADED: ' .. type(f()) end return 'refused: ' .. tostring(e)",
          buf, sizeof buf);
  check("FF6", strncmp(buf, "refused:", 8) == 0 && strstr(buf, "malformed number"),
        "Lua load('return 1LL', name, 't', {}) refuses", buf);
  /* The lexer used to open FFI on demand (lj_lex.c:121-137 -> lj_ctype.h:397
   * -> luaopen_ffi -> lib_ffi.c:829-837 registers _LOADED.ffi). */
  evalstr(L, "local r = debug.getregistry() "
             "return tostring(r._LOADED.ffi) .. '/' .. tostring(r._PRELOAD.ffi)",
          buf, sizeof buf);
  check("FF7", strncmp(buf, "nil/", 4) == 0,
        "registry._LOADED.ffi is still nil after FF1-FF6", buf);
  { size_t n = strlen(buf);   /* the _PRELOAD half alone: FF7 has _LOADED */
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
    snprintf(detail, sizeof detail, "status=%d%s%s", st, st ? " " : "",
             st && lua_isstring(L, -1) ? lua_tostring(L, -1) : "");
    check("FF9", st == 0, "control: a plain stripped dump loads in mode \"b\"", detail);
    lua_settop(L, top0);
    r.p = (const char *)BC_FFI; r.n = sizeof BC_FFI; r.done = 0;
    st = lua_loadx(L, bufread, &r, "=bcffi", "b");
    if (st == 0) {
      if (lua_pcall(L, 0, 1, 0) == 0)
        snprintf(detail, sizeof detail, "LOADED; returns lua_type %d (%s)",
                 lua_type(L, -1), lua_typename(L, lua_type(L, -1)));
      else
        snprintf(detail, sizeof detail, "LOADED; raised %s", lua_tostring(L, -1));
    } else {
      snprintf(detail, sizeof detail, "status=%d \"%s\"", st,
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "");
    }
    /* The loader raises "incompatible bytecode" for four header reasons
     * (lj_bcread.c:394-418).  The two dumps differ only in the FFI flag, so
     * the refusal is the FFI one only while the plain dump (FF9) loads. */
    if (!plain_ok)
      strncat(detail, " (FF9 control failed: the header is refused for another reason)",
              sizeof detail - strlen(detail) - 1);
    check("FF10", plain_ok && st != 0 && strstr(detail, "incompatible bytecode") != NULL,
          "an FFI-flagged dump (return 1LL) is refused in mode \"b\"", detail);
    lua_settop(L, top0);
  }
  evalstr(L, "return tostring(debug.getregistry()._LOADED.ffi)", buf, sizeof buf);
  check("FF11", strcmp(buf, "nil") == 0,
        "registry._LOADED.ffi is still nil after FF10", buf);

  /* ---------------------------------------------------------------- BF */
  section("BF  string.buffer: FFI-only methods compiled out, the rest intact");
  /* Reached the way the machine state could: _PRELOAD, no package/require
   * (luaopen_string preregisters it, lib_string.c:686). */
  evalstr(L, "local open = debug.getregistry()._PRELOAD['string.buffer'] "
             "if type(open) ~= 'function' then return 'NO PRELOAD: ' .. type(open) end "
             "local sb = open('string.buffer') local b = sb.new() "
             "b:put('ab', 12) "
             "return type(b) .. '/' .. b:tostring() .. '/' .. type(b.put) .. type(b.get) .. type(b.set) .. type(b.reset)",
          buf, sizeof buf);
  check("BF0", strcmp(buf, "userdata/ab12/functionfunctionfunctionfunction") == 0,
        "control: string.buffer works; its objects are USERDATA", buf);
  {
    const char *m[] = { "reserve", "commit", "ref", "putcdata" };
    const char *ids[] = { "BF1", "BF2", "BF3", "BF4" };
    for (i = 0; i < 4; i++) {
      char src[256], what[96];
      snprintf(src, sizeof src,
               "local sb = debug.getregistry()._PRELOAD['string.buffer']('string.buffer') "
               "return type(sb.new().%s)", m[i]);
      evalstr(L, src, buf, sizeof buf);
      snprintf(what, sizeof what, "buf:%s is absent (lib_buffer.c:183-237)", m[i]);
      check(ids[i], strcmp(buf, "nil") == 0, what, buf);
    }
  }


  /* ---------------------------------------------------------------- */
  printf("\n%d checks, %d failures\n", checks, failures);
  free(bc);
  lua_close(L);
  printf(failures == 0 ? "SECURITY TESTS: PASS\n" : "SECURITY TESTS: FAIL\n");
  return failures == 0 ? 0 : 1;
}
