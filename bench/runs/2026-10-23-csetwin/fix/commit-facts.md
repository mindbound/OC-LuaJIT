# The CSE type twin round: commit facts (the fixer, 2026-10-23)

Scratch `claude-tmp/oclj/csetwin/round/fix/` (called `fix/` below). Every fact has a mark: [M] measured (the run directory is named), [S] read in source (file:line), [I] inferred. Paths without a prefix are under `claude-tmp/oclj/csetwin/round/`.

## 0. State

- **The real repo was never written** [M]. At the start HEAD was 60a24ec with `bench/runs/2026-10-23-shiftexact/README.md`, `docs/jit-guide.md` and `docs/roadmap.md` modified (`fix/start/real-status.txt`). By the end someone else had committed them as **2ea33dd** ("The proof's roadmap rows and its review's fixes ..."), and the working tree was clean. 2ea33dd changes only those three files: `git diff --name-only 60a24ec HEAD -- native test src serializer build.gradle.kts` is empty [M]. The code base of this round is therefore the same at 1a13bed, 60a24ec and 2ea33dd.
- **build/native is unchanged** [M]: luajit.exe f4038cd6, lj_opt_fold.o f6d916e2 (Windows); luajit cb68e454, lj_opt_fold.o 57970a51 (Linux) (`fix/start/base-natives.md5`, checked again at the end).
- **The scratch repo** `repo/` is 1a13bed's tree (git archive, impl-code) plus the round's eight files. Its tree outside `docs/` and `bench/runs/` equals HEAD's but for those eight [M smoke/s1..s8 CHANGED-SET; `cmp/changed.txt` there].
- **The eight files, final** [M `fix/repo-eight-end.md5`]:

| file | md5 | change |
|---|---|---|
| native/luajit/patch-bitop-fold.sh | cfa5a3db | hunk 12 (impl-code) + verify_content's two lj_opt_cse counts and their comment (fixer) |
| native/luajit/oclj_bitop.h | 8385a4d1 | comment only (impl-code); moves no object |
| native/luajit/oclj_bitop_rec.c | 076c0a1a | comment only (impl-code); moves no object |
| test/native/negctl-bitop.sh | 52ccbc59 | CSEFWD, the 37th arm, and the cse catchers (integrate); header margins and the verify_content sentence (fixer) |
| test/native/run-bitjit.sh | cab65ddf | part cse (impl-tests, integrate); header counts (fixer) |
| test/native/bitop/t_csefwd.lua | 2c73c0f6 | new (impl-tests); cases copy, side, ctl-copy, ctl-side, their text checks, header (fixer) |
| test/native/bitop/cseir.lua | 98f5c649 | new (impl-tests); the copy and side gates, header (fixer) |
| test/native/bitop/t_cserev.lua | 2d361505 | new (impl-tests); the text check and two header sentences (fixer) |

- At the fixer's start the eight equalled `integrate/apply-manifest.md5` [M `fix/start/repo-eight.md5`]; the copies are in `fix/start/files/`.
- **code.patch** (`fix/code.patch`, md5 **8a126631410b25784b4cdb8d46992eb0**, `fix/code.patch.md5`; files in `fix/code-files.txt`): a unified diff of the eight against HEAD's copies (`fix/head/`, `git show HEAD:<path>`), the three new files from /dev/null. `git -c core.autocrlf=false apply` on a fresh `git archive HEAD -- native test` reproduces the eight byte for byte [M `fix/patchtest-2`]. Outside a repo, Git's global `core.autocrlf=true` writes CRLF (`fix/patchtest-1`, whose content matches once CR is stripped); inside the real repo `.gitattributes` (`* text eol=lf`) governs. After applying, check the eight md5s against the table above.

## 1. The fix (hunk 12)

