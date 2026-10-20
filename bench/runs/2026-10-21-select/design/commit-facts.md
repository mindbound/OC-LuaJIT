# Commit facts: the select fix (roadmap row 213, JIT guide P54)

Facts a commit message needs, each marked [M] measured, [S] read in source,
[I] inferred, with the run, file or function behind it. Written by the fixer
(`claude-tmp/oclj/sel/fix`), 2026-10-21, on the working tree at HEAD
`e7eb613`. Nothing was committed; the user runs commit and push. The final
check (`sel/fix/final-check.sh`, md5 `d45910e9`) has NOT run end to end: its
result, the full 32-arm negctl sweep and the release natives belong in the
message only after the main session runs them
(`bench/runs/2026-10-21-select/logs/final-main/`, `logs/release/`).

## Suggested subject (the repo's style: one long sentence)

The select fix: compiled select(k, ...) gives the interpreter's results and
errors: rec_varg aborts the recording for a k above 2^27 and guards
1 <= k <= 2^27 before path C's 32-bit shift (patch-bitop-record.sh hunks 4
and 5), closing upstream's nil for a k whose 8k wraps, a k <= 0 in a call
with fewer arguments than parameters and a narrowing-wrapped k; with
t_select.lua and run-bitjit.sh's sel part, negctl's SELGUARD and SELRECK (32
arms), and the JIT guide's P54 rewritten as the record of the fix

## What ships

