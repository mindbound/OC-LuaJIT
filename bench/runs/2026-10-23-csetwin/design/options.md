# CSE type twin: fix options

csetwin/options, 2026-10-23. Read-only work: nothing was run except grep, awk and md5sum over source files. Marks: [M] measured (the run or command is named), [S] read in source (file:line), [I] inferred. "Build copy" means `build/native/luajit-windows-x86_64/src/` (its `lj_opt_fold.c` md5 `3b11930f`, the FIX-NUMCONV patch output). "Pristine" means `prototype/watchdog/luajit/src/` at `1ee778a4`. Inputs read: `native/luajit/oclj_bitop_rec.c` (md5 `ef711189`), `native/luajit/patch-bitop-fold.sh` (md5 `08c242a5`), `oclj_bitop_fold.c`, the build copy's `lj_opt_fold.c`, `lj_ffrecord.c`, `lj_record.c` and `lj_snap.c`, the pristine `lj_opt_loop.c`, `lj_opt_narrow.c`, `lj_opt_mem.c` and `lj_asm_x86.h`, `docs/jit-guide.md`, `test/native/negctl-bitop.sh`, and the reproducer `claude-tmp/oclj/shiftexact/cse/cse-fwd2.lua` (md5 `39539055`) with its `run-3/`.

## 0. Verdict

**Recommend option B, in its I64 form: one line in `lj_opt_cse` that refuses a match when exactly one of the two instructions is `IRT_I64`.**

- **It fixes every order and every pair, whatever the producer.** That covers record time, the loop copy, side traces and instructions that fold rules emit inside other folds. It also covers the reverse order, which can crash. This holds because it is a property of the one matcher that can pair our int64 instructions with 32-bit ones (section 2), not of any list of producers.
- **It changes no IR outside collision sites** [I, section 4B].
- **It is one hunk (12) in `patch-bitop-fold.sh`.** The anchor text is identical at the pin and at upstream's tip [M].
- **It gets a memory-safe negctl arm (CSEFWD).** The arm allows only the forward merge, so the reverse order stays refused while the arm is in place.

A (an abort in the recorder) leaves the reverse order and the nested and loop-copy forward cases open. C (a distinguishing operand) cannot cover BAND/BOR/BXOR with two variable operands, variable shift counts or ADD, and it breaks folds we rely on. D1 (stop handing int refs to int64 ops) is the only other complete fix. It costs an instruction per int operand in every such trace, plus wide churn in IR, tests and docs. Keep it as the fallback.

## 1. The defect, restated

- **`lj_opt_cse` matches on `op12` only and returns the existing instruction with its own type.** It walks `J->chain[op]`, tests `IR(ref)->op12 == op12` and returns `TREF(ref, irt_t(IR(ref)->t))` [S build copy lj_opt_fold.c:2673-2676; pristine :2611-2614]. The guide records this as "It does not compare the type" [S docs/jit-guide.md:505].
- **On x64, our int64 instructions take some int refs directly.** `simplify_conv_sext` LEFTFOLDs our `CONV i64.int SEXT` for three kinds of ref [S build copy lj_opt_fold.c:1278-1305; LEFTFOLD :1299]:
  - a u8/u16 `XLOAD`;
  - the SCEV loop index;
  - `ADD idx, k` with start + k >= 0.

  `oclj_rec_bitarg` emits that conversion for every int-typed operand [S oclj_bitop_rec.c:53-54].
- **So an int64 op and a 32-bit op on the same int ref can have equal `op12`.**
  - At record time the index is the `SLOAD`; in the loop body it is the FORL's `int ADD 0001 +1`. run-3's dump shows `0049 int BSHL 0043 +3` with `0043 + int ADD 0001 +1` [M run-3/jdump.txt, TRACE 1].
- **Forward order: a 32-bit instruction exists first, and ours CSEs to it.** The 5.3 operator gets the 32-bit value, zero-extended. In run-3:
  - `bit.lshift(i,3)` then `i << 3` gave 341 of 401 wrong values;
  - `bit.bnot(i)` then `~i` gave 341 of 401 wrong values;
  - the controls had 0 wrong values, and so did `-joff` [M run-3/jit.txt, joff.txt].
  - The result guard folds away too. The width rule scores an `IRT_INT` ref 33 [S oclj_bitop_fold.c:76] and returns it [S build copy lj_opt_fold.c:1189-1190], so nothing exits.
