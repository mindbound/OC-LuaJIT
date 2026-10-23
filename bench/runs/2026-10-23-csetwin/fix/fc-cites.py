"""fc-cites.py <repo> <base build copy src> <pin lj_opt_fold.c> [shift] --
the CSE type twin round's final check, its line cites by content.

Each row below is one line cite in a file of the round (a code, test or
script file; the docs have their own check in the docs phase): the citing
file (repo-relative), the token it must still hold (so a cite that is
renumbered or dropped in the citing file is seen), the cited file (BC: the
unfixed base build copy, build/native's luajit-windows-x86_64/src at
1a13bed, read only; PR: the pin's pristine lj_opt_fold.c, git cat-file of
1ee778a4:src/lj_opt_fold.c), the cited line, and a text that line must
hold.  With shift = +1 or -1 every cited line moves by that much, and every
row must then fail: the texts are distinctive enough that a cite one line
off is seen (the fail-first).

Prints one line per row and a last line "cites: rows=<n> ok=<n> bad=<n>
shift=<s>"; exit 0 iff every row holds (shift 0), or iff every row fails
(shift +1 or -1).  Reads files as bytes and strips a line-end CR."""
import sys

REPO, BCD, PIN = sys.argv[1], sys.argv[2], sys.argv[3]
SHIFT = int(sys.argv[4]) if len(sys.argv) > 4 else 0

