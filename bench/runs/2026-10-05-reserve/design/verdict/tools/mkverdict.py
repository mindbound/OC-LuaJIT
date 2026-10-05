# mkverdict.py <in lj52shim.c> <out lj52shim.c> [ref]
# THE ADDRESS -- the "verdict" design prototype (revision 2): anchored splices
# over the repo's lj52shim.c (3186e87, md5 9b912f60) or over the forensics'
# instrumented copy of it (md5 33edc64b); every anchor must match exactly
# once.  With "ref" the instrumented copy also gets addr= and rec= on every
# OCLJREF line, and one OCLJHOLD| line per held verdict (OCLJ_REFLOG set).
# Python writes with newline="" (no CRLF); the output is checked for CRs.
import sys

src, dst = sys.argv[1], sys.argv[2]
ref = len(sys.argv) > 3 and sys.argv[3] == "ref"
with open(src, "r", newline="") as f:
    s = f.read()
assert "\r" not in s, "source has CRs"


def splice(s, anchor, new, what):
    n = s.count(anchor)
    assert n == 1, "%s: anchor found %d times" % (what, n)
    return s.replace(anchor, new, 1)


# 1. the record's fields, after THE WINDOW's
a = "  long long     gc_refdelta;   /* the last refused request, bytes: diagnostics */\n"
s = splice(s, a, a +
           "  /* -- THE ADDRESS: the verdict's addressee; see THE WINDOW -- */\n"
           "  const void   *gc_hand;       /* the handler of record: the function the  */\n"
           "  const void   *gc_handL;      /* innermost pcall called, and its thread --  */\n"
           "  long          gc_handn;      /* compared, never followed -- and its vote  */\n"
           "  int           gc_addr;       /* this call's request is addressed to it     */\n"
           "  int           gc_rec;        /* ... is the trace recorder's own            */\n"
           "  volatile long gc_holds;      /* verdicts held: lent on past another        */\n"
           "  volatile long gc_holdfail;   /* holds that met their ceiling: diagnostics  */\n"
           "  volatile long gc_recref;     /* the recorder's refusals: they opened nothing */\n",
           "fields")

# 2. the prototype
a = "static int lj52_gc_lend(lj52_mem *M, long long total, long long used, long long delta);\n"
s = splice(s, a, a + "static void lj52_gc_vote(lj52_mem *M);\n", "proto")

# 3. the slow path, C mode: the vote after the look
a = ("    if (acct && delta > 0 && M->total - M->used < delta)\n"
     "      lj52_gc_look(M, M->total, M->used);   /* THE WINDOW: a finished cycle first */\n")
s = splice(s, a,
           "    if (acct && delta > 0 && M->total - M->used < delta) {\n"
           "      lj52_gc_look(M, M->total, M->used);   /* THE WINDOW: a finished cycle first */\n"
           "      lj52_gc_vote(M);                      /* THE ADDRESS: whose growth is this  */\n"
           "    }\n", "C-mode slow path")

# 4. the slow path, legacy
a = ("  if (delta > 0 && total - used < delta)\n"
     "    lj52_gc_look(M, total, used);           /* THE WINDOW: a finished cycle first */\n")
s = splice(s, a,
           "  if (delta > 0 && total - used < delta) {\n"
           "    lj52_gc_look(M, total, used);           /* THE WINDOW: a finished cycle first */\n"
           "    lj52_gc_vote(M);                        /* THE ADDRESS: whose growth is this  */\n"
           "  }\n", "legacy slow path")

# 5. the frame macros
a = "#include \"lj_jit.h\"\n"
s = splice(s, a, a + "#include \"lj_frame.h\"                  /* THE ADDRESS reads frame links */\n", "include")

# 6. THE WINDOW's comment: which refusal shuts the window
a = (" * A refusal shuts the window, so the cycle it arms decides the next\n"
     " * crossing: a caught refusal in the reserve tier opens no room, and without\n")
s = splice(s, a,
           " * A refusal shuts the window (the recorder's excepted: THE ADDRESS, below),\n"
           " * so the cycle it arms decides the next\n"
           " * crossing: a caught refusal in the reserve tier opens no room, and without\n",
           "window comment")