- **Reverse order: ours exists first, and a 32-bit producer CSEs to it.** Upstream code then holds an I64-typed TRef.
  - The bit library stores it in a slot: `J->base[0] = emitir(IRTI(op), tr, tsh)` [S build copy lj_ffrecord.c:819; unary :779].
  - On an exit, `snap_restoreval` has no I64 case under GC64. An I64 ref in a register falls through to `setgcV(J->L, o, (GCobj *)ex->gpr[...], irt_toitype(t))` [S build copy lj_snap.c:757-760], making a GC value from an integer.
  - That is crash-class. Nothing here proposes running it on any build without the fix.

## 2. Where two instructions can be matched

Every place in the tree that pairs an instruction being emitted with an existing one [S, grep of `lj_opt_cse(`, `lj_opt_cselim`, `op12 ==` and `chain[` over the build copy]:

| matcher | where | can it pair one of our I64 instructions with a non-I64 one? |
|---|---|---|
| `lj_opt_cse` | build copy lj_opt_fold.c:2663-2688 | **Yes: the defect.** It is reached by fold exhaustion (:2643), the `-O-fold` path for N-mode instructions (:2597), `CSEFOLD` (lj_iropt.h:120), `LJFOLDX(lj_opt_cse)` keys (:949, :2446), `fload_tab_ah` (:2341), `fwd_sload` (:2457), `barrier_tab` (:2496) and `cse_carg` (:2563). It is also reached by the nested `lj_opt_fold(J)` in `simplify_shiftk_andk` (:1758, :1767), and by `loop_unroll`'s re-emission of every copied instruction (pristine lj_opt_loop.c ~:328-331) |
| `lj_opt_cselim` | :2693-2703 | No. Its only callers are `fold_base` (SUB or EQ with a `BASE` operand, :2482-2485) and `lj_opt_fwd_fload` (lj_opt_mem.c:640). We emit no SUB, EQ-with-BASE or FLOAD [S] |
| `cse_conv` | :1344-1361 | No. A CONV's identity includes `op2 & IRCONV_MODEMASK`, which holds both types (:1347, :1353), and it never falls through to `lj_opt_cse` (`EMITFOLD`, :1359) |
| `cse_uref`, `cse_urefo` | :2231-2266 | No: UREFO and UREFC only |
| load/store forwarding | lj_opt_mem.c | No. Our ops are N-mode. Forwarding a mistyped store emits a CONV (pristine lj_opt_mem.c ~:868-880) |
| narrowing's backprop cache | lj_opt_narrow.c `narrow_bpc_get` | No. It caches int conversions only, and hunk 8 keeps 64-bit CONVs out of narrowing [S guide 3.13] |
| `loop_unroll`'s invariant shortcut | pristine lj_opt_loop.c:325 | No: it maps an instruction to itself |
| `loop_unroll`'s loop-carried type check | :334-352 | Not a matcher. It raises TYPEINS for I64 against int on a pre-roll ref and checks nothing for a loop-body ref [S] |

Fold rules that return an existing ref by structure (LEFTFOLD, `comm_dup`, `reassoc_dup`, `reassoc_bxor`, `shortcut_leftleft`) return an operand or an operand's operand [S :998-1002, :1874-1899, :2076-2081]. On our ops these are LEFTFOLD sources or our own results. That is value-correct, and it is not CSE [I].

## 3. Which shapes can collide (cross-check for the census agent)

Our side [S oclj_bitop_rec.c]:

- Constant operands of BAND/BOR/BXOR are KINT64 (:57-58). Every 32-bit op uses KINT, so those never match.
- Shift counts are KINT (:118, :120, :122, :133), the same as 32-bit shifts.
- A variable count is an int ref (:138-141).

