# CRC32 follow-up (roadmap row 209): the combined design pass

Scratch record of the combiner (crc/combine, 2026-10-20). The repo is untouched: `C:/Users/astro/Downloads/OC-LuaJIT` is still at `eb47daf` with a clean tree. Everything here is under `C:/Users/astro/claude-tmp/oclj/crc/combine/`. Every claim is marked [M] (measured; the run is named), [S] (read in source) or [I] (inferred).

## The correctness contract

A change may only change speed. Every result must equal the interpreter's (`-joff`), and through the twin it must equal PUC 5.3.6's under round 3's U1-B semantics (an inexact result raises, with the hint). That holds for every input, under every option set of guide 11.3, in root and side traces, across PHIs and at guard exits. Speculation is allowed only where a failed guard exits to code that computes the right answer, and its cost is measured.

Both changes were held to this contract. Neither the prototypers, the verifiers nor this pass found an input on which a build computes anything `-joff` does not.

## What each change does on this build

**Fold a, the table-index fold** (proto-folda, hunk 11 of `patch-bitop-fold.sh`) [S]
- Where: `simplify_conv_int_num`, the owner of `LJFOLD(CONV CONV IRCONV_INT_NUM)`.
- What: it rewrites `CONV int.num (CONV num.i64 y)` to the unguarded `CONV int.i64 y`, mode exactly `(IRT_INT<<IRCONV_DSH)|IRT_I64`. It fires when `oclj_bitwidth(y) <= 32` and `fleft` is not PHI-marked, and it returns `RETRYFOLD`.
- Why it is sound: such a y lies in [-2^31, 2^31), so it is exactly a double and exactly an int32. The removed check (INDEX, ANY or CHECK) can never fail. The proof reads no guard and no mark (S2), and the index is still bounds-checked on the int it uses.
- Emitted code: x64 emits `mov r32, r32`.
- Build impact: the `#include` of `oclj_bitop_fold.c` moves up, above `simplify_conv_int_num`.

**rg2, the range guard** (proto-rg2, hunk 7 plus `oclj_rangeguard53`) [S]
- Where: in a loop body only (`J->chain[IR_LOOP]`), when both conversions carry the exact mark, `fleft` is not PHI-marked, y is i64, and the width rule cannot bound y.
- What: it replaces a result guard's own check (`CONV i64.num d` plus `EQ.i64`) with `BSAR y,53; CONV int.i64; ADD 1; ULE 1`. That test passes exactly for y in [-2^53, 2^53).
- Why it is sound: the guard sits where the old one sat and exits through the same snapshot.
- Cost: it speculates. An exact y outside the range leaves the trace, and the interpreter recomputes.

**On this build's CRC loop** (`probes/crcprobe.lua`, trace 8, loop body; `probes/crc-<variant>.dump`) [M]

| variant | body instructions | body guards | mcode bytes | result |
|---|---|---|---|---|
| base (HEAD) | 42 | 10 | 824 | 3012454781 |
| folda | 41 | 9 | 752 | 3012454781 |
| rg2 | 48 | 10 | 832 | 3012454781 |
| both | 47 | 9 | 759 | 3012454781 |

- Fold a removes the guarded `int CONV int.num index` from the chain. In the both build this is `0085 BAND ... / 0086 int CONV 0085 int.i64 / 0087 ABC`.
- rg2 turns the three result guards into range guards (0081-0084, 0092-0095, 0101-0104).
- What remains in every variant is the table value's operand guard (`CONV i64.num`, `CONV num.i64`, `EQ.num`, 0096-0098).
- `-joff` and PUC 5.3.6 print the same result, 3012454781.
- mcode sizes vary by a few bytes between processes: folda read 746 bytes in proto-folda's run and 752 here.

## The combined tree (`repo/`, diff `combine-vs-HEAD-eb47daf.diff`, md5 `abe2fc07`)

**Native: only `lj_opt_fold.c` changes in the build** [M]
- `native/luajit/patch-bitop-fold.sh` (`608d5f20`):
  - hunk 7 carries rg2's rule; hunk 11 carries fold a and the moved include;
  - NADD 71 = 45 + 18 + 8, NDEL 8;
  - `verify_content` merges both prototypes' checks and adds the range guard's count. Its comment says which checks can fail on their own;
  - the hunk engine is unchanged (md5 `077d1dbebe05`). The script has 0 CR, 0 TAB and 0 backslashes.