# 7. THE ADDRESS comment block, before THE VALVE
a = " * THE VALVE COUNTS ATTEMPTS.  LJ52_GC_ARMCAP counts allocator calls that\n"
ADDRESS = r''' * THE ADDRESS (2026-10-05; docs/roadmap.md, "A refusal the program never
 * saw opens the reserve tier for it").  THE WINDOW's verdict is a finding
 * about the heap -- live data past the tier's top, twice proven -- but it
 * was executed by whichever growth came next: the fill's (good), the
 * capacity probe's pcall(paint), the trace recorder's GCtrace, event.timer's
 * record.  Hermetically every refusal the paint or the recorder absorbed
 * was a verdict (2 328 of 2 328 in 28 672 runs; the paint opened the second
 * chance in 2 169 of 2 192, the recorder in 23), and such a refusal opened
 * the reserve tier for a program that never saw it, so its data went on to
 * the reserve top, where the next verdict could land outside any handler
 * (21 of 228 in the OpenOS-shaped probe; the machine's 3 downs in 30).
 * Stock has no tier: an absorbed refusal there changes nothing, and the
 * program meets its own at the same live set.  So the verdict is ADDRESSED.
 * The handler of record is the protected call under which most of this
 * episode's growths past the cap were made -- its callee's prototype and
 * its thread, one candidate and one count (a majority vote, reset by a
 * proof that finds the heap under the cap) -- read from the frame links the
 * VM keeps and lj_err.c's unwinder walks, from jit_base on a trace as
 * lj_err_mem reads it, LJ52_GC_WALK links at most, nothing followed and
 * nothing allocated.  A request is addressed when it comes from under that
 * handler and not from inside the trace recorder's protected call
 * (lj_vm_cpcall's frame, J->state not idle, vmstate not C, GC or EXIT:
 * trace_abort drops that error, lj_trace.c:585-656).  Then:
 *   - a verdict refuses only an addressed crossing.  Any other is HELD: lent
 *     on with the verdict standing, so the program's own next crossing
 *     meets it, in its handler.  A standing verdict STANDS through the
 *     proofs the held lends arm, until one finds the heap under the top:
 *     THE WINDOW's two-cycle rule, read again at such a proof, would demote
 *     it, because the held lends it has since collected and whatever the
 *     kernel holds live between resumes both sit in the bytes granted since
 *     the previous proof -- and a verdict demoted to "open" lets the next
 *     crossing meet the plain ceiling (the dispatcher's pack after the
 *     kernel's garbage: the sandbox down, measured, section (d)).  Two
 *     consecutive cycles proved the data; a third past the top does not
 *     unprove it.  A held crossing may go LJ52_GC_HOLD past the window in
 *     the burst tier -- the code between a machine's steps (a paint of five
 *     component calls, event.timer, the dispatcher) is a few KB, and a hold
 *     that ended at the window's ceiling would end in that code -- and no
 *     further than the window in the reserve tier, whose window is the
 *     sandbox's bound.  The kernel's slice lies past the hold's room as it
 *     lies past the window: its burst top gains LJ52_GC_HOLD, so it keeps
 *     LJ52_GC_KSLICE - LJ52_GC_LEND past whatever the sandbox was lent;
 *   - the recorder's own refusal -- past the hold's room, or on the kernel's
 *     thread, where nothing is lent -- counts and arms as every refusal
 *     does (W2b/W2c) but opens no reserve tier and shuts no window: nobody
 *     recovers from it, and the program sees the next one at the same top,
 *     as stock would.  Every other refusal, the hold's ceiling included,
 *     opens the reserve tier as before: a program whose growth moved to
 *     another of its own handlers is refused there, later by the hold's
 *     room, and must still be able to format and drop.
 * The kernel's own requests are addressed as before.  No pointer kept here
 * is followed after it is read, so a prototype freed and reused costs at
 * worst one verdict delivered as today; nothing crosses eris (a fresh
 * record votes anew).  The bounds are unchanged: LJ52_GC_LEND + LJ52_GC_HOLD
 * <= G/2 at the smallest G (checked at compile time), so a held crossing
 * stays under total + G + LJ52_GC_LEND and the kernel under total + G +
 * LJ52_GC_KSLICE.  What it costs: one frame walk per growth past the cap,
 * one to four links as a rule; a program that holds its data under a
 * handler that makes few of the growths -- a quiet producer behind a chatty
 * consumer -- gets today's delivery, by sequence; and the kernel's burst
 * top, which was total + G/2 + the slice, is that plus the hold's room
 * (C6b).  What it does not fix: another's growth that overruns the hold's
 * room is refused at its ceiling and opens the reserve tier, as today; and
 * nothing here reaches a refusal no window was open for (W9's class, the
 * kernel's garbage between resumes).
 *
'''
s = splice(s, a, ADDRESS + a, "address comment")

# 8. the constants
a = ("#if LJ52_GC_KSLICE - LJ52_GC_LEND < 12 * 1024\n"
     "#error \"the kernel must keep 12 KiB past the sandbox's ceiling (mem_test W19)\"\n"
     "#endif\n")