| our instruction | its `op12` | equals a 32-bit instruction's when | 32-bit producers seen [S unless marked] |
|---|---|---|---|
| `BNOT a`, direct (:107), or from `x ~ -1` via `simplify_bxor_k` (build copy :1660-1663) | (a, 0) | a is an int-family LEFTFOLD ref | `bit.bnot` (lj_ffrecord.c:779); `bit.bxor(x, -1)` through the same rule |
| `BAND`/`BOR`/`BXOR a, b` | (a, b), both non-constant | both are int-family | `bit.band`/`bor`/`bxor` (`recff_bit_nary`, lj_ffrecord.c:783-797). Values are equal for non-negative int32 operands, so only an IR read sees it [I] |
| `BSHL`/`BSHR`/`BSAR a, KINT k` | (a, k) | a is int-family | `bit.lshift`/`rshift`/`arshift` (:819), including counts of 32 or more, which `simplify_shift_ik` masks to `k & 31` (build copy :1684-1687) [I]. `rec_varg`'s `BSHL tridx, +3` (build copy lj_record.c:2081) is in game, value-benign under the 2^27 guard at :2080 [I]. An int `MUL` by 2^k becomes `BSHL` (`simplify_intmul_k`, :1481-1484), if any int MUL is emitted without FFI [I] |
| `BSHx a, cnt` | (a, cnt) | a and cnt are int | `bit.lshift(i, n)` with n int |
| `ADD a, a`, from `a << 1` (`simplify_shift_ik`, :1679-1683) | (a, a) | a is int-family | the bit library's `BSHL i, 1`, which becomes `ADD` the same way. Narrowing's unchecked index `ADD i, i` is possible [I: guide 3.13; census to confirm] |
| inner `BSHL x, k` built by `simplify_shiftk_andk`'s KINT64 branch (:1762-1771) | (x, k) | x is int-family | as the BSHL row |
| `BSHx x, k1+k2` from `reassoc_shift` (:1906-1926) | (x, k) | x is int-family | as the BSHL row |

- In game the bit library is not opened: the game opens BIT32 [S src/main/java/.../LuaJITStateFactory.java:117-125].
- So the in-game producers are `rec_varg`'s BSHL and whatever narrowing or other recorders emit. The census agent owns that list. Options B and D1 do not depend on it; A and C do.

## 4. The options

### A. Abort in the recorder

**The change.** In `oclj_rec_bitop`, after `res` is emitted and before `d` (oclj_bitop_rec.c:150), abort when a non-constant `res` comes back with a type other than I64. Allow it when it is a ref the x64 LEFTFOLD itself would hand to an int64 op. One way to test exactly that:

```c
if (!tref_isk(res) && !irt_isi64(IR(tref_ref(res))->t) &&
    tref_ref(emitir(IRT(IR_CONV, IRT_I64), res,
		    (IRT_I64<<5)|IRT_INT|IRCONV_SEXT)) != tref_ref(res))
  lj_trace_err(J, LJ_TRERR_BADTYPE);  /* a 32-bit instruction served an int64 one */
```

- **What the test accepts.** It accepts the identity folds that return an int operand or an operand's operand:
  - `i | 0`, `i & -1`, `i << 0`, `i & i`;
  - `~~i` (`shortcut_leftleft` returns the index, :998-1002);
  - `(i ~ j) ~ j` (`reassoc_bxor` returns i, :1891-1899);
  - a u8 `XLOAD` (`simplify_conv_sext` takes these refs, :1287-1299).
- **What it rejects.** A CSE'd `int BSHL`/`BNOT`/`ADD a, a` stays a CONV, so it aborts [I]. In a trace that is not aborted, the probe CONV it emits is dead, and DCE removes it [I].

**Orders and pairs fixed.**
- Fixed: the forward order at record time, when the 32-bit instruction is the operator's final ref. That covers BNOT (both forms), the constant and variable shifts, `ADD` from `<< 1` and `reassoc_shift`.
- **Not fixed: the reverse order.** The 32-bit producer is upstream code, which gets the I64 ref (lj_ffrecord.c:819; lj_record.c:2081-2086), and A never sees it.
- **Not fixed: a 32-bit instruction nested inside the result.** In `simplify_shiftk_andk`'s KINT64 branch the inner `BSHL` CSEs to the 32-bit one, and the returned `res` is an I64 `BAND` built on it (build copy :1762-1771) [S]. For a mask whose shifted bits reach beyond bit 31 the value is wrong and A's test passes [I].
- **Not fixed: the loop copy.** `loop_unroll` re-emits without the recorder.

**Patch footprint.**
- `oclj_bitop_rec.c` only. It is copied whole, and build-native.sh's freshness map already ties it to `lj_record.o` [S guide 1.3, 11.7].
- No patch-script hunk and no `verify_content` change.
- The lines that NOINT-JIT, SARCONST and INEXACT-JIT anchor on (negctl-bitop.sh:751, :771, :792) must stay untouched.
- `BADTYPE` makes `-jv` misleading [S lj_traceerr.h:24]. A reason of its own needs `lj_traceerr.h`, which no patch script touches today.

