#!/usr/bin/env python3
# fc-citecheck.py <repo> <pcdir> [shift]: FIX-NUMCONV's final check (scratch
# claude-tmp/oclj/numconv/fix/final-check.sh): every line cite that the round
# writes or moves in docs/jit-guide.md and docs/roadmap.md, checked by
# content: the cited line must contain the given text ("}" alone means the
# whole line is "}").  The docs agent's citecheck.py (numconv/docs/scripts/,
# 94 checks), with the cites the fixer's changes moved (run-bitjit.sh's nc
# part grew by two lines at :729-730; patch-bitop-fold.sh's verify_content
# comment and body by four each) and the fixer's new cites added; the
# negctl-bitop.sh cites moved by NUMCONVNOOP's lines (the arm agent,
# numconv/arm/map-1/negctl.txt, 2026-10-22: +11 from :271, +14 from
# :829).  The follow-up's fixer (numconv/fix2, 2026-10-22) added the
# follow-up's new line cites: oclj_bitop_fold.c :150, the old negctl
# text's ~:135, ~:283 and ~:829 (guide's Citations; read in
# fc-negctl-e5838e14.sh beside this script, FIX-NUMCONV's negctl-bitop.sh,
# numconv/followup-start/), and upstream a4c0645's lj_record.c ~:2042-2063
# (P54) and ~:2053-2063 (roadmap row 270; read in fc-a4c0645-lj_record.c
# beside this script, the blob read with GIT_NO_LAZY_FETCH=1 from a copy
# of the scratch bare clone, equal to the census's git archive export); the
# moved positions of those old lines in the current negctl (:136, :294,
# :843); a distinctive neighbour for each bare-brace negctl cite (the arm
# verifier's MINOR 4); and, for these new cites only, that the doc carries
# the cite's number (DOCS below).  Both pinned files are checked by md5.
# Files: the
# repo's working tree, the build copy patched by the working tree's
# patch-bitop-fold.sh (<pcdir>/patched-lj_opt_fold.c, md5 3b11930f) and the
# pin's pristine blobs (<pcdir>/pristine-*, git cat-file).  With a shift (1
# or -1) every cite is moved by that many lines, and the check must then
# fail.  Exit 0 if every cite holds.  No backslashes in this file.
import sys, os, hashlib

REPO = sys.argv[1]
PC = sys.argv[2]
SHIFT = int(sys.argv[3]) if len(sys.argv) > 3 else 0

BN = REPO + "/native/build-native.sh"
NC = REPO + "/test/native/negctl-bitop.sh"
RB = REPO + "/test/native/run-bitjit.sh"
PF = REPO + "/native/luajit/patch-bitop-fold.sh"
OF = REPO + "/native/luajit/oclj_bitop_fold.c"
BC = PC + "/patched-lj_opt_fold.c"
P = lambda f: PC + "/pristine-" + f
HERE = os.path.dirname(os.path.abspath(__file__))
OLDNC = HERE + "/fc-negctl-e5838e14.sh"
UP = HERE + "/fc-a4c0645-lj_record.c"
GUIDE = REPO + "/docs/jit-guide.md"
ROAD = REPO + "/docs/roadmap.md"
PINNED = [
    (OLDNC, "e5838e142c23605a918551ac3143ad64"),
    (UP, "1f55838c162c3e1aec7b0c2c58aafc52"),
]
# The doc must carry each new cite's number, as written.
DOCS = [
    (GUIDE, "comment line of `oclj_bitop_fold.c` (:150,"),
    (GUIDE, "the header's lines from ~:135 on move by 1 to 11, the code from `set -u` (~:283) by 11, and every line from `armlist`'s closing brace (~:829) by 14"),
    (GUIDE, "lj_record.c ~:2042-2063 of `a4c0645`'s tree"),
    (ROAD, "lj_record.c ~:2053-2063"),
]

