# mkid.py <in lj52shim.c> <out lj52shim.c> <flags...>
# THE RECIPIENT -- the "identify" design, as anchored splices over either the
# repo's lj52shim.c (the shippable diff) or the forensics' instrumented copy
# (the measurement).  Every anchor must match exactly once.
# Flags (the shippable object is all of rec,res,vmevent):
#   rec      a refusal inside the trace recorder's protected call opens no
#            reserve, shuts no window, consumes no verdict (counted apart)
#   res      the reserve a refusal opens reaches LJ52_GC_RESERVE past the heap
#            it was refused at (clamped to [G/2, G]); a fresh record keeps G
#   vmevent  HOOK_VMEVENT handled like HOOK_GC: no credit, no window, no reserve
#   instr    the instrumented copy: one "OCLJID|" line per refusal (OCLJ_REFLOG)
# Always: the counters (gc_refabsorbed, gc_refstrtab, gc_refrecording), the
# string-table doubling recognised and counted, the four new _OCLJ_WALLSTATS
# values, the new comment block.
import sys

src, dst, flags = sys.argv[1], sys.argv[2], set(sys.argv[3:])
assert flags <= {"rec", "res", "vmevent", "instr"}, flags
REC, RES, VME, INSTR = "rec" in flags, "res" in flags, "vmevent" in flags, "instr" in flags
with open(src, "r", newline="") as f:
    s = f.read()
assert "\r" not in s, "source has CRs"


def splice(s, anchor, new, what, n=1):
    c = s.count(anchor)
    assert c == n, "%s: anchor found %d times (want %d)" % (what, c, n)
    return s.replace(anchor, new)


# 1. the fields, after gc_refdelta
a = "  long long     gc_refdelta;   /* the last refused request, bytes: diagnostics */\n"
s = splice(s, a, a +
           "  /* -- THE RECIPIENT; see THE CREDIT -- */\n"
           "  long long     gc_odcredit;   /* the reserve tier's credit, set as it opens  */\n"
           "  volatile long gc_refabsorbed;/* refusals inside the recorder: not the program's */\n"
           "  volatile long gc_refstrtab;  /* ... of all refusals, intern-table doublings  */\n"
           "  volatile long gc_refrecording;/* ... raised while recording, yet the program's */\n",
           "fields")

# 2. the constant, after LJ52_GC_LEND
a = "#define LJ52_GC_LEND   (4 * 1024)       /* THE WINDOW; <= KSLICE: the bound  */\n"
s = splice(s, a, a +
           "#define LJ52_GC_RESERVE (4 * 1024)      /* THE RECIPIENT: a refusal's reserve */\n",
           "constant")

# 3. lj_frame.h, for the cframe reads
a = '#include "lj_jit.h"\n'
s = splice(s, a, a + '#include "lj_frame.h"                  /* THE RECIPIENT: cframe_nres/pc  */\n', "include")

