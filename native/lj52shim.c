/* lj52shim.c -- implementation of the Lua 5.2 C API surface OC-JNLua needs,
 * on top of LuaJIT 2.1 (Lua 5.1 ABI) built with LUAJIT_ENABLE_LUA52COMPAT and
 * LUAJIT_ENABLE_CHECKHOOK.
 *
 * See lj52shim.h for the contract and for the two comment blocks that matter
 * most: THE MODE GATE and the allocator STOPGAP.
 *
 * HOUSE RULES FOR THIS FILE (same as serializer/eris_lj.c):
 *   - every place where LuaJIT's 5.1 semantics differ from 5.2 gets a comment
 *     saying WHAT differs and WHY the chosen behaviour is the 5.2 one, so a
 *     future reader never has to re-derive the reasoning;
 *   - no getenv(), anywhere. A shipping shim has exactly ONE behaviour. The
 *     variants this file replaces carried OCLJ_NOMODECHECK (disabled the
 *     bytecode gate), OCLJ_TRACE (installed a LUA_MASKCOUNT hook -- the very
 *     hook slot OC's deadline watchdog owns), OCLJ_JITOFF, OCLJ_JITOPT,
 *     OCLJ_JITATTACH and LJ52_MEMLIMIT. Every one of those is a switch that
 *     changes security- or scheduling-relevant behaviour from the process
 *     environment, where no server operator would ever see it. If a JIT-off
 *     escape hatch is wanted it belongs in OC's own config file.
 *   - no build flags that select a known-broken behaviour.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <luajit.h>

#include "lj52shim.h"

/* Inside this file we need the GENUINE 5.1 entry points that the header
 * redirects for jnlua.c's benefit. lua_load stays redirected: it now maps to
 * LuaJIT's own lua_loadx, which is what we would want here anyway. */
#undef lua_resume
#undef luaL_newstate
#undef lua_pushcfunction

#include "eris_lj.h"

/* ================================================================== *
 * registry-cached VM helpers
 * ================================================================== */

/* lua_compare, lua_arith and lua_len must fire METAMETHODS, and must fire the
 * RIGHT ones. The only way to be sure of that on LuaJIT is to let the VM do
 * the operation, so we keep one compiled chunk per state and call into it.
 *
 * The chunk is cached in the registry under a LIGHT USERDATA key -- the
 * address of a file-static object. A string key would sit in the same
 * namespace as everything else that stores things in the registry (jnlua's
 * own "_LOADED", OC's persistence keys, luaL_ref's freelist), and this key can
 * never collide with any of them. */
static const char LJ52_HELPERS_KEY = 0;

static const char LJ52_HELPERS_SRC[] =
  /* op codes here are 5.2's: LUA_OPEQ=0 LUA_OPLT=1 LUA_OPLE=2, and
   * LUA_OPADD=0 .. LUA_OPUNM=6. */
  "local function cmp(op, a, b)\n"
  "  if op == 0 then return a == b\n"
  "  elseif op == 1 then return a < b\n"
  "  else return a <= b end\n"
  "end\n"
  "local function arith(op, a, b)\n"
  "  if op == 0 then return a + b\n"
  "  elseif op == 1 then return a - b\n"
  "  elseif op == 2 then return a * b\n"
  "  elseif op == 3 then return a / b\n"
  "  elseif op == 4 then return a % b\n"
  "  elseif op == 5 then return a ^ b\n"
  "  elseif op == 6 then return -a\n"
  "  end\n"
  "  error('bad arith op')\n"
  "end\n"
  "local function len(a) return #a end\n"
  "return { cmp = cmp, arith = arith, len = len }\n";

/* Compile and install the helper table. Leaves nothing on the stack.
 * Called once from lj52_newstate; lj52_gethelper re-runs it lazily for any
 * state we did not create. */
