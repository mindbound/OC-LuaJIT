# 2026-10-21 -- the select fix: compiled `select(k, ...)` gives the interpreter's results and errors

The evidence behind roadmap row 213 (and the new row 214), and behind [docs/jit-guide.md](../../../docs/jit-guide.md)
P54, P59, 11.5b, 8.5 step 2, 8.6 step 7 and 3.13's bullet on narrowing's wrapped index. The fix was written on
2026-10-20; the final check and the release ran 2026-10-20 22:08-22:56Z, which was 2026-10-21 on the machine's
clock, the date this directory carries.

- **The problem.** The CRC32 follow-up's verifier found that compiled `select(k, ...)` returned nil for
  `k = -2147483628` where `-joff` raises "index out of range" (`probes/selbug.lua`, here `scripts/fc-selbug.lua`).
  The divergence is upstream LuaJIT's: the 2026-09-01 upstream binary behaves alike, and `rec_varg` at upstream's
  v2.1 tip `dd3b243` (2026-10-18) is the pin's, byte for byte. No path loads through a wrapped index: path C,
  beyond the varargs, loads nothing, and the only load sits behind an unsigned bounds check on k-1 or a guard
  against a record-time constant [S: `rec_varg`, read by the main session, the implementer, the sweep, both
  verifiers and the fixer before any wrapping index ran on a build without the fix].
- **The round** (one workflow, six agents: an implementer beside a read-only sweep of sibling 32-bit index
  arithmetic, a docs agent, a code verifier and a docs verifier in parallel, a fixer; `design/reports.json`,
  `design/commit-facts.md`) found three classes of k, not one: a k whose 8k wraps past the frame; with no wrap, a
  k from m+1 to 0 in a call with fewer arguments than fixed parameters; and a k that narrowing's unchecked
  outermost ADD or SUB wrapped. A guard of k >= 1 alone, built as a variant, still differed from `-joff` in 11 of
  15 option sets.
