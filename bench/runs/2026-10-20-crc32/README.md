# 2026-10-20 -- the CRC32 follow-up, round 1: the table-index fold ships, the range guard does not, and row 209 stays open

The evidence behind roadmap row 209's "Status 2026-10-20", row 211's item (5) and row 213, and behind
[docs/jit-guide.md](../../../docs/jit-guide.md) 8.8, 11.5a, P53-P58 and open questions 16-18.

- **The problem.** Round 3's 64-bit operators cost table-driven CRC32 7.2 ns per byte, against 2.8-2.9 with
  round 2's 32-bit ones, and bit-serial CRC32 70 against 48-49 (`bench/runs/2026-10-17-bitop`). Round 3's
  review had prototyped two changes on an earlier build: a speculative range guard in the integer domain (rg2)
  and a fold of `CONV int.num (CONV num.i64 y)` for a small y (the table-index fold, "fold a").
- **The design pass** (five agents: a prototyper and an adversarial verifier for each change, then a combiner)
  ported both to this build as patch-script changes, with tests and sabotage arms, and found no input on which
  either computes anything the interpreter does not (`design/design.md`, `design/reports-design.json`). The
  main session timed four builds of the pin, which differ only in `lj_opt_fold.o`, and PUC 5.3.6
  (`logs/design-chain/`), and round 2's b0 beside them (`logs/design-b0/`).
- **The user's decisions (2026-10-20):** ship the table-index fold only; it never crosses a PHI; rg2 does not
  ship, but its 2^53-boundary tests stay; FIX-NUMCONV is a later round of its own; row 209 stays open for
  bit-serial CRC32 and table-driven CRC32's last quarter; an upstream divergence in compiled `select`, found by
  a verifier, is recorded as row 213 and fixed in its own round, next.
