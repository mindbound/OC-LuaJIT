# 2026-10-23 -- the int/i64 CSE twins: lj_opt_cse never commons an int64 instruction with one of another type

The evidence behind roadmap row 271 (the int/i64 CSE twins) and [docs/jit-guide.md](../../../docs/jit-guide.md)'s
P63, and behind what the guide says of run-bitjit.sh's `cse` part (its 11.5d) and negctl's 37th arm (its 11.7).
The round ran on 2026-10-23 in scratch (`claude-tmp/oclj/csetwin/`), on a scratch copy of the repo (HEAD's tree,
`git archive`, plus the round's eight files): a design from three read-only parts, then five stages, impl-code and
impl-tests in parallel, integrate, verify-code and fix. The real repo was only read. The bug itself was found the
same day by the shift-exactness round ([`../2026-10-23-shiftexact/`](../2026-10-23-shiftexact/README.md), `cse/`).

## What is here

Paths inside the stage reports are relative to the scratch `claude-tmp/oclj/csetwin/round/`; here impl-code is
`code/`, impl-tests `tests/` and verify-code `verify/`, each stage with its returned report as `REPORT.md`.

- `design/`: `options.md` (the fix options, read in source; no luajit, Lua or build ran). The design itself and
  its producer census stay in scratch (`claude-tmp/oclj/csetwin/design.md`, `census/census.md`; `md5s.txt` lists
  them): written before the user's decisions, they sketch reverse-order slot shapes at the level of code (see
  "Never run"). Where the design said "cserev gated", "28 cases" or "18 pairs", the stage reports supersede it.