CITES = [
    # build-native.sh (guide 7.6, 7.7; roadmap row 211 (5))
    (BN, 1681, "LJEXE=$LJ/luajit.exe"),
    (BN, 2063, "jdline other than 1"),
    (BN, 2065, "# -----"),
    (BN, 2065, " 1b"),
    (BN, 2161, "esac"),
    (BN, 2635, "# COLLECT ADDITIVE ARTIFACTS FOR PACKAGING."),
    (BN, 2661, "fi"),
    (BN, 2526, "# BEGIN ELF IMPORT GATE"),
    (BN, 2627, "# END ELF IMPORT GATE"),
    (BN, 1668, "oclj_isnumconv(J, 0) +"),
    # negctl-bitop.sh (guide 7.6, 8.2, 11.7, 12.10)
    (NC, 859, "WORK=$OCLJ_BUILD/negctl-bitop/"),
    (NC, 321, "SRCTREE=$OCLJ_BUILD/luajit-$PLATFORM"),
    (NC, 342, "lj52shim.o"),
    (NC, 874, "for p in $PATCHED; do"),
    (NC, 881, "done"),
    (NC, 659, "# arm <name> <file> <catchers>"),
    (NC, 731, "armlist() {"),
    (NC, 843, "}"),
    (NC, 680, "SABOTAGE $name:"),
    (NC, 467, "run_bitop() {"),
    (NC, 647, "}"),
    (NC, 732, "arm canon - 'bitop fuzz gen genrg2 floor fix1 idx sel nc security gate stage4'"),
    (NC, 482, "run_genrg2() {"),
    (NC, 335, "# serializer's eris_lj.c"),
    (NC, 338, "ALLFILES="),
    (NC, 393, "objs_of() {"),
    (NC, 406, "}"),
    (NC, 491, "run_gate() {"),
    (NC, 511, "}"),
    # the bare-brace cites' neighbours (numconv/fix2)
    (NC, 404, '    *) echo "" ;;'),
    (NC, 510, 'exit 0 ) > "$1/stage4.log" 2>&1'),
    (NC, 646, 'echo "${s#; }"'),
    (NC, 842, "SABOTAGE NUMCONVNOOP:"),
    # the follow-up's line map (guide's Citations): FIX-NUMCONV's text and now
    (OLDNC, 135, "#   PHIIDX and NOLOOPFOLD change no value"),
    (NC, 136, "#   PHIIDX and NOLOOPFOLD change no value"),
    (OLDNC, 283, "set -u"),
    (NC, 294, "set -u"),
    (OLDNC, 828, "SABOTAGE NUMCONVOFF:"),
    (OLDNC, 829, "}"),
    # upstream a4c0645's rec_varg (guide P54 ~:2042-2063; roadmap row 270 ~:2053-2063)
    (UP, 2042, "ptrdiff_t idx = lj_ffrecord_select_mode(J, tridx, &J->L->base[dst-1]);"),
    (UP, 2043, "if (idx < 0 || idx > LUAI_MAXSTACK) goto nyivarg;"),
    (UP, 2053, "} else if (idx <= nvararg) {  /* Compute size. */"),
    (UP, 2062, "} else {  /* Indexing beyond nvararg. */"),
    (UP, 2063, "goto nyivarg;  /* Uncommon and pointless to compile it. */"),
    # run-bitjit.sh (guide 7.4, 11.1, 11.3, 11.4, 11.5b, 11.5c, 11.7)
    (RB, 220, "LJEXE=$OCLJ_BUILD/luajit-$PLATFORM"),
    (RB, 323, '"$nl" -ne "$OCLJ_BITJIT_CASES"'),
    (RB, 380, '"$nl" -ne 400'),
    (RB, 498, 'IDXOPTS="jon'),
    (RB, 582, 'SELOPTS="$IDXOPTS'),
    (RB, 656, 'NCIROPTS="jon O1:-O1'),
    (RB, 301, 'GENOPTS="jon'),
    (RB, 577, "# -------"),
    (RB, 577, " 5"),
    (RB, 649, "fi"),
    (RB, 651, "# -------"),
    (RB, 651, " 6"),
    (RB, 745, "fi"),
    (RB, 729, "elif ! grep -q '^ncir: [0-9]* of [0-9]* cases compiled'"),
    (RB, 730, 'inothing="$inothing $n: no summary line'),
    (RB, 198, "OCLJ_BITJIT_PARTS:=gen floor fix1 idx sel nc}"),
    (RB, 227, "case $p in gen|floor|fix1|idx|sel|nc)"),
    (RB, 223, "for f in gen.lua"),
    (RB, 259, 'md5sum "$LJEXE"'),
    (RB, 748, '"gen floor fix1 idx sel nc"'),
    (RB, 300, "# The JIT option sets"),
    (RB, 303, 'JIT2OPTS="jon'),
    # patch-bitop-fold.sh (guide 3.11, 8.2)
    (PF, 462, "verify_content() {"),
    (PF, 489, "}"),
    (PF, 477, "countsub 'oclj_isnumconv('"),
    (PF, 484, "  fi"),
    (PF, 485, "RL='      return fleft->op1;'"),
    (PF, 488, "  fi"),
    (PF, 447, "# FIX-NUMCONV's predicate is named on one line"),
    (PF, 461, "# this check fails alone."),
    (PF, 239, "/* FIX-NUMCONV: y is an unguarded CONV i64.num"),
    (PF, 245, "return fleft->op1;"),
    # oclj_bitop_fold.c (guide 3.9, 3.11; roadmap row 211 (5))
    (OF, 116, "    return 64;"),
    (OF, 115, "  default:"),
    (OF, 120, "/*"),
    (OF, 121, "** FIX-NUMCONV (roadmap row 211 (5))."),
    (OF, 169, "*/"),
    (OF, 150, "(2026-10-21; the arm NUMCONVNOOP)."),
    (OF, 170, "static int oclj_isnumconv(jit_State *J, IRRef ref)"),
    (OF, 175, "}"),
    # the build copy patched by the working tree's script (guide 3.10, 3.11, 8.8)
    (BC, 1169, "LJFOLD(CONV CONV IRCONV_I64_NUM)"),
    (BC, 1196, "if (oclj_isnumconv(J, fleft->op1))"),
    (BC, 1199, "  PHIBARRIER(fleft);"),
    (BC, 1140, '#include "oclj_bitop_fold.c"'),
    (BC, 1167, "}"),
    (BC, 1189, "if (oclj_bitwidth(J, fleft->op1, 0) <= 54)"),
    (BC, 1190, "return fleft->op1;"),
    # pristine (guide 3.11, 11.7; roadmap Parked row)
    (P("lj_asm_x86.h"), 908, "x86Op op = st == IRT_NUM ? XO_CVTTSD2SI"),
    (P("lj_asm_x86.h"), 929, "emit_mrm(as, op,"),
    (P("lj_asm_x86.h"), 931, "asm_fuseload(as, lref, RSET_FPR));"),
    (P("lj_asm_x86.h"), 900, "FP to integer conversion"),
    (P("lj_asm_x86.h"), 933, "    }"),
    (P("lj_asm_x86.h"), 911, "if (irt_isu64(ir->t)) {"),
    (P("lj_asm_x86.h"), 912, "add -2^64 and convert again"),
    (P("lj_asm_x86.h"), 924, "ra_left(as, tmp, lref);"),
    (P("lj_asm_x86.h"), 901, "if (irt_isguard(ir->t)) {"),
    (P("lj_asm_x86.h"), 905, "asm_tointg(as, ir,"),
    (P("lj_opt_fold.c"), 901, "LJFOLD(CONV KNUM IRCONV_I64_NUM)"),
    (P("lj_opt_fold.c"), 904, "lj_num2i64(knumleft)"),
    (P("lj_opt_fold.c"), 905, "}"),
    (P("lj_obj.h"), 1057, "#define lj_num2i64(x)"),
    (P("vm_x64.dasc"), 2684, "->vm_num2i64:"),
    (P("vm_x64.dasc"), 2685, "cvttsd2si rax, xmm0"),
    (P("vm_x64.dasc"), 2686, "|  ret"),
    (P("lj_ffrecord.c"), 1105, "IR_CONV, IRT_U64"),
    (P("lj_ffrecord.c"), 1104, "#if LJ_HASFFI"),
    (P("lj_ir.h"), 57, "_(BNOT,"),
    (P("lj_ir.h"), 64, "_(BSAR,"),
    (P("lj_asm_arm64.h"), 658, "A64Ins ai = irt_is64(ir->t) ?"),
    (P("lj_asm_arm64.h"), 659, "A64I_FCVT_S64_F64"),
    (P("vm_arm64.dasc"), 2197, "->vm_num2i64:"),
    (P("vm_arm64.dasc"), 2198, "fcvtzs CRET1, FARG1"),
]

cache = {}
bad = 0
for path, want in PINNED:
    got = hashlib.md5(open(path, "rb").read()).hexdigest() if os.path.exists(path) else "missing"
    ok = got == want
    if not ok:
        bad += 1
    print("%s md5 %s %s" % ("OK " if ok else "BAD", path.split("/")[-1], got))
for path, snip in DOCS:
    ok = snip in open(path, "rb").read().decode("utf-8")
    if not ok:
        bad += 1
    print("%s doc %s carries %s" % ("OK " if ok else "BAD", path.split("/")[-1], snip))
for path, line, text in CITES:
    if path not in cache:
        cache[path] = open(path, "rb").read().decode("utf-8").replace(chr(13) + chr(10), chr(10)).split(chr(10))
    lines = cache[path]
    n = line + SHIFT
    got = lines[n - 1] if 1 <= n <= len(lines) else ""
    ok = (got == text) if text == "}" else (text in got)
    if not ok:
        bad += 1
    print("%s %s:%d %s" % ("OK " if ok else "BAD", path.split("/")[-1], n, text))
print("cites=%d md5s=%d doc-snippets=%d bad=%d shift=%d" % (len(CITES), len(PINNED), len(DOCS), bad, SHIFT))
sys.exit(1 if bad else 0)