# 4. the comment block, before THE CADENCE
a = " * THE CADENCE (2026-10-04).  Until this change, once a proven cycle left the\n"
COMMENT = r""" * THE RECIPIENT (2026-10-05).  A refusal is a message to the program that
 * made the request -- your data does not fit -- and it opens the reserve
 * tier so that the catch, the message and the drop can be paid for.  But
 * the allocator hands it to whoever made the crossing, and some recipients
 * are not the program and tell it nothing: the trace recorder, whose
 * protected call it unwinds and whose error trace_abort drops (lj_trace.c);
 * a VM event handler, run under lj_vm_pcall and reported to stderr; and,
 * on the sandbox's own thread, code with a handler of its own -- the
 * capacity probe's pcall(paint), OpenOS's event dispatcher -- which the
 * allocator cannot tell from the program.  Each left the reserve tier open
 * for a fill that never heard, and the reserve top's refusal then landed
 * wherever the next crossing was: 21 of 228 such second chances in the
 * OpenOS-shaped hermetic probe ended outside every handler, 0 of 1 820 runs
 * without one (bench/results-wall-window-2026-10-05.md, "What is left").
 *   - A refusal raised INSIDE THE RECORDER'S PROTECTED CALL opens no
 *     reserve, shuts no window and consumes no verdict: the verdict stands
 *     for the next crossing, which is the program's.  Known without a
 *     LuaJIT line: the running thread's innermost C frame is an
 *     lj_vm_cpcall frame (saved PC == L, negative nres: vm_x64.dasc), the
 *     recorder is not idle, and the VM is not in a C function, the
 *     collector or a trace exit -- the recorder's cpcalls are the only ones
 *     reached with vmstate RECORD, OPT or ASM.  J->state alone is NOT it:
 *     it stays RECORD while the interpreter executes the instruction just
 *     recorded, and a refusal there reaches the program (1 092 did, in the
 *     forensics' sweeps; counted here as gc_refrecording).  The flag agreed
 *     with a --wrap=lj_vm_cpcall ground truth on all 31 000 refusals of
 *     those sweeps.  Counted apart (gc_refabsorbed); the cycle still armed,
 *     as every refusal arms it.
 *   - Under HOOK_VMEVENT, as under HOOK_GC: no credit, no window, no
 *     reserve.  A handler exists only once something calls jit.attach (the
 *     harness's trace counter; the sandbox has no `jit`), and its refusal
 *     is dropped with "VM handler failed".
 *   - The reserve a refusal opens reaches LJ52_GC_RESERVE past the heap it
 *     was refused at -- never under the burst tier's top, never past
 *     total + G -- not G/2 further whatever the cap.  The recovery it
 *     exists for (mem_test W8) is tens of bytes, a message through the tty
 *     a few KB; G/2 is 16 KB at the floor and 256 KB at caps of 8 MB.  So a
 *     refusal the program never saw buys its fill LJ52_GC_RESERVE plus THE
 *     WINDOW, in every cap, instead of up to a quarter of a megabyte.  A
 *     fresh record's reserve (above) keeps G: that is history, not a
 *     refusal.
 *   - The intern table's doubling (lj_str.c: the string is linked, THEN the
 *     table grown, and the growth's refusal thrown in whoever made the
 *     string -- again at every new string until a sweep) is recognised,
 *     str.num > str.mask with a request of 2 (mask + 1) GCRefs, and only
 *     COUNTED (gc_refstrtab): in 28 672 hermetic runs it never fired, and
 *     the reserve is what lets its retry succeed when the doubling is under
 *     G/2.  If the machine's count says it fires, the fix is in
 *     lj_str_resize (a failed growth keeps the old table), not a tier rule.
 * The bound tightens and stays absolute: the sandbox's used + delta <=
 * total + min(G, max(G/2, r + LJ52_GC_RESERVE - total)) + LJ52_GC_LEND,
 * r the heap at the refusal that opened the tier; every thread's <= total
 * + G + LJ52_GC_KSLICE, as before.  Not identified, and bounded only by the
 * third rule: the kernel's own refusals (pcall(main): the machine is down
 * whatever the tier) and the sandbox-thread handlers no test can name.
"""
s = splice(s, a, COMMENT + " *" + chr(10) + a, "comment")

# 5. the fresh record keeps G
a = "  if (!M->gc_hyst && !M->gc_win && used > total + (lj52_gc_odmax(total) >> 1)) {\n    M->gc_odstate = LJ52_OD_RESERVE;\n"
s = splice(s, a, a + "    M->gc_odcredit = lj52_gc_odmax(total);   /* THE RECIPIENT: history keeps G */\n", "fresh")