**Effect on traces that compile today.**
- Every loop with a forward pair aborts at every recording, and after 11 aborts it is blacklisted [S guide 2.5].
- That includes loops whose values are right today: in game, `select(k, ...)` path C with `k << 3`, and non-negative AND/OR/XOR pairs. Those are pure regressions [I].
- No other IR changes.

**Folds and arguments.** No rule changes; FIX-NUMCONV, the width rule and fix1 are untouched.

**Tests, arm and builds.**
- The arm removes the check. T1 (section 6) catches it by value.
- T3 must never run on an A build, because the reverse hazard stays. T3's gate refuses one: A aborts the T2 loops, so T2 reads PROVED NOTHING.

**Risk.** Low to write, high to leave in place. The crash-class order stays open.

### B. A type test in `lj_opt_cse` (recommended)

**The change.** Refuse a candidate whose I64-ness differs from the instruction being emitted, and keep walking the chain, because an older instruction of the right type may still match:

```c
      if (IR(ref)->op12 == op12 &&
	  irt_isi64(IR(ref)->t) == irt_isi64(fins->t))
	return TREF(ref, irt_t(IR(ref)->t));  /* Common subexpression found. */
```

`irt_isi64` masks the type (lj_ir.h:384), so the guard, PHI and mark flags never block a match [S]. A test written on the whole `t` byte would block guard and PHI merges, and with them hoisting.

**Three variants of the predicate.**

| variant | predicate | refuses | upstream pairs it could change (no FFI) |
|---|---|---|---|
| **B-i64** (recommended) | `irt_isi64(a) == irt_isi64(b)` | any pair where exactly one is I64: int, u8, u32, P64 or NUM against I64 | Upstream's own I64 instructions are string.buffer's `BAND`/`BXOR` with `IRT_IGC` (pristine lj_ffrecord.c:1248, :1253), `SUB` with `IRT_INTP` (:1194), and `rec_varg`'s `SUB` with `IRT_IGC` (pristine lj_record.c:2022, :2073, reached through `fold_base`, so `lj_opt_cselim`, untouched). None has a non-I64 twin with the same op12 [S grep; I that none exists] |
| B-all | `irt_sametype(a, b)` (lj_ir.h:366) | every pair of different types | any cross-type pair upstream emits. None is known without FFI [I]. It also covers U64 against int if FFI is ever turned on |
| B-width | a 64-bit integer type (I64 or U64) against an 8- to 32-bit one | exactly the value-changing class | needs a one-line macro or a static helper (the wgate) |

**Orders and pairs fixed.** All of them, in both orders: record time, the nested folds, the loop copy, side traces and the `-O-fold` path. Every one of those matches goes through `lj_opt_cse` (section 2).
- Coverage does not depend on the producer list: whatever emits the 32-bit instruction, it cannot common with ours, and ours cannot common with it.
- Refusing is value-safe. When the test refuses, `lj_opt_cse` emits `fins` exactly as requested (:2679-2688), which is what an `-O-cse` run emits [S].
- No caller needs a match. `cse_carg`, `barrier_tab`, `fload_tab_ah` and `fwd_sload` test the returned ref and emit raw otherwise [S :2341-2342, :2457-2458, :2496-2499, :2563-2566].
- In the loop copy a refused match emits a body instruction, which is recomputed each iteration. No PHI is wanted for it, and no TYPEINS arises [S lj_opt_loop.c:334][I].

