# Commit facts: FIX-NUMCONV (roadmap row 211 (5), JIT guide 3.11)

Facts a commit message needs, each marked [M] measured, [S] read in source,
[I] inferred, with the run, file or function behind it. Written by the fixer
(`claude-tmp/oclj/numconv/fix`), 2026-10-22, on the working tree at HEAD
`209aa95`. Nothing was committed; the user runs commit and push. The final
check (`numconv/fix/final-check.sh`, md5 `a21cb5bc`) has NOT run end to end:
its result, the full 35-arm negctl sweep, the timing smoke and the release
natives belong in the message only after the main session runs them
(`bench/runs/2026-10-21-numconv/logs/final-main/`, `logs/release/`). Every
part of it ran once in the fixer's smoke runs (below), the negctl part with
the three new arms only.

## Suggested subject (the repo's style: one long sentence)

FIX-NUMCONV: an identity bit operation on a double (x | 0, x & -1, x ~ 0,
x << 0, x >> 0 and the like) loses a result guard that cannot fail:
simplify_conv_i64_num folds (i64)(num)y ==> y when y is an unguarded
CONV i64.num of a double, x64's cvttsd2si, whose value is always exactly a
double (patch-bitop-fold.sh hunk 7, a line of its own after the width rule;
oclj_isnumconv in oclj_bitop_fold.c, called from bitop_wgate.c), identity
rows 1.10 to 0.90 ns; with t_numconv.lua, ncir.lua and run-bitjit.sh's nc
part, negctl's NUMCONVOP1, NUMCONVW and NUMCONVOFF (35 arms), and the JIT
guide's 3.11, 11.5c and P60-P62

## What ships

