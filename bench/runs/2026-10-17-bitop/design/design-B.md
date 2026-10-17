# Round 3: the decided design (addendum to `r3/synth/design.md`)

Written 2026-10-17 by the main session after the user's decisions. **Where this file and `design.md` disagree, this file wins.** Everything `design.md` says that this file does not change still holds: its facts F1-F18, its file plan (§8, with the changes below), the build gates (§4), the fingerprint (§5), the tests' shape (§6), the docs (§10), and the implementer rules (§0).

## 1. The user's decisions

- **U1 = B.** A result with more than 53 significant bits raises an error. Every result that does not raise equals Lua 5.3.6's exactly. The user's reasons: a wrong value is always worse than an error, and the error has a remediation path in user code (mask before shifting).
- **U2-U10:** as `design.md` recommends (refuse 2^63; coerce strings; "no integer representation"; LuaJIT's message shape with 5.3's verb; JIT on; no metamethods; keep `~>>`, 64-bit; keep LuaJIT's lexer; `bit`/`bit32` untouched).
- **The width-fold speed bug** is fixed: the reviewer's fix1 (§3.4).
- **The test gap** is closed: the reviewer's generator ships, in its B form, and negctl holds every fold-rule sabotage to it (§5).
- **Bitwise metamethods:** a later round, together with `//` and `__idiv` (one change to the metamethod table and its layout gates), after the CRC32 follow-up. Docs only in this round (§7).
- **The full CRC32 speed fix** (the reviewer's rg2 range guard, and the table-index fold) is follow-up work after round 3. It is not in this round.

## 2. The B semantics, in one place

- An operation whose 64-bit result r has a double d with `(int64)d == r` (that is, r has at most 53 significant bits) returns d.
- Any other result raises: **`result of '<op>' has more than 53 significant bits`**, with `<op>` one of `~` (BNOT), `&`, `|`, `~` (BXOR), `<<`, `>>`, `~>>`. The message gets the usual `chunk:line:` prefix (the slow path's `ob_errv`).
- This applies everywhere the operators compute: the parser's constant folding (an inexact constant result is NOT folded; the run time raises, as for an operand with no integer representation), the interpreter's fast and slow paths, and the JIT.
- Examples, measured on the prototype against PUC 5.3.6 (`r3/b/probes/bprobe-*.txt`):
  - raises: `-1 >> 1`, `~0 >> 10`, `(1 << 62) | 1`, `~(2^53)`, `2^60 | 1`, and `(n >> 8) & 0xFF` for n = -2 (at the `>>`);
  - computes, equal to PUC: `1 << 62`, `~0 >> 11` (2^53 - 1), `~(2^53 - 1)`, `-2^63 | 0`, `((n & 0xFFFFFFFF) >> 8) & 0xFF` (255).
- U9's literal case is unchanged by B: the lexer rounds a hex literal with more than 53 significant bits before any operator sees it, so `0x00ff00ff00ff00ff & 0xff` is 0 here (PUC: 255). This is a LEX-class deviation; it is documented and gets a `t_fold` case. Census: no such literal exists (main-session grep, 2026-10-17).

## 3. The code (normative)

The normative implementation is the composite of three steps, applied to the pristine pinned tree:

1. `r3/synth/proto/apply_r3.py` variant `full`;
2. `r3/review/widthfold/builds/fix1.py` (fix1);
3. `r3/b/proto/delta_b.py` variant `full`, with the B versions of the three new files in `r3/b/proto/` (`oclj_bitop.h`, `oclj_bitop_meta.c`, `oclj_bitop_rec.c`).

The built reference is `r3/b/bB/src` (luajit.exe md5 `702b747a17d5`). Its six patched LuaJIT files (`lj_parse.c`, `vm_x64.dasc`, `lj_meta.c`, `lj_record.c`, `lj_opt_fold.c`, `lj_bcdump.h`) are exactly pristine + those three steps (CRLF; compare with CR stripped). The shipped patch scripts must reproduce them, except for the deliberate differences in §3.5.

### 3.1 `oclj_bitop.h`
- `oclj_bit2num(uint64_t r, double *d)` returns 1 and the double, or 0 when inexact. It refuses 2^63 before converting back (C99 6.3.1.4).
- `OCLJ_IRCONV_EXACT 0x0400`: a mode bit of a CONV's op2. LuaJIT 2.1 does not use it. It lies inside `IRCONV_MODEMASK` (0x0fff), so `cse_conv` (`lj_opt_fold.c:1286-1302`) never merges a marked with an unmarked conversion. It lies outside the fold key's `0x3ff` (`lj_opt_fold.c:2566`), so every CONV fold rule still matches. The source contains no other use of bit 0x400 in a CONV op2, and every exact op2 comparison in LuaJIT is against `IRCONV_NUM_INT` (grep, 2026-10-17: `lj_snap.c`, `lj_opt_sink.c`, `lj_asm.c`).

### 3.2 The interpreter (`vm_x64.dasc`)
After the 64-bit operation and `cvtsi2sd`: `cvttsd2si` back, `cmp` with the int64 result, `jne` to the C path, which recomputes from the untouched operand slots and raises. BC_BNOT uses `TMPR` for the conversion back (RA and RD must survive for `->vmeta_bnot`); `ins_bitop` uses RA (free after the operation; `->vmeta_bitop_pc` reloads RA and RC from PC). See `delta_b.py`.

### 3.3 The recorder (`oclj_bitop_rec.c`)
- **Record-time check:** the operands' values now are converted (`oclj_rec_bitval`), and if this iteration's result is inexact the trace aborts (`LJ_TRERR_BADTYPE`): the interpreter is about to raise anyway.
- **The result:** `d = CONV num.i64 res` with the exact mark. Unless `res` is a constant, it is followed at once by its guard: `back = CONV i64.num d` (`IRCONV_ANY`, and the exact mark, which here means "this is the guard's own check") and `EQ.i64 back, res`.
- **An operand's back-conversion is marked too** (`back = CONV num.i64 i`, exact mark, then `EQ.num back, tr`). Past that guard, back equals tr, an integral double, so it is i exactly. When tr is itself a marked result, i folds to that result's int64, back commons with tr (`cse_conv`), and the guard `EQ.num tr, tr` is dropped by `comm_equal`'s "converted integers cannot be NaN" case (`lj_opt_fold.c:1978-1987`).

### 3.4 The fold engine (`lj_opt_fold.c`)
Four changes (the first three as `design.md` D6; the fourth replaces the A width fold's role):
1. The seven `#if LJ_HASFFI` int64 bit folds become `#if 1`.
2. `narrow_convert` returns NEXTFOLD for an i64 CONV.
3. **The exact-mark rule:** in `simplify_conv_i64_num`, before `PHIBARRIER`: `(i64)(num)y ==> y` when the inner conversion is marked exact and the outer one is not.
   - **Why it is sound:** the guard is emitted directly after the marked conversion, so it precedes every use in trace order. The loop copy keeps that order. A value carried by a PHI is the pre-roll's or the previous iteration's, and each passed its guard. Values that reach a trace from outside (stack slots, tables, upvalues, a parent trace's snapshot) arrive as plain doubles, never as a marked CONV. Store-to-load forwarding hands back the stored ref, whose guard preceded the store.
   - **What it buys:** an earlier result used by a later operator never makes a round trip through a double, and a value carried between iterations becomes an int64 PHI.
4. **The width rule** (A's `oclj_bitwidth` and `oclj_kwidth`, unchanged): `(i64)(num)y ==> y` when the bound is 54 or less.
   - **Its role under B:** removing guards. The guard's own conversion folds to `res`, so `EQ.i64 res, res` folds away.
   - **Soundness:** the reviewer's argument (`r3/review` widthfold verdict). The bound reads only opcodes, IR types and constants. Types are iteration-invariant (`lj_opt_loop.c:343-352` converts or raises TYPEINS). Every outside value enters through a num-to-i64 CONV, which scores 64. `design.md` §3.5's step 3 is not what the code relies on: correct its text when documenting.
   - **fix1:** both rules are guarded by `(irt_isi64(IR(fleft->op1)->t) || !irt_isphi(fleft->t))`. Across a PHI, fold only to an int64-typed y; otherwise `x = i | 0` hands the int loop index (via `simplify_conv_sext`'s x64 LEFTFOLD) to an int64 PHI, `loop_unroll` raises TYPEINS, and the loop is blacklisted.

### 3.5 Deliberate differences from the reference tree
- **Move `oclj_kwidth` and `oclj_bitwidth` out of the fold patch** into a new tracked file, `native/luajit/oclj_bitop_fold.c`. The build copy's `lj_opt_fold.c` `#include`s it directly above `simplify_conv_i64_num`. The `LJFOLD` rule body stays in `lj_opt_fold.c`, because `buildvm -m folddef` scans only that file for `LJFOLD` lines. `build-native.sh` copies and `cmp`s it like the others, and its own `-Wall -Wextra` gate covers it.
- **D4 factoring** (`oclj_num53.h`), as `design.md` D4 says. Then `oclj_bitop_meta.c` uses it instead of its own `ob_str2int`/`ob_str2d` twin.
- **Comments** may be rewritten for the shipped files. Keep the facts, the file:line references and the reasons. Drop "PROTOTYPE" and "scratch".
- `oclj_bitop_rec.c`'s header comment must describe B (the guard, the marks, the record-time abort), not A's "nearest double".

## 4. Measured on the prototype (`r3/b/`)

- **Speed**, best of 3, same run, no Java running (`b/bench/bench-1.txt`, `b/bench/p4v-bB.txt`). Columns are today, then A + fix1, then B:

| loop | today | A + fix1 | B |
|---|---|---|---|
| bit loop, ns/it | 0.35 | 0.35-0.40 | 0.35-0.40 |
| RGB, ns | 3.6-3.7 | 3.7-3.8 | 3.6-3.8 |
| CRC table, ns/byte | 2.8-2.9 | 14.0-14.1 | 7.2-7.3 |
| CRC bit-serial, ns/byte | 48-49 | 100 | 70 |
| p4 `x = i \| 0`, s | (32-bit result) | 0.023 | 0.005 |

- **Generator, B form** (`b/gen`; `b/runs/gen-sw1/`): 20 seeds × 2000 loops × 7 starts, shared and fresh closures, five JIT option sets against `-joff`: 0 differences. The PUC 5.3.6 twin with `X()` equals `-joff` in every cell. 115,529 of 280,000 start-runs (shared) raise the new error, so the JIT's error exits are exercised.
- **Sabotages caught by that generator** (`b/runs/neg-b-1.txt`), counted as differing lines per 2000-loop seed over seeds 1-4:
  - `selfguard` (the mark rule also folds the guard's own check): 476-524;
  - `w55`: 148-168;
  - `shr` (BSHR bound 64-k): 62-79.
- **Spot checks:** `b/probes/bprobe.lua`. JIT equals `-joff`; every non-error result equals PUC.

## 5. Tests: what changes from `design.md` §6

- **Expected outputs come from PUC 5.3.6 mechanically**, never by hand. The PUC side applies the B rule per operator as an `X()` wrapper: the result's double if `math.tointeger(r + 0.0) == r`, else an error. This is how the generator's twin works (`r3/b/gen/mkgen_b.py`). For the matrix (`t_ops`, `t_fold`, `t_sar`), the provenance check becomes:
  1. PUC + X, reworded, differs from `.expect` in exactly `deviations.txt`'s ids (LEX, `//`, RESID-varinfo, and the new LEX case of §2).
  2. Separately, a PUC raw run (no X), printing integer results with `%d` (not `%.17g`, which hides inexactness: `design.md` §6's instrument note), shows that the cases where X raises are exactly those whose raw integer result has more than 53 significant bits. This checks the X rule against PUC's own integers.
- **Fuzzer** (`run-bitfuzz.sh`): the REF rule is per-operator X. A's rounding controls (sim-rta, sim-rtz) become:
  - `sim-round`: A's rounding instead of raising. It must FAIL in exactly the tuples where X raises.
  - `sim-raw`, unchanged in spirit.
  
  The comparator keeps F13's pattern. The error kind for the new message is a new class, `E:INEXACT`.
- **The generator ships:** `r3/b/gen/gen.lua` and `drv.lua` (the B form; credit the reviewer's `r3/review/widthfold/gen`). Put them in `test/native/bitop/`, with a runner (`test/native/run-bitjit.sh`) that does the following:
  - Generates seeds × cases into a fresh directory under the given output root (never clearing one).
  - Runs five option sets × two closure modes against `-joff`, and the PUC twin when PUC is available.
  - Gates on 0 differences, and prints a coverage line (cases, error runs, error runs past iteration 60).
  - Its default must run in under 2 minutes. The campaign size is a parameter.
  - It also ships the `t_rec`/`t_jit2` floor (from `r3/synth/probes`, re-checked under B). `t_sar` belongs to C1's matrix part (`run-bitop.sh`), not here.
- **A fix1 check** (in `run-bitjit.sh`): the p4 loops (`r3/review/widthfold/probes/p4/p4v.lua`, all 8 variants) must compile. Assert from `-jv` output (or `jit.attach` trace events) that no trace aborts with type instability and none is blacklisted. Do not use a timing bound. Fail-first: the fix1-less build.
- **`negctl-bitop.sh`**, arms against B. Each is one line at the fix's own site; the catcher is in brackets, and each catch must be shown by its intended suite.
  - From `design.md`, kept: WRAP32-INTERP [matrix, fuzz V]; WRAP32-FOLD [matrix K, fuzz K]; SHIFTMASK [matrix, fuzz]; NEGSHIFT [matrix]; SARSHR [t_sar]; NOINT-FOLD [matrix K]; NOINT-JIT [t_jit2 guard-exit]; RANGE-HI [matrix, fuzz]; STRCOERCE [matrix, coerce_agree]; ERROPERAND [matrix]; NARROW (= negA) [t_rec, t_jit2]; KFOLD64 (= negB) [fuzz U, t_rec]; SARCONST [t_rec counts, t_sar]; BCDUMP [FF12, the gate]; WORDTOKEN [stage 4].
  - From `design.md`, dropped: ROUNDTRUNC and TIESAWAY. Nothing rounds under B.
  - New for B:
    - INEXACT-INTERP: the `vm_x64.dasc` check removed [matrix, fuzz V];
    - INEXACT-SLOW: the C path stores the rounded double [matrix: a string-operand case such as `"-1" >> 1`, which only the C path computes];
    - INEXACT-FOLD: the parser folds an inexact result [matrix K, fuzz K];
    - INEXACT-JIT: no guard after the result [generator];
    - SELFGUARD [generator];
    - INEXACT-RECABORT: the record-time abort removed [`-jv` shows a trace recorded through an inexact result?]. **Only if a catcher exists;** otherwise drop it and say why.
  - From the review, the five width-rule sabotages, all [generator]:
    - WIDTH55: bound ≤ 55;
    - WSHR: BSHR 64-k;
    - WBAND: BAND ignores the constant's sign;
    - WADD0: ADD without +1;
    - WSHL0: BSHL count & 31. Per the reviewer, `simplify_shiftk_andk` rewrites `(x&m)<<k`, so the generator needs a non-BAND operand with count ≥ 32 for this one; check that it is caught, and if it is not, add the boundary template the reviewer suggests (`((a >> 42) << 32) | 1`).
  - FIX1: fix1 removed [the p4 check].
  - `canon` must pass.
  - Arms in `native/luajit/*.c|h` rebuild only their object, then `luajit.exe`. Arms in `vm_x64.dasc` rebuild through buildvm.
- **Harness d5** (`OcljSmoke.scala`): re-derive the expected probe line from PUC 5.3.6 with the B rule (`r3/synth/fuzz/d5-probe.lua`). Stock PUC 5.2 still wants `absent`.
- **The rest of `design.md` §6 stands:** `coerce_agree`, `security_test.c` (0x80 fixtures, FF12), `serializer/tests/bitop.lua`, the for-in fixture, and the fingerprint token. Re-derive any expected value that an inexact result would change.

## 6. File ownership (replaces `design.md` §8)

| owner | files |
|---|---|
| **A, LuaJIT plumbing** | NEW `native/luajit/oclj_bitop.h`, `oclj_bitop_meta.c`, `oclj_bitop_rec.c`, `oclj_bitop_fold.c`, `oclj_num53.h`, `patch-bitop-{parse,vm,meta,record,fold,bcdump}.sh`; `oclj_strpack.c` (D4 only), `oclj_features.h`, `patch-features-include.sh` (comment only), `native/build-native.sh` |
| **B, serializer and gradle** | `serializer/eris_lj.c`, `serializer/Makefile`, `serializer/README.md`, `serializer/tests/fingerprint.lua`, `serializer/tests/negctl-fingerprint.sh`, NEW `serializer/tests/bitop.lua`, `build.gradle.kts`. The for-in fixture is regenerated by the main session after the build. |
| **C1, matrix and native** | NEW `test/native/run-bitop.sh`, `test/native/bitop_test.c`, `test/native/bitop/` (matrix, fold, sar inputs and `.expect`s, `deviations.txt`, `coerce_agree.lua`, the reword script); `test/native/security_test.c` |
| **C2, JIT and fuzz** | NEW `test/native/run-bitjit.sh`, `test/native/run-bitfuzz.sh`, and in `test/native/bitop/`: `gen.lua`, `drv.lua`, `t_rec.lua`, `t_jit2.lua`, `bitfuzz.lua`, `bitfuzz-cmp.lua`, the p4 check |
| **C3, negctl (after A and C1/C2)** | NEW `test/native/negctl-bitop.sh` |
| **D, harness and docs** | `test/native/OcljSmoke.scala` (d5), `test/native/OcljArch.scala` (if it lists natives' features), `LuaJITStateFactory.java` (comment), `README.md`, `NOTICE`, `docs/roadmap.md` |

C1 and C2 share `test/native/bitop/` and must not write each other's files.

## 7. Docs (additions to `design.md` §10)

- **README "Lua dialect"**, B's version:
  - Results that do not raise equal Lua 5.3.6's.
  - A result with more than 53 significant bits raises, with the message.
  - The common case: `>>` of a negative number. The remedy: mask to the width you mean first, `(n & 0xFFFFFFFF) >> k`.
  - 5.3's `math.maxinteger` idiom `~0 >> 1` raises.
  - Literals (U9, with the 0x00ff... example); no integer subtype; `%.14g` printing; double arithmetic between operators; no bitwise metamethods (a later round, with `//`).
- **docs/roadmap.md, new rows:**
  - Round 3 `[x]`.
  - **CRC32 follow-up** (next): the rg2 range guard and the table-index fold, measured under B: 7.3 against today's 2.9 ns/byte.
  - **Metamethods + `//` + `__idiv`**, after the CRC32 follow-up: one change to the metamethod table and its layout gates. Why it can come later: round 3's C path raises the type error where 5.3 would look for the metamethod, and no working program depends on a metamethod being ignored.
  - u8/u16 operand width (9/17) in `oclj_bitwidth`, speed only.
  - F17 (the `PROTO_BITOP` collision), to be reported upstream.
  - RESID-scan for the operators: a numeric string with an exponent of 2^20 or more reads as not a number, the same residual as pack's. A strtod fallback in `oclj_num53.h` could fix both.
  - Instrument note: the Windows PUC 5.3.6 binary mis-rounds long hex-float strings.
  - Loop-invariant out-of-range shift counts abort the trace (speed only).
- **Rows 146, 147, 196, 206** as `design.md` §10 says, with B's wording.
- **Correct U9's wording everywhere:** any hex literal with more than 53 significant bits rounds silently, not only literals of 2^63 and above.

## 8. Process

- **Implementers** follow `design.md` §0's rules: edit only your own files; write LF; no git; never write under `build/` or into `serializer/` at run time; never run `negative-control.sh`, the harness or gradle. Build in your own scratch with `OCLJ_BUILD=<scratch>/build/native`. Never write a file containing backslashes through a shell heredoc; use your file-writing tool.
- **The reference builds for test authors:**
  - `r3/b/bB/src/luajit.exe` (B, the expected passes);
  - `r3/synth/b0/build/native/luajit-windows-x86_64/src/luajit.exe` (today, the fail-firsts);
  - PUC 5.3.6: `C:/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/lua.exe`.
- **Evidence** goes to a fresh `bench/runs/2026-10-17-bitop/`, written by the main session.
- **Never clear a results directory.**