# 6. the helpers, before THE KERNEL'S SLICE
a = "/* THE KERNEL'S SLICE: is the thread running the kernel's?  See THE CREDIT. */\n"
HELPERS = r"""/* THE RECIPIENT: the credit the current tier gives past the cap. */
static long long lj52_gc_tiercredit(lj52_mem *M, long long total)
{
  return M->gc_odstate == LJ52_OD_RESERVE ? M->gc_odcredit : lj52_gc_odmax(total) >> 1;
}

/* THE RECIPIENT: the reserve a refusal at heap `used` opens -- LJ52_GC_RESERVE
 * past it, never under the burst tier's top, never past G. */
static long long lj52_gc_odfor(long long total, long long used)
{
  long long G = lj52_gc_odmax(total), c = used + LJ52_GC_RESERVE - total;
  return c < (G >> 1) ? (G >> 1) : c > G ? G : c;
}

/* THE RECIPIENT: was this refusal raised inside the trace recorder's
 * protected call?  Read-only, two loads on the running thread's own stack;
 * only on the refusal path. */
static int lj52_gc_absorbed(lj52_mem *M, global_State *g)
{
  lua_State *L;
  void *cf;
  (void)M;
  if (G2J(g)->state == LJ_TRACE_IDLE) return 0;
  if (g->vmstate >= 0 || g->vmstate == ~LJ_VMST_C || g->vmstate == ~LJ_VMST_GC
      || g->vmstate == ~LJ_VMST_EXIT) return 0;
  L = gco2th(gcref(g->cur_L));
  if (L == NULL) return 0;
  cf = cframe_raw(L->cframe);
  return cf != NULL && cframe_nres(cf) < 0 && (char *)cframe_pc(cf) == (char *)cframe_L(cf);
}

"""
if not RES:   # the variants without the reserve rule do not call lj52_gc_odfor
    i = HELPERS.index("/* THE RECIPIENT: the reserve a refusal at heap")
    j = HELPERS.index("/* THE RECIPIENT: was this refusal raised")
    HELPERS = HELPERS[:i] + HELPERS[j:]
s = splice(s, a, HELPERS + a, "helpers")

# 7. the credit: the reserve tier's credit, and HOOK_VMEVENT
a = "  if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) return 0;\n  c = lj52_gc_odmax(total);\n  if (!lj52_gc_reserve(M, total, used)) c >>= 1;\n"
new = ("  if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) return 0;\n"
       + ("  if (g->hookmask & HOOK_VMEVENT) return 0;   /* THE RECIPIENT: as a finalizer */\n" if VME else "")
       + "  c = lj52_gc_odmax(total);\n"
       + ("  if (lj52_gc_reserve(M, total, used)) c = M->gc_odcredit;   /* THE RECIPIENT */\n  else c >>= 1;\n"
          if RES else "  if (!lj52_gc_reserve(M, total, used)) c >>= 1;\n"))
s = splice(s, a, new, "credit")
if not RES:
    # the tier credit helper must still agree with the shipped arithmetic
    s = s.replace("  return M->gc_odstate == LJ52_OD_RESERVE ? M->gc_odcredit : lj52_gc_odmax(total) >> 1;\n",
                  "  return M->gc_odstate == LJ52_OD_RESERVE ? lj52_gc_odmax(total) : lj52_gc_odmax(total) >> 1;\n")

# 8. the lend: HOOK_VMEVENT
a = "  if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM || lj52_gc_kernel(M, g))\n    return 0;\n"
if VME:
    s = splice(s, a, a + "  if (g->hookmask & HOOK_VMEVENT) return 0;   /* THE RECIPIENT: as a finalizer */\n", "lend")

# 9. the two tier tops
a = ("        top = total + (M->gc_odstate == LJ52_OD_RESERVE ? lj52_gc_odmax(total)\n"
     "                                                        : lj52_gc_odmax(total) >> 1);\n")
s = splice(s, a, "        top = total + lj52_gc_tiercredit(M, total);\n", "top (proof)")
a = ("    top = total + (M->gc_odstate == LJ52_OD_RESERVE ? lj52_gc_odmax(total)\n"
     "                                                    : lj52_gc_odmax(total) >> 1);\n")
s = splice(s, a, "    top = total + lj52_gc_tiercredit(M, total);\n", "top (cadence)")

# 10. the refusal
a = ("  if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) return;\n"
     "  M->gc_odstate = LJ52_OD_RESERVE;\n"
     "  M->gc_win = 0;                        /* THE WINDOW: its cycle decides anew */\n")
