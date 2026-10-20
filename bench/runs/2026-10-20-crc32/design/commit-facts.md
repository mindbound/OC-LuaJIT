# Commit facts: the CRC32 follow-up, round 1 (roadmap row 209)

Facts a commit message needs, each marked [M] measured, [S] read in source,
[I] inferred, with the run, file or function behind it. Written by the fixer
(crc2/fix), 2026-10-20, on the working tree at HEAD eb47daf. Nothing was
committed; the user runs commit and push. The final check
(`crc2/fix/final-check.sh`) has NOT run end to end: its result belongs in the
message only after the main session runs it (`bench/runs/2026-10-20-crc32/logs/final-main/`).

## What ships

- **The table-index fold ("fold a")**, `native/luajit/patch-bitop-fold.sh`
  hunk 11, in `simplify_conv_int_num`: `CONV int.num (CONV num.i64 y)` becomes
  the unguarded `CONV int.i64 y` (mode exactly 0x275) when `oclj_bitwidth`
  bounds y at 32 bits or fewer and `fleft` is not PHI-marked [S]. Such a y is
  exactly an int32, so the removed check could never fail; it speculates
  nothing; the consumer's own check (ABC/ULE, the string length checks,
  `ULT 64`) still runs [S: guide 8.8]. The `#include "oclj_bitop_fold.c"`
  moved from above `simplify_conv_i64_num` to directly above
  `simplify_conv_int_num` [S]. On the pin's pristine blob the script adds 63
  lines and removes 8, of 2708 [M: crc2/fix/runs/ps-fix-1; crc2/impl/logs/ps-1.log].
- **The only object that changes**: `lj_opt_fold.o`. Windows (additive):
  77 LuaJIT objects, only `lj_opt_fold.o` differs from `build/native`'s
  (`1d018acc` against `03fa01f5`), our 3 objects equal; build copy
  `lj_opt_fold.c` md5 `c745ef05` [M: crc2/fix/logs/build-b-fix.log,
  logs/obj-b-fix.md5, logs/ours-b-fix.md5]. AlmaLinux 8
  (`OCLJ_GLIBC_MAX=2.28`): only `lj_opt_fold.o` differs from the release tree
  (`33a2cc50` against `7e5b11c5`), needs GLIBC_2.17 [M: crc2/impl/runs/alma-1,
  crc2/verify-code/runs/alma-1]. `native/build-native.sh` is unchanged
  (md5 `47b9c52e`) [M].
- **Never across a PHI** (the user's decision 2, policy (a)); PHIIDX stays a
  negctl arm [S].
- **Tests** [S]:
  - `test/native/bitop/twin.lua` (new): one text, two dialects, the PUC twin
    for the idx suites; coverage counts `CONV int.i64` (0x275).
  - `t_idx.lua` (new, 684 cases), `t_cnt33.lua` (new, 16), `t_idx2.lua` (new,
    1440 cases, 720 in its PUC part; verify-folda's vf_idx consumers without
    select), `phiidx.lua` (new, 7 variants, reads the compiled IR).
  - `t_rg2.lua` (new, in the floor part): 15 loops at the 2^53 boundary,
    kept from the unshipped rg2 because it passes on any build.
  - `gen.lua`: `idx` and `rg2` modes (`OCLJ_BITJIT_GENMODE`), behind their own
    flags so the default and `phi` modes write byte-identical cases [M: 36
    triples, crc2/impl/logs/gencheck-1.log; fail-first 9 DIFFER, gencheck-ff1].
  - `run-bitjit.sh`: part 4 `idx` (in the default parts: t_idx, t_cnt33,
    t_idx2 under the nine `IDXOPTS` sets against `-joff` and through PUC,
    each needing at least one `CONV int.i64` or PROVED NOTHING; then
    phiidx); t_rg2 in the floor part; a missing PUC now makes the run PROVED
    NOTHING (exit 2) unless `OCLJ_LUA53=none`, and a PUC must also run a 5.3
    chunk (luac.exe's `-v` prints PUC's banner) [S].
- **negctl-bitop.sh: 30 arms** (round 3's 27 plus WIDTHIDX33 [idx:t_idx
  idx:t_cnt33 idx:t_idx2], PHIIDX [idx:phiidx], NOLOOPFOLD [idx:phiidx]) and a
  `genrg2` catcher (GENMODE=rg2) listed on INEXACT-JIT, SELFGUARD, WIDTH55,
  NOINT-JIT and KFOLD64; canon runs `bitop fuzz gen genrg2 floor fix1 idx
  security gate stage4` [S]. Margins of the three new arms, three runs
  (2026-10-20): WIDTHIDX33 t_idx 20-51, t_idx2 92-138 per option set where
  the fold runs, t_cnt33 10, 0 under -O0 and -O-fold; PHIIDX phiidx 3 of 7
  variants; NOLOOPFOLD 1 of 7 [M: crc2/impl/logs/negctl-idx-arms-1.log,
  crc2/verify-code/logs/negctl-idx-arms.log, crc2/fix/logs/negctl-sel-1.log].
  genrg2, two runs: INEXACT-JIT 603-655, SELFGUARD 595-654, KFOLD64 513-586,
  NOINT-JIT 361-408, WIDTH55 154-162 cases a seed [M: crc2/impl probes A and
  negctl-genrg2-arms-1]. The full 30-arm sweep in one call has not run yet:
  about 12 minutes, estimated [I].