**Patch footprint.**
- **The hunk.** `patch-bitop-fold.sh` gains hunk 12 (`NH` 11 to 12). `o12` is the two lines at build copy :2674-2675 (pristine :2612-2613). As a pair they occur once: the `if` line occurs twice (`lj_opt_cse` and `lj_opt_cselim`), and the comment line once [M grep -c on the build copy]. Write the tab as `@T@`; the script holds no backslash (P8).
- **NADD/NDEL.** With a four-line comment above the `if`, `NADD` goes from 70 to 76 and `NDEL` from 8 to 9 [I; confirm with the script's own count, guide 8.2 step 0].
- **The marker.** Write the comment as `OC-LuaJIT:`, without the script's path, so `NMARK` stays 1 [S guide 8.2].
- **`verify_content`.** Add:
  - the full predicate text, `irt_isi64(IR(ref)->t) == irt_isi64(fins->t))`, counted exactly once. `irt_isi64(fins->t)` alone already occurs twice, at :411 and :1177 [M grep];
  - the order `TRef LJ_FASTCALL lj_opt_cse(` < predicate < `TRef LJ_FASTCALL lj_opt_cselim(`;
  - the predicate directly preceded by `      if (IR(ref)->op12 == op12 &&` and directly followed by the return line, so that no edit leaves it outside the `if`.

  Fail-first each check as the guide requires (11.8): a stray copy, the predicate moved into `lj_opt_cselim`, the asymmetric form, and the predicate dropped.
- **What stays the same.** No LJFOLD line is added, so `rules.in` equals `rules.out` (P14). No oclj file and no wgate call. Only `lj_opt_fold.o` changes (P4).
- **The pin move.** `lj_opt_cse`'s text is byte-identical at the pin and in the extract of upstream's tip (md5 of the function's text `282290f7` in both) [M awk+md5sum over `csetwin/upstream/src-pin` and `src-tip`, another agent's extracts; I did not verify the tip's commit]. So hunk 12 survives row 270's move. `simplify_conv_sext` is identical too [M, md5 `db90df5a` both].

**Effect on traces that compile today.**
- IR changes only where an I64 and a non-I64 instruction share opcode and op12. Outside collision sites none is known (the table above), so the expected change is zero [I]. T4 measures it.
- At a collision site the trace computes both the 32-bit and the 64-bit op: one more instruction.
- Compile time: one more compare, and only on an op12 hit.
- Aborts, TYPEINS and blacklisting: no new ones [I].

**Folds and arguments.**
- No rule body changes. Rules that end in CSE (`simplify_shift_ik`'s `ADD`, `simplify_bxor_k`'s `BNOT`, `reassoc_shift`, `simplify_shiftk_andk`'s inner fold) now get an I64 twin or a new instruction.
- **The width rule.** `irt_isint` scores 33 (oclj_bitop_fold.c:76). With B it meets only int refs whose value is the operator's int64: a LEFTFOLD source, or a ref returned by a valid identity fold. Before, it also met a CSE'd 32-bit op, whose wrong value it bounded correctly [S][I]. The text of the argument is unchanged; its premise is restored.
- **FIX-NUMCONV.** `oclj_isnumconv` reads CONVs only, which `lj_opt_cse` never sees [S :1359, oclj_bitop_fold.c:170-175]. Its loop-copy induction assumes "folds and CSE preserve values" (guide 9.5, :1630). This bug made that premise false for mixed widths, and B makes it true [I].
- **fix1.** Unchanged: it is a fold-return rule, not CSE.
- **The guide's rules.** B is guide 9.3's S3 applied to types: a type that changes the value belongs in CSE identity.

**Tests, arm and builds.** See section 6.
- T1 and T2 run on every build and are the arm's catchers.
- T3 runs only behind its gate.
- T4 runs on both builds.
- Arm CSEFWD: the sabotage allows forward merges only and keeps reverse ones refused, so it stays memory-safe by construction (guide 11.7 item 8, :2014).

**Risks.**
1. **A predicate on whole `t` would block guard and PHI merges.** Use `irt_isi64` (type-masked).
2. **The hottest function in the fold engine changes.** One compare on hits only.
3. **FFI later.** B-i64 does not separate U64 from int. FFI is off (`#define LUAJIT_DISABLE_FFI 1`, oclj_features.h:61); a round that turns FFI on must move to B-all or B-width (open point).
4. **Docs.** The guide's "It does not compare the type" (:505), and every sentence that leans on it, must change (checklist item 9's grep rule, guide :34).

### C. A distinguishing operand

- **Shift counts as KINT64.**
  - The backend accepts them: `asm_bitshift` reads a KINT64 count on x64 [S pristine lj_asm_x86.h:2318-2327].
  - But every fold keyed on a KINT count stops matching:
    - `simplify_shift_ik`: the `x << 0` identity (FIX-NUMCONV's `x << 0`, `x >> 0` and `x ~>> 0` rows), the count masking, and `x << 1 ==> x + x`;
    - `reassoc_shift`, `simplify_shiftk_andk`, and `kfold_int64shift` (`BSHL KINT64 KINT`, :426-431).
  - `oclj_bitwidth` reads only KINT counts (oclj_bitop_fold.c:98-114). Every shift would score 64, and the width rule would keep guards it removes today, such as `i << 7` and `(x & 0xffff) << 8` (guide 3.12) [S][I].
  - This does remove the constant-shift pairs, the `ADD` from `<< 1` and the nested shiftk-andk case.
- **BNOT with a tag in op2.**
  - `simplify_bxor_k` rewrites `x ~ -1` to `BNOT x, 0` with op2 = 0 (build copy :1660-1662), which undoes the tag.
  - The tag also enters the fold key's literal part (`op2 & 0x3ff`, :2628). How `LJFOLD(BNOT KINT64)` and `LJFOLD(BNOT BNOT)` (:449, :996) are keyed for a missing operand decides whether they still match [I].
- **No free operand** for BAND/BOR/BXOR with two variable operands, for a variable count, or for `ADD a, a`.

**Orders.** Both orders, but only for the shapes it changes. The reverse order stays open for the two-operand bit ops and for variable counts, which is crash-class.

**Footprint.** The recorder, `oclj_bitwidth`, and FIX-NUMCONV's identities and tests.

**Verdict.** Rejected: incomplete, and it costs folds we depend on.

### D1. No int stand-ins for int64 operands (the fallback)

**The change.** Make `simplify_conv_sext`'s x64 branch do what the other targets do. Replace `return LEFTFOLD;` (pristine :1240-1242) with the zero-extension reduction `fins->op2 &= ~IRCONV_SEXT; return RETRYFOLD;` (pristine :1245-1246).

- An int operand becomes `CONV i64.int`, and `asm_conv` emits `mov r32, r32` for it [S guide 5.1].
- Then every non-constant op1 of our I64 instructions is I64-typed, and every 32-bit instruction's op1 is int-family, so their op12 can never be equal [I]. The nested and loop-copy cases are covered by the same fold.
- Without FFI only our recorder emits `CONV i64.int SEXT` [S grep]:
  - lj_ffrecord.c:1106 is under `LJ_HASFFI`;
  - lj_opt_narrow.c:376 is reached only by narrowing a 64-bit CONV, which hunk 8 blocks;
  - :506 is `lj_opt_narrow_cindex` (FFI);
  - lj_opt_mem.c:874 handles an I8/I16 XLOAD forward [I: FFI loads].

**Orders and pairs fixed.** All, both orders, independent of the producers.

**Footprint.**
- A hunk in an upstream function in `patch-bitop-fold.sh`.
- Its negctl arm (putting the LEFTFOLD back) builds today's binary, where the reverse order is unsafe. Only T1 and T2 may be its catchers, and T3's gate must refuse it.

**Effect on traces.**
- One more instruction per int operand (the loop index, `string.byte` bytes) in every trace that feeds one to a bit operator: CRC-style loops, and the guide's `i << 7` shape (3.12). A timing round is required (guide 11.12).
- The IR-reading suites (p4v, phiidx, ncir) need re-checking.
- Side effects:
  - fix1's case vanishes, because y is always I64; fix1 stays as dead but harmless code.
  - A u8 operand scores 33 instead of 64 (oclj_bitop_fold.c:79-82), which is row 211 (1)'s improvement.

**Risk.** Moderate. It also rests on an invariant that a future rule could break silently; B states the same invariant in the matcher itself.

### D2. Considered and rejected

- **A as well as B.** Under B, CSE can no longer hand back a 32-bit instruction, so A is dead code. No arm could catch its removal (P34, guide 11.7 item 9).
- **A check in `lj_opt_fold`'s return processing** (:2648-2649). It cannot tell a wrong 32-bit ref from the valid LEFTFOLD and identity returns without re-deriving `simplify_conv_sext`, and it would run for every instruction.
- **The type test in `lj_opt_cselim` too.** Its callers never see our ops (section 2), so a second check would have nothing to catch. Revisit if int64 ops ever reach SUB or EQ with `BASE`, or FLOAD.
- **A private CSE for our ops.** Fold rules' `RETRYFOLD` paths still end in `lj_opt_cse`, and the reverse order is upstream's emission.

## 5. Comparison

| | A recorder abort | **B-i64 in `lj_opt_cse`** | C tag operand | D1 no LEFTFOLD |
|---|---|---|---|---|
| forward, final ref, record time | yes | yes | shifts (KINT64), BNOT except via `~ -1` | yes |
| forward, nested in a fold rule | no | yes | only by losing the rule | yes |
| forward, loop copy | no | yes | as record time | yes |
| reverse (crash-class) | **no** | yes | partly; **not** two-operand bit ops or variable counts | yes |
| independent of the producer census | no | yes | no | yes |
| files | `oclj_bitop_rec.c` | `patch-bitop-fold.sh` hunk 12 + `verify_content` | recorder, `oclj_bitwidth`, fold behaviour | `patch-bitop-fold.sh`, an upstream function |
| IR change in today's traces | aborts at forward pairs, benign pairs included | none outside collision sites (predicted) | every constant shift | +1 instruction per int operand |
| memory-safe negctl arm | yes (forward only) | yes (CSEFWD: forward only) | — | only behind T3's gate |
| risk | high residual | low | high | moderate |

## 6. The recommended change in detail

**Hunk 12 (`patch-bitop-fold.sh`).**
- `o12` is the `if` line and the return line.
- `n12` is a four-line `/* OC-LuaJIT: ... */` comment, then the `if` split as in section 4B. The predicate line is a line of its own, so `verify_content` and the arm can each anchor on it alone (P62).
- Line 2 of the predicate starts with `@T@` and two spaces; the return line keeps `@T@return`.
- Header: the hunk list gains item 12 and the anchor sentence gains `lj_opt_cse`'s two lines. `NH`=12, `NADD`/`NDEL` as the script counts them, and the success message gains "no int64/int CSE".

**Arm CSEFWD** (`negctl-bitop.sh`, file `lj_opt_fold.c`, catchers `cse:t_csefwd cse:cseir`).
- The anchor is the predicate line.
- The new line is `@T@  (irt_isi64(IR(ref)->t) == irt_isi64(fins->t) || irt_isi64(fins->t)))  /* SABOTAGE CSEFWD: an int64 instruction may common with a 32-bit one (the forward order); the reverse stays refused */`.
- Forward means `fins` is I64 and the candidate is int, so the sabotage matches: today's behaviour, and values are wrong. Reverse means `fins` is int and the candidate is I64, so the sabotage still refuses.
- So it computes a different value and nothing else (item 8). The memory safety of forward merges is [M] for run-3's two pairs and [I] beyond them (section 7, point 8).
- No arm can hold the reverse direction: its sabotage would be crash-class. By guide 11.10 (:2099-2101), the reverse half is held by the exact-text `verify_content` check, a build assertion, together with T3 on the fixed build.

**Tests.**

| test | what it reads | order | may run on |
|---|---|---|---|
| T1 `t_csefwd.lua` | values against `-joff` and against a reference that uses no bit operator. Seed it from cse-fwd2.lua (its two pairs, its controls and its checker's fail-first). Pairs where the 32-bit value differs: `bit.lshift(i,3)` then `i << 3` (i from 2^29); `bit.lshift(i,1)` then `i << 1` (ADD; i from 2^30); `bit.bnot(i)` then `~i` and `i ~ -1`; `bit.lshift(i,35)` then `i << 3` (masked count); `bit.lshift(i, n)` then `i << n` (n int); a u8 operand, `bit.lshift(s:byte(k), 30)` then `s:byte(k) << 30`; nested, `bit.lshift(i, 8)` then `(i & M) << 8` with M a 53-bit mask (i from 2^24) | forward only | **every build**, the unfixed one included |
| T2 `cseir.lua` | `jit.util.traceir`, per trace. `served`: a marked `CONV num.i64` whose op1 is an int-family instruction with opcode `BNOT`..`BROR` or `ADD`, excluding ADD with a constant op2. That is the defect's signature; valid stand-ins are SLOAD, XLOAD and `ADD idx, k`. `split`: one I64 and one 32-bit instruction with equal op12. Wanted: `served` 0, and `split` at least 1 in every pair loop, including the value-benign ones (BAND/BOR/BXOR, BSHR/BSAR of non-negative values, `select`'s BSHL). Count only where the precondition is present (P61), key on operands (P56), and refuse `-O0`, `-O-fold` and `-O-cse`, where no collision can form [I] | forward only | **every build** |
| T3 `t_cserev.lua` (its own run-bitjit.sh part `cserev`) | values against `-joff`, plus `split`. Our operator first, then the 32-bit producer, with its result stored to a table and live in snapshots (the exact hazard): `i << 3` then `bit.lshift(i,3)`; `~i` then `bit.bnot(i)`; `i << 1` then `bit.lshift(i,1)`; `k << 3` then `select(k, ...)` beyond the varargs | reverse | **only a build that passes the gate**: in the same run, T2 passed on this `luajit.exe` with the default options, and the build copy's `lj_opt_fold.c` holds the predicate line exactly once. Never on `build/native` at `1a13bed`, and never named by any negctl arm, so neither canon nor an arm runs it. Fail-first its reader on the fixed build with same-type pairs (two `bit.lshift(i,3)` must read as merged), not on an unfixed build |
| T4 IR census | whole-trace IR of the existing suites (gen, genrg2, floor, idx, sel, nc, bitop) on base and fixed builds, refs normalized | existing suites only | both builds. The existing suites hold no reverse pair: `t_bit.lua` is the only file under `test/native/bitop/` that calls `bit.*` [M grep -l], and it uses no 5.3 operator [M grep]. `select`/narrowing pairs inside t_select, idx and gen are the census agent's to confirm |

**Option sets.** Run T1 to T3 under run-bitjit.sh's sets. Collisions need FOLD (the LEFTFOLD) and CSE together [I].

**Then the standard chain, from the main session.**
- run-bitop.sh, run-bitjit.sh (all parts, plus `cse`, plus `cserev`) and run-bitfuzz.sh.
- The negctl sweep with 37 arms; CSEFWD's margin over three runs.
- AlmaLinux 8 as well.
- A smoke timing with bench-r3 (no change expected).

**Docs to change in the same commit.**
- Guide sections: 3.9 (:505), 3.10's table (a hunk-12 row), 1.2 row 10, 7.5's NADD/NDEL, 8.2's `verify_content` paragraph, and 9.3/9.5 (S3 for types; S5's premise).
- A new pitfall: P63, "CSE ignored the type: a 32-bit instruction served an int64 one".
- 11.7 (37 arms) and 11.5d (the `cse` and `cserev` parts); Appendix A.
- The roadmap row.

## 7. Open points

1. **The producer list is mine, not the census agent's.** It needs cross-checking, especially the in-game producers: narrowing's unchecked index `ADD i, i`, any int `MUL` that `simplify_intmul_k` turns into `BSHL`, and `rec_varg`'s BSHL. B and D1 do not depend on the list; T2's pair loops and T3's reverse loops should cover every shape it finds.
2. **No loop-copy-only collision was constructed** (one where the pre-roll has none and the copy does) [I]. B and D1 cover it, A and C do not. T2 could look for one by counting `split` in loop bodies only.
3. **Upstream may have the same defect with FFI.** `crec_bit64_arg` converts through `crec_ct_tv` (pristine lj_crecord.c:1831-1839), so an int64 cdata op on the SCEV index gets the same x64 LEFTFOLD. For example, `bit.lshift(i, 3)` and `bit.lshift(i, 3LL)` in one loop [I]. Not testable on our build (FFI off). It is a candidate for row 269's upstream reports, after a check on a stock FFI build: the user's decision.
4. **The predicate variant is the user's call.** B-i64 is minimal and exact for this fork. B-all and B-width also cover U64 against int if FFI is ever turned on. Each needs T4.
5. **T3's gate.** Is "T2 passed + the predicate line present in the build copy" enough? The only build that would pass it while allowing reverse merges is one with the asymmetric reverse-allowing predicate, which `verify_content` refuses and which no arm may ever be. Whether the reverse half should also have a black-box census A/B (guide 11.10) is the main session's call. The census workloads probably contain no reverse pair, so an A/B would show nothing.
6. **If A is chosen anyway:** its abort reason (`BADTYPE` misleads `-jv`), and its regression on value-benign in-game pairs.
7. **B-i64 would split a P64/I64 pair with equal op12.** None was found by grep [S]; T4 confirms.
8. **CSEFWD's memory-safety argument rests on the forward order being value-only.** That is [M] for run-3's two pairs (rc 0) and [S][I] beyond them: x64 32-bit ops zero-extend, and `asm_fuseloadm` refuses to fuse a 32-bit spill into a 64-bit operand (guide 5.1). Before relying on it, T1 should be run on the unfixed build under every option set, with exit codes counted.
