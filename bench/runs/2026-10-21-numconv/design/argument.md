# FIX-NUMCONV, step 1: the soundness argument

Roadmap row 211 item (5); JIT guide 3.11. Written 2026-10-21 by the step-1 "argue" agent, independently of the prototype being built beside it (`claude-tmp/oclj/numconv/proto/`, not read). Repo at HEAD `209aa95`, clean, not edited. Base build: `build/native` (read only), `luajit.exe` md5 `17f96322`, `lj_opt_fold.o` `1d018acc`, `lj_vm.o` `583d6da3`, `lj_asm.o` `ee6d0c98`. Every probe here ran on that `luajit.exe`, from its `src/`, value level only; nothing was timed. Marks: **[M]** measured (run named), **[S]** read in source (file and function; `~:N` is a pristine line at `1ee778a4`, "build copy :N" a line of `build/native/luajit-windows-x86_64/src`), **[I]** inferred.

## 0. Verdict

1. **The guard the rule removes can never fail on this build.** Its check is `cvttsd2si(cvtsi2sd(y)) == y` for a `y` that is itself `cvttsd2si r64` of some double; every such `y` is the double's integral part or INT64_MIN, each exactly a double in [-2^63, 2^63), so the round trip is the identity whatever MXCSR's rounding mode, DAZ or FTZ [S][M: section 3].
2. **The rule changes no value.** It replaces the guard's own conversion back, whose only consumer is that guard's `EQ.i64`, by a ref of equal value; the `EQ.i64 y, y` that results is dropped by `comm_equal` [S: section 4].
3. **It holds in every loop iteration and across PHIs**: it reads y's opcode, IR type and the CONV's literal mode only (S5), returns an existing ref of the folded instruction's type (requirement 2, S4), and when it crosses a PHI, y is already the copy's `res` and already PHI-marked, so it adds no PHI [S: section 4.6].
4. **It reads no guard and no mark** (S2): the fact is a property of the instruction `cvttsd2si`, true of every input.
5. **verify-rg2's one-line diff is sound on this build but not shippable as written**: merged into the width rule's line, it removes the text `<= 54)` that `patch-bitop-fold.sh`'s `verify_content` counts and that negctl's WIDTH55 arm anchors on [S: section 7].
6. **One trap for step 2**: the fact is *exactness*, not a *range*. It must never enter `oclj_bitwidth` (a converted double scored 54 would compose: `x | 1` with x = 2^53 would lose its guard and return 2^53 where 5.3.6 raises). That is the proposed sabotage NUMCONVW (section 8).

## 1. The guard and the rule

The guard, as `oclj_rec_bitop` emits it after every non-constant result [S: `native/luajit/oclj_bitop_rec.c` :150-155]:

```
d    = CONV num.i64 res   [exact]   op2 0x05d5
back = CONV i64.num d     [exact]   op2 0x16ae (ANY | EXACT)
       EQ.i64 back, res
```

The rule (verify-rg2's form, section 7): in `simplify_conv_i64_num`, inside the fix1 `if` and before `PHIBARRIER`, after the width rule, when `y = fleft->op1` is a CONV whose source is NUM, return `y`. With `fins` = `back` and `fleft` = `d`, that makes `back` := `res`.

An identity operation folds `res` to the operand's own conversion `i = CONV i64.num x` [S: `simplify_bor_k`, `simplify_band_k`, `simplify_bxor_k` ~:1566-1600, `simplify_shift_ik` ~:1611, `comm_dup` ~:2014, `reassoc_bxor` ~:1829, `reassoc_intarith_k64` ~:1792, `shortcut_leftleft` ~:990]. Today `oclj_bitwidth(i)` is 64 (`case IR_CONV` returns 64 for a non-INT source, `native/luajit/oclj_bitop_fold.c` :73-76), so the width rule keeps the guard [S]. Measured on the base build: one `EQ.i64` per identity form in the pre-roll and in the loop body (section 5) [M: `runs/ir-ident-1`].

## 2. Every CONV i64.num a trace can hold on this build

**Emitters** [S]:

| source | op2 | guard | where |
|---|---|---|---|
| an operand's conversion | 0x12ae (`IRCONV_ANY`) | no (`IRT`, not `IRTG`) | `oclj_rec_bitarg`, `oclj_bitop_rec.c` :64 |
| a result guard's own conversion back | 0x16ae (`ANY` and `OCLJ_IRCONV_EXACT`) | no | `oclj_rec_bitop`, :152-153 |
| `loop_unroll`'s copy of either | the same op2: a literal operand is not substituted (`if (!irref_isk(op2))`, lj_opt_loop.c :322) and `emitir(ir->ot & ~IRT_ISPHI, op1, op2)` keeps the type | no | lj_opt_loop.c ~:318-330 |

**Ruled out** [S]:
- `lj_opt_narrow_cindex`'s `CONV intp.num` (`IRT_INTP` is `IRT_I64` on x64, lj_ir.h ~:340): under `#if LJ_HASFFI` (lj_opt_narrow.c ~:499-503); this build has `LUAJIT_DISABLE_FFI` (`native/luajit/oclj_features.h` :61).
- All of `lj_crecord.c` (`#if LJ_HASJIT && LJ_HASFFI`, ~:11), and `lj_ffrecord.c`'s `CONV u64.int` (build copy :1105, under `LJ_HASFFI`).
- `narrow_conv_emit`'s raw re-emit of the folded instruction's own `ot`/op2 (`NARROW_CONV`, lj_opt_narrow.c ~:373): reached only through `narrow_convert` → `lj_opt_narrow_convert`, and hunk 8 returns NEXTFOLD for any 64-bit CONV (build copy :1371-1372).
- `lj_opt_fwd_xload`'s conversion on store forwarding (lj_opt_mem.c ~:869-883): needs an `XSTORE`, and no non-FFI code emits one (grep of the build copy: only `lj_snap.c` names it, in replay checks); without FFI every `XLOAD` is u8, u16 or int.
- `simplify_conv_narrow` (body compiled out under `LJ_64`, build copy :1316-1319); `lj_opt_split` (a no-op macro on x64: lj_iropt.h ~:158-162); `lj_snap.c`, `lj_record.c`, `lj_opt_loop.c`, `lj_ir.c` (only `NUM_INT` and `INT_NUM`).
- Fold rules that rewrite a CONV's mode produce `i64.int SEXT`, `i64.u32` (`simplify_conv_i64_num`'s reductions), `int`/`u32` from `int`/`u32` (`simplify_conv_int_i64`), `int.u32` (`simplify_tobit_conv`) and `int.i64` (the table-index fold), never a destination of I64 from NUM.

