# mklt.py <in lj52shim.c> <out lj52shim.c> <variant>
# THE RESERVE'S LIFETIME AND SIZE -- design "lifetime", prototype generator.
# Anchored splices (each asserted to match exactly once) over EITHER the
# repo's lj52shim.c (9b912f60, = 3186e87) OR the forensics' instrumented copy
# (sc/forensics/src/lj52shim.c, 33edc64b), detected by its oclj_credit.
# Variants:
#   R<n>K | R0   THE RESERVE'S SIZE: a refusal opens LJ52_GC_RSV = n KiB past
#                the heap it found (floored at the burst top, clamped to G),
#                once per reserve episode; the fresh-record rule keeps G.
#                R0 is the destructive control (no room past the refusal).
#   L4           THE RESERVE'S LIFETIME BY RESUME (the map's L4, on the
#                shipped size): a refusal-opened reserve closes at the first
#                proof after the sandbox's next outermost arm (wd_depth 0->1).
# Nothing allocates; every write is to lj52_mem scalars.  Python writes with
# newline="" and the output is checked for CRs.
import sys

src, dst, var = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, "r", newline="") as f:
    s = f.read()
assert "\r" not in s, "source has CRs"
instr = "oclj_credit" in s
# "R4K+L4": both levers -- the size first, then the lifetime over its output
if "+" in var:
    import subprocess
    first, second = var.split("+", 1)
    tmp = dst + ".stage1"
    subprocess.check_call([sys.executable, __file__, src, tmp, first])
    subprocess.check_call([sys.executable, __file__, tmp, dst, second])
    raise SystemExit(0)
if var == "L4" and "LJ52_GC_RSV" in s:
    staged = True          # over an R variant: the fresh branch already has gc_rsv's line
else:
    staged = False


def splice(s, anchor, new, what, count=1):
    n = s.count(anchor)
    assert n == count, "%s: anchor found %d times (wanted %d)" % (what, n, count)
    return s.replace(anchor, new)