- The build copy's `lj_opt_cse` match is `if (IR(ref)->op12 == op12 &&` / `irt_isi64(IR(ref)->t) == irt_isi64(fins->t))` / `return TREF(...)` [S `fix/b1/luajit-windows-x86_64/src/lj_opt_fold.c`:2674-2680 per verify-code].
- **The patch line**: NH 12, NADD/NDEL **76/9 of 2720** on the pin's pristine blob (15c7420c), **76/9 of 2730** on a4c0645's lj_opt_fold.c (blob 9d48aaa2, md5 0f28177c), idempotent, output = the build copy (59778bb6) [M fix/runs/ffpatch-1, -2, fc-ffpatch-1; smoke/s1 PATCH-*].
- **Objects** [M]:
  - Windows `fix/b1` (built 15:36:10-15:36:40, 30 s, rc 0, `fix/logs/build-b1.log`): 77 LuaJIT objects + our 3; only lj_opt_fold.o differs from build/native's: f6d916e2 -> **a6c5fcc2** (`fix/cmp/`). The same in smoke/s5 (a fresh build, 34 s).
  - AlmaLinux 8 `fix/alma1` (14 s, OCLJ_GLIBC_MAX=2.28, GLIBC_2.17 needed): only lj_opt_fold.o differs from build/native's Linux tree: 57970a51 -> **1b4a7c13**; luajit 6b9b72b4; build copy 59778bb6 [M alma1/summary.txt, smoke/s4].
  - The two comment-only C files move no object [M verify-code/cmp; fix/cmp: only lj_opt_fold.o differs].
- Build gates [M fix/logs/build-b1.log, alma1/gates.txt]: pin met, export verified (8 trees, 232 files), nothing ignored from the environment, round 3's C files and the shim 0 warnings.

## 2. verify_content: the verifier's finding 1 (applied, generalized)