- `code/`: hunk 12 written, its build and object comparisons (`cmp/`, `objdiff/`), the patch script's fail-first
  (`ff-patch-3/results.txt`, 65 of 65; `ff-instr-1/`, the harness's own fail-first), the runners on the new build
  (`run-fix-1/`), a forward smoke reading with the shift-exactness round's probe (`smoke-fwd-1/`, `smoke-fwd-jv-1/`).
- `tests/`: the `cse` part's first form (`run-bitjit.diff`; the three test files' first md5s in
  `deliverables.md5`, the final ones being in the commit), two one-file prototypes built by hand, not by
  build-native.sh (`proto-fix/`: its `lj_opt_fold.o` `a6c5fcc2` is the same bytes as the fixed build's;
  `proto-fwd/`: `ccf83851`, CSEFWD's), and every run's log, exit code and time (`runs/`), with the 19
  fail-firsts (`runs/ff-*`).
- `integrate/`: the files applied to the scratch repo (`apply-manifest.md5`), negctl's CSEFWD arm and its plumbing
  (`logs/negctl*.diff`, `ff-check/`, `ff-anchors/`, `anchors-1/`, `logs/anchors-1.log`), the first CSEFWD run
  and the catchers' end-to-end fail-first (`runs/negctl-cse-1.log`, `runs/negctl-ff-1.log`; `negctl-work/` keeps
  both work directories' logs), T4's refusal census (`t4/`, `t4-census-1/`, `runs/t4-cse-1/`), the
  AlmaLinux 8 build (`alma1/`), and the smoke timing with its fail-firsts (`timing/`).
- `verify/`: the code verifier's own build, prototype (`pfwd/`) and instrument, its probes of a pair formed only in
  the loop copy or only in a side trace (`probes/`, `runs/bodyfwd-1/`, `runs/sidefwd-1/`, the IR dumps), its
  `verify_content` mutations (`runs/ffpatch-1/`) and its refusal census (`runs/t4c-*`). Its report's findings are
  in `REPORT.md`'s REST part.
- `fix/`: the fixer's facts for the commit (`commit-facts.md`, the map of every number in the docs), the code as a
  patch against HEAD (`code.patch`, `8a126631`, with `code-files.txt` and `repo-eight-end.md5`), the final check and
  its helpers (`final-check.sh`, `fc-*`), the fixer's builds' records (`logs/`, `cmp/`, `alma1/`), runs (`runs/`:
  the `cse` part on `build/native` six times and on the fixed build three, each run's log, and the outputs of
  `cse-base-5`, `cse-base-6`, `cse-fix-3` and `alma1/`'s two; the fail-firsts; the cite checks), the two CSEFWD
  runs (`runs/negctl-cse-*`, `negctl-work/`) and the final check's smoke runs and refusals (`smoke/`).
- `final/`: the final check's outdir, without its builds, HEAD's exported tree and the run outputs other than the
  `cse` part's (see "Not here").
- `release/`: the release's logs and md5 lists.
- `md5s.txt`: every file's md5 as it is in scratch (with the copy's md5 where line ends, colour codes or the
  redaction below changed it), the files not copied with their md5s, the binaries the runs used, and the
  directories left out whole with their file counts and sizes. `scripts/mkcse.py` wrote every file here; this
  README is its draft's, with the final check's and the release's numbers filled in.

## The bug [M: `../2026-10-23-shiftexact/cse/run-3/`; `code/smoke-fwd-1/`][S][I]

`lj_opt_cse` matched an instruction by opcode and operands (`op12`) and returned the existing one with that one's
type. On x64 `simplify_conv_sext` folds our `CONV i64.int SEXT` to its int operand (an int loop index with a
constant lower bound >= 0, `ADD idx, k`, a u8/u16 load such as `string.byte`'s), so our int64 `BNOT`, `BAND`,
`BOR`, `BXOR`, `BSHL`, `BSHR`, `BSAR`, and the `ADD` that `x << 1` becomes, could share `op12` with a 32-bit
instruction [S: the design 1.1-1.2, in scratch].

- **Forward order** (the 32-bit instruction first): our 5.3 operator got its value, zero-extended: wrong for `BNOT`,
  for `BSHL` with x * 2^k >= 2^32, and for variable counts of 32 or more. On `build/native`'s `luajit.exe`
  (`f4038cd6`), `bit.lshift(i, 3)` then `i << 3` read 341 of 401 wrong, and `bit.bnot(i)` then `~i` 341 of 401; 682
  mismatches in all, 0 under `-joff` and 0 on the fixed build (`code/smoke-fwd-1/summary.txt`).
- **Reverse order** (ours first): a 32-bit recorder gets an `I64`-typed ref; where it stores it in a Lua slot, a
  snapshot carries it and `snap_restoreval` has no `I64` case. Crash-class by reading [S][I: the design 1.3,
  in scratch], and never run on any build (below).
- **In game** no wrong value is known: the game opens lj52shim's C `bit32`, not LuaJIT's `bit`, and FFI is off; the
  three pair families the game can form are value-right in the forward order, and in the reverse order one of
  them, `x << 1` before an inner `for j = x, n, x` recorded in the same trace, is a crash candidate by reading,
  never run [S][I: the design 1.4-1.5 and the census, in scratch]. By reading only, the same reverse can also
  arise from a pair that forms only in `loop_unroll`'s copy, from operands that differ at record time (the code
  verifier's finding 3, `fix/commit-facts.md` 6) [I]: never written or run; hunk 12 covers both routes.

## The fix [M][S]

`native/luajit/patch-bitop-fold.sh` hunk 12 (the user's decision D1, the design's B-i64): the match in
`lj_opt_cse` also requires `irt_isi64(IR(ref)->t) == irt_isi64(fins->t)`. A refused candidate keeps the walk
going, and a refused match emits what `-O-cse` would. The two comment-only edits (`oclj_bitop.h`,
`oclj_bitop_rec.c`) move no object [M: `code/cmp/commentonly-vs-buildnative.txt`, 80 of 80 equal].

- The patch line: 12 hunks, 76 lines added and 9 removed, of 2720 on the pin's `lj_opt_fold.c` (`15c7420c`) and
  of 2730 on upstream `a4c0645`'s (`0f28177c`); idempotent; its output is the build copy (`59778bb6`) [M:
  `code/ff-patch-3/results.txt`, `fix/runs/fc-ffpatch-1/results.txt`; the build copy, `fix/smoke/s1/summary.txt`
  PATCH-IS-BUILD-COPY].
- Objects: of 77 LuaJIT objects and our 3 only `lj_opt_fold.o` changes, `f6d916e2` to `a6c5fcc2` on Windows and
  `57970a51` to `1b4a7c13` in AlmaLinux 8 (GLIBC_2.17 needed) [M: `fix/cmp/`, `fix/alma1/summary.txt`]; in it only
  `lj_opt_cse` differs, 67 to 83 instructions of 155 functions [M: `code/objdiff/`].
- `verify_content` checks hunk 12's line by text, place and neighbours (`code/`), and, after the code verifier's
  finding 1, that `lj_opt_cse` names `op12 == op12` on one line and `return` on two: the round's earlier script
  passed the verifier's m1-m4 and the fixer's m5-m6 (extra match lines, or a stray `op12 == op12`), rc 0; the
  final one refuses each, rc 1, and each new count fails alone [M: `verify/runs/ffpatch-1/`,
  `fix/runs/ffpatch-1/`, `-2/`, `fc-ffpatch-1/`]. Not checked: a macro redefining `irt_isi64` inside the hunk [I].

## The tests and their readings [M]

run-bitjit.sh's part 7, `cse`, in its default parts: `test/native/bitop/t_csefwd.lua` (32 forward cases: 13
whose served value is wrong, 7 whose served value is right, 12 controls; values against `-joff` in 15 option sets
and a plain-arithmetic reference), `cseir.lua` (the IR reader: `served`, `split`, `rserved`, `direct`, `i64slot`,
in 12 sets) and `t_cserev.lua` (8 cases: the two reverse shapes that put no int64 ref into a slot, `select` beyond
its varargs and a narrowed `string.byte`/`string.sub` argument, 4 cases, and 4 controls; against `-joff` in 15
sets and against PUC 5.3.6).