if var.startswith("R"):
    kb = var[1:]
    assert kb.endswith("K") or kb == "0"
    rsv = "(%s * 1024)" % kb[:-1] if kb != "0" else "0"

    # 1. the constant, after the window's compile-time checks
    a = ('#if LJ52_GC_KSLICE - LJ52_GC_LEND < 12 * 1024\n'
         '#error "the kernel must keep 12 KiB past the sandbox\'s ceiling (mem_test W19)"\n'
         '#endif\n')
    s = splice(s, a, a +
               "#define LJ52_GC_RSV    %-16s/* THE RESERVE'S SIZE: past a refusal  */\n" % rsv,
               "define")

    # 2. the field
    a = "  long long     gc_grown;      /* bytes granted since the last proof          */\n"
    s = splice(s, a, a +
               "  long long     gc_rsv;        /* the reserve tier's credit past the cap, set  */\n"
               "                               /* when it opens; see THE RESERVE'S SIZE       */\n",
               "field")

    # 3. the fresh-record rule keeps the whole tier
    a = ("  if (!M->gc_hyst && !M->gc_win && used > total + (lj52_gc_odmax(total) >> 1)) {\n"
         "    M->gc_odstate = LJ52_OD_RESERVE;\n"
         "    return 1;\n")
    s = splice(s, a,
               "  if (!M->gc_hyst && !M->gc_win && used > total + (lj52_gc_odmax(total) >> 1)) {\n"
               "    M->gc_odstate = LJ52_OD_RESERVE;\n"
               "    M->gc_rsv = lj52_gc_odmax(total);   /* the whole tier: the bytes are history */\n"
               "    return 1;\n",
               "fresh")

    # 4. the helper, before the kernel predicate
    a = "/* THE KERNEL'S SLICE: is the thread running the kernel's?  See THE CREDIT. */\n"
    s = splice(s, a,
               "/* THE RESERVE'S SIZE: the reserve tier's credit -- what the refusal that\n"
               " * opened it set, never under the burst tier's, never over G.  G is passed\n"
               " * in so a cap changed since then re-clamps it.  See THE CREDIT. */\n"
               "static long long lj52_gc_rsvcredit(lj52_mem *M, long long g)\n"
               "{\n"
               "  return M->gc_rsv < (g >> 1) ? g >> 1 : M->gc_rsv > g ? g : M->gc_rsv;\n"
               "}\n\n" + a,
               "helper")

    # 5. the credit
    a = "  if (!lj52_gc_reserve(M, total, used)) c >>= 1;\n"
    s = splice(s, a,
               "  if (lj52_gc_reserve(M, total, used)) c = lj52_gc_rsvcredit(M, c);\n"
               "  else c >>= 1;\n",
               "credit")

    # 6. the two tops (the proof's, the cadence's)
    a = ("        top = total + (M->gc_odstate == LJ52_OD_RESERVE ? lj52_gc_odmax(total)\n"
         "                                                        : lj52_gc_odmax(total) >> 1);\n")
    s = splice(s, a,
               "        top = total + (M->gc_odstate == LJ52_OD_RESERVE\n"
               "                       ? lj52_gc_rsvcredit(M, lj52_gc_odmax(total))\n"
               "                       : lj52_gc_odmax(total) >> 1);\n",
               "proof top")
    a = ("    top = total + (M->gc_odstate == LJ52_OD_RESERVE ? lj52_gc_odmax(total)\n"
         "                                                    : lj52_gc_odmax(total) >> 1);\n")
    s = splice(s, a,
               "    top = total + (M->gc_odstate == LJ52_OD_RESERVE\n"
               "                   ? lj52_gc_rsvcredit(M, lj52_gc_odmax(total))\n"
               "                   : lj52_gc_odmax(total) >> 1);\n",
               "cadence top")

    # 7. the refusal sizes the reserve, once
    a = ("  M->gc_odstate = LJ52_OD_RESERVE;\n"
         "  M->gc_win = 0;                        /* THE WINDOW: its cycle decides anew */\n")
    note = "    oclj_rsv_note(M, total, used, M->gc_rsv);\n" if instr else ""
    s = splice(s, a,
               "  if (M->gc_odstate != LJ52_OD_RESERVE) {   /* THE RESERVE'S SIZE: once, past this heap */\n"
               "    long long g = lj52_gc_odmax(total), over = used - total;\n"
               "    if (over < (g >> 1)) over = g >> 1;     /* never under the burst tier's top */\n"
               "    M->gc_rsv = over + LJ52_GC_RSV;         /* clamped to G where it is read */\n"
               + note +
               "  }\n" + a,
               "refused")

    # 8. _OCLJ_WALLSTATS: a 14th value, the sandbox's tier credit as it stands
    a = (" *                      window, lends, win, refused\n")
    s = splice(s, a, " *                      window, lends, win, refused, tier\n", "wallstats doc 1")
    a = (" * attributed by it).  A separate global, not more\n")
    s = splice(s, a,
               " * attributed by it); tier the sandbox's credit in its tier as it stands --\n"
               " * G/2, or what the refusal that opened the reserve set (THE RESERVE'S\n"
               " * SIZE; the sandbox's ceiling is then cap + tier + window: W19, W7k, W20\n"
               " * read it).  A separate global, not more\n",
               "wallstats doc 2")
    a = ("  lua_pushnumber(L, M ? (lua_Number)M->gc_refdelta : -1);\n"
         "  return 13;\n")
    s = splice(s, a,
               "  lua_pushnumber(L, M ? (lua_Number)M->gc_refdelta : -1);\n"
               "  lua_pushnumber(L, M == NULL || M->gc_seentotal <= 0 ? -1\n"
               "                    : (lua_Number)(M->gc_odstate == LJ52_OD_RESERVE\n"
               "                                   ? lj52_gc_rsvcredit(M, lj52_gc_odmax(M->gc_seentotal))\n"
               "                                   : lj52_gc_odmax(M->gc_seentotal) >> 1));\n"
               "  return 14;\n",
               "wallstats")

    # 9. THE CREDIT's RESERVE bullet and its bound sentence
    a = (" *   - RESERVE, after a refusal: up to G.  The refusal opens it; a proof that\n"
         " *     finds the heap back under the cap closes it.  A proof that does not --\n"
         " *     the cycle ran before the program dropped its data -- leaves it open,\n"
         " *     which is what lets \"catch, format the message, drop, carry on\" work;\n")
    s = splice(s, a,
               " *   - RESERVE, after a refusal: LJ52_GC_RSV past the heap the refusal\n"
               " *     found -- never under the burst tier's top, never past total + G.\n"
               " *     The refusal opens it; a proof that finds the heap back under the\n"
               " *     cap closes it.  A proof that does not -- the cycle ran before the\n"
               " *     program dropped its data -- leaves it open, which is what lets\n"
               " *     \"catch, format the message, drop, carry on\" work.  THE RESERVE'S\n"
               " *     SIZE (2026-10-05): it was G/2 more past the cap, whoever caught the\n"
               " *     refusal.  Caught by code that is not the program's -- the capacity\n"
               " *     probe's pcall(paint), the JIT recorder (trace_abort drops the\n"
               " *     error), OpenOS's error path -- it opened all of that for a fill\n"
               " *     that never saw it, which then held 16-256 KB more than its own\n"
               " *     refusal allowed and met the reserve top's verdict wherever it fell\n"
               " *     (3 of 30 amplified JIT-on record runs down; results-wall-window-\n"
               " *     2026-10-05).  The allocator cannot tell that catcher from the\n"
               " *     program's, so the reserve is sized for what the recovery needs:\n"
               " *     tens of bytes (W8) to a few KB (a message printed through the\n"
               " *     tty).  One window is that, and a quarter of the old floor.  Sized\n"
               " *     ONCE, at the refusal that opens the tier: later refusals in it\n"
               " *     shut the window and arm, as before, and cannot creep it (W20);\n",
               "credit comment")
    a = (" * + LJ52_GC_LEND, inside it -- so caught refusals cannot ratchet it\n"
         " * (mem_test W7, W7k), and the excursion is charged -- getFreeMemory reads\n")
    s = splice(s, a,
               " * + LJ52_GC_LEND, inside it, and after a refusal the refused heap +\n"
               " * LJ52_GC_RSV + LJ52_GC_LEND, i.e. total + G/2 + LJ52_GC_RSV + 2 *\n"
               " * LJ52_GC_LEND (W20) -- so caught refusals cannot ratchet it\n"
               " * (mem_test W7, W7k), and the excursion is charged -- getFreeMemory reads\n",
               "bound")

    if instr:
        # the instrument's read-only re-computation follows the same arithmetic
        a = ("  c = lj52_gc_odmax(total);\n"
             "  if (!(M->gc_odstate == LJ52_OD_RESERVE\n"
             "        || (!M->gc_hyst && !M->gc_win && used > total + (lj52_gc_odmax(total) >> 1))))\n"
             "    c >>= 1;\n")
        s = splice(s, a,
                   "  c = lj52_gc_odmax(total);\n"
                   "  if (M->gc_odstate == LJ52_OD_RESERVE) c = lj52_gc_rsvcredit(M, c);\n"
                   "  else if (!(!M->gc_hyst && !M->gc_win && used > total + (lj52_gc_odmax(total) >> 1)))\n"
                   "    c >>= 1;\n",
                   "oclj_credit")
        s = splice(s, "static void oclj_ref_init(lj52_mem *M);\n",
                   "static void oclj_ref_init(lj52_mem *M);\n"
                   "static void oclj_rsv_note(lj52_mem *M, long long total, long long used, long long rsv);\n",
                   "proto")
        s = splice(s, "/* The chunkname's last cap-1 bytes,",
                   "/* LIFETIME (mklt.py): one line per reserve opened by a refusal (OCLJ_REFLOG). */\n"
                   "static void oclj_rsv_note(lj52_mem *M, long long total, long long used, long long rsv)\n"
                   "{\n"
                   "  if (M->oc_log <= 0) return;\n"
                   "  fprintf(stderr, \"OCLJXP| fired=1 kind=rsv used=%lld total=%lld rsv=%lld top=%lld\\n\",\n"
                   "          used, total, rsv, total + lj52_gc_rsvcredit(M, lj52_gc_odmax(total)));\n"
                   "  fflush(stderr);\n"
                   "}\n\n/* The chunkname's last cap-1 bytes,",
                   "note body")

