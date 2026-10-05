# frag-from-forensics.py -- derive THIS directory's frag_types.c, frag_protos.c
# and frag_hooks.c from the forensics' (sc/forensics/tools/), by anchored
# splices asserted to match exactly once, for THE RESERVE'S SIZE (the final
# native/lj52shim.c, md5 28a8f091).  What changes in the instrument, and why:
#   - oclj_credit, the read-only re-computation of lj52_gc_credit, follows the
#     final shim: no credit under HOOK_VMEVENT; in the reserve tier the credit
#     is lj52_gc_rsvcredit's (m-L4 in d3-final.txt);
#   - the record and the OCLJREF line gain rsv0= (gc_rsv before the refusal),
#     rsv= (after), tier= (the sandbox's credit in its tier after it, the
#     arithmetic of _OCLJ_WALLSTATS' 14th value with the refusal's total);
#   - oclj_rsv_note: the "OCLJXP| fired=1 kind=rsv rsv= used= total= over= top=
#     G=" line at the sizing block (lifetime's, with over=).
# frag_fields.c is the forensics' unchanged.  Python writes with newline="".
import os

here = os.path.dirname(os.path.abspath(__file__))
fo = os.path.normpath(os.path.join(here, "..", "..", "forensics", "tools"))


def rd(name):
    with open(os.path.join(fo, name), "r", newline="") as f:
        t = f.read()
    assert "\r" not in t, name
    return t


def wr(name, t):
    assert "\r" not in t, name
    with open(os.path.join(here, name), "w", newline="") as f:
        f.write(t)
    print("wrote %s (%d bytes)" % (name, len(t)))


def splice(s, anchor, new, what):
    n = s.count(anchor)
    assert n == 1, "%s: anchor found %d times" % (what, n)
    return s.replace(anchor, new, 1)


# ---- frag_types.c: the record's three new fields, and the banner
t = rd("frag_types.c")
t = splice(t,
           "/* Made by mkref.py from the repo's lj52shim.c.  No branch of the shim's\n",
           "/* Made by mkref.py (sc/finst/tools) from the repo's lj52shim.c -- THE\n"
           " * RESERVE'S SIZE, md5 28a8f091.  No branch of the shim's\n",
           "types banner")
t = splice(t,
           "  long long delta, used, total, G, credit, top, low, grown, gctotal, gcthresh;\n",
           "  long long delta, used, total, G, credit, top, low, grown, gctotal, gcthresh;\n"
           "  long long rsv0, rsv, tier;            /* THE RESERVE'S SIZE: gc_rsv before and */\n"
           "                                        /* after; the tier's credit after        */\n",
           "types fields")
wr("frag_types.c", t)

# ---- frag_protos.c: the note's prototype
p = rd("frag_protos.c")
p = splice(p,
           "static void oclj_ref_init(lj52_mem *M);\n",
           "static void oclj_ref_init(lj52_mem *M);\n"
           "static void oclj_rsv_note(lj52_mem *M, long long total, long long used);\n",
           "proto")
wr("frag_protos.c", p)