static void lj52_installhelpers(lua_State *L) {
  if (luaL_loadbuffer(L, LJ52_HELPERS_SRC, sizeof(LJ52_HELPERS_SRC) - 1,
                      "=[lj52shim]") != 0)
    lua_error(L);
  lua_call(L, 0, 1);                                   /* t */
  lua_pushlightuserdata(L, (void *)&LJ52_HELPERS_KEY); /* t k */
  lua_insert(L, -2);                                   /* k t */
  lua_rawset(L, LUA_REGISTRYINDEX);
}

/* Pushes helpers[name]. Raises on failure; every caller is reached from a
 * protected frame in jnlua. */
static void lj52_gethelper(lua_State *L, const char *name) {
  lua_pushlightuserdata(L, (void *)&LJ52_HELPERS_KEY);
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    lj52_installhelpers(L);
    lua_pushlightuserdata(L, (void *)&LJ52_HELPERS_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
  }
  lua_getfield(L, -1, name);
  lua_remove(L, -2);
}

/* ================================================================== *
 * lua_pushcfunction memo
 * ================================================================== */

/* See the long comment in lj52shim.h. The memo table lives at
 * registry[LJ52_CF_RIDX]; keys are the C function pointers as light userdata,
 * values are the one GCfunc we ever build for them in this state.
 *
 * Casting a function pointer to void* is not something ISO C blesses, but it
 * is well defined on every ABI this DLL can be built for (Win64, SysV x64) and
 * the union spelling keeps -Wall -Wpedantic quiet. */
typedef union { lua_CFunction f; void *p; } lj52_cfkey;

void lj52_pushcfunction(lua_State *L, lua_CFunction f) {
  lj52_cfkey k;
  k.p = NULL;
  k.f = f;
  lua_rawgeti(L, LUA_REGISTRYINDEX, LJ52_CF_RIDX);
  if (!lua_istable(L, -1)) {
    /* A state we did not create (or one whose registry has been reset).
     * Fall back to the plain 5.1 behaviour rather than failing. */
    lua_pop(L, 1);
    lua_pushcclosure(L, f, 0);
    return;
  }
  lua_pushlightuserdata(L, k.p);   /* t key */
  lua_rawget(L, -2);               /* t val */
  if (lua_isfunction(L, -1)) {     /* warm: allocation-free */
    lua_remove(L, -2);
    return;
  }
  lua_pop(L, 1);                   /* t */
  lua_pushlightuserdata(L, k.p);   /* t key */
  lua_pushcclosure(L, f, 0);       /* t key fn   -- cold: once per state */
  lua_pushvalue(L, -1);            /* t key fn fn */
  lua_insert(L, -4);               /* fn t key fn */
  lua_rawset(L, -3);               /* fn t */
  lua_pop(L, 1);                   /* fn */
}

/* ================================================================== *
 * state creation
 * ================================================================== */

/* The libc allocator the state is born on. See the "allocator ownership"
 * comment in lj52shim.h for why the state cannot use LuaJIT's own lj_alloc. */
static void *lj52_defalloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  (void)ud;
  (void)osize;
  if (nsize == 0) { free(ptr); return NULL; }
  return realloc(ptr, nsize);
}

/* An unprotected Lua error inside a JNI frame otherwise aborts the process
 * with no diagnostic at all; at least name it on the way down. */
static int lj52_panic(lua_State *L) {
  const char *s = lua_tostring(L, -1);
  fputs("LJ52 PANIC: unprotected error in call to Lua API (", stderr);
  fputs(s ? s : "?", stderr);
  fputs(")\n", stderr);
  fflush(stderr);
  return 0;
}