elif var == "L4":
    a = "  long long     gc_grown;      /* bytes granted since the last proof          */\n"
    s = splice(s, a, a +
               "  int           gc_rsvby;      /* L4: 1 the reserve was opened by a refusal   */\n"
               "  int           gc_rsvexp;     /* L4: an outermost arm since; close at proof  */\n",
               "fields")
    a = "    M->gc_odstate = LJ52_OD_RESERVE;\n"        # the fresh-record branch's (4-space) line
    s = splice(s, a, a +
               "    M->gc_rsvby = 0; M->gc_rsvexp = 0;    /* L4: a fresh record's keeps its tier */\n",
               "fresh")
    (void_staged,) = (staged,)
    a = ("  M->gc_odstate = LJ52_OD_RESERVE;\n"
         "  M->gc_win = 0;                        /* THE WINDOW: its cycle decides anew */\n")
    s = splice(s, a,
               "  if (M->gc_odstate != LJ52_OD_RESERVE) { M->gc_rsvby = 1; M->gc_rsvexp = 0; }   /* L4 */\n" + a,
               "refused")
    a = ("    M->wd_depth = 0;\n"
         "    if (lua_gethook(L) != NULL) lua_sethook(L, NULL, 0, 0);\n")
    s = splice(s, a, a +
               "    /* L4: THE RESERVE'S LIFETIME BY RESUME -- a reserve a refusal opened\n"
               "     * expires at the first proof after this resume. */\n"
               "    if (M->gc_odstate == LJ52_OD_RESERVE && M->gc_rsvby) M->gc_rsvexp = 1;\n",
               "arm")
    note = "        oclj_l4_note(M, total, used);\n" if instr else ""
    a = "      if (used <= total) M->gc_odstate = LJ52_OD_BURST;   /* repaid */\n"
    s = splice(s, a,
               "      if (M->gc_rsvexp) {                 /* L4: the reserve expired at the resume */\n"
               + note +
               "        M->gc_odstate = LJ52_OD_BURST; M->gc_rsvexp = 0;\n"
               "      }\n" + a,
               "proof")
    if instr:
        s = splice(s, "static void oclj_ref_init(lj52_mem *M);\n",
                   "static void oclj_ref_init(lj52_mem *M);\n"
                   "static void oclj_l4_note(lj52_mem *M, long long total, long long used);\n",
                   "proto")
        s = splice(s, "/* The chunkname's last cap-1 bytes,",
                   "/* LIFETIME (mklt.py): one line per reserve closed by L4 (OCLJ_REFLOG). */\n"
                   "static void oclj_l4_note(lj52_mem *M, long long total, long long used)\n"
                   "{\n"
                   "  if (M->oc_log <= 0) return;\n"
                   "  fprintf(stderr, \"OCLJXP| fired=1 kind=l4 used=%lld total=%lld win=%d\\n\", used, total, M->gc_win);\n"
                   "  fflush(stderr);\n"
                   "}\n\n/* The chunkname's last cap-1 bytes,",
                   "note body")
else:
    raise SystemExit("unknown variant " + var)

assert "\r" not in s
with open(dst, "w", newline="") as f:
    f.write(s)
print("wrote %s (%s, %s; %d lines)" % (dst, var, "instrumented" if instr else "plain", s.count("\n")))
