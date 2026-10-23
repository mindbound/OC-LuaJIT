All five integration steps were done in scratch, and every result matches the design's prediction. The real repo is unchanged: HEAD 60a24ec, the same git status, and build/native's luajit.exe f4038cd6 and lj_opt_fold.o f6d916e2 and its Linux objects as at the start [M integrate/logs/real-repo-status-end.txt, start/]. Below, integrate/ means C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/.

SCRATCH REPO. In round/repo exactly five files changed [M logs/round-repo-start-vs-end.diff]:
- added test/native/bitop/t_csefwd.lua 7dc833e0, cseir.lua 5e0a79fe and t_cserev.lua fbeaf16b;
- run-bitjit.sh 27b8262d -> f75d6bcf (impl-tests' cse part);
- negctl-bitop.sh 0e453ecb -> 674841b4.
With impl-code's three files that makes eight to apply; their md5s are in integrate/apply-manifest.md5. The new HEAD 60a24ec changes no file under test/ or native/, so the files apply cleanly onto it [M git diff --name-only 1a13bed 60a24ec]. Each changed file has 0 CR and 0 tab, and git diff --no-index --check is clean on all of them [M scripts/bytecount.py]. negctl's backslashes go from 118 to 120, the two new ones being its new continuations.

BUILD. integrate/b1 is a pinned additive Windows build of round/repo: rc 0 in 29 s, ignored from the environment: none, warnings 0 [M logs/build-b1.log].
- Its 80 objects equal impl-code's build-fix all 80.
- Against build/native only lj_opt_fold.o differs: f6d916e2 -> a6c5fcc2 [M cmp/].
- luajit.exe is 038d09f5, a link-time md5 (P13).

(1) THE CSE PART on b1, rc 0, 9 s [M runs/cse-b1-1]:
- t_csefwd: 0 differences in all 15 SELOPTS sets; traced 28/28; pairs 18/18; served 0; split 36; i64slot 0.
- t_cserev: 0 in all 15 sets; reverse cases judged 4/4 in the 10 sets with fold, cse and narrowing on (0/4 under O0, O1, nofold, nocse and nonarrow); PUC equals -joff in 8/8.
- cseir: 0 in all 12 CSEIROPTS sets; pairs judged 18/18 (1/18 under -O1 and -O-narrow).
- The full default runners on b1 also pass: run-bitop (12 checks, 0 failures), run-bitjit with all seven parts and no "parts run" note (71 s), and run-bitfuzz. round/repo did not change during the runs [M run-b1-1/summary.txt].

(2) NEGCTL: CSEFWD, the 37th arm, as the design's section 5 gives it.
- Old line: '@T@  irt_isi64(IR(ref)->t) == irt_isi64(fins->t))'. New line: '@T@  (irt_isi64(IR(ref)->t) == irt_isi64(fins->t) || irt_isi64(fins->t)))  /* SABOTAGE CSEFWD: ... */'.
- Plumbing: cse added to rcof, runcatchers and canon's catcher list; check cases cse:t_csefwd (grep '^FAIL t_csefwd (') and cse:cseir (grep '^FAIL cseir ('); info's awk gains t_csefwd, t_cserev, t_cserev-PUC, t_cserev-joff and cseir.
- Header: the catcher entry, the arm list, a paragraph on why no arm holds the reverse order (verify_content plus the predicate's symmetry; the dropped predicate is the unfixed build), the margins, the cost, and the memory-safety sentence.
- One selected run, OCLJ_NEGCTL_ARMS=CSEFWD, rc 0 [M runs/negctl-cse-1.log, work dir b1/negctl-bitop/20261023T113715Z-1926]:
  - canon PASS in 108 s, with bitjit[gen floor fix1 idx sel nc cse] 0.
  - CSEFWD caught by cse:t_csefwd and cse:cseir in 12 s, objects changed: lj_opt_fold.o only. The sabotage object ccf83851 is the same object as impl-tests' proto-fwd.
  - t_csefwd: 11 cases in 10 of 15 sets, 1 under -O1 and -O-narrow, 0 under -O0, -O-fold and -O-cse. cseir: 18 in 10 of 12 sets, 1 under -O1 and -O-narrow. t_cserev passes.
  - All three verdict lines are byte-equal to impl-tests' cse-fwdsab-1.
  - restore PASS. The work dir is 157 MB.
- Anchor counter: all 37 arms count exactly 1 in the build copy, in the patch output on the pin's export (all 7 patched files equal b1's build copy) and in the repo's oclj_* files, 73 rows OK [M anchors-1/, logs/anchors-1.log]. Its fail-first on mutated negctl copies gives x0, x70, 'mark 0' and 'DIFF 1/2', each rc 1, with only CSEFWD's rows failing [M ff-anchors/results.txt].
- Fail-first of the new checks, run on negctl's own extracted rcof() and check():
  - 16 of 16 wanted verdicts on the CSEFWD, base, fixed and synthetic logs (only-reverse, only-cseir, -joff-only, rc 0 and rc 2); HEAD's 0e453ecb text gives 10 of 16, wrong exactly where cse plumbing is needed [M ff-check/new.txt, head.txt].
  - One end-to-end call on a mutated tree (cseir's JIT results doctored; CSEFWD listed on nc:t_numconv): canon FAIL with 'failed: cseir' as the only failing suite, and CSEFWD FAIL (NOT CAUGHT by nc:t_numconv), with bitjit[nc] 0 under the sabotage; restore PASS; rc 1 [M runs/negctl-ff-1.log].
- After the run I edited the header to add the measured cost (comment lines only): as-run text 626f1b2d, final 674841b4 [M logs/negctl-asrun-vs-final.diff].

(3) T4, THE REFUSAL CENSUS.
- integrate/t4 is a copy of b1's tree (guide 7.4), with lj_opt_fold.c changed in two lines: '#include <stdio.h>', which the file otherwise lacks [S lj_def.h], and one line after hunk 12's return that prints 'CSEREFUSE op= fins= cand=' to stderr when op12 matched and the predicate refused. Never shipped.
- Only lj_opt_fold.o changed (a6c5fcc2 -> b58962f1, 77 objects compared), with no warnings [M t4/obj.diff, fold-c.diff].
- Instrument fail-first: the cse part on t4 PASSes and prints 830 refusal lines in 34 .err files [M runs/t4-cse-1]:
  - forward refusals (fins I64 = 21, candidate INT = 19): BSHL 336, BNOT 152, ADD 152, BSHR 76, BAND 38;
  - reverse refusals (fins INT, candidate I64): ADD 57, BSHL 19, all from t_cserev.
- Census [M t4-census-1/, t4-census-1.recount.txt]: 0 refusal lines over 568 output files (237 .err). The runs:
  - gen (4 seeds), floor, fix1, idx, sel and nc, from a scratch copy of run-bitjit.sh whose GENOPTS, RECOPTS, JIT2OPTS and IDXOPTS gain the side-trace sets he1 and ts1 [M t4-tree.py diff]: rc 0 PASS;
  - run-bitop.sh: rc 0, 12 checks;
  - t_ops, t_fold, t_sar, t_bit, p4v and phiidx run directly under the default, he1 and ts1: 18 runs, all rc 0.
  The script's first count read 1: the format string inside bitop_test.exe, linked with the instrumented libluajit.a, not an output. The recount over text files reads 0, and the script is fixed to use grep -I.
- The four benches on t4 print 0 refusals [M timing/t4-benches/summary.txt].

(4) ALMALINUX 8 [M alma1/summary.txt, cse.log]: a pinned additive build of round/repo with OCLJ_GLIBC_MAX=2.28 into integrate/alma1/b.
- rc 0; ignored from the environment: none; export verified; warnings 0; glibc needs at most GLIBC_2.17.
- Of 80 objects compared with build/native's Linux tree, only lj_opt_fold.o differs (57970a51 -> 1b4a7c13).
- The .so is dd3ab258, a scratch build only.
- The cse part with the Linux PUC: rc 0 PASS, identical to Windows (traced 28/28, pairs 18/18, served 0, split 36, i64slot 0, reverse judged 4/4, cseir 18/18, PUC equals -joff).

(5) SMOKE TIMING [M timing/run-1/]: build/native's luajit.exe (f4038cd6) against b1's, alternating the order each round, 8 rounds, about 30 s.
- Benches: bench_bit 2e7, bench_bit2 1e7 (crc-table among its rows), ident 1e7 time and bench_numconv 2e7; the bench md5s are in timing/bench/sources.md5.
- No java or javaw at the start or between rounds; CPU load 2% before and after.
- RESULTS: EQUAL in all 21 rows. Every row's median new/base is 1.000 (crc-table 1.000 [0.973-1.000]), as predicted. GROSS OK; SUMMARY OK.
- Fail-firsts: timing.sh refuses a stand-in javaw.exe with rc 97, creating nothing else [M timing/ff-java/]. The summarizer gives 5 of 5 wanted verdicts on doctored input: a result differs, rows missing, a malformed line, and a 3x row [M timing/ffsumm-1.txt].

FILES:
C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/test/native/negctl-bitop.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/test/native/run-bitjit.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/test/native/bitop/t_csefwd.lua
C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/test/native/bitop/cseir.lua
C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/test/native/bitop/t_cserev.lua
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/apply-manifest.md5
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/head-negctl-bitop.0e453ecb.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/negctl-as-run-626f1b2d.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/logs/negctl-hunks.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/logs/negctl-asrun-vs-final.diff
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/logs/round-repo-start-vs-end.diff
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/logs/build-b1.log
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/cmp/b1.md5
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/runs/cse-b1-1.log
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/run-b1-1/summary.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/runs/negctl-cse-1.log
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/runs/negctl-ff-1.log
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/ff-check/new.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/ff-check/head.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/logs/anchors-1.log
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/ff-anchors/results.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/t4/fold-c.diff
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/runs/t4-cse-1.log
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/t4-census-1/census.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/t4-census-1.recount.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/timing/t4-benches/summary.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/alma1/summary.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/alma1/cse.log
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/timing/run-1/summary.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/timing/ff-java/rc.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/timing/ffsumm-1.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/build.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/csepart.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/runners.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/negctl.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/anchors.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/ffanchors.py
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/ffcheck.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/ffnegctl.py
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/t4-instrument.py
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/t4-tree.py
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/t4-census.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/alma.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/timing.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/timing-summ.py
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/ffsumm.py
C:/Users/astro/claude-tmp/oclj/csetwin/round/integrate/scripts/bytecount.py

REST:
{
 "open_points": [
  "CSEFWD's margins rest on one negctl run (integrate/runs/negctl-cse-1), plus impl-tests' run of the same sabotage object ccf83851 (cse-fwdsab-1); every count is identical between the two. The design asked for three runs; the final check's full 37-arm sweep would be the third. The full sweep was not run here: it takes about 13-14 min and belongs to the main session.",
  "negctl-bitop.sh's header was edited after its run, adding the cost sentence (canon 108 s, CSEFWD 12 s, 157 MB). The run used text 626f1b2d and the final text is 674841b4; they differ in three comment lines only [M integrate/logs/negctl-asrun-vs-final.diff].",
  "Guide and final-check cites into negctl-bitop.sh move. The header gained 39 lines before 'set -u' (HEAD :294 -> :333). From there the code moves by 39 lines up to check's new cse lines (HEAD :593), by 41 up to info's five new awk lines (HEAD :632), and by 46 from there (armlist :731 -> :777, canon :732 -> :778). From CSEFWD's 3-line call after NUMCONVNOOP (HEAD :842) it moves by 49 (WORK= :859 -> :908). Total 953 -> 1002 lines [M integrate/logs/negctl-hunks.txt]. The docs phase must re-derive guide 11.7's cites (~:659, ~:731-843, ~:732, ~:467-647, ~:482, ~:680, ~:859, ~:335-338, ~:393-406) and the cite checks.",
  "Under D2, t_cserev (T3-lite) runs inside the default cse part, so negctl's canon runs it, and so does every build's run-bitjit. Design 4.4/4.7's 'cserev never by default, never in canon' described the gated T3 and is superseded; the docs should describe the cse part as built. The negctl header says 'the part's t_cserev runs with them and no arm names it'.",
  "T4's instrument is two lines in one file (an include of stdio.h was needed), not the design's 'one extra line'. 'Two side-trace sets' was read as he1 (-Ohotloop=1 -Ohotexit=1) and ts1 (-Otryside=1 -Ohotexit=2), added to scratch copies of GENOPTS, RECOPTS, JIT2OPTS and IDXOPTS (as ts1x), and to direct runs of the matrix files, p4v and phiidx. The instrumented build and the census tree are never shipped.",
  "In AlmaLinux 8 only the cse part was run on the new .so. The other default parts, negctl and the gated items there are for the final check.",
  "Side observation [M runs/negctl-ff-1]: under CSEFWD the nc part passes (t_numconv and ncir see nothing). This agrees with T4's reading that no int/i64 pair forms in the nc suites.",
  "integrate/ holds 616 MB, mostly two negctl work directories under integrate/b1/negctl-bitop/ (20261023T113715Z-1926 and 20261023T114052Z-815, about 157 MB each). Nothing was deleted, per the results-directory rule."
 ]
}