new = ("  if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) return;\n"
       + ("  if (g->hookmask & HOOK_VMEVENT) return;   /* THE RECIPIENT: as a finalizer */\n" if VME else "")
       + "  /* THE RECIPIENT: the intern table's doubling, recognised and counted. */\n"
         "  if (g->str.num > g->str.mask\n"
         "      && M->gc_refdelta == (long long)(g->str.mask + 1) * 2 * (long long)sizeof(GCRef))\n"
         "    M->gc_refstrtab++;\n"
         "  absorbed = lj52_gc_absorbed(M, g);\n"
       + ("  if (M->oc_log > 0) {\n"
          "    fprintf(stderr, \"OCLJID| st=%p absorbed=%d strtab=%d strnum=%u strmask=%u jst=%d vm=%d tier0=%d\"\n"
          "            \" odcredit=%lld used=%lld total=%lld delta=%lld\\n\", (void *)M, absorbed,\n"
          "            g->str.num > g->str.mask && M->gc_refdelta == (long long)(g->str.mask + 1) * 2 * (long long)sizeof(GCRef),\n"
          "            (unsigned)g->str.num, (unsigned)g->str.mask, (int)G2J(g)->state, (int)g->vmstate, M->gc_odstate,\n"
          "            M->gc_odcredit, used, total, M->gc_refdelta);\n"
          "    fflush(stderr);\n"
          "  }\n" if INSTR else "")
       + "  if (G2J(g)->state != LJ_TRACE_IDLE && !absorbed) M->gc_refrecording++;\n"
       + ("  if (absorbed) {                       /* THE RECIPIENT: not the program's */\n"
          "    M->gc_refabsorbed++;\n"
          "    if (!M->gc_armed) lj52_gc_arm(M, g, LJ52_ARM_WALL);\n"
          "    return;\n"
          "  }\n" if REC else
          "  if (absorbed) M->gc_refabsorbed++;   /* counted only: the rule is not in this variant */\n")
       + ("  if (M->gc_odstate != LJ52_OD_RESERVE) M->gc_odcredit = lj52_gc_odfor(total, used);\n" if RES
          else "  M->gc_odcredit = lj52_gc_odmax(total);\n")
       + "  M->gc_odstate = LJ52_OD_RESERVE;\n"
         "  M->gc_win = 0;                        /* THE WINDOW: its cycle decides anew */\n")
s = splice(s, a, new, "refused")
a = "static void lj52_gc_refused(lj52_mem *M, long long total, long long used)\n{\n  global_State *g;\n"
s = splice(s, a, a + "  int absorbed;\n", "refused decl")

# 11. the stats: four more values
a = "  lua_pushnumber(L, M ? (lua_Number)M->gc_refdelta : -1);\n  return 13;\n}\n"
s = splice(s, a,
           "  lua_pushnumber(L, M ? (lua_Number)M->gc_refdelta : -1);\n"
           "  /* 14-17, THE RECIPIENT (2026-10-05): refusals raised inside the trace\n"
           "   * recorder (not the program's: no reserve), the intern table's doublings\n"
           "   * among all refusals, refusals raised while recording that WERE the\n"
           "   * program's, and the reserve tier's credit as it stands. */\n"
           "  lua_pushinteger(L, M ? M->gc_refabsorbed : -1);\n"
           "  lua_pushinteger(L, M ? M->gc_refstrtab : -1);\n"
           "  lua_pushinteger(L, M ? M->gc_refrecording : -1);\n"
           "  lua_pushnumber(L, M ? (lua_Number)M->gc_odcredit : -1);\n"
           "  return 17;\n}\n", "wallstats")
a = " *                      window, lends, win, refused\n"
s = splice(s, a, " *                      window, lends, win, refused, absorbed, strtab,\n *                      recording, od_credit\n", "wallstats comment")

assert "\r" not in s
with open(dst, "w", newline="") as f:
    f.write(s)
print("wrote %s (%s) %d lines" % (dst, ",".join(sorted(flags)) or "counters only", s.count("\n")))
