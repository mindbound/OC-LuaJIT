# OC-LuaJIT round 3: design, pending the user's decisions

**Lua 5.3's bitwise operators with 64-bit integer semantics, on a VM whose numbers are all doubles**

- **Base:** OC-LuaJIT `5d782d7` (round 1: LuaJIT without FFI) plus round 2, uncommitted in the working tree (`string.pack`; `bench/runs/2026-10-17-strpack/`). The pinned LuaJIT `1ee778a4` at `prototype/watchdog/luajit` contains upstream a2ce8114, which parses `& | ~ << >> ~>>` and unary `~` into `BC_BNOT..BC_BSAR`.
- **Written:** 2026-10-17 by the round-3 designer, from four investigator reports (`vm`, `semantics`, `compat`, `tests`, all under `C:/Users/astro/claude-tmp/oclj/r3/`). Every load-bearing claim was re-opened or re-run in `C:/Users/astro/claude-tmp/oclj/r3/synth/` (written `synth/` below).
- **Status:** **no repo target files yet.** The user's instruction leaves semantic choices open, so this round's contract cannot be fixed until they are made. The choices come first, under USER DECISIONS NEEDED. A **prototype** of the recommended choices is built and measured in scratch:
  - `synth/proto/` holds the patch script and three new source files.
  - Builds: `synth/b1/build/native` (additive), `synth/b1d` (dropin), and a Linux `luajit` in `synth/linux1`.
  - Baseline: `synth/b0/build/native` is today's tree, built the same way, for the fail-firsts.
  - Negative and comparison variants: `synth/b-negA`, `b-negB`, `b-nyi`, `b-nophi`, `b-shiftmask`.
  - **Not run anywhere:** the harness, gradle, `negative-control.sh`, a Linux `.so`, a game.

Legend: **[M]** measured (where the log is); **[S]** read in source (file:line, pinned tree unless named); **[I]** inferred.

---

## USER DECISIONS NEEDED

The instruction "FIX the 5.3 bitwise operators ... Lua 5.3's 64-bit integer semantics on a VM whose numbers are all doubles" settles that operands and results are 64-bit. It does not settle the ten questions below. Each lists its options, what each option costs (measured where marked), and a recommendation. **The prototype implements every recommendation.** Changing any of them changes one place in the code (named) and one rule in the tests.

### U1. A result that needs more than 53 bits: round it, or refuse it?

A 5.3 result such as `-1 >> 1` (2^63-1), `(1 << 62) | 1` or `~0 >> 10` has no exact double.

- **(A) Round to the nearest double, ties to even. RECOMMENDED; prototyped.** This is round 2's D1 for `string.unpack` applied to every operator, and it is what LuaJIT does everywhere else (`2^53 + 1 == 2^53`). Every 5.3 result of 53 significant bits or fewer is exact. That covers all 32-bit work: masks, bytes, 24-bit colours, CRC32, xorshift32, and 32-bit values shifted by any count.
  - **Cost [M]: some 5.3 idioms go silently wrong.** OpenOS's 5.3 `bit32` polyfill was run on the prototype (`lib/bit32.lua`; MineOS's `Libraries/Bit32.lua` is a copy; its one `//` was respelled `math.floor`). It differs from PUC 5.3.6 in **357 of 3298 calls**: 175 `replace`, 112 `extract`, 58 rotates and 12 shifts.
  - Of those 357, 26 raise (U2). The rest return a wrong value silently: `bit32.rshift(-1, 2)` gives 0 where 5.3.6 gives 4294967295 (`synth/logs/polyfill/`).
  - Today's build differs from PUC in 927 of the same calls.
  - That polyfill never loads on our architecture, because ours has a real `bit32` (`lib/package.lua:13`). No census OS needs results above 2^53 (F15).