s = splice(s, a, a +
           "#define LJ52_GC_HOLD   (8 * 1024)       /* THE ADDRESS: a held verdict's room past */\n"
           "                                        /* the window, in the burst tier            */\n"
           "#if LJ52_GC_LEND + LJ52_GC_HOLD > LJ52_GC_ODMIN / 2\n"
           "#error \"a held verdict must stay under the reserve top at the smallest G, or the sandbox's bound moves\"\n"
           "#endif\n", "constants")

# 9. the kernel's credit: its slice past the hold's room
a = "  if (lj52_gc_kernel(M, g)) c += LJ52_GC_KSLICE;\n"
s = splice(s, a, a +
           "  if (lj52_gc_kernel(M, g) && M->gc_odstate != LJ52_OD_RESERVE)\n"
           "    c += LJ52_GC_HOLD;                  /* THE ADDRESS: the slice past the hold */\n", "kernel credit")
a = "    if (lj52_gc_kernel(M, g)) top += LJ52_GC_KSLICE;   /* where the kernel is refused */\n"
s = splice(s, a,
           "    if (lj52_gc_kernel(M, g))                          /* where the kernel is refused */\n"
           "      top += LJ52_GC_KSLICE + (M->gc_odstate == LJ52_OD_RESERVE ? 0 : LJ52_GC_HOLD);\n",
           "cadence kernel top")

# 10. the hold, before the lend; the lend consults it before the ceiling
a = "/* THE WINDOW: lend a sandbox growth the credit refused?  Up to LJ52_GC_LEND\n"
HOLD = ("/* THE ADDRESS: a verdict stands and this sandbox crossing is not the\n"
        " * program's own.  Lend on, the verdict standing, within the window and --\n"
        " * in the burst tier -- LJ52_GC_HOLD past it; arm as the window arms, so\n"
        " * the next proof decides again.  Past that room: refused, counted, and\n"
        " * the refusal opens the reserve tier as any does (lj52_gc_refused),\n"
        " * unless it is the recorder's. */\n"
        "static int lj52_gc_hold(lj52_mem *M, global_State *g, long long used, long long delta, long long top)\n"
        "{\n"
        "  long long room = LJ52_GC_LEND + (M->gc_odstate == LJ52_OD_RESERVE ? 0 : LJ52_GC_HOLD);\n"
        "  if (used + delta > top + room) { M->gc_holdfail++; return 0; }   /* the hold's ceiling */\n"
        "  M->gc_holds++;\n"
        + ("  oclj_hold_note(M);\n" if ref else "") +
        "  M->gc_lends++;\n"
        "  if (!M->gc_armed) lj52_gc_arm(M, g, LJ52_ARM_WALL);   /* the window's cycle */\n"
        "  return 1;\n"
        "}\n\n")
s = splice(s, a, HOLD + a, "hold")
a = ("  top = total + lj52_gc_credit(M, total, used);\n"
     "  if (used + delta > top + LJ52_GC_LEND) return 0;      /* the ceiling */\n")
s = splice(s, a,
           "  top = total + lj52_gc_credit(M, total, used);\n"
           "  if (M->gc_win == 2 && M->gc_low > top && !M->gc_addr)  /* THE ADDRESS: another's crossing */\n"
           "    return lj52_gc_hold(M, g, used, delta, top);         /* under a standing verdict: held */\n"
           "  if (used + delta > top + LJ52_GC_LEND) return 0;      /* the ceiling */\n", "lend")

# 11. the refusal: the recorder's opens nothing
a = ("  M->gc_odstate = LJ52_OD_RESERVE;\n"
     "  M->gc_win = 0;                        /* THE WINDOW: its cycle decides anew */\n"
     "  if (M->gc_armed) M->gc_armby = LJ52_ARM_WALL;\n")
s = splice(s, a,
           "  if (!M->gc_rec) {                     /* THE ADDRESS: not the recorder's own */\n"
           "    M->gc_odstate = LJ52_OD_RESERVE;\n"
           "    M->gc_win = 0;                      /* THE WINDOW: its cycle decides anew */\n"
           "  } else M->gc_recref++;                /* the recorder's: it opens nothing */\n"
           "  if (M->gc_armed) M->gc_armby = LJ52_ARM_WALL;\n", "refused")

# 12. the proof: a heap back under the cap starts a new episode; a standing
#     verdict stands until a proof finds the heap under the top
a = "      if (used <= total) M->gc_odstate = LJ52_OD_BURST;   /* repaid */\n"
s = splice(s, a, a + "      if (used <= total) M->gc_handn = 0;                  /* THE ADDRESS: a new episode */\n",
           "proof")