Option sets are named as in run-bitjit.sh's `SELOPTS`; `fix/commit-facts.md` 3.1 has every per-set count.

- **`build/native`, unfixed** (`luajit.exe` `f4038cd6`; `fix/runs/cse-base-1.log` to `-6.log`, `fix/alma1/base-cse`
  on its Linux `luajit` `cb68e454`): the part FAILs, as it must.
  - t_csefwd: 13 cases wrong in 6 sets in every run and in a 7th (`he1`) in 6 of 7 runs; 12 in `noloop`, `ms0` and
    `hl1ms0` (13 once); 2 (`u8sh30`, `side`) under `-O1` and `-O-narrow`; 0 under `-O0`, `-O-fold` and `-O-cse`.
    No value-right case and no control was ever wrong.
  - cseir, in every run with its final judge (`cse-base-2` to `-6`, `alma1/base-cse`): 20 of its 32 cases FAILED
    in 7 sets, 19 in 3, 2 in 2; every failed pair with `served` at least 1. `cse-base-1`, read by cseir's first
    judges of `copy` and `side`, read 21 under `ms0` and `hl1ms0` and 3 under `-O-narrow`.
  - t_cserev: its 4 reverse cases merged (`rserved` at least 1, `split` 0) in the 10 sets with narrowing; every
    value right, and PUC 5.3.6 equal to `-joff`.
  - The case `copy` (a pair formed only in the loop copy) read 336, 393 and 393 of 400 wrong over its three calls,
    and `side` (a pair formed only in a side trace) 285, 295 and 295 of 600
    [`fix/runs/cse-base-6/cse/t_csefwd-jon.txt`]; both came from the code verifier's probes
    [`verify/runs/bodyfwd-1/`, `sidefwd-1/`].
    Whether `side` reads wrong under the `-Ohotexit=1` and `-Omaxside=0` sets varied between runs (a trace may or
    may not compile its branch), so its per-set counts are ranges; the base reader judges it in the default set.
- **The fixed build** (`fix/runs/cse-fix-2.log`, `cse-fix-3/`; `fix/alma1/cse`): t_csefwd 0 in all 15
  sets, "a trace completed in 32 of 32 cases; 20 of 20 pairs formed, served 0, split 38"; cseir 32 of 32 ok in its
  12 sets; t_cserev 8 of 8 ok in 15, its reverse pairs kept apart (`split` 2). All seven parts PASS in 74 s
  (`fix/runs/bitjit-all-fix-1.log`), and in AlmaLinux 8 (`fix/smoke/s4/summary.txt`). `fix/runs/cse-fix-1.log`'s FAIL
  is cseir's first judges of `copy` and `side`, corrected after it (`fix/commit-facts.md` 3.1).