lua_State *lj52_newstate(void) {
  lua_State *L = lua_newstate(lj52_defalloc, NULL);
  if (!L) {
    /* Non-GC64 LuaJIT refuses a foreign allocator on x64. build-native.sh
     * gates on this at stage 1b, so reaching here means someone linked a
     * different libluajit.a. Fall back so the failure shows up as a
     * crash-on-close rather than a silent NULL. */
    L = luaL_newstate();
    if (!L) return NULL;
  }
  lua_atpanic(L, lj52_panic);

  /* --- 5.2 registry layout -------------------------------------------
   * 5.2 keeps the main thread at registry[LUA_RIDX_MAINTHREAD == 1] and the
   * globals table at registry[LUA_RIDX_GLOBALS == 2]. LuaJIT keeps neither:
   * it has LUA_GLOBALSINDEX instead. JNLua's LuaState.register(module, fns,
   * global=true) does rawGet(REGISTRYINDEX, RIDX_GLOBALS) followed by
   * setField, so on an unseeded LuaJIT registry it would index nil.
   * Neither OC nor ocelot-brain calls register() today, so this is latent
   * rather than load-bearing -- but it is one of the 5.2 invariants a caller
   * is entitled to assume, and seeding it costs two stores at startup.
   * Side effect worth knowing: luaL_ref numbers references from
   * lua_objlen(registry)+1, so refs now start at 4 instead of 1, exactly as
   * they do on 5.2 (which starts at 3). Nothing persists a raw ref number
   * across a state, so this is safe. */
  lua_pushthread(L);
  lua_rawseti(L, LUA_REGISTRYINDEX, 1);
  lua_pushvalue(L, LUA_GLOBALSINDEX);
  lua_rawseti(L, LUA_REGISTRYINDEX, 2);

  /* registry[3] = the lua_pushcfunction memo table (LJ52_CF_RIDX). */
  lua_newtable(L);
  lua_rawseti(L, LUA_REGISTRYINDEX, LJ52_CF_RIDX);

  /* The VM helper chunk used by lua_compare / lua_arith / lua_len. Built
   * eagerly so those three never have to compile anything on a hot path. */
  lj52_installhelpers(L);

  /* --- turn the JIT on ------------------------------------------------
   * LuaJIT only sets JIT_F_ON inside luaopen_jit, and jnlua never opens the
   * jit library (5.2 has no such library to open). Without this the state
   * runs interpreter-only and the entire point of the exercise is lost.
   * pcall'd because a failure here must degrade to interpreter mode, not
   * take the JVM down; the outcome is recorded in _OCLJ_JIT so a harness can
   * assert on it.
   *
   * NOTE the nresults=0. luaopen_jit installs the global `jit` table ITSELF
   * (LJ_LIB_REG -> lj_lib_register, which writes _LOADED.jit and the global),
   * and its `return 1` does NOT describe the top of the stack: lib_jit.c
   * pushes four scratch values for use as upvalues, registers jit and jit.opt,
   * and then does `L->top -= 2`, so what a caller sees on top is a leftover
   * STRING. The base variant of this shim took that value and did
   * lua_setglobal(L, "jit") with it, clobbering the freshly registered jit
   * table with the string "x64" -- measured: `jit` was type string, not table.
   * The JIT itself was still on (jit_init runs first), which is why it went
   * unnoticed, but jit.on/jit.off/jit.status were unreachable from Lua.
   * Asking for zero results and letting the opener do its own registration is
   * both correct and simpler. */
  lua_pushcclosure(L, luaopen_jit, 0);
  lua_pushliteral(L, LUA_JITLIBNAME);
  if (lua_pcall(L, 1, 0, 0) == 0) {
    lua_pushliteral(L, "ok");
  } else {
    /* pcall pushed the error message even with nresults == 0. */
    lua_pushfstring(L, "luaopen_jit failed: %s", lua_tostring(L, -1));
    lua_remove(L, -2);
  }
  lua_setglobal(L, "_OCLJ_JIT");

  /* An unfakeable marker that this state came from the LuaJIT-backed native.
   * ocelot-brain sets includeLuaJ = !isAvailable, so a failed native load
   * SILENTLY substitutes LuaJ -- which has no Eris, so every persistence test
   * then passes vacuously. Any harness that claims a result must read this
   * global out of the live state and refuse to report a pass without it. */
  lua_pushliteral(L, "luajit/" LUAJIT_VERSION);
  lua_setglobal(L, "_OCLJ_NATIVE");
  return L;
}

/* ================================================================== *
 * index / length / comparison
 * ================================================================== */

