I wrote T1, T2, T3-lite and the `cse` part, and ran their fail-firsts. Everything is in scratch under C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/. I edited nothing in the real repo [M git status; build/native is still luajit.exe f4038cd6 and lj_opt_fold.o f6d916e2]. HEAD moved from 1a13bed to 60a24ec while I worked. That commit touches no file under test/ or native/ [M git diff --name-only], so my runner diff still applies to run-bitjit.sh 27b8262d.

**Files** (md5 in deliverables.md5; LF, 0 CR, 0 tab [M scripts/bytecount.py]):
- `test/native/bitop/t_csefwd.lua` (7dc833e0, no backslash). T1: 28 forward cases, each its own loop called 3 times, with the 32-bit producer first in program order. A load-time check enforces that order.
  - 11 wrong-value pairs: lsh3, bnot, bnotx, bxorm1, lsh35, u8sh30, nested, reassoc, chain, vlsh, vrsh. These are the design's F1-F10, with F6 split into vlsh and vrsh.
  - 7 right-value pairs: lsh1, band, rsh5, select (G1f), byte2, sub2 (G2f), forin (G3f, forward only).
  - 10 controls, run first: our operator alone; the bit library alone; same-type pairs (same-bit, same-53); and c1.
  - Every 5.3 result and every bit-library result is checked against a plain-arithmetic reference with no bit operators. A mismatch makes the file exit 1 under any VM, -joff included.
  - It prints a `#cov` line (traced, pairs, served, split, i64slot). Run as `loadfile(..)("cases")` it returns its case list.
- `test/native/bitop/cseir.lua` (5e0a79fe, no backslash). T2, and the shared IR reader (`loadfile(..)("lib")`).
  - It reads `jit.util.traceir` and `tracesnap` and counts served, split, rserved (a 32-bit instruction consuming our I64 one), direct and i64slot, keyed on operands.
  - It refuses -O0, -O-fold and -O-cse (exit 2), prints a summary line that only a JIT run prints, and FAILs a pair that does not form where fold, CSE and narrowing are on.
- `test/native/bitop/t_cserev.lua` (fbeaf16b, no backslash). T3-lite: only R5 (`j << 3`, then select beyond the varargs) and R6 (`i << 1`, then `string.byte(S, i + i)`, `string.sub(S, i + i, i + i)` or `string.byte(S, i * 2)`), plus 4 controls.
  - Its header gives the no-slot argument from the build copy, with line numbers: lj_record.c:2052-2098; lj_ffrecord.c:873-911; lj_opt_narrow.c:394-442 and :471; lj_opt_fold.c:2675; lj_opt_loop.c:330-334. In short, the merged I64 ref reaches only an int ADD held in a C local, never `J->base`. The loop copy adds no new pair. Snapshots carry no such ref [S].
  - A load-time text check refuses any case that uses `bit.` or an inner `for j = i`, or that does not put our operator first.
  - It checks values against a plain reference and judges the IR itself. Its output runs unchanged on PUC 5.3.6.