- `native/luajit/oclj_bitop_fold.c` (`bc958949`): folda's header plus rg2's paragraph and function.
- `native/build-native.sh` (`4f7d4ba4`, rg2's): one line, so that `bitop_wgate.c` calls `oclj_rangeguard53`.

**Tests**
- `gen.lua` (`7dcb57fa`) merges GENMODE idx and rg2. The modes exclude each other, and each mode's draws sit behind its own flag.
- `run-bitjit.sh` (`4052233c`) has five parts: gen, floor (t_rg2 inside), fix1, idx (part 4) and rg2 (part 5).
- `negctl-bitop.sh` (`09714335`) has 37 arms. Two of the ten new ones come from the verifiers: NOLOOPFOLD (verify-folda) and RG2-NEG (verify-rg2).
- New suites: `twin.lua`, `t_idx.lua`, `t_cnt33.lua`, `phiidx.lua`, `t_rg2.lua`, `p_rg2.lua`.

**Fixes made in the merge, each small and measured**

1. **t_idx's `fori` consumer (verify-folda F1).**
   - The old consumer `for j = e, e + 1` had a double start, so rec_for recorded a number loop and emitted no conversion. Its replacement is `for j = 1, e ... break at 3`.
   - Under WIDTHIDX33 the new consumer differs in 21-23 cases per option set (0 under O0, O1 and nofold). t_idx's catch under jon rose from 28 to 52 (`b-both/negctl-bitop/20261020T133823Z-362/WIDTHIDX33`) [M].
2. **The two rules' signatures collide.**
   - rg2's range guard emits `CONV int.i64` (of `BSAR y, 53`) with the same opcode and mode, 0x275, as fold a's.
   - Measured on the rg2-only build, folda's original instruments counted rg2's conversions as folds: t_idx reported `convs 179`, t_cnt33 `convs 16`, and phiidx read `crc fold=3` and `phicnt fold=1`. So the idx part could not say PROVED NOTHING on a build that has the range guard but not the fold (`runs/rg2only-oldtwin-*.err`, `runs/rg2only-oldphiidx.txt`) [M].
   - The fix: `twin.lua`'s coverage and `phiidx.lua`'s scan skip a `CONV int.i64` whose operand is `BSAR _, 53`.
   - After the fix, the rg2-only build reads t_idx and t_cnt33 PROVED NOTHING (0 convs) and phiidx INSTRUMENT, so the run exits 2 (`runs/bitjit-rg2only-idx-1.log`) [M].
   - Limit [I]: a program key of exactly `x ~>> 53` would also be skipped. No suite uses one.
3. **NOLOOPFOLD is now caught (verify-folda F3).**
   - phiidx gains `ctl1 = acc + T[((i * 7) & 0x7f) + 1]`, which needs fold >= 1 in the loop body. The key is a narrowing leaf that the pre-roll emits raw, so only the rule firing in the loop copy can fold it.
   - Under NOLOOPFOLD, ctl1 reads fold=0 and FAILED, while the other six variants still pass (`b-both/negctl-bitop/20261020T133823Z-362/NOLOOPFOLD/bitjit.log`) [M].
4. **RG2-NEG becomes an arm (verify-rg2).** It is caught by floor:t_rg2 (in t_rec seeds 1-4 too) and by genrg2 at 11-19 cases a seed in 4 of 4 seeds. This is the thinnest margin of the new arms (one run) [M].
5. **negctl's memory-safety paragraph is restated.**
   - The old argument rested on "no fold removes the int conversion", which fold a makes false. The new one rests on ABC/ULE, the string-length checks and ULT 64.
   - It also names the arms that change only the IR's shape or the exits.

**Not taken in, and listed below:** FIX-NUMCONV, PHIREUSE, vf_idx as a shipped suite, the upstream select bug, and run-bitjit's PUC-SKIP-still-PASS.

## Correctness evidence (all on the combined build `b-both` unless named)

**Build and patch script**
- build-native.sh rc 0 in 31 s, every gate passed, `ignored from the environment: none`, pin met (`logs/build-both.log`).
- 77 objects. Only `lj_opt_fold.o` differs from build/native (`298239c4` against `03fa01f5`; `logs/obj-*.md5`).
- The base variant reproduces every shipped object. The folda and rg2 variants reproduce their prototypes' b1 `lj_opt_fold.o` (`1d018acc`, `40ac1c3e`) [M].
- The patch script on the pin's blob (`git cat-file`): 71 added and 8 removed lines, reversal OK, idempotent on its own output, output byte-identical to b-both's build copy (`ps/out1.c`, `73c2e131`) [M].
- Its fail-firsts (`ps/ff/*.log`) each refuse with rc 1 and the expected message [M]:
  - a stray `oclj_rangeguard53(` line;
  - a stray `oclj_bitwidth(` line;
  - `simplify_conv_int_num` moved below `simplify_conv_i64_num` (only the order check sees it);
  - the anchor twice;
  - the anchor missing;
  - n11's bound written 33;
  - n7's width bound written 55.

**run-bitjit.sh, all five parts, with PUC set explicitly: PASS** (`runs/bitjit-both-all-1.log`, 57 s) [M]
- gen, seeds 1-4: 0 in all 12 comparisons; traces in 1334-1415 of 2000 loops.
- floor:
  - t_rec seeds 1-4;
  - t_jit2 in six option sets, plus PUC;
  - t_rg2 in six option sets, plus PUC.
- fix1: 8 of 8.
- idx:
  - t_idx, 684 cases, and t_cnt33, 16 cases: 0 differences in 9 option sets, plus PUC; 1524 and 12 fold conversions;
  - phiidx: 7 of 7.
- rg2: p_rg2, 7 of 7, in four option sets.

**Generator modes: all 0 in every comparison** [M]
- GENMODE idx: seeds 1-4 and 901-902.
- GENMODE rg2: seeds 1-4 and 901-902.
- GENMODE phi: seeds 201-204.
- Runs: `runs/bitjit-both-gen*.log`.

**Generator identity: 24 of 24 mode-seed pairs byte-identical** (`gencheck-1/`) [M]
- The default and phi outputs equal HEAD's gen.lua for seeds 1, 2, 3, 4, 57 and 301.
- The idx output equals proto-folda's gen.lua for seeds 1-5 and 777.
- The rg2 output equals proto-rg2's for seeds 1-4, 501 and 777.
- Control: idx-1 and rg2-1 differ from default-1.

**The other runners: PASS** [M]
- run-bitop.sh: matrix, provenance, BT1-BT6 (`runs/bitop-both-1.log`).
- run-bitfuzz.sh: 16000 tuples, 0 mismatches, controls as expected (`runs/bitfuzz-both-1.log`).

**The verifiers' adversarial suites on b-both: 0 differences** [M]
- verify-folda's vf_idx: 1440 cases in 16 option sets; its PUC subset, 720 cases, is 0 too (`runs/vf-idx-both-1`).
- vf_carry and vf_press: 0 in 16 option sets.
- verify-rg2's adv.lua: 56 loops in 20 option sets, plus PUC on 53 of them (`runs/adv-both-1`). Range guards are in every loop body (jon: rg_body=74, exits=1769, side=140).
- stale.lua: 0 range guards on a pre-roll BSAR (default and -Ohotloop=1).

**negctl-bitop.sh, all 37 arms, in five selected runs; canon PASS and restore PASS in each; every arm caught at its named check** [M]

| run | arms | wall time | work dir | log |
|---|---|---|---|---|
| A | WIDTHIDX33, PHIIDX, NOLOOPFOLD | 2:32 | `20261020T133823Z-362` | `logs/negctl-A.log` |
| B | 7 RG2 arms | 4:32 | `20261020T134107Z-147` | `logs/negctl-B.log` |
| C1 | NARROW, KFOLD64, SELFGUARD, WIDTH55, FIX1 | 3:47 | `20261020T134549Z-411` | `logs/negctl-C1.log` |
| C2 | WSHR, WBAND, WADD0, WSHL0, NOINT-JIT, SARCONST, INEXACT-JIT | 5:55 | `20261020T134941Z-237` | `logs/negctl-C2.log` |
| D | the 15 interpreter, parser and format arms | 4:31 | — | `logs/negctl-D.log` |

- The work directories are under `b-both/negctl-bitop/`.
- Catches of the RG2 arms (genrg2, cases a seed): RG2-54 203-238, RG2-NEG 11-19, RG2-NOGUARD 379-399, each over 4 of 4 seeds. RG2-SHR, RG2-52, RG2-OFF and RG2-PREROLL are caught by p_rg2.
- Margins were measured once, not over three runs (guide 11.7 item 10).
- In total the sweep took about 21 minutes in five calls. One call no longer fits the 8-minute bound.

**AlmaLinux 8** (`scripts/alma-combine.sh`, `runs/alma/`, 90 s) [M]
- build-native.sh with OCLJ_GLIBC_MAX=2.28: rc 0, the library needs GLIBC_2.17 at most.
- Only `lj_opt_fold.o` differs from the release tree (`c330bf7f` against `7e5b11c5`).
- run-bitjit.sh, all five parts with the Linux PUC: PASS.
- GENMODE idx and rg2, 2 seeds each: PASS.
- negctl was not run on Linux.

## Speed (SMOKE: 2 rounds, `timing-smoke/`, 100 s, CPU load 3%, no Java; not the authoritative reading)

Median ns, and each build's ratio to base in the same round [M]:

| row | base | folda | rg2 | both | PUC 5.3.6 |
|---|---|---|---|---|---|
| bench_bit2 crc-table | 7.25 | 3.60 (0.50) | 7.05 (0.97) | 3.55 (0.49) | 32.60 |
| crcprobe loop | 7.30 | 3.65 (0.50) | 7.00 (0.96) | 3.65 (0.50) | 32.35 |
| crctm (crc masked) | 7.50 | 3.90 (0.52) | 7.25 (0.97) | 3.75 (0.50) | 33.75 |
| crcmb (crc and byte masked) | 7.30 | 3.75 (0.51) | 7.15 (0.98) | 3.65 (0.50) | 35.00 |
| bit-serial crc | 70.00 | 1.00 | 0.99 | 0.99 | 119.75 |
| rgb, bit, idx, phi, phi2, cnt | — | 0.97-1.07 | 0.99-1.02 | 0.94-1.01 | — |
| spec mix | 4.25 | 2.75 (0.65) | 3.50 (0.82) | 2.12 (0.50) | 19.57 |
| spec hi60, sh40 | 0.65-0.68 | ~1.0 | 7.1-7.2 | 7.1-7.2 | 8.6-11.0 |
| spec top8, half, flag63 | 0.65-1.50 | 0.52-0.96 | 3.2-5.1 | 3.1-5.1 | 10-13 |
| ident, big values | 1.80-1.90 | 0.58-0.63 | 1.95-2.06 | 1.82-1.94 | 13.9-16.7 |
| ident, small values | 1.80-1.85 | 0.58-0.61 | 0.87-0.92 | 0.49-0.56 | 13.6-16.7 |

- **What rg2 adds on top of fold a** (both/folda, `scripts/pairratio.py`):
  - CRC rows 0.96-1.00;
  - mix 0.77;
  - ident small 0.82-0.91;
  - ident big 2.88-3.30;
  - spec rows past 2^53 3.95-7.09 [M smoke].
- **Fold a's win is wider than CRC** [M smoke; the reason is I]: every masked bit result used as a key through narrowing (`T[(i & 1023) + 1]` in ident and mix) or as a variable count (`1 << (60 + (i & 3))` in flag63) loses its guarded conversion.
- **Fold a's one possible cost, phi2:** 1.00 [M smoke].
- **What a failing range guard costs with no side trace** (-Omaxside=0, bench_spec at 2e6, 0.5 ns step, one pass): hi60 base 0.5 ns, rg2 11.5 ns, both 11.5 ns; flag63 1.0, 12.5 and 12.0 [M smoke].
- **Against the row's target:** today's 7.25 drops to 3.55-3.60 ns/byte. That is not the 2.8-2.9 of round 2's b0, which this pass did not time. The remaining cost is the table value's operand guard, and the three result guards in folda alone [M from the IR, the split is I].

**The authoritative timing is the main session's:** `timing-chain.sh <fresh outdir>`.
- Default 9 rounds, about 50 s a round, so about 8 minutes.
- It refuses an existing outdir (rc 99, fail-first `ff-chain/refuse-exists.log`).
- It refuses to start when a java or javaw process runs (rc 97, fail-first with a stand-in tasklist, `ff-chain/refuse-java.log`), and it stops between rounds if one appears (rc 96).
- `bench_crcx.lua` refuses an instrument whose crcprobe(20000) is not 3012454781 (fail-first on round 2's b0: exit 2).
- The summarizer flags a changed result (fail-first `ff-chain/sum/bad.txt`: RESULTS DIFFER, exit 1).
- The final chain (`1f17a792`) and summarizer (`68579d96`) differ from the smoked ones (`c4a84865`, `5b0e553a`) in comments and the PUC message only, plus one appended `pairratio.py` call. That call was tested on the smoke raw data but not inside a chain run.

## The speculation's cost, plainly

Fold a speculates nothing: it adds no guard and removes a check that cannot fail [S].

rg2 speculates on every result whose bound exceeds 54, in loop bodies:
- Every B-legal loop whose exact results leave [-2^53, 2^53) pays one exit per failing iteration. After 10 exits it pays a side trace that re-enters the root at its head, through the pre-roll.
- That costs 3-7x on tight loops (hi60, sh40, top8, half, flag63) and 2x on identity operations of big doubles. Against fold a alone it costs 3-7x.
- Correctness held in all of these loops [M: adv.lua, t_rg2, GENMODE rg2, p_rg2's beyond rows].

## Open problems

1. The authoritative timing (main session, `timing-chain.sh`) has not run. Every speed number above is smoke.
2. negctl margins for the ten new arms are one run each. RG2-NEG's 11-19 cases a seed is thin.
3. Linux negctl is not run. Linux is only built and suite-tested.
4. Fold a under register pressure: the fused-load path that reads a 64-bit spill of y's register is unexercised (verify-folda F12) [I].
5. A latent CSE hazard, FFI-only: `cse_conv` ignores IRCONV_NONE, so a NONE-mode `CONV int.i64` would common with the fold's. It is unreachable while `LJ_HASFFI` is 0 [S].
6. The instruments' rg2 exclusion skips any `CONV int.i64 (BSAR _, 53)`, a program's own `T[x ~>> 53]` included [I].
7. The guide's gaps, below, are to be fixed in the implementation commit.

## Decisions for the user, each with a recommendation

1. **Ship fold a?** Recommend **yes**.
   - It halves table-driven CRC32 on this build (smoke 7.25 to 3.60) and speeds other masked-index and masked-count loops (0.52-0.65).
   - No row slowed (phi2 1.00), and it has no speculation.
   - It passed every suite, the generator in three modes, 16-20 option sets of the verifiers' suites, all 37 arms, and Linux.
   - Confirm with the main-session chain first.
2. **Ship rg2?** Recommend **no**.
   - On top of fold a it buys 0-4% on CRC, 23% on the mix loop and 9-18% on small identity operations.
   - It costs 3-7x on B-legal loops past 2^53 and about 3x on identity operations of big doubles.
   - Keep `t_rg2.lua` and GENMODE=rg2: they pass on any build and hold the 2^53 boundary. Drop `p_rg2.lua`, part 5 and the seven RG2 arms. Revisit rg2 only with a record-time hint or FIX-NUMCONV.
3. **Fold a's PHI policy:** (a) never across a PHI, as built; (b) PHIIDX; (c) PHIREUSE. Recommend **(a)**.
   - phi2 shows no cost in any smoke run.
   - (b) relies on a CONV-hint PHI that loop_unroll's type-fix branch never adds.
   - (c) is requirement-2-compliant but needs a written argument and a changed phiidx NEED. Revisit (c) only if the chain shows a phi2 cost.
4. **FIX-NUMCONV**, the width rule's "a CONV i64.num of a double is always exact" (verify-rg2): recommend a **separate small round**, with its own arm and catcher.
   - It is a one-line fold that also helps the shipped build (1.4 against 1.8 ns smoke).
   - Bundling it here would change p_rg2's counts and the width rule's arms.
5. **Ship vf_idx's consumers?** Recommend **yes, as t_idx2.lua in the idx part**.
   - The consumers: string.char, rep, find, concat, unpack, rawget, `sub(e)`, `sub(-e, e)`, a loop stop, branches and carried keys, all with a PUC subset.
   - It catches WIDTHIDX33 in 90-139 cases per option set, about 8 s for 16 option sets.
   - Leave select out (upstream bug, decision 7).
6. **run-bitjit.sh's missing PUC:** recommend making a missing `OCLJ_LUA53` **PROVED NOTHING (exit 2)** unless the caller sets `OCLJ_LUA53=none`. Today a git-archive scratch repo skips every twin and still PASSes (verify-folda F11).
7. **The upstream select bug** (rec_varg's 32-bit BSHL bound: `select(-2147483628, ...)` gives nil compiled and raises interpreted): recommend **a roadmap note** now. A fork fix belongs in a later round.
8. **Row 209's target:** recommend **recording fold a's measured ns/byte** as the row's result and closing the row. Do not chase 2.9 in this round. The rest is the table value's operand guard and the result guards, which need an exactness fact the width rule does not have.

## The guide's gaps (merged, deduplicated; section, what it said, what was found, proposed fix)

Sources: proto-folda (F), verify-folda (VF), proto-rg2 (R), verify-rg2 (VR), this pass (C).

### Folds, loops and their soundness arguments

1. **8.8, 3.8 requirement 2, S5 (9.5).**
   - *Said:* the index fold must never cross a PHI.
   - *Found:* PHIIDX is value-correct in every suite, because of 4.1's CONV-hint PHI. But that PHI exists only in loop_unroll's regular branch; the type-fix branch adds none. PHIREUSE (return the pre-roll's own `CONV int.i64` of y) satisfies requirement 2 and gives phi2's 476-byte loop. [F, VF]
   - *Fix:* call "never across a PHI" a conservative policy, give PHIIDX's measurements and the type-fix hole, and describe PHIREUSE.
2. **4.1.**
   - *Said:* every recorded instruction is re-emitted through FOLD/CSE; "Extra PHIs for hints" reads as general.
   - *Found:* an instruction folded in the pre-roll is copied in its folded form, and the rule never runs again for it. It runs in the copy only for raw-emitted narrowing leaves, for bounds that improve in the copy, and at PHIs. The hint PHI is regular-branch only. And `!irt_isphi(fleft->t)` does not mean `fleft->op1` is a body value. [VF, VR]
   - *Fix:* add these as three bullets.
3. **8.4a.**
   - *Said:* requirement 2 applies to each new instruction.
   - *Found:* instructions a rule emits on the side, and does not return, are invisible to loop_unroll's PHI marking. If one CSEs to a pre-roll instruction, the loop body reads a stale value (`stale.lua`: 1 on RG2-PHI-RELAXED, 0 on rg2; cse_carg's "CSE across loop?" is the precedent). It is ambiguous whether a PHI-marked fleft whose operand is also PHI-marked may take new instructions. [R, VR]
   - *Fix:* say to build side instructions only on body refs, keep `!irt_isphi(fleft->t)`, and write the argument down.
4. **8.4 item 11, S4 (9.4), 12.5-12.6.**
   - *Said:* hold a PHI-crossing rule with p4v-style trace events; traceir is used only to read the mark.
   - *Found:* a value-correct PHI crossing is invisible to trace events and to differential suites; only an IR read sees it. There is no recipe for one. [F, R]
   - *Fix:* add an IR-shape recipe to 12.5:
     - `traceinfo(tr).nins`;
     - `traceir`'s `ot >> 8` (via vmdef.irnames), `ot & 0x40` for PHI, `ot & 0x80` for guard, `op2 & 0x3ff` for a CONV's mode;
     - operands are bias-relative (instructions positive, constants negative, and `tracek` reads the negative ones).
5. **8.8's consumer list.**
   - *Said:* table keys (INDEX), string.byte and string.sub (ANY), and the variable shift count.
   - *Found:* also fori_conv's CHECK (only with an int start), select's INDEX, `recff_sbufx_checkint`, loop's "Fix num->int" (always PHI-marked), and narrowing leaves emitted raw in the pre-roll. lj_opt_narrow_toint's other users: string.char, rep, find's init, format's %c, concat's i and j, unpack's i and j, tonumber's base, table.new, ipairs_aux. Also rawget, and ULE asize for hash-only tables. [F, VF]
   - *Fix:* replace the bullet with that table, and say which consumers can expose a bound of 33.
6. **8.8, 11.4: designing bound tests.**
   - *Said:* nothing.
   - *Found:* a 33-bit truncation is visible only where it lands on a valid index or count. A value below 2^32 truncates to a negative int32, which ABC or ULT rejects (a correct exit). String functions take negative arguments, so `x & 0xffffffff` does expose the bound in sub, byte and find. A variable count outside [0, 63] at record time aborts the trace. [F, VF]
   - *Fix:* add a paragraph on designing bound tests.
7. **S7 (9.7) instances.**
   - *Found:* t_idx's `fori` consumer was vacuous: a double start makes a number loop, so no conversion. The fix `for j = 1, e` adds 21-23 catches. [VF, C: 52 against 28 under jon]
   - *Fix:* cite it.
8. **3.11, 3.12, 2.6.**
   - *Said:* only the width rule removes a guard; 3.12 reads `x << 20, x a double: both guards stay` as if both were needed.
   - *Found:* some results can never be inexact whatever their width: an identity result that is an operand's `CONV i64.num` of a double (FIX-NUMCONV), and BSHL and BSAR of exact operands (25.6M pairs on PUC). A speculative guard inherits them as needless failures. [VR]
   - *Fix:* say so in 3.11/3.12, and list FIX-NUMCONV as a candidate.
9. **3.9 and 5.1, not tied.**
   - *Found:* cse_conv compares MODEMASK, which excludes IRCONV_NONE. So a NONE-mode `CONV int.i64` (FFI-only today) could common with the fold's zero-extending one, an S3 case. [F, VF]
   - *Fix:* add one sentence to each section.
10. **4.6, 4.8.**
    - *Found:* a side trace linking to a root enters at its head, through the pre-roll. So a failing body guard costs a pre-roll iteration plus a side-trace iteration, 3-7x on tight loops. [R]
    - *Fix:* add a bullet.
11. **10, a new pitfall.**
    - *Found:* select's compiled bound wraps (rec_varg's 32-bit `BSHL(idx, 3)`): compiled code returns nil where the interpreter raises. This is upstream. [VF]
    - *Fix:* add a P entry and a roadmap note.

### Tests, the generator and negctl

12. **11.2, the twin.**
    - *Found:* library arguments differ: LuaJIT's are int32 through lj_lib_checkint, PUC's lua_Integer. string.char, rep and select would not twin. [F]
    - *Fix:* add one paragraph.
13. **11.2, 12.10, 7.4, 7.6: running from a scratch repo.**
    - *Found:* OCLJ_LUA53's default is relative to OCLJ_REPO, and a git-archive scratch repo has no bench/vendor. run-bitjit.sh then SKIPs every PUC comparison and still PASSes. The example also omits OCLJ_LUAJIT. [VF, R]
    - *Fix:* document both knobs, and make a missing PUC PROVED NOTHING.
14. **11.4 GENMODE.**
    - *Said:* add new shapes behind a new mode.
    - *Found:* there is no recipe and no check. The draws must short-circuit (`MODE and rnd(n)`) and the modes must exclude each other. The check is a byte compare of every mode's output against its own reference gen.lua over several seeds (C: 24 of 24 pairs, `gencheck.sh`). [F, R, C]
    - *Fix:* add that recipe and check.
15. **Checklist 19, 11.4, 11.5: coverage.**
    - *Said:* traces in a quarter of the loops.
    - *Found:* that does not show a rule fired; count the rule's own IR signature. Two rules can share one: rg2's `CONV int.i64` of `BSAR y, 53` has fold a's opcode and mode, and folda's instruments counted 179 and 16 such conversions on an rg2-only build. [F, C]
    - *Fix:* key a signature count on operands, not only on opcode and mode.
16. **11.7, "Adding a catcher".**
    - *Found:* the list omits canon's catcher list, info's failure awk, and the header's catcher and arm lists. run_bitjit pins GENMODE, so a generator-mode catcher needs its own run function and R_ status (genrg2). [F, R]
    - *Fix:* complete the list.
17. **11.7 item 8, the negctl header.**
    - *Found:* the memory-safety argument rested on "no fold removes the int conversion from an int64 source", which fold a makes false. [F]
    - *Fix:* restate it on ABC/ULE, the length checks and ULT 64, as the combined header does.
18. **11.7 item 9, P34.**
    - *Found:* sabotages that change no value (PHIIDX, NOLOOPFOLD, RG2-SHR, RG2-52, RG2-OFF, RG2-PREROLL) need IR-shape or exit-count catchers. R's quote of 8.8 was not in the guide (VR). [R, VR, C]
    - *Fix:* add that and the examples.
19. **11.7, cost and splitting.**
    - *Said:* a full run takes about 8 minutes.
    - *Found:* with 37 arms the sweep took 5 selected calls, 21 minutes, and canon repeats in each (100-110 s). negctl's work directory is fixed at `$OCLJ_BUILD/negctl-bitop`, about 1.1 GB for 5 calls, so a verifier must copy a build. [VF, C]
    - *Fix:* give the split recipe and say that a selected run proves only its arms.
20. **11.7 item 2.**
    - *Said:* the script holds no tab and no backslash.
    - *Found:* negctl-bitop.sh holds 98 backslashes at HEAD (73 line continuations) and 120 combined. [VR, C]
    - *Fix:* scope the rule to anchor and arm texts.
21. **11.8, checks implied by others.**
    - *Found:* rg2's order check could never fail on its own. The combined verify_content's comment names which links can (C: 7 fail-firsts in `ps/ff`). [VR, C]
    - *Fix:* say to prove a check fails alone, or drop it.
22. **8.2 step 0 and step 6.**
    - *Said:* step 6 says to run the script on a pristine copy; step 0 does not cover two changes to one script.
    - *Found:* a pristine file comes from `git cat-file blob <pin>:src/<f>`, which is LF (build/native has no export dir). Counts like "`oclj_bitwidth(` on N lines" also count comments. Moving an include changes NADD. Two changes to one script merge with additive NADD (45+18+8=71), and git merge-file on the test files leaves predictable conflicts in the part lists. [F, C]
    - *Fix:* add these to step 0 and step 6.
23. **7.6, 8.4 step 1, checklist 15.**
    - *Found:* a new static function in an oclj_* file must also be called from build-native.sh's bitop_wgate.c, or `-Wunused-function` fails the warning gate. [R]
    - *Fix:* add that step.
24. **7.4, Linux make by hand.**
    - *Found:* copying the Linux tree from Git Bash fails on `host/buildvm` against `buildvm.exe`. Copy inside WSL with `cp -a`. [VF]
    - *Fix:* add that.
25. **11.3, 12.4: option sets and exit counts.**
    - *Said:* the ms0 row says "no side traces".
    - *Found:* a hot exit still gets a "fallback to interpreter" stub, and a patched exit fires no texit event. For a speculative guard the relevant sets also include -Ohotexit=1, -Otryside=1 -Ohotexit=2, -Omaxside=1 and -Ohotloop=1 -Omaxside=0; for an index fold, -O-abc, -O-narrow, -O-fuse, -O-fwd -O-dse and -O-sink. [R, VR, VF]
    - *Fix:* add those sets and the exit-count caveat.

### Measurement

26. **8.8 fourth bullet, 11.12.**
    - *Said:* time xorshift64 and `h ~ (i<<40) ~ (h>>3)` as the loops where the speculation fails; and "2^53 or more".
    - *Found:* both raise under U1-B. B-legal loops are needed (bench_spec.lua), and the range is "outside [-2^53, 2^53)". [R]
    - *Fix:* name the B-legal loops and correct the range.
27. **11.12, os.clock.**
    - *Found:* os.clock steps 1 ms, so a reading moves in steps of 1 ms / N (0.1 ns at 1e7, 0.05 at 2e7, 0.5 at 2e6). The guide gives an upper bound on N, not a lower one, and R's chain used 1e8 against 11.12. [F, R, VR]
    - *Fix:* state the quantum, and N between 1e7 and 2e7.
28. **11.12, results against PUC.**
    - *Found:* PUC's results differ where plain arithmetic passes 2^53: bench_bit2's rgb and ref (i * 2654435761) and ident's big rows. A cross-VM result check must expect it. [C]
    - *Fix:* add one sentence.
29. **7.6, build time.**
    - *Said:* 31-36 s.
    - *Found:* 48 s under another session's load [F], 37 s [R], 31.5 s quiet [C].
    - *Fix:* say it varies with load.
30. **12.6, 8.7: mcode sizes.**
    - *Found:* they vary by a few bytes between processes (746 against 752 for the same build). [VF, C]
    - *Fix:* compare within one process.

### Shell and instrument pitfalls

31. **P8.**
    - *Said:* heredocs eat backslashes.
    - *Found:* any tool command text does: printf, grep, and `python -c` with `b'\r'` (C: a SyntaxError). [VR, C]
    - *Fix:* say "any command text", and count with a Python file.
32. **P11, 12.4.**
    - *Found:* there is no recipe for counting trace events beside a script that attaches its own handler (wrap `jit.attach`), and a probe's own attach silences -jdump. [VR]
    - *Fix:* add the recipe and the warning.
33. **10 or 11.9.**
    - *Found:* never merge a suite's stderr into a diffed stdout: `#cov` lands mid-line. [VF]
    - *Fix:* add that.
34. **Checklist item 4, a new P.**
    - *Found:* never run `python -`: it hangs on stdin even with `</dev/null` on this machine. Four agents of this round ran it once each, by a stray token. [F, R, VR, C]
    - *Fix:* add the rule and the pitfall.

### Scope and upkeep

35. **8.8's framing.**
    - *Found:* fold a's effect is wider than table-driven CRC. Masked bit results used as keys through narrowing, or as counts, speed up 0.52-0.65 in smoke (ident, flag63, mix). [C]
    - *Fix:* reframe 8.8 after the main-session chain.
36. **Upkeep for the implementation commit.** [F, R, C] The commit must update:
    - the header's Next task;
    - 1.2 row 10;
    - 1.3 (the include now sits above simplify_conv_int_num);
    - 2.6 ("only the width rule");
    - 3.10's table;
    - 3.11;
    - 5.1 (`CONV int.i64` is now emitted);
    - 7.5's NADD (fold 63/8 with fold a alone, 71/8 with both);
    - 8.8;
    - 11.4 (GENMODE idx, rg2);
    - 11.5 (the idx and rg2 parts);
    - 11.7 (27 arms become 30 with fold a, 37 with both);
    - Appendix A;
    - oclj_bitop_rec.c's header.
37. **8.4a, open question 3: evidence to add.**
    - *Found:* math.random's call is followed by a snapshot, and a body range guard resumes past it (`dump-reexec-random-2.txt`). [VR]
    - *Fix:* cite it.