- **The fix.** `native/luajit/patch-bitop-record.sh` hunks 4 and 5 (22 lines added and 36 removed on the pin's
  `lj_record.c`, round 3's 7/35 plus 15/1): `OCLJ_SELECT_KMAX`, 2^27; the recorder aborts for a recorded k above
  it; and on path C a guard `ULT k-1, 2^27` comes before the 32-bit shift. Only `lj_record.o` changes, on Windows
  and on Linux; `native/build-native.sh` is unchanged (`47b9c52e`).
- **Its tests.** `test/native/bitop/t_select.lua` (110 cases) and `run-bitjit.sh`'s part 5, `sel`, in its
  default parts (15 option sets against `-joff`, PUC 5.3.6 on part `puc`, a coverage gate, `t_select-kmax`);
  `negctl-bitop.sh`'s arms SELGUARD and SELRECK, 32 arms in all.

## Results

**The final check** (`scripts/final-check.sh`, md5 `d45910e9`, run by the main session on the working tree,
2026-10-20 22:08-22:31Z; `logs/final-main/`): **69 PASS, 0 FAIL, 0 SKIP in 1397 s.**

| group | lines | what passed |
|---|---|---|
| build (Windows) | 7 | build-native.sh, additive, into a fresh `OCLJ_BUILD`: rc 0, the pin met and the export verified, nothing ignored from the environment, the patch line (22 added, 36 removed, of 2966); of 77 LuaJIT objects only `lj_record.o` differs from `build/native`'s, and it is the implementer's `c536c2b9`; our 3 equal; the build copy's `lj_record.c` is `d490af9b` |
| AlmaLinux 8 | 12 | the same with `OCLJ_GLIBC_MAX=2.28` (needs GLIBC_2.17; `lj_record.o` `a8e738ca`); run-bitjit.sh's five parts with the Linux PUC, t_select at 0 in all 15 sets; the generator's idx and phi modes; the fail-first: the sel part on `build/native`'s Linux luajit fails in all 15 sets (15-52 cases a set) and `t_select-kmax` in 2-3 loops a set |
| bitjit | 5 | run-bitjit.sh's five parts (gen, floor with t_rg2, fix1, idx, sel) with PUC, t_select at 0 in all 15 sets and the three k = 2^27 controls compiled; the generator's idx, rg2 and phi modes, four seeds each |
| base | 4 | the fail-first on `build/native`'s Windows natives: the sel part fails in all 15 sets (12-53 cases a set), `t_select-kmax` in 3 loops a set, PUC passing; selbug prints `n 30 E 200` there with the JIT on and `E 30 E 200` with it off, and `E 30 E 200` both ways on the fixed build |
| suites | 2 | run-bitop.sh, run-bitfuzz.sh |
| negctl | 5 | the full 32-arm `negctl-bitop.sh` sweep in one call, 870 s: canon (111 s), every arm caught at its named catchers (SELGUARD by `sel:t_select` in all 15 sets, 15-53 cases a set; SELRECK by `sel:kmax`, 3 of 3 loops a set, 2 under `noloop`; 9 s each), restore |
| runners | 9 | run.sh, run-mem, run-vgc, run-wd, run-penalty, run-race, run-security, run-pack, run-packfuzz |
| hygiene | 17 | exactly the round's seven files changed; 0 CR bytes in each; `git diff --check`, and its `--no-index` form on the new file; `sh -n` in Git Bash, AlmaLinux 8's sh and Ubuntu's dash; the hunk engine of all seven scripts and `build-native.sh` unchanged; no tab or backslash in the patch script, no backslash in t_select.lua; the patch script on the pin's pristine blob (counts, idempotence, the build copy's bytes); the guide's 89 line cites by content (88 fail moved down one line), its 388 anchors and 44 tables |
| timing | 4 | see below |
| census | 4 | `build/` (md5 of each of 39450 files) and the pristine checkout unchanged; the changed files, the script and its helpers unchanged during the run |

**The timing** [M: `logs/final-main/timing/`; `scripts/fc-bench_sel.lua`, six loops of select at N = 1e8, best
of 3 inside a run; 7 rounds, the order alternating, 22:30Z, CPU load 7% before and 14% after, no Java running].
Base is `build/native`'s luajit.exe (`lj_record.o` `81918b7d`), new the final check's build. Medians in ns per
iteration and new/base ratios, median [min-max]; every result was equal in every round:

| row | what it times | base | new | new/base |
|---|---|---|---|---|
| idx | `for i = 1, select('#', ...) do s = s + select(i, ...) end`: k within the 7 varargs (path B), per select | 0.70 | 0.70 | 1.000 [0.986-1.014] |
| cycle | `select(i % 7 + 1, ...)`: k cycling within them (path B) | 1.21 | 1.21 | 0.992 [0.992-1.008] |
| beyond | `select(K[1], ...)` with K[1] = 9: a loop-invariant k beyond them (path C), which the loop optimizer hoists, so the row reads about the bare loop | 0.38 | 0.38 | 1.000 [0.949-1.026] |
| vbeyond | `select(i % 7 + 8, ...)`: a k beyond them that changes every iteration, so path C's guards, the fix's among them, run in the loop body | 1.19 | 1.21 | 1.017 [1.000-1.017] |
| konst | `select(3, ...)`: a constant k (path A), hoisted | 0.39 | 0.38 | 1.000 [0.974-1.000] |
| count | `select('#', ...)`, hoisted | 0.38 | 0.38 | 1.026 [0.974-1.027] |

The check's bound is only against a gross change (each median ratio within [0.5, 2.0]): os.clock steps by 1 ms
on Windows, about 2.6% of a 0.38 ns row's 38 ms run. The fixer's smoke reading before the check agreed (vbeyond
1.017 [1.008-1.017]). The fix's guard costs 3 instructions, 18 bytes of machine code in a two-copy trace [M: the
code verifier, `design/reports.json`].

**The release** (`scripts/release.sh`, after the final check; `logs/release/`) [M]:
- `build/native` rebuilt, dropin then additive, on Windows and in AlmaLinux 8 with `OCLJ_GLIBC_MAX=2.28`. All 80
  objects of each platform's additive tree equal the final check's builds. Both dist natives carry
  `1ee778a4|LuaJIT 2.1.ROLLING|412be694|ffi0.lua52.gc64.fr2.dn0.le.p64.pack1.bit64`, and the .so needs GLIBC_2.17
  at most. The dist DLL is now `b5ff2d18` (it was `c5fe96fc`), the .so `9247cbfd` (`da5a3b13`).
- The JVM harness, one JVM at a time, on the frozen natives: the seven arms on Windows and the seven in AlmaLinux 8
  read exactly what the glibc and CRC32 rounds' did: additive with the JIT on 82 checks, dropin 69, additive with
  the JIT off 80, sieve 76, stock 53, disposeoff 82, and bundleoff 82 with its 3 expected failures (stk-2, stk-3,
  stk-4).
- gradle `verifyModAssets` and `build`: rc 0; the jar `ocluajit-e7eb613-master+e7eb613299-dirty.jar` is
  `44433955`.

## Files

| path | what |
|---|---|
| `logs/final-main/` | the final check: `summary.txt` (one line per check), `ALL.done`, `logs/` (every build, suite, negctl and runner log, and `checks.log`), `rc/`, `cmp/` (object lists, cites, anchors, tables, arm lists), `alma/` and `ubuntu/` (the Linux parts), `runs/selbug/` (selbug's outputs on both builds), `timing/` (`raw.txt`, `summary.txt`), `ps/` (the patch script's runs; `c-files.md5` for its outputs), `census/digest.txt`, `md5-start.txt` and `md5-end.txt` |
| `logs/release/` | `release.log`, the builds' logs and md5 lists, the object comparisons (`win-*.md5`, `linux-*.md5`), `frozen.md5`, `harness-win/` and `harness-alma/` (each arm's `run.log`, `args.txt`, `native.md5`, `exit.txt` and times), the gradle logs, `jars.md5` |
| `scripts/` | `final-check.sh` and its helpers (`fc-summarize.py`, `fc-bench_sel.lua`, `fc-selbug.lua`, which is verify-folda's `probes/selbug.lua`, `fc-citecheck.py`, `fc-anchorcheck.py`, `fc-tablecheck.py`), `release.sh` |
| `design/reports.json` | every agent's returned report, as returned |
| `design/commit-facts.md` | the fixer's facts for the commit message, written before the final check |
| `MANIFEST.txt` | every file here with its md5 and size |

Not archived:
- the binaries and build trees (the final check's `b/`, `alma/b`), the runners' and generator's outputs and the
  base build's sel outputs (`runs/` but `runs/selbug/`; the logs keep each run's verdict and counts), the
  harness arms' `work/` directories, the pristine LuaJIT sources the hygiene part read (`ps/*.c`, whose md5s
  `ps/c-files.md5` keeps), and the frozen natives (`claude-tmp/oclj/new-sel-b5ff2d18`, `new-sel-linux-9247cbfd`);
