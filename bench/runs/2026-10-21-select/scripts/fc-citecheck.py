#!/usr/bin/env python3
# citecheck.py (the select fixer's copy of sel/docs/scripts/citecheck.py) <repo> <patched lj_record.c> [shift]: every line cite the select
# round's guide update writes into run-bitjit.sh, negctl-bitop.sh,
# patch-bitop-record.sh and the patched build copy of lj_record.c, checked by
# content: the cited line must contain the given text.  With a shift (e.g. 1),
# every cite is moved by that many lines, and the check must then fail
# (prove-a-check-can-fail).  Exit 0 if every cite holds, 1 otherwise.
import sys

REPO = sys.argv[1]
PATCHED = sys.argv[2]
SHIFT = int(sys.argv[3]) if len(sys.argv) > 3 else 0

PC = PATCHED.rsplit("/", 1)[0]
PREC = PC + "/pristine-lj_record.c"
PNAR = PC + "/pristine-lj_opt_narrow.c"
PTRA = PC + "/pristine-lj_trace.c"
PFFR = PC + "/pristine-lj_ffrecord.c"
RB = REPO + "/test/native/run-bitjit.sh"
NC = REPO + "/test/native/negctl-bitop.sh"
PR = REPO + "/native/luajit/patch-bitop-record.sh"