- **The implementation** (five agents: an implementer, a docs agent, a code verifier and a docs verifier in
  parallel, a fixer; `design/reports-impl.json`, `design/commit-facts.md`) changed `patch-bitop-fold.sh`
  (hunk 11, 63 lines added and 8 removed on the pin's `lj_opt_fold.c`), `oclj_bitop_fold.c`'s header, the
  bit-operator runners and suites, and the docs. `native/build-native.sh` is unchanged (`47b9c52e`); only
  `lj_opt_fold.o` changes, on Windows and on Linux.

## Results

**The speed** [M]. Medians in ns per byte (CRC rows) or per iteration, and ratios to the build without the fold
in the same round, median [min-max]; on these benches, on this machine:

| row | before | with the fold | ratio | round 2's b0 | PUC 5.3.6 |
|---|---|---|---|---|---|
| table-driven CRC32 (`bench_bit2.lua` crc-table, row 209's number), design chain | 7.20 | 3.70 | 0.51 [0.50-0.51] | 2.90; the fold 1.28 of it [1.24-1.28] | 32.40 |
| the same, final check | 7.30 | 3.70 | 0.51 [0.49-0.52] | 2.90; the fold 1.31 of it [1.24-1.33] | 32.50 |
| the other table-driven CRC32 loops (`bench_crcx.lua` crcprobe and crcmb, `bench_idx.lua` crct and crctm), design chain | 7.20-7.50 | 3.70-3.90 | 0.51-0.52 | | 32.3-35.1 |
| bit-serial CRC32 (`bench_bit.lua` crc), design chain | 69.50 | 70.00 | 1.00 [0.98-1.01] | 48.50; the fold 1.44 of it [1.43-1.47] | 120.50 |
| the same, final check | 70.00 | 70.50 | 1.01 [0.99-1.01] | 49.00; the fold 1.45 of it [1.44-1.45] | 120.50 |
| `bench_spec.lua` mix / flag63, design chain | 4.25 / 1.50 | 2.80 / 0.75 | 0.66 / 0.50 | | 19.25 / 12.90 |
| `ident.lua`'s ten identity rows, design chain | 1.80 | 1.10-1.20 | 0.61-0.63 | | 13.6-16.1 |
| `bench_idx.lua` phi2, the one shape the fold could slow, design chain | 4.20 | 4.10 | 0.98 [0.95-1.00] | | 17.60 |

Every other row read 1.00-1.02 in the design chain. The final check's ratios agree with the design chain's,
except two rows near 0.7 ns per iteration, where one os.clock step of 0.05 ns moves a ratio by 7% (half 1.08,
top8 0.93). Every result was equal across the builds in every round. The design chain ran 2026-10-20
14:17-14:24Z at CPU load 7-9%, the final check's timing 17:51-17:56Z at 4%, with no Java running either time.

**rg2, measured and not shipped** [M: `logs/design-chain/summary.txt`]. On top of the fold it bought
crc-table 0.97, mix 0.79 and ident's small rows 0.82-0.91. On loops whose exact results leave [-2^53, 2^53),
legal under round 3's rule, it cost hi60 6.64x, sh40 7.31x, top8 5.0x, half 3.64x and flag63 3.17x of base
(6.27x of the fold alone), and ident's big rows 2.0x; with `-Omaxside=0`, hi60 took 11.5 ns against 0.5.

**The final check** (`scripts/final-check.sh`, md5 `ea8360ca`, run by the main session on the working tree;
`logs/final-main/`): **57 PASS, 0 FAIL, 0 SKIP in 1645 s.**

| group | lines | what passed |
|---|---|---|
| build (Windows) | 6 | build-native.sh, additive, into a fresh `OCLJ_BUILD`: rc 0, the pin met and the export verified (8 trees, 232 files), nothing ignored from the environment, the patch line (63 added, 8 removed); of 77 LuaJIT objects only `lj_opt_fold.o` differs from `build/native`'s (`1d018acc` against `03fa01f5`), and our 3 are equal |
| AlmaLinux 8 | 10 | the same with `OCLJ_GLIBC_MAX=2.28` (needs GLIBC_2.17; `lj_opt_fold.o` `33a2cc50`); run-bitjit.sh's four parts with the Linux PUC; the generator's idx and rg2 modes, seeds 1-4 |
| bitjit | 4 | run-bitjit.sh's four parts (gen, floor with t_rg2, fix1, idx) with PUC; the generator's idx, rg2 and phi modes, four seeds each |
| suites | 2 | run-bitop.sh, run-bitfuzz.sh |
| negctl | 4 | the full 30-arm `negctl-bitop.sh` sweep in one call, 843 s: canon, every arm caught at its named catchers, restore |
| runners | 9 | run.sh, run-mem, run-vgc, run-wd, run-penalty, run-race, run-security, run-pack, run-packfuzz |
| gen | 1 | the generator's identity: 24 mode-seed pairs byte-identical to each mode's reference |
| hygiene | 12 | 0 CR bytes in 14 changed files; `git diff --check`; `sh -n` in Git Bash, AlmaLinux 8's sh and Ubuntu's dash; the hunk engine of all seven scripts and `build-native.sh` unchanged; the patch script on the pin's pristine blob (counts, idempotence, the build copy's bytes, no tab or backslash) |
| timing | 5 | the benches are the design chain's; base is its base; 7 rounds; every result equal; crc-table's ratio 0.507 |
| census | 4 | `build/` (md5 of every file) and the pristine checkout unchanged; the changed files and the script unchanged during the run |

**The release** (`scripts/release.sh`, after the final check; `logs/release/`) [M]:
- `build/native` rebuilt, dropin then additive, on Windows and in AlmaLinux 8 with `OCLJ_GLIBC_MAX=2.28`. All
  80 objects of each platform's additive tree equal the final check's builds. Both dist natives carry
  `1ee778a4|LuaJIT 2.1.ROLLING|412be694|ffi0.lua52.gc64.fr2.dn0.le.p64.pack1.bit64`, and the .so needs
  GLIBC_2.17 at most. The dist DLL is now `c5fe96fc` (it was `3174ef37`), the .so `da5a3b13` (`6c888050`).
- The JVM harness, one JVM at a time, on the frozen natives: the seven arms on Windows and the seven on
  AlmaLinux 8 read exactly what the glibc round's did: additive with the JIT on 82 checks, dropin 69,
  additive with the JIT off 80, sieve 76, stock 53, disposeoff 82, and bundleoff 82 with its 3 expected
  failures (stk-2, stk-3, stk-4).
- gradle `verifyModAssets` and `build`: rc 0; the jar `ocluajit-eb47daf-master+eb47daf260-dirty.jar` is
  `8609bec9`.

## Files

| path | what |
|---|---|
| `logs/design-chain/` | the design pass's timing chain (`scripts/timing-chain.sh`, md5 `1f17a792`), 9 rounds, five VMs: `summary.txt`, `raw.txt`, `inputs.md5`, `progress.txt` |
| `logs/design-b0/` | `scripts/b0-companion.sh`, 5 rounds, round 2's b0 beside three of the builds; `summary.txt` is `scripts/b0sum.py`'s |
| `logs/final-main/` | the final check: `summary.txt` (one line per check), `ALL.done`, `logs/` (every build, suite, negctl and runner log), `rc/`, `cmp/`, `alma/` and `ubuntu/` (the Linux parts), `timing/` (`raw.txt`, `summary.txt`), `gen/pairs.txt`, `ps/` (the patch script's runs; `c-files.md5` for its outputs), `census/digest.txt`, `md5-start.txt` and `md5-end.txt` |
| `logs/release/` | `release.log`, the builds' logs and md5 lists, the object comparisons (`win-*.md5`, `linux-*.md5`), `frozen.md5`, `harness-win/` and `harness-alma/` (each arm's `run.log`, `args.txt`, `native.md5`, `exit.txt` and times), the gradle logs, `jars.md5` |
| `scripts/` | `timing-chain.sh`, `summarize.py`, `pairratio.py`, `b0-companion.sh`, `b0sum.py`, `bench/` (the six benches), `gencheck.sh`, `final-check.sh` and `fc-summarize.py`, `release.sh` |
| `design/design.md` | the design pass's combined record: what each change does, the evidence, the decisions, the 37 guide gaps |
| `design/reports-design.json`, `design/reports-impl.json` | every agent's returned report, both workflows |
| `design/commit-facts.md` | the fixer's facts for the commit message, written before the final check |
| `MANIFEST.txt` | every file here with its md5 and size |

Not archived:
- the binaries and build trees (the final check's `b/`, `alma/b`), the runners' and generator's outputs
  (`runs/`, generated case files), the harness arms' `work/` directories, and the frozen natives
  (`claude-tmp/oclj/new-crc-c5fe96fc`, `new-crc-linux-da5a3b13`);
- the full census files, of which `census/digest.txt` keeps each one's line count and md5;
- the machine's process lists, which the chains record beside their Java checks;
- the agents' scratch evidence, which the docs cite by path under `claude-tmp/oclj/crc/` (the design pass)
  and `claude-tmp/oclj/crc2/` (the implementation);
- the script that made this archive (`claude-tmp/oclj/crc2/main/mkarchive.py`, md5 `2ebdccb4`): it holds the
  patterns it scrubs. The agents' reports are as returned, except that sentences naming a scratch directory
  kept out of the repository, and one link to a private claude.ai artifact, were removed.

24 logs' CRs (gradle's and a few Windows tools') were converted to LF for the repo.

Repo files at the final check (md5): `native/luajit/patch-bitop-fold.sh` `149187d8`,
`native/luajit/oclj_bitop_fold.c` `1ac93081`, `native/build-native.sh` `47b9c52e` (HEAD's),
`test/native/run-bitjit.sh` `103529a4`, `test/native/negctl-bitop.sh` `7d125177`, `test/native/bitop/gen.lua`
`ce4671e9`, `twin.lua` `216a844b`, `t_idx.lua` `1281747f`, `t_cnt33.lua` `b5dc9e14`, `t_idx2.lua` `b7393359`,
`phiidx.lua` `c3e47b74`, `t_rg2.lua` `c690d89c`, `CLAUDE.md` `45b861fb`; `docs/jit-guide.md` `2c1d57a5` and
`docs/roadmap.md` `6fa66b3c`, which after the run gained the final check's and the release's results and the
pointers to this archive.