- **The new check** [S patch-bitop-fold.sh verify_content, after the adjacency check]: between lj_opt_cse's definition line and lj_opt_cselim's, `op12 == op12` on exactly one line (the match count) and `return` on exactly two (the return count: hunk 12's return of the common subexpression and upstream's return of the emitted instruction). The verifier proposed counting the specific return text `return TREF(ref, irt_t(IR(ref)->t))`; counting every `return` also refuses an extra match spelled without op12 and with another return (m5).
- **Fail-firsts** [M fix/runs/ffpatch-1 (on the script before the comment edit), ffpatch-2 and fc-ffpatch-1 (final script); scripts/ffpatch.py, fc-ffpatch.py]:
  - Script mutations of n12, apply mode on the pin's blob, NADD set to each mutation's own count:
    - m1 extra forward-allowing match line (78/9), m2 the same reverse-allowing (78/9), m3 an else-if after the return (77/9), m4 one-line reverse match with a cut comment (76/9): the round's old script (d488821b) **passes all four, rc 0**; the new one refuses each, rc 1, "names 'op12 == op12' on 2 lines".
    - m5 (fixer) a reverse match spelled `op1 == fins->op1 && op2 == fins->op2` with its own return: old rc 0, new rc 1, "names 'return' on 3 lines".
    - m6 (fixer) a stray `if (... op12 == op12 && !irt_isi64(fins->t)) break;`: old rc 0, new rc 1, "names 'op12 == op12' on 2 lines".
    - c5 CSEFWD's text and c6 `|| irt_isi64(IR(ref)->t)`: refused by both, rc 1 ("is a line of its own 0 times").
  - Every check evaluated with a non-exiting fail() on mutations of a patched file (hunk 12's seven lines whole): p1, p2, p3 fire both counts and nothing else; p5 the return count alone; p6 the match count alone; the control none.
  - Controls: the pin's blob 76/9 of 2720; a4c0645's 76/9 of 2730; already-patched mode on its output verified, same bytes; the control output is the same bytes under the old and new scripts (59778bb6).
- The script still holds no tab, backslash or CR, and its hunk engine is unchanged (077d1dbe, all seven patch scripts) [M smoke/s1 PATCH-NO-TAB-BS, ENGINE].
- Residual [I]: a macro redefining irt_isi64 inside n12 would pass (named in the comment).

## 3. The tests

### 3.1 t_csefwd: cases copy and side (the verifier's finding 2, applied)

- **copy** (the verifier's body-v2): `j = string.byte(S, 2)` before the loop; each iteration `local a = bit.lshift(j, 30); local c = string.byte(S, i + 1) << 30`, then `j = string.byte(S, i + 2)`; 400 iterations, S = S8. The pair forms only in loop_unroll's copy. Fields: kind pair, narrow true, need "loop".
- **side** (the verifier's side-pair): 600 iterations; past i = 300, `b = string.byte(S, i)`, then `bit.lshift(b, 30)` and `b << 30`; the root trace records the other branch, so the pair is compiled only in a side trace. narrow false, need "side".
- Controls **ctl-copy** and **ctl-side**: the same shapes with `x * 1073741824 % 4294967296` for the bit library's call.
- t_csefwd now has **32 cases**: 13 wrong-when-served, 7 right-when-served, 12 controls [S]. Its producer-first check also requires each of the two texts in order (statements as above) with exactly one `bit.` and one `<<` [S].
- **cseir's judge** [S cseir.lua judge]: copy judged only with the loop optimisation on; side and ctl-side only where `direct + served > 0` (pre >= 1: a trace compiled our operator). A first try that judged side where `traces >= 2` failed on the fixed build under -Omaxside=0: there a side trace is a stub that links to the interpreter, so traces was 2 with no pair [M fix/runs/cse-fix-1; fix/probes/onecase.lua under -Omaxside=0 shows trace 6 with parent 5/1]. copy under -O-narrow forms no pair on either build (split 0 fixed, served 0 base, values right) [M cse-fix-1, cse-base-1], so copy is narrow true.
- **Fixed build** (`fix/b1`): t_csefwd 0 in all 15 sets; coverage "a trace completed in 32 of 32 cases; 20 of 20 pairs formed, served 0, split 38"; cseir 32 of 32 ok in all 12 sets; pairs judged 20 of 20 (default and the 6 other sets with loop, narrowing and side traces), 19 of 20 under -O-loop and the two -Omaxside=0 sets, 2 of 20 under -O1 and -O-narrow [M fix/runs/cse-fix-2, cse-fix-3, bitjit-all-fix-1; alma1/cse]. Default set: copy split 1, side split 1 (2 under -Ohotexit=1 sets), every other pair split 2 [M cse-fix-3/cse/cseir-jon.txt].
- **build/native** (luajit f4038cd6), runs cse-base-1 to -6 (Windows) and alma1/base-cse (Linux cb68e454) [M]:
  - copy wrong 336, 393 and 393 of 400 over the three calls; side 285, 295 and 295 of 600 [M cse-base-6 t_csefwd-jon.txt].
  - Wrong cases per set (7 runs): FIRST11 in each of the 10 sets with fold, CSE and narrowing on; copy in the 9 of them with the loop on (not -O-loop), never elsewhere; u8sh30 and side under -O1 and -O-narrow; nothing under -O0, -O-fold, -O-cse; the 7 right-when-served cases and the 12 controls never.
  - side varies with whether a trace compiles its branch: wrong in every run under jon, hl1, noloop, hx1, ts1, mx1, noabc, O1, nonarrow; under he1 (-Ohotloop=1 -Ohotexit=1) in 6 of 7 runs (right in cse-base-6); under ms0 and hl1ms0 in 1 of 14 readings (hl1ms0 in cse-base-5, the first call wrong from its 594th result).
  - So t_csefwd FAILs with 13 in jon, hl1, hx1, ts1, mx1, noabc (every run) and he1 (6 of 7), 12 under noloop, ms0, hl1ms0 (13 once), 2 under O1 and nonarrow, 0 under O0, nofold, nocse.
  - cseir FAILs 20 in 7 sets, 19 under noloop, ms0, hl1ms0, 2 under O1 and nonarrow, in every run with the final judge (cse-base-2 to -6, alma1); every FAILED pair has served >= 1; i64slot and rserved 0 in every line.
  - t_cserev FAILs its 4 reverse cases (rserved >= 1, split 0) in the 10 sets with narrowing; every value right; i64slot 0; PUC equals -joff in all 8 [M; fc-basecse.py base PASS on cse-base-2, -5, -6, alma1/base-cse].
- **CSEFWD** (negctl, two selected runs on fix/b1, `fix/runs/negctl-cse-1`, `-2`): caught by cse:t_csefwd and cse:cseir both times; t_csefwd 13 in 7 sets (in run 1 hx1 read 12: side right there), 12 under noloop, ms0, hl1ms0, 2 under O1 and nonarrow; cseir 20/19/2 as on build/native; t_cserev passes. canon 110 s and 112 s, CSEFWD 12 s; restore PASS [M]. verify-code's CSEFWD prototype (ccf83851) read side wrong under -Ohotexit=1 in 5 of 5 standalone runs, and build/native in 3 of 3 [M fix/runs/pfwd-hx1-1].
- The new cases are forward order and value-only: the bit library's call precedes our operator in program order; loop_unroll re-emits in pre-roll order; a side trace records in program order [S][I].

### 3.2 t_cserev (the verifier's findings 5 and 3)

- **The text check** [S t_cserev.lua, before any case is loaded]: refuses any case text naming `bit` at all and any with other than exactly one `for ` (the loop jloop or iloop writes). The old check refused only `bit.` and `for j = i`.
- **Its fail-first writes no slot shape** [M fix/runs/fftests-1, -2, fc-fftests-1; scripts/fftests.py, fc-fftests.py]: the verifier proposed a mutated case in the G3r shape [code redacted in the public archive], which D2 forbids writing; instead a Lua comment `-- for ` (r6-byte) and `-- bit` (r5-sel) is prepended to a case's text. The new check prints `INSTRUMENT: t_cserev's texts: r6-byte (a slot shape)` (and r5-sel), exit 2, under PUC 5.3.6 and under build/native's -joff; the old file (fix/start/files) passes both, rc 0, under PUC. Nothing runs under the JIT in these fail-firsts.
- **The header** (finding 3, the part for code): the sentence "the copy emits no new pair" now says it holds for these loops, whose pairs' operands are the loop index, and that in general the copy can form a pair record time did not (no type check between two body instructions; covered by hunk 12 since every copied instruction goes through lj_opt_cse; t_csefwd's copy is one, forward). The TYPEINS cite became "the loop-carried branch, :334, raising it at :352" [S build/native's lj_opt_loop.c:334 `if (ref < invar)`, :352 `lj_trace_err(J, LJ_TRERR_TYPEINS)`].
- t_cserev's cases and values are unchanged: fixed build 8 of 8 ok in all 15 sets, its 4 reverse cases judged with split 2 in the default set [M cse-fix-3].

### 3.3 Other test fail-firsts [M fix/runs/fftests-2, fc-fftests-1]

- t_csefwd's copy and side order checks (their search strings changed) and the `bit.` count (wanted 2) print INSTRUMENT, exit 2, under -joff.
- cseir's side gate removed: under -Omaxside=0 on the fixed build side and ctl-side FAIL (pre 0, split 0); loop gate removed: under -O-loop copy FAILs (split 0); with the gates, both sets read 32 of 32 ok, pairs judged 19 of 20.

### 3.4 Finding 4 (applied, then superseded)

- "each of the 12 option sets" became "each of the 10"; the paragraph was rewritten with the new cases' numbers (3.1).

### 3.5 Full suites on the fixed build [M]

- run-bitjit.sh, all seven parts: PASS, 74 s (`fix/runs/bitjit-all-fix-1`); in smoke/s3 73 s, the generator's idx, rg2 and phi modes PASS in 47, 28 and 36 s; base cse 12 s.
- AlmaLinux 8 (smoke/s4, 168 s for the WSL part): build, all seven parts with the Linux PUC, the three generator modes, base FAIL as read: PASS. Ubuntu's dash: sh -n of the three changed scripts, the final check and fc-anchors.sh: 0.
- run-bitop.sh PASS 4 s, run-bitfuzz.sh PASS 3 s, the nine runners exit 0 in 36 s together (smoke/s5).
- Line cites of the round's files: 46 rows hold by content (t_cserev's 32 into build/native's build copy, patch-bitop-fold.sh's 14 into the pin's blob), and every cite moved one line up or down fails all 46 [M fix/runs/cites-shift{0,1,-1}.txt; fc-cites.py].
- negctl's 37 arms' anchors: each once in each copy, each sabotage one changed line (fc-anchors.sh = integrate/scripts/anchors.sh, smoke/s1: verdict ALL-OK).

## 4. The final check (`fix/final-check.sh`, md5 in `fix/scripts-and-helpers.md5`)

- **Run** (main session, Git Bash, quiet machine, Minecraft closed):
  `nohup sh /c/Users/astro/claude-tmp/oclj/csetwin/round/fix/final-check.sh <fresh outdir> > <outdir>.log 2>&1 &`, monitor `<outdir>/ALL.done`. Expected 30-35 min [I: parts measured in smoke/s1-s8 and the negctl sweep's history]. Keep the real repo still during it: a commit there fails CENSUS-real-repo and FILES-unchanged by design.
- **Parts**: build, alma (with Ubuntu's sh -n), bitjit, base, suites, negctl (full 37-arm sweep, one call), runners, hygiene, timing (last; 8 rounds, base vs new on the four integrate benches); the census, md5s, and the tree check always run.
- **Refusals** (all measured): an existing outdir 97 (smoke/g1); inside the real repo 97, also lower-cased (g2, g2b); inside the scratch repo 97 (g3); FC_USE_BUILD in the real repo 97 (g4); a scratch repo whose eight files are not the pinned md5s 95, before the outdir is made (g5); a running javaw with timing wanted 96 (g6, a stand-in tasklist); the scratch tree differing from HEAD's by an extra file 95 after the census, nothing run (g7: CHANGED-SET FAIL, test/native/bitop/extra.lua listed). Nothing was created in the real or scratch repo by g2-g4 [M ls].
- **Reader fail-firsts**: fc-basecse.py reads build/native's cse output as base PASS and as new FAIL (281 findings); the fixed build's as new PASS and as base FAIL (93 findings) [M smoke/s1, s3]. FC_BASE_BUILD pointed at the fixed build: BASE-cse, BASE-base-md5 and BASE-reader-ff1 FAIL (smoke/s2-baseisnew). The timing summarizer reads a doctored new result as `RESULTS: DIFFER`, `SUMMARY: FAIL` (smoke/raw-doctored.txt); a javaw appearing before round 1 stops the timing part (STOPPED; TIMING-complete FAIL, smoke/s7).
- **Smoke runs** (knobs set, so VERDICT INCOMPLETE by design): s1 base+hygiene 28 PASS 0 FAIL; s3 bitjit+base all PASS; s4 alma all PASS; s5 build+suites+runners+timing all PASS but the timing summary, which crashed at FC_NDIV=10 on rows reading 0 ns (integrate's timing-summ.py); fixed in fc-timing-summ.py with a guard (min/max of an empty ratio list; it still reproduces integrate/timing/run-1/summary.txt byte for byte, smoke/summ-integrate-run1.txt), and s6 then PASS; s8 negctl with FC_NEGCTL_ARMS=CSEFWD: arm list, canon list, canon, restore PASS, NEGCTL-rc and NEGCTL-37-arms FAIL by design.
- The census of build/ took 186 s in stat mode (g7); FIX-NUMCONV measured 164-219 s in md5 mode. FC_CENSUS=none (smoke only) skips it.
- **What it does not check**: the docs (a later phase), the in-game behaviour, the release.

## 5. Helpers beside the final check (md5s pinned in it; also `fix/scripts-and-helpers.md5`)

fc-cites.py 573a623b; fc-basecse.py 5e32aade; fc-ffpatch.py 1b569815; fc-fftests.py d879060f; fc-anchors.sh 948d0698 (integrate's anchors.sh); fc-timing-summ.py 2e3113f6 (integrate's f66d10af plus the guard); fc-a4c0645-lj_opt_fold.c 0f28177c (csetwin/upstream/src-tip, blob 9d48aaa2 = `git rev-parse a4c0645:src/lj_opt_fold.c` in sel/upstream.git with GIT_NO_LAZY_FETCH=1); fc-bench/ bench_bit 2c6a60e0, bench_bit2 7bb3ab87, bench_numconv c15c325e, ident 5a042955 (integrate/timing/bench).

## 6. For the docs phase

- **Numbers that changed** with the fixer's cases: t_csefwd 28 -> 32 cases (11 -> 13 wrong-when-served, 10 -> 12 controls); pairs 18 -> 20; base counts as in 3.1; CSEFWD margins as in 3.1; canon 110-112 s.
- **verify_content** (guide 7.5, 8.2, 11.8): the two lj_opt_cse counts and their fail-firsts m1-m6 (section 2).
- **In-game reach** (finding 3, docs only): G3 can also arise from a pair formed only in the loop copy, from operands that differ at record time and coincide in the copy (a string.byte value or a slot carried across iterations). loop_unroll type-checks only matches with a pre-roll ref (`ref < invar`, lj_opt_loop.c:334); nothing type-checks a body-to-body match [S build/native lj_opt_loop.c:330-352]. The reverse route is [I] only; it was never written or run (D2). Hunk 12 covers it (loop_unroll -> emitir -> lj_opt_cse). The forward analogue is measured: t_csefwd's copy.
- **Side traces**: a pair that forms only in a side trace is covered too (t_csefwd's side) [M].
- The side case's values on an unfixed build depend on trace formation in a few option sets (3.1); cseir judges it only where a trace compiled it.
- The guide's 11.10 paragraph: the reverse half is held by verify_content's exact-text and no-other-match checks on every build, the predicate's symmetry, and t_cserev's two no-slot shapes; no reverse slot case exists anywhere.

## 7. Findings: applied, changed, rejected

1. Medium, verify_content: **applied, generalized** (a count of every `return` rather than of one return text; measured to refuse m1-m4 as proposed and also m5).
2. Low, copy and side cases: **applied** as proposed, with the precondition for side changed from the proposal's implied "a side trace exists" to "a trace compiled our operator", measured necessary (3.1).
3. Low, in-game reach: **docs phase**; the t_cserev sentence applied now (3.2).
4. Low, "12 option sets": **applied**, then rewritten with the new numbers.
5. Low, t_cserev's text check: **check applied**; its proposed fail-first **rejected**: it is the G3r slot shape [code redacted in the public archive], which D2 forbids writing on any build, gated or not. Comment mutations prove the same two checks without writing it (3.2).

## 8. Open points

- **My slip**: once I ran `python -I -` with stdin from /dev/null (a leftover in a command, against CLAUDE.md); it hung, I stopped it (task bcqv14z26), and the sed in the same command never ran. It touched nothing.
- The side case under -Ohotexit=1 and -Omaxside=0 sets is the one per-set count that varies between runs (3.1); the final check's base reader judges side only in the default set, where it read wrong in 7 of 7 runs.
- In the default set every pair must be judged (the runner's gate); a run in which side's side trace failed to form would read PROVED NOTHING, not PASS [S run-bitjit.sh]. The default set judged 20 of 20 in all 10 runs of the cse part on fixed builds: fix/runs/cse-fix-1 to -3, bitjit-all-fix-1, smoke/s3, smoke/s4 (Linux), alma1/cse, and the three negctl canons (b1/negctl-bitop/*, smoke/s5/b/win/negctl-bitop/*) [M].
- HEAD moved to 2ea33dd during the round (docs only); the final check archives whatever HEAD is when it runs.
- fc-anchors.sh (integrate's anchors.sh, unchanged) holds one backslash, the `\n` in its printf format at :74, though its header says none; it is no patch script and was written with a file tool, so it is harmless, but the header is wrong [M grep]. final-check.sh, fc-cites/basecse/ffpatch/fftests and the fixer's scripts/*.sh hold none in their shell text [M od].
- The final check has not run in full; its parts ran separately in smoke/s1-s8 with knobs (so each VERDICT was INCOMPLETE by design), and the full negctl sweep only as canon plus CSEFWD.
