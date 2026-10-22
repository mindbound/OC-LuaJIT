# Commit facts 2: FIX-NUMCONV's follow-up (2026-10-22)

Read beside `claude-tmp/oclj/numconv/fix/commit-facts.md` (md5 `a26d02af`,
left unchanged). Where the two disagree, this file is the later record and
wins. Facts are marked [M] measured, [S] read in source, [I] inferred, with
the run, file or function behind each. Written by the follow-up's fixer
(`claude-tmp/oclj/numconv/fix2`), 2026-10-22, on the working tree at HEAD
`209aa95`. Nothing was committed; the user runs commit and push. The final
check (`numconv/fix/final-check.sh`, md5 `e0f1797a`) has NOT run end to end;
its full 36-arm sweep, timing smoke and release belong in the message only
after the main session runs them.

## What it supersedes in commit-facts.md

- "35 arms" / "35-arm" (its lines 8, 23, 140, 151, 230) -> 36 arms;
  negctl-bitop.sh is `0e453ecb` (not `e5838e14`), oclj_bitop_fold.c
  `28e403c8` (not `7dc61000`), the guide `3620c612`, the roadmap `53a8316a`.
- Its "decision (d) named three" (line 89) and "three arms" (line 165): a
  fourth arm, NUMCONVNOOP, was added by the main session on 2026-10-22 (D1).
- Its "Why it is sound", third bullet (lines 85-89): the mechanism is wider
  than the traced case (below), and "It has no arm" is no longer true.
- Its "Open, for the user" 1-3 (lines 217-224): 1 is closed by D1 (the user
  may still drop the arm), 2 by D2, 3 by D3; its "genrg2 costs 40-70 s an
  arm" is wrong as genrg2's added cost: about 35 s an arm (negctl's header,
  one run of each, 2026-10-20) [S].
- Its "After the final check" third item (P54, Next task, rows 213, 269:
  #1535 closed upstream) is done (D4).
- Its final-check md5s (`a21cb5bc`, `fc-citecheck.py` `9b0a6c25`): now
  `e0f1797a` and `a3878767`, with two new helper files (below).

## Suggested subject (one long sentence, the repo's style)

FIX-NUMCONV: an identity bit operation on a double (x | 0, x & -1, x ~ 0,
x << 0, x >> 0 and the like) loses a result guard that cannot fail:
simplify_conv_i64_num folds (i64)(num)y ==> y when y is an unguarded
CONV i64.num of a double, x64's cvttsd2si, whose value is always exactly a
double (patch-bitop-fold.sh hunk 7, a line of its own after the width rule;
oclj_isnumconv in oclj_bitop_fold.c, called from bitop_wgate.c), identity
rows 1.10 to 0.90 ns; with t_numconv.lua, ncir.lua and run-bitjit.sh's nc
part, negctl's NUMCONVOP1, NUMCONVW, NUMCONVOFF and NUMCONVNOOP (36 arms),
the JIT guide's 3.11, 11.5c and P60-P62, and upstream's fix of LuaJIT#1535
(a4c0645) and the pin-move plan recorded

## The arm: NUMCONVNOOP (D1)

- **What it is** [S]: `test/native/negctl-bitop.sh` :840-842,
  `arm NUMCONVNOOP oclj_bitop_fold.c 'gen'`, removing `ir->o == IR_CONV && `
  from `oclj_isnumconv`'s return line (oclj_bitop_fold.c :173, found there
  once as a whole line). Header: the arm row :135, "Not arms" :169-175,
  THE MARGINS :226-229, cost :238, memory safety :273-275. The 36th arm.