CITES = [
    (RB, 188, "LJEXE=$OCLJ_BUILD/luajit-$PLATFORM"),
    (RB, 291, '"$nl" -ne "$OCLJ_BITJIT_CASES"'),
    (RB, 348, '"$nl" -ne 400'),
    (RB, 466, 'IDXOPTS="jon'),
    (RB, 269, 'GENOPTS="jon'),
    (RB, 191, "for f in gen.lua"),
    (RB, 227, 'md5sum "$LJEXE"'),
    (RB, 268, "# The JIT option sets"),
    (RB, 271, 'JIT2OPTS="jon'),
    (RB, 550, 'SELOPTS="$IDXOPTS'),
    (RB, 545, "# -----"),
    (RB, 547, "== 5. select(k, ...)"),
    (RB, 617, "fi"),
    (RB, 620, '"gen floor fix1 idx sel"'),
    (RB, 87, "5. SELECT (sel;"),
    (NC, 782, "WORK=$OCLJ_BUILD/negctl-bitop/"),
    (NC, 261, "SRCTREE=$OCLJ_BUILD/luajit-$PLATFORM"),
    (NC, 282, "lj52shim.o"),
    (NC, 797, "for p in $PATCHED; do"),
    (NC, 804, "done"),
    (NC, 594, "# arm <name> <file> <catchers>"),
    (NC, 595, "arm() {"),
    (NC, 666, "armlist() {"),
    (NC, 766, "}"),
    (NC, 615, "SABOTAGE $name:"),
    (NC, 407, "run_bitop() {"),
    (NC, 543, "info() {"),
    (NC, 582, "}"),
    (NC, 667, "arm canon - 'bitop fuzz gen genrg2 floor fix1 idx sel"),
    (NC, 422, "run_genrg2() {"),
    (NC, 275, "# serializer's eris_lj.c"),
    (NC, 278, "ALLFILES="),
    (NC, 333, "objs_of() {"),
    (NC, 346, "}"),
    (NC, 431, "run_gate() {"),
    (NC, 451, "}"),
    (NC, 453, "rcof() {"),
    (NC, 461, "runcatchers() {"),
    (NC, 510, "check() {"),
    (NC, 760, "arm SELGUARD lj_record.c 'sel:t_select'"),
    (NC, 763, "arm SELRECK lj_record.c 'sel:kmax'"),
    (NC, 178, "THE SELECT FIX'S ARMS"),
    (NC, 218, "SELGUARD removes the guard, SELRECK the record-time bound"),
    (PR, 34, "# THE SELECT FIX, hunks 4 and 5"),
    (PR, 169, "# 4. The bound on select's index"),
    (PR, 189, "# 5. select's index"),
    (PR, 246, "EOF"),
    (PR, 351, "verify_content() {"),
    (PR, 365, "# The select fix (hunks 4 and 5)."),
    (PR, 383, "out of order (OCLJ_SELECT_KMAX"),
    (PR, 384, "  fi"),
    (PR, 385, "}"),
    (PATCHED, 2000, "#define OCLJ_SELECT_KMAX"),
    (PATCHED, 2003, "static void rec_varg("),
    (PATCHED, 2052, "select_detect(J)"),
    (PATCHED, 2057, "if (idx > OCLJ_SELECT_KMAX) goto nyivarg;"),
    (PATCHED, 2065, "frofs+8*(int32_t)idx"),
    (PATCHED, 2074, "rec_idx_abc(J, tr, tridx"),
    (PATCHED, 2080, "emitir(IRTGI(IR_ULT), tmp2, lj_ir_kint(J, OCLJ_SELECT_KMAX));"),
    (PATCHED, 2081, "tmp2 = emitir(IRTI(IR_BSHL), tridx"),
    (PATCHED, 2086, "emitir(IRTGI(IR_LT), fr, tmp);"),
    (PATCHED, 2110, "static TRef rec_tnew("),
    (RB, 166, "OCLJ_BITJIT_PARTS:=gen floor fix1 idx sel"),
    (RB, 195, "case $p in gen|floor|fix1|idx|sel)"),
    # Pristine cites (the pin's blobs, git cat-file), which the patch does not move.
    (PREC, 1989, "static void rec_varg("),
    (PREC, 2089, "}"),
    (PREC, 1998, "if (nvararg < 0) nvararg = 0;"),
    (PREC, 2038, "select_detect(J)"),
    (PREC, 2046, "IRCONV_INT_NUM|IRCONV_INDEX"),
    (PREC, 2050, "frofs+8*(int32_t)idx"),
    (PREC, 2054, "if (numparams)"),
    (PREC, 2055, "emitir(IRTGI(IR_GE), tmp, lj_ir_kint(J, 0));"),
    (PREC, 2061, "} else {"),
    (PREC, 2064, "IR_BSHL), tridx"),
    (PREC, 2069, "emitir(IRTGI(IR_LT), fr, tmp);"),
    (PREC, 1458, "lj_opt_narrow_index(J, key)"),
    (PNAR, 293, "checki16"),
    (PNAR, 386, "Omit some overflow checks for array indexing"),
    (PNAR, 392, "mode += IRCONV_CHECK-IRCONV_INDEX;"),
    (PNAR, 457, "Omit some overflow checks for array indexing"),
    (PNAR, 461, "return emitir(IRTI(ir->o - IR_ADDOV + IR_ADD)"),
    (PNAR, 162, "always accompanied by an array bounds-check. The outermost overflow"),
    (PNAR, 168, "an int32_t into the range of valid array indexes [0..2^27+1)"),
    (PTRA, 413, "hotcount_set(J2GG(J), pc+1, val);"),
    (PFFR, 504, "numberVint(&rd->argv[1])+1"),
    (PFFR, 508, "emitir(IRTI(IR_ADD), ix.key, lj_ir_kint(J, 1))"),
    # The select round's fixer (sel/fix): 11.5b's recff_nyi cite.
    (PFFR, 162, "static void LJ_FASTCALL recff_nyi(jit_State *J, RecordFFData *rd)"),
    (PFFR, 168, "if (J->framedepth && frame_islua(J->L->base-1)) {"),
    (PFFR, 189, "}"),
]

cache = {}
bad = 0
for path, line, text in CITES:
    if path not in cache:
        cache[path] = open(path, "rb").read().decode("utf-8").split("\n")
    lines = cache[path]
    n = line + SHIFT
    got = lines[n - 1] if 1 <= n <= len(lines) else ""
    # "}" alone means a closing brace at column 0, the whole line.
    ok = (got == text) if text == "}" else (text in got)
    if not ok:
        bad += 1
    print("%s %s:%d %s" % ("OK " if ok else "BAD", path.split("/")[-1], n, text))
print("cites=%d bad=%d shift=%d" % (len(CITES), bad, SHIFT))
sys.exit(1 if bad else 0)