**Mode bits.** SRC `IRT_NUM` (14), DST `IRT_I64` (21), check mode `ANY` (0x1000), and on the guard's own conversion the exact mark (0x400). Never `SEXT`, `INDEX` or `CHECK`, never the guard bit, always typed `i64`. Measured across 14 loop shapes (identities, `x | 1`, `x ~ y`, `~x`, shifts by constants and by `i & 7`, a table key, a `string.byte` argument): the only modes with DST I64 and SRC NUM were 0x12ae (30) and 0x16ae (28), type 21, unguarded [M: `runs/modes-2/out.txt`].

**What the argument needs from this list, and what it does not.** The argument rests on the backend (section 3), not on the list: every unguarded CONV with SRC NUM and an `i64` type is `cvttsd2si r64`. The list is needed for two side facts. (a) No guarded CONV i64.num exists: one would go to `asm_tointg`, a 32-bit `cvttsd2si` (lj_asm_x86.h ~:830-842), and the `lj_assertA` that forbids it (~:903) compiles to `((void)as)` without `LUA_USE_ASSERT` (lj_asm.c ~:114-117; the build log has no `LUA_USE_ASSERT`) [S]. (b) No `CONV u64.num` exists (it has its own code, ~:910-924) [S].

## 3. The machine code, the constant fold, and why the guard cannot fail

**The backend** [S]: `asm_conv` (lj_asm_x86.h ~:857), branch "FP to integer conversion" (~:900). An unguarded conversion that is not to u64 emits `emit_mrm(as, XO_CVTTSD2SI, dest|REX_64, asm_fuseload(...))` (~:908, ~:929-931): `cvttsd2si r64, xmm` or `cvttsd2si r64, m64` (F2 REX.W 0F 2C, `XO_CVTTSD2SI = XO_f20f(2c)`, lj_target_x86.h ~:300). Operand fusion changes where the double comes from, not the instruction. Measured on the base build, `out[k] = v | 0` (pre-roll, 0011-0015) [M: `runs/kfold-copy-dump-1/dump.txt`]:

```
0011  i64 CONV 0010 i64.num none   cvttsd2si r10, xmm3             the operand's i (= res)
0012  num CONV 0011 num.i64        xorps xmm1, xmm1 / cvtsi2sd xmm1, r10   back of the operand guard, and d (CSE'd: same op1, same marked mode)
0013 >num EQ   0012 0010           ucomisd xmm1, xmm3 / jpe / jnz  the operand guard
0014  i64 CONV 0012 i64.num none   cvttsd2si r9, xmm1              the result guard's back  <- the rule folds this to 0011
0015 >i64 EQ   0014 0011           cmp r9, r10 / jnz               the result guard         <- then this drops
```

So per identity operation the rule removes one CONV and one guard: `cvttsd2si`, `cmp`, `jnz` and that guard's exit branch [M, the dump; what it saves in time is step 1's other half and is not measured here].