a = "        M->gc_win = used <= top ? 0 : used - M->gc_grown > top ? 2 : 1;\n"
s = splice(s, a,
           "        M->gc_win = used <= top ? 0                       /* THE ADDRESS: a standing */\n"
           "                 : (M->gc_win == 2 || used - M->gc_grown > top) ? 2 : 1;   /* verdict stands */\n",
           "proof verdict")

# 13. the vote and the handler walk, before lj52_gc_refused's comment
a = "/* A refusal: counted, the valve and the proof seen to first, then the\n"
VOTE = r'''#define LJ52_GC_WALK 64                 /* frame links THE ADDRESS follows   */

/* THE ADDRESS: the handler of record's identity for the running thread --
 * the function the innermost pcall or xpcall called (the frame pcall gave
 * it carries FRAME_PCALL: vm_x64.dasc ff_pcall, lj_err.c err_unwind), its
 * prototype when it is a Lua function so that a fresh closure per step is
 * the same handler; NULL when nothing in this coroutine protects the
 * request.  0 when the frames cannot be read -- a slot that holds no
 * function, a walk past LJ52_GC_WALK links -- and the caller then treats the
 * request as addressed, which is today's behaviour.  Reads only; the base is
 * lj_err_mem's own (jit_base on a trace). */
static int lj52_gc_handler(lua_State *L, global_State *g, const void **id)
{
  TValue *stk = tvref(L->stack), *bot = stk + LJ_FR2;
  TValue *base = tvref(g->jit_base), *frame;
  int n;
  if (base == NULL) base = L->base;
  if (base <= bot + 1 || base > stk + L->stacksize) return 0;
  frame = base - 1;
  for (n = 0; n < LJ52_GC_WALK && frame > bot; n++) {
#if LJ_FR2
    if (!tvisfunc(frame - 1)) return 0;
#endif
    if (frame_ispcall(frame)) {
      GCfunc *fn = frame_func(frame);
      *id = isluafunc(fn) ? (const void *)funcproto(fn) : (const void *)fn;
      return 1;
    }
    frame = frame_prev(frame);
  }
  if (n >= LJ52_GC_WALK) return 0;
  *id = NULL;                           /* nothing protects this coroutine */
  return 1;
}

/* THE ADDRESS: whose growth is this?  On the slow path, once per request
 * that would pass the cap: the vote (one candidate, one count), and whether
 * this request is addressed -- from under the handler of record, on its
 * thread, and not the trace recorder's own (the forensics' predicate: a
 * cpcall frame, J->state not idle, vmstate not C, GC or EXIT; 31 000 of
 * 31 000 refusals against the recorder's protected call itself).  The
 * kernel is addressed; so is any request whose frames cannot be read.  Not
 * under norefuse, HOOK_GC or a host GCSTOP: nothing is decided there. */
static void lj52_gc_vote(lj52_mem *M)
{
  global_State *g;
  lua_State *L;
  const void *id = NULL;
  void *cf;
  M->gc_addr = 1;
  M->gc_rec = 0;
  if (M->L == NULL || M->norefuse > 0) return;
  g = G(M->L);
  if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) return;
  L = gco2th(gcref(g->cur_L));
  if (L == NULL) return;
  cf = cframe_raw(L->cframe);
  M->gc_rec = G2J(g)->state != LJ_TRACE_IDLE && g->vmstate < 0 && g->vmstate != ~LJ_VMST_C
              && g->vmstate != ~LJ_VMST_GC && g->vmstate != ~LJ_VMST_EXIT
              && cf != NULL && cframe_nres(cf) < 0 && (char *)cframe_pc(cf) == (char *)cframe_L(cf);
  if (lj52_gc_kernel(M, g) || !lj52_gc_handler(L, g, &id)) { M->gc_addr = !M->gc_rec; return; }
  if (M->gc_handn > 0 && M->gc_handL == (const void *)L && M->gc_hand == id) M->gc_handn++;
  else if (M->gc_handn > 0) M->gc_handn--;
  else { M->gc_handL = (const void *)L; M->gc_hand = id; M->gc_handn = 1; }
  M->gc_addr = !M->gc_rec && M->gc_handL == (const void *)L && M->gc_hand == id;
}

'''
s = splice(s, a, VOTE + a, "vote")

# 14. _OCLJ_WALLSTATS: six more values
a = ("  lua_pushnumber(L, M ? (lua_Number)M->gc_refdelta : -1);\n"
     "  return 13;\n")