- **The fix** [S]: `native/luajit/patch-bitop-record.sh`, new hunks 4 and 5
  on `lj_record.c`. Hunk 4 defines `OCLJ_SELECT_KMAX` (0x08000000, 2^27)
  above `rec_varg`. Hunk 5, in `rec_varg`'s select path: `if (idx >
  OCLJ_SELECT_KMAX) goto nyivarg;` right after upstream's `idx < 0` abort,
  and on path C (a k beyond the varargs) `emitir(IRTGI(IR_ULT), k-1,
  2^27)` before the `BSHL`, so the trace exits unless 1 <= k <= 2^27 and the
  interpreter computes select. On the pin's pristine blob the script adds 22
  lines and removes 36 of 2966 (round 3's 7/35 plus 15/1) [M: the final
  check's PATCH-PRISTINE in `sel/fix/fc-smoke-hyg2/`, and the implementer's
  `sel/impl/ps1/`]; idempotent; output = the build copy, md5 `d490af9b` [M].
  `NMARK` stays 1 (the new hunks say `OC-LuaJIT:` without the script path),
  so `native/build-native.sh` is unchanged (md5 `47b9c52e`) [S][M].
- **Why this script** [S]: it is the only script that patches `lj_record.c`
  (JIT guide 1.2); build-native.sh's `BITOP_PATCHES` loop and negctl's
  `PATCHED` list patch each file with one script (guide 8.2 step 0). HEAD's
  roadmap row 213 named only "the patch script that already changes
  lj_record.c"; `patch-penalty-scrub.sh` (it patches `lj_func.c`) was never
  a candidate [S: `git show HEAD:docs/roadmap.md`, line 213].
- **Only `lj_record.o` changes** [M]: Windows (additive) 77 LuaJIT objects,
  only `lj_record.o` differs from `build/native`'s (`c536c2b9` against
  `81918b7d`), our 3 objects equal; the same in a fresh build of the final
  working tree (`sel/fix/ff-guards-1/java-real/cmp/`, W-objects PASS).
  AlmaLinux 8 with `OCLJ_GLIBC_MAX=2.28`: only `lj_record.o` (`a8e738ca`
  against `46e485f8`), GLIBC_2.17 at most [M: `sel/fix/fc-smoke-E/alma/`;
  the implementer's `alma1/`, the code verifier's `alma1/`].
- **The constant path's C overflow (the question asked)** [S][M]: path A's
  record-time `frofs+8*(int32_t)idx` is int arithmetic, undefined in C for a
  constant k from about 2^28 (2^28-2 with no fixed parameters, about 2^28-202
  with the most); our build compiles `lj_record.c` without `-fwrapv`. The
  shipped build wrapped it: `select(2^28, ...)` in a one-parameter function
  compiled `LT fr, -2147483621`, which always fails (25 trace starts, a root
  and 24 side traces, in 300 iterations); `select(2^29 + 5, ...)` wrapped to
  `LT fr, +67`, which passes with the right nil (one trace); values right in
  both [M: `sel/impl/probes/konst1-base.dump`, `konst1-base.jv`, re-read by
  the fixer]. With the fix the abort runs before that expression (`NYI:
  bytecode VARG`), same values [M: `konst1-b2.jv`].
- **k from 2^28 up** [S][I]: for an exact int32 k >= 1 upstream's path-C nil
  was right whenever the guard passed; the wrap only turned passes into
  exits. With the fix such loops run in the interpreter, same values.

## The bug, as measured on the shipped build (upstream's)

- **The report** [M]: verify-folda's `probes/selbug.lua` (7 varargs, a loop
  recorded with k = 100, then k = -2147483628): `-joff` prints `E 30 E 200`,
  JIT on `n 30 E 200`, on `build/native` and the 2026-09-01 upstream binary.
  On the fix's build both print `E 30 E 200` [M: the final check's
  SELBUG-new and SELBUG-base, `sel/fix/fc-smoke-B/runs/selbug/`].
- **Three classes, each nil where the interpreter raises "index out of
  range"** [S: `rec_varg` ~:2061-2070; M: `sel/impl/runs/diag-base-2/`]:
  (1) a k whose 8k wraps past the frame (-2^31+20, -2^29+20 and kin);
  (2) no wrap: k from m+1 to 0 in a call with m < 0 varargs (fewer arguments
  than fixed parameters; `fr` below `frofs`), measured with the sweep's own
  probe too [M: `sel/verify-code/runs/rank1-1/`]; (3) narrowing's unchecked
  outermost ADD/SUB of an INDEX conversion (`narrow_conv_emit`, int16
  constants only), so `select(x + c, ...)` reached path C within 2^15 of
  +-2^31.
- **No path loads through a wrapped index** [S, read by the main session,
  the implementer, the sweep, both verifiers and the fixer]: path C loads
  nothing; the only load is behind the unsigned ABC on k-1 (path B) or a GE
  guard against a record-time constant (path A).
- **Upstream** [M][S]: `rec_varg` at upstream's v2.1 tip `dd3b243`
  (2026-10-18) equals the pin's byte for byte and `lj_opt_narrow.c` is
  unchanged (the bare clone `sel/upstream.git`); no tip build was run. Not
  reported upstream (the user's call).

## Tests and proof

- **`test/native/bitop/t_select.lua`** (new, 417 lines, md5 `b2616108`,
  no backslash) [S]: 110 cases (3 controls first, 50 list cases on 4 shapes x
  classes B/C/H x sources pl/st/ap/am/an/bx, 4 loop-index cases, 52
  constants, kx-pl); part `puc` 106 cases.
- **`run-bitjit.sh` part 5 `sel`**, in the default parts (md5 `01cc9a17`)
  [S]: 15 option sets (`SELOPTS`), `-joff` reference, PUC on part `puc`,
  coverage gate (each path's guard, the fix's guard, the k = 2^27 controls),
  and `t_select-kmax` (no select trace in a loop recorded only above 2^27).
- **negctl-bitop.sh** (md5 `fbd42f2c`, 32 arms): SELGUARD [sel:t_select],
  SELRECK [sel:kmax]. Five selected runs, canon and restore passing in each:
  the implementer's four (SELGUARD 11-53 cases a set, 11-15 under
  `-Ohotloop=1 -Omaxside=0`; SELRECK kmax 2-3 of 3 a set; `sel/impl/runs/
  s-b2-negctl-1..4`) and the fixer's on the edited script (SELGUARD 13-53,
  SELRECK 3 of 3 every set; canon 115 s; `sel/fix/fc-smoke-D/`) [M]; the
  code verifier's a sixth (19-53, 3 of 3) [M].
- **Fail-firsts** [M]: the sel part on `build/native` FAILs in all 15 sets
  on Windows and in AlmaLinux 8, kmax too (the final check's BASE-sel and
  ALMA-base-sel, `sel/fix/fc-smoke-B`, `fc-smoke-E`); the k >= 1-only variant
  fails 11 of 15 sets; the code verifier's two guard sabotages (k instead of
  k-1; signed LT) fail all 15; `verify_content`'s count and order links fail
  alone.
- **Beyond the suite** [M: the code verifier]: `probes/vsel.lua`, 209 cases
  incl. stitched and lower-frame entries, 0 differences in 21 option sets on
  both platforms, 31-129 a set on `build/native`; the new guard shares exit 4
  (loop) / 1 (pre-roll) with the CONV guard and path C's own guard; +18
  bytes in a two-copy trace.
- **Speed (smoke reading only)** [M: `sel/fix/fc-smoke-T3/timing/
  summary.txt`, Java closed, CPU load 5-7%, 7 alternating rounds, N = 1e8]:
  new/base medians idx 1.000, cycle 1.000, beyond 1.000, vbeyond (k changes
  every iteration, the fix's guard in the loop body [M: its IR,
  `sel/fix/runs/vbeyond-dump-new.txt`]) 1.017 [1.008-1.017], konst 0.974,
  count 1.000; every result equal.

## Checked before the final check [M]

- The fixer's smoke runs of the final check on a fresh Windows build of the
  final working tree (`b-fix`, copy of `ff-guards-1/java-real/b/win`):
  build 7/7 PASS (`ff-guards-1/java-real/summary.txt`); base, suites, 9
  runners and negative-control.sh 20/20 (`fc-smoke-B`); bitjit, all five
  parts with PUC, sel 0 in all 15 sets, generator idx/rg2/phi 9/9
  (`fc-smoke-C`); AlmaLinux 8 and hygiene 33/33 (`fc-smoke-E`); timing 8/8
  (`fc-smoke-T3`); hygiene on the final docs 19/19 + 2 SKIP (`fc-smoke-hyg2`).
- negative-control.sh passed on this build in 578 s (`fc-smoke-B`); the final
  check leaves it out (no sabotage in `lj_record.c`).
- `git diff --check HEAD` clean; 0 CR in the 7 changed files; sh -n 0 in
  Git Bash, AlmaLinux 8 (bash) and Ubuntu (dash) for the three changed shell
  scripts and the final check (`sel/fix/runs/shn-final/`).

## Docs [S]

- `docs/jit-guide.md` (md5 `29844cd9`): P54 rewritten as the record of the
  fix; new P59 (a control loop that must compile can miss after an earlier
  abort: the penalty in the shared hot counter, [S][I]); new 11.5b (the sel
  part); 8.6 step 7; 8.5 step 2 (record-time C overflow; no `-fwrapv`); 3.13
  (narrowing's wrapped index); 1.2, 2.1, 2.5, 2.6, 7.5, 7.6, 8.2, 8.8, 9.6,
  9.8, 11, 11.2, 11.3, 11.7, 11.8, 11.9, 11.11, 12.10, Appendix A, glossary,
  open question 19. 89 line cites checked by content, 88 fail moved down,
  89 moved up (`sel/fix/runs/cite-check-fix-3*.txt`); 388 anchors, 44 tables.
- `docs/roadmap.md` (md5 `53708b13`): row 213 [x] (the record of the fix);
  new row 214 (the sweep's unfixed findings); row 211 (5) marked next; the
  upstream-reports row gains the select divergence; row 146 notes upstream's
  `2a8e017` (strtoull in `tonumber` with a base, after the pin).
- `test/native/bitop/t_idx2.lua` (md5 `f60e7948`): header only, its "NOT
  HERE: select" paragraph now says the divergence is fixed and select is still
  left out (whether it joins is open).

## The fixer's review: what changed (see the report for each finding)

Guide: 8.2 step 0 and row 213 no longer say row 213 named
patch-penalty-scrub.sh; P54/row 213 no longer call twin.lua stale; konst1
counts (25 + 1, not 26 for two loops) in P54, 8.5 and row 213; 9.8's
record-time abort (path C fails its guard; path A from 2^27+1 to ~2^28 was
a right nil); 11.7 item 8 (each arm removes one site; path A's load behind a
GE guard) and item 9 (t_select-kmax's loops are kx-pl and the constant
2^27+1); row 213's upstream claim marked; 8.6 step 7 and 9.6 scoped to
t_select's sources; the 2^30 + 1619 bound's premise; 7.6's work-directory
size; P59's date; P6's marks; 3.13's ADDOV sentence; 11.5b's case count, its
selA, a by-hand line and the uncovered stitched/lower-frame routes; 9.8's
machine-code evidence; 11.7's cost sentence; the 11.8 row for this final
check. negctl-bitop.sh: header comments only, line count unchanged (876),
backslashes unchanged (110/85): three runs -> four, 7-8 s -> 7-9 s, the
"estimated, not yet measured" 12 minutes replaced by the measured 14 min 3 s,
SELRECK's and the memory-safety wording. Roadmap row 214 (4) and row 146:
`2a8e017`.

## Open, for the user

1. Keep SELRECK's record-time abort (changes no value; removes path A's C
   overflow and an always-exiting trace; the second fix site)?
2. `OCLJ_SELECT_KMAX` = 2^27 (a choice in [65500, ~2^28-202])?
3. Select in t_idx2.lua, or is t_select's bx source enough?
4. A stitched / lower-frame wrap in t_select (the code verifier's vsel.lua
   covers it)?
5. Report the divergence upstream?

## After the final check, update before committing

- Roadmap row 213: the sentence "Left by the implementer to the main
  session, and not yet run when this row was written: ..." -> the final
  check's results (32-arm sweep, timing, release md5s); confirm the archive
  path `bench/runs/2026-10-21-select/` (cited in row 213, guide 11.7 Cost and
  Appendix A evidence).
- Guide 11.11's "more with the select fix's 32 [I]" -> the measured time.

## Files and md5s

Repo working tree (vs HEAD `e7eb613`): `docs/jit-guide.md` `29844cd9`,
`docs/roadmap.md` `53708b13`, `native/luajit/patch-bitop-record.sh`
`b218585d`, `test/native/negctl-bitop.sh` `fbd42f2c`,
`test/native/run-bitjit.sh` `01cc9a17`, `test/native/bitop/t_select.lua`
`b2616108` (new), `test/native/bitop/t_idx2.lua` `f60e7948`. README.md
unchanged (`98f6042d`); build-native.sh unchanged (`47b9c52e`).
Final check: `sel/fix/final-check.sh` `d45910e9`, `fc-summarize.py`
`74db422b`, `fc-bench_sel.lua` `70dfdac8`, `fc-selbug.lua` `96ffbad1`
(= verify-folda's selbug.lua), `fc-citecheck.py` `e22de212`,
`fc-anchorcheck.py` `d02e23e4`, `fc-tablecheck.py` `8bf1f616`.