- `test/native/run-bitjit.sh` (f75d6bcf; the diff against the repo's 27b8262d is run-bitjit.diff, 211+/12-). Note that the repo file lives at test/native/, not bitop/. Changes:
  - Part 7, `cse`, added to the default parts.
  - t_csefwd under SELOPTS (15 sets) against -joff, with a coverage gate: jit on, traced ≥ HOTMIN, pairs ≥ 1. No PUC run, with the reason stated.
  - t_cserev fields 1-2 against -joff in 15 sets; the summary line required; the default run must judge 4 of 4; its whole output must equal PUC's.
  - cseir under CSEIROPTS (12 sets: SELOPTS without O0, nofold and nocse), in the ncir pattern; the default run must judge 18 of 18.
  - Header, file check, `inputs.md5` and the "parts run" string updated.

**Prototype** (one-file method; not the shipped object): `proto-fix` has the design's predicate applied by hand (lj_opt_fold.o a6c5fcc2). `proto-fwd` has CSEFWD's sabotage text (ccf83851). Only lj_opt_fold.o differs from the base build [M proto-*/obj-other.txt = 0].

**What the runs measured [M runs/]:**
- **build/native (unfixed base)**, `cse` part rc 1 in 3 Windows runs (cse-base-1..3) and 1 AlmaLinux 8 run (alma-base-1, luajit cb68e454), per-set counts identical:
  - t_csefwd FAILs in 11 cases per set where fold, CSE and narrowing are on. The other sets: 1 case (u8sh30) under -O1 and -O-narrow; 0 under -O0, -O-fold and -O-cse.
  - Per-case wrong values, by call (cse-base-2), first call then the next two:

| case | call 1 | calls 2 and 3 |
|---|---|---|
| lsh3, chain | 328 | 400 |
| bnot | 342 | 400 |
| bnotx | 342 | 400 |
| bxorm1 | 381 | 400 |
| lsh35 | 327 | 400 |
| nested, reassoc | 343 | 400 |
| u8sh30 | 338 | 394 |
| vlsh | 359 | 416 |
| vrsh | 66 | 78 |

    The first-call counts move by a few between runs. The E rows and the controls show 0 wrong.
  - cseir FAILs 18 cases per set (1 under -O1 and -O-narrow), each with served 2 and split 0.
  - t_cserev FAILs its 4 reverse cases in the 10 sets that judge them: rserved 2, split 0, i64slot 0. Its values equal -joff in all 15 sets, and PUC equals -joff.
- **proto-fix**: the `cse` part PASSes in 5 runs. t_csefwd shows 0 wrong in 15 sets with 18 of 18 pairs formed, served 0, split 36. cseir is 28/28 in 12 sets. t_cserev shows split 2 and rserved 0. The full seven-part default run PASSes in 68 s (full-proto-1).
- **proto-fwd** (CSEFWD text): t_csefwd and cseir FAIL exactly as on base; t_cserev PASSes (cse-fwdsab-1).
- **i64slot is 0 in all 456 case-runs** on each of base-Windows, base-Alma, proto-fix and proto-fwd.
- The `cse` part takes 8-12 s.

**Fail-firsts [M runs/ff-*, mutated copies made by scripts/ffmut.py; none writes a reverse case]:**

| mutation | expected | rc |
|---|---|---|
| fwd-joffref | FAIL: -joff exits 1 | 1 |
| fwd-doctor | FAIL in 15 sets | 1 |
| fwd-jitoff | PROVED NOTHING | 2 |
| fwd-nopairs | PROVED NOTHING | 2 |
| fwd-textcheck | PROVED NOTHING | 2 |
| ir-doctor | FAIL, values differ in 12 sets | 1 |
| ir-nosummary | PROVED NOTHING | 2 |
| ir-nocse | PROVED NOTHING | 2 |
| ir-nosplit (on proto) | cseir and t_cserev FAIL with "split 0" alone | 1 |
| ir-numslot | every case FAILs on i64slot | 1 |
| ir-noserved (on base) | still FAILs: 16 cases on pre+split, 2 on split | 1 |
| ir-nojudge | PROVED NOTHING | 2 |
| rev-doctor | FAIL | 1 |
| rev-joffdoctor | FAIL against -joff and PUC | 1 |
| rev-pucdoctor | FAIL against PUC | 1 |
| rev-nosummary | PROVED NOTHING | 2 |
| rev-nonarrow | PROVED NOTHING (judged 0 of 4) | 2 |
| rev-textcheck | PROVED NOTHING | 2 |
| nofile | SETUP FAIL | 2 |

cseir refuses -O0, -O-fold and -O-cse on base with rc 2 [M smoke-base-1].

FILES:
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/test/native/bitop/t_csefwd.lua
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/test/native/bitop/cseir.lua
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/test/native/bitop/t_cserev.lua
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/test/native/run-bitjit.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/run-bitjit.diff
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/deliverables.md5
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/scripts/proto-apply.py
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/scripts/proto-build.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/scripts/csepart.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/scripts/ffmut.py
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/scripts/ffrun.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/scripts/alma-cse.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/scripts/bytecount.py
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/runs/
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/proto-fix/
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/proto-fwd/

REST:
{
 "open_points": [
  "Decision for the main session: under D2 I put t_cserev into the default `cse` part with no gate. The design's separate gated `cserev` part, its gate, the logging stand-in and 'never by default' are not built. Reason: T3-lite's shapes are safe on any build, argued in its header and measured on base: i64slot 0, values equal -joff, rserved 2. It also has to run on build/native as its own fail-first. As a result negctl's canon and every arm will run t_cserev; it passes on CSEFWD [M cse-fwdsab-1].",
  "Scope check on R6: besides string.byte(S, i + i), t_cserev has r6-sub, which is string.sub(S, i + i, i + i) and has the same consumers. It also has r6-mul, string.byte(S, i * 2), the narrow_conv_emit route that the design's G2 row lists. Both are argued in the header from the same recff_string_range lines. Confirm they fall inside D2's 'R6'.",
  "Path correction: run-bitjit.sh is test/native/run-bitjit.sh, not test/native/bitop/run-bitjit.sh. My copy and its diff (run-bitjit.diff) are against 27b8262d. That is the same file at both 1a13bed and 60a24ec (HEAD moved during the round; test/ and native/ were not touched).",
  "For integrate (negctl): CSEFWD's catchers are cse:t_csefwd and cse:cseir. The runner prints '^FAIL t_csefwd (' and '^FAIL cseir (', the greps the design names. A setup failure such as 'FAIL t_csefwd: -joff exited' does not match, as in the nc convention. 'cse' still has to be added to rcof, runcatchers, check, info's awk, canon's catcher list and the header. CSEFWD is measured only on my hand-applied prototype, one run; negctl margins over 3 runs are integrate's job. The runner header's sentence about the CSEFWD prototype should then be replaced with those margins.",
  "The prototype objects (a6c5fcc2 fix, ccf83851 CSEFWD) were built by hand-applying the design's 2.1 text to a scratch copy. impl-code's hunk-12 build should be run through `OCLJ_BUILD=<its build> sh test/native/run-bitjit.sh` with OCLJ_BITJIT_PARTS=cse, and with all parts. I did not compare it with my prototype.",
  "AlmaLinux 8: I ran only the base build there; its `cse` part FAILs with the same counts as on Windows [M alma-base-1]. The fixed .so in Alma, run with `cse`, belongs to integrate. scripts/alma-cse.sh can be reused with another OCLJ_BUILD.",
  "Which checks fail alone (written into cseir's header): split, i64slot, the summary line and the 'judged' gates each fail alone. served fails alone on no measured build: base also fails split and pre. served is kept for its message. rserved fails only together with split 0.",
  "The t_csefwd case names map to the design's IDs: lsh3=F1, bnot=F2, bnotx=F3, bxorm1=F4, lsh35=F5, vlsh+vrsh=F6, u8sh30=F7, nested=F8, reassoc=F9, chain=F10, lsh1=E1, band=E2, rsh5=E3, select=E4, byte2+sub2=E5, forin=E6, c1=C1. Every [I] prediction in design 4.2 now has a measurement: F3-F10 are wrong on base, E1-E6 equal.",
  "Under -O1 and -O-narrow the loop index stays a double, so only u8sh30's pair forms and t_cserev judges no case; under -O-cse split appears on every build. Only the default run's gates (cseir 18/18, t_cserev 4/4, t_csefwd pairs \u2265 1) prove that pairs formed. A first-call count can move by a few between runs (P6); later calls are deterministic.",
  "The docs phase needs: guide 11.5d (the `cse` part), 11.8 rows for these fail-firsts, appendix A for the three files, and the header text of t_cserev's argument. The facts are in the files' MEASURED paragraphs."
 ]
}
