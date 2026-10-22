# 2026-10-21 -- FIX-NUMCONV: an identity bit operation on a double keeps no result guard that cannot fail

The evidence behind roadmap row 211 (5) (FIX-NUMCONV), the upstream part of row 213 (LuaJIT#1535, fixed upstream
by `a4c0645`) and row 270 (the pin-move plan), and behind [docs/jit-guide.md](../../../docs/jit-guide.md) 3.10,
3.11, 11.4, 11.5c, 11.7, P54 and P60-P62. Step 1 measured and argued the rule on 2026-10-21, step 2 built it the
same day and the next, and its follow-up ran on 2026-10-22; the final check and the release ran 2026-10-21
23:04-23:50Z, which was 2026-10-22 on the machine's clock. The directory carries the round's start date.

- **The rule.** An identity bit operation on a double (`x | 0`, `x & -1`, `x ~ 0`, `x << 0`, `x >> 0`) is
  recorded as `(i64)(num)y` over y, an unguarded `CONV i64.num` of the double, and kept a result guard
  (y's value must be exact in a double) that cannot fail on x64: `cvttsd2si` gives the operand's truncation or
  `INT64_MIN`, and both are exactly doubles. `simplify_conv_i64_num` now folds `(i64)(num)y` to y when y is
  such a conversion (`native/luajit/patch-bitop-fold.sh` hunk 7, a line of its own after the width rule;
  `oclj_isnumconv` in `native/luajit/oclj_bitop_fold.c`, compiled under `-Wall -Wextra` by
  `native/build-native.sh`'s `bitop_wgate.c`). It is a fact of exactness, not of range, so it never enters
  `oclj_bitwidth`, and it is x64's (`design/argument.md`). Only `lj_opt_fold.o` changes, on Windows and on
  Linux.
- **Its tests.** `test/native/bitop/t_numconv.lua` (75 cases against `-joff` under 15 option sets and against
  PUC 5.3.6) and `test/native/bitop/ncir.lua` (the guards the rule removes, counted in the compiled loops
  under 13 option sets), in `run-bitjit.sh`'s part 6, `nc`, in its default parts.
- **Its arms.** `negctl-bitop.sh`'s NUMCONVOP1, NUMCONVW and NUMCONVOFF (the nc part's), and NUMCONVNOOP
  (the predicate's opcode test removed, caught by the generator), 36 arms in all. NUMCONVNOOP was added by
  the main session in the follow-up, correcting its own claim that none of the predicate's tests could be
  shown to matter; the user may drop it.
- **The round** (three workflows, 16 agents; `design/reports.json`, `design/commit-facts.md`,
  `design/commit-facts-2.md`, which wins where they differ): step 1, a prototype, the soundness argument and a
  refutation sweep in parallel; step 2, the code and the tests in parallel, then negctl, the docs, a code and a
  docs verifier, a fixer; the follow-up, the NUMCONVNOOP arm beside the upstream docs, the arm's docs, an arm
  and a docs verifier, a fixer.
- **Upstream** (`upstream/`). LuaJIT#1535, the select divergence the user reported on 2026-10-21, was fixed by
  `a4c0645` the same day. The main session built stock `a4c0645` GC64 and non-GC64 in WSL Ubuntu: the issue's
  reproducer gives the interpreter's output with the JIT on, and vsel differs from `-joff` in 0 of 209 cases in
  all 21 option sets (`up-4/`, judged by `check4.py`, which fails on the earlier tip `95f931c`'s outputs,
  `ff-check4/`). The syntax probe (`syn/`) compares the shipped build, stock `1ee778a4` and `a4c0645` on 23
  cases of v3.0's syntax backports. The census (`census/`) ran the twelve patch scripts on `a4c0645`'s tree
  without building: eleven apply, and `patch-bitop-record.sh` refuses at hunk 5, the select fix that upstream
  replaced.

## Results

**The final check** (`scripts/final-check.sh`, md5 `e0f1797a`, run by the main session on the working tree,
2026-10-21 23:04-23:25Z; `logs/final-main/`): **80 PASS, 0 FAIL, 0 SKIP in 1267 s.**

| group | lines | what passed |
|---|---|---|
| build (Windows) | 9 | build-native.sh, additive, into a fresh `OCLJ_BUILD`: rc 0, the pin met and the export verified, nothing ignored from the environment, the patch line (70 added, 8 removed, of 2715), round 3's C files at 0 warnings with `bitop_wgate.c` calling `oclj_isnumconv`; of 77 LuaJIT objects only `lj_opt_fold.o` differs from `build/native`'s, and it is the implementer's `f6d916e2`; our 3 equal; the build copy's `lj_opt_fold.c` is `3b11930f` |
| AlmaLinux 8 | 15 | the same with `OCLJ_GLIBC_MAX=2.28` (needs GLIBC_2.17; `lj_opt_fold.o` `57970a51`); run-bitjit.sh's six parts with the Linux PUC, t_numconv at 0 in all 15 sets, ncir at 0 in all 13; the generator's idx, rg2 and phi modes; the fail-first: the nc part on `build/native`'s Linux luajit fails at ncir in all 13 sets, t_numconv and PUC passing |
| bitjit | 5 | run-bitjit.sh's six parts (gen, floor with t_rg2, fix1, idx, sel, nc) with PUC; the generator's idx, rg2 and phi modes, four seeds each |
| base | 1 | the fail-first on `build/native`'s Windows natives: ncir fails in all 13 sets (17-22 of its 29 cases a set), t_numconv and PUC passing: the rule changes no value |
| irident | 4 | step 1's `ir_ident.lua` on both builds: the identities' result guards 0 on the new build and 1 on the base, the cancellations' and controls' as expected; each build's output read as the other's fails |
| suites | 2 | run-bitop.sh, run-bitfuzz.sh |
| negctl | 6 | the arm list (exactly 36 arms) and canon's catcher list; the full 36-arm `negctl-bitop.sh` sweep in one call, 768 s: canon (99 s), every arm caught at its named catchers (NUMCONVOP1 and NUMCONVW by `nc:t_numconv nc:ncir`, NUMCONVOFF by `nc:ncir`, 9 s each; NUMCONVNOOP by gen, 20-26 cases a seed, 36 s), restore |
| runners | 9 | run.sh, run-mem, run-vgc, run-wd, run-penalty, run-race, run-security, run-pack, run-packfuzz |
| hygiene | 21 | exactly the round's ten files changed; 0 CR bytes in each; `git diff --check`, and its `--no-index` form on the two new files; `sh -n` in Git Bash, AlmaLinux 8's sh and Ubuntu's dash; the hunk engine of all seven patch scripts unchanged; build-native.sh differing from HEAD by its `bitop_wgate.c` lines only; no tab or backslash in the patch script, no backslash in the new tests or `oclj_bitop_fold.c`; the patch script on the pin's pristine blob (counts, idempotence, the build copy's bytes) and its refusal of a call nested in the width rule's `if`; no private path and no email address in the added lines; the guide's md5s of the new tests; 116 line cites by content (115 fail moved one line either way), 431 anchors and 44 tables |
| timing | 4 | see below |
| census | 4 | `build/` (md5 of each of 39456 files) and the pristine checkout unchanged; the changed files, the script and its helpers unchanged during the run |

**The timing.** The speed claim is step 1's [M: `logs/step1-timing/`; `scripts/step1/timing-chain.sh` and its
benches; 20 rounds alternating with `build/native` on 2026-10-21 08:55-08:57Z, CPU load 12% before and 9% after,
no JVM running, every result equal], on the prototype's build, whose rule is the shipped one in an
`LJ_AINLINE` helper. The final check repeated its two benches on the shipped object as a smoke reading [M:
`logs/final-main/timing/`; 8 rounds alternating at the check's end, 23:25Z, CPU load 5% before and 1% after, no
JVM running, every result equal]. Medians, ns per iteration, and new/base:

| rows | what they time | step 1 (20 rounds) | final check (8 rounds) |
|---|---|---|---|
| `ident.lua`, ten rows | `x \| 0`, `x & -1`, `x ~ 0`, `x << 0`, `x >> 0` on doubles past 2^53 and small | 1.10 to 0.90, 0.82 [0.73-0.91] | 1.10 to 0.90, 0.818 in every row |
| arith | `x \| 0` on a double, in a sum | 0.75 to 0.60, 0.80 | 0.800 |
| key | as a table key | 0.88 | 0.885 |
| bits | feeding two more bit operators | 0.93 | 0.927 |
| floor | after `math.floor` | 0.97 | 0.972 |
| ref and the controls | no bit operator; crc-table, the table-index fold's rows, a three-xor chain | 1.00 | ref 1.000 |

The final check's bound is only against a gross change (each median ratio within [0.5, 2.0]): os.clock steps by
1 ms on Windows.

**The release** (`scripts/release.sh`, after the final check; `logs/release/`) [M]:
- `build/native` rebuilt, dropin then additive, on Windows and in AlmaLinux 8 with `OCLJ_GLIBC_MAX=2.28`. All 80
  objects of each platform's additive tree equal the final check's builds. Both dist natives carry
  `1ee778a4|LuaJIT 2.1.ROLLING|412be694|ffi0.lua52.gc64.fr2.dn0.le.p64.pack1.bit64`, and the .so needs GLIBC_2.17
  at most. The dist DLL is now `9ac03aeb` (it was `b5ff2d18`), the .so `f91700bd` (`9247cbfd`).
- The JVM harness, one JVM at a time, on the frozen natives: the seven arms on Windows and the seven in AlmaLinux 8
  read exactly what the glibc, CRC32 and select rounds' did: additive with the JIT on 82 checks, dropin 69,
  additive with the JIT off 80, sieve 76, stock 53, disposeoff 82, and bundleoff 82 with its 3 expected failures
  (stk-2, stk-3, stk-4).
- gradle `verifyModAssets` and `build`: rc 0; the jar `ocluajit-209aa95-master+209aa9579a-dirty.jar` is
  `81648991`, and it carries the DLL `9ac03aeb` and the .so `f91700bd`.

## Files

| path | what |
|---|---|
| `logs/final-main/` | the final check: `summary.txt` (one line per check), `ALL.done`, `logs/` (every build, suite, negctl and runner log, `timing.txt` with each part's seconds, and `checks.log`), `rc/`, `cmp/` (object lists, cites, anchors, tables, arm lists, the added lines), `alma/` and `ubuntu/` (the Linux parts), `runs/irident/` (ir_ident's outputs on both builds), `negctl-work/` (the sweep's summary and, for canon, restore and each arm, its logs and object md5s, with the catchers' per-seed counts), `timing/` (`raw.txt`, `summary.txt`), `ps/` (the patch script's runs), `census/digest.txt`, `md5-start.txt` and `md5-end.txt` |
| `logs/release/` | `release.log`, the builds' logs and md5 lists, the object comparisons (`win-*.md5`, `linux-*.md5`), `frozen.md5`, `harness-win/` and `harness-alma/` (each arm's `run.log`, `args.txt`, `native.md5`, `exit.txt` and times), the gradle logs, `jars.md5` |
| `logs/step1-timing/` | step 1's timing chain: `raw.txt`, `summary.txt`, `progress.txt`, `inputs.md5`, the CPU loads and the JVM check |
| `scripts/` | `final-check.sh` and its helpers (`fc-summarize.py`, `fc-citecheck.py` with `fc-negctl-e5838e14.sh`, the follow-up's starting `negctl-bitop.sh`, which it reads, `fc-anchorcheck.py`, `fc-tablecheck.py`, `fc-irident.py`, `fc-ir_ident.lua`, `fc-nestn7.py`), `release.sh`; `step1/` (the timing chain, `summarize.py` and the five benches) |
| `design/argument.md` | step 1's soundness argument: why the removed guard cannot fail on x64, and why only there |
| `design/reports.json` | every agent's returned report, as returned, by workflow |
| `design/commit-facts.md`, `commit-facts-2.md` | the two fixers' facts for the commit message, written before the final check; the second wins where they differ |
| `upstream/` | `up-4/` (stock `a4c0645`, GC64 and non-GC64: the reproducer, vsel's 21 sets, konst), `ff-check4/` (`95f931c`'s outputs, `check4.py`'s fail-first), `check4.py`, `build-up3.sh`; `syn/` (`probe.lua`, `build-syn.sh`, `up-1/` with stock `1ee778a4` and `a4c0645`, `shipped-2/` with `build/native`'s luajit.exe); `census/` (both trees' verdicts and per-script outputs, the hunk counts, the negctl anchors, check4's re-run, the probe of `2a8e017`'s and `849bbbe`'s old behaviour on the shipped build, and the census scripts) |
| `DIGESTS.txt` | each file not copied (md5, bytes, lines, its place here, its scratch source), and the two files archived with a redaction |
| `MANIFEST.txt` | every file here with its md5 and size |

Not archived:
- the binaries and build trees (the final check's `b/`, `alma/b`, the sweep's work directory beyond its logs and
  md5 lists), the runners' and generator's outputs (`runs/` but `runs/irident/`, and `alma/`'s; the logs keep
  each run's verdict and counts), the harness arms' `work/` directories, and the frozen natives
  (`claude-tmp/oclj/new-nc-9ac03aeb`, `new-nc-linux-f91700bd`);
- LuaJIT's sources, pristine, patched or upstream's (the hygiene part's `ps/*.c`, `a4c0645`'s `lj_record.c`
  that `fc-citecheck.py` reads, the two backport diffs), the tar files and the 46 vsel outputs of 433 KB each:
  `DIGESTS.txt` keeps their md5s; the draft of the upstream issue (`issue.md`), which is public as LuaJIT#1535;
- the full census files, of which `census/digest.txt` keeps each one's line count and md5;
- the machine's process lists, which the check and the release record beside their Java checks;
- the agents' scratch evidence, which the docs cite by path under `claude-tmp/oclj/numconv/` and
  `claude-tmp/oclj/sel/upreport/`;
- the scripts that made this archive and checked the commit (`claude-tmp/oclj/numconv/main/mkarchive.py` and
  `finalize.py`): they hold the patterns they scan for.

`scripts/final-check.sh` and `logs/final-main/logs/checks.log` hold, in the run, the pattern of the check that no
private scratch path reached the added lines; here it reads `PRIVATE-SCRATCH-PATHS`, and `DIGESTS.txt` gives
both md5s. Two sentences of the agents' reports, each quoting a pattern of the check for the user's address,
were dropped. 100 logs'
CRs (gradle's and a few Windows tools') were converted to LF for the repo.

Repo files at the final check (md5): `native/luajit/patch-bitop-fold.sh` `08c242a5`,
`native/luajit/oclj_bitop_fold.c` `28e403c8`, `native/build-native.sh` `ae218485`,
`test/native/bitop/t_numconv.lua` `de0d14e9` (new), `test/native/bitop/ncir.lua` `baaa4490` (new),
`test/native/run-bitjit.sh` `27b8262d`, `test/native/negctl-bitop.sh` `0e453ecb`,
`test/native/bitop/t_idx2.lua` `f6b9115c` (its header only); `docs/jit-guide.md` `3620c612` and
`docs/roadmap.md` `53a8316a`, which after the run gained the final check's and the release's results.