- **Docs** [S]: `docs/jit-guide.md` (8.8 rewritten as "The CRC32 follow-up:
  the table-index fold, and what remains"; new 11.5a; pitfalls P53-P58; open
  questions 16-18; all 37 design.md gaps; the verifiers' corrections),
  `docs/roadmap.md` (row 209's status note, row 211 item (5) FIX-NUMCONV, new
  row 213 the select divergence, marked next), `CLAUDE.md` (never `python -`).
  README.md unchanged.

## What does not ship, and why

- **rg2**, the speculative range guard (`BSAR y, 53` ... `ULE 1` in the loop
  body): no hunk-7 rule, no `oclj_rangeguard53`, no p_rg2.lua, no run-bitjit
  part 5, none of the seven RG2 arms (the user's decision 1). On top of the
  fold it bought crc-table 0.97, crcprobe 0.97, crctm 0.95, mix 0.79, ident's
  small rows 0.82-0.91 (both/fold); it cost, on B-legal loops past 2^53,
  hi60 6.64x, sh40 7.31x, top8 5.0x, half 3.64x, flag63 3.17x of base (6.27x
  of the fold alone), ident's big rows 2.0x, and with `-Omaxside=0` hi60 11.5
  ns against 0.5 [M: crc/main/chain-1/summary.txt]. Its boundary tests stay
  (t_rg2.lua, GENMODE=rg2, the genrg2 catcher).
- **Crossing a PHI** (PHIIDX's fold, PHIREUSE): decision 2 [S].
- **FIX-NUMCONV** (an operand's own `CONV i64.num` is exact): its own later
  round, a roadmap entry only (decision 3) [S]. Its smoke gain was measured
  against round 3's build without the fold; with the fold alone ident's rows
  already read 1.10-1.20, so its gain on top is unmeasured [M:
  crc/verify-rg2/runs/smoke-ident-1/inputs.md5 names lj_opt_fold.o 03fa01f5;
  chain-1] [I].
- **The select fix**: roadmap row 213, its own round, next (decision 5).
  Recorded only as the observed divergence: compiled `select(k, ...)` with a
  large negative k returns nil where `-joff` raises "index out of range", on
  the shipped build and the 2026-09-01 upstream binary alike, no bit operator
  involved [M: verify-folda, as reported]. Not probed further in this
  workflow; t_idx2.lua leaves select out [S].

## The numbers (cite these)

The main session's timing chain `timing-chain.sh` (md5 `1f17a792`), 9
interleaved rounds, 2026-10-20 14:17:15-14:24:44Z, CPU load 7-9%, no Java,
every result equal across the four builds [M: crc/main/chain-1/summary.txt,
start, end; archive `bench/runs/2026-10-20-crc32/logs/design-chain/`]; and
`b0-companion.sh`, 5 rounds beside round 2's b0 [M: crc/main/b0-1/,
summarized by crc/main/b0sum.py; archive `logs/design-b0/`]. Medians, ns per
byte (fold = the shipped `lj_opt_fold.o` `1d018acc`, chain-1's `b-folda`):

| row | base | fold | fold/base | round 2's b0 | PUC 5.3.6 |
|---|---|---|---|---|---|
| table-driven CRC32 (bench_bit2 crc-table, row 209's number) | 7.20 | 3.70 | 0.51 [0.50-0.51] | 2.90 (fold 1.28 of it [1.24-1.28]) | 32.40 |
| crcprobe / crct / crctm / crcmb | 7.20-7.50 | 3.70-3.90 | 0.51-0.52 | | 32.3-35.1 |
| bit-serial CRC32 (bench_bit crc) | 69.5 (b0 run: 70.0) | 70.0 | 1.00 [0.98-1.01] | 48.5 (fold 1.44 of it [1.43-1.47]) | 120.5 |
| bench_spec mix / flag63 | 4.25 / 1.50 | 2.80 / 0.75 | 0.66 / 0.50 | | 19.25 / 12.90 |
| ident's ten identity rows | 1.80 | 1.10-1.20 | 0.61-0.63 | | 13.6-16.1 |
| bench_idx phi2 | 4.20 | 4.10 | 0.98 [0.95-1.00] | | 17.60 |
| every other row | | | 1.00-1.02 | | |

[M: chain-1 summary.txt; b0sum on b0-1, re-run in crc2/docs/b0sum-1.txt.]

## Tests and checks run on this working tree [M]

- Windows build of the working tree (additive), rc 0 in 44 s; objects as
  above [crc2/fix/logs/build-b-fix.log].
- patch-bitop-fold.sh on the pristine blob: 63/8, reversal and idempotence
  OK, output equals the build copy; all 8 fail-firsts refuse with rc 1
  [crc2/fix/runs/ps-fix-1].
- run-bitjit.sh, all four parts with PUC, on b-fix: RUN-BITJIT: PASS; gen
  seeds 1-4 all 0; t_rg2 0 in 6 sets and against PUC; t_idx 684 cases, a
  trace in 599, 1487 CONV int.i64; t_cnt33 16/16; t_idx2 1440 cases, 1742
  convs, puc part equal; phiidx 7/7 [crc2/fix/logs/bitjit-fix-all-1.log].
  Earlier: the implementer's build (Windows and Alma) and the code verifier's
  (Windows and Alma, fresh seeds in every mode, 24 option sets, edge/carry/
  regpress suites) [crc2/impl/runs, crc2/verify-code/runs].
- The idx part on the base build: PROVED NOTHING, rc 2 [crc2/impl/runs/bitjit-base-idx-1.log].
- The missing-PUC path, 13 cases: every no-PUC case rc 2, luac.exe included
  (rc 0 before the fix, crc2/verify-code/runs/pucpath-1); `none` and the real
  PUC rc 0 [crc2/fix/runs/pucpath-1].
- negctl-bitop.sh, selected arms on the fixer's build
  (OCLJ_NEGCTL_ARMS=WIDTHIDX33,PHIIDX,NOLOOPFOLD,NOINT-JIT,FIX1): canon PASS
  (109 s, every catcher passes, every object reproduced), each arm caught at
  its named checks (NOINT-JIT by floor:t_jit2/guard-exit and genrg2), restore
  PASS, rc 0 in 220 s [crc2/fix/logs/negctl-sel-1.log]. Earlier selected
  runs: crc2/impl/logs/negctl-idx-arms-1.log, negctl-genrg2-arms-1.log;
  crc2/verify-code/logs/negctl-idx-arms.log, negctl-old-arms.log.
- run-bitop.sh, run-bitfuzz.sh and the nine other runners: PASS on the
  implementer's build [crc2/impl/runs, logs/runners-1.log] (the fixer changed
  no file they read except comments of twin/phiidx/t_idx2, which they do not
  load) [S].
- Hygiene: 0 CR in every changed file; `git diff --check HEAD` rc 0;
  `git diff --no-index --check` rc 1 (clean) for each of the 6 new files;
  `sh -n` of the changed shell scripts; negctl-bitop.sh 106 backslashes (81
  continuations), 0 tab; patch-bitop-fold.sh 0 tab, 0 backslash [crc2/fix].
- final-check.sh (ea8360ca) smoke runs on the fixer's build: parts
  `bitjit gen hygiene`, PASS 19, FAIL 0, SKIP 2 in 280 s (BITJIT-all, the
  idx, rg2 and phi generator modes, 24 generator pairs byte-identical, CR0
  on 14 files, `git diff --check HEAD`, PATCH-*, both censuses,
  FILES-unchanged) [crc2/fix/fc-smoke-A/summary.txt]; parts `alma hygiene`
  with the outdir spelled `/C/...`, PASS 26, FAIL 0 in 203 s (AlmaLinux 8
  build rc 0, needs GLIBC_2.17, only lj_opt_fold.o differs, 33a2cc50;
  run-bitjit all parts with the Linux PUC; idx and rg2 modes; sh -n in
  Alma's sh and Ubuntu's dash) [crc2/fix/fc-smoke-B/summary.txt]. Its
  refusals: 13 of 13 [crc2/fix/ff/real-final/results.txt].
- Docs: 368 in-page links resolve; 44 tables consistent; 35 cites by
  content; P1-P58 in order; open questions 1-18 [crc2/fix/logs/anchors-1.txt,
  tables-1.txt, cite-1.txt, pcheck-1.txt].

## The fixer's changes (after the implementer and docs agents)

| file | md5 now | what changed |
|---|---|---|
| native/luajit/patch-bitop-fold.sh | 149187d8 | the comment above verify_content: which checks fail alone and which are implied (verify-code F3); 11 lines as before, so `~:429-444` still holds; output unchanged (c745ef05) |
| test/native/run-bitjit.sh | 103529a4 | a PUC must also run a 5.3 chunk, so luac.exe is no PUC (verify-code F4); header reworded in place; line count unchanged (528) |
| test/native/negctl-bitop.sh | 7d125177 | THE MARGINS for the idx arms over three runs (verify-code F5, plus the fixer's run); the memory-safety paragraph: PHIIDX's values rest on a hint PHI (docs F12); same line count (841), so every guide cite holds |
| test/native/bitop/t_idx2.lua | b7393359 | header: x & 0xffffffff shows through narrowed keys, loop stop and concat, not sub (docs F9, three runs) |
| test/native/bitop/phiidx.lua | c3e47b74 | header: string.buffer's #buf records a NONE-mode CONV int.i64 this count would take (docs F1) |
| test/native/bitop/twin.lua | 216a844b | coverage comment: the same (docs F1) |
| docs/jit-guide.md | 2c1d57a5 | docs F1-F15, verify-code F1-F6 and the verifiers' guide gaps (see the fixer's report) |
| docs/roadmap.md | 6fa66b3c | docs F2, F3, F11, F13 |

Unchanged since the implementer: oclj_bitop_fold.c 1ac93081, gen.lua
ce4671e9, t_idx.lua 1281747f, t_cnt33.lua b5dc9e14, t_rg2.lua c690d89c,
CLAUDE.md 45b861fb, README.md 98f6042d, build-native.sh 47b9c52e.

## The final check (for the main session; its result is not yet a fact)

`crc2/fix/final-check.sh` (md5 `ea8360ca8ba248d2e533b97ddde3dffc`) with
`crc2/fix/fc-summarize.py` beside it (md5 `adbedfd1d37b06fc5596a9f0272205c3`);
the archive's `scripts/final-check.sh` and `scripts/fc-summarize.py` should be
these two files. Parts in order: build, alma (with Ubuntu's dash `sh -n`),
bitjit, suites, negctl (the full 30-arm sweep, one call), runners, gen,
hygiene, timing (7 rotated rounds of base, new, b0 and PUC); a census of
`build/` and the pristine checkout before and after. About 35 minutes,
estimated [I].

## Open items (for the message's last paragraph)

- Row 209 stays open (decision 4): bit-serial CRC32 70 ns/byte against
  round 2's 48.5, and crc-table's last quarter (3.6-3.7 against 2.9). Next
  step: a design pass on loop-carried widths (an inductive bound for a PHI
  such as the bit-serial loop's b, which the width rule scores 64), an idea,
  not measured [I].
- Next round: the select fix (row 213); then FIX-NUMCONV (row 211 (5)).
- genrg2's margins are two runs, not three (guide open question 18); the
  idx arms now have three. Whether `floor:t_rg2` should be a named KFOLD64
  catcher is open [M: t_rg2 failed under KFOLD64 in crc2/impl
  negctl-genrg2-arms-1]; so is whether genrg2 should stay on all five arms
  (about 3 minutes of the sweep) [I].
- The full 30-arm sweep and final-check.sh end to end: the main session.
- Fold a's fused 32-bit load from a 64-bit spill is still unobserved (guide
  open question 5) [M: verify-code regpress-4, -5 reloaded the full value].
- A latent CSE hazard (guide open question 16): unreachable while LJ_HASFFI
  is 0 and oclj_bitwidth scores a SUB 64 [S].
