/* wrapcp.c -- the hermetic driver's GROUND TRUTH for "the JIT recorder
 * absorbed it": linked with -Wl,--wrap=lj_vm_cpcall, every protected C call
 * LuaJIT makes passes through here, and one that returns an error is
 * printed (OCLJ_REFLOG set) as
 *   OCLJCP| st=<status> recorder=<1 when ud is the jit_State>
 * The trace recorder's protected calls all pass the jit_State as ud
 * (lj_trace_ins -> trace_state; and the nested rec_stop_stitch_cp,
 * recff_metacall_cp, recff_xpcall_cp, cpsplit, which rethrow to it); the
 * others (lua_load's parser, lua_cpcall, the loop optimiser's &lps, the
 * concat recorder's &rcd -- the last two also rethrow inside the recorder)
 * do not.  trace_abort drops the error the outermost one returns, so the
 * program never sees it.  Compiled WITHOUT -include lj52shim.h. */
#include <stdio.h>
#include <stdlib.h>
#include "lua.h"
#include "lj_obj.h"
#include "lj_dispatch.h"
#include "lj_vm.h"

int drv_reflog = -1;

int __real_lj_vm_cpcall(lua_State *L, lua_CFunction func, void *ud, lua_CPFunction cp);
int __wrap_lj_vm_cpcall(lua_State *L, lua_CFunction func, void *ud, lua_CPFunction cp);

int __wrap_lj_vm_cpcall(lua_State *L, lua_CFunction func, void *ud, lua_CPFunction cp)
{
  int st = __real_lj_vm_cpcall(L, func, ud, cp);
  if (st != 0) {
    if (drv_reflog < 0) drv_reflog = getenv("OCLJ_REFLOG") != NULL;
    if (drv_reflog) {
      fprintf(stderr, "OCLJCP| st=%d recorder=%d\n", st, ud == (void *)G2J(G(L)));
      fflush(stderr);
    }
  }
  return st;
}