int lua_absindex(lua_State *L, int idx) {
  /* Same shape as 5.2's lua_absindex. On LuaJIT every pseudo-index
   * (LUA_REGISTRYINDEX, LUA_ENVIRONINDEX, LUA_GLOBALSINDEX and the upvalue
   * indices) is <= LUA_REGISTRYINDEX, so 5.2's test transfers unchanged.
   * Using LUA_GLOBALSINDEX as the floor instead would mangle
   * LUA_REGISTRYINDEX, which is more negative. */
  return (idx > 0 || idx <= LUA_REGISTRYINDEX) ? idx : lua_gettop(L) + idx + 1;
}

size_t lua_rawlen(lua_State *L, int idx) {
  /* 5.2's lua_rawlen is 5.1's lua_objlen: raw length, no __len. */
  return lua_objlen(L, idx);
}

int lua_compare(lua_State *L, int idx1, int idx2, int op) {
  int r;
  /* THE __le FIX. -----------------------------------------------------
   * The obvious 5.1 spelling for LUA_OPLE is `!lua_lessthan(L, idx2, idx1)`,
   * because 5.1 itself implements `a <= b` as `not (b < a)` when there is no
   * __le. That is wrong on 5.2 in three distinct ways, all measured against
   * this LuaJIT build with a differential harness (see AUDIT/le_test.c):
   *   - on a metatable defining ONLY __le, the fallback looks up a __lt that
   *     is not there and RAISES "attempt to compare two table values", both
   *     when __le would return true and when it would return false;
   *   - with __le and __lt both present and both returning true, the fallback
   *     returns FALSE where 5.2 returns TRUE;
   *   - it fires the WRONG metamethod: __lt once, __le never.
   * A third spelling seen in sibling variants, `lua_lessthan(a,b) ||
   * lua_equal(a,b)`, is wrong the same way and additionally fires __eq.
   * Routing through the VM's own `<=` gets all of it right for free, because
   * LUAJIT_ENABLE_LUA52COMPAT already makes the VM use 5.2's __le rules.
   * (Nothing in OC or ocelot-brain calls LuaState.compare today, so this was
   * latent rather than a live regression -- but it is a wrong 5.2 surface and
   * costs nothing to get right.) */
  idx1 = lua_absindex(L, idx1);
  idx2 = lua_absindex(L, idx2);
  lj52_gethelper(L, "cmp");
  lua_pushinteger(L, op);
  lua_pushvalue(L, idx1);
  lua_pushvalue(L, idx2);
  lua_call(L, 3, 1);
  r = lua_toboolean(L, -1);
  lua_pop(L, 1);
  return r;
}

void lua_arith(lua_State *L, int op) {
  /* 5.2: pops the operands (2, or 1 for LUA_OPUNM) and pushes the result,
   * honouring the arithmetic metamethods. Routed through the VM for the same
   * reason as lua_compare. */
  int nargs = (op == LUA_OPUNM) ? 1 : 2;
  int base  = lua_gettop(L) - nargs + 1;   /* index of the first operand */
  lj52_gethelper(L, "arith");              /* a [b] f  */
  lua_insert(L, base);                     /* f a [b]  */
  lua_pushinteger(L, op);                  /* f a [b] op */
  lua_insert(L, base + 1);                 /* f op a [b] */
  lua_call(L, nargs + 1, 1);
}

void lua_len(lua_State *L, int idx) {
  /* 5.2's lua_len honours __len on tables as well as strings; 5.1's
   * lua_objlen does not. `#x` in a LUA52COMPAT VM does. */
  idx = lua_absindex(L, idx);
  lj52_gethelper(L, "len");
  lua_pushvalue(L, idx);
  lua_call(L, 1, 1);
}

/* ================================================================== *
 * unsigned accessors
 * ================================================================== */

/* LuaJIT has no integer subtype: every number is a double. 5.2's
 * lua_pushunsigned/lua_tounsigned are exact for the whole 32-bit range a
 * double can represent, which is the entire domain of lua_Unsigned, so these
 * are exact rather than merely practical. */
void lua_pushunsigned(lua_State *L, lua_Unsigned n) {
  lua_pushnumber(L, (lua_Number)n);
}