R = "test/native/bitop/t_cserev.lua"
P = "native/luajit/patch-bitop-fold.sh"
ROWS = [
    # citing file, token in it, cited file, line, text the line holds
    (R, "lj_opt_fold.c:2675", "BC:lj_opt_fold.c", 2675, "return TREF(ref, irt_t(IR(ref)->t));  /* Common subexpression found. */"),
    (R, "lj_record.c:2052", "BC:lj_record.c", 2052, "select_detect(J)"),
    (R, "(:2053)", "BC:lj_record.c", 2053, "TRef tridx = getslot(J, dst-1);"),
    (R, "(:2054)", "BC:lj_record.c", 2054, "TRef tr = TREF_NIL;"),
    (R, "(:2080)", "BC:lj_record.c", 2080, "emitir(IRTGI(IR_ULT), tmp2, "),
    (R, "(:2081)", "BC:lj_record.c", 2081, "tmp2 = emitir(IRTI(IR_BSHL), tridx, lj_ir_kint(J, 3));"),
    (R, "(:2082)", "BC:lj_record.c", 2082, "tmp = emitir(IRTI(IR_ADD), tmp2, tmp);"),
    (R, "(:2086)", "BC:lj_record.c", 2086, "emitir(IRTGI(IR_LT), fr, tmp);"),
    (R, "(:2097)", "BC:lj_record.c", 2097, "J->base[dst-2-LJ_FR2] = tr;"),
    (R, "(:2098)", "BC:lj_record.c", 2098, "J->maxslot = dst-1-LJ_FR2;"),
    (R, "863) narrows", "BC:lj_ffrecord.c", 863, "static void LJ_FASTCALL recff_string_range(jit_State *J, RecordFFData *rd)"),
    (R, "(:888 for byte", "BC:lj_ffrecord.c", 888, "trstart = lj_opt_narrow_toint(J, J->base[1]);"),
    (R, ":873 for sub)", "BC:lj_ffrecord.c", 873, "trstart = lj_opt_narrow_toint(J, J->base[1]);"),
    (R, "(:894)", "BC:lj_ffrecord.c", 894, "trend = trstart;"),
    (R, "(:879)", "BC:lj_ffrecord.c", 879, "trend = lj_opt_narrow_toint(J, trend);"),
    (R, "(:904)", "BC:lj_ffrecord.c", 904, "if (trstart == trend && start != 0) {  /* Common 1-char case. */"),
    (R, "(:905;", "BC:lj_ffrecord.c", 905, "tr = emitir(IRTI(IR_ADD), trstart, lj_ir_kint(J, -1));"),
    (R, "(:906)", "BC:lj_ffrecord.c", 906, "emitir(IRTGI(IR_ULT), tr, trlen);"),
    (R, "(:907)", "BC:lj_ffrecord.c", 907, "trptr = emitir(IRT(IR_STRREF, IRT_PGC), trstr, tr);"),
    (R, "(:909)", "BC:lj_ffrecord.c", 909, "J->base[0] = emitir(IRT(IR_SNEW, IRT_STR), trptr, lj_ir_kint(J, 1));"),
    (R, "(:911)", "BC:lj_ffrecord.c", 911, "J->base[0] = emitir(IRT(IR_XLOAD, IRT_U8), trptr, IRXLOAD_READONLY);"),
    (R, "lj_opt_narrow.c:440", "BC:lj_opt_narrow.c", 440, "tr = emitir(IRT(op - IR_ADDOV + IR_ADD,"),
    (R, "(:442)", "BC:lj_opt_narrow.c", 442, "narrow_bpc_set(J, ref, tref_ref(tr), mode);"),
    (R, "(:471)", "BC:lj_opt_narrow.c", 471, "return emitir(IRTI(IR_CONV), tr, IRCONV_INT_NUM|IRCONV_ANY);"),
    (R, "(:394)", "BC:lj_opt_narrow.c", 394, "sp[-1] = emitir(op+guardot, sp[-1], sp[0]);"),
    (R, "(:397)", "BC:lj_opt_narrow.c", 397, "narrow_bpc_set(J, narrow_ref(ref), narrow_ref(sp[-1]), mode);"),
    (R, "(:401, :419)", "BC:lj_opt_narrow.c", 401, "return nc->stack[0];"),
    (R, "(:401, :419)", "BC:lj_opt_narrow.c", 419, "return narrow_conv_emit(J, &nc);"),
    (R, "lj_opt_narrow.c:435", "BC:lj_opt_narrow.c", 435, "return TREF(bp->val, irt_t(IR(bp->val)->t));"),
    (R, "330); the pre-roll", "BC:lj_opt_loop.c", 330, "IRRef ref = tref_ref(emitir(ir->ot & ~IRT_ISPHI, op1, op2));"),
    (R, "branch, :334,", "BC:lj_opt_loop.c", 334, "if (ref < invar) {  /* Loop-carried dependency? */"),
    (R, "raising it at :352)", "BC:lj_opt_loop.c", 352, "lj_trace_err(J, LJ_TRERR_TYPEINS);"),
    # patch-bitop-fold.sh's "Anchored" sentence (the pin's pristine file).
    (P, "(lj_opt_fold.c:31 at 1ee778a4)", "PR", 31, '#include "lj_strfmt.h"'),
    (P, "(:376-377,", "PR", 376, "#if LJ_HASFFI"),
    (P, "(:376-377,", "PR", 377, "  case IR_BAND: k1 &= k2; break;"),
    (P, ":432-436,", "PR", 432, "#if LJ_HASFFI"),
    (P, ":444-445,", "PR", 444, "#if LJ_HASFFI"),
    (P, ":471-472,", "PR", 471, "#if LJ_HASFFI"),
    (P, ":492-493,", "PR", 492, "#if LJ_HASFFI"),
    (P, ":1746-1749,", "PR", 1746, "#if LJ_HASFFI"),
    (P, ":1794-1796);", "PR", 1794, "#if LJ_HASFFI"),
    (P, "(:1138-1142);", "PR", 1138, "LJFOLD(CONV CONV IRCONV_I64_NUM)  /* _INT or _U32 */"),
    (P, "(:1315-1317);", "PR", 1315, "/* Narrowing ignores PHIs and repeating it inside the loop is not useful. */"),
    (P, "(:1128-1136);", "PR", 1128, "LJFOLD(CONV CONV IRCONV_INT_NUM)  /* _INT */"),
    (P, "(:2612-2613;", "PR", 2612, "      if (IR(ref)->op12 == op12)"),
    (P, "(:2612-2613;", "PR", 2613, "return TREF(ref, irt_t(IR(ref)->t));  /* Common subexpression found. */"),
]

def lines(p):
    with open(p, "rb") as f:
        data = f.read().decode("latin-1")
    out = data.split("\n")
    return [l[:-1] if l.endswith("\r") else l for l in out]

cache = {}
def cited(key):
    if key not in cache:
        cache[key] = lines(PIN if key == "PR" else BCD + "/" + key.split(":", 1)[1])
    return cache[key]

src = {}
ok = bad = 0
for cf, tok, key, n, text in ROWS:
    if cf not in src:
        with open(REPO + "/" + cf, "rb") as f:
            src[cf] = f.read().decode("latin-1")
    L = cited(key)
    m = n + SHIFT
    held = 1 <= m <= len(L) and text in L[m - 1]
    named = tok in src[cf]
    good = held and named
    ok += good
    bad += not good
    print("%s %s cites %s:%d%s -- %s%s" % ("ok" if good else "BAD", cf, key, n,
          (" (as %d)" % m) if SHIFT else "", "holds" if held else "does not hold " + repr(text[:60]),
          "" if named else "; the token %r is not in the citing file" % tok))
print("cites: rows=%d ok=%d bad=%d shift=%d" % (len(ROWS), ok, bad, SHIFT))
if SHIFT == 0:
    sys.exit(0 if bad == 0 else 1)
sys.exit(0 if ok == 0 else 1)