# ---- frag_hooks.c
h = rd("frag_hooks.c")
h = splice(h,
           "/* lj52_gc_credit without its one side effect (lj52_gc_reserve can move a\n"
           " * fresh record to the reserve tier): the same arithmetic, read only. */\n"
           "static long long oclj_credit(lj52_mem *M, global_State *g, long long total, long long used, int kernel)\n"
           "{\n"
           "  long long c;\n"
           "  if (M->L == NULL || total <= 0) return 0;\n"
           "  if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) return 0;\n"
           "  c = lj52_gc_odmax(total);\n"
           "  if (!(M->gc_odstate == LJ52_OD_RESERVE\n"
           "        || (!M->gc_hyst && !M->gc_win && used > total + (lj52_gc_odmax(total) >> 1))))\n"
           "    c >>= 1;\n"
           "  if (kernel) c += LJ52_GC_KSLICE;\n"
           "  return c;\n"
           "}\n",
           "/* lj52_gc_credit without its one side effect (lj52_gc_reserve can move a\n"
           " * fresh record to the reserve tier): the same arithmetic, read only.  THE\n"
           " * RESERVE'S SIZE: in the reserve tier the credit is lj52_gc_rsvcredit's\n"
           " * (what the refusal that opened it set, clamped to [G/2, G]); a fresh\n"
           " * record past the burst top would be moved there with gc_rsv = G, so its\n"
           " * credit is G.  No credit under HOOK_VMEVENT, as in the shim. */\n"
           "static long long oclj_credit(lj52_mem *M, global_State *g, long long total, long long used, int kernel)\n"
           "{\n"
           "  long long c;\n"
           "  if (M->L == NULL || total <= 0) return 0;\n"
           "  if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) return 0;\n"
           "  if (g->hookmask & HOOK_VMEVENT) return 0;\n"
           "  c = lj52_gc_odmax(total);\n"
           "  if (M->gc_odstate == LJ52_OD_RESERVE) c = lj52_gc_rsvcredit(M, c);\n"
           "  else if (!(!M->gc_hyst && !M->gc_win && used > total + (lj52_gc_odmax(total) >> 1)))\n"
           "    c >>= 1;\n"
           "  if (kernel) c += LJ52_GC_KSLICE;\n"
           "  return c;\n"
           "}\n"
           "\n"
           "/* THE RESERVE'S SIZE: one line per reserve a refusal sized (OCLJ_REFLOG),\n"
           " * from the sizing block of lj52_gc_refused, after gc_rsv is set and before\n"
           " * the tier is opened.  over = used - total, the heap past the cap the\n"
           " * refused request found (negative: a refusal under the cap by one big\n"
           " * request); top = the reserve tier's top as it will be read, through\n"
           " * lj52_gc_rsvcredit's clamp.  Reads only; prints only. */\n"
           "static void oclj_rsv_note(lj52_mem *M, long long total, long long used)\n"
           "{\n"
           "  long long g = lj52_gc_odmax(total);\n"
           "  if (M->oc_log <= 0) return;\n"
           "  fprintf(stderr, \"OCLJXP| fired=1 kind=rsv rsv=%lld used=%lld total=%lld over=%lld top=%lld G=%lld calls=%lld\\n\",\n"
           "          M->gc_rsv, used, total, used - total, total + lj52_gc_rsvcredit(M, g), g, M->mem_calls);\n"
           "  fflush(stderr);\n"
           "}\n",
           "credit")
h = splice(h,
           "  r->tier0 = M->gc_odstate;\n",
           "  r->tier0 = M->gc_odstate;\n"
           "  r->rsv0 = M->gc_rsv;\n",
           "pre rsv0")
h = splice(h,
           "  r->tier1 = M->gc_odstate;\n",
           "  r->tier1 = M->gc_odstate;\n"
           "  r->rsv = M->gc_rsv;\n"
           "  r->tier = r->total <= 0 ? 0\n"
           "          : M->gc_odstate == LJ52_OD_RESERVE ? lj52_gc_rsvcredit(M, lj52_gc_odmax(r->total))\n"
           "          : lj52_gc_odmax(r->total) >> 1;\n",
           "post rsv/tier")
h = splice(h,
           "          \" credit=%lld top=%lld ceil=%lld over=%lld\"\n",
           "          \" credit=%lld top=%lld ceil=%lld over=%lld rsv0=%lld rsv=%lld tier=%lld\"\n",
           "format")
h = splice(h,
           "          r->credit, r->top, ceil, r->used + r->delta - r->top,\n",
           "          r->credit, r->top, ceil, r->used + r->delta - r->top, r->rsv0, r->rsv, r->tier,\n",
           "args")
wr("frag_hooks.c", h)