lua_Unsigned lua_tounsigned(lua_State *L, int idx) {
  /* 5.2 converts modulo 2^32 (luaconf.h's lua_number2unsigned). Doing the
   * reduction in floating point first avoids the undefined behaviour of
   * casting an out-of-range double straight to an integer type. */
  double d = (double)lua_tonumber(L, idx);
  if (!(d > -9.0e18 && d < 9.0e18)) return 0;   /* NaN / inf / absurd */
  d = d - floor(d / 4294967296.0) * 4294967296.0;
  return (lua_Unsigned)(unsigned long long)d;
}

/* ================================================================== *
 * luaL_getsubtable / luaL_requiref / luaL_tolstring
 * ================================================================== */

int luaL_getsubtable(lua_State *L, int idx, const char *fname) {
  idx = lua_absindex(L, idx);
  lua_getfield(L, idx, fname);
  if (lua_istable(L, -1)) return 1;             /* already there */
  lua_pop(L, 1);
  lua_newtable(L);
  lua_pushvalue(L, -1);
  lua_setfield(L, idx, fname);
  return 0;
}

void luaL_requiref(lua_State *L, const char *modname, lua_CFunction openf, int glb) {
  /* 5.2's luaL_requiref consults package.loaded first and only calls openf if
   * the module is not already there; several sibling variants always called
   * openf, which re-runs a library opener and discards the previous module
   * table (so anything that had already been stored into it is lost). */
  luaL_getsubtable(L, LUA_REGISTRYINDEX, "_LOADED");
  lua_getfield(L, -1, modname);
  if (!lua_toboolean(L, -1)) {
    lua_pop(L, 1);
    lua_pushcclosure(L, openf, 0);
    lua_pushstring(L, modname);
    lua_call(L, 1, 1);
    lua_pushvalue(L, -1);
    lua_setfield(L, -3, modname);
  }
  if (glb) {
    lua_pushvalue(L, -1);
    lua_setglobal(L, modname);
  }
  lua_replace(L, -2);   /* drop _LOADED, leave the module on top */
}

const char *luaL_tolstring(lua_State *L, int idx, size_t *len) {
  idx = lua_absindex(L, idx);
  if (luaL_callmeta(L, idx, "__tostring")) {
    if (!lua_isstring(L, -1)) luaL_error(L, "'__tostring' must return a string");
  } else {
    switch (lua_type(L, idx)) {
      case LUA_TNUMBER:
      case LUA_TSTRING:
        lua_pushvalue(L, idx);
        break;
      case LUA_TBOOLEAN:
        lua_pushstring(L, lua_toboolean(L, idx) ? "true" : "false");
        break;
      case LUA_TNIL:
        lua_pushliteral(L, "nil");
        break;
      default:
        lua_pushfstring(L, "%s: %p", luaL_typename(L, idx), lua_topointer(L, idx));
        break;
    }
  }
  return lua_tolstring(L, -1, len);
}

/* ================================================================== *
 * resume
 * ================================================================== */

int lj52_resume(lua_State *L, lua_State *from, int nargs) {
  (void)from;
  return lua_resume(L, nargs);
}

/* ================================================================== *
 * coroutine
 * ================================================================== */

int luaopen_coroutine(lua_State *L) {
  /* 5.2 splits the coroutine library out of the base library and gives it its
   * own opener. LuaJIT's luaopen_base already registers the global
   * `coroutine` table, and OC always opens BASE before COROUTINE
   * (LuaStateFactory.openLibs), so the right answer is to hand back the table
   * that already exists rather than build a second one. */
  lua_getglobal(L, LUA_COLIBNAME);
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
  }
  return 1;
}

/* ================================================================== *
 * bit32 -- Lua 5.2 semantics
 * ================================================================== */

/* This is a real 5.2 bit32, NOT an alias for LuaJIT's luaopen_bit. Two
 * sibling variants defined luaopen_bit32 as luaopen_bit; that is wrong
 * because BitOp returns SIGNED 32-bit results (bit.bnot(0) == -1) whereas
 * 5.2's bit32 returns unsigned ones (bit32.bnot(0) == 4294967295), and OpenOS
 * arithmetic on the result then differs. */