- `i64slot` (a snapshot naming an int64 instruction) read 0 in every case of every run of the round, on every
  build, the unfixed one included.
- Fail-firsts: impl-tests' 19 mutations of the three files (`tests/runs/ff-*`), the fixer's text and gate
  mutations (`fix/runs/fc-fftests-1/`), and the base reader's, each build's output read as the other's
  (`fix/fc-basecse.py`; `fix/smoke/s1`, `s2-baseisnew`, `s3`).

**negctl.** CSEFWD, the 37th arm, lets only the forward merge back in (`|| irt_isi64(fins->t)`): memory-safe by
construction. Caught by `cse:t_csefwd` and `cse:cseir` in each of its three selected runs, canon 108-112 s and
CSEFWD 12 s, restore PASS [M: `integrate/runs/negctl-cse-1.log`, `fix/runs/negctl-cse-1.log`, `-2.log`]. No arm
holds the reverse order: its sabotage would be crash-class. The catcher plumbing's fail-first gave 16 of 16 wanted
verdicts where HEAD's text gave 10 [M: `integrate/ff-check/`].

**T4, the refusal census.** An instrumented scratch build (never shipped) printed a line each time hunk 12 refused
a match: 830 in the `cse` part as it stood before `copy` and `side` (its fail-first), and 0 in every other suite
it ran (gen, floor, fix1, idx, sel, nc with two side-trace sets added, run-bitop.sh, direct runs; the verifier's
own census added run-bitfuzz.sh and other seeds) and in the four benches, so in them the fix changed no CSE
decision; neither census ran the nine native runners, the generator's idx, rg2 and phi modes or the JVM harness
[M: `integrate/t4-census-1/`, `integrate/runs/t4-cse-1/`, `integrate/timing/t4-benches/`, `verify/runs/t4c-*`]
[S: the predicate is the change's only effect].

**Timing, a smoke reading.** `build/native`'s `luajit.exe` against the fixed build, 8 rounds alternating, the four
benches' 21 rows: every result equal and every row's median new/base 1.000 [M: `integrate/timing/run-1/`].

## The user's decisions (2026-10-23)

1. **D1, the fix:** B-i64, the type test in `lj_opt_cse` (hunk 12).
2. **D2, the reverse order:** tested only in the two shapes whose 32-bit consumer stores nothing in a slot (T3-lite).
   The design's gated `cserev` part with slot cases was not built; `t_cserev.lua` runs ungated in the default `cse`
   part, on every build, negctl's canon included.
3. **D3, upstream:** stock LuaJIT with FFI has the same class by reading; not verified or reported now (row 269).

## Never run

- **No reverse-order case that can put an int64 ref into a Lua slot, on any build, at any time:** no inner `for`
  loop after our operator, and no `bit` library call after it. The only reverse-order cases anywhere are
  `t_cserev.lua`'s four, in the two shapes that store nothing in a slot (D2). The file refuses any case text naming
  `bit` or holding a second `for `; that check's fail-first adds a Lua comment to a case's text and runs under PUC
  5.3.6 and `-joff` only; the verifier's proposed fail-first, which wrote the slot shape, was rejected [M:
  `fix/runs/fftests-*`, `fix/commit-facts.md` 3.2]. The design and the census, written before the user's
  decisions, sketch reverse shapes at the level of code, for a gated part that D2 replaced; none was written as a
  test or run, and both stay in scratch. This archive keeps no reverse slot shape beyond the shape family that
  roadmap row 271 names: where `verify/REPORT.md`, `fix/REPORT.md` and `fix/commit-facts.md` quote the verifier's
  rejected fail-first or spell out its loop-copy route as code, the copy reads "[code redacted in the public
  archive]" (`scripts/mkcse.py`'s `FREDACT`; `md5s.txt` gives both md5s). The patch-script mutations that allow a
  reverse match (in `code/`'s, `verify/`'s and `fix/`'s fail-firsts of `verify_content`) only patch a copy of
  `lj_opt_fold.c`, to show which script text refuses them; nothing was built from them.
- No black-box census A/B: no known workload reaches the reverse order, so it would read 0 against 0 (design 4.8).
- Upstream's reproducer (D3), and no in-game test.

## The final check [M: `final/`]

`fix/final-check.sh` (md5 `c4e69de1` as run), by the main session from Git Bash (it refuses to time with a Java
process running), on the scratch repo with the round's eight files: build (Windows), alma (AlmaLinux 8, and `sh -n`
in Ubuntu's dash), bitjit, base (the fail-first on `build/native`), suites, negctl, runners, hygiene and timing,
with censuses of `build/`, the pristine checkout, the real repo's git state and the scratch repo before and after.
Its parts first ran separately with knobs, on earlier texts of the script, and its refusals were each made to fire
(`fix/smoke/`, `fix/commit-facts.md` 4).

- **Verdict:** **83 PASS, 0 FAIL, 0 SKIP, VERDICT PASS**, in 1538 s (26 min), from 2026-10-23T13:38:02Z.
- **negctl,** the full 37-arm sweep in one call: PASS in 865 s, its work directory 947 MiB (4952 files;
  `final/negctl-work/` keeps its logs).
- **timing,** a smoke bound against a gross change, not a speed claim: RESULTS: EQUAL; GROSS: OK (every row's median
  new/base within [0.5, 2]); ALL: the 21 rows' median new/base ratios have median 1.000 [1.000-1.056]; 8 rounds, CPU
  load 12% before and 8% after.

## The release [M: `release/`]

After the final check: the dist DLL `a2fcae89`, the .so `dd3ab258`, and the jar `db1633cf`.
`scripts/release.sh` (FIX-NUMCONV's, which refuses unless the repo's eight round files have the md5s the final check
pinned, `fix/repo-eight-end.md5`) rebuilt `build/native`, dropin then additive, on Windows and in AlmaLinux 8 with
`OCLJ_GLIBC_MAX=2.28`; all 80 objects of each platform's additive tree equal the final check's, and both dist natives
carry the pin's fingerprint. The JVM harness's seven arms on each platform read the glibc round's counts (82, 69, 80,
76, 53, 82, and bundleoff 82 with its 3 expected failures), and gradle `verifyModAssets` and `build` pass. The jar
is `-dirty` because the round was not yet committed when it was built.