- **The rule** [S]: `native/luajit/patch-bitop-fold.sh` hunk 7, in
  `simplify_conv_i64_num`, inside fix1's block, after the width rule and
  before `PHIBARRIER`, on a line of its own (the user's decision (a)):
  `if (oclj_isnumconv(J, fleft->op1)) return fleft->op1;` with a five-line
  comment (build copy `lj_opt_fold.c` :1196-1197). NADD 63 -> 70, NDEL 8;
  on the pin's pristine blob (md5 `15c7420c`) the script reports "70 lines
  added, 8 removed, of 2715", its output is the build copy (`3b11930f`) and
  it is idempotent [M: the final check's PATCH-PRISTINE, -IDEMPOTENT,
  -IS-BUILD-COPY in `numconv/fix/fc-smoke-A/`, `fc-smoke-H/`].
- **The predicate** [S]: `static int oclj_isnumconv(jit_State *J, IRRef ref)`
  in `native/luajit/oclj_bitop_fold.c` (:170-175; decision (b): not
  `LJ_AINLINE`), true when y is an `IR_CONV`, typed `i64`, with no guard,
  from `IRT_NUM`; its argument in the comment above it (:120-169). The three
  type tests are documented preconditions with no arm (decision (c)).
- **The warning gate** [S][M]: `native/build-native.sh`'s `bitop_wgate.c`
  calls `oclj_isnumconv(J, 0)` (:1668; 5 lines added, 2 removed, all in that
  block), so `-Wall -Wextra` compiles it; a planted warning inside it and the
  call removed each give `BUILD FAIL` (the implementer's `impl-code/logs/
  build-wg-a.log`, `-b.log`; the code verifier's `verify-code/logs/
  build-wg-a.log`, `wg-b`).
- **verify_content** [S][M]: requires `oclj_isnumconv(` on exactly one line,
  the call on `fleft->op1`, the call inside the rules' block below the width
  rule's call (the implementer's tightening, FF3b/FF9), and, added by the
  fixer, each of the two calls followed directly by its own
  `      return fleft->op1;` (patch-bitop-fold.sh :485-488), so FIX-NUMCONV's
  call cannot sit nested in the width rule's unbraced `if`, which every other
  check passed (the code verifier's m11). The script refuses such an n7,
  rc 1, where the script before the check took it, rc 0
  (`numconv/fix/ff-nest/`); evaluated on m11 the new check fails alone
  (`fix/vc-check-1.txt`).
- **Only `lj_opt_fold.o` changes** [M]: Windows (additive) 77 LuaJIT objects,
  only `lj_opt_fold.o` differs from `build/native`'s (`f6d916e2` against
  `1d018acc`), our 3 objects equal (`numconv/fix/fc-smoke-A/cmp/
  win-vs-buildnative.txt`, also `fix/b1`, the implementer's `wb2`, the
  integrator's `wb1`, the code verifier's `vb1`). AlmaLinux 8 (gcc 8.5.0,
  `OCLJ_GLIBC_MAX=2.28`) against `build/native`'s Linux tree (209aa95's
  release built in AlmaLinux 8): only `lj_opt_fold.o` (`57970a51` against
  `33a2cc50`), GLIBC_2.17 at most (`fc-smoke-D/alma/`). The fixer's edits to
  `oclj_bitop_fold.c` are comment-only and left `f6d916e2` unchanged [M:
  `fix/b1`, built after them].

## Why it is sound (brief)

- x64's `asm_conv` compiles an unguarded `CONV i64.num` to one
  `cvttsd2si r64` (lj_asm_x86.h ~:908, ~:929-931 at the pin), whose value,
  the double's integral part in [-2^63, 2^63) or else -2^63, is always
  exactly a double, so the result guard's round trip gives y back in every
  rounding mode [S]; a probe of those instructions read 0 mismatches in
  21,179,656 doubles under eight MXCSR settings, its controls failing [M:
  `numconv/argue/runs/cvt-rt-1/`]. Every iteration and across a PHI: an
  induction over the loop copy that rests on the guards emitted before y
  [S][I: `argue/argument.md` section 4.6]. x64 only (arm64's `fcvtzs`
  saturates) [S][I].
- Exactness, not range: it must never enter `oclj_bitwidth`, where it would
  compose (x | 1 for x = 2^53 would lose its guard and return 2^53 where the
  interpreter raises; PUC 5.3.6 itself returns 2^53 + 1) [S][M: the
  NUMCONVW arm; `fix/runs/edge-1.txt` for the interpreters].
- The opcode test is value-visible when dropped (gen, t_rec and genrg2
  differed from `-joff`, `impl-code/sab-noop/r1`) [M]; why: a bit operator's
  constant op2 ref 0x7fee reads `IRT_NUM` in its low five bits (ncir's
  `x | 1` loop under `-O1`) [M: `verify-code/noop-probe-1/`]. It has no arm
  (decision (d) named three); open question 20.

## The gain [M]

- Step 1's timing chain on the prototype's build (`lj_opt_fold.o`
  `bbfab438`, the same rule in an `LJ_AINLINE` helper; the shipped object
  differs in `simplify_conv_i64_num`'s compiled code only): 20 rounds
  alternating with `build/native`, ident's ten identity rows 1.10 to 0.90 ns
  (0.82), bench_numconv arith 0.80, key 0.88, bits 0.93, floor 0.97, every
  control 1.00, every result equal (`numconv/main/timing-1/summary.txt`).
- Smoke readings on the shipped object (`f6d916e2`), no JVM running: the
  fixer's final-check timing part, 4 rounds (`fix/fc-smoke-B/timing/
  summary.txt`, CPU load 1% before and 7% after): the ten identity rows'
  median ratios 0.75-0.86, median 0.818; arith 0.800, key 0.885, bits 0.944,
  floor 0.986; the ref control 0.938 at 0.35-0.375 ns, within a step of the
  0.05 ns clock unit; every result equal. The code verifier's, 6 rounds of
  ident.lua: ratio medians 0.78-0.87 (`verify-code/smoke-ident-1/`). Smoke
  only; the final check's timing part is the round's reading.
- IR [M]: exactly the identity result guards are gone, 10 in ident.lua and
  8 in bench_numconv.lua, every other instruction and snapshot unchanged
  (`impl-code/jdump-ident-2/`, `jdump-numconv-2/`); step 1's ir_ident.lua
  reads the identities 0 guards and the cancellations 1 on the new build, 1
  and 2 on `build/native` (the final check's IRIDENT checks,
  `fix/fc-smoke-B/runs/irident/`).

## Tests and arms

- `test/native/bitop/t_numconv.lua` (new, 244 lines, md5 `de0d14e9`, no
  backslash) [S]: 25 forms (identities, cancellations, controls) in 3 modes,
  75 cases, each loop recorded on small values and then met by BIG's 22
  values (at and past 2^53, the edges 2^52 + 1, 2^53 - 1 and -0.0, and
  operands that must raise), under 15 option sets against `-joff`, with a
  PUC twin of every case.
- `test/native/bitop/ncir.lua` (new, 273 lines, md5 `baaa4490`) [S]: counts
  the result guards the rule removes, keyed on their operands, under the 13
  sets that fold; every loop must compile (JFORL, no TYPEINS); swap1 reads
  the rule on a PHI-marked `fleft`.
- `test/native/run-bitjit.sh` part 6, `nc`, in the default parts (md5
  `27b8262d`) [S]; since the fixer, every JIT run of ncir must print its
  summary line, else PROVED NOTHING (:729-730): before, a copy whose ncir.lua
  began with `jit.off()` PASSed, rc 0 (the code verifier's `tn-ff-c`; the
  fixer's `fix/confirm/pre-jitoff.log`); now it and a copy without the
  summary print read PROVED NOTHING, rc 2, the unmutated copy PASS and
  `build/native` FAIL, rc 1 (`fix/ff-ncirgate-2/`, `ff-ncirgate/`).
- On the shipped build [M]: t_numconv 0 differences in all 15 sets, ncin
  237, 0 identity guards left, PUC equal in 75 of 75; ncir 0 in all 13 sets;
  on Windows and in AlmaLinux 8 with the Linux PUC (`fix/fc-smoke-C/`,
  `fc-smoke-D/alma/`). On `build/native` ncir fails 22 cases a set (20 under
  `-O1` and `-O-loop`, 17 under `-O-cse`), t_numconv passes, so the default
  run-bitjit.sh fails there at ncir alone (the final check's BASE-nc and
  ALMA-base-nc, `fc-smoke-B/`, `fc-smoke-D/`).
- `test/native/negctl-bitop.sh`, 35 arms (md5 `e5838e14`) [S][M]:
  NUMCONVOP1 [nc:t_numconv nc:ncir], NUMCONVW [nc:t_numconv nc:ncir],
  NUMCONVOFF [nc:ncir]; canon lists `nc`. Margins in five selected runs, the
  same each time: NUMCONVOP1 t_numconv 30 a set (22 under `-O1`, `-O-loop`,
  `-O-cse`; 0 under `-O0`, `-O-fold`), ncir 10 (9); NUMCONVW t_numconv 27,
  ncir 10 (9); NUMCONVOFF ncir 22 (20, 17), t_numconv 0
  (`integrate/runs/negctl-nc-1` to `-5`); a sixth on the fixer's final
  scripts gave the same verdicts and counts (ncir 10/9, 10/9 and 22/20/17 in
  every set; t_numconv 30, 22 under `-O1`, and 27), canon 101 s, the arms
  9-10 s (`fix/fc-smoke-E/`; its work directory
  `fix/b-fix/negctl-bitop/`). NUMCONVOFF's `lj_opt_fold.o` is HEAD's (`1d018acc`),
  not the shipped one, so the fingerprint takes it. The full 35-arm sweep
  has not run in one call (the final check runs it).
- Beyond the suites [M: the code verifier]: its own value differential of
  identities and their uses (keys, counts, shifts, library arguments,
  side traces, stitches, PHIs): 0 differences from `-joff` in 60 JIT runs of
  the shipped build on Windows and 13 in AlmaLinux 8, failing on the
  sabotages; step 1's refutation sweep re-run on the shipped build, 0
  differences (`verify-code/vdiff-s1..3`, `vdiff-alma-s4`, `refute-d0-vb1`).

## The user's decisions this round (binding, all followed) [S]

(a) the rule on a line of its own after the width rule; (b) the predicate
a `static int` helper beside `oclj_bitwidth`, called from `bitop_wgate.c`;
(c) the three type tests kept as documented preconditions with no arm; (d)
three arms, NUMCONVOP1, NUMCONVW, NUMCONVOFF. Out of scope and untouched:
shifts of an exact operand, the pin move, row 209.

## The fixer's review (findings and outcomes)

Fixed in the repo:
1. run-bitjit.sh: ncir's JIT-on gate (the code verifier's Problem 1).
2. patch-bitop-fold.sh: verify_content's next-line check against a nested
   call (Problem 2), and its comment.
3. Guide 3.9: "only the width rule may" fold the guard's own check, now
   "only a proof that reads no guard": the width rule and FIX-NUMCONV.
4. "Where 5.3.6 raises" -> "where the interpreter raises (U1-B)" in the
   guide (3.11, 11.7 item 8), negctl's header and oclj_bitop_fold.c's
   comment [M: `fix/runs/edge-1.txt`: PUC 5.3.6 returns 2^53 + 1].
5. Guide 11.4: gen caught NUMCONVOP1 in 188-266, not 195-266 [M:
   `impl-tests/runs/genfloor-OP1-1.log`, seed 4 ms0].
6. Guide 11.5c and t_numconv.lua's header: BIG's values classed correctly
   (-0.0 and -2^63 do not raise for an identity).
7. Guide 7.6: `oclj_isnumconv` is not the first non-inline helper called
   from `bitop_wgate.c`; `oclj_bitwidth` has been since round 3 [S: `git show
   2dd5f05:native/build-native.sh`].
8. t_numconv.lua and ncir.lua headers: two AlmaLinux 8 runs, not one; and
   t_numconv's "30 cases with loop optimization" -> "with loop optimization
   and CSE".
9. Roadmap row 211 (5): ncir fails 17-22 cases a set on `build/native`; the
   per-iteration claim marked [S][I]; the code verifier's and fixer's checks
   recorded.
10. Guide marks: the per-iteration and PHI claims [S][I] (3.11, 9.5); "was
    sound" -> "sound on this build [S][I]" (3.11 History, P62); 3.11's
    probe fail-first stated precisely (994,085 of 1,000,000 random int64,
    -2^53 - 1 too).
11. Guide header cite wording (the width rule's return :1190, its call
    :1189); 1.2 row 10's commit column; 3.10's SELFGUARD genrg2 595-658.
12. run-bitjit.sh header: about 60 s, not 50 (61 s for all six parts).
13. negctl header: FIX-NUMCONV's arm runs five, not three.
14. oclj_bitop_fold.c: the loop-iteration sentence names the guards before y.
15. Guide: the opcode test's cause traced [M] (3.11, open question 20, the
    roadmap); 11.5c: VNOPHI caught by swap1; 11.8: rows for the two new
    checks and this final check; 11.9: two instrument rows; checklist 9 and
    19: grep for the rules a new rule joins; require an IR reader's summary
    line.

Not changed, with reasons: the negctl header's 2026-10-17 and 2026-10-20
margin minima (dated measurements that stay true; the one-run readings on
this build are in guide 3.10, 11.4 and 11.7 item 10, and widening them in
place would shift every negctl line cite); #1535's closing and upstream's
fix (the main session holds that evidence); decision (3)'s wording in
t_idx2.lua (accurate; a suggestion only); hunk 11's include comment (not
false); the integrator's short comment line (cosmetic).

## Open, for the user

1. An arm for `oclj_isnumconv`'s opcode test (NUMCONVNOOP, caught by gen;
   ncir sees it only under `-O1` and `-O-narrow`)? Decision (c)'s premise
   listed it among the unshowable tests; measured, it is visible.
2. gen, the floor or genrg2 as extra catchers for NUMCONVOP1 and NUMCONVW
   (one-run catches on the prototype's objects; genrg2 costs 40-70 s an arm)?
3. Keep the implementer's tighter order link (inside the rules' block) and
   the fixer's next-line check in verify_content (both documented, guide 8.2
   step 0)?

## After the final check, update before committing

- Guide 3.11 "What it buys" and roadmap row 211 (5) "The gain": add the
  final check's timing smoke (`logs/final-main/timing/summary.txt`).
- Guide 11.7 Cost and 11.11: the 35-arm sweep's measured time.
- Guide P54, Next task, roadmap rows 213 and 269: #1535 closed by upstream's
  `a4c0645`, if the main session wants it recorded now.

## Files and md5s

Repo working tree against HEAD `209aa95` (HEAD -> before the fixer -> final):
- `docs/jit-guide.md` `d5f39975` -> `0b566cc6` -> `92f2ce4b`
- `docs/roadmap.md` `870d8ad5` -> `b272fb35` -> `ee3d21b5`
- `native/build-native.sh` `47b9c52e` -> `ae218485` (the fixer: unchanged)
- `native/luajit/oclj_bitop_fold.c` `1ac93081` -> `18a710c3` -> `7dc61000`
- `native/luajit/patch-bitop-fold.sh` `149187d8` -> `f353efcc` -> `08c242a5`
- `test/native/negctl-bitop.sh` `fbd42f2c` -> `869bdc66` -> `e5838e14`
- `test/native/run-bitjit.sh` `01cc9a17` -> `d6a11298` -> `27b8262d`
- `test/native/bitop/t_idx2.lua` `f60e7948` -> `f6b9115c` (the fixer:
  unchanged)
- `test/native/bitop/t_numconv.lua` (new) `b41f3c85` -> `de0d14e9`
- `test/native/bitop/ncir.lua` (new) `fa1d06c1` -> `baaa4490`
- README.md unchanged (`98f6042d`).

Final check (scratch `claude-tmp/oclj/numconv/fix/`): `final-check.sh`
`a21cb5bc`, `fc-summarize.py` `27487bcc`, `fc-citecheck.py` `9b0a6c25`,
`fc-irident.py` `ea1b3ab3`, `fc-nestn7.py` `75364ea4`, `fc-ir_ident.lua`
`e01eb3af` (= step 1's `argue/probes/ir_ident.lua`), `fc-anchorcheck.py`
`d02e23e4` and `fc-tablecheck.py` `8bf1f616` (= the select round's).
Objects: Windows `lj_opt_fold.o` `f6d916e2`, AlmaLinux 8 `57970a51`; build
copy `lj_opt_fold.c` `3b11930f`. luajit.exe differs from build to build and
is no fingerprint (P13).