**No variant rounds by MXCSR.** The x64 backend has no rounding FP-to-int conversion at all: `lj_target_x86.h` defines `XO_CVTTSD2SI` and no `XO_CVTSD2SI` [S]. The truncating instructions ignore MXCSR.RC. The only RC-dependent instruction in the guard is `cvtsi2sd` (the `d`), and it rounds only an int64 that is not exactly a double. Neither LuaJIT nor our files write MXCSR (no `ldmxcsr`, `_mm_setcsr`, `fesetround` or `_controlfp` in the build copy's `.c`, `.h` and `.dasc`) [S].

**What `cvttsd2si r64` returns** (Intel SDM, CVTTSD2SI; the same on AMD) [I, from the manual; M on this CPU below]: the double truncated toward zero when that fits in int64, otherwise (NaN, ±inf, magnitude past range) the "integer indefinite" 0x8000000000000000 = INT64_MIN, with the invalid exception masked; MXCSR is 0x1F80 by default (all exceptions masked; the C runtime reported 0x1f80 at the probe's start, `runs/cvt-rt-1/out.txt`). An unmasked invalid exception would fault inside y's own conversion with or without the rule, so it is not a value question.

**The argument** [S][I]. Let y be any value a `CONV i64.num` computes on this build.
1. If x is a double whose truncation fits, y = trunc(x). trunc(x) is exactly a double: if |x| ≥ 2^52, x's ulp is at least 1, so x is an integer and trunc(x) = x; if |x| < 2^52, trunc(x) is an integer of magnitude below 2^52 < 2^53. The doubles whose truncation fits int64 are exactly those in [-2^63, 2^63) (the neighbours of ±2^63 are 2^63 - 1024 and -2^63 - 2048).
2. Otherwise y = INT64_MIN = -2^63, a power of two, exactly a double.
3. So y is an integer, exactly a double, in [-2^63, 2^63). Then `d = cvtsi2sd(y)` is y exactly (nothing to round, so RC does not matter), and `back = cvttsd2si(d)` is trunc(y) = y, in range, so not the indefinite value. `cmp back, y` is equal and `jnz` is never taken. ∎

DAZ only zeroes denormal inputs (whose truncation is 0 anyway) and FTZ only flushes denormal results (`cvtsi2sd` never makes one).

**Measured on this machine's CPU** (Intel Core Ultra 9 285HX) [M: `probes/cvt_rt.c` md5 `8981cd25`, built with gcc 16.2.0 -O2 to `runs/cvt-rt-1/cvt_rt.exe` md5 `f9a065de`, output `runs/cvt-rt-1/out.txt`, 2.5 s]. The probe executes the guard's exact instructions (inline `cvttsd2si`, `xorps`/`cvtsi2sdq`) on 21,179,656 doubles per MXCSR setting: 20 M random bit patterns, every sign and biased exponent with edge and random mantissas, 4096 ulps either side of ±2^63, ±2^53, ±2^52 and ±1, and 8192 denormals of each sign. In all eight settings (RN, RD, RU, RZ, each with DAZ+FTZ off and on): `back != y` 0 times, and `cvtsi2sd(y)` identical in all four rounding modes (y exactly a double) every time; about 9.9 M of each set gave INT64_MIN. Fail-first, same run: y = 2^53 + 1, INT64_MAX and -2^53 - 1 (not `cvttsd2si` outputs) fail the check, and 994,085 of 1,000,000 random int64 do. This probe goes beyond "run on `luajit.exe`": it is a standalone C program in this directory, pure computation, no pointers but local ones; it measures the CPU fact, not the build.

**Inside the build, as compiled** [M]. The identity loops ran 200,000 iterations each over 128 boundary values (0, -0, ±1, 2^52, 2^52 + 1, ±2^53, ±(2^53 + 2), 2^63 - 1024, -2^63, -2^63 + 1024, ±2^60, ±3·2^61, and 108 random m·2^e) with exactly one trace exit each, the loop's end; the control `x | 1`, compiled on small values and then run on the same values, took 28 exits [M: `runs/exits-ident-2/out.txt`, `probes/exits_ident.lua` md5 `6cafba68`; run 1's control compiled nothing, so the control was reworked: a check is trusted only after it is seen to fail].

**The constant fold of a `CONV i64.num` of a constant** [S][M]. `kfold_conv_knum_i64_num` (~:902; build copy :909-913): `return INT64FOLD((uint64_t)lj_num2i64(knumleft));`. On x64 `LJ_TARGET_X86` is 0 (it is the 32-bit target, lj_arch.h ~:193 against ~:207), so `lj_num2i64(x)` is `lj_vm_num2i64(x)` (lj_obj.h ~:1057), declared `LJ_ASMF LJ_CONSTF` (~:1037): the DynASM routine `->vm_num2i64: cvttsd2si rax, xmm0; ret` (vm_x64.dasc ~:2684, build copy :2689). The header comment says why it moved to assembler: "Out-of-range values, NaN and +-Inf return an arch-dependent result, but do not cause C undefined behavior" (~:1032-1036).
- **No undefined behaviour.** There is no C conversion from double to integer in the fold, so C11 6.3.1.4p1 (undefined for a value outside the integer type, and for NaN) does not arise; the `(uint64_t)` cast of an `int64_t` is defined modulo 2^64 [S]. A plain C cast `(int64_t)x` would have been undefined for x ≥ 2^63, NaN or inf.
- **What this build's compiler gives** [M: objdump]: `lj_opt_fold.o` (md5 `1d018acc`) compiles `fold_kfold_conv_knum_i64_num` to `movsd 0xc8(%rcx),%xmm0; call lj_vm_num2i64; mov %rax,%rdx; jmp lj_ir_kint64`, and `lj_vm.o` (md5 `583d6da3`) has `lj_vm_num2i64: f2 48 0f 2c c0 cvttsd2si %xmm0,%rax; c3 ret`. So the constant fold and the trace compute the same instruction on the same bits [M]. The build compiled `lj_opt_fold.c` with `gcc -O2 -fomit-frame-pointer -Wall -fPIC ... -fno-stack-protector` and no `-ffast-math` (`build/native/luajit_build.log` :180) [M]; that it was gcc 16.2.0, the compiler on the PATH today, is [I].
- **Reached** [M: `runs/kfold-copy-1`, `runs/kfold-copy-dump-1`]: in `out[k] = v | 0; v = C` with C a literal, the loop copy's `fwd_sload` hands back the KNUM C, the copy's `CONV i64.num` folds to a KINT64, the guards fold to constants, and the loop body stores the KNUM directly (no `CONV i64.num` and no `EQ.i64` in the body, `ASTORE ... +4.6116860184274e+18` for C = 2^62); values equal to `-joff` for C = 2^60, -2^63, 2^63 - 1024, 3, -(2^53 + 2), 2^62. An out-of-range C cannot reach it: the recorder checks the operand's value at record time and aborts (`oclj_rec_bitarg`, `oclj_flt2int`), and the interpreter raises first [S][I]. Were it reached, the fold would give INT64_MIN and the operand guard `EQ.num KNUM KNUM` would fold to FAILFOLD, a trace abort, not a wrong value [S: `kfold_numcomp`, keyed `EQ KNUM KNUM`, lj_opt_fold.c build copy :246-260][I].

## 4. When the rule fires, the guard is gone and nothing else notices

**4.1 The EQ folds away** [S]. In the recorder, `d` is `emitir(CONV num.i64, res)`; whatever it returns is either a constant (then `tref_isk(res)` and no guard is emitted, `oclj_bitop_rec.c` :151) or a CONV whose op1 is `res`: no rule but the KINT64 constant fold is keyed on `CONV <x> IRCONV_NUM_I64` (the `LJFOLD(CONV ...)` list of the build copy), and `cse_conv` returns a hit only with the same op1 (~:1287-1302). So `fleft->op1` is `res`, the rule makes `back` = `res`, and `emitir(EQ.i64, res, res)` reaches `comm_equal` (~:1978): `fins->op1 == fins->op2 && !irt_isnum(fins->t)` gives `CONDFOLD(fins->o == IR_EQ)`, a DROPFOLD. Nothing is emitted for `back` or the EQ. The same holds in the loop copy: the copy of `d` is `CONV num.i64 subst[res]`, so a CONV `fleft` there has `op1 == subst[res]`, and the copied EQ is `EQ.i64 y, y`.

**4.2 Nothing consumes `back` but its EQ** [S]. `oclj_rec_bitop` passes `back` only to the EQ. An operand conversion of `d` is unmarked (0x12ae), so `cse_conv`, which compares `op2 & IRCONV_MODEMASK` (0x400 included), never commons it with the marked `back`, and the exact-mark rule folds it to `res` before CSE anyway. Another marked `CONV i64.num d` exists only as a copy of the same guard, which folds the same way.

**4.3 Snapshots and exits** [S]. The guard has no snapshot of its own: a bit operator takes none, and its guards exit through the newest one (JIT guide 4.3). Snapshots name slots, which hold `d`, never `back` or an EQ. A dropped guard does not set `J->guardemit` (it is set only when an instruction is emitted: `lj_ir_emit`, lj_ir.c ~:127; `lj_opt_cse`'s emit, lj_opt_fold.c build copy :2680), so the next snapshot may merge into the previous one (`lj_snap_add`, lj_snap.c ~:185-188; `loop_subst_snap`, lj_opt_loop.c ~:217-224; `loop_unroll`'s "Drop redundant snapshot", ~:375). Each such merge replaces a snapshot that no remaining guard uses, so every remaining guard keeps its snapshot and its resume pc: this is upstream's own mechanism, the same one the width rule's DROPFOLD and `comm_equal` already trigger today [I, from the code].

**4.4 Side traces** [S][I]. A side trace hangs on a parent exit that was taken `hotexit` times; the removed guard's exit could never be taken, so no side trace hangs on it. A side trace's own values enter as `num SLOAD PI` (bit results cross as their double `d`, guide 4.8) and are converted again by `CONV i64.num`, which section 3 covers.

**4.5 DCE and the backend.** A guard is a DCE root (`ir_sideeff`); with it gone, nothing new becomes live, and `back` was never emitted [S].

**4.6 The loop copy and PHIs** [S][I].
- **Where it sits.** Inside the fix1 `if` (`(fleft->op2 & IRCONV_SRCMASK) == IRT_I64 && irt_isi64(fins->t) && (irt_isi64(IR(fleft->op1)->t) || !irt_isphi(fleft->t))`, build copy :1177-1178) and before `PHIBARRIER`, like the width rule. y, a `CONV i64.num`, is `i64`-typed, so the rule fires across a PHI.
- **Requirement 2 and S4.** It returns an existing ref (`fleft->op1`), never builds an instruction, and that ref's type, I64, is the folded instruction's (lj_opt_fold.c's requirement 2 allows returning an existing ref; `loop_unroll`'s type check, ~:342-352, sees equal types and does nothing).
- **S5: what it reads.** `IR(y)->o`, `IR(y)->op2 & IRCONV_SRCMASK` (a literal mode word, which the copy never substitutes), and with the recommended form `IR(y)->t`: an opcode, a constant and a type. No value, no guard, no mark.
- **Why the fact read from a pre-roll y holds in every iteration.** In the loop body a PHI-marked pre-roll ref y denotes, in iteration k ≥ 2, the value of `subst[y]` from iteration k - 1. `subst[y]` is the copy of `CONV i64.num x` on the substituted operand, and every fold or CSE it can go through (`cse_conv`, the exact-mark rule, the width rule, this rule, `simplify_conv_i64_num`'s int reductions, `kfold_conv_knum_i64_num`) returns a value-equal ref, given the guards emitted before it (S1). So in every iteration y's value is `cvttsd2si` of some double, and section 3 applies. This is S5's induction, with "an exact value" in place of "a bounded range".
- **It adds no PHI.** When `fleft` is PHI-marked it is a pre-roll `CONV num.i64 F` that the copy of `d` CSE'd to (PHI marks go only on pre-roll refs, ~:334-339, ~:361-366), so `F->op1 == subst[res]`: `res`'s copy returned y, which `loop_unroll` already PHI-marked then. The rule's return of y is that same ref. And if `fleft` is an unmarked pre-roll ref, `d` was invariant, so `back`'s copy took the invariant shortcut (~:324-326) and no fold ran.
- **TYPEINS cannot arise from it**: y is I64, and a copy of y that folds to an int-typed ref already raises TYPEINS without the rule (I64 against INT, ~:352).

**4.7 Option sets.** Under `-O-fold` no rule runs (N-mode instructions go straight to CSE, guide 3.6), so the guards stay. Under `-O-cse`, rules still run and `comm_equal` still drops `EQ.i64 y, y`. Under `-O-loop` there is no copy. The rule speculates nothing and adds no guard [S].

## 5. The shapes that reach it, and whether any could change a value

Base-build reading, `EQ.i64` guards (result guards) in a hot loop over a table of doubles, pre-roll | body [M: `runs/ir-ident-1/out.txt`, `probes/ir_ident.lua` md5 `e01eb3af`]. "Expected with the rule" is what section 4 predicts [I]: step 2 can read it the same way.

| form | base | why `res` is a CONV i64.num | expected with the rule |
|---|---|---|---|
| `x \| 0`, `0 \| x` | 1 \| 1 | `simplify_bor_k` k = 0 (constants move right: `comm_dup` → `fold_comm_swap`) | 0 \| 0 |
| `x & -1`, `-1 & x` | 1 \| 1 | `simplify_band_k` k = -1 | 0 \| 0 |
| `x ~ 0` | 1 \| 1 | `simplify_bxor_k` k = 0 | 0 \| 0 |
| `x << 0`, `x >> 0`, `x ~>> 0` | 1 \| 1 | the recorder emits `BSHL`/`BSAR` by KINT 0 (`oclj_bitop_rec.c` :116-134), `simplify_shift_ik` k = 0 | 0 \| 0 |
| `x & x`, `x \| x` | 1 \| 1 | `comm_dup` | 0 \| 0 |
| `(x \| 0) & -1` | 1 \| 1 | the second operator's operand is `d`, the exact-mark rule gives `i`, and its d, back and EQ CSE to the first's | 0 \| 0 |
| `~~x` | 2 \| 2 | `shortcut_leftleft` on `BNOT BNOT` (not across a PHI) | 1 \| 1: `~x` keeps its guard |
| `(x ~ y) ~ y` | 2 \| 2 | `reassoc_bxor` | 1 \| 1: `x ~ y` keeps its guard |
| `(x ~ 5) ~ 5` | 2 \| 2 | `reassoc_intarith_k64` gives `x ~ 0`, then `simplify_bxor_k` | 1 \| 1 |
| `~(x ~ -1)` | 2 \| 2 | `simplify_bxor_k` k = -1 makes `BNOT`, then `BNOT BNOT` | 1 \| 1 |
| controls `x \| 1`, `x ~ y`, `x << 1` | 1 \| 1 | not a conversion | 1 \| 1, unchanged |
| control `x & 0xff` | 0 \| 0 | the width rule (bound 9) | 0 \| 0 |

Other shapes that can reach the rule: any composition of the above; a stored result read back (forwarding returns `d`, the exact-mark rule gives `res`); in the loop copy, any of these on substituted operands, and a body `res` that becomes a conversion only in the copy. In gen's rg2 mode the atom `(2^53 - 2 + i) | 0` (`test/native/bitop/gen.lua` :111-112) is an identity on a double at the 2^53 boundary, so genrg2 already runs the rule's shape [S].

**Could any change a value? No.** The rule changes no value of its own (section 4.1-4.2), and the folds that make these shapes run with or without it [S]. Measured on the base build, against `-joff` [M: `runs/vals-ident-2/` (jit and joff outputs both md5 `de2a7808`), `probes/vals_ident.lua` md5 `35b9b3ad`]: 12 forms on 128 exact boundary values (loop A, 5,120 calls a form) and the same mixed with 1.5, 2^63, -2^63 - 2048, NaN, ±inf, 2^63 + 2048 and -0.5 (loop B), every call through `pcall`: identical text, 348 "number has no integer representation" and 522 "more than 53 significant bits" messages included. Two facts from that run step 2 must keep:
- **The inner operator of a cancellation is no identity under U1-B.** `~x` for an exact x ≥ 2^53 with bit 0 clear is -x - 1, inexact, so `~~x` raises in its inner `~`, as 5.3.6 does; likewise `x ~ 5` in `(x ~ 5) ~ 5`, and `x ~ y` in `(x ~ y) ~ y`. The rule keeps those inner guards, because their `res` is a `BNOT`/`BXOR`, not a conversion [S][M: run 1 of this probe stopped at exactly that raise, `runs/vals-ident-1/jit.err`].
- **`-0.0 | 0` is 0**: `cvttsd2si` gives 0 and `d` is +0.0, as the interpreter's result [M: loop A, value 2].

The rule also does not mask NARROW: it keys on the opcode CONV, so if narrowing ever rewrote `CONV i64.num (ADD ...)` into int64 arithmetic (the NARROW arm), y would be an `ADD`, the rule would not fire, and the arm stays visible as before [S][I].

## 6. What holds only on x64

- **The indefinite value.** x64's `cvttsd2si` returns INT64_MIN for everything it cannot convert, and INT64_MIN is a double. arm64's `FCVTZS` (`asm_conv` uses `A64I_FCVT_S64_F64` = 0x9e780000, lj_asm_arm64.h ~:653-657; the constant fold `vm_num2i64: fcvtzs`, vm_arm64.dasc ~:2196-2198) saturates: NaN gives 0, and +inf or x ≥ 2^63 gives INT64_MAX = 2^63 - 1, which is not a double [S]. The premise of section 3 fails there. The guard would still pass on arm64, by saturation and not by exactness (`SCVTF(INT64_MAX)` rounds to 2^63, and `FCVTZS(2^63)` saturates back to INT64_MAX) [I], so a port must re-argue the rule rather than reuse this text.
- **Round 3's operand guard has an arm64 hole too, found on the way and not this rule's** [I]: for x = 2^63 exactly, `FCVTZS` gives INT64_MAX, `SCVTF` of that is 2^63 = x, and the `EQ.num` passes, where 5.3.6 raises "number has no integer representation". It is moot while aarch64 is parked (roadmap: the platforms row moved to Parked on 2026-10-10; guide 1.1: build-native.sh refuses any machine but x64), and worth a line in the Parked row.
- **No rounding conversion.** x64 has only truncating FP-to-int conversions in the backend (section 3). The 32-bit x86 path (SPLIT, `asm_conv_int64_fp`, x87 `FISTTP`, or `FISTP` with the control word set to truncate) also yields the indefinite 0x8000000000000000, but it is not built [S].
- **`REX_64`** comes from `irt_is64(ir->t)` under `LJ_64` (lj_asm_x86.h ~:930) [S].
- **The fix1 condition** exists because of x64's `simplify_conv_sext` LEFTFOLD, but a conversion y is always I64-typed, so fix1 never refuses this rule [S].

## 7. verify-rg2's one-line diff (`crc/verify-rg2/sab/FIX-NUMCONV/sabotage.diff`)

```
1171c1171
<     if (oclj_bitwidth(J, fleft->op1, 0) <= 54)
---
>     if (oclj_bitwidth(J, fleft->op1, 0) <= 54 || (IR(fleft->op1)->o == IR_CONV && (IR(fleft->op1)->op2 & IRCONV_SRCMASK) == IRT_NUM))  /* VERIFY-RG2 FIX-NUMCONV: a converted double is exact */
```

- **What it was written against.** Line 1171 of the rg2 prototype's build copy (`lj_opt_fold.c.canon`, md5 `c97daf47`), where rg2's range guard followed the width rule. In the shipped build copy the same text is line 1189. As a content replacement, its old line occurs exactly once in both [M: grep].
- **Is it sound? Yes, on this build** [S][I]. Its predicate fires when y is a CONV from NUM. Reachable such y have type I64 (the target) or INT; an INT y scores 33 and the width rule, which the `||` evaluates first, takes it. Parentheses balance, and `IR(fleft->op1)` is in bounds for any ref, constant or instruction.
- **Is it right as written? Not for shipping**, for three reasons:
  1. **It breaks `patch-bitop-fold.sh`.** `verify_content` requires `countsub 'oclj_bitwidth(J, fleft->op1, 0) <= 54)'` to be 1 (:434) and finds `LC2` by the same text (:439); the merged line no longer contains `<= 54)`, so the patched file would fail "the width rule's call (54) does not occur exactly once" [S].
  2. **It breaks negctl's WIDTH55 arm**, whose OLD text is that exact line (`test/native/negctl-bitop.sh` :733-735); `sabotage()` then exits 1 (it needs exactly one match), which negctl reports as a setup failure [S].
  3. **It merges two proofs into one condition**, so no one-line arm can break the new one alone.

  So: give it a line of its own, after the width rule, with its own comment. A suggested comment: why the fact holds, the two outcomes of `cvttsd2si`, the x64 dependency, and "not a range: never in `oclj_bitwidth`".
- **The type test.** Its predicate does not test y's type. Adding `irt_isi64(IR(y)->t)` (with the SRC test) states the fact precisely and guards a future FFI build, where `CONV u64.num` and `CONV intp.num` exist. On this build both the type test and the SRC test are unreachable in effect: every CONV y they could exclude is INT, and the width rule takes it first. A sabotage that drops either is invisible to every test, so it is no arm (negctl's header treats INEXACT-RECABORT the same way) [I].
- **Its comment** ("a converted double is exact") is the right fact; the shipped one should also say why.

## 8. Proposed sabotage arms and catchers for step 2 (proposal only)

The fix site's arm must make the rule unsound in a way that changes a value, stay one line, be memory-safe, and anchor on unique text. I propose writing the predicate as a small helper (in `oclj_bitop_fold.c`, called from `bitop_wgate.c` per checklist 15), so the arm is deterministic:

```c
/* y is a double's own conversion (CONV i64.num): exactly a double, x64 */
static int oclj_isnumconv(jit_State *J, IRRef ref)
{
  IRIns *ir = IR(ref);
  return ir->o == IR_CONV && irt_isi64(ir->t) && (ir->op2 & IRCONV_SRCMASK) == IRT_NUM;
}
...
    if (oclj_isnumconv(J, fleft->op1))   /* in simplify_conv_i64_num, after the width rule */
      return fleft->op1;
```

**Arm 1, NUMCONVOP1 (the fix site; value-visible).** A bit operator *on* a converted double counted as one:

```
arm NUMCONVOP1 lj_opt_fold.c '<catchers>' \
  '    if (oclj_isnumconv(J, fleft->op1))' \
  '    if (oclj_isnumconv(J, fleft->op1) || (IR(fleft->op1)->o >= IR_BNOT && IR(fleft->op1)->o <= IR_BSAR && oclj_isnumconv(J, IR(fleft->op1)->op1)))  /* SABOTAGE NUMCONVOP1: a bit operator on a converted double counts as one */'
```

It is memory-safe: `BNOT` to `BSAR` all have a ref as op1 (lj_ir.h ~:57-64: `BNOT ref ___`, `BAND ref ref`, ..., `BSHL ref ref`), and `IR()` of any ref, constant or instruction, is in the IR array [S]. It drops the guard of `x | 1`, `x ~ 1`, `~x`, `x ~ y` and the inner guard of `~~x` and `(x ~ 5) ~ 5` whenever an operand is a converted double. Shifts change nothing visible, since a shift of an exact value stays exact (the out-of-scope claim).

**The catching case**, `probes/catch_numconv.lua` (md5 `be3321c6`). It records each form on small values (300 iterations of `x = 2i`), then the same compiled loop, with no branch in between, meets 2^53, 2^60, -2^60, 2^53 + 2 and 3·2^61 (100 iterations), every result stored unconditionally and read after the loop, over three calls.
- Correct build: `or1`, `xor1`, `bnot`, `xory`, `or1or0`, `notnot` and `xor5x5` raise 300 times each ("result of '|'/'~' has more than 53 significant bits"), and `or0` returns the five values. Measured on the base build in 8 option sets (default, `-joff`, `-Ohotloop=1`, `-Omaxside=0`, `-Ohotloop=1 -Ohotexit=1`, `-O-loop`, `-O-fold`, `-O-cse`): all identical to `-joff` [M: `runs/catch-numconv-4/`, every `.out` md5 `ca246f82`]. The compiled loop does meet the big part: in each raising form's first call the result guard exits 15 times (11 under `-Omaxside=0`) before its exit is linked, against `or0`'s single loop-end exit [M: `runs/catch-numconv-4/jit.err`, `ms0.err`].
- Under the arm: no raise, and the rounded doubles instead (2^53 | 1 gives 9007199254740992) [I: not built here].
- The probe's history: run 1 collected results behind `if rep == 3 and i > 300`, which sent the big part out of the root trace and could not have caught anything; runs 2 and 3 had array growth and a shared loop prototype confounding the exit counts. Their value outputs equal run 4's, and run 4 is the one to trust.

Under `-O-fold` no rule runs, so the arm is invisible there by design; in every other set the rows sit in the root trace. gen and genrg2 probably catch the arm too, since gen draws big constants and slots, and genrg2 draws `(hi << 52) | 1`-style atoms [I: margins to be measured in step 2, as negctl's header records them].

**Arm 2, NUMCONVW (the design trap; independent of the rule's text).** In `oclj_bitwidth`, a converted double scored 54, i.e. exactness put into the range bound. Its anchor is unique in `oclj_bitop_fold.c` [M: `grep -c -x` gives 1]:

```
arm NUMCONVW oclj_bitop_fold.c '<catchers>' \
  '    if ((ir->op2 & IRCONV_SRCMASK) == IRT_INT)' \
  '    if ((ir->op2 & IRCONV_SRCMASK) == IRT_NUM) return 54; else if ((ir->op2 & IRCONV_SRCMASK) == IRT_INT)  /* SABOTAGE NUMCONVW: a converted double scored as 54 bits wide */'
```

It is memory-safe: it reads only op2. It composes: `x | 1` gets max(54, 2) = 54, so the width rule drops its guard; `x ~ y`, `~x` and `x ~>> k` (54 - k) likewise, and `x ~>> 22` (32) would also enter the table-index fold. Caught by the same rows (2^53 | 1 returns 2^53 instead of raising) [I]. It holds JIT guide 3.11's warning in place, "A bound is a range, and exactness is a second fact the table does not have", for whoever later tries to "simplify" the rule into the bound.

**Arm 3, NUMCONVOFF (coverage; changes no value).** The rule switched off (`if (0 && oclj_isnumconv(...))`). It is a speed-only change, so only an IR read sees it (P56, checklist 19). Proposed catcher: `ir_ident.lua`'s count as a check. Key it on the rule's own signature, an `EQ.i64` guard whose right operand is a `CONV i64.num` with an unmarked op2 (0x12ae) (the width rule can never remove such a guard, since that y scores 64). Require 0 for the 11 identity forms and 1 for the four cancellations. Fail-first is already in hand: the base build reads 1 (identities) and 2 (cancellations) in pre-roll and body [M: `runs/ir-ident-1/out.txt`], which such a check must fail.

## 9. Evidence index

All under `C:/Users/astro/claude-tmp/oclj/numconv/argue/`. Fresh run directories, none reused.

| probe (md5) | runs | what |
|---|---|---|
| `probes/ir_ident.lua` (`e01eb3af`) | `runs/ir-ident-1` | `EQ.i64` and CONV counts per form, base |
| `probes/vals_ident.lua` (`35b9b3ad`) | `runs/vals-ident-2` (run 1: an earlier text without `pcall` in loop A, stopped at `~~x`'s legitimate raise) | values, JIT against `-joff` |
| `probes/exits_ident.lua` (`6cafba68`) | `runs/exits-ident-2` (run 1: vacuous control) | trace exits of identity loops on boundary values |
| `probes/kfold_copy.lua` (`934bac91`), `probes/kfold_one.lua` (`8714894c`) | `runs/kfold-copy-1`, `runs/kfold-copy-dump-1` | the constant fold in the copy; the guard's machine code |
| `probes/modes.lua` (`1d584111`) | `runs/modes-2` (run 1: a raising value set) | every CONV mode in 14 shapes |
| `probes/cvt_rt.c` (`8981cd25`) | `runs/cvt-rt-1` (exe `f9a065de`) | CPU round trip, 8 MXCSR settings, fail-first |
| `probes/catch_numconv.lua` (`be3321c6`) | `runs/catch-numconv-4` (1-3: earlier texts, see section 8) | the proposed catching case, 8 option sets |

Read-only objdumps: `build/.../lj_opt_fold.o` (`1d018acc`), `fold_kfold_conv_knum_i64_num` and `..._u64_num`; `build/.../lj_vm.o` (`583d6da3`), `lj_vm_num2i64`.

## 10. Doubts and limits

- **The CPU fact is checked on one CPU.** The x64 contract is the manual's [I], and the eight-mode probe ran on one Intel CPU [M]; AMD documents the same indefinite value [I].
- **The value-preservation induction in 4.6 assumes upstream's copy-substitution and every fold rule are value-preserving** past the guards before them; this is the same assumption S5 makes for the width rule, not proved here [I].
- **"Snapshots hold only `d` or ints" is S6's [I]**; the rule does not lean on it, because an i64 snapshot value would enter a side trace as an `SLOAD`, not as a CONV.
- **Nothing here was built with the rule.** The "expected with the rule" column and both arms' catches are predictions for step 2 [I].