s = splice(s, a,
           "  lua_pushnumber(L, M ? (lua_Number)M->gc_refdelta : -1);\n"
           "  lua_pushinteger(L, M ? M->gc_holds : -1);      /* THE ADDRESS */\n"
           "  lua_pushinteger(L, M ? M->gc_recref : -1);\n"
           "  lua_pushinteger(L, M ? M->gc_handn : -1);\n"
           "  lua_pushinteger(L, M ? M->gc_addr : -1);\n"
           "  lua_pushinteger(L, M ? LJ52_GC_HOLD : -1);\n"
           "  lua_pushinteger(L, M ? M->gc_holdfail : -1);\n"
           "  return 19;\n", "wallstats")
a = (" *                      od_limit, kernel_slice, gc_low, armby, hyst,\n"
     " *                      window, lends, win, refused\n")
s = splice(s, a,
           " *                      od_limit, kernel_slice, gc_low, armby, hyst,\n"
           " *                      window, lends, win, refused,\n"
           " *                      holds, recorder_refusals, handvotes, addressed,\n"
           " *                      hold, holdfails\n", "wallstats doc")
a = (" * hermetic W16 cases judge \"covered\" by it, and a capacity run's stall is\n"
     " * attributed by it).  A separate global, not more\n")
s = splice(s, a,
           " * hermetic W16 cases judge \"covered\" by it, and a capacity run's stall is\n"
           " * attributed by it).  THE ADDRESS's six: holds, the verdicts held for the\n"
           " * program while another's growth was lent on; recorder_refusals, the\n"
           " * recorder's own, which opened nothing; handvotes, the handler of\n"
           " * record's standing count; addressed, whether the last request past the\n"
           " * cap was the program's own; hold, LJ52_GC_HOLD (the burst tier's kernel\n"
           " * top is then cap + G/2 + kernel_slice + hold: C6b); holdfails, holds\n"
           " * that met their ceiling (a capacity run's down is attributed by it).\n"
           " * Nineteen values: under LUA_MINSTACK still.  A separate global, not more\n",
           "wallstats doc 2")

if ref:
    # the instrumented copy: addr= and rec= on OCLJREF, and OCLJHOLD lines
    a = "  int fkind, ffid, line, pcsrc, ctx, tline;\n"
    s = splice(s, a, a + "  int addr, isrec;                      /* THE ADDRESS: addressed, the recorder's */\n", "ref type")
    a = "  r->grown = M->gc_grown;\n"
    s = splice(s, a, a + "  r->addr = M->gc_addr;\n  r->isrec = M->gc_rec;\n", "ref pre")
    a = "          \" calls=%lld arms=%ld/%ld/%ld/%ld/%ld proofs=%ld lends=%ld collects=%ld\\n\",\n"
    s = splice(s, a,
               "          \" addr=%d rec=%d calls=%lld arms=%ld/%ld/%ld/%ld/%ld proofs=%ld lends=%ld collects=%ld\\n\",\n",
               "ref fmt")
    a = "          r->calls, r->arms[0], r->arms[1], r->arms[2], r->arms[3], r->arms[4],\n"
    s = splice(s, a, "          r->addr, r->isrec, r->calls, r->arms[0], r->arms[1], r->arms[2], r->arms[3], r->arms[4],\n",
               "ref args")
    a = "static void oclj_prf_post(lj52_mem *M, long long total, long long used);\n"
    s = splice(s, a, a + "static void oclj_hold_note(lj52_mem *M);\n", "ref proto")
    a = "/* Called at the end of lj52_gc_arm.  The cause: the flush's arm; inside\n"
    NOTE = r'''/* THE ADDRESS (verdict prototype): one line per held verdict. */
static void oclj_hold_note(lj52_mem *M)
{
  global_State *g = G(M->L);
  if (M->oc_log <= 0) return;
  fprintf(stderr, "OCLJHOLD| st=%p used=%lld tier=%d win=%d vm=%s jst=%s calls=%lld holds=%ld votes=%ld rec=%d\n",
          (void *)M, M->used, M->gc_odstate, M->gc_win, oclj_vmname(g->vmstate),
          oclj_jname(G2J(g)->state), M->mem_calls, M->gc_holds, M->gc_handn, M->gc_rec);
  fflush(stderr);
}

'''
    s = splice(s, a, NOTE + a, "ref note")

assert "\r" not in s
with open(dst, "w", newline="") as f:
    f.write(s)
print("wrote %s (%d bytes, %d lines)%s" % (dst, len(s), s.count("\n"), " [ref]" if ref else ""))