- **(B) Refuse an inexact result** with an error. Every result that does not raise would then equal 5.3.6's exactly, and the polyfill calls above would raise instead of lying.
  - **Cost [I]:** it raises where 5.3 computes, including `-1 >> 1`, `~0 >> 1` (5.3's `math.maxinteger` idiom), `x >> n` of most negative x for small n (`-1 >> 10`), and `(hi << 32) | lo` when hi ≥ 2^21 and lo is odd.
  - It contradicts the D1 precedent.
  - It needs an exactness check after the operation: about 3 more instructions in the interpreter, plus a guard in the JIT. Not prototyped.
- *Where it lives:* `oclj_bit2num` (`oclj_bitop.h`), the final `cvtsi2sd` in `vm_x64.dasc`, the final `CONV num.i64` in `oclj_bitop_rec.c`, and in the tests the fuzzer's reference rule (`+ 0.0` per operator).

### U2. The operand 2^63, which rounding produces

Any result in [2^63-512, 2^63) rounds to 2^63, and 2^63 has no int64 representation.

- **(A) Refuse 2^63 as an operand, as 5.3.6 does for that double: RECOMMENDED; prototyped.** This is also what our `string.pack` already does (`pk_flt2int`, round 2 D5), so the operators and pack accept exactly the same operands (F12).
  - **Cost [M]:** a rounded result in that band cannot be reused. `(~0 >> 1) & 1` raises "number has no integer representation" (`synth/logs/misc-b1.out`).
  - In the fuzzer's random tuples, 85 of 16000 reference results are "rounded into an error" where 5.3.6 computes (`synth/logs/fuzz2-b1-s1.log`).
- **(B) Saturate:** read 2^63 as `math.maxinteger`. Then `x & (~0 >> 1)` clears the sign bit exactly as in 5.3.
  - **Cost [I]:** `2^63 | 0` computes where 5.3.6 raises.
  - Values such as 2^63-7 that rounded up become maxinteger silently, instead of raising.
  - Pack would then disagree with the operators, unless round 2's `pk_flt2int` changed too.
- *Where it lives:* `oclj_flt2int`, plus the interpreter's round-trip check (`cvttsd2si`/`cvtsi2sd`/`ucomisd`), which already sends 2^63 to the C path.

### U3. Strings as operands

- **(A) Coerce as 5.3.6 does: RECOMMENDED; prototyped.**
  - The reading is luaO_str2num, then tointeger: `"3" & 1` is 1, `"0x10" | 0` is 16, and `" 7 "`, `"1e3"` and `"-0"` are accepted.
  - A decimal integer numeral is exact if it fits int64. A hex numeral of any length wraps mod 2^64, so `"0xffffffffffffffff" | 0` is -1.
  - `"1.5"`, `"abc"` and `"inf"` are refused.
  - This is the same reading as round 2's D5 for pack arguments; 51 strings were measured to agree, pack against operator (F12).
  - LuaJIT's arithmetic already coerces strings (`"10" + 1` is 11 here), so coercion is no stranger to the VM. `tonumber` and arithmetic keep LuaJIT's own reading (`"0xffffffffffffffff" + 0` is 1.8446744073709552e19), as with pack.
  - **Cost:** about 70 lines of C on the slow path. A string operand never takes the fast path, and a trace aborts on it (`LJ_TRERR_BADTYPE`), so such loops run interpreted [M: the abort counts in the fuzz logs].
- **(B) Refuse strings**, as today, but with the bitwise wording. This differs from 5.3 for every numeric string.
- *Where it lives:* `ob_tonum` in `oclj_bitop_meta.c`.

### U4. Floats with no integer representation (1.5, NaN, inf, ±2^64)

- **(A) Raise "number has no integer representation", as 5.3.6 does: RECOMMENDED; prototyped.**
  - Today the tobit trick rounds silently: `1.5 | 0` is 2 and `1e100 | 0` is 630506365.
  - The parser does not fold such an operand, so `1.5 & 1` still compiles and raises at run time, as with 5.3.6's `lcode.c` validop.
  - Census: Plan9k's one plain-code use, `toHex` (`01_util.lua:98`), shifts byte values, which are integral [M grep].
- **(B) Truncate toward zero**, as bit32 does in 5.2. **(C) Keep today's rounding.** Both differ from 5.3.6 on every non-integral operand.

### U5. Error-message shape

- **(A) LuaJIT's shape with 5.3's verb: RECOMMENDED; prototyped.** Every other operator error on this VM keeps LuaJIT's shape. The messages:
  - `attempt to perform bitwise operation on local 't' (a table value)`.
  - `number (local 'x') has no integer representation`, which is 5.3.6's shape, with LuaJIT's slot names.
  - Constant operands read exactly as in 5.3.6: `attempt to perform bitwise operation on a nil value`, `number has no integer representation`.
  - Blame order as in 5.3.6, measured identical on all 7440 matrix cases (F9).
  - Residual: LuaJIT names fewer operands, so 5.3.6's `number (field '?') has no integer representation` is `number has no integer representation` here [M `t_jit2` guard-error].
- **(B) 5.3.6's word order exactly** (`... on a table value (local 't')`). This means a second formatter used only by these operators.
- **(C) Keep "perform arithmetic on".**

### U6. The JIT

- **(A) Record the operators as int64 IR, with three fold-engine changes: RECOMMENDED; prototyped.** The three changes:
  - The int64 constant folds that LuaJIT compiles only with FFI are un-stubbed. Without FFI, `BAND/BOR/BXOR KINT64 KINT64` silently folds to the left operand.
  - An i64 CONV is never narrowed.
  - A width fold `(i64)(num)y ==> y` applies when y provably lies in [-2^53, 2^53), also across PHIs.
  - Measured [M]: 0 JIT-against-interpreter differences across all suites (F6, F7); both negative builds are caught (F8); speed in F10.
  - Today's speed is kept for masked loops: the bit loop runs at 0.40 ns per iteration on both builds, RGB at 3.7-3.8 against 3.6-3.7 ns.
  - **Cost:** table-driven CRC32 runs at 14.1 ns per byte against today's 2.9, and bit-serial CRC32 at 100 against 48.5. Both still beat PUC 5.3.6 (32.4 and 121).
- **(B) The same without crossing PHIs:** the pure shl/xor/and loop runs at 7.8 ns/it, 19x slower.
- **(C) Not recorded (NYI: the trace aborts and the loop is interpreted):** the safe fallback, measured not to miscompile (F8).
  - **Cost [M]:** bit loop 10.55 ns/it, RGB 41.3 ns, CRC table 31.6 ns/byte. Against (A) that is 26x, 11x and 2.2x; against today's JIT, 26-30x, 11x and 11x.
  - The fuzzer's coverage gate then reads PROVED NOTHING (83 of 1000 hot cases compiled), which is the gate working.
- **Recommendation: (A).** The PHI-crossing width fold rests on a monotonicity argument (§3.5), not a proof, so it needs a review. Its adversarial tests ship with it (§6).

### U7. Bitwise metamethods (`__band __bor __bxor __shl __shr __bnot`)

- **(A) Defer: RECOMMENDED; prototyped (none).** LuaJIT 2.1 has none (a2ce8114 says "Not backported: bit operator metamethods", doc/extensions.html:432-436 [S]).
  - A table, nil, boolean, function or userdata operand raises the type error.
  - **Census: zero uses** of any of the six names in AxisOS, MineOS, QuickOS, OpenOS and Plan9k (both copies), and OC's kernel [M grep].
- **(B) Implement them in round 3.**
  - **Cost [S]:** six MMDEF slots grow `gcroot[]` and move GG_State. That means the layout gates and every "6376" in docs and tests.
  - It also needs a vmeta continuation path like vmeta_arith, recorder support, and eris continuation-frame acceptance (`bcmode_mm(BC_BAND..)` is none today; eris_lj.c refuses mismatched sites).

### U8. `~>>` (LuaJIT 3.0's arithmetic right shift, also `~>>=`)

This is not 5.3. Today it is BitOp's `arshift`: 32-bit, count & 31.

- **(A) Keep it, 64-bit: RECOMMENDED; prototyped.**
  - A count in 0..63 is `sar` on int64.
  - A count of 64 or more fills with the sign: 0 or -1.
  - A negative count shifts left, giving 0 at -64 or below: the mirror of 5.3's `>>`.
  - The result is rounded as in U1.
  - Measured [M] against a model on PUC: 391 cases, each folded, interpreted, compiled with a variable count and compiled with a constant count. 0 differences (`synth/logs/sar/`).
  - Census: zero uses [M grep].
- **(B) Remove it from the syntax** with a lexer patch. That drops one of a2ce8114's extensions while the rest (`!=`, `&&`, `continue`, ...) stay (row 146 lists them).
- **(C) Leave it 32-bit.** Then it is the one operator with 32-bit semantics. Not recommended.

### U9. Hex literals of 2^63 and above, and decimal literals above 2^53

- **(A) Keep LuaJIT's lexer, which reads a literal as the nearest double: RECOMMENDED; prototyped.**
  - `0xffffffffffffffff` is 2^64, and `0x7fffffffffffffff` and `0x8000000000000000` are both 2^63. All three raise "no integer representation" as operands, where 5.3.6 has -1, maxinteger and mininteger.
  - Measured as the only literal-folding differences [M `synth/logs/ops/fold-*.txt`].
  - **Census: zero literals beyond 2^53** in every tree [M grep; the one hit is a string].
- **(B) Wrap hex integer literals mod 2^64, as 5.3 does.**
  - This changes what existing 5.2-style code means: `print(0xffffffffffffffff)` would print -1.
  - `0x7fffffffffffffff` would still round to 2^63 and stay unusable.
  - It needs a lexer patch (`lj_lex.c:114-116`).

### U10. `bit` and `bit32`

- **(A) Untouched: RECOMMENDED; measured unchanged.**
  - OC's `bit32` is the shim's real 5.2 library: shim suite section D passes, 57/0.
  - 5.3.6's own compatibility `bit32` is also 32-bit, so in 5.3 itself `bit32.lshift(1, 32)` is 0 while `1 << 32` is 4294967296.
  - LuaJIT's `bit` is not in the sandbox. On luajit.exe, `bit.lshift(1, 32)` is 1 and `bit.tobit(2^32)` is 0, as before [M].
  - The `bit` fast functions keep their own TOBIT recorder path. Only the six bytecodes change.

### Also to confirm (no option to pick, but the user should know)

- **No integer subtype.** Rounding at every operator means iterated 64-bit algorithms (64-bit hashes, xorshift64, SHA-512) cannot match 5.3 on this VM; 32-bit-masked ones match.
  - `tostring` prints a result of 1e14 or more in `%.14g` exponent form: `1 << 47` prints `1.4073748835533e+14`, while `%d` and `%x` print it exactly.
  - Arithmetic between operators is double arithmetic.
  - Recommendation: document all three as deviations next to D1. An integer subtype stays out of scope.
- **Today's operators are not even self-consistent.** In today's build, `(i * 2^45 - i) | 0` in a loop gives -66 compiled and -33 interpreted at i = 66; 233 of 300 iterations differ [M `synth/probes/today_div.lua`]. Generated recurrences differ between JIT and interpreter in 141 of 400 (seed 1) and 125 of 400 (seed 2) [M `synth/logs/rec/b0-*`].
  - The cause is BitOp's unspecified range beyond ±2^51, which LuaJIT's narrowing exploits.
  - Round 3 removes this: 0 of 800 on the prototype. It is a pre-existing defect, worth one line in roadmap row 206's "found" list.

---

## 0. Scope and rules

### In scope

1. The six bytecodes `BC_BNOT, BC_BAND, BC_BOR, BC_BXOR, BC_BSHL, BC_BSHR` and `BC_BSAR` (`~>>`, U8) get Lua 5.3.6's semantics as decided above. That covers parse-time folding, the interpreter (fast and slow path), and the JIT (recorder and fold engine). Compound assignments (`x <<= 40`, `x ~= y` as a statement) come with them, since they emit the same bytecodes: `x <<= 40` gives 2^40 [M `synth/logs/misc-b1.out`].
2. Persistence: `BCDUMP_VERSION` becomes 0x80 (`lj_bcdump.h:36-39`). The blob fingerprint's word gains a ninth token.
3. Tests that prove all of it against PUC 5.3.6, and prove that the tests can fail.

### Not in this round

- Bitwise metamethods (U7), `//`, `math.type`/`math.tointeger`/`math.maxinteger`, the integer subtype, `utf8`.
- The upstream `PROTO_BITOP`/closure-counter collision (F17): speed only. It is to be recorded and reported upstream, not fixed here.
- The two JIT speedups F10 names (table-index conversions, a cheaper int64-domain guard): a follow-up row.

### Rules for implementers (once targets exist)

As round 2's §0:
- Edit only your own files; write LF; no git.
- Never write under `build/` or into `serializer/` at run time, and never run `negative-control.sh`, the harness or gradle.
- Build in your own scratch with `OCLJ_BUILD=<scratch>/build/native`.
- Never write a file containing backslashes through a shell heredoc. `oclj_bitop_meta.c` contains `'\0'`, `'\t'` and `'\r'`.
- **New for this round:** `cp -r serializer` to a scratch copy keeps the checkout's prebuilt `erislj_test.exe` with a fresh mtime, so `make test` does not rebuild it and silently tests the old binary. In this round's scratch, that stale binary even failed differently (`synth/logs/ser-b1-test.log`). `rm -f erislj_test.exe erislj_test` first [M].

---

## 1. Facts this rests on

**F1 [S] Today's lowering.**
- **Lexer:** `lj_lex.c:365-379` gives `TK_shl`, `TK_shr` and `TK_sar` (`~>>`).
- **Parser:** priorities match 5.3's (`lj_parse.c:2302-2312`, `lparser.c:1029-1042`). `bcemit_binop` sets `PROTO_BITOP` (`:956`, `:1056`) and emits `BC_BAND+(opr-OPR_BAND)` with both operands in registers. There are no constant forms.
- **Folding:** `foldbitop` (`:818-835`) and the `~` fold (`:1049-1053`) fold every numeric constant pair to int32 through `expr_bitV` (`:89-93`, `lj_num2bit`), with shift counts & 31.
- **Interpreter:** `vm_x64.dasc:3522-3600` takes the low 32 bits after `addsd 2^52+2^51` and computes in 32 bits. A non-number goes to `->vmeta_bnot`/`->vmeta_bitop` (`:1098-1135`), then `lj_meta_bitop` (`lj_meta.c:242-308`), which without FFI or DUALNUM only raises `attempt to perform arithmetic on`.
- **Recorder:** `lj_record.c:2509-2547` records `lj_opt_narrow_tobit` plus int32 `IR_BAND..`.

**F2 [M] Today's results** (`synth/b0`, luajit.exe md5 `2e737b868794`). `1<<32` is 1, `1<<31` is -2147483648, `(-1)>>1` is 2147483647, and `"3" & 1` raises the arithmetic error.
- The 7440-case runtime matrix (`r3/vm/t_ops.lua`) agrees with PUC 5.3.6 in 696 cases (`synth/logs/ops/`).
- The differential fuzzer reports 11665 of 16000 tuples MISMATCH (`synth/logs/fuzz2-b0-s1.log`).
- JIT and interpreter disagree beyond ±2^51 (see "Also to confirm" above).

**F3 [S] 5.3.6's rules,** re-read in `bench/vendor/lua-5.3.6/src/`:
- **Operands:** `luaV_tointeger` mode 0 (`lvm.c:94-117`, `luaconf.h:447-451`); strings through `luaO_str2num` (`lobject.c:299-343`).
- **Operations:** int64 wrapping (`lvm.h:46`); `luaV_shiftl` (`lvm.c:588-601`), where `>>` is `shiftl(x, -n)` and logical.
- **Errors:** `ltm.c:142-149`, `ldebug.c:598-615`.
- **Folding:** only valid operands fold (`lcode.c:960-971`).

**F4 [M] The prototype is correct against PUC 5.3.6 on the runtime matrix.** On `t_ops.lua`, with LuaJIT's error word order rewritten to 5.3's (`synth/probes/reword.py`, 1350 messages), `synth/b1` equals PUC 5.3.6 on **all 7440 cases**, JIT on and `-joff` identical (`synth/logs/ops/`). The same holds on Linux: the WSL `luajit` built from the same patched copy equals Linux PUC 5.3.6 and equals Windows byte for byte (`synth/logs/linux/`).

**F5 [M] Folding.** `t_fold.lua`'s 45 literal cases equal PUC except the LEX class (U9: three hex literals, three of their `| 0` uses) and `5 // 1` (`synth/logs/ops/fold-*.txt`). Operands with no integer representation are left to the run time ("runtime:BOR").

**F6 [M] The differential fuzzer passes** (the `tests` investigator's driver, with one comparator change: F13).
- Seed 1, 1000 cases × 16 tuples: **MISMATCH 0** in modes K/V/P/H/U, JIT on and `-joff`.
- All four instrument controls behave: sim-wrap PASS; sim-raw FAIL in exactly the 2983 ROUNDED tuples; sim-rta FAIL 213; sim-rtz FAIL 1610 (`synth/logs/fuzz2-b1-s1.log`).
- Strict mode, which compares the verb too: PASS.
- Campaign, seeds 11-14 × 10000 cases: **640 000 tuples, 0 MISMATCH**, about 62% of hot loops compiled (`synth/logs/fuzz3-b1-s1[1-4].log`).
- Linux, seed 1, against Linux PUC: PASS (`synth/logs/linux/fuzz-s1.log`).
- Against today's build: FAIL, 11665 (F2).

**F7 [M] The JIT agrees with the interpreter everywhere tested.**
- `r3/vm/t_jit.lua`: 1740 hot cases, 0 mismatches.
- `r3/vm/t_jit2.lua`: 20 loops built to break the JIT, identical under the default options, `-joff`, `-O0`, `-O1`, `-O3 -Ohotloop=1`, `-Omaxside=0` and `-Ohotloop=1 -Ohotexit=1`; also on Linux (`synth/logs/jit/`, `synth/logs/linux/`).
- **`synth/probes/t_rec.lua`, new this round:** loop-carried recurrences mixing bit operators with double arithmetic on the loop index. It covers what the fuzzer cannot (F8). 800 recurrences × 5 starting values, plus 800 more with negative, ≥ 64 and -2^63 shift counts: 0 differences. Linux identical.
- `synth/probes/t_sar.lua` (`~>>` against a model): 0.
- `t_jit2` differs from PUC only in the inherent classes: rounding, 5.3's integer `+`/`*`, `~>>`, and the one varinfo residual.

**F8 [M] Each fold change is load-bearing, and the suites catch its removal.**

| build | `t_jit2` | `t_rec` (seeds 1, 2) | `t_rec counts` (3, 4) | fuzzer (2 × 10000 cases) |
|---|---|---|---|---|
| negA: no narrow_convert skip | `bnot` differs | **87, 81** | 63, 47 | **0: not caught** |
| negB: int64 BAND/BOR/BXOR fold left FFI-only | `kfold` differs | 10, 5 | -- | 8413, 8412 (H, U) |
| nyi: not recorded | identical | 0, 0 | -- | 0, then **PROVED NOTHING** (83/1000 hot) |
| nophi: no PHI crossing | identical | 0, 0 | 0, 0 | -- |
| shiftmask: no `cmp RA, 63` in the fast path | -- | -- | -- | 3585, and `t_ops` 238 |
| r3/vm's full3d prototype | -- | -- | **1, 3** | -- |

- The fuzzer's expressions hold only bitwise operators and fresh table values, so it never reaches the narrowing trap. Hence `t_rec`/`t_jit2` must ship beside it.
- **Found this round: the `vm` investigator's prototype miscompiles `x ~>> -2^63` for a negative x with a constant count.** It gives -1 compiled and 0 interpreted (`synth/probes/sar_minint.lua`, `synth/logs/sar/vmfull3d.txt`: 7 splits). Neither its 20-loop suite nor the fuzzer, which has no `~>>`, saw it. Fixed in `synth/proto/oclj_bitop_rec.c`, whose constant-count `~>>` now follows `oclj_shiftar` case by case.

**F9 [M] Errors.** On the 7440 cases, the operand blamed and the message kind equal 5.3.6's after word-order rewriting (F4). Samples:
- `attempt to perform bitwise operation on local 't' (a table value)`.
- `number (local 'x') has no integer representation`.
- `number has no integer representation` for a temporary (`synth/logs/misc-b1.out`).

**F10 [M] Speed.** Unpinned, best of 3. **Two `java.exe` processes were running and were not probed** (the game-open rule); figures are comparisons within one session (`synth/logs/bench/bench-1.txt`; scripts `r3/vm/bench_bit*.lua`).

| loop | today, interp | prototype, interp | today, JIT | prototype, JIT | nophi | nyi | PUC 5.3.6 |
|---|---|---|---|---|---|---|---|
| shl/xor/and loop, ns/it | 9.85 | 10.60 | 0.35-0.40 | 0.40 | 7.8 | 10.55 | 4.75 (r3/vm) |
| RGB pack/unpack, ns | 37.7 | 41.3 | 3.6-3.7 | 3.7-3.8 | 3.7 | 41.3 | 25.2 (r3/vm) |
| CRC32 bit-serial, ns/byte | 142.5 | 147 | 48.5 | 100 | 100 | 147 | 121 (r3/vm) |
| CRC32 table, ns/byte | 29.3 | 31.8 | 2.9 | 14.1 | 14.1 | 31.6 | 32.4 (r3/vm) |

- The interpreter's 64-bit fast path is 3-10% slower.
- Table CRC is 4.9x slower than today's JIT. Its cause, read from r3/vm's IR dump (`m6/dump-crct-p3d.txt`): every table-loaded value takes a checked conversion, and `crc >> 8` unmasked has a 57-bit bound. Follow-ups, unbuilt: fold `CONV int.num (CONV num.i64 y)` for small y (table indices), and an int64-domain range guard instead of the round trip.

**F11 [M] Build and layout.** `build-native.sh` on the patched copy exits 0, dropin and additive (`synth/logs/b1-build.log`, `b1d-build.log`):
- `FOREIGN-ALLOC-OK GG=6376`, unchanged: no new bytecode, IR op or metamethod.
- Word `...p64.pack1` (no token yet), serializer hash `baf083da`, ABI 87/89 dropin.
- No compiler warning.
- DynASM regenerated `host/buildvm_arch.h` from the patched `vm_x64.dasc` (`luajit_build.log:118`); the two patched blocks' comments are echoed in it.
- Sizes: `libluajit.a` 707 894 B (today 699 926), additive DLL 738 655 B (today 732 544).

**F12 [M] The operators and `string.pack` read operands alike.** `synth/probes/coerce_agree.lua` (51 strings: signs, spaces, hex wrap, 2^63 and over, `inf`, `nan`, `0b`, an embedded NUL, partial numerals) gives 0 disagreements on the prototype and on PUC 5.3.6, and 29 on today's build. The prototype's converter is a second copy of round 2's `pk_str2int`/`pk_str2d` over a `GCstr` (D4 decides that).

**F13 [M] The fuzz comparator needs the LuaJIT word order.** Unchanged, it scored 175 tuples as `E:TYPE -> E:OTHER`. All 175 were `attempt to perform bitwise operation on local 'a' (a boolean value)`, in V/P/H/U (`synth/logs/fuzz-b1-s1.log`). One added pattern in `errkind` (`synth/fuzz/bitfuzz.lua`) makes it PASS. That pattern is U5's residual, encoded.

**F14 [M] Persistence.**
- **Same fingerprint, version bumped:** a blob of closures saved on today's build is refused by the prototype mid-restore with `eris-lj: cannot load function (eris-lj: cannot load incompatible bytecode)`, and the reverse likewise. Each build restores its own blob (`synth/logs/xb/`, hosts `synth/ser0`, `synth/ser`).
- **Serializer suites on the prototype** (host rebuilt against `synth/b1`): m1 82, m2 56, m3 79, stack-universe 0 FAILS, fingerprint 18/18, strpack 11/11.
- **For-in:** `diag/4-identity` fails `body differs from the reference at byte 14`, as expected. The diag blob against `tests/fixtures/forin-identity.blob` differs in **exactly 3 bytes, all three dumps' version bytes (0x80 against 0x02)**, plus the masked frame-link payload at 499-503 (`synth/logs/forin/cmp.txt`).
- **A coroutine frozen mid-loop inside a compiled 64-bit bit-op trace** persists, restores and resumes to the uninterrupted result. `synth/probes/ser_bitop.lua` passes 6/0 on the prototype; on today's build it fails exactly the folded-constants check (`synth/logs/ser_bitop-b*.out`).
- With a ninth token, the refusal moves to the header (compat measured it on its own prototype: `r3/compat/xb/load2-b1-on-tok.out`; not re-run here).

**F15 [M] Consumers** (grep over the census trees listed in `r3/semantics/census-1/trees.txt`, all present):
- Zero bitwise metamethods, zero `~>>`, zero literals beyond 2^53 (the one long-digit hit is a string, `RayEngine.lua:385`).
- Plan9k's `toHex` (`01_util.lua:98`) is the one plain-code use, on bytes.
- The semantics investigator's tokenising census agrees, and adds two points. Every census OS uses its `bit32` path on our architecture. The 64-bit semantics matter to player programs written for OC's 5.3 CPU, which is GTNH's default [S `r3/semantics` report; not re-run].

**F16 [M] Native suites on the prototype** (`synth/logs/suites-b1/`): shim 57/0, mem 86/0, vgc 47/0, wd 35/0, penalty 6/0, race 2/0, run-pack 13/0 (all conformance exact), security 55 with **2 failures, FF9 and FF10**.
- The failures exist only because `security_test.c:182-188` embeds version-2 dumps.
- With the fixtures' byte 3 set to 0x80 and a new check FF12 ("an upstream version-2 dump is refused"), the prototype passes 56/0. Today's build then fails FF9, FF10 and FF12, which is FF12's fail-first (`synth/sec/`, `synth/logs/sec80-b*.log`).
- The 0x80 `BC_PLAIN` equals the prototype's own `string.dump(load("return 1"), true)` byte for byte [M].
- The count hook still fires inside a compiled 64-bit bit loop: 240000 on both builds (`synth/probes/checkhook_bit.lua`).

**F17 [S][M] An upstream collision.** `PROTO_BITOP` is 0x80 (`lj_obj.h:404`), inside the 3-bit closure counter at 0x20..0xe0 (`:409-411`, `lj_func.c:134-135`). So `flags >= PROTO_CLC_POLY` (`lj_record.c:802`, `:1795`) is always true in a function that uses a bit operator: its immutable upvalues are never constified, and its calls specialise to the prototype.
- Measured: one `UREFC` with a bit operator, a constant without it (`synth/probes/clc.lua`).
- The effect is speed only. The flags byte has no free bit, so a fix is not a one-liner. Record it (roadmap) and report upstream.

**F18 [S] What still returns FAILFOLD without FFI.** `kfold_int64arith2` (`lj_opt_fold.c:406`, DIV/MOD/POW), `kfold_bswap64` (`:450-455`) and `simplify_intmul_k64` (`:1438`) stay FFI-only: a trace abort, never a wrong value. The recorder never emits those ops. `simplify_shiftk_andk` (`:1688-1706`) is not FFI-gated and calls `kfold_int64arith` with shift ops, which the un-stubbed block covers.

---

## 2. Decisions

Rows marked **U#** follow a user decision; the stated choice is the recommendation. The rest are the designer's.

| # | Question | Decision | Why |
|---|---|---|---|
| D1 | Semantics | U1-U10 as recommended | Each item above |
| D2 | One rule set | `native/luajit/oclj_bitop.h` (no Lua state): `oclj_flt2int`, `oclj_u2s`, `oclj_shiftl`, `oclj_shiftar`, `oclj_bitop64`, `oclj_bit2num`. Included by the parser, the slow path and the recorder. It `#error`s unless `OCLJ_LUAJIT_FEATURES` and `OCLJ_OPS_BIT64 == 1`, and under DUALNUM | Folding, the C path and the recorder's record-time decisions cannot disagree. The fast path and IR are checked against them by tests |
| D3 | Slow path | `native/luajit/oclj_bitop_meta.c`, `#include`d by the build copy's `lj_meta.c` above `lj_meta_bitop`, whose no-FFI tail becomes `oclj_meta_bitop(L, ra, rb, rc, op)`. Errors are raised by its own copy of `err_msgv` (public `lj_strfmt_pushvf`, `lj_debug_addloc`, `lj_err_run`), with the verb and the two "no integer representation" texts as literals, and LuaJIT's `LJ_ERR_BADOPRT`/`BADOPRV` formats reused | `lj_err.c` is already patched by `patch-fastfunc-errmem-top.sh`, and `lj_errmsg.h` needs no change. The `vm` prototype added three ERRDEFs and a function in `lj_err.c`; this one touches neither and measures the same (F4) |
| D4 | The 5.3 string reader | **Factor** round 2's `pk_isspace/isdigit/isxdigit/hexavalue`, `pk_str2int`, the refusal prefix of `pk_str2d`, `pk_flt2int` and `pk_u2s` into `native/luajit/oclj_num53.h` (`static LJ_AINLINE`; `(const char *, size_t)` inputs; the scan by `lj_strscan_scan(..., STRSCAN_OPT_TONUM)`), included by `oclj_strpack.c` and `oclj_bitop_meta.c`. `oclj_flt2int`/`oclj_u2s` alias them | One copy. No `negctl-pack.sh` anchor moves: CHECKINT's line is in `pk_checkint` and LJCOERCE's in `pk_tonum`, both of which stay in `oclj_strpack.c` [S `negctl-pack.sh:165-167`, `:196-198`]. `coerce_agree.lua` ships as a check (F12). **Unproven [I]:** the prototype kept two copies |
| D5 | Recorder | `native/luajit/oclj_bitop_rec.c` (`synth/proto/oclj_bitop_rec.c`), `#include`d by `lj_record.c` after its emitir macros. The seven cases call `oclj_rec_bitop` | U6-A. The constant-count `~>>` is per F8's fix |
| D6 | Fold engine | In `lj_opt_fold.c`: the seven `#if LJ_HASFFI` guards of the int64 bit folds become `#if 1` (`:376`, `:432`, `:444`, `:471`, `:492`, `:1746`, `:1794`); `narrow_convert` (`:1312`) returns NEXTFOLD for an i64 CONV; and `simplify_conv_i64_num` (`:1140`) gains the width fold (§3.5) | F8: two of the three are proven load-bearing; the third is the speed of U6-A |
| D7 | Interpreter | `vm_x64.dasc`: the BC_BNOT block and the `ins_bitop` macro's non-DUALNUM half are replaced, and `->vmeta_bitop_pc` (reload RA/RC from PC) is inserted before `->vmeta_bitop` (§3.4) | No calls, so no ABI difference: measured on Windows and SysV |
| D8 | Bytecode version | `BCDUMP_VERSION 0x80`, the first private value; the next private change takes 0x81 | `lj_bcdump.h:36-39` demands at least 0x80. Upstream's `BCDUMP_F_BITOP` cannot mark folded constants (compat [M]: `return 1 << 32` dumps without the flag) |
| D9 | Feature macro | `#define OCLJ_OPS_BIT64 1` in `oclj_features.h`, new section "OUR CHANGES TO WHAT LuaJIT'S BYTECODE MEANS". Its comment names `BCDUMP_VERSION 0x80` and the token | One source of truth, as `OCLJ_LIB_STRPACK` |
| D10 | Token | Ninth word token **`bit64`** (else `bit32`), last | Self-describing, like `gc64`/`p64`; the off value is upstream's behaviour |
| D11 | Patch scripts | Six new `native/luajit/patch-bitop-*.sh` (parse, vm, meta, record, fold, bcdump), each in `patch-strpack-register.sh`'s form: pristine input asserted; exact anchors once; insertion and replacement checked by content and diff; strips CR, writes LF; no backslashes. Their hunks are exactly `synth/proto/apply_r3.py`'s (variant `full`) | The round-1/2 pattern. `apply_r3.py` is the normative text of every hunk |
| D12 | Dropin | Gets it too | Same archive (round 2 D13) |
| D13 | Not changed | `lj_lex.c`, `lj_err.c`/`.h`, `lj_errmsg.h`, `lib_bit.c`, the shim, OC-JNLua, `native/kernel/*`, `eris_lj.h`, `test_main.c`, `negative-control.sh` | U9, U10, D3 |

---

## 3. The implementation (prototype: `synth/proto/`, md5s in the appendix)

### 3.1 `oclj_bitop.h` (93 lines)

U1-A, U2-A and U8-A are encoded here:
- `oclj_flt2int` accepts exact integral doubles in [-2^63, 2^63); NaN fails the range test.
- `oclj_bitop64` computes 5.3.6's operations on `uint64_t`. `BC_BSHR` passes `-c`, with INT64_MIN kept as INT64_MIN.
- `oclj_bit2num` is `(double)(int64_t)r`, round to nearest, ties to even.

### 3.2 `oclj_bitop_meta.c` (191 lines)

- `ob_str2int`/`ob_str2d`/`ob_tonum`/`ob_toint` give 5.3.6's view of an operand (D4 replaces the first two with `oclj_num53.h`).
- `oclj_meta_bitop`:
  - If both operands convert: `setnumV(ra, oclj_bit2num(oclj_bitop64(op, b, c)))`.
  - Else, if both are numbers or numeric strings: `ob_err_noint` on the first that fails `toint`.
  - Else: `ob_err_type` on the first that fails `tonum`.
- For BC_BNOT the interpreter passes the operand as both `rb` and `rc` (`vm_x64.dasc:1098-1102` [S]).

### 3.3 `lj_parse.c` (+17 -19 in the diff)

- Include `oclj_bitop.h` and delete `expr_bitV`.
- `foldbitop` folds only when both constants pass `oclj_flt2int`, to `setnumV(oclj_bit2num(oclj_bitop64(...)))`.
- The `~` fold does the same.

### 3.4 `vm_x64.dasc` (+32 -15)

- **BC_BNOT:** `cvttsd2si RB, xmm0`; `cvtsi2sd xmm1, RB`; `ucomisd`; `jne`/`jp ->vmeta_bnot`; `not RB`; `cvtsi2sd xmm0, RB`.
  - 2^63 and larger become INT64_MIN, whose round trip differs, so they take the C path.
  - -2^63 round-trips and is accepted. NaN goes out through `jp`.
- **ins_bitop:** the same round trip for both operands, to `->vmeta_bitop_pc`. Shifts take the fast path only when `cmp RA, 63` / `ja` finds the count unsigned at most 63. Then the 64-bit `and/or/xor/shl/shr/sar` and `cvtsi2sd`.
- **`->vmeta_bitop_pc`:** `movzx RCd, PC_RB`; `movzx RAd, PC_RC`, as the DUALNUM path already does. It then falls into `->vmeta_bitop`.
- DynASM sees only the Makefile's `-D` flags (compat [M]). The patch is unconditional and touches only `.else` (non-DUALNUM) halves; `oclj_features.h` already refuses `LUAJIT_NUMMODE`.

### 3.5 `lj_record.c` (+7 -35) and `lj_opt_fold.c` (+92 -8)

**Recorder** (101 lines, D5). An operand is handled as follows:
- An int TRef is sign-extended (`CONV i64.int SEXT`).
- A constant is checked at record time and becomes a `KINT64`.
- Any other number gets `CONV i64.num` plus `CONV num.i64` back and an `EQ` guard. The guard fails for non-integral values, NaN and out-of-range values; the side exit returns to the interpreter, which raises.
- A string, or a value not convertible at record time, aborts the trace (`BADTYPE`).

Shift counts:
- A constant count is decided at record time: it becomes `0`, `BSHL`/`BSHR k`, or for `~>>` per `oclj_shiftar`.
- A variable count is guarded `ULT 64` at record time and aborts when outside 0..63.

The result is `CONV num.i64`.

**Width fold** (`oclj_bitwidth`, `oclj_kwidth`). It returns a bound w with the value in [-2^(w-1), 2^(w-1)); 64 means unknown.
- Leaves with a finite bound: `KINT64`, an int value (33), `CONV i64.int` (32 sign-extended, 33 zero-extended), `BAND` with a non-negative constant (that constant's width), and `BSHR` by a constant k ≥ 1 (65 - k).
- Operators: `BOR`/`BXOR`/`BAND` take the max; `BNOT` keeps the width; `ADD` (from `x << 1`) adds 1; `BSHL` by a constant adds k; `BSAR` by a constant subtracts k. All are capped at 64. The depth limit is 6, beyond which the bound is 64.
- `(i64)(num)y ==> y` when w ≤ 54, also when the inner CONV is a PHI.

**The soundness argument (for review).**
1. Every leaf's bound holds in every iteration, independent of the iteration (constants, int types, which loop typing keeps stable, masks, unsigned shifts).
2. Every operator's bound is monotone in its operands' bounds.
3. A loop copy has the pre-roll's structure with substituted operands, so its bound is at most the pre-roll's.

Hence the pre-roll bound holds for every value the PHI takes [I]. Measured: F7 and F8, the nophi comparison included.

### 3.6 `lj_bcdump.h` (+1 -1), and `lj_meta.c` (+6 -26)

- `lj_bcdump.h`: `#define BCDUMP_VERSION 0x80`.
- `lj_meta.c`: `#include "oclj_bitop_meta.c"` under `#if !LJ_HASFFI`, directly above `lj_meta_bitop` (`:242`). The no-FFI tail of `lj_meta_bitop` is replaced by the single call `oclj_meta_bitop(L, ra, rb, rc, op)`; that tail held the DUALNUM 32-bit block and the `LJ_ERR_OPARITH` raise. The FFI branch stays as it is, compiled out.

### 3.7 Size

- The prototype diff against `1ee778a4`: 6 files, +155 -104 (`synth/logs/proto-full.diff`, 452 lines), plus the three new files, 385 lines.
- The shipped round: the six patch scripts (about 150 lines each, as round 2's), `oclj_num53.h` (about 120 lines, moved out of `oclj_strpack.c`), build-native.sh (about +200), the fingerprint (about +60 across eris, tests, gradle), and the tests (§6, about 1500 lines, about half of them the `tests` investigator's driver).
- **Estimate: 3000-3500 changed lines, about round 2's size** [I].

---

## 4. Build and gates (`native/build-native.sh`)

| where | what |
|---|---|
| header, PREREQUISITES | "FIVE changes" becomes ELEVEN: the six bitop patches, and the three tracked files copied in |
| before `make clean` (after the strpack block, `:603-641`) | For each of `lj_parse.c`, `vm_x64.dasc`, `lj_meta.c`, `lj_record.c`, `lj_opt_fold.c`, `lj_bcdump.h`: assert that the pristine file has no `OC-LuaJIT (native/luajit/patch-bitop-` marker, re-copy it, assert the marker absent, patch, and assert the marker count. Copy `oclj_bitop.h`, `oclj_bitop_meta.c`, `oclj_bitop_rec.c` and `oclj_num53.h` in and `cmp` each. `vm_x64.dasc` MUST be re-copied: `make clean` regenerates `buildvm_arch.h` from whatever dasc is there (compat [M]) |
| after make | `lj_parse.o`, `lj_meta.o`, `lj_record.o`, `lj_opt_fold.o`, `lj_bcwrite.o` and `lj_bcread.o` are newer than their sources; `host/buildvm_arch.h` is newer than `vm_x64.dasc`, and `lj_vm.o` (Linux `lj_vm.S`) newer than it; the DynASM command line `-o host/buildvm_arch.h vm_x64.dasc` appears in the log (CRLF-tolerant); `buildvm_arch.h` carries the two echoed `OC-LuaJIT: Lua 5.3's` comment lines [M: 2 in the prototype]; no warning names a new file |
| `-dM` loop (`:716-723`) | adds `OCLJ_OPS_BIT64 1`. A second `-dM` of `lj_bcdump.h` must say `BCDUMP_VERSION 0x80` (compat [M] `logs/dM-bcdump.out`) |
| `-Wall -Wextra` gate | a generated TU includes LuaJIT's headers and `oclj_bitop_meta.c` and references `oclj_meta_bitop`, plus `oclj_bitop.h`: 0 warnings |
| luajit.exe gate (`bitops.lua`, no backslashes, like `strpack.lua`) | one exact line, with each field explained in the failure message: folded `1<<32`; runtime `o<<32`, `(-o)>>1`, `~0>>1`, `1<<64`; `1.5`/`"3"`/table errors by kind; `~>>`; `string.dump(...):byte(4) == 128`; `bit.lshift(1,32) == 1`; a hot loop computed with jit on, off, on (`hot=... abort=0`). Fail-first: today's luajit.exe prints the 32-bit values [M d5 probe, F2] |
| stage 4 OBS (`:1209`) | gains `(tonumber("1") << 32 == 4294967296) and "bit64" or "bit32"`, from **runtime** operands, because constants fold. OBS's case (`:1211`) gains `" bit"(32\|64)` |
| stage 4 WORD (`:1217`) | each alternative gains `.bit(32\|64)`. It fails today against a nine-token word (compat [M] `b3/logs/build-additive.log`) |

**Fail-firsts (to run when targets exist):**
- Today's luajit.exe against the new `bitops.lua`.
- An eris built from a header copy without the macro (`bit32`) against the round-3 luajit.exe.
- A header copy without `OCLJ_OPS_BIT64`, which must stop `oclj_bitop.h` at its `#error`.
- The `-Wall -Wextra` gate counting 1 on a copy with one unused variable.

---

## 5. The fingerprint

- **`serializer/eris_lj.c`:**
  - `ELJ_W_BIT` is `"bit64"` when `OCLJ_OPS_BIT64`, else `"bit32"`, appended as the ninth token (`:173-177`).
  - `#if defined(OCLJ_OPS_BIT64) && OCLJ_OPS_BIT64 && BCDUMP_VERSION < 0x80` gives `#error`. This is one-directional, so the negctl header copy without the macro still compiles.
  - The serializer hash moves (a new value, unknown until the target exists). The word becomes `ffi0.lua52.gc64.fr2.dn0.le.p64.pack1.bit64`; the shipped fingerprint grows by 6 bytes to about 79 (u8 limit 255).
- **`serializer/tests/fingerprint.lua`:**
  - Shape `...%.pack[01]%.bit[36][24]$`.
  - The pack pattern changes to `%.(pack[01])%.`, since it currently needs pack last (`:45`).
  - A new check: the bit token agrees with the archive's operators, at run time.
  - `FLIP` gains `bit64`/`bit32`; "nine tokens". Expected: 19 checks, from 18.
  - compat measured that today's file fails 3 checks against a nine-token word [M `r3/compat/xb/fingerprint-repo-on-tok.out`].
- **`serializer/tests/negctl-fingerprint.sh`:**
  - `nocompare` wants 9 token FAILs, 11 FAIL lines and exit 11.
  - New arm `bitword`: the header copy without `#define OCLJ_OPS_BIT64 1` must fail exactly the agreement check.
- **`build.gradle.kts` (`:140-162`):** compare the **whole** word `<hash>|ffi0.lua52.gc64.fr2.dn0.le.p64.pack1.bit64`, not a suffix, so the middle tokens are checked too. compat emulated: today's DLL is refused, a nine-token one accepted [M emulation].
- **Also changed by the bump, not the token:**
  - `security_test.c` fixtures at 0x80, plus FF12 (F16).
  - `serializer/tests/fixtures/forin-identity.blob` regenerated with `ELJ_MODE=diagblob`. Only the three version bytes change (F14). The commit must say so (`run-forin.sh:96-99`).
- `serializer/tests/bitop.lua` (from `synth/probes/ser_bitop.lua`, 6 checks; fail-first measured) and a `Makefile` line.

---

## 6. Tests and their fail-firsts

| Test | Lives in | Today's build (fail-first) | Sabotage that it catches | Prototype |
|---|---|---|---|---|
| matrix: 7440 runtime cases (`t_ops`), 45 literals (`t_fold`), 391 `~>>` (`t_sar`), error kinds, `bit`/`bit32` regressions; exact against `.expect`, JIT on and `-joff` | `run-bitop.sh` part 1; `test/native/bitop/` | 6744 lines differ [M] | shiftmask: 238 lines [M] | PASS [M, as reworded files] |
| provenance: PUC 5.3.6 reworded differs from `.expect` in exactly `deviations.txt`'s ids (LEX x6, `//`, `RESID-varinfo`) | part 2 | (judges the files) | -- | [M: exactly those] |
| shim path: results through `lua_tonumber`; `lua_tointeger` of a 2^40 result; the RAM cap; the count hook in a compiled bit loop | part 3, `bitop_test.c` | [I] | -- | hook: 240000 on both [M luajit.exe] |
| JIT consistency: `t_jit2` x 7 option sets, `t_rec` (2 seeds plus 2 `counts` seeds), `t_sar` | `run-bitop.sh` part 4, or `run-bitjit.sh` | `t_rec`: 141 and 125 of 400 [M] | negA, negB, the r3/vm prototype's `~>>` [M] | 0 [M] |
| differential fuzz (default 1 seed x 1000 cases; four controls; coverage gate) | `run-bitfuzz.sh` + `bitop/bitfuzz*.lua` | 11665 MISMATCH [M] | negB, shiftmask [M]; FOLDP, FOLDJ (r3/tests [M]); **not negA** [M] | PASS [M] |
| string readers agree | `coerce_agree.lua` in part 1 | 29 disagreements [M] | -- | 0 [M] |
| bytecode version | `security_test.c` FF9/FF10 (0x80), FF12 | FF9, FF10, FF12 fail [M] | `BCDUMP` arm [I] | 56/0 [M] |
| persistence | `serializer/tests/bitop.lua`; for-in fixture | 1 failure [M] | -- | 6/0 [M] |
| token | `fingerprint.lua`, `negctl-fingerprint.sh bitword` | 3 failures (compat [M]) | `bitword` [I] | [I] |
| in the sandbox | harness `d5-sandbox-bitwise` (probe `r3/tests/proto/d5-probe.lua`; operators inside `load()` strings so stock PUC 5.2 compiles the autorun) | `ok/0:1/-1:2147483648/0:2147483647/0:1073741825/0:1/0:1/1.5ok/strE/0:0` [M luajit.exe] | -- | `ok/1:0/-2147483648:0/2147483648:0/1073741824:0/0:0/0:1/noint/0:16/11:98566144` = PUC 5.3.6 [M]; stock wants `absent` |

**`negctl-bitop.sh`** follows the arms method of `negctl-pack.sh`, one line per arm at the fix's own site; the expected catcher is in brackets:
- `WRAP32-INTERP` [matrix, fuzz V]
- `WRAP32-FOLD` [matrix K, fuzz K]
- `SHIFTMASK` [matrix, fuzz; M]
- `NEGSHIFT` [matrix]
- `SARSHR` [`t_sar`]
- `ROUNDTRUNC` [fuzz controls' rule]
- `TIESAWAY` [fuzz: 280 ties per 16000]
- `NOINT-FOLD` (fold 1.5 & 1) [matrix K]
- `NOINT-JIT` (drop the EQ guard) [`t_jit2` guard-exit]
- `RANGE-HI` (2^63 accepted) [matrix, fuzz]
- `STRCOERCE` [matrix, `coerce_agree`]
- `ERROPERAND` [matrix]
- `NARROW` (= negA) [`t_rec`, `t_jit2`; M]
- `KFOLD64` (= negB) [fuzz U, `t_rec`; M]
- `SARCONST` (r3/vm's `~>>` constant) [`t_rec counts`, `t_sar`; M]
- `WIDTH55` (bound ≤ 55 instead of 54) [`t_rec` I]
- `BCDUMP` [FF12, the gate]
- `WORDTOKEN` [stage 4]
- `canon` must pass.

Arms marked M were measured as whole builds; the rest are [I]. Each arm rebuilds only the object it touches, then `luajit.exe`; `vm_x64.dasc` arms rebuild `lj_vm.o` through buildvm.

**Instrument notes [M].**
- Hot-trace counts vary between runs of one binary: `t_rec counts` seed 4 on r3/vm's prototype gave 4, then 3 divergences. LuaJIT randomises hotcount back-off, so gate on "nonzero" and "zero", never on a count.
- `t_ops`' `%.17g` output makes the rounding deviation invisible (a 5.3 integer prints as its nearest double). Only the fuzzer's REF/RAW pair sees U1.

---

## 7. Prototype results in one place (Windows unless named; `synth/logs/`)

- **Builds:** b1 additive and b1d dropin rc 0 (F11). Linux `luajit` from the same copy (`linux1/build.log`, no warnings).
- **Native suites:** F16.
- **Correctness:**
  - Matrix 7440/7440 (Windows, Linux).
  - Folding (F5).
  - Fuzz 640 000 tuples and Linux, 0 MISMATCH (F6).
  - JIT suites, 0 differences under 7 option sets, Linux identical (F7).
  - `~>>` 391 cases.
  - Readers agree (F12).
  - Persistence (F14).
  - Polyfill (U1).
- **Negatives:** F8.
- **Speed:** F10.
- **Size:** §3.7.

---

## 8. File ownership (when targets are written; 4 implementers, disjoint)

- **A, LuaJIT plumbing:**
  - NEW `native/luajit/oclj_bitop.h`, `oclj_bitop_meta.c`, `oclj_bitop_rec.c`, `oclj_num53.h`, and `patch-bitop-{parse,vm,meta,record,fold,bcdump}.sh`.
  - `oclj_strpack.c` (D4), `oclj_features.h`, `patch-features-include.sh` (comment), `native/build-native.sh`.
- **B, serializer and gradle:** `eris_lj.c`, `Makefile`, `README.md`; `tests/fingerprint.lua`, `tests/negctl-fingerprint.sh`; NEW `tests/bitop.lua`; `tests/fixtures/forin-identity.blob`; `build.gradle.kts`.
- **C, tests:**
  - NEW `test/native/run-bitop.sh`, `run-bitfuzz.sh`, `negctl-bitop.sh`, `bitop_test.c`.
  - NEW `test/native/bitop/` (matrix, fold, sar, rec, jit2, coerce, expects, `deviations.txt`, the fuzzer and comparator with F13's pattern).
  - `security_test.c` (F16).
- **D, harness and docs:** `OcljSmoke.scala` (d5), `OcljArch.scala`, `LuaJITStateFactory.java` comment, `README.md`, `NOTICE`, `docs/roadmap.md`.

---

## 9. What the main session runs

1. **Now:** put USER DECISIONS U1-U10 to the user. Every later step depends on the answers. A decision against a recommendation changes the places named under it.
2. **Then:** commission the targets from this design and `synth/proto/` (the hunks are `apply_r3.py`'s; recorder and rules are the three files), as round 2 did. Record into a fresh `bench/runs/<date>-bitop/`.
3. **Fail-first, before any rebuild** (round 2's natives in place):
   - the new `run-bitop.sh` (FAIL: matrix, readers, JIT `t_rec`);
   - `run-bitfuzz.sh` (exit 1, about 11665);
   - `run-security.sh` with the new fixtures (FF9, FF10, FF12);
   - `serializer/tests/bitop.lua` (1 failure);
   - the harness d5 (additive FAIL; stock `absent`).
4. **Builds:** Windows dropin then additive, and the WSL `.so`. Want the new gate lines; `GG=6376`; the word `...pack1.bit64`, which luajit.exe agrees with.
5. **Suites:**
   - Shim 57/0, security 56/0, mem 86/0, vgc 47/0, wd 35/0, penalty 6/0, race 2/0, run-pack 13/0.
   - `run-bitop.sh` 0, `run-bitfuzz.sh` 0, `negctl-bitop.sh` PASS.
   - Serializer `make test` (fingerprint 19, bitop, for-in exact on the regenerated fixture), and `make negctl` (four arms).
   - Harness: every arm gains one check.
   - gradle.
   - **Campaign** (nohup + Monitor): 50 seeds x 20000 fuzz cases (about 14 min; delete a passing seed's files only if the user agrees, since they total about 54 MB per 10 000 cases), and `t_rec` over 20 seeds in both modes.
6. **Afterwards:** a memory note; dev-world machines reboot once (serializer hash, token, bytecode version).

---

## 10. Docs (when targets are written)

- **README "Lua dialect":** a paragraph covering:
  - the operators compute Lua 5.3's 64-bit results;
  - the rules as decided (U1-U5, U8);
  - what must differ (rounding beyond 53 significant bits and its reuse at 2^63, literals (U9), no integer subtype, `%.14g` printing, double arithmetic between operators);
  - no bitwise metamethods;
  - the operators alone do not unblock MineOS, whose `Color.lua` 5.3 path needs `//` (row 147).
- **NOTICE:** LuaJIT's "Used in" adds `lj_parse.c`, `vm_x64.dasc`, `lj_meta.c`, `lj_record.c`, `lj_opt_fold.c` and `lj_bcdump.h`. The Lua 5.3.6 paragraph adds `luaV_shiftl`, `luaV_tointeger` and `luaG_tointerror`/`opinterror` texts, ported into `oclj_bitop*.{h,c}`. No new licence text.
- **docs/roadmap.md:**
  - Row 146: the operators are 64-bit, not 32.
  - Row 147: `//` remains MineOS's blocker.
  - Row 196: the `bit64` token, the bump, the measured matrix.
  - Row 206: the 32-bit sentence is resolved; found: today's JIT and interpreter disagree beyond ±2^51.
  - A new `[x]` row for round 3, and a row for the two JIT follow-ups (F10) and the `PROTO_BITOP` collision (F17).

---

## 11. Commit message draft (the user commits; adjust to the decisions)

```
Lua 5.3's bitwise operators with 64-bit results: & | ~ << >> and unary ~ follow Lua 5.3.6 on int64 and return the nearest double, in the parser's folding, the interpreter and the JIT; bytecode is version 0x80 and the blob fingerprint's word gains a bit64 token

Why: decided 2026-10-13.  Without FFI the operators computed 32-bit BitOp
results (1 << 32 was 1), and the JIT and the interpreter disagreed for
operands beyond 2^51.

- native/luajit/oclj_bitop.h: the rules, shared by folding, the C path and
  the recorder: an operand converts as 5.3.6's tointeger (an integral double
  in [-2^63, 2^63), or a numeric string by 5.3's reading); & | ~ wrap on
  int64; << >> are luaV_shiftl; the result is the nearest double (as
  string.unpack decided); ~>> is a 64-bit arithmetic shift.
- vm_x64.dasc: a 64-bit fast path with an exactness check; lj_meta.c ->
  oclj_bitop_meta.c: strings, out-of-range counts, and 5.3.6's errors
  ("number has no integer representation", "attempt to perform bitwise
  operation on").
- lj_record.c -> oclj_bitop_rec.c: int64 IR with guards; lj_opt_fold.c: the
  int64 bit folds without FFI, no narrowing of an int64 conversion, and a
  width fold that keeps masked loops at today's speed.
- lj_bcdump.h: BCDUMP_VERSION 0x80 (folded constants change meaning);
  security_test.c fixtures follow, and an upstream dump is refused (FF12);
  serializer/tests/fixtures/forin-identity.blob regenerated (its three
  version bytes only).
- Fingerprint: ...pack1.bit64; gradle checks the whole word.
- Tests: run-bitop.sh, run-bitfuzz.sh, negctl-bitop.sh, serializer
  tests/bitop.lua, harness d5-sandbox-bitwise.

Evidence: bench/runs/<date>-bitop/.  Saved dev-world machines reboot once.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ToCfjxVT2SZodwDPFEt6Js
```

---

## 12. Open risks and notes

1. **The width fold across PHIs** rests on §3.5's argument plus tests (F7, F8). It needs a reviewer, and `WIDTH55` must be shown caught.
2. **The fuzzer alone is not enough** (F8: negA escapes it, and it has no `~>>`). `t_rec`, `t_jit2` and `t_sar` must ship, and `negctl-bitop.sh` must hold each arm to the suite that catches it.
3. **A real JIT bug survived r3/vm's 20 adversarial loops** (F8). Treat the current JIT suites as a floor.
4. **Speed:** table CRC is 4.9x slower than today's JIT (still above PUC 5.3.6's speed). The follow-ups are unbuilt. Timings were taken with two `java.exe` processes running.
5. **Not run:** harness, gradle, `negative-control.sh`, a Linux `.so`, any game test. The token regime of F14 was measured by compat on its own prototype, not on this one.
6. **D4's factoring is unbuilt** (the prototype has two reader copies, measured equal).
7. **U1-A's silent cases** are real (U1). If the user picks U1-B, the fuzzer's REF rule and every `.expect` change, and the fast path gains a check.
8. **Results kept, never cleared:** `synth/fuzz/runs` holds 632 MB (Windows) and `runs-linux` 7.5 MB. Move them aside if space matters.
9. **Investigator open questions, closed or carried:**
   - `vm`: hex literals → U9; `~>>` → U8; metamethods → U7; per-operator rounding → U1 and "also to confirm"; BADTYPE aborts accepted (U3, U6); Linux `.so` → risk 5.
   - `semantics`: round/refuse → U1; 2^63 → U2; metamethods → U7; error shape → U5; `~>>` → U8; tree identities → F15; FNV-32 → "also to confirm" (an integer-subtype limit).
   - `compat`: token name → D10; version value → D8 (0x80; a `bc80` word token is not added, since `BCDUMP_VERSION` moves only with a feature that has its own token); metamethods → U7; JIT layout → D6/F11 (GG unchanged); security FF in build-native.sh → not added (row 190 stays open); Linux → risk 5.
   - `tests`: 2^63 → U2; error text → U5 (strict mode passes); LEX → U9; `~>>` → U8; metamethods → U7; the collision → F17; per-operator coverage gate → only if U6-C.

---

## Appendix: evidence index and prototype manifest

**Prototype** (`synth/proto/`, md5, first 12 hex digits):

| md5 | file |
|---|---|
| `8275c0133505` | `apply_r3.py` (variants full, nyi, nowidth, nophi, negA, negB) |
| `dc33c6fd5047` | `oclj_bitop.h` |
| `e888e216e4ee` | `oclj_bitop_meta.c` |
| `f2ddc6428e38` | `oclj_bitop_rec.c` |

**Builds:**
- `synth/b0` (today): luajit.exe `2e737b868794`, `libluajit.a` `cc275f7e5372`, DLL `473c68a09a77`.
- `synth/b1` (prototype): luajit.exe `0cd8b30da700`, `libluajit.a` `7f105c0badb9`, DLL `9240d59c6f9d`.
- `synth/linux1/lj/src/luajit`: `91fc958e6493`.
- Patched trees: `synth/lj-full`, `lj-negA`, `lj-negB`, `lj-nyi`, `lj-nophi`, `lj-shiftmask`.

**Probes** (`synth/probes/`):
- `t_rec.lua` `735a0063dd83` (new; the counts mode)
- `t_sar.lua` `4f6d1e9637e2`
- `coerce_agree.lua` `56f95cb37f34`
- `polyfill.lua` `3c177823694a`
- `ser_bitop.lua` `538d95b1f89e`
- `xb.lua` `1db5fbeb8a9d`
- `today_div.lua` `152ffa12b63f`
- `sar_minint.lua` `1fc26402f025`
- `checkhook_bit.lua` `3715fd04ef31`
- `clc.lua` `68b3c66b85d0`
- `reword.py`
- copies of r3/vm's `t_ops.lua` `20d788b189ee` and `t_jit2.lua` `c9db02adc5c1`

**Fuzzer copy** (`synth/fuzz/`): `bitfuzz.lua` `d7ca3e380c62` (F13's one-line change against r3/tests' `9433ee1e34b5`), `bitfuzz-cmp.lua` `038ef0dab068` and `run-bitfuzz.sh` `e99595485d76`, both unchanged.

**Security prototype:** `synth/sec/mksec.py` makes `synth/sec/security_test.c` (`98a2231fa678`).

**Logs** (`synth/logs/`):

| log | contents |
|---|---|
| `b*-build.log` | the builds |
| `suites-b1/` | native suites |
| `sec80-*.log` | the 0x80 fixtures |
| `ops/` | matrix, fold |
| `jit/` | `t_jit`, `t_jit2` |
| `rec/` | `t_rec` |
| `sar/` | `~>>` model |
| `fuzz*.log`, `linux/` | fuzz and Linux |
| `bench/` | speed |
| `polyfill/` | the OpenOS polyfill |
| `xb/`, `forin/`, `ser-b1-test2.log`, `ser_bitop-*.out` | persistence |
| `coerce-agree-*.out` | the two readers |
| `misc-b1.out` | misc |
| `proto-full.diff` | the prototype diff |