#define B32MASK 0xFFFFFFFFu

static unsigned int b32arg(lua_State *L, int i) {
  /* 5.2: "the given argument is converted to an integer modulo 2^32". The
   * base variant of this shim did `(unsigned)((long long)d & 0xFFFFFFFF)`,
   * which TRUNCATES toward zero before masking -- so it disagrees with 5.2
   * for any argument with a fractional part (-3.5 becomes -3, not -4) and is
   * undefined for |d| >= 2^63. The floating-point floor-modulo below is
   * 5.2's actual definition and has neither problem. */
  double d = (double)luaL_checknumber(L, i);
  if (!(d > -9.0e18 && d < 9.0e18)) return 0;   /* NaN / inf */
  d = d - floor(d / 4294967296.0) * 4294967296.0;
  return (unsigned int)(unsigned long long)d;
}

static int b32_band(lua_State *L) {
  int n = lua_gettop(L), i;
  unsigned int r = B32MASK;
  for (i = 1; i <= n; i++) r &= b32arg(L, i);
  lua_pushnumber(L, (lua_Number)r);
  return 1;
}
static int b32_bor(lua_State *L) {
  int n = lua_gettop(L), i;
  unsigned int r = 0;
  for (i = 1; i <= n; i++) r |= b32arg(L, i);
  lua_pushnumber(L, (lua_Number)r);
  return 1;
}
static int b32_bxor(lua_State *L) {
  int n = lua_gettop(L), i;
  unsigned int r = 0;
  for (i = 1; i <= n; i++) r ^= b32arg(L, i);
  lua_pushnumber(L, (lua_Number)r);
  return 1;
}
static int b32_btest(lua_State *L) {
  int n = lua_gettop(L), i;
  unsigned int r = B32MASK;
  for (i = 1; i <= n; i++) r &= b32arg(L, i);
  lua_pushboolean(L, r != 0);
  return 1;
}
static int b32_bnot(lua_State *L) {
  lua_pushnumber(L, (lua_Number)(~b32arg(L, 1) & B32MASK));
  return 1;
}

/* 5.2's shifts are logical, saturate to 0 past 32 bits, and treat a negative
 * displacement as a shift in the other direction. */
static int b32_lshift(lua_State *L) {
  unsigned int r = b32arg(L, 1);
  int i = (int)luaL_checknumber(L, 2);
  unsigned int res;
  if (i < 0) { i = -i; res = (i >= 32) ? 0 : ((r >> i) & B32MASK); }
  else       { res = (i >= 32) ? 0 : ((r << i) & B32MASK); }
  lua_pushnumber(L, (lua_Number)res);
  return 1;
}
static int b32_rshift(lua_State *L) {
  unsigned int r = b32arg(L, 1);
  int i = (int)luaL_checknumber(L, 2);
  unsigned int res;
  if (i < 0) { i = -i; res = (i >= 32) ? 0 : ((r << i) & B32MASK); }
  else       { res = (i >= 32) ? 0 : ((r >> i) & B32MASK); }
  lua_pushnumber(L, (lua_Number)res);
  return 1;
}
static int b32_arshift(lua_State *L) {
  unsigned int r = b32arg(L, 1);
  int i = (int)luaL_checknumber(L, 2);
  unsigned int res;
  if (i < 0) {                       /* negative displacement: shift left */
    i = -i;
    res = (i >= 32) ? 0 : ((r << i) & B32MASK);
  } else {
    int neg = (r & 0x80000000u) != 0;
    if (i >= 32) res = neg ? B32MASK : 0;
    else if (i == 0) res = r;
    else {
      res = r >> i;
      if (neg) res |= (B32MASK << (32 - i)) & B32MASK;
    }
  }
  lua_pushnumber(L, (lua_Number)res);
  return 1;
}
static int b32_lrotate(lua_State *L) {
  unsigned int r = b32arg(L, 1);
  int i = (int)luaL_checknumber(L, 2) & 31;
  lua_pushnumber(L, (lua_Number)(((r << i) | (r >> ((32 - i) & 31))) & B32MASK));
  return 1;
}
static int b32_rrotate(lua_State *L) {
  unsigned int r = b32arg(L, 1);
  int i = (int)luaL_checknumber(L, 2) & 31;
  lua_pushnumber(L, (lua_Number)(((r >> i) | (r << ((32 - i) & 31))) & B32MASK));
  return 1;
}