## Not here

- The design and its producer census (see "What is here" and "Never run"): in scratch, `md5s.txt` lists them.
- Upstream's reproducer (`up-cse-fwd.lua`, `run-upcse.sh`), the upstream part's report (`upstream.md`) and its
  source exports (`src-pin/`, `src-tip/`): the user decided not to verify or report upstream now (D3). They stay
  in scratch, `claude-tmp/oclj/csetwin/upstream/`; `md5s.txt` lists them.
- Binaries and build trees (every `OCLJ_BUILD`, the prototypes' and instruments' trees, tars): their md5s only.
  LuaJIT's sources, pristine, patched or upstream's: md5s only.
- negctl's work directories (155 to 162 MiB each; `md5s.txt` section 4 gives each one's size): their summaries,
  logs and object md5 lists only.
- Run outputs other than the `cse` part's (the generator, run-bitop, run-bitfuzz, the runners), and, of the
  stages' runs, the `cse` part's outputs but `cse-base-5`, `cse-base-6`, `cse-fix-3` and `alma1/`'s two
  (`bitjit-all-fix-1`'s whole tree among them): each run's log keeps its verdict and per-set counts. The scratch
  repos and HEAD's exported trees, and the machine's process lists.
- `final-check.sh` and `final/logs/checks.log` hold, as run, the pattern of the check that no forbidden scratch path
  reached the round's added lines; here it reads `PRIVATE-SCRATCH-PATHS`, and `md5s.txt` gives both md5s. The same
  holds for the one path `scripts/mkcse.py` refuses as a source.