- the full census files, of which `census/digest.txt` keeps each one's line count and md5;
- the machine's process lists, which the check and the release record beside their Java checks;
- the agents' scratch evidence, which the docs cite by path under `claude-tmp/oclj/sel/` (the implementer's
  `impl/`, the sweep's `sweep/`, `docs/`, `verify-code/` with its 209-case `probes/vsel.lua`, `verify-docs/` and
  the fixer's `fix/` with its smoke runs);
- the scripts that made this archive and checked the commit (`claude-tmp/oclj/sel/main/mkarchive.py`, md5
  `fa27a1ab`, and `finalize.py`): they hold the patterns they scan for.

31 logs' CRs (gradle's and a few Windows tools') were converted to LF for the repo.

Repo files at the final check (md5): `native/luajit/patch-bitop-record.sh` `b218585d`,
`test/native/bitop/t_select.lua` `b2616108` (new), `test/native/run-bitjit.sh` `01cc9a17`,
`test/native/negctl-bitop.sh` `fbd42f2c`, `test/native/bitop/t_idx2.lua` `f60e7948` (its header only),
`native/build-native.sh` `47b9c52e` (HEAD's); `docs/jit-guide.md` `29844cd9` and `docs/roadmap.md` `53708b13`,
which after the run gained the final check's and the release's results.