- **What it breaks** [S][M]: without the opcode test any unguarded int64
  instruction other than a CONV whose op2 reads `IRT_NUM` (14) in its low
  five bits passes for a converted double and loses its result guard [S:
  `oclj_isnumconv`, oclj_bitop_fold.c :170-175]. op2 may be a constant's ref
  (the code verifier's traced BOR, op2 0x7fee, in ncir's `x | 1` loop under
  `-O1`, `numconv/verify-code/noop-probe-1/`) or an instruction's ref: the
  arm verifier's IR scan of the generator's four seeds found BOR, BXOR,
  BAND, the shifts and ADD with op2 refs of both kinds keeping no result
  guard on the sabotage build, where on the shipped build many keep one
  (seed 1: 51 BORs with an instruction's op2 ref)
  [M: `numconv/verify-arm/irscan-1/`, `verify-arm/scripts/irscan.lua`]. The
  arm agent's and the docs' first wording ("a constant's ref") was too
  narrow; the fixer reworded it (below).
- **Its catcher is gen** [M]: three selected runs by the arm agent on a
  fresh Windows build (`numconv/arm/b1`, `lj_opt_fold.o` `f6d916e2`, only it
  differing from `build/native`'s, our 3 objects equal): canon PASS (101-103
  s), NUMCONVNOOP "PASS (caught by gen)", 4/4 seeds, 18-29, 18-32 and 19-31
  cases a seed, restore PASS, the arm 37 s, each work directory 194 MB
  (`numconv/arm/negctl-1` to `-3`; work directories
  `numconv/arm/b1/negctl-bitop/20261021T21*Z-*`, UTC stamps). A fourth by
  the arm verifier on its own fresh build: canon PASS, 17-27 a seed, restore
  PASS (`numconv/verify-arm/negctl-1/`). So gen 17-32 a seed over four runs,
  fewest 17, every seed in every run. The sabotage object is `e4fd19d9` in
  every run, the same as the code implementer's `sab-noop` and the code
  verifier's `sab-vnoop`, and the arm verifier's hand-written predicate
  without the test also gives `e4fd19d9` while a control dropping the
  `irt_isi64` test gives `13e15d33` [M: `numconv/verify-arm/sab-*`].
- **Not ncir, not t_numconv, not genrg2** [M]: on the sabotage build
  t_numconv shows 0 differences in all 15 sets and ncir differs only under
  `-O1` (2) and `-O-narrow` (3), by ref layout (`numconv/verify-code/
  sab-vnoop`, `numconv/verify-arm/floornc-sab-1.log`); listed on
  `nc:t_numconv` the arm is "FAIL (NOT CAUGHT by nc:t_numconv)", rc 1
  (`numconv/arm/ff-catch-1/`). genrg2 caught it 24-28 a seed in one run
  (`numconv/impl-code/sab-noop/r1/`) and is not listed: about 35 s an arm
  for a catch gen already makes.
- **Its anchor and sabotage** [M]: negctl's own `sabotage()` changes line
  173 alone, with the marker, 175 lines; a mutated anchor, a doubled anchor,
  a two-line new text and a new text without the marker are each refused,
  6 of 6 as wanted (`numconv/arm/ff-sab-1.txt`).
- **Memory safety** [S]: it reads y's IR type and op2, fields of the same
  ref in the IR array (per call fewer fields than the shipped predicate,
  though now the op2 of a non-CONV too, which the shipped `&&` never
  reaches), compares op2's bits without following them, and keeps the
  `irt_isi64` test, so y keeps its I64 type and no instruction changes
  type; the effect is a lost result guard: a wrong value, never a pointer.
- **What the measured runs executed** [M]: the arm agent's three ran
  `b7a31dd3`, the arm verifier's `d3e7e4d3`; each differs from the final
  `0e453ecb` in comment lines only (`numconv/arm/recon-1/`,
  `numconv/fix2/cdiff-1/`: 20 and 12 differing lines, 0 non-comment; the
  follow-up's start copy against the final shows the 3 code lines of the
  arm call, so the check can fail).

## The decisions, as recorded (who, when, where)

- **D1** (the main session, 2026-10-22). The user's decision of 2026-10-21,
  made on the main session's proposal, kept all four tests of
  `oclj_isnumconv` without arms on the main session's claim that no test
  could show one matters. That claim was false for the opcode test, the
  main session's mistake, not the user's; the main session added
  NUMCONVNOOP, caught by gen, correcting its own proposal's premise. The
  three type tests stay without arms, as decided. The user is told and may
  drop the arm. Recorded: guide 3.11 (preconditions), 11.7 items 8-10, open
  question 20 (closed); roadmap row 211 (5) [S].
- **D2** (the main session, 2026-10-22). NUMCONVOP1 and NUMCONVW keep only
  the nc part's catchers, as the idx and sel arms list only their own
  part's; their one-run gen, floor and genrg2 catches stay recorded in guide
  11.4. Open question 21 closed. Recorded: guide 11.4, open question 21;
  roadmap row 211 (5) (the fixer narrowed its "These three" to the two arms
  D2 covers) [S].
- **D3** (the main session, 2026-10-22). verify_content's two tightenings
  beyond the prototype (the call inside the rules' block, the code
  implementer's; each rule's call followed directly by its own return, the
  fixer's) are kept; nothing about them is open. Recorded: guide 8.2 step
  0; roadmap row 211 (5) [S].
- **D4** (fact). LuaJIT#1535, filed by the user on 2026-10-21, was fixed
  upstream by `a4c0645` ("Don't compile select() indexing beyond varargs.",
  2026-10-21, lj_record.c only: 3 insertions, 10 deletions) and closed as
  completed [S: the commit; the issue page per D4 and the upstream docs
  agent's WebFetch of 2026-10-22]. Verified by the main session [M]: stock
  `a4c0645` built GC64 and non-GC64 in WSL Ubuntu (`build-up3.sh`; `a4c.tar`
  `79c5100b`); the issue's reproducer gives the interpreter's output with
  the JIT on both; vsel.lua differs from `-joff` in 0 of 209 cases in all 21
  option sets; konst.lua records 3 NYI VARG aborts and 0 traces (printed by
  `check4.py`, not judged); `check4.py` PASS rc 0, and FAIL rc 1 on the
  earlier stock tip `95f931c`'s outputs (up-3's, copied as `ff-check4/`),
  re-run by the upstream docs agent with the same verdicts
  (`numconv/docs-up/check4-*.txt`). Scratch `claude-tmp/oclj/sel/upreport/`
  (`up-4/`, `check4.py`, `build-up3.sh`, `ff-check4/`); archive
  `bench/runs/2026-10-21-numconv/upstream/`. Our hunks 4 and 5 of
  patch-bitop-record.sh stay until the pin move. Recorded: guide P54, Next
  task, 2.6; roadmap rows 213 and 269.
- **D5** (the main session, under the user's delegation, 2026-10-21). When
  the pin moves it moves whole to upstream's v2.1 tip (`a4c0645` at the
  2026-10-21 fetch, 23 commits past `1ee778a4` [M: `rev-list --count`];
  re-fetched then), not by cherry-picks. That round adopts upstream's select
  change and drops hunks 4 and 5, retires SELGUARD, re-anchors or retires
  SELRECK, rewrites t_select's path-C coverage gates (`selC`, `kguard`), and
  adds the stitched and side-trace cases; the settled select decisions hold
  for the current pin. Side note confirmed [S: `rec_varg` in `a4c0645`'s
  tree, lj_record.c ~:2042-2063]: upstream aborts recording
  `select('#', ...)` when `nvararg` < 0. Also by reading [S][I: not run]:
  upstream's abort above `LUAI_MAXSTACK` (65500) keeps t_select's three
  k = 2^27 controls from compiling, so t_select's coverage gate on them
  (`kmaxctl` = `kctl`) would read PROVED NOTHING too. Recorded: guide Next
  task item (2), 8.2a step 4, 11.5b's "At the pin move"; roadmap row 270
  (new) and 213.
- **D6** (the main session, under the user's delegation, 2026-10-21). The
  move takes `0218af7` (empty statements anywhere; in our LUA52COMPAT build
  only `return 1;;` and `continue;` are new) and `c41d727` (the line-number
  directive; a first line `#` but not `#!` becomes a syntax error) unpatched
  [S: their diffs][M: the main session's probe, 23 cases, `syn/up-1/`,
  `syn/shipped-2/`; build/native equals stock `1ee778a4` on every case once
  CRs are stripped]. That round greps the census's OS trees and documents
  every accepted v3.0 backport in README's Lua dialect section; README is
  not changed now. The fixer widened the grep's wording to the lexer's rule
  ('#' at a line start, optional spaces or tabs, a digit: `# 100 "x.lua"`,
  the directive's own form, is missed by a grep for '#' directly followed
  by a digit) [S: `lex_linedir` in `c41d727`, `numconv/docs-up/c41d727.diff`]
  and named where the trees come from (`census-os.sh`'s kernel-root
  argument; so far axis-os, MineOS and the quick set). Recorded: guide Next
  task, 8.2a steps 5 and 7; roadmap row 270.

## The census of the pin move (the upstream docs agent, 2026-10-22) [M]

No build. On `a4c0645`'s tree (`b8e5f484`) eleven of the twelve patch
scripts apply; `patch-bitop-record.sh` refuses at hunk 5 ("occurs 0 times"),
the only one of the round-3 scripts' 28 hunks not found exactly once; on the
pin all twelve apply and the patched `lj_record.c` (`d490af9b`) and
`lj_opt_fold.c` (`3b11930f`) equal the build copies. Of negctl's 20 arms on
LuaJIT files, 18 keep their anchors on `a4c0645`; SELGUARD and SELRECK lose
theirs (`numconv/docs-up/census-a4c/verdicts.txt`, `census-pin/`,
`hunks-a4c.txt`, `hunks-pin.txt`, `negarms-2/arms.txt`; re-read by the
fixer). The 23 commits are classified in roadmap row 270 [S]; of the eight
in our build, `a4c0645`, `c41d727` and `0218af7` were run on stock builds,
and `2a8e017`'s and `849bbbe`'s old behaviour on the shipped build
(`tonumber("100000000", 16)` 4294967295; `math.floor()`/`ceil()` with no
argument raise in every try) [M: `numconv/docs-up/upfix-1/`].

## The follow-up's verifiers and the fixer's outcomes

Arm verifier (`numconv/verify-arm/`):
1. PROBLEM 1, the mechanism stated too narrowly ("a constant's ref"):
   FIXED in negctl's header :171-175 (reworded line for line), guide 3.10's
   row, 3.11 (the IR scan added), 8.4 item 8, open question 20, roadmap row
   211 (5).
2. MINOR 2, a fourth run (17-27, fewest 17): FIXED in guide 3.10, 11.4,
   11.7 item 10, open question 20 and roadmap row 211; negctl's header keeps
   "three runs, 18-32", which is accurate, since widening it would move
   every later line cite.
3. MINOR 3, "reads less than the shipped test": FIXED in negctl :274 and
   guide 11.7 item 8 (it also reads the op2 of a non-CONV).
4. MINOR 4, bare-brace cites: FIXED in `fc-citecheck.py` (a distinctive
   neighbour for :406, :511, :647, :843); on a tree holding the old negctl,
   :647 still passes alone and its neighbour :646 fails, 24 of 25 negctl
   cites bad [M: `numconv/fix2/ff-cites-1/E-out.txt`].

Docs verifier (`numconv/verify-docs2/`), all confirmed and FIXED:
the "row N = line N at 2dd5f05" definition (guide :7; a difflib map,
`fix2/rowmap-2dd5f05.txt`); the directive grep (guide :13, roadmap 270);
check4.py's scope and its fail-first's source `95f931c` (guide P54, roadmap
213); "These three" -> NUMCONVOP1 and NUMCONVW (roadmap 211); the Java
wording (roadmap 211); the narrow mechanism (guide :1304, :532, :2391); 35 s
not 40-70 s for genrg2 (guide :2016, :2392); t_select's coverage gate, not
t_select-kmax's (guide 11.5b); `849bbbe`'s probe (roadmap 270);
`census-os.sh`'s trees (roadmap 270); the archive's `upstream/` (roadmap
211, guide Appendix A); the 194 MB cite target (guide 11.7 Cost); the tense
of `dd3b243` (guide P54, roadmap 213). The process finding: the bare clone
is a `blob:none` partial clone [M: its config] and two promisor packs
arrived at 00:45:21 on 2026-10-22, the second the upstream docs agent's
`git log --stat` output was written (refs unchanged); `GIT_NO_LAZY_FETCH=1`
makes such a read fail instead of fetching [M: `git cat-file` on a copy
whose remote points nowhere, `numconv/fix2/lazy/run-1/`]; recorded in
roadmap row 270 and guide 8.2a step 4.

Also by the fixer: guide 11.4 records gen's shared-mode knock-on effect
(310 knock-on starts beside 480 first ones in the arm verifier's
classification, `verify-arm/classify-2/`), and 8.4 item 8 the lesson to
scan many traces before stating a mechanism.

## The final check, brought to the final tree

- `final-check.sh` `a21cb5bc` (FIX-NUMCONV's fixer) -> `6ab3b54c` (the arm
  agent: ARMS36 with NUMCONVNOOP, NEGCTL-36-arms requiring "PASS (caught by
  gen)" for it) -> `e0f1797a` (the fixer: two helpers added to HELPERS,
  comments, the DOCS-CITES text). 679 lines, 0 CR, 0 backslashes; `sh -n` 0
  in Git Bash, AlmaLinux 8 (bash in POSIX mode) and Ubuntu's dash [M:
  `fix2/shn-1/`, `fix2/fc-hyg-2/cmp/shn-gitbash.txt`].
- `fc-citecheck.py` `9b0a6c25` -> `0e16d2d0` (the arm agent: 19 negctl
  cites moved) -> `a3878767` (the fixer): the follow-up's own new line
  cites (oclj_bitop_fold.c :150; FIX-NUMCONV's negctl text ~:135, ~:283,
  ~:829 and their places now :136, :294, :843; `a4c0645`'s lj_record.c
  ~:2042-2063 and ~:2053-2063), read in two md5-pinned files beside the
  script, `fc-negctl-e5838e14.sh` (`e5838e14`, the follow-up's start copy)
  and `fc-a4c0645-lj_record.c` (`1f55838c`, the blob read with
  `GIT_NO_LAZY_FETCH=1` from a copy of the bare clone, equal to the census's
  export, `fix2/upblob-1/`), each new cite's number required in the doc's
  text, and the bare-brace neighbours. 116 line cites, 2 md5s, 4 doc
  snippets: 0 bad; every cite moved one line down 115 bad, up 115 bad [M:
  `fix2/cites-2/`]. Fail-firsts, 4 of 4 as wanted: the start docs (4 bad
  snippets), a changed pinned copy (its md5 alone), the current negctl in
  place of the old text (md5 and 4 cites), the unchanged inputs pass [M:
  `fix2/ff-cites-2/summary.txt`].
- Its hygiene part on the final tree (FC_PARTS=hygiene, FC_USE_BUILD
  `numconv/fix/b-fix`, FC_CENSUS=stat): PASS 23, FAIL 0, SKIP 2 (SHN-alma,
  SHN-ubuntu: no alma part), DOCS-CITES as above, 20 s [M:
  `numconv/fix2/fc-hyg-2/`; `fc-hyg-1/` the same on an earlier text].
- Its 36-arm negctl-list fail-first, with final-check `e0f1797a`'s own
  commands on synthetic logs and the final negctl: 11 of 11 as wanted [M:
  `numconv/fix2/ff-negctl36-1.txt`, the arm agent's `ff-negctl36.py`
  `2c52a042`].
- No pinned md5 or count changed: `FOLD_O_WIN` `f6d916e2`, `FOLD_C_MD5`
  `3b11930f`, CHANGED10 (ten files), the guide's t_numconv/ncir md5s.

## Files and md5s

Repo working tree against HEAD `209aa95` (follow-up start -> arm agent ->
upstream docs agent -> arm docs agent -> fixer):
- `docs/jit-guide.md` `92f2ce4b` -> - -> `1be91848` -> `9db4a9a1` ->
  `3620c612` (2392 lines, CR 0, TAB 0, 20 backslashes)
- `docs/roadmap.md` `ee3d21b5` -> - -> `95a01067` -> `54b328ef` ->
  `53a8316a` (312 lines, CR 0, TAB 0, 4 backslashes)
- `test/native/negctl-bitop.sh` `e5838e14` -> `d3e7e4d3` -> - -> - ->
  `0e453ecb` (953 lines, CR 0, 118 backslashes, comment lines only since
  `d3e7e4d3`)
- `native/luajit/oclj_bitop_fold.c` `7dc61000` -> `28e403c8` (line 150, a
  comment; `lj_opt_fold.o` stays `f6d916e2`) [M: `numconv/arm/b1`,
  `numconv/verify-arm/b1`]
- Unchanged by the follow-up: `native/build-native.sh` `ae218485`,
  `native/luajit/patch-bitop-fold.sh` `08c242a5`,
  `test/native/bitop/t_idx2.lua` `f6b9115c`, `test/native/run-bitjit.sh`
  `27b8262d`, `test/native/bitop/ncir.lua` `baaa4490`,
  `test/native/bitop/t_numconv.lua` `de0d14e9`, `README.md` `98f6042d`,
  `CLAUDE.md` `45b861fb`.

Final check (scratch `claude-tmp/oclj/numconv/fix/`): `final-check.sh`
`e0f1797a`, `fc-citecheck.py` `a3878767`, `fc-negctl-e5838e14.sh`
`e5838e14`, `fc-a4c0645-lj_record.c` `1f55838c`; unchanged:
`fc-summarize.py` `27487bcc`, `fc-anchorcheck.py` `d02e23e4`,
`fc-tablecheck.py` `8bf1f616`, `fc-irident.py` `ea1b3ab3`, `fc-nestn7.py`
`75364ea4`, `fc-ir_ident.lua` `e01eb3af`.

## Java and timing

No java.exe or javaw.exe was running at any of the fixer's checks; the
fixer built nothing and timed nothing (the hygiene part's own seconds are
its log's). The arm agent saw one java.exe running when its catcher
fail-first started, gone after it, a correctness run [M: its report].

## Open, for the user and the main session

1. D1: NUMCONVNOOP may be dropped; dropping it reverts negctl :135,
   :169-175, :226-229, :238, :273-275 and :840-842, final-check's ARMS36 and
   NEGCTL-36-arms, and the guide and roadmap passages named under D1.
2. D6's grep wording now includes optional spaces or tabs after the '#';
   the main session may restore D6's literal wording.
3. The archive's `upstream/`: `ff-check4/` (check4's fail-first inputs,
   text) is cited beside it by the docs but is not on the brief's list.
4. The full 36-arm sweep has not run in one call (about 16 minutes [I]); the
   final check runs it.