/* 5.2's exact argument-error messages for the field accessors, so a Lua-side
 * pcall that matches on them behaves the same as on PUC 5.2. */
static int b32field(lua_State *L, int i, int *width) {
  int f = (int)luaL_checknumber(L, i);
  int w = (int)luaL_optnumber(L, i + 1, 1);
  luaL_argcheck(L, 0 <= f, i, "field cannot be negative");
  luaL_argcheck(L, 0 < w, i + 1, "width must be positive");
  if (f + w > 32) luaL_error(L, "trying to access non-existent bits");
  *width = w;
  return f;
}
static int b32_extract(lua_State *L) {
  int w;
  unsigned int v = b32arg(L, 1);
  int f = b32field(L, 2, &w);
  lua_pushnumber(L, (lua_Number)((v >> f) & (B32MASK >> (32 - w))));
  return 1;
}
static int b32_replace(lua_State *L) {
  int w;
  unsigned int v = b32arg(L, 1);
  unsigned int r = b32arg(L, 2);
  int f = b32field(L, 3, &w);
  unsigned int m = B32MASK >> (32 - w);
  lua_pushnumber(L, (lua_Number)(((v & ~(m << f)) | ((r & m) << f)) & B32MASK));
  return 1;
}

static const luaL_Reg bit32lib[] = {
  {"arshift", b32_arshift}, {"band",    b32_band},    {"bnot",    b32_bnot},
  {"bor",     b32_bor},     {"bxor",    b32_bxor},    {"btest",   b32_btest},
  {"extract", b32_extract}, {"lrotate", b32_lrotate}, {"lshift",  b32_lshift},
  {"replace", b32_replace}, {"rrotate", b32_rrotate}, {"rshift",  b32_rshift},
  {NULL, NULL}
};

int luaopen_bit32(lua_State *L) {
  /* lua_newtable + luaL_register(L, NULL, ...) and NOT
   * luaL_register(L, LUA_BITLIBNAME, ...): the latter also creates a global
   * named "bit32" as a side effect. jnlua reaches this through
   * luaL_requiref(L, LUA_BITLIBNAME, luaopen_bit32, glb), which is the code
   * that gets to decide whether a global is created. */
  lua_newtable(L);
  luaL_register(L, NULL, bit32lib);
  return 1;
}

/* ================================================================== *
 * eris
 * ================================================================== */

int luaopen_eris(lua_State *L) {
  /* jnlua.c's openlib case for ERIS is
   *     luaL_requiref(L, LUA_ERISLIBNAME, luaopen_eris, 1)
   * -- one name, one opener, no other eris-specific constant anywhere in
   * jnlua.c. Our serializer's luaopen_eris_lj leaves the module table on the
   * stack exactly as requiref needs. */
  int n = luaopen_eris_lj(L);

  /* _VERSION. OC's platform is 5.2 source and the harness fingerprint reads
   * this out of the live state. It has to be set HERE rather than in
   * lj52_newstate for an ordering reason that is easy to get wrong:
   * LuaStateFactory.openLibs opens BASE first, and LuaJIT's luaopen_base
   * assigns _VERSION = "Lua 5.1", clobbering anything set at state creation.
   * ERIS is opened after BASE (BASE, BIT32, COROUTINE, DEBUG, ERIS, ...), so
   * this is the last opener that can win.
   * The string must not contain "5.3" or "5.4": machine.lua:65-66 pattern-
   * matches _VERSION to decide which Lua dialect it is running on, and
   * machine.lua:812 derives the sandbox's own _VERSION from it. */
  lua_pushliteral(L, "Lua+Eris 5.2");
  lua_setglobal(L, "_VERSION");
  return n;
}
