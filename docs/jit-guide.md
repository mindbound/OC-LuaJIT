# JIT and DynASM work on OC-LuaJIT's LuaJIT

> **What this covers.** How to change what our LuaJIT fork's parser, interpreter and JIT compute, and how to prove the change: the pipeline as our code meets it, the IR and the fold engine, loop optimization, snapshots and exits, the x64 backend, DynASM in `vm_x64.dasc`, the build, recipes, invariants, pitfalls, verification and tools. Round 3 (Lua 5.3.6's 64-bit bitwise operators, commit `2dd5f05`) is the worked example throughout.
>
> **The pin.** LuaJIT 2.1 at upstream `1ee778a4` (`1ee778a4e37122d8ca7d5733c590a47dafd6b15c`), x64 only, GC64, no FFI, no DUALNUM, with our twelve changes ([section 1](#1-scope-and-the-pin)). Written 2026-10-17, at `2dd5f05`.
>
> **Citations.** LuaJIT internals are cited by **function name plus the pin**. A line number is only a hint, written `~:N`: "`simplify_conv_i64_num` (lj_opt_fold.c ~:1140)" means line 1140 of the pristine tree `prototype/watchdog/luajit/src` at `1ee778a4`. The pristine tree is CRLF, and the line numbers are the same with or without the CRs. Lines in the patched build copy are marked "build copy". "Roadmap row N" means line N of [docs/roadmap.md](roadmap.md) at `2dd5f05`.
>
> **Marks.** Every claim carries one: **[M]** measured (the run, probe or log is named), **[S]** read in source, **[I]** inferred. A claim with two marks rests on both.
>
> **Upkeep.** Every round that touches the JIT, the interpreter, the parser or the fold engine updates this guide in the same commit, and that round's review checks the guide against the code. When a function moves, update its hint; when a claim stops being true, fix it or mark it.
>
> **Next task.** The CRC32 follow-up (roadmap row 209) starts at [8.8](#88-where-the-crc32-follow-up-starts). Its prototypes change `lj_opt_fold.c` (and `oclj_bitop_fold.c` for the u8 score): read [1](#1-scope-and-the-pin), [3](#3-ir-and-the-fold-engine), [4](#4-loop-optimization-snapshots-exits-and-side-traces), [8.2](#82-writing-a-patch-script), [8.4](#84-adding-a-fold-rule-safely), [8.4a](#84a-emitting-instructions-or-a-guard-from-a-fold-rule), [8.8](#88-where-the-crc32-follow-up-starts), [9](#9-invariants-and-soundness-arguments) and [10](#10-pitfalls), then [11](#11-verification-discipline).

**Contents:** [Checklist](#agent-checklist) · [1 Scope](#1-scope-and-the-pin) · [2 Pipeline](#2-the-pipeline) · [3 IR and folds](#3-ir-and-the-fold-engine) · [4 Loops, snapshots, exits](#4-loop-optimization-snapshots-exits-and-side-traces) · [5 Backend](#5-the-backend) · [6 DynASM](#6-dynasm-in-practice) · [7 Build](#7-the-build) · [8 Recipes](#8-recipes) · [9 Invariants](#9-invariants-and-soundness-arguments) · [10 Pitfalls](#10-pitfalls) · [11 Verification](#11-verification-discipline) · [12 Tools](#12-tools) · [A Files](#appendix-a-file-map-where-each-round-3-piece-lives) · [B Glossary](#appendix-b-glossary) · [Open questions](#open-questions)

## Agent checklist

One page, in the order the work goes. Each item links to the section that explains it.

**Before you start**

1. Read [1](#1-scope-and-the-pin) (what is ours), [2](#2-the-pipeline) (where your change enters) and [10](#10-pitfalls) (what has already gone wrong). For a fold or recorder change, add [3](#3-ir-and-the-fold-engine), [4](#4-loop-optimization-snapshots-exits-and-side-traces) and [9](#9-invariants-and-soundness-arguments); for an interpreter change, [6](#6-dynasm-in-practice).
2. Know the pin: `1ee778a4`, x64, GC64, `LJ_HASFFI 0`, no DUALNUM. Grep any LuaJIT function you rely on for `LJ_HASFFI`, `LJ_DUALNUM` and `LJ_GC64` first: without FFI some of it is stubbed (P1).
3. Work in a fresh scratch copy of the build tree, never in `build/` ([7.4](#74-running-make-by-hand)); for the build gates and negctl, run build-native.sh with `OCLJ_BUILD` pointing at scratch ([7.6](#76-build-nativesh-stage-by-stage)). Never clear or reuse a results directory.
4. Write every script with a file tool. Patch scripts contain no backslashes and no tabs (P8). Repo files are LF; in Python use `newline=""`; count CRs by bytes (P7).

**While changing code**

5. Put each change in a patch script run on the build copy (extend the file's existing script if it has one), using round 3's hunk engine ([8.2](#82-writing-a-patch-script)). Put new code in an `oclj_*` file that the patched file `#include`s.
6. Put rules shared by the parser, the slow path and the recorder in one header, as `oclj_bitop.h` is, so the three cannot disagree ([9.9](#99-one-source-of-truth-for-every-c-path)).
7. **Interpreter:** store the result slot last; keep the registers each slow-path label needs, or reload them ([6.5](#65-what-a-handler-may-clobber), [6.7](#67-round-3s-checks-instruction-by-instruction)).
8. **Recorder:** check the runtime operands first and abort (`lj_trace_err`) on anything you will not compile; emit each guard right after the value it guards ([8.5](#85-adding-a-recorder-path), [8.6](#86-adding-a-guard), S1).
9. **Fold engine:** extend the function that owns a key; keep `LJFOLD` lines in `lj_opt_fold.c`; return existing refs; use `PHIBARRIER` before building on an operand's operand; across a PHI, return only a ref of the folded instruction's own type ([8.4](#84-adding-a-fold-rule-safely), S2-S5); to emit IR from a rule, [8.4a](#84a-emitting-instructions-or-a-guard-from-a-fold-rule).
10. **Backend:** check which CONV modes the backend can emit (only `int.num` may be guarded) before you design IR ([5](#5-the-backend)).
11. If the bytecode's meaning changes, bump `BCDUMP_VERSION` (0x81 is next) and the fingerprint token ([8.1](#81-adding-or-changing-an-operator-end-to-end)).

**Building**

12. Delete what make cannot see: the objects that `#include` your `oclj_*` file; for a `.dasc` edit, `host/buildvm_arch.h host/buildvm.o lj_vm.o lj_bc.o` ([7.4](#74-running-make-by-hand), P4, P14).
13. Pass `Q=` (empty), never `Q=.`; on Windows the binary is `mingw32-make` (P5, P45). Pass build-native.sh's `XCFLAGS`.
14. Compare object md5s, not `luajit.exe` (P13). Only the objects your change reaches may differ.
15. For a new file or script: add it to build-native.sh (re-copy, patch, marker assertions, freshness gates, a `luajit.exe` gate, [7.6](#76-build-nativesh-stage-by-stage)) and to negctl-bitop.sh's lists ([11.7](#117-negctl-one-line-sabotages)).

**Testing**

16. The interpreter is the oracle: JIT on against `-joff`, whole outputs, both directions, CR stripped ([11.1](#111-the-interpreter-is-the-oracle)).
17. Check the interpreter against PUC 5.3.6 through a twin generated from the same source ([11.2](#112-the-puc-twin)).
18. Run the generator and the floor suites under every option set (`-Ohotloop=1`, `-Omaxside=0`, `-Ohotloop=1 -Ohotexit=1`, `-O-loop`, and others) ([11.3](#113-option-sets), [11.4](#114-the-generator)).
19. Require coverage: `jit on`, and traces in at least a quarter of the loops. A run that compiled nothing proved nothing (P27).
20. Test chained idioms and boundary values the lexer can actually spell, not single operators (P16, P47, S7). For a speed change, also time the loops where its speculation fails ([11.12](#1112-measuring-speed)).

**Proving**

21. Run every new check against a case that must fail it before you trust a pass ([11.8](#118-fail-first)).
22. Give every fix site a one-line sabotage arm in a negctl script, caught at a named check ([11.7](#117-negctl-one-line-sabotages)).
23. When a reading surprises you, suspect the instrument first ([11.9](#119-instrument-first)).
24. Prove a crash fix only by a black-box census A/B plus build assertions; never write a test that forces a crash ([11.10](#1110-crash-fixes)).
25. Runs longer than a minute belong to the main session; never edit a script a running chain executes ([11.11](#1111-long-runs-and-results-directories), P17).

**Docs and upkeep**

26. Read IR with `-jdump=+rsT`, remembering its blind spots: KINT64 constants and the exact mark (P3, P30, [8.7](#87-reading-a--jdump)).
27. Archive evidence under `bench/runs/<date>-<name>/` with md5s, not binaries (P20). Mark every claim [M], [S] or [I].
28. Update this guide, the roadmap row and the patch list in [1](#1-scope-and-the-pin) in the same commit as the code.

## 1. Scope and the pin

### 1.1 What the fork is

- **Upstream.** LuaJIT 2.1 at `1ee778a4`, cloned by `make -C prototype/watchdog luajit-src` into `prototype/watchdog/luajit`, which is not tracked in this repo (build-native.sh PREREQUISITES) [S]. That checkout is the **pristine tree**: tracked sources only, CRLF on Windows (`core.autocrlf=true`). It also holds ignored build products from 2026-09-01, which are harmless because nothing builds there [M].
- **Our LuaJIT is a fork.** Since 2026-10-13 it may take Lua 5.3 additions (the decision is recorded in roadmap row 146; rounds 2 and 3 applied it) [S].
- **The configuration** is `native/luajit/oclj_features.h`, one header that the build copy's `lj_arch.h` includes [S]:
  - `LUAJIT_ENABLE_LUA52COMPAT` (OC's platform is Lua 5.2 source);
  - `LUAJIT_ENABLE_CHECKHOOK` (a compiled loop checks the hook mask, so the watchdog can stop it; see [docs/watchdog.md](watchdog.md));
  - `LUAJIT_DISABLE_FFI` (with FFI the lexer mints cdata from `1LL`);
  - an `#error` for every other option that changes a structure, the bytecode, the unwinder or what a gate measures, including `LUAJIT_NUMMODE` (so no DUALNUM) and `LUAJIT_NO_UNWIND`;
  - feature words for what we added: `OCLJ_LIB_STRPACK 1`, `OCLJ_OPS_BIT64 1`.
- **The preprocessor's verdict** (`gcc -E -dM lj_arch.h` on the build copy) [M]: `LJ_HASFFI 0`, `LJ_DUALNUM 0`, `LJ_GC64 1`, `LJ_FR2 1`, `LJ_HASJIT 1`, `LJ_52 1`, and on Windows `LJ_ABI_WIN 1` and `LJ_UNWIND_EXT 1`. What every build checks [S]: the `-dM` gate (build-native.sh ~:859) asserts `LJ_52`, `LJ_HASFFI`, `LJ_HASJIT` and `LJ_GC64` (and the OCLJ_* words); FR2 is held by stage 4's `fr2` token, which luajit.exe's dump flags must agree with; DUALNUM by `oclj_features.h`'s `#error` on `LUAJIT_NUMMODE` (the word's `dn0` is the serializer's compile-time view, not compared with luajit.exe); `LJ_ABI_WIN` and `LJ_UNWIND_EXT` are not gated.
- **Platforms.** x64 only: build-native.sh refuses any other machine, because the fast path is patched in `vm_x64.dasc` only [S]. Windows (MinGW-w64, PE/COFF, `buildvm -m peobj`) and Linux (ELF, `buildvm -m elfasm`) are both built and gated. macOS and aarch64 are parked as unsupported (roadmap) [S].
- **What reads LuaJIT internals besides LuaJIT.** `serializer/eris_lj.c`, `native/lj52shim.c`, and the C tests `penalty_test.c`, `race_test.c` and `wd_test.c` compile against the build copy's headers (`oclj_features.h` header) [S]. A change to a LuaJIT structure reaches them. build-native.sh stage 1b compares the archive's `GG_State` size (6376) with the one our headers describe [M] (logs).

### 1.2 Our twelve changes to LuaJIT

Each change is a script that patches one file of the build copy. build-native.sh re-copies the pristine file first, asserts the change is absent, runs the script, and asserts the script's marker is present the right number of times before make [S] ([7.6](#76-build-nativesh-stage-by-stage)).

| # | build-copy file | script (`native/luajit/`) | what it changes | commit |
|---|---|---|---|---|
| 1 | `lj_func.c` | `patch-penalty-scrub.sh` | `lj_func_freeproto` scrubs a dying prototype's loop heads from the trace-abort penalty cache, which is keyed by bytecode address | `83aeabd` |
| 2 | `lj_err.c` | `patch-fastfunc-errmem-top.sh` | `lj_err_mem` and `lj_err_err` never push their message below the current frame | `a4994e6` |
| 3 | `lj_ffrecord.c` | `patch-strfmt-xint-noffi.sh` | `recff_format` keeps `%x %X %o %u`, and `%d` with a flag or width, compiled without FFI | `5d782d7` |
| 4 | `lj_arch.h` | `patch-features-include.sh` | includes `oclj_features.h` right after `lua.h` | `5d782d7` |
| 5 | `lib_string.c` | `patch-strpack-register.sh` | registers `string.pack`, `string.packsize`, `string.unpack`; includes `oclj_strpack.c` | `c9ae4f9` |
| 6 | `lj_parse.c` | `patch-bitop-parse.sh` | `foldbitop` and the unary `~` fold use 5.3.6's rules (`oclj_bitop.h`) | `2dd5f05` |
| 7 | `vm_x64.dasc` | `patch-bitop-vm.sh` | `BC_BNOT` and `ins_bitop` compute on int64 and return only exact results; new label `->vmeta_bitop_pc` | `2dd5f05` |
| 8 | `lj_meta.c` | `patch-bitop-meta.sh` | `lj_meta_bitop`'s no-FFI tail calls `oclj_meta_bitop`; includes `oclj_bitop_meta.c` | `2dd5f05` |
| 9 | `lj_record.c` | `patch-bitop-record.sh` | the seven bit cases of `lj_record_ins` become one call of `oclj_rec_bitop`; includes `oclj_bitop.h` (after `lj_prng.h`) and `oclj_bitop_rec.c` (after the `emitir` macros) | `2dd5f05` |
| 10 | `lj_opt_fold.c` | `patch-bitop-fold.sh` | seven int64 folds compiled without FFI; `narrow_convert` leaves int64 alone; the exact-mark and width rules and fix1 in `simplify_conv_i64_num`; includes `oclj_bitop_fold.c` | `2dd5f05` |
| 11 | `lj_bcdump.h` | `patch-bitop-bcdump.sh` | `BCDUMP_VERSION` becomes 0x80 | `2dd5f05` |
| 12 | `lib_jit.c` | `patch-bitop-jitlib.sh` | `jit.util.funcbc` and `tracesnap` return unsigned numbers, so LuaJIT's own `jit/*.lua` decode exactly under 64-bit `>>` | `2dd5f05` |

[S] native/build-native.sh header and each script's header; commits from `git log --diff-filter=A`.

### 1.3 Our files in the build copy

build-native.sh copies these next to LuaJIT's sources, compares each with `cmp`, and refuses a pristine tree that already holds one [S].

| file | included by | what it holds |
|---|---|---|
| `oclj_features.h` | `lj_arch.h` (change 4), so every LuaJIT object, buildvm, the Makefile's DynASM flag probe, and our C | the feature set and its `#error`s |
| `oclj_num53.h` | `oclj_strpack.c`, `oclj_bitop.h` | Lua 5.3.6's readers: `luaO_str2num` for strings, `luaV_tointeger` mode 0 for floats (`oclj_flt2int`) |
| `oclj_strpack.c` | `lib_string.c` (change 5) | 5.3.6's pack/unpack, ported |
| `oclj_bitop.h` | `lj_parse.c`, `lj_record.c` and `lj_opt_fold.c` (each by its patch script), and `oclj_bitop_meta.c` | the operator rules with no Lua state: `oclj_bitop64`, `oclj_bit2num`, the shift rules, `OCLJ_IRCONV_EXACT` |
| `oclj_bitop_meta.c` | `lj_meta.c`, directly above `lj_meta_bitop` | the slow path: `oclj_meta_bitop`, its three errors |
| `oclj_bitop_rec.c` | `lj_record.c`, after the `emitir` macros | the recorder: `oclj_rec_bitop` |
| `oclj_bitop_fold.c` | `lj_opt_fold.c`, directly above `simplify_conv_i64_num` | `oclj_bitwidth`, the width rule's bound (no LJFOLD lines: P14) |

### 1.4 Out of scope

- Sandbox and security analysis: not here.
- The C API shim, the serializer's protocol and the watchdog's design: `native/lj52shim.c`, [serializer/README.md](../serializer/README.md), [docs/watchdog.md](watchdog.md).
- The bitwise metamethods and `//` (roadmap row 210) and the CRC32 follow-up (row 209) are future rounds. This guide records what they will need ([8.8](#88-where-the-crc32-follow-up-starts)).

## 2. The pipeline

One operator, from source text to machine code and back again, with round 3's bitwise operators as the running example. Our code is cited by path and function name. Every [M] in this section comes from a single-process run of the built `build/native/luajit-windows-x86_64/src/luajit.exe`, run from that directory so that `jit.*` loads. For the probes behind `guide1`, `side1` and `side2`, compiled code, `-joff` and PUC 5.3.6 gave the same output; for `exit1` and `abort2`, compiled code and `-joff` did (PUC computes their integers exactly and raises nothing) [M]. `guide1.lua` is printed in [8.7](#87-reading-a--jdump) and `crcprobe.lua` in [8.8](#88-where-the-crc32-follow-up-starts); the other four are kept here, line for line, so a review can re-run them and the cited line numbers hold.

`side1.lua`, a branch that switches at i = 500 ([4.6](#46-closing-a-trace-and-linking-it), [4.8](#48-side-traces)); prints 2000:

```lua
local s = 0
for i = 1, 1000 do
  local x = i * 3
  if i > 500 then x = x & 0xFF else x = x | 1 end
  s = s ~ x
end
print(s)
```

`side2.lua` ([4.6](#46-closing-a-trace-and-linking-it), [4.8](#48-side-traces)); prints 1002000:

```lua
-- The shift count is a variable from a table: 3 for i <= 500, 64 after.
local cnt = {}
for i = 1, 1000 do cnt[i] = i > 500 and 64 or 3 end
local s = 0
for i = 1, 1000 do
  s = s + (i << cnt[i])
end
print(s)
```

`exit1.lua` ([4.7](#47-exits)):

```lua
-- x is positive until i = 80; at i = 81, x = -1 and x >> 1 has 63 significant bits.
local s = 0
local ok, err = pcall(function()
  for i = 1, 100 do
    local x = 80 - i
    s = s + (x >> 1)
  end
end)
print(s, ok, err)
```

`abort2.lua` ([2.6](#26-the-recorder)):

```lua
-- The result is inexact in the iteration being recorded: the recorder aborts,
-- then the interpreter raises.
local s = 0
print(pcall(function()
  for i = 1, 100 do
    local x = 1 - i
    s = s + (x >> 1)
  end
end))
```

### 2.1 The map

| stage | LuaJIT entry (1ee778a4) | takes | gives | round 3's hook |
|---|---|---|---|---|
| lex | `lj_lex.c` `lex_scan` (~:297; the operator cases ~:365-379) | characters | `TK_shl` `TK_shr` `TK_sar`, `'&' '\|' '~'`; numerals as doubles | none [S] |
| parse | `lj_parse.c` `expr_binop` (~:2340) → `bcemit_binop` (~:950) → `foldbitop` (~:818) or `bcemit_arith` (~:838); `expr_unop` (~:2319) → `bcemit_unop` (~:996) | `ExpDesc` operands | a folded constant, or `BC_BAND+(opr-OPR_BAND)` | `patch-bitop-parse.sh` [S] |
| dump/load | `lj_bcwrite.c` `bcwrite_header` (~:388), `lj_bcread.c` `bcread_header` (~:394) | a prototype | version byte, flags | `patch-bitop-bcdump.sh`: `BCDUMP_VERSION` 0x80 [S] |
| interpret | `vm_x64.dasc` `BC_BNOT` (~:3522), `ins_bitop` (~:3544) | the instruction word | a slot value, or a jump to `->vmeta_*` | `patch-bitop-vm.sh` [S] |
| slow path | `lj_meta.c` `lj_meta_bitop` (~:243) | `L, ra, rb, rc, op` | a result, or an error | `patch-bitop-meta.sh` → `oclj_meta_bitop` [S] |
| hot count | `vm_x64.dasc` `hotloop` macro (~:332) → `->vm_hotloop` (~:2323) → `lj_trace.c` `lj_trace_hot` (~:781) | a back-edge | recording begins | none (`patch-penalty-scrub.sh` touches the penalty cache) [S] |
| record | `lj_record.c` `lj_record_ins` (~:2227) | one bytecode plus the runtime operand values | IR through `emitir` | `patch-bitop-record.sh` → `oclj_rec_bitop` [S] |
| fold/CSE | `lj_opt_fold.c` `lj_opt_fold` (~:2524), `lj_opt_cse` (~:2601) | one instruction (`fins`) | a ref | `patch-bitop-fold.sh` ([3](#3-ir-and-the-fold-engine)) [S] |
| loop | `lj_opt_loop.c` `loop_unroll` (~:265) | the pre-roll | `LOOP`, a copy of the body, PHIs | none [S] |
| assemble | `lj_asm.c` `lj_asm_trace` (~:2471); `lj_asm_x86.h` `asm_conv` (~:857), `asm_guardcc` (~:75) | IR and snapshots | x64 code and exit stubs | none [S] |
| exit | `->vm_exit_handler` (~:2449) → `lj_trace.c` `lj_trace_exit` (~:886) → `lj_snap.c` `lj_snap_restore` (~:940) → `->vm_exit_interp` (~:2499) | the machine state | the interpreter state at the snapshot's pc | none [S] |
| side trace | `lj_trace.c` `trace_hotside` (~:799) → `lj_record.c` `lj_record_setup` (~:2863) → `lj_snap.c` `lj_snap_replay` (~:508) | the parent's snapshot | a new trace | none [S] |

### 2.2 Lexer and parser

- **Lexing.** `lex_scan` returns `TK_shl` for `<<`, `TK_shr` for `>>` and `TK_sar` for `~>>`. `&`, `|` and `~` are one-character tokens, and `~=` is `TK_ne` [S]. The lexer turns a numeral into a double before any operator sees it. A hex literal with more than 53 significant bits is therefore already rounded (U9): `0x00ff00ff00ff00ff & 0xff` is 0 here, and `0x7fffffffffffffff | 0` raises `number has no integer representation`, because that literal is 2^63 [M] (P47).
- **Precedence.** `token2binop` (~:2269) and `priority[]` (~:2302) rank BOR 4 < BXOR 5 < BAND 6 < the shifts 7 < CONCAT 9 < ADD 10 < unary 12. These are Lua 5.3's ranks [S].
- **Emission.** `expr_binop` parses the left side through `expr_unop`. While the next operator's left priority beats the limit, it calls `bcemit_binop_left`, parses the right side at the operator's right priority, and calls `bcemit_binop` [S].
  - For a bit operator, `bcemit_binop_left` leaves a numeric-constant left operand undischarged (`if (!expr_isnumk_nojump(e)) expr_toanyreg(fs, e)`), so the operator can still fold [S].
  - `bcemit_binop` sends OPR_BAND..OPR_BSAR to `foldbitop`. If that fails, it sets `PROTO_BITOP` (~:956) and calls `bcemit_arith`, which puts both operands in registers and emits `BC_BAND+(opr-OPR_BAND)` [S].
  - The unary path is `expr_unop` → `bcemit_unop`. Its `~` fold is at ~:1050-1054 and its `PROTO_BITOP` at ~:1056 [S].
- **Round 3's change** (`patch-bitop-parse.sh`). `foldbitop` and the `~` fold read each constant with `oclj_flt2int` (5.3.6's `luaV_tointeger`, mode 0), compute with `oclj_bitop64` and accept the result only through `oclj_bit2num`. They store it with `setnumV` where upstream used `setintV`. `expr_bitV` (~:89), BitOp's 32-bit reader, is gone. `oclj_bitop64` is also what the C slow path and the recorder call, so the three cannot disagree [S].
- **A second route to the same emitter: compound assignment.** The pin's backported compound assignments `&= |= ~= <<= >>= ~>>=` (doc/extensions.html ~:425) go through `parse_compound` (lj_parse.c ~:2410). It puts the variable in a register and calls `bcemit_binop`, so they emit the same `BC_BAND..BC_BSAR` (never folded, since one operand is a register) and set `PROTO_BITOP`; round 3's semantics apply unchanged [S]. As a statement, `x ~= y` is xor-assignment (`OPR_NE` becomes `OPR_BXOR`). `&&` and `||` lex as the logical `TK_and_` and `TK_or_` (lj_lex.c ~:393-398), never as two bit operators [S]. Measured: `local x = 1; x <<= 40; local y = 5; y ~= 3; local z = 6; z &= 3; print(x, y, z)` prints `1099511627776 6 2`, `-bl` lists `BSHL 0 0 1` and `BXOR 1 1 2`, and `local x = -1; x >>= 1` raises the 53-bit error [M]. PUC 5.3 has none of these forms, so neither the twin nor the generator nor the fuzzer covers them (no file in `test/native/bitop/` uses one); a round that changes the parser tests them by hand (Open questions).
- **When the parser declines to fold** [S]:
  1. an operand is not a numeric constant without pending jumps (`expr_isnumk_nojump`), for example a local;
  2. an operand has no integer representation (`1.5 | 0`);
  3. the result has more than 53 significant bits (`-1 >> 1` is 2^63 - 1).

  Cases 2 and 3 leave the operator to run time, which raises, the way 5.3.6's `lcode.c` `validop` leaves invalid operands to run time (`lcode.c:960-971`) [S]. `luajit -bl` shows all three [M]:

```
local r1 = 1 << 40   ->  0002  KNUM     2   0      ; 1099511627776
local r2 = ~0        ->  0003  KSHORT   3  -1
local r3 = 1.5 | 0   ->  0004  KSHORT   4   0
                         0005  KNUM     5   1      ; 1.5
                         0006  BOR      4   5   4
local r4 = -1 >> 1   ->  0007  KSHORT   5   1
                         0008  KSHORT   6  -1
                         0009  BSHR     5   6   5
local r5 = a & b     ->  0010  BAND     6   0   1
local r6 = ~a        ->  0011  BNOT     7   0
local r7 = a ~>> 3   ->  0012  KSHORT   8   3
                         0013  BSAR     8   0   8
```

- **`PROTO_BITOP` collides with the closure counter** (an upstream bug, roadmap row 212, P32). `PROTO_BITOP` is 0x80 (`lj_obj.h` ~:404), inside the 3-bit closure counter at 0x20..0xe0 (~:409-411), so `flags >= PROTO_CLC_POLY` (`lj_record.c` ~:802, and `rec_upvalue` ~:1795) is true in every function that uses a bit operator [S]. In such a function an immutable upvalue is never constified: a loop reading upvalue `K = 7` compiles `ADD … +7`, and the same loop in a function that also contains `n & 1` compiles `UREFO` plus `ULOAD` [M] (an open upvalue; round 3's design work saw `UREFC` for a closed one, roadmap row 212). Speed only; not fixed in our fork [S].

### 2.3 Bytecode and the dump version

- **Formats.** `lj_bc.h` `BCDEF` (~:189-196) defines `BNOT` as dst/___/var (AD: A = destination, D = source slot) and `BAND`..`BSAR` as dst/var/var (ABC). The metamethod column is `___` [S].
- **No constant forms.** Unlike `ADDVN` and `ADDNV`, both operands of a bit opcode are registers, so a literal operand is first put in a register by `KSHORT` or `KNUM` (`0008 KSHORT 6 -1; 0009 BSHR 5 6 5` above) [S][M].
- **ORDER OPR / ORDER BIT.** `OPR_BAND..OPR_BSAR` and `BC_BAND..BC_BSAR` run in the same order. The parser relies on that (`opr-OPR_BAND+BC_BAND`), and so does `oclj_bitop64`, which switches on `BC_*` numbers [S]. The IR order differs: `IR_BSWAP` sits between `IR_BNOT` and `IR_BAND` (`lj_ir.h` ~:56-66), so `oclj_rec_bitop` maps bytecode to IR by arithmetic only for BAND..BXOR and names the IR op of BNOT and of each shift explicitly [S] (P42).
- **Same bytecode, new meaning: the dump version.** `bcwrite_header` writes `BCDUMP_VERSION` (~:397) and sets `BCDUMP_F_BITOP` only when `pt->flags` has `PROTO_BITOP` (~:401). `bcread_header` refuses any other version (~:400) [S]. Measured [M]:

| case | header bytes |
|---|---|
| dump of a function containing `a & 1` | `27 76 74 128` and flags 0x18 (FR2 \| BITOP) |
| dump of a function containing `1 << 3` | flags 0x08: the expression folded away, no bit opcode is left, so `BCDUMP_F_BITOP` cannot carry the version |
| the version byte set back to 2 | `load` fails with `cannot load incompatible bytecode` |

  The blob fingerprint gains `bit64` from `oclj_features.h`'s `OCLJ_OPS_BIT64`, and `serializer/eris_lj.c` refuses to compile if that word is on while `BCDUMP_VERSION` is below 0x80 [S].

### 2.4 The interpreter

- **Decode.** `ins_NEXT` loads the instruction word, sets RA = A and OP = the opcode, leaves RC (= RD) holding the upper 16 bits, and jumps through `[DISPATCH+OP*8]` (`vm_x64.dasc` ~:212) [S]. `ins_bitop` swaps registers: "RB = dst, RC = src1, RA = src2". The register table and the macros are in [6](#6-dynasm-in-practice) [S].
- **The fast path.** `patch-bitop-vm.sh` changes only the non-DUALNUM half of `BC_BNOT` and of `ins_bitop` [S]:

| step | instructions | goes to C when |
|---|---|---|
| type | `checknumtp [BASE+R*8]` | an operand is not a number |
| operand → int64 | `cvttsd2si`, `cvtsi2sd`, `ucomisd`, `jne`, `jp` | the double is not integral; or it is outside [-2^63, 2^63), where `cvttsd2si` gives INT64_MIN, whose round trip differs; or it is NaN (unordered, so PF is set) |
| shift count | `cmp RA, 63`, `ja` (unsigned) | the count is < 0 or > 63; 5.3.6's `luaV_shiftl` runs in C |
| operation | 64-bit `not`/`and`/`or`/`xor`/`shl`/`shr`/`sar`, count in `cl` | — |
| result | `cvtsi2sd`, `cvttsd2si` back, `cmp`, `jne` | the result has more than 53 significant bits, or rounded to 2^63 |
| store | `movsd [BASE+dst*8]`, `ins_next` | — |

  [S] The instruction-level listing and which registers survive each exit are in [6.7](#67-round-3s-checks-instruction-by-instruction).
- **Into C.** `->vmeta_bitop` (~:1105) calls `lj_meta_bitop(L, ra, rb, rc, op)`: on Win64 the first four arguments go in rcx, rdx, r8 and r9 and `op` in the stack slot `ARG5`; on SysV all five go in registers. It stores `L->base` and `SAVE_PC` (which gives the error its line), calls, reloads BASE and continues at `->cont_nop` [S]. For `BNOT`, `->vmeta_bnot` passes the operand as both `rb` and `rc` [S].
- **The slow path.** `lj_meta_bitop`'s no-FFI tail calls `oclj_meta_bitop` (`native/luajit/oclj_bitop_meta.c`). `ob_toint` converts each operand, reading a string through 5.3.6's readers in `oclj_num53.h`. The result is `oclj_bitop64` passed through `oclj_bit2num`; if either step fails, one of three errors is raised [S]:

| case | raiser | message [M] |
|---|---|---|
| result has more than 53 bits | `ob_err_inexact` | `result of '>>' has more than 53 significant bits (mask each operand to 32 bits first)` |
| numbers or numeric strings, one with no integer value | `ob_err_noint` | `number (local 'x') has no integer representation` |
| any other type | `ob_err_type` | `attempt to perform bitwise operation on local 't' (a table value)` |

  All three raise through `ob_errv`, a copy of `lj_err.c` `err_msgv` (~:931): it restores `L->base` from `jit_base` if set, sets `L->top = curr_topL`, then calls `lj_strfmt_pushvf`, `lj_debug_addloc` and `lj_err_run` (~:887). It is a copy so that `lj_err.c` (already patched by change 2) and `lj_errmsg.h` stay unchanged [S]. Measured: `"3" & 1` is 1, `1 << 64` is 0, `256 >> -4` is 4096 [M].

### 2.5 Hot counting and trace start

- **The counter.** `BC_FORL`, `BC_ITERL`, `BC_ITERN` and `BC_LOOP` run the `hotloop` macro (vm_x64.dasc ~:4558, ~:4709, ~:4308, ~:4739). It computes `(PC>>1) & HOTCOUNT_PCMASK`, a byte offset that selects one of 64 16-bit counters (`HOTCOUNT_SIZE`, `lj_dispatch.h` ~:75; `hotcount_get` ~:126 indexes `(pc>>2) & 63`), and subtracts `HOTCOUNT_LOOP` = 2. On a borrow (`jb`) it jumps to `->vm_hotloop`. Function headers subtract `HOTCOUNT_CALL` = 1 [S].
- **The start value is fixed.** `lj_dispatch_init_hotcount` (~:86) starts every counter at `hotloop*HOTCOUNT_LOOP - 1` = 111 [S]. `->vm_hotloop` calls `lj_trace_hot`, which resets the counter to `hotloop*2` and, if the JIT is idle, sets `LJ_TRACE_START` and calls `lj_trace_ins` → `trace_state` → `trace_start` → `lj_record_setup` [S].
- **Measured** (a `jit.attach` "trace" counter, one loop, fresh state): recording begins after back-edge 56 by default, in 6 of 6 processes; after 1 with `-Ohotloop=1`; after 10 with `-Ohotloop=10` [M].
- **Why "compiles after N iterations" is only approximate** (P6) [S]:
  - counters are hashed by pc, so loops and functions whose pcs collide share one, and calls decrement it too;
  - an abort sets the counter to a penalty value with random bits (below);
  - up-recursion sets a random count (`lj_record.c` ~:1896);
  - the PRNG is seeded per state by `lj_prng_seed_secure` (`lj_state.c` ~:257).

  The tests therefore use option sets and coverage gates, never exact counts ([11.3](#113-option-sets)).
- **Penalties and blacklisting.** `trace_abort` (~:585) calls `penalty_pc` (~:392) for an aborted root trace. `penalty_pc` keys a 64-slot cache by bytecode address. A new slot gets `PENALTY_MIN` = 72; a repeat gets twice the old value plus 4 random bits. Above `PENALTY_MAX` = 60000, `blacklist_pc` (~:380) patches `FORL` to `IFORL`, and the loop is never counted again (`lj_jit.h` ~:309-312) [S].
  - A root trace that always aborts is therefore attempted exactly 11 times, since 72·2^10 > 60000 [S]. A loop aborting on a variable shift count of 64 printed 11 `-jv` aborts in each of three runs, then nothing; an FNEW-aborting loop did the same in 6 of 6 processes, its 11th abort coming between iterations 38,215 and 42,958 [M].
  - **`-jv` prints no line for the blacklisting itself**: `blacklist_pc` sends no vmevent [S][M]. A later `-- blacklisted at <file>:<line>` line is a different event: another recording that reached the patched `IFORL` aborted with `LJ_TRERR_BLACKL` (P39).
  - Change 1 makes `lj_func_freeproto` scrub a dying prototype's slots, because the cache is keyed by address and a reused address would inherit them [S].
- **The recorder runs before the interpreter.** While the JIT is not idle, the dispatch table routes every instruction through `lj_dispatch_ins` (~:411), which calls `lj_trace_ins(J, pc-1)` before the instruction executes [S]. So the recorder sees exactly the operand values the interpreter is about to use. That is what lets `oclj_rec_bitop` test whether this iteration's result is inexact [S].

### 2.6 The recorder

**How `lj_record_ins` sees an instruction** (~:2227) [S]:

- If `J->needsnap` is set, it first takes a snapshot (~:2283-2288; [4.3](#43-snapshots)).
- It decodes operands by `bcmode` (~:2312-2346). A `var` operand is copied into `rbv`/`rcv` (the runtime values, `copyTV`), and its TRef comes from `getslot`: `J->base[s]` if set, otherwise `sload` (~:201), which emits `SLOAD` typed by the runtime value, with `IRSLOAD_TYPECHECK` and a guard (`T` in a dump).
- For `BNOT`, mode B is none, so `rb` = 0 and `rc` = D.
- After the switch, a dst-mode op stores its result: `J->base[ra] = rc` (~:2774).

Round 3 replaces the seven cases (~:2511-2546) with one line, `rc = oclj_rec_bitop(J, op, rb, rc, rbv, rcv)`, and includes `oclj_bitop_rec.c` right after the `emitir` macros (~:43-46) [S].

**`oclj_rec_bitop`, step by step** (`native/luajit/oclj_bitop_rec.c`) [S]:

1. **The record-time check.** `oclj_rec_bitval` reads each runtime operand with `oclj_flt2int`, then `oclj_bitop64` computes and `oclj_bit2num` checks. Any failure calls `lj_trace_err(J, LJ_TRERR_BADTYPE)`. A string operand, an operand with no integer value, or an inexact result aborts here, before any IR is emitted.
2. **The operands**, through `oclj_rec_bitarg`:

   | operand TRef | IR emitted | guard |
   |---|---|---|
   | int-typed (`tref_isinteger`, I8..INT: a narrowed value such as the FORL index, or `string.byte`'s `u8 XLOAD`) | `CONV i64.int sext`; on x64 `simplify_conv_sext` (`lj_opt_fold.c` ~:1221) folds it back to the operand itself when SCEV proves the index ≥ 0, and always for a u8/u16 XLOAD (~:1229) | none |
   | constant | `lj_ir_kint64(k)` | none: checked at record time |
   | any other number `x` | `i = CONV i64.num x` (`IRCONV_ANY`); `back = CONV num.i64 i`, **marked**; `EQ.num back, x` | the `EQ`: an exit if `x` is not integral, is out of range, or is NaN |

3. **The shift count.** A constant count is decided now by 5.3.6's rule: `BSHL` or `BSHR` by a `KINT`, or `KINT64 0` when the count's absolute value is 64 or more. `~>>` is handled case by case (`BSAR` by 63 for a count of 64 or more, `BSHL` for a negative count). A variable count must be in [0, 63] at record time, or the trace aborts; it becomes `CONV int.num check` (unless it is already an int), then a guard `ULT cnt, 64`, then the i64 shift by `cnt`.
4. **The operation.** `IR_BNOT`, `IR_BAND+(op-BC_BAND)`, or the named shift, all typed `IRT_I64`.
5. **The result.** `d = CONV num.i64 res`, **marked**. Unless `res` is a constant, the guard follows at once: `back = CONV i64.num d` (`IRCONV_ANY`, **marked**: here the mark means "this is the guard's own check"), then `EQ.i64 back, res`. The function returns `d`, so the slot holds the double and snapshots name the double.

**What FOLD does with that IR** ([3.10](#310-the-two-rules)) [S]: `simplify_conv_i64_num` folds `(i64)(num)y` to `y` by the **exact-mark rule** (the inner CONV is marked and the outer one is not) or the **width rule** (`oclj_bitwidth(y)` ≤ 54). When the next operator converts `d`, it therefore gets `res` back: `back` commons with `d` (`cse_conv` ~:1287), and `EQ.num d, d` disappears through `comm_equal` (~:1978), whose comment says converted integers cannot be NaN. The guard's own check is marked, so only the width rule can remove it. Measured widths [M]:

| expression | bound | result guard |
|---|---|---|
| `i << 21` (i the FORL index) | 33 + 21 = 54 | none |
| `i << 22` | 55 | kept |
| `x >> 3` | 65 - 3 = 62 | kept |
| `… & 0xFFFF` | 17 | none |

The loop index scores 33, not 32, because `simplify_conv_sext` removed its sign extension and an int value scores 33 in `oclj_bitwidth` [M][S] (P41).

**Record-time aborts.** `lj_trace_err` (~:38) pushes the `TraceError` number and throws `LUA_ERRRUN`. `lj_vm_cpcall` in `lj_trace_ins` catches it, the state becomes `LJ_TRACE_ERR`, and `trace_abort` runs [S]. Under `-Ohotloop=1`, `abort2.lua` (printed in [2](#2-the-pipeline)), whose first recorded iteration (its second) is inexact, printed `[TRACE --- abort2.lua:5 -- bad argument type at abort2.lua:7]`, then the interpreter raised the 53-bit error [M]. A loop that is inexact in iteration 1 raises in the interpreter before any back-edge, so no trace starts and no abort line is printed [M].

- The inexact-result abort is defensive. Without it, the interpreter raises right after the recorder returns, `lj_err_throw` calls `lj_trace_abort` (`lj_err.c` ~:771, `lj_trace.h` ~:45), and the trace is aborted as `LJ_TRERR_RECERR` instead [S].
- `negctl-bitop.sh` measured the same raises, 26 starts and 26 aborts, with the check and without it. That is why INEXACT-RECABORT is not one of its arms [M] (its header; [11.7](#117-negctl-one-line-sabotages)).

## 3. IR and the fold engine

The SSA IR that traces are recorded into, and the fold/CSE engine that every instruction passes through. IR and machine-code excerpts marked [M] come from the round-3 build (`luajit.exe` md5 `df3664c5`, at `2dd5f05`), run with `-jdump`; each names the Lua loop that produced it. In the build copy, the patched files are shifted against the pristine line hints.

### 3.1 The instruction: `IRIns`

```
     16      16     8   8   8   8
 +-------+-------+---+---+---+---+
 |  op1  |  op2  | t | o | r | s |   r/s (register, spill slot) overlap prev,
 +-------+-------+---+---+---+---+   the CSE chain link, until the backend runs
 |  TValue: 2nd slot of KNUM, KINT64 (and GC64 KGC/KPTR/KKPTR) |
```

[S] lj_ir.h `IRIns`, ~:556.

- **`o` is an `IROp` from `IRDEF` (~:14), and the order matters.** Comparison pairs flip with `^1`; `LT^4` is `ULT`. The bit ops `BNOT..BROR` are contiguous ("ORDER BIT"), and so are the loads and stores. Static asserts at ~:163-176 check this [S].
- **`lj_ir_mode[o]` gives each opcode a kind**: `N` (pure, can be CSE'd), `R` (reference), `L` (load), `S` (store), `A` (allocation); on top of that, `C` means commutative and `W` a weak guard [S].
- **`ir_sideeff` (~:600) decides what DCE must keep**: a store, or any op with a non-weak guard. That is why DCE keeps every guard: `EQ` is not weak. The overflow guards of `ADDOV` and friends are weak, so DCE may drop them [S].

### 3.2 Types and flag bits

[S] `IRTDEF` (~:320) numbers the types; these are the ones round 3 touches:

| type | # | role |
|---|---|---|
| `IRT_NUM` | 14 | every Lua number held in a slot (no DUALNUM) |
| `IRT_U8` | 16 | `string.byte`'s `u8 XLOAD` (lj_ffrecord.c ~:911, ~:944). After `simplify_conv_sext`'s u8/u16 LEFTFOLD it is the int64 op's operand itself, and `oclj_bitwidth` scores it 64 ([3.11](#311-oclj_bitwidth-the-bound)) [S][M] |
| `IRT_INT` | 19 | narrowed values: the loop index, `#t` |
| `IRT_U32` | 20 | |
| `IRT_I64` | 21 | round 3's operator values |

The numbers follow from the `IRTDEF` order and match the measured CONV op2 values below [S][M].

- `irt_isinteger` (~:389) means I8..INT. U32 and I64 do not count as "integer" to it, and that decides `loop_unroll`'s type check ([4.4](#44-type-instability-typeins-retry-blacklist)) [S].
- `irt_is64` (~:409) is true for NUM, I64, U64 and P64, and for the GC reference types under GC64 [S].

The high bits of the type byte are flags (~:344):

| flag | bit | meaning |
|---|---|---|
| `IRT_MARK` | 0x20 | Scratch mark for DCE and `loop_emit_phi`'s passes. It is not round 3's exact mark, which is bit 0x400 of a CONV's op2 [S]. |
| `IRT_ISPHI` | 0x40 | The instruction is a PHI operand. Only lj_opt_loop.c sets it (and SPLIT, on 32-bit targets only) [S, grep `irt_setphi`], so `PHIBARRIER` matters only inside `loop_unroll` [I]. It also raises the register priority of PHI values (lj_target.h `REGCOST_PHI_WEIGHT`) [S]. |
| `IRT_GUARD` | 0x80 | The instruction is a guard: if it fails, the trace leaves through the snapshot in effect. `IRTG(o,t)` and `IRTGI(o)` (~:361) set it [S]. |

### 3.3 References, constants, literals, TRefs

[S] lj_ir.h ~:455-520.

- **Refs.** `REF_BIAS` is 0x8000. Instructions grow upwards from `REF_FIRST` (0x8001); constants grow downwards from `REF_NIL` (0x7fff), `REF_FALSE` and `REF_TRUE`. `J->cur.nk` is the lowest constant, and `irref_isk(ref)` is `ref < REF_BIAS`. A dump prints `ref - REF_BIAS`, so `0001` is `REF_FIRST`, and prints constants inline.
- **Constants are interned**: the same ref always means the same value (the comment at `LJFOLD(EQ KINT KINT)`, lj_opt_fold.c ~:948). `KINT` keeps its int32 in `ir->i`; `KNUM` and `KINT64` keep their value in the second slot (`ir_k64`, ~:594).
- **Literal operands are raw numbers below `REF_BIAS`**: a CONV's mode, an SLOAD's slot and flags, an FLOAD's field (~:473). This is why CSE's "higher of the two operands" and DCE's `>= REF_BIAS` test work without looking up the opcode's mode.
- **A `TRef` (~:495) is `ref | type << 24`**, plus the flags `TREF_FRAME`, `TREF_CONT` and `TREF_KEYINDEX`. The recorder passes TRefs around. `tref_isinteger` means I8..INT and `tref_isnumber` means NUM..INT; these are what `oclj_rec_bitarg` tests.

The recorder's vocabulary [S]:

| term | what it is | where |
|---|---|---|
| `IRT(o,t)`, `IRTN`, `IRTI`, `IRTG(o,t)`, `IRTGI` | `o<<8 \| t`; G sets the guard bit | lj_ir.h ~:358-362 |
| `emitir(ot,a,b)` | `lj_ir_set` + `lj_opt_fold`: every instruction passes through FOLD and CSE | lj_record.c ~:43 |
| `emitir_raw` | `lj_ir_set` + `lj_ir_emit`, no folding | ~:46 |
| `lj_ir_kint`, `lj_ir_kint64` | interned `KINT` and `KINT64` constants | lj_ir.c ~:200, ~:246 |

### 3.4 The CONV mode word (op2)

| bits | name | meaning |
|---|---|---|
| 0-4 | `IRCONV_SRCMASK` 0x001f | source type |
| 5-9 | `IRCONV_DSTMASK` 0x03e0 | destination type (also in `ir->t`) |
| 10 | 0x0400 | unused by LuaJIT 2.1; round 3's `OCLJ_IRCONV_EXACT` |
| 11 | `IRCONV_SEXT` 0x0800 | sign-extend int to int |
| 0-11 | `IRCONV_MODEMASK` 0x0fff | what `cse_conv` compares |
| 12-15 | `IRCONV_CONVMASK` 0xf000 | num-to-int check: `TOBIT` 0 (narrowing cache only), `ANY` 1 (= `NONE`, unchecked), `INDEX` 2, `CHECK` 3 |
| 0-9 | (the fold key) | `lj_opt_fold` keys a literal operand on `op2 & 0x3ff` (~:2566) |

[S] lj_ir.h ~:251-266, lj_opt_fold.c ~:2566.

Round 3 emits three kinds of CONV; their raw op2 values, read with `jit.util.traceir` [M]:

| op2 | IR | role |
|---|---|---|
| 0x12ae | `CONV i64.num`, ANY | an operand's conversion (`cvttsd2si r64`) |
| 0x05d5 | `CONV num.i64`, marked | a result `d`, or an operand's back-conversion |
| 0x16ae | `CONV i64.num`, ANY, marked | a result guard's own back-conversion |

The backend supports a guarded CONV only from number to int: `asm_conv` (lj_asm_x86.h ~:902) asserts it [S]. So a checked int64 conversion cannot be written as `IRCONV_CHECK`; round 3 spells it out as a conversion, a conversion back, and an `EQ` [S][I].

### 3.5 Reading a dump

`0016  + num CONV   0015  num.i64` reads: the ref, `>` if a guard, `+` if a PHI operand (`}` if sunk), the type, the opcode, the operands [S].

- **Gaps in the numbering are DCE'd instructions.** NOP and CARG lines are skipped (jit/dump.lua ~:478-495) [S][M].
- **SLOAD flags print as letters**: `P` parent, `F` frame, `T` typecheck, `C` convert, `R` read-only, `I` inherit, `K` key index (`IRSLOAD_KEYINDEX`; jit/dump.lua ~:271-277). `C` means the interpreter's double becomes an int: the narrowed loop index (lj_record.c ~:378) [S].
- **`i64.num none` is the unchecked conversion.** The CONV formatter (jit/dump.lua ~:282-292) prints `none` for `IRCONV_ANY`, which is `cvttsd2si` with no check, not "no conversion" [S][M] (P38).
- **Two blind spots** [M]: a KINT64 constant prints as the trace number (P3), and the exact mark is never printed (P30). Read raw op2 values with the `traceir` snippet in [12.6](#126-reading-the-exact-mark).

A full annotated trace is in [8.7](#87-reading-a--jdump).

### 3.6 How an instruction is folded

[S] Every emitter goes through `emitir`: `lj_ir_set` (fills `J->fold.ins`), then `lj_opt_fold` (~:2524). That covers the recorder, the narrowing code and `loop_unroll`.

- **Inside a rule, `fins` is that instruction.** `fleft` and `fright` are copies of its operand instructions, including the second slot of a 64-bit constant, made at the `retry:` label (~:2553-2567).
- **Writing `fleft` changes nothing in the IR.** To change the instruction, write `fins` and return `RETRYFOLD`, which folds the changed instruction again.
- **The key** is `o << 17 | left->o << 10 | right->o`. A literal op2 contributes `op2 & 0x3ff`; an absent or literal op1 contributes 0.

The key is looked up four times, most specific first; `any` is 0x7f on the left and 0x3ff on the right (~:2569-2581):

```
ins left right  ->  ins any right  ->  ins left any  ->  ins any any  ->  lj_opt_cse
```

A rule that returns `NEXTFOLD` passes the instruction on to the next lookup. Consequences [S]:

- **Each key has exactly one function.** buildvm refuses a second `LJFOLD` line with the same key ("duplicate fold definition", buildvm_fold.c `foldrule` ~:143). "Rule order" means this order of specificity. To add behaviour for an existing key, edit the function that owns it. That is why round 3 put its rules inside `simplify_conv_i64_num` and added no second `LJFOLD(CONV CONV IRCONV_I64_NUM)`.
- **A constant operand matches by its opcode.** `LJFOLD(BAND any KINT64)` fires only when op2 is a 64-bit constant.
- **A CONV is matched on its two types only.** buildvm parses `IRCONV_I64_NUM` as `(I64 << 5) + NUM` (`nexttoken`, ~:114). SEXT, the check mode and the exact mark are not part of the key, so every CONV rule also sees marked conversions.
- **Commutative ops are normalized, lower ref on the right**, which moves constants to the right (`comm_swap` ~:1965, `comm_equal` ~:1978, `comm_dup` ~:2014, `comm_bxor` ~:2031). Rules are written as `op any K`.
- **`-O-fold` sends every N-mode instruction straight to `lj_opt_cse`** (~:2529-2537). No rule runs, round 3's included: traces stay correct but slower. Measured on `guide1.lua` ([8.7](#87-reading-a--jdump)) with `-jdump=iT`: 8 `num EQ` guards under `-O-fold` against 3, and the same result, 16565 [M].

### 3.7 From LJFOLD lines to lj_folddef.h

[S] The Makefile rule `lj_folddef.h: $(BUILDVM_T) lj_opt_fold.c` (~:709) runs `buildvm -m folddef -o lj_folddef.h lj_opt_fold.c`.

- **What `emit_fold` reads** (buildvm_fold.c ~:169): only the lines of that one file that begin with `LJFOLD` at column 0. `LJFOLD(op left right)` adds a key, which binds to the next `LJFOLDF(name)` (a local `fold_name`) or `LJFOLDX(fn)` (an outside function such as `lj_opt_cse` or `lj_opt_fwd_aload`).
- **What `makehash` builds**: a semi-perfect hash table, probed twice; each entry is the 24-bit key with the function's index in the top byte.
- **buildvm never follows an `#include`.** An `LJFOLD` line in an included file is silently missing from the table (P14). Round 3 therefore keeps its rule bodies in `lj_opt_fold.c` and puts only the helper `oclj_bitwidth` in `oclj_bitop_fold.c`; `patch-bitop-fold.sh` refuses any output whose LJFOLD lines differ from upstream's.
- **`Makefile.dep` does not know the include either.** After editing `oclj_bitop_fold.c`, delete `lj_opt_fold.o` (P4). make regenerates `lj_folddef.h` whenever `lj_opt_fold.c` changes, but its content changes only when an LJFOLD line does [S][I]. All four width-rule sabotage arms rebuild exactly `lj_opt_fold.o` (logs/suite-native-2/negctl-bitop.log) [M].

### 3.8 What a rule returns, and upstream's requirements

[S] lj_iropt.h ~:106-121, and the comment at lj_opt_fold.c ~:33-79.

| return | effect |
|---|---|
| `NEXTFOLD` | no fold; try the next, less specific key, and finally CSE |
| `RETRYFOLD` | `fins` was changed in place; fold it again from the start |
| `INTFOLD(k)` / `KINTFOLD` | the KINT `k` |
| `INT64FOLD(k)` | `lj_ir_kint64(J, k)`, a KINT64 ref |
| `LEFTFOLD` / `RIGHTFOLD` | the operand ref itself; nothing is emitted |
| `CSEFOLD` / `EMITFOLD` | straight to `lj_opt_cse`, or emit without CSE |
| `DROPFOLD` | a guard that always holds is dropped (the result is `REF_DROP`) |
| `FAILFOLD` | a guard that always fails: the trace aborts (`LJ_TRERR_GFAIL`) |
| `CONDFOLD(c)` | `DROPFOLD` if `c` holds, else `FAILFOLD` |
| any other ref | that instruction, existing or newly emitted |

The header (~:89-130) states three requirements [S]:

1. **Preserve the destination type.** Use `INTFOLD` for a KINT result and `lj_ir_knum` for a KNUM; never a helper whose result can be either.
2. **Do not create new instructions that reference operands across PHIs.** A `RETRYFOLD` with `fins->op1 = fleft->op1` is invalid when `fleft` is a PHI, because `fleft->op1` points past the PHI frontier into the pre-roll. `PHIBARRIER(fleft)` (~:157, `if (irt_isphi(fleft->t)) return NEXTFOLD`) prevents this. Returning an *existing* ref, even `fleft->op1`, is allowed: "a new PHI will added, if needed" (sic, lj_opt_fold.c ~:115).
3. **Keep the rule set monotonic.** Rules should reduce strength; a rule that does not, such as commutativity, must work in one direction only, or folding cycles.

Upstream itself breaks or qualifies these in three places that round 3 runs into [S]:

- **`simplify_conv_int_num` and `simplify_tobit_conv` fold across PHIs on purpose** ("Fold even across PHI to avoid expensive num->int conversions in loop", ~:1131 and ~:1193).
- **On x64, `simplify_conv_sext` returns an int-typed ref for a `CONV i64.int`**: a `LEFTFOLD` at ~:1241 ("All 32 bit ops do an implicit zero-extension"), taken when `J->scev` proves the loop index non-negative, and for u8/u16 XLOADs. It breaks requirement 1 on purpose, and it is the root cause of fix1 ([4.5](#45-fix1-the-worked-case)).
- **"A new PHI will be added" is `loop_unroll`'s `ref < invar` branch,** and that PHI takes the returned ref's type. So returning an existing ref across a PHI is safe only if its type equals the folded instruction's type (S4).

### 3.9 CSE, and why the exact mark is bit 0x400

**CSE** [S]:

- **`lj_opt_cse` (~:2601)** walks `J->chain[o]` from the newest instruction downwards, through `prev`, and stops at the higher of the two operand refs. It matches on `op12`, both operands with literals included. It does not compare the type.
- **CONV has its own CSE rule, `cse_conv`** (`LJFOLD(CONV any any)`, ~:1287). It matches when op1 is the same, `op2 & IRCONV_MODEMASK` is the same, and the existing instruction's guard is at least as strong ("Commoning with stronger checks is ok"). If nothing matches it returns `EMITFOLD`, so generic CSE never sees a CONV. The check mode (CONVMASK) is not part of a CONV's identity; the guard bit decides instead.
- **Guards are CSE'd too.** `EQ` reaches `lj_opt_cse` through `comm_equal` and `comm_swap`. In the loop copy, this is how an invariant guard is hoisted: its copy CSEs to the pre-roll's guard (the lj_opt_loop.c header).

**Why bit 0x400** [S] unless marked:

- **It is inside `IRCONV_MODEMASK`.** So `cse_conv`, and the narrowing CSE (`narrow_conv_backprop` ~:308, `narrow_bpc_get` ~:221), never merge a marked conversion with an unmarked one. The direction that matters [I]: an unmarked conversion CSE'd into a marked one would carry a promise that no guard backs.
- **It is outside the key's `0x3ff`.** So every CONV rule still matches a marked conversion. For example, `kfold_conv_kint64_num_i64` (~:862) still turns a constant result's `d` into a KNUM, which is why the recorder emits no guard for a constant result.
- **No upstream code tests it.** Every test of op2 in the pinned source is a mask (SRC, DST, SEXT, CONVMASK) or an equality with `IRCONV_NUM_INT`. The equalities are at lj_snap.c ~:585/654/738/798, lj_opt_sink.c ~:55, lj_asm.c ~:986, and lj_asm_x86.h ~:1993 (`asm_x87load`, a 32-bit path, found by the implementation review and missing from `oclj_bitop.h`'s list). A `CONV num.i64` is never equal to `IRCONV_NUM_INT`, and `asm_conv` ignores the bit.
- **It is the only free bit in `MODEMASK` outside `0x3ff`.** The other one, 0x800, is SEXT.

**What the mark means** depends on the conversion [S]:

- **On `CONV num.i64`** (a result `d`, or an operand's back-conversion): this double equals its int64 wherever it is used, because its guard follows at once, or because the width rule proved it.
- **On `CONV i64.num`**: this is the guard's own check. The exact-mark rule must not fold it; only the width rule may (S2).

### 3.10 The two rules

`patch-bitop-fold.sh` makes ten changes to `lj_opt_fold.c` and adds no LJFOLD line [S]. The last column is each change's one-line sabotage arm in `negctl-bitop.sh`, with its measured margin (the fewest differing cases in any seed over three runs; the script's header). Every arm passed (logs/suite-native-2/negctl-bitop.log) [M].

| change | where | why | sabotage arm and catch [M] |
|---|---|---|---|
| seven `#if LJ_HASFFI` become `#if 1` | the helper `kfold_int64arith` (~:367) behind the rule of the same name (~:397); `kfold_int64shift` (~:430), which now computes the shift itself because `lj_carith_shift64` is FFI-only; `kfold_bnot64` (~:442); `kfold_int64comp` (~:469); `kfold_int64comp0` (~:490); `simplify_andor_k64` (~:1744); `reassoc_intarith_k64` (~:1792) | Without FFI the helper fell through to `default: lj_assertJ(0, ...)`, which a release build compiles to `((void)J)` (lj_jit.h ~:525), so BAND/BOR/BXOR of two KINT64s returned the left operand: a wrong value. `simplify_shiftk_andk`'s KINT64 path (~:1700) calls the same helper, so `(x & K) << k` became `(x << k) & K` with the mask unshifted. The other stubs return FAILFOLD, which aborts the trace (P1). | KFOLD64: fuzz mode U 431-436 cases, t_rec 4-14 lines per seed |
| `narrow_convert` returns NEXTFOLD for a 64-bit CONV | ~:1312 | Narrowing `(i64)(a+b)` into int64 arithmetic keeps bits the double rounded away (2^53+1 is 2^53 as a double). | NARROW: t_rec 27-55 lines per seed; t_jit2 under 4 of 6 option sets |
| the exact-mark rule | `simplify_conv_i64_num` (~:1140), before its PHIBARRIER | An earlier result reaches a later operator with no round trip through a double. | SELFGUARD (the rule also folds the guard's own check): gen, at least 516 cases per seed |
| the width rule | the same function, calling `oclj_bitwidth` (`#include`d just above it) | Removes the guard of a result that provably fits. | WIDTH55 168, WSHR 70, WSHL0 24, WBAND 11, WADD0 11 (gen) |
| fix1, on both rules | the same function | Across a PHI, fold only to an int64-typed y. | FIX1: caught by run-bitjit.sh's p4 check |
| `#include "oclj_bitop.h"` | after `lj_strfmt.h` | provides `OCLJ_IRCONV_EXACT` | (none) |

- Three int64 folds stay FFI-only, harmlessly, because the recorder never emits their ops: `kfold_int64arith2`, `kfold_bswap64` and `simplify_intmul_k64` [S].
- A side effect: without FFI, GC64 pointer arithmetic that reassociates KINT64 constants used to hit FAILFOLD, and now it folds [S, from the implementation review; not measured].

As shipped (build copy, lj_opt_fold.c ~:1151-1174):

```c
LJFOLD(CONV CONV IRCONV_I64_NUM)  /* _INT or _U32 */
LJFOLD(CONV CONV IRCONV_U64_NUM)  /* _INT or _U32 */
LJFOLDF(simplify_conv_i64_num)
{
  if ((fleft->op2 & IRCONV_SRCMASK) == IRT_I64 && irt_isi64(fins->t) &&
      (irt_isi64(IR(fleft->op1)->t) || !irt_isphi(fleft->t))) {  /* fix1 */
    if ((fleft->op2 & OCLJ_IRCONV_EXACT) &&      /* the exact mark: inner */
        !(fins->op2 & OCLJ_IRCONV_EXACT))        /* marked, outer not */
      return fleft->op1;
    if (oclj_bitwidth(J, fleft->op1, 0) <= 54)   /* the width rule */
      return fleft->op1;
  }
  PHIBARRIER(fleft);
  ... upstream's sign- and zero-extension reductions ...
}
```

Both rules return an existing ref (`fleft->op1`), never a new instruction, which requirement 2 allows [S]. The guards that make them useful are emitted by `oclj_rec_bitop` ([2.6](#26-the-recorder)) [S]:

```
i    = CONV i64.num x            -- for each operand x that is a double
back = CONV num.i64 i  [exact]
       EQ.num back, x            -- x is integral and in [-2^63, 2^63)
res  = <op>.i64 a, b
d    = CONV num.i64 res [exact]  -- the operator's value, as a double
back = CONV i64.num d   [exact]  -- the guard's own check (not emitted for a constant res)
       EQ.i64 back, res          -- res has at most 53 significant bits
```

When an operand x is itself an earlier result `d0`, three upstream mechanisms finish the job [S][M]:

1. `i` folds to `res0`, by the exact-mark rule;
2. `back` CSEs to `d0`, by `cse_conv`: same op1, same marked mode;
3. `EQ.num d0, d0` is dropped by `comm_equal` (~:1978), because a CONV from an integer type cannot be NaN.

When the width rule folds the guard's `back` to `res`, the same `comm_equal` drops `EQ.i64 res, res`, because it is not a number compare.

### 3.11 `oclj_bitwidth`, the bound

`oclj_bitwidth(J, ref, 0) = w` means the int64 value lies in [-2^(w-1), 2^(w-1)); 64 means unknown; w ≤ 54 means every possible value is exactly a double [S] (`oclj_bitop_fold.c`).

| node | bound | why it holds [I unless marked] |
|---|---|---|
| KINT64 k | `oclj_kwidth(k)` | exact |
| an `IRT_INT` ref | 33 | an int32, sign- or zero-extended, whatever its origin (`irt_isint` tests IRT_INT only) [S] |
| an I8..U16 ref, e.g. `string.byte`'s `u8 XLOAD`, which `simplify_conv_sext` hands to the int64 op directly | 64 | conservative (`!irt_isi64`): `string.byte(s, i) << 3` keeps its result guard [S][M]; scoring u8 9 and u16 17 is roadmap row 211 (1) |
| `CONV i64.int` | 32 with SEXT, 33 otherwise | |
| `CONV` from anything else (num) | 64 | every double from outside the trace lands here |
| `BAND x, k` with k ≥ 0 | `kwidth(k)` | the value is in [0, k] |
| `BAND`, `BOR`, `BXOR` otherwise | max of the two operands | bitwise ops keep a w-bit sign extension |
| `BNOT` | unchanged | |
| `ADD` | max + 1, capped at 64 | an int64 ADD comes only from `simplify_shift_ik`'s `i << 1 ==> i + i` (~:1617) [S] |
| `BSHL x, k` | w + k, capped at 64 | |
| `BSHR x, k`, k ≥ 1 | 65 - k | a logical shift is in [0, 2^(64-k)) |
| `BSAR x, k` | w - k, floored at 1 | |
| depth > 6, or anything else | 64 | |

Shift counts are taken `& 63`, as in `simplify_shift_ik` and `asm_bitshift` [S]. Write shape tests for the shape left after other folds run: `simplify_shiftk_andk` turns `(x & m) << k` into `(x << k) & (m << k)`, so a test of the BSHL rule needs an operand that is not a BAND, such as `((a >> 42) << 32) | 1` (review1) [S][M].

### 3.12 What it looks like

**`s = s + ((x & 0xffff) << 8)`, with x a double slot** [M]. No result guard is left. `x & 0xffff` has bound 17, so its guard folded as soon as it was emitted. Then `simplify_shiftk_andk` rewrote the shift as `BAND(BSHL(x, 8), 0xffff00)`, with bound 25, so that guard folded too. The first BAND and its `d` became dead (0011-0012 are NOPs). Only x's operand guard remains (0008-0010):

```
0007 >  num SLOAD  #4    T
0008    i64 CONV   0007  i64.num none
0009    num CONV   0008  num.i64
0010 >  num EQ     0009  0007
0013    i64 BSHL   0008  +8
0014    i64 BAND   0013  +1        ; KINT64 0xffff00, printed as the trace number (P3)
0015    num CONV   0014  num.i64
```

**`h = (h ~ i) & 0xffffff`, with h carried across iterations** [M]. In the pre-roll, BXOR keeps its guard, because h comes from a slot and has bound 64. In the loop body, BXOR's operand folds across the PHI to the pre-roll's BAND, which creates an int64 PHI (0031), and BXOR's guard folds away, because its bound is max(33, 25) = 33:

```
0015  + i64 BAND   0011  +1        ; 0xffffff
0016  + num CONV   0015  num.i64
0019 ------ LOOP ------------
0023    i64 BXOR   0017  0015
0025  + i64 BAND   0023  +1
0026  + num CONV   0025  num.i64
0030    num PHI    0016  0026
0031    i64 PHI    0015  0025
```

```
->LOOP:  test byte [rbx-0xf07], 0xc / jnz ->2     ; CHECKHOOK (docs/watchdog.md)
         xor rdi, rsi                             ; rsi: the int index, zero-extended
         and rdi, 0x00ffffff                      ; a KINT64 that fits a 32-bit immediate
         xorps xmm7, xmm7 / cvtsi2sd xmm7, rdi    ; the slot's double, for snapshots
         add esi, +0x01 / cmp esi, eax / jle ->LOOP
```

Three more shapes [M]:

- **`i << 7`, i the int loop index:** the index is used directly (`i64 BSHL 0003 +7`, no CONV), and no guard is kept (bound 40).
- **`x << 20`, x a double:** both guards stay (bound 64).
- **A stored result:** after `t[1] = x << 20`, the read in `t[1] | 7` is forwarded as the marked `d`, so the BOR uses `res` directly.

### 3.13 Narrowing, and why round 3 goes around it

[S] The header of lj_opt_narrow.c (~:22-90) sets the policy: keep numbers as doubles, and narrow to int only on demand (index expressions, integer arguments, bit operations) or by prediction (the loop index: `lj_opt_narrow_forl`, ~:590, makes it an `int SLOAD ... C`).

- **Backpropagation.** `narrow_conv_backprop` (~:265) and `narrow_conv_emit` (~:357) push a `CONV int.num`, or a TOBIT, down through ADD and SUB: `CONV.int.num(ADD(CONV.num.int(i), 1))` becomes `ADDOV(i, 1)`. Only when no extra conversions are needed; results are cached in `J->bpropcache`, keyed by mode. Fold rules reach it through `narrow_convert` (~:1312), and only before the LOOP [S].
- **Upstream's bit operators** went through `lj_opt_narrow_tobit` (~:482): a number operand became `TOBIT x, 2^52+2^51` (the `bit` library's wrapping int32), an int operand had its ADDOV/SUBOV stripped, and the operator became `int BAND` and so on [S].
- **Round 3 replaces those seven cases** with `oclj_rec_bitop`, because 5.3.6 differs on every point: an operand must be integral and in [-2^63, 2^63) or it raises (TOBIT silently wraps); the result is an int64; and an inexact result raises (U1-B) [S][I].
- **`narrow_convert` would otherwise match round 3's own `CONV i64.num` of an ADD or SUB** (`LJFOLD(CONV ADD IRCONV_I64_NUM)`, ~:1310); without FFI nothing else emits one [I]. Hence its NEXTFOLD for 64-bit CONVs (the NARROW arm).

## 4. Loop optimization, snapshots, exits and side traces

### 4.1 Copy-substitution

[S] lj_opt_loop.c, the header (~:22-90) and `loop_unroll` (~:265).

- **When it runs.** `rec_loop_interp` (lj_record.c ~:630) sees the FORL at `startpc` at frame depth 0 and calls `lj_record_stop(J, LJ_TRLINK_LOOP, traceno)` (~:300), which adds the loop snapshot. In `trace_state`, `LJ_TRACE_END` (lj_trace.c ~:720) then runs `lj_opt_dce` and `lj_opt_loop` on a trace that links back to itself at frame depth 0 (~:722-723): a root trace closing its loop, or a side trace forming an extra loop (`rec_loop_jit` ~:668, "Form extra loop").
- **The pre-roll.** The recorded instructions become the pre-roll. It performs exactly one iteration, though not necessarily the first.
- **The copy.** `LOOP` is emitted. Then every recorded instruction is emitted again, through the full FOLD/CSE/FWD pipeline, with its operands replaced through `subst[]` (~:318-330). `fwd_sload` (lj_opt_fold.c ~:2392) hands back the slot's current TRef for an SLOAD. The copy keeps the recorded order.
- **No control dependencies are modelled.** The pre-roll "honors the control-dependencies for both the pre-roll and the loop body", so invariant guards are hoisted simply by CSE.
- **Invariant instructions.** An N-mode instruction whose operands did not change maps to itself (`subst[ins] = ins`, ~:325). It is invariant and never PHI-marked.
- **Loop-carried dependencies.** A copy that folds or CSEs back to a pre-roll ref (`ref < invar`, ~:334) is loop-carried, and that ref is PHI-marked at once, before any later copy is folded. So a fold in the loop copy sees a PHI-marked operand exactly when that operand is loop-carried. `loop_emit_phi` clears marks that later turn out redundant, and a spurious mark only makes `PHIBARRIER` more conservative [I].
- **Extra PHIs for hints.** A copied CONV or ALEN whose operand is in the pre-roll may get an extra PHI for that operand ("May need an extra PHI for a CONV or ALEN hint", ~:361).

### 4.2 PHIs

[S] `loop_emit_phi` (~:104) works in five passes:

1. Pass 1 drops candidates that turned out invariant.
2. Passes 2 and 4 keep a PHI only if the loop body or a snapshot uses it, propagating through PHIs that feed other PHIs.
3. Pass 3 adds PHIs for slots whose value changed without an SLOAD.
4. Pass 5 emits `PHI left, right` *below* the loop body, with the type of the left (pre-roll) ref, and PHI-marks the right ref.

A PHI's two operands share a register at the loop branch (`asm_phi` and `asm_phi_shuffle`, lj_asm.c ~:1491-1680). In a dump, `0031 i64 PHI 0015 0025` reads: 0015 on loop entry, 0025 from the previous iteration.

### 4.3 Snapshots

A snapshot maps each modified slot to a TRef, plus the pc at which the interpreter resumes. `lj_snap_add` (lj_snap.c ~:181) records them [S].

- **Where the recorder takes them** [S]:
  - **#0**, by `lj_record_setup` after `rec_setup_root`; its pc is the first instruction of the loop body.
  - **On `J->needsnap`**, at the start of the next instruction (`lj_record_ins` ~:2283-2288). `needsnap` is set after table stores (~:1686), upvalue stores (~:1862), FORL (~:586), returns and some fast functions.
  - **Mid-instruction**, by `lj_snap_add` in specific recorders: `rec_comp_prep` (~:2202) gives each comparison guard its own snapshot; `rec_for` (~:575) the FORI/FORL one (SNAP #1 in [8.7](#87-reading-a--jdump)); `rec_itern` (~:702); `lj_record_ret` (~:981); the profiler hooks `rec_profile_ins` and `rec_profile_ret` (~:778, ~:787).
  - **The loop snapshot**, by `lj_record_stop`.
- **A bit operator takes no snapshot.** Each of its guards exits through the newest snapshot: the assembler walks backwards, steps `as->snapno` down whenever it crosses a snapshot's ref (`asm_snap_prev` ~:1073), and `asm_guardcc` jumps to `exitstub_addr(J, as->snapno)` [S].
- **So a guard failure resumes at the snapshot's pc, which can be several instructions before the operator** (P40). Those instructions are safe to execute again, because every side effect forces a snapshot after itself [S][I] (read from the `needsnap` sites, not audited exhaustively).
- **Measured** with `jit.util.tracesnap(1, sn, true)` on the [8.7](#87-reading-a--jdump) loop: #0 and #2 resume at the loop body's first instruction (`MULVN`, before the operators); #1 and #3 resume at the first instruction after the loop, the loop-exit snapshots behind the `LE` guard [M].
- **In the loop copy**, `loop_subst_snap` (~:208) copies each recorded snapshot with its refs replaced, merged with the loop snapshot's entries. It adds a new snapshot only if a guard was emitted since the last one (`J->guardemit`). So a guard in the loop body exits through a replaced snapshot that keeps the original pc [S].

### 4.4 Type instability: TYPEINS, retry, blacklist

[S] For every loop-carried dependency, `loop_unroll` compares the original instruction's type `t` with the type of the ref the copy returned (~:342-352):

| original `t` | returned ref | action |
|---|---|---|
| same type | | nothing |
| I8..INT | I8..INT, but different | nothing (`continue`) |
| NUM | I8..INT | emit `CONV num.int` ("Fix int->num") |
| I8..INT | NUM | emit a guarded `CONV int.num CHECK` ("Fix num->int") |
| anything else, e.g. I64 vs INT | | `lj_trace_err(J, LJ_TRERR_TYPEINS)`: "persistent type instability" |

What happens after a TYPEINS (or GFAIL), which `lj_opt_loop` (~:415) catches [S]:

1. **Retry.** While `--J->instunroll` stays at 0 or above, it undoes the copy (`loop_undo` ~:384) and recording continues for one more iteration. `instunroll` defaults to 4 and is reset at each trace start (lj_record.c ~:2883). A loop whose boolean flips each iteration compiles this way, with its body recorded twice [M].
2. **Abort.** After that, the error aborts the trace.
3. **Penalty and blacklist.** `penalty_pc` raises the start pc's penalty, and after 11 aborts `blacklist_pc` turns `FORL` into `IFORL` for good ([2.5](#25-hot-counting-and-trace-start)) [S]. review1 measured this on the prototype without fix1: `-jv` showed `persistent type instability` x11, then `blacklisted at p4.lua:3` [M review1]. That last line is not the blacklisting, which prints nothing: it is a later recording aborting with `LJ_TRERR_BLACKL` when it reached the patched `IFORL` (P39) [S].

### 4.5 fix1, the worked case

The loop is `for i = 1, n do y = y ~ ((x & 255) << 45); x = i | 0 end`, the `or0` variant in `test/native/bitop/p4v.lua` [S][M]:

1. **The pre-roll records `i | 0`.** The operand `i` is an int, so it gets `CONV i64.int SEXT`. `simplify_conv_sext` turns that into the int ref itself, because SCEV proves the start, 1, is at least 0. `simplify_bor_k` folds `BOR <int ref>, KINT64 0` to that int ref. The result is `d = CONV num.i64 <int ref>`: a CONV whose op2 says I64 but whose operand is typed int.
2. **The loop copies x's operand conversion as `CONV i64.num d`**, with `d` PHI-marked because slot x is loop-carried.
   - Without fix1, the width rule (33 ≤ 54) returned `fleft->op1`, the int-typed loop index: a pre-roll ref of type INT for an instruction of type I64. Neither of `loop_unroll`'s fix-ups covers that, so it raised TYPEINS, and the abort, penalty and blacklist chain followed.
   - The loop ran at `-joff`'s speed: 0.135 s, against 0.023 s compiled [M review1].
3. **fix1 refuses the fold across the PHI unless `fleft->op1` is int64-typed.** The loop body keeps one round trip and one guard for x, and the loop compiles. `p4v.lua` reports `traces=1 typeins=0 loop=JFORL` for all 8 variants on this build [M]. The FIX1 negctl arm puts back `1 ||`, and run-bitjit.sh's p4 check catches it [M].

The implementation review also checked a pre-roll/copy mismatch [S]: with a negative start there is no SCEV proof, so the copy's `CONV i64.int` is not turned into the int ref; `PHIBARRIER` then blocks it, and no int/i64 PHI arises.

### 4.6 Closing a trace and linking it

After `lj_opt_loop` come `lj_opt_split` and `lj_opt_sink`, then `LJ_TRACE_ASM`: `lj_asm_trace`, then `trace_stop` (~:499) [S]. `trace_stop` patches by trace kind [S]:

- **A root loop:** FORL becomes `JFORL` with the trace number, and FORI becomes `JFORI`.
- **A side trace** (its `startins` is `BC_JMP`): `lj_asm_patchexit` (lj_asm_x86.h ~:3132) rewrites the parent's exit jump to the new code, and the exit's `snap->count` becomes `SNAPCOUNT_DONE`.
- **Stitching:** the previous trace's `link` is patched.

| link | when | `-jv` / `-jdump` shows | |
|---|---|---|---|
| `LJ_TRLINK_LOOP` | a root trace closes its own loop | `[TRACE 1 … loop]`, `stop -> loop` | [M] |
| `LJ_TRLINK_ROOT` | a side trace reaches a compiled loop (`rec_loop_jit` ~:661) | `[TRACE 2 (1/1) side1.lua:4 -> 1]` | [M] |
| `LJ_TRLINK_STITCH` | a call the recorder cannot follow (`recff_stitch`, lj_ffrecord.c ~:110) | `[TRACE 1 … stitch os.time]`, then `[TRACE 2 (1/stitch) … -> 1]` | [M] |
| `LJ_TRLINK_INTERP` | side-trace setup after `maxside`, or after `hotexit + tryside` exits | `[TRACE 4 (3/0) side2.lua:6 -- fallback to interpreter]` | [M] |
| `RETURN`, `TAILREC`, `UPREC`, `DOWNREC` | returns and recursion | — | [S] |

### 4.7 Exits

1. **A guard fails**, and its `jcc` goes to exit stub N. In dumps the stubs are 4 bytes apart (`…020`, `…024`, `…028`, `…02c` for exits 0-3) [M]. The stub pushes N's low byte, then its group's high byte, and jumps to `->vm_exit_handler` (`asm_exitstub_gen`) [S].
2. **`->vm_exit_handler`** pushes every GPR and XMM register into an `ExitState`. It reads the trace number from `g->vmstate`, which a root trace's head stores (`mov dword [rbx-0xee0], 0x1` in trace 1), and calls `lj_trace_exit` [S][M].
3. **`lj_trace_exit`** calls `trace_exit_cp` through `lj_vm_cpcall`, which calls `lj_snap_restore`. It writes each snapshot entry's slot from a register, a spill slot or a constant (`snap_restoreval`), sets `L->base`, `L->top` and the cframe pc, and returns the snapshot's pc [S].
4. **It sends the TEXIT vmevent** (`-jdump=x` prints `---- TRACE 1 exit 2`), calls `trace_hotside`, and returns to `->vm_exit_interp`, which dispatches the bytecode at that pc in the interpreter [S].
5. **The interpreter re-executes from the snapshot's pc.** At the operator, its fast path finds the same inexact result, and the slow path raises with the operator's line [S]. Measured with `x = 80 - i`, which turns negative at i = 81: `x >> 1` leaves trace 1 through exit 2, and the error text equals `-joff`'s [M]. On `s = s + (((x << 30) | 1) & 0xff)` with x stepping through 2^23, the compiled loop leaves at exit 4 in iteration 201, exactly where `-joff` raises "result of '|' has more than 53 significant bits", with the same message and state [M].

### 4.8 Side traces

- **Hot exits become side traces.** `trace_hotside` (lj_trace.c ~:799) increments `snap->count`; at `hotexit` (default 10) it sets `LJ_TRACE_START` and calls `lj_trace_ins` at the exit's pc. `J->parent` and `J->exitno` were stored by `->vm_exit_handler` before `lj_trace_exit` ran (vm_x64.dasc ~:2462-2463) [S]. In `side1.lua` (a branch that switches at i = 500) the dump shows `exit 5` once, then `exit 1` ten times, then `TRACE 2 start 1/1` [M]. Later iterations enter through `JFORL` at the head of the trace and so fail the pre-roll's copy of the guard, exit 1 [I].
- **What crosses from the parent.** For a side trace, `lj_record_setup` sets `startins` to `BC_JMP` and calls `lj_snap_replay`, which makes each snapshot slot an `SLOAD` with `IRSLOAD_PARENT|IRSLOAD_INHERIT` (`PI` in a dump), typed as the parent's IR value. It remakes constants and replays sunk allocations [S]. In `side1`'s trace 2: `int SLOAD #3 PI` (the loop index) and `num SLOAD #7 PI` (x = i * 3); a slot the snapshot does not name is loaded fresh with a type check, `num SLOAD #2 T` [M].
- **A bit result always crosses as its double**, because the slot holds `d` and never `res`. The side trace converts it again behind a fresh guard: in `side1`'s trace 2, s (a BXOR result in trace 1) is reloaded as `num SLOAD #2 T` and re-converted at 0011-0014; 0006-0008 do the same for x = i * 3, a plain double [S][M]. So an int64 temporary never crosses a trace boundary, which the width rule's soundness rests on (S6).
- **When side traces keep failing.** `trace_abort` penalizes root traces only; a side trace that aborts leaves the exit counting. Once `snap->count` reaches `hotexit + tryside` (10 + 4), `lj_record_setup` stops at once with `LJ_TRLINK_INTERP`, a stub trace that goes straight back to the interpreter [S]. In `side2.lua` (a table-supplied shift count that becomes 64): four `bad argument type` aborts, then `fallback to interpreter`; the output equals `-joff`'s and PUC's (1002000) [M].

### 4.9 The passes in order

| when | pass | where | note for our ops |
|---|---|---|---|
| per instruction, during recording | FOLD, CSE, narrowing, array-bounds-check (ABC) elimination, load/store forwarding and dead-store elimination | `lj_opt_fold` and its rules; `abc_*` (~:1890-1950); `LJFOLDX(lj_opt_fwd_*)` and `lj_opt_dse_*` (lj_opt_mem.c) | forwarding returns the stored ref, so a stored bit result comes back as its marked `d` [M] |
| trace end, looping traces only (link == itself, frame depth 0) | DCE | `lj_opt_dce` (lj_opt_dce.c): snapshot refs and side-effecting instructions are the roots; everything else becomes a NOP | guards count as side effects, so a result guard stays even when nothing uses its value [S] |
| | LOOP | `lj_opt_loop` ([4.1](#41-copy-substitution)) | the same fold pipeline runs again [S] |
| trace end | SPLIT | `lj_opt_split`: a no-op macro unless LJ_SOFTFP32, or LJ_32 with LJ_HASFFI (lj_iropt.h ~:158-162) | not used on x64 [S] |
| | SINK | `lj_opt_sink` (lj_opt_sink.c): allocation and store sinking | special-cases only a `CONV num.int` of a PHI (~:55) [S] |
| ASM | backend | `lj_asm_trace` (lj_asm.c ~:2471): one backward pass with DCE (`!ra_used && !ir_sideeff`, ~:2572), register allocation, operand fusion and exit branches | [5](#5-the-backend) [S] |

Each pass can be switched off: `-O-fold -O-cse -O-dce -O-fwd -O-dse -O-narrow -O-loop -O-abc -O-sink -O-fuse` (lj_jit.h `JIT_F_OPT_*`, ~:77-102); `-O3` is the default [S]. Review1 compared JIT output with interpreter output on the round-3 prototype under 11 option sets, among them `-O-fold`, `-O-cse`, `-O-loop`, `-O-sink` and `-O-fwd -O-dse`, and found 0 differences [M review1].

## 5. The backend

`lj_asm_trace` (lj_asm.c ~:2471) assembles a trace in one backward pass, allocating registers as it goes; `lj_asm_x86.h` holds the x64 code generators [S].

### 5.1 Our IR in x64

| IR | function | x64 code [S][M] |
|---|---|---|
| `CONV i64.num` (unguarded) | `asm_conv` ~:857 | `cvttsd2si r64, xmm/m64`. An out-of-range input or NaN gives `0x8000000000000000`, which the back-conversion and EQ that follow catch; -2^63 itself is a valid operand. |
| `CONV num.i64` | `asm_conv` | `xorps x, x` (avoids a partial-register stall), then `cvtsi2sd x, r64` (REX.W) |
| `CONV i64.int` SEXT | `asm_conv` ~:966 | `movsxd`, unless `simplify_conv_sext` already removed the conversion |
| `CONV int.i64` (not emitted today; review1's table-index fold, [8.8](#88-where-the-crc32-follow-up-starts)) | `asm_conv` ~:972 | `mov r32, r32`, the low 32 bits, only when op2's `IRCONV_NONE` bit (0x1000, which `IRCONV_ANY` and `IRCONV_CHECK` both contain) is clear; with it set, `asm_conv` emits nothing and the register keeps its upper half. So write the mode as exactly `(IRT_INT<<IRCONV_DSH)\|IRT_I64`, as review1's `fold-a.diff` does; review1 saw `mov ebp, ebp` [S][M review1] |
| `BAND`, `BOR`, `BXOR` | `asm_intarith` ~:2104 | `and`/`or`/`xor r64, r/m64/imm32`. A KINT64 that fits a signed imm32 is encoded inline (`asm_isk32` ~:102); otherwise it is loaded into a register. |
| `BNOT` | `asm_neg_not` ~:2255 | `not r64` |
| `BSHL`, `BSHR`, `BSAR` | `asm_bitshift` ~:2318 | A constant count is masked `& 63` and emitted as `shl`/`shr`/`sar r64, imm8`. A variable count goes in `cl`, or uses BMI2 `shlx`/`shrx`/`sarx`. The recorder's `ULT cnt, 64` guard keeps the count in range, so the hardware's own masking never matters. |
| `EQ.i64` | `asm_comp` ~:2406, integer path | `cmp r64, r/m64`, then `jne exit` |
| `EQ.num` | `asm_comp`, floating-point path | `ucomisd`, then `jpe exit` and `jne exit` (NaN compares unordered) |

- **`asm_conv` reads only `IRCONV_SRCMASK`, `IRCONV_SEXT` and (for a 64-to-32-bit integer conversion) the `IRCONV_NONE` bit of op2** (~:859, ~:964, ~:972); the destination type comes from `ir->t`. So the exact mark (0x400) changes nothing in the machine code [S].
- **Only `CONV int.num` may carry a guard** (`asm_conv` ~:902 asserts it), which is why round 3 writes its checks as round trips plus `EQ` ([3.4](#34-the-conv-mode-word-op2)) [S].
- **Int-typed operands in int64 ops are safe on x64** because every 32-bit instruction zero-extends into its 64-bit register, and `asm_fuseloadm` (~:529, "Don't fuse a 32 bit load into a 64 bit operation") refuses to fuse a 4-byte slot or spill into a 64-bit operand. SCEV's non-negativity proof makes zero extension equal sign extension. Upstream's FFI code relies on the same facts [S]. No test forces register pressure and spilling of such an index (review1) [I].

The round trip as compiled, for `x << 20` of a double [M]:

```
cvttsd2si rbp, xmm6 / xorps xmm15, xmm15 / cvtsi2sd xmm15, rbp
ucomisd xmm15, xmm6 / jpe ->2 / jnz ->2          ; operand guard: 4 instructions + 2 branches
shl rbp, 0x14                                    ; the operator
xorps xmm15, xmm15 / cvtsi2sd xmm15, rbp         ; d (the slot needs it anyway)
cvttsd2si rsi, xmm15 / cmp rsi, rbp / jnz ->2    ; result guard: 2 instructions + 1 branch
```

### 5.2 Registers, in brief

[S]

- `lj_asm_trace` walks the IR backwards. An instruction's destination register is allocated at its definition (`ra_dest`); its operands where the backward walk first meets them, which is their last use (`ra_alloc1`, and `ra_left` for x86's two-operand form).
- Constants are rematerialized rather than spilled (`ra_rematk`). When registers run out, `ra_evict` spills.
- Refs that a snapshot needs get a weak register or a spill slot (`asm_snap_alloc1`, ~:953). Only a `CONV num.int` may be "sunk" there and recomputed on exit. So round 3's slot doubles are computed in the loop even when only snapshots use them: see the `cvtsi2sd` in the carry loop in [3.12](#312-what-it-looks-like) [S][M].

### 5.3 Guards become exits

[S]

- As the backward pass crosses snapshot boundaries, `asm_snap_prev` (~:1073) tracks which snapshot is in effect; before a guard, `asm_snap_prep` makes that snapshot's refs available.
- `asm_guardcc` (lj_asm_x86.h ~:75) emits a `jcc` to `exitstub_addr(J, snapno)`.
- The stub pushes the exit number and jumps to `lj_vm_exit_handler`; from there, `lj_trace_exit` calls `lj_snap_restore`, and the interpreter resumes at the snapshot's pc ([4.7](#47-exits)).
- A trace's code and its exit stubs live in the machine-code area; `trace_stop` links the trace in by patching bytecode or the parent's exit ([4.6](#46-closing-a-trace-and-linking-it)).

## 6. DynASM in practice

Scope: `src/vm_x64.dasc` at `1ee778a4` (5196 lines pristine, CRLF), assembled for x64 GC64 with no DUALNUM and no FFI by DynASM 1.5.0 (the banner of `host/buildvm_arch.h`) [M]. Line numbers are the pristine file's. Round 3's `patch-bitop-vm.sh` moves every later line: +5 after `->vmeta_bitop`, and more after BC_BNOT [S].

### 6.1 From .dasc to machine code

```
vm_x64.dasc --host/minilua + ../dynasm/dynasm.lua -D ...--> host/buildvm_arch.h   (C: action list + build_* functions)
host/buildvm.c + buildvm_arch.h --HOSTCC--> host/buildvm(.exe)
buildvm -m peobj  --> lj_vm.o                    Windows: a PE/COFF object, written directly
buildvm -m elfasm --> lj_vm.S --gcc--> lj_vm.o   Linux
buildvm -m bcdef|ffdef|libdef|recdef|vmdef|folddef --> generated headers and jit/vmdef.lua (7.1)
```

- DynASM turns each `|` line into a `dasm_put(Dst, <offset into build_actionlist>, <run-time args>)` call inside the C functions `build_subroutines`, `build_ins` and `build_backend` (vm_x64.dasc :389, :2925, :4935) [S]. In the build copy, BC_BNOT's code is the single call `dasm_put(Dst, 11224, LJ_TISNUM);` [M].
- For every mode, buildvm first assembles the whole interpreter in memory: `build_code` (host/buildvm.c ~:172-243) calls `dasm_init`, `dasm_setup`, `build_backend`, `dasm_link` and `dasm_encode`, then records each opcode's pc label as its offset. Only after that does it emit anything [S]. So a .dasc that does not assemble breaks `-m folddef` as well [I].
- The handlers come first and the subroutines after them: `build_backend` emits the subroutines into `.code_sub`, then switches to `.code_op` for the opcodes, and sections link in declaration order (`|.section code_op, code_sub`, :6) [S]. `nm -n lj_vm.o` shows `lj_vm_asm_begin` at 0 and `lj_BC_BNOT` at 0x1add on both Windows and Linux; `lj_vmeta_bitop` is at 0x2806 on Windows and 0x282c on Linux [M].
- The pinned VM has 104 opcodes (BNOT..BSAR included). `lj_bc_ofs[]` has 161 entries: one per opcode, then one per assembler fast function [M] (jit/vmdef.lua's `bcnames`, lj_bcdef.h).
- `make clean` deletes `host/buildvm_arch.h` and make regenerates it from whatever .dasc the copy holds, so re-copy and re-patch the .dasc **before** `make clean` (P43; build-native.sh does) [S]. Which objects a .dasc edit reaches, and how to rebuild them: [7.4](#74-running-make-by-hand), [8.3](#83-changing-one-line-of-vm_x64dasc).

### 6.2 The dialect, by example

- `|.arch x64` (:5) selects DynASM's x86 engine in 64-bit mode [S].
- A `|` line is assembled at that point of the enclosing C function. Ordinary C around it decides at buildvm time which code is emitted, for example `switch (op)` in `build_ins` [S].
- A `||` line is a C line inside a `.macro` body, emitted at each expansion: `jmp_comp` (~:2957) contains `||switch (op) {` [S].
- `|.define NAME, text` is a textual alias; the whole register map is made of these (:21-80) [S].
- `|.if FLAG` / `|.else` / `|.endif` is decided by DynASM from the `-D` flags: `.if X64WIN` (25 uses), `.if DUALNUM` (47), `.if JIT` (18), `.if FFI` (9) [M] (counted in the pristine file).
- `|.if shift == 1` inside a macro is decided at each expansion, from the macro's arguments (`ins_bitop`) [S].
- `#if LJ_52` (a line without `|`) is plain C preprocessor, decided when gcc compiles buildvm_arch.h into host/buildvm.o (`->vmeta_len`, :1085) [S]. There are two evaluation times, and both must agree: `.if FFI` at DynASM time, `#if LJ_HASFFI` at buildvm compile time [S].
- `|.macro name, a, b` ... `|.endmacro` defines a macro (`ins_NEXT`, `checknumtp`, `ins_bitop`) [S].
- `|.type L, lua_State` lets `L:RB->base` mean `[rbp + offsetof(lua_State, base)]`; the C compiler computes the offset through `Dt1(->base)` [S] (:82-95; the generated `#define Dt1(_V)` is in buildvm_arch.h [M]).
- `->name:` defines a global label and `->name` references one. Each becomes `GLOB_name` in the generated enum and a symbol `lj_name` in lj_vm.o, except names ending in `_Z` (`build_code`, ~:231) [S]. Round 3's new label shows up as `lj_vmeta_bitop_pc` [M] (`nm`).
- `=>expr` is a dynamic (pc) label. `build_ins` defines label `op` for every opcode with `|=>defop:` (:2929), and buildvm reads it back as `lj_bc_ofs[op]`; `jmp =>BC_JLOOP` jumps to an opcode's handler [S].
- `1:` ... `9:` are local labels, referenced as `<1` (backward) and `>1` (forward). Macros use them too: `ffgccheck` says "Caveat: uses label 1" (:1225) [S].
- `call extern f` calls a name from `extnames`, relocated by buildvm. `call extern lj_meta_bitop` is a `R_X86_64_PLT32 lj_meta_bitop-0x4` relocation in the ELF lj_vm.o [M] (`objdump -d -r`).
- `mov64 reg, imm64` loads a 64-bit immediate (`settp`, `mov_true`) [S].

### 6.3 Register roles

| role | Windows x64 | SysV (Linux) | contract |
|---|---|---|---|
| BASE | rdx | rdx | volatile ("Not C callee-save, refetched anyway"): reload from `L->base` after every C call |
| KBASE | rdi | r15 | callee-saved: the function's constants, GC constants at negative indexes |
| PC | rsi | rbx | callee-saved; inside a handler it points at the NEXT instruction |
| DISPATCH | rbx | r14 | callee-saved: the dispatch table in GG_State |
| RA (RAd, RAL) | rcx (ecx, cl) | rcx | decoded A. It is `cl`, so a shift count goes here. It is CARG1 on Windows and CARG4 on SysV |
| RB | rbp | rbp | callee-saved on both. Holds OP (`OP = RBd`) during dispatch. Slow paths keep `L` in it across calls |
| RC = RD (RCd, RCL, RCH) | rax | rax | decoded D (or B and C packed); also the C return value |
| TMPR | r10 | r10 | volatile scratch |
| ITYPE | r11 | r11 | volatile; every `check*` macro clobbers it |
| CARG1..4 (5, 6) | rcx rdx r8 r9; ARG5 = `[rsp+0x20]` | rdi rsi rdx rcx r8 r9 | C call arguments |

[S] vm_x64.dasc :15-80 (`.if WIN` / `.define X64WIN`). [M] Disassembly of `lj_BC_BNOT` from both lj_vm.o files: Windows ends in `mov eax,[rsi]` ... `jmp [rbx+rbp*8]`, Linux in `mov eax,[rbx]` ... `jmp [r14+rbp*8]`; every other instruction is register-identical.

### 6.4 Decoding and dispatch

- **An instruction is 32 bits**: `B | C | A | OP` or `D | A | OP`, from MSB to LSB (lj_bc.h :12-20) [S]. The interpreter has already advanced PC by 4, so the current instruction is read at negative offsets: `PC_OP` = byte [PC-4], `PC_RA` = [PC-3], `PC_RC` = [PC-2], `PC_RB` = [PC-1], `PC_RD` = word [PC-2] (:313-318) [S].
- **`ins_NEXT`** (:212-219) is `mov RCd,[PC]; movzx RAd,RCH; movzx OP,RCL; add PC,4; shr RCd,16; jmp [DISPATCH+OP*8]`. So at a handler's entry RA = A, RC = RD = D (16 bits), and B and C are still packed in RC [S].
- **The decode macros** (:202-209) [S]: `ins_A`, `ins_AD` and `ins_AJ` are empty (they only document the format); `ins_ABC` is `movzx RBd, RCH; movzx RCd, RCL`, giving RB = B and RC = C; `ins_AB_` and `ins_A_C` decode one of the two; `ins_AND` is `not RD`, because constant indexes count down from KBASE (KSTR: `mov RD, [KBASE+RD*8]`).
- **Dispatch is replicated.** `.if 1` makes `ins_next` the inline `ins_NEXT`, so every handler ends in its own decode and indirect jump (:221-237) [S]; `lj_BC_BNOT` ends that way [M].
- **A handler may decode its own way.** `ins_bitop` does `mov RB, RA; movzx RAd, RCL; movzx RCd, RCH`, which gives RB = A (dst), RA = C (src2) and RC = B (src1). The shift count is src2, so it lands in `cl` ("Assumes RA is ecx"). `->vmeta_bitop` expects exactly this layout ("Caveat: ra=RB rb=RC rc=RA", :1104) [S].
- **Hot counting is a DynASM macro too**: `hotloop` / `hotcall` (:332-345) subtract from `word [DISPATCH+reg+GG_DISP2HOT]` ([2.5](#25-hot-counting-and-trace-start)) [S].

### 6.5 What a handler may clobber

- **At dispatch, BASE, KBASE, PC (pointing at the next instruction) and DISPATCH must be intact, and `rsp` unchanged: no push or pop** [S]. The frame layout is fixed (:96-189) and the unwinder describes it with a single entry, so a push inside a handler would make the unwinder's view wrong [I]. That entry is `.xdata` from `emit_peobj` (host/buildvm_peobj.c ~:301-318) on Windows and `.eh_frame` from `emit_asm_debug` (vm_x64.dasc :4947) on ELF [S].
- **RA, RB, RC, TMPR, ITYPE and the xmm registers are free inside a handler**, and `ins_next` reloads RA, RC and OP [S]. No xmm value is live across a dispatch [I] (no handler reads one before writing it).
- **Every slow-path label has an entry contract.** `->vmeta_bitop` needs RB = dst index, RC = B index and RA = C index; `->vmeta_bnot` needs RA and RD. If a fast path consumes a register a contract needs, it must reload it (round 3's `->vmeta_bitop_pc`) or use another register (round 3's BC_BNOT uses TMPR) [S].
- **Store the result slot last**, after every check that can exit. Then the slow path can recompute from operand slots the fast path never wrote. Round 3's handlers write `[BASE+RB*8]` / `[BASE+RA*8]` only after the exactness check [S].

### 6.6 Calling C from the interpreter

- **What a call destroys.** On Windows rax, rcx, rdx, r8-r11 and xmm0-5 are volatile; on SysV rax, rcx, rdx, rsi, rdi, r8-r11 and every xmm register [S] (the platform ABIs; the dasc's "Must be C callee-save" comments and its `saveregs_` macros agree, :21-35, :99-160). Lost across a call: BASE, RA, RC, TMPR, ITYPE, and (assume) every xmm register. Kept: RB, KBASE, PC, DISPATCH.
- **The pattern** (`->vmeta_bitop`, :1105-1132) [S]:

  ```
  mov L:RB, SAVE_L          ; L in a callee-saved register
  mov L:RB->base, BASE      ; the callee reads L->base
  mov SAVE_PC, PC           ; errors and debug info take the pc from here
  ...arguments...
  call extern lj_meta_bitop ; (lua_State *L, TValue *ra, *rb, *rc, BCReg op)
  mov BASE, L:RB->base      ; the stack may have moved
  jmp ->cont_nop            ; -> ins_next
  ```

  Also store `L->top` when the callee may push or allocate: change 2 exists because some fast functions stored `L->base` but not `L->top` before an allocating call (build-native.sh header) [S].
- **Argument registers alias interpreter registers** [S]. On Windows CARG1 = RA and CARG2 = BASE; on SysV CARG3 = BASE and CARG4 = RA. Store `L->base` before writing CARG2 or CARG3 (":1120 Caveat: CARG2d == BASE"). The 5th argument goes to `ARG5` = `[rsp+aword*4]` on Windows, above the 32-byte shadow space `CSAVE_1..4` the frame keeps at `[rsp]`, and to CARG5 = r8 on SysV. The frame keeps rsp 16-byte aligned (:118-135, :161-186), so a plain `call` from a handler is ABI-correct on both.
- **Seen in lj_vm.o** [M]. Windows `lj_vmeta_bitop`: `mov [rsp+0x20],rax` (ARG5), `mov rbp,[rsp+0x58]` (SAVE_L), `mov [rsp+0x60],rsi` (SAVE_PC), `call`, `mov rdx,[rbp+0x20]`. Linux: `movzx r8,byte [rbx-0x4]`, `mov rdi,[rsp+0x10]`, `mov [rsp+0x18],rbx`, `call`, `mov rdx,[rbp+0x20]`.
- **A handler that does not call out is the same on both ABIs** apart from the PC and DISPATCH registers in its `ins_next`; round 3's handlers are register-identical on the two platforms [M].

### 6.7 Round 3's checks, instruction by instruction

`lj_BC_BSHL` from the Windows lj_vm.o (`objdump -d -M intel`), annotated [M]:

```
mov  rbp,rcx ; movzx ecx,al ; movzx eax,ah     ins_bitop decode: RB=A, RA=C (count), RC=B
mov  r11,[rdx+rcx*8] ; sar r11,0x2f            checknumtp: ITYPE = tag
cmp  r11d,0xfffffff2 ; jae lj_vmeta_bitop      not a number (LJ_TISNUM = -14): indices intact, plain label
... same for [rdx+rax*8]
movsd xmm0,[rdx+rcx*8] ; movsd xmm1,[rdx+rax*8]
cvttsd2si rcx,xmm0 ; cvttsd2si rax,xmm1        operands to int64: RA and RC are now VALUES
cvtsi2sd xmm2,rcx ; ucomisd xmm0,xmm2          round trip of src2
jne  lj_vmeta_bitop_pc ; jp lj_vmeta_bitop_pc  not exact, or NaN
... same for src1
cmp  rcx,0x3f ; ja lj_vmeta_bitop_pc           count outside [0, 63] (unsigned compare)
shl  rax,cl
cvtsi2sd xmm0,rax ; cvttsd2si rcx,xmm0         result to double and back
cmp  rcx,rax ; jne lj_vmeta_bitop_pc           more than 53 significant bits
movsd [rdx+rbp*8],xmm0                         store last
mov eax,[rsi] ; movzx ecx,ah ; movzx ebp,al ; add rsi,4 ; shr eax,0x10 ; jmp [rbx+rbp*8]
```

- **Operand round trip.** `cvttsd2si r64` truncates and yields INT64_MIN for NaN and for anything outside [-2^63, 2^63); `cvtsi2sd` converts back, and `ucomisd` compares [S] (patch-bitop-vm.sh header).
  - NaN compares unordered, which sets ZF=PF=CF=1, so `jne` alone would let NaN through and `jp` catches it [I] (x86 flag semantics). No negctl arm removes a `jp`: its necessity is argued from the ISA, not measured; t_ops' operand list contains `0/0`, so the matrix would see a missing `jp` [I].
  - Accepted: -2^63, which round-trips, and -0.0, as 0. Refused: 2^63 and 1.5. A probe printed `nan&1=noint -0.0|0=0 -2^63&-1=-9.2233720368547758e+18 2^63&1=noint 1.5|0=noint`, identical under `-joff` [M].
- **Shift count.** `cmp RA, 63; ja` is an unsigned compare, so negative counts and counts of 64 or more go to C, which applies 5.3.6's `luaV_shiftl` rules [S]. The check is needed because x86 masks a 64-bit shift count to 6 bits: without the `ja`, `x << 64` would compute `x << 0` [S]. negctl's SHIFTMASK arm removes the `ja` and is caught by t_ops and the fuzzer [M]. Probe: `1<<64=0 8>>-1=16 -1~>>70=-1` [M].
- **Result exactness.** The int64 result is converted to the nearest double and back. If it differs, it had more than 53 significant bits, or it rounded up to 2^63 and came back as INT64_MIN; then the C path recomputes from the untouched slots and raises [S]. Probe: `1<<63=-9.2233720368547758e+18` (1 significant bit, exact), `(2^63-2^10)|0=9.2233720368547748e+18` (53 bits, exact), `~(2^53-1)=-9007199254740992` [M].
- **Why `->vmeta_bitop_pc`.** The conversions overwrite RA and RC, which `->vmeta_bitop` needs as slot indices. The new label reloads them from the instruction bytes (`movzx RCd, PC_RB; movzx RAd, PC_RC`, as the DUALNUM path already did, :1106-1109) and falls into `->vmeta_bitop` [S]. In lj_vm.o it is exactly those two 4-byte `movzx`: `lj_vmeta_bitop_pc` at 0x27fe, `lj_vmeta_bitop` at 0x2806 [M]. The type-check exits jump to the plain label, because nothing has been clobbered yet [M].
- **BC_BNOT.** Its result is in RB and the comparison uses TMPR, because `->vmeta_bnot` needs RA and RD and rewrites RB itself (`mov RB, RA`) [S].

### 6.8 The -D flags

The Makefile builds DynASM's flags from `TARGET_TESTARCH = $(TARGET_CC) -E lj_arch.h -dM` (src/Makefile :236, `DASM_AFLAGS` :409-457) [S]. DynASM never reads a C header. Our `lj_arch.h` includes `oclj_features.h`, so the feature header decides `FFI`, and its `#error` lines rule out `DUALNUM` and `NO_UNWIND` [S]. A dry run of the *pristine* tree's Makefile adds `-D FFI`, because only the build copy's `lj_arch.h` includes the header [M].

| flag | selects in vm_x64.dasc | Windows | Linux (WSL Ubuntu 26.04, gcc 15.2) | why |
|---|---|---|---|---|
| ENDIAN_LE | - | yes | yes | LJ_LE 1 |
| P64 | - | yes | yes | LJ_ARCH_BITS 64 |
| JIT | `.if JIT` (18 uses) | yes | yes | LJ_HASJIT 1 |
| FFI | `.if FFI` (9) | no | no | LJ_HASFFI 0 (LUAJIT_DISABLE_FFI in oclj_features.h) |
| DUALNUM | `.if DUALNUM` (47) | no | no | LJ_DUALNUM 0; LUAJIT_NUMMODE is `#error`ed |
| FPU, HFABI | - | yes | yes | x64 |
| NO_UNWIND | `.if NO_UNWIND` (3, POSIX frame) | no | no | LUAJIT_NO_UNWIND is `#error`ed |
| SHADOW_STACK | none in the dasc | no | yes | gcc's default `-fcf-protection` (`__CET__ & 2`, lj_arch.h ~:234-243); only a `.note.gnu.property` in lj_vm.S (`emit_asm_debug`) |
| BRANCH_TRACK | `.if BRANCH_TRACK` (`endbr`) | no | no | needs LUAJIT_ENABLE_CET_BR (lj_arch.h ~:222-232) |
| WIN | `.if WIN` -> `X64WIN` | yes | no | TARGET_SYS=Windows |
| VER= | - | empty | empty | x64 has no LJ_ARCH_VERSION |

[M] The DynASM command lines in the logs. Windows: `host/minilua.exe ../dynasm/dynasm.lua -D ENDIAN_LE -D P64 -D JIT -D FPU -D HFABI -D VER= -D WIN -o host/buildvm_arch.h vm_x64.dasc` (bench/runs/2026-10-17-bitop/logs/builds-2/luajit_build-additive.log :118). Linux: the same without WIN and with `-D SHADOW_STACK` (logs/linux/luajit_build-additive.log :115); its lj_vm.S ends in `.note.gnu.property` with the value 2.

### 6.9 Reading what you assembled

- **The echo proves DynASM read your line, not that it assembled it** (P46). buildvm_arch.h echoes every `|` line of the .dasc as a `//|` comment: all 4491 of the patched file's, including the DUALNUM halves of BC_BNOT and `ins_bitop`, which are not assembled [M]. A macro body is echoed once, at its definition; an expansion site echoes only the call (`//|  ins_bitop and, 0` followed by `dasm_put(Dst, 11323, ...)`) [M]. The assembly shows in lj_vm.o. build-native.sh's echo gate and negctl's echo check pair the echo with object freshness or object-change checks, which is what makes them sound [S]. C lines of the .dasc (no `|`) are copied, not echoed [S].
- **`#line N "vm_x64.dasc"`** directives map buildvm compile errors back to .dasc lines [M].
- **Symbols and offsets.** `nm -n lj_vm.o` lists `lj_BC_<OP>`, `lj_ff_<name>` and the global labels as `lj_<label>`. If an earlier handler changes length, every later offset moves, and with it `lj_bc_ofs` and lj_bc.o (P14) [M].
- **Disassembly.** `objdump -d -M intel --start-address=0x... --stop-address=0x... lj_vm.o` shows the actual instructions, and `-r` adds the relocations. The MinGW binutils read the ELF lj_vm.o too [M].

## 7. The build

`native/build-native.sh` makes the build copy `build/native/luajit-<platform>` from the pristine tree plus our twelve changes and seven files, builds LuaJIT with its Makefile, and gates the result. This section is what you need to rebuild by hand without fooling yourself.

### 7.1 Who generates what

| buildvm mode | output | contents | compiled into |
|---|---|---|---|
| `peobj` (Windows) | lj_vm.o | the VM as a PE/COFF object, with `.pdata`/`.xdata` unwind data written by `emit_peobj` (buildvm_peobj.c ~:182, ~:275-318) | the archive |
| `elfasm` (Linux) | lj_vm.S | GNU assembler source, `.eh_frame` and the CET note from `emit_asm_debug` | lj_vm.o via gcc |
| `coffasm`, `machasm`, `raw` | - | unused here (macOS is parked) | - |
| `bcdef` | lj_bcdef.h | `lj_bc_ofs[]`, the offset of every handler and assembler fast function (`emit_bcdef`, buildvm.c ~:312), and `lj_bc_mode[]` (`emit_lib`, buildvm_lib.c ~:445-452) | lj_bc.o |
| `ffdef` | lj_ffdef.h | the `FFDEF(name)` list, i.e. the fast-function ids | lj_err.o, lj_dispatch.o, lj_record.o, lj_ffrecord.o, lib_*.o |
| `libdef` | lj_libdef.h | `lj_lib_cf_*`, `lj_lib_init_*` per library | lib_*.o |
| `recdef` | lj_recdef.h | `recff_idmap`, `recff_func` | lj_ffrecord.o |
| `vmdef` | jit/vmdef.lua | `bcnames`, `irnames`, `ircall`, `traceerr`, `ffnames` | LuaJIT's jit/*.lua tools |
| `folddef` | lj_folddef.h | `fold_func[]` and `fold_hash[]` from `lj_opt_fold.c`'s LJFOLD lines (`emit_fold`, buildvm_fold.c ~:169-225) | lj_opt_fold.o |

[S] The sources cited, and the rules at src/Makefile :675-711. [M] Windows log lines :132-142 of luajit_build-additive.log. Every buildvm output depends on `$(BUILDVM_T)`, so whatever relinks buildvm regenerates all of them [S]. `lj_dispatch_init` (lj_dispatch.c ~:60-67) fills the dispatch table from `lj_bc_ofs`, so lj_vm.o and lj_bc.o must come from the same buildvm run [S].

### 7.2 Dependency traps

| trap | evidence | what to do |
|---|---|---|
| `Makefile.dep` is upstream's `gcc -MM` output (`depend`, Makefile :646). It knows no file of ours, so an edit to an `#include`d file rebuilds nothing (P4) | [M] `touch` + `mingw32-make -n` gives `Nothing to be done` for oclj_bitop_rec.c, oclj_bitop_fold.c, oclj_bitop.h, oclj_num53.h and oclj_features.h; `Makefile.dep` has 0 mentions of `oclj` | delete the including objects ([7.4](#74-running-make-by-hand)) |
| `oclj_features.h` changes DynASM's flags through lj_arch.h, but no make rule names it: the interpreter would keep the old `.if FFI` while C sees the new `LJ_HASFFI` | [M] touching it: nothing. Touching `lj_arch.h`: DynASM, 75 of the 77 objects (71 + 6 host; all but `lj_char.o` and `host/minilua.o`, with lj_vm.o remade by buildvm) and every generated file | after a feature change, `make clean`, or run build-native.sh (it re-copies lj_arch.h and runs `make clean`) |
| A .dasc edit with an older mtime than buildvm_arch.h is invisible to make (a restore with `cp -p`, an editor that keeps mtimes) | [M] dry run: appended a line, set the mtime to 2026-10-01: `Nothing to be done` | delete `host/buildvm_arch.h` and the objects it reaches |
| `lj_bcdef.h` holds the handler offsets, so a .dasc change that moves any handler changes lj_bc.o (P14) | [M] negctl: WRAP32-INTERP (32-bit `and`, no REX.W) and SHIFTMASK (one `ja` removed) changed `lj_bc.o lj_vm.o host/buildvm.o`; INEXACT-INTERP and INEXACT-BNOT (`cmp r,r`, same length) changed only `lj_vm.o host/buildvm.o`. Same on Windows and Linux | always rebuild lj_bc.o with lj_vm.o |
| `buildvm -m folddef` reads only lines of lj_opt_fold.c that **start** with `LJFOLD` (`emit_fold`, `strncmp(buf, FOLDDEF_PREFIX, ...)` ~:200) and never follows an `#include` (P14) | [S] | keep LJFOLD lines in lj_opt_fold.c; patch-bitop-fold.sh asserts they are unchanged |
| `make clean` deletes `host/buildvm_arch.h` (in ALL_HDRGEN, Makefile :544-548), and make regenerates it from whatever .dasc the copy holds (P43) | [S] | re-copy and re-patch the .dasc **before** `make clean`; build-native.sh does (:694-733) |
| A .dasc touch remakes far more than it changes | [M] `make -n` after touching it: DynASM, host/buildvm.o and buildvm.exe, lj_vm.o, all six generated files, and 18 more objects. Only lj_vm.o and host/buildvm.o change bytes, plus lj_bc.o if offsets move (negctl) | judge by object md5s, not by what was recompiled |
| The build copy persists. build-native.sh copies the tree only when `build/native/luajit-<platform>` is missing (:496-501) and re-takes only the 12 patched files and our 7. A hand edit to any other file (say `lj_asm_x86.h`) survives every later build, and `make clean` does not undo it (P44) | [S]; [M] today the Windows copy differs from the pristine sources exactly in those 12 + 7 and the generated files (`diff -rq --strip-trailing-cr` over src, objects excluded) | experiment in scratch copies only; a round that changes a new upstream file adds it to build-native.sh's re-copy list |
| `luajit_build.log` sits in `$OCLJ_BUILD`, not per platform: the last platform built overwrites it (P19) | [M] on 2026-10-17 it held the WSL build (`-m elfasm`, `-fPIC`) | read each platform's log from the round's archive (round 3: logs/builds-2/, logs/linux/) |
| `luajit.exe`'s md5 changes on every link (P13) | [M] `objdump -p luajit.exe`: `Time/Date Sat Oct 17 12:29:30 2026`, its link time | compare `*.o host/*.o` |

### 7.3 Line endings and the Git Bash instrument

- **The pristine checkout is CRLF** (`core.autocrlf=true`; vm_x64.dasc has 5196 CRs in 5196 lines; lj_opt_fold.c 2653 in 2653) [M]. The build copy mixes the 19 LF files our scripts write with 145 CRLF upstream `.c`/`.h`/`.dasc` files, and both build [M]. Unpatched build files keep the pristine CRLF (Makefile 757 CRs, lj_asm_x86.h 3170) [M].
- **On this machine's Git Bash, awk (GNU Awk 5.4.1) and grep drop a line-end CR on input** [M]: `printf 'a\r\nb\r\nc\n'` gives awk lengths `1 1 1`; an awk `index($0, CR)` count gives 0 for that file and 0 for a log with 95 CRLF lines; `grep -c $'\r'` gives 0 and `grep -c -U $'\r'` gives 95; awk sees the CRs only with `-v BINMODE=1`.
- **Count CRs by bytes**: `python -c 'import sys;print(open(sys.argv[1],"rb").read().count(13))' f`, `grep -c -U`, or `od -c` (P7).
- **One consequence**: the hunk engine's `ncr()` check ("the output carries CR characters") is awk-based and cannot fail on Git Bash for line-end CRs; on Linux it can. The outputs are LF by byte count anyway [M]. This is an open gap (Open questions).
- **Windows `luajit.exe` and `lua.exe` write CRLF to stdout**: strip CR before comparing. Every gate pipes through `tr -d '\r'` or compares a stripped copy [S] (P18).

### 7.4 Running make by hand

Always in a fresh scratch copy, never in `build/`:

```sh
S=<fresh scratch dir>                                   # never under build/, never reused
mkdir -p "$S/luajit-windows-x86_64" && cp -rp build/native/luajit-windows-x86_64/. "$S/luajit-windows-x86_64/"   # -p keeps mtimes
cp -rp build/native/obj-windows-x86_64 "$S/"            # run-bitop.sh part 3 links these
W=$S/luajit-windows-x86_64/src
( cd "$W" && md5sum *.o host/*.o ) | tr -d '*' > "$S/base-obj.md5"     # 77 lines
# change ONE file (LF, written with a file tool, not a heredoc), then delete what it reaches (table below)
mingw32-make -C "$W" BUILDMODE=static XCFLAGS= "Q=" -j4 > "$S/build.log" 2>&1      # Windows
make         -C "$W" BUILDMODE=static XCFLAGS=-fPIC Q= -j4 > "$S/build.log" 2>&1   # Linux
( cd "$W" && md5sum *.o host/*.o ) | tr -d '*' | diff "$S/base-obj.md5" -          # only the reached objects may differ
```

The layout mirrors `$OCLJ_BUILD`, so the suites run against the scratch build unchanged: they take `$OCLJ_BUILD/luajit-<platform>/src/luajit.exe`, and run-bitop.sh also `$OCLJ_BUILD/obj-<platform>` (run-bitjit.sh ~:117, run-bitop.sh ~:104-121) [S]. For example `OCLJ_BUILD=$S OCLJ_BITJIT_OUT=$S/bitjit-1 sh test/native/run-bitjit.sh`, and likewise run-bitfuzz.sh (`OCLJ_BITFUZZ_OUT`) and run-bitop.sh (`OCLJ_BITOP_OUT`). negctl-bitop.sh accepts the same layout, but it refuses a copy that is not what the repo's files and patch scripts make ([11.7](#117-negctl-one-line-sabotages) item 1), so it proves a change only once the change is in `native/luajit/` and the copy was rebuilt by build-native.sh ([7.6](#76-build-nativesh-stage-by-stage)) [S].

- **`BUILDMODE=static`** builds `libluajit.a` and a statically linked `luajit.exe`. Without it, Windows builds a DLL (`-DLUA_BUILD_AS_DLL`, Makefile ~:568-572). Under static mode `TARGET_DYNCC` is `@:`, so the `_dyn.o` compiles are no-ops [S].
- **`XCFLAGS` must be build-native.sh's** (`LJ_FLAGS="$PICFLAG"`: empty on Windows, `-fPIC` elsewhere, :292-293), or every recompiled object differs from the shipped build [S]. Rebuilding with the right flags gives byte-identical objects [M] (negctl canon).
- **`Q=`, empty.** The Makefile's default `Q= @` (:625) hides command lines, and build-native.sh passes `Q=` so its log gates have compile lines to match (:733) [S]. A literal `Q=.` (a report's full stop copied into the command) prefixes every command with a dot: `make -n` prints `.host/minilua.exe ../dynasm/dynasm.lua ...` and `.gcc ...` [M] (P5).
- **`make` on Windows.** build-native.sh and the negctls call `make`, but WinLibs MinGW-w64 ships only `mingw32-make`, and in a plain Git Bash `command -v make` finds nothing [M]. This machine's launchers prepend `/c/Users/astro/claude-tmp/oclj/bin`, which holds a two-line `make` (`exec mingw32-make "$@"`); `bench/runs/2026-10-13-dispose/scripts/make-shim` is its archived copy [M] (P45).
- **Cost.** A rebuild takes 1-3 s, a vm_x64.dasc one included; a C object plus the relink about 1 s [M] (negctl-bitop.sh header; impl-C3.json). build-native.sh's whole LuaJIT stage, `make clean` included, takes +17 s on Windows and +6 s in WSL [M] (logs/builds-2, logs/linux).

**What to delete before make**, so make cannot miss a change. This is negctl-bitop.sh's map (`objs_of`, `dirty`), plus `lib_string.o` for `oclj_strpack.c` from negctl-pack.sh [S]:

| you changed | delete |
|---|---|
| vm_x64.dasc | `host/buildvm_arch.h host/buildvm.o lj_vm.o lj_bc.o` |
| lj_parse.c / lj_meta.c / lj_record.c / lj_opt_fold.c / lib_jit.c | its `.o` (make would see the mtime, but delete anyway) |
| oclj_bitop_meta.c | `lj_meta.o` |
| oclj_bitop_rec.c | `lj_record.o` |
| oclj_bitop_fold.c | `lj_opt_fold.o` |
| oclj_bitop.h | `lj_parse.o lj_meta.o lj_record.o lj_opt_fold.o` |
| oclj_num53.h | those four and `lib_string.o` |
| oclj_strpack.c | `lib_string.o` |
| lj_bcdump.h | `lib_string.o lj_bcread.o lj_bcwrite.o lj_lib.o lj_load.o` (only lj_bcread.o and lj_bcwrite.o changed bytes in negctl's BCDUMP arm [M]) |
| oclj_features.h, lj_arch.h | everything: `make clean` |

### 7.5 The patch-script engine

Round 3's seven scripts share one engine; use it for any new change ([8.2](#82-writing-a-patch-script)).

- **The engine block is byte-identical in all seven**: 99 lines, md5 `077d1dbebe05` [M]. The scripts contain no backslash, no tab and no CR [M]; in the hunk texts, `@T@` stands for a tab.
- **Hunks.** Each hunk is a pair of files written by the script: `o<h>` holds upstream's text, `n<h>` ours. A text matches only as a run of consecutive whole lines, compared exactly after the trailing CR is stripped [S].
- **Modes** [S]: `count` (per hunk, how often upstream's text and ours occur, and whether upstream's text survives inside ours, which an insertion does); `apply` (each upstream text must occur exactly once at its point); `revert` (the inverse, in reverse order).
- **After `apply`, the output must pass all of these** [S]:
  - the marker exactly `NMARK` times, and every patched text exactly once;
  - per-script content checks (the vm script checks that `->vmeta_bitop_pc` is defined once and named on 7 lines and that there are 3 OC-LuaJIT lines; the fold script that the LJFOLD lines are unchanged and where the include sits);
  - no CR (but see [7.3](#73-line-endings-and-the-git-bash-instrument)), and line count in + NADD - NDEL = out;
  - `diff -d --strip-trailing-cr` counting exactly NADD added and NDEL removed lines (vm 40/15, fold 45/8, parse 24/18, record 7/35, meta 8/26, jitlib 7/3, bcdump 6/1);
  - **reversal**: putting every upstream text back must reproduce the input byte for byte (CR stripped).
- **Output is LF.** An "already patched" input is verified and left alone; that path is for hand use only, because the build always re-copies the pristine file first [S].
- **The earlier five** have the same shape with an older engine: they splice a block with awk, anchor on lines that occur exactly once (CRLF-tolerant), check `diff --strip-trailing-cr` hunk and line counts, and check the removed lines by content [S]. patch-penalty-scrub.sh and patch-fastfunc-errmem-top.sh still contain backslashes (5 and 8 lines) [M]; new scripts follow round 3's no-backslash rule.

### 7.6 build-native.sh, stage by stage

**Stage 1: the copy and the twelve changes** (:486-733) [S].

- `build/native/luajit-<platform>` is created once with `cp -r` from `prototype/watchdog/luajit`, and its `.git` is removed.
- On every run, for each of the twelve changed files ([1.2](#12-our-twelve-changes-to-luajit)): assert the pristine checkout does not carry the change; re-copy the pristine file over the build copy; assert the change is **absent** after the copy; run the patch script; assert the marker is **present the exact number of times** before make. The counts: the scrub line once, the clamp line twice, the `lj_ffrecord.c` marker once, `#include "oclj_features.h"` once and directly after `lua.h`, the strpack marker and its `#include` once each, and each round-3 file its own marker once, no other round-3 marker, and each new `#include` once.
- Our seven files are copied and compared with `cmp`; their presence in the pristine checkout is refused [S].
- Stage 1 refuses any architecture but x86_64 (:691-693) [S].
- Then `make -C $LJ clean`, then `make -C $LJ BUILDMODE=static XCFLAGS="$LJ_FLAGS" Q= -j$JOBS` (:730-733) [S].

**Running it outside `build/`**, for agents and for any experiment the gates or negctl must see [S] (build-native.sh EXTERNAL INPUTS and USAGE, ~:111-128):

```sh
OCLJ_BUILD=<fresh scratch dir> OCLJ_JNLUA=<OC-JNLua checkout> OCLJ_JNI=<JDK include dir> \
  PATH=<dir holding make>:$PATH sh native/build-native.sh > <log> 2>&1
```

- Round 3's values for `OCLJ_JNLUA`, `OCLJ_JNI` and `PATH` are in `bench/runs/2026-10-17-bitop/scripts/build-r3.sh`; `OCLJ_VARIANT=additive` builds the other library.
- A missing build copy is created from the pristine tree, so the first run builds everything; if it takes more than a minute, run it from the main session ([11.11](#1111-long-runs-and-results-directories)).
- Point every runner and negctl-bitop.sh at the same `OCLJ_BUILD`. negctl writes its ~445 MB work directory under `$OCLJ_BUILD/negctl-bitop/` (no other knob, ~:647) and needs `obj-<platform>/` (`lj52shim.o`, `eris_lj.o`) as well as the LuaJIT copy (~:180-192).

**Freshness gates** (:739-845) [S]:

- Each patched object must be newer (`-nt`) than its source and every round-3 file it includes: lj_parse.o, lj_meta.o, lj_record.o, lj_opt_fold.o, lj_bcwrite.o, lj_bcread.o, lib_jit.o, lib_string.o, lj_func.o, lj_err.o, lj_ffrecord.o.
- Each object's compile line must be in the log, anchored as `-c -o X[.]o X[.]c[[:cntrl:]]?$`. A bare file name would also match buildvm's five command lines, which list every LJLIB_C file. The `[[:cntrl:]]?` is there because mingw32-make writes 95 of the log's 185 lines with CRLF [M].
- `host/buildvm_arch.h` must be newer than vm_x64.dasc, and DynASM's command line must be in the log. lj_vm.o must be newer than buildvm_arch.h; on ELF, lj_vm.S must sit between them.
- buildvm_arch.h must echo exactly 3 `//|` lines carrying `OC-LuaJIT`, 2 of them `OC-LuaJIT: Lua 5.3's`.
- `lj_ffdef.h` must list `FFDEF(string_pack|packsize|unpack)` once each.
- **`-f` comes before `-nt`**, because `[ a -nt b ]` is true when b is missing (:801; P15) [S][M].

**Feature-channel gates** (:847-876) [S]:

- No `-D LUAJIT_*` may appear on any compile line except `LUAJIT_TARGET` and `LUAJIT_UNWIND_EXTERNAL`, which are platform facts.
- `gcc -I$LJ -E -dM lj_arch.h` must say `OCLJ_LUAJIT_FEATURES 1`, `LJ_52 1`, `LJ_HASFFI 0`, `LJ_HASJIT 1`, `LJ_GC64 1`, `OCLJ_LIB_STRPACK 1` and `OCLJ_OPS_BIT64 1` (~:859); `lj_bcdump.h -dM` must say `BCDUMP_VERSION 0x80`. `LJ_DUALNUM`, `LJ_FR2`, `LJ_ABI_WIN` and `LJ_UNWIND_EXT` are not in this list ([1.1](#11-what-the-fork-is)).

**Warning gates** [S]: the LuaJIT compile is `-Wall`, and no warning may name a patched or added file. Our C also compiles under `-Wall -Wextra` in two throwaway translation units, `strpack_wgate.c` and `bitop_wgate.c`, with zero warnings; each calls the entry points, because an uncalled static inline function is never compiled.

**luajit.exe gates** (:948-1332), each a probe with an exact wanted line [S]:

- `table.unpack` exists (LUA52COMPAT); a count hook fires over a hot loop (CHECKHOOK, more than 100 ticks).
- FFI / integer-format: `lit=refused preload=nil loaded=nil s=0/1/0 x=1/0/0 same=true`.
- string.pack: `... hot=14000 jit=0/1/0`.
- **bitops**: `fold=4294967296/-1/0 kx=X>> rt=4294967296/X>>/X>>/9007199254740991/X>>/0/X~/X| err=noint/1/17/type/noint/X>> sar=-2/-1/8 dump=128 bit=1 hot=X>>@151 acc=43800 jit=1/0/0 same=true` [M] (re-run on today's luajit.exe: identical).
- **jit tools**: `jitlib f=1 hot=206208 snapend=4278190080 bc=118 bl=118 blerr=0 bldec=3 jd=1/1/0/0 jdb=12/1 jdim=1/1 jdline=1`, run in `$LJ` with `LUA_PATH='./?.lua'`.
- The JIT gates count loop, stitch and abort traces in the probed function, so they fail with the JIT off.

**Stage 1b** (:1334-1430) [S]: `lua_newstate` with a plain realloc allocator must work (GC64 accepts a foreign allocator); its first allocation must equal `sizeof(GG_State)` as seen through `-I$LJ`, the view the shim and the serializer compile with: 6376 [M]. The **negative arm** recompiles the probe against a header copy with `LUAJIT_DISABLE_FFI` removed and must mismatch: `GG-LAYOUT-MISMATCH lib=6376 tu=6384` on every build [M].

**Stages 2-6** [S]: the shim (`-Wall -Wextra`, zero warnings) and jnlua.c compile; `eris_lj.o` carries the VM-features word, which must agree token by token with luajit.exe's behaviour (today `ffi0.lua52.gc64.fr2.dn0.le.p64.pack1.bit64`, and luajit.exe agrees [M]); the link; then the ABI surface is pinned (PE: exactly 87 `Java_*` + JNI_OnLoad + JNI_OnUnload = 89 names for dropin, 91/93 for additive; ELF: the `Java_*` count).

### 7.7 The Linux path

Same script, with these differences [S]:

- The copy is `luajit-linux-x86_64`, and `PICFLAG=-fPIC` reaches XCFLAGS and our compiles.
- `buildvm -m elfasm` writes lj_vm.S, which gcc assembles; the freshness gate adds lj_vm.S between buildvm_arch.h and lj_vm.o.
- The Makefile's unwind probe adds `-DLUAJIT_UNWIND_EXTERNAL`, which the `-D` allowlist permits.
- DynASM gets `-D SHADOW_STACK` from the compiler's CET default, and loses `-D WIN`.
- The binary is `luajit` and the library `libjnlua*52-linux-x86_64.so`.

Verified 2026-10-17 in WSL (Ubuntu 26.04.1, gcc 15.2.0, glibc 2.43): every gate printed the Windows line, and `negctl-bitop.sh` passed all 27 arms in 6 min 20 s [M] (logs/linux/). Both .so files still need GLIBC_2.38; the glibc floor round is next [M] (round 3 README).

## 8. Recipes

### 8.1 Adding or changing an operator end to end

Worked through round 3 (commit `2dd5f05`; evidence in [bench/runs/2026-10-17-bitop/](../bench/runs/2026-10-17-bitop/README.md)). An operator touches every stage of [2](#2-the-pipeline), and each stage has a file, a build gate, a test and a sabotage arm. Do the steps in this order; each later step assumes the earlier ones.

| step | what | round 3's file | held by |
|---|---|---|---|
| 0 | Write the semantics down, against PUC 5.3.6, with the user's decisions | `design/design.md` (U1-U10), `design/design-B.md` (decided) | the review workflow |
| 1 | The rules, once, with no Lua state | `native/luajit/oclj_bitop.h`, `oclj_num53.h` | NEGSHIFT, SARSHR, RANGE-HI arms |
| 2 | The parser's constant folding | `patch-bitop-parse.sh` (lj_parse.c) | t_fold; WRAP32-FOLD, NOINT-FOLD, INEXACT-FOLD |
| 3 | The interpreter's fast path | `patch-bitop-vm.sh` (vm_x64.dasc) | t_ops, fuzz V; WRAP32-INTERP, SHIFTMASK, INEXACT-INTERP, INEXACT-BNOT |
| 4 | The interpreter's slow path | `oclj_bitop_meta.c` + `patch-bitop-meta.sh` (lj_meta.c) | t_ops-str, coerce; STRCOERCE, ERROPERAND, INEXACT-SLOW |
| 5 | The recorder | `oclj_bitop_rec.c` + `patch-bitop-record.sh` (lj_record.c) | t_jit2, t_rec, gen; NOINT-JIT, SARCONST, INEXACT-JIT |
| 6 | The fold engine | `patch-bitop-fold.sh` (lj_opt_fold.c) + `oclj_bitop_fold.c` | gen, t_rec, fuzz U, p4v; NARROW, KFOLD64, SELFGUARD, WIDTH55, WSHR, WBAND, WADD0, WSHL0, FIX1 |
| 7 | The bytecode's meaning and the blob fingerprint | `patch-bitop-bcdump.sh` (0x80); `OCLJ_OPS_BIT64` in `oclj_features.h`; the `bit64` token in `serializer/eris_lj.c` | security FF12, the bitops gate's `dump=` field, stage 4; BCDUMP, WORDTOKEN |
| 8 | LuaJIT's own tools | `patch-bitop-jitlib.sh` (lib_jit.c), because `jit/bc.lua` decodes with these operators (P9) | the jit tools gate |
| 9 | The build | build-native.sh: re-copy, patch, marker counts, freshness gates for every include, the echo gate, the `-dM` feature gate, `bitop_wgate.c`, the bitops and jit tools gates | the gates' own fail-firsts |
| 10 | The tests | `test/native/run-bitop.sh` (matrix + provenance + `bitop_test.c`), `run-bitjit.sh` (gen, floor, fix1), `run-bitfuzz.sh` | [11](#11-verification-discipline) |
| 11 | The proof | fail-firsts on round 2's build (`failfirst/`, `failfirst2/`); `negctl-bitop.sh`, 27 arms, on Windows and Linux | [11.7](#117-negctl-one-line-sabotages), [11.8](#118-fail-first) |
| 12 | The evidence and the docs | `bench/runs/2026-10-17-bitop/` (README, design, logs, md5s); roadmap row 208; this guide | the review |

[S] for the files; [M] for the arms and catchers (negctl-bitop.sh header, logs/suite-native-2/, logs/linux-negctl/).

Lessons from round 3 that apply to the next operator:

- **Decide what a value the double cannot hold does** before writing code. U1-A (round) and U1-B (raise) need different guards, different tests and different arms; the rule went into one header and every C path calls it ([9.9](#99-one-source-of-truth-for-every-c-path)) [S].
- **The parser must decline to fold anything that raises**, so the error happens at run time with a line number, as 5.3.6's `validop` does [S].
- **Check the idioms people write, not single operators.** The design's claim that masked code matches 5.3 held for each operator and failed for the rotate idiom; the harness found it after every unit suite had passed (P16) [M].
- **A tool that uses the operators is a client too.** `jit/bc.lua` broke under 64-bit `>>` and made `-jdump` abort the traces it recorded, which looked like "the JIT does not compile bit operators" (P9) [M].
- **Same bytecode, new meaning means a new dump version**: `BCDUMP_F_BITOP` cannot carry it, because a folded constant leaves no bit opcode ([2.3](#23-bytecode-and-the-dump-version)) [M].

### 8.2 Writing a patch script

0. **Changing a file that a script already patches**, as the CRC32 follow-up does with `lj_opt_fold.c`: extend that file's script; never add a second one [S].
   - build-native.sh re-copies and patches each file once, and asserts exactly one `OC-LuaJIT (native/luajit/patch-bitop-` marker in it (`BITOP_PATCHES` and its loop, ~:696-722). negctl-bitop.sh rebuilds each patched file from the pristine one with that one `patch-bitop-<x>.sh` (~:661-668).
   - Add hunks, and update `NH`, `NADD`, `NDEL` and `verify_content`.
   - For `lj_opt_fold.c`, `verify_content` (patch-bitop-fold.sh ~:355-366) requires `oclj_bitwidth(` on exactly one line and the include above `simplify_conv_i64_num`. `simplify_conv_int_num` (~:1129) sits above that include, so a rule there needs the include moved up, or a forward declaration as in review1's `fold-a.diff`, and a rewritten `verify_content`.
   - Then update [1.2](#12-our-twelve-changes-to-luajit)'s row, [7.5](#75-the-patch-script-engine)'s NADD/NDEL list and [3.10](#310-the-two-rules)'s table.
1. **For a new file, copy the smallest round-3 script**, `native/luajit/patch-bitop-bcdump.sh` (231 lines), and rename it. Keep the hunk engine block byte for byte; check that its md5 matches the other seven ([7.5](#75-the-patch-script-engine)).
2. **Set the header variables**: `ME`, `MARK` (a string that appears only in your text, e.g. `OC-LuaJIT (native/luajit/patch-<name>.sh)`), `NMARK` (how often it appears in the output), `NH` (hunks), `NADD` and `NDEL` (what `diff -d` will count).
3. **Write each hunk as `o<h>` (upstream's text, copied exactly from the pristine file) and `n<h>` (yours)**. Each upstream text must occur exactly once in the pristine file; widen it until it does. Write a tab as `@T@`. Use no backslash anywhere in the script (P8): if C code needs one, restructure it, or put that code in an `oclj_*` file copied whole.
4. **Write `verify_content`** for what the hunks cannot say (one define, one label, an include in the right place).
5. **Write the file with a file tool**, LF, and check by bytes that it has no CR (P7).
6. **Run it** (`sh patch-<name>.sh <in> <out>`) on a scratch copy of the pristine file, then on its own output (the already-patched path). Check that the output has 0 CR bytes and the marker count is right. The reversal check (each upstream text put back must reproduce the input) runs inside the script after every apply (patch-bitop-bcdump.sh ~:222-227); there is no separate revert command [S].
7. **Make it fail first**: feed it a file in which the anchor occurs twice, and one where it is missing; both must refuse with exit 1 ([11.8](#118-fail-first)).
8. **Wire it into build-native.sh** like the round-3 seven: assert absent in the pristine tree, re-copy, assert absent, patch, assert the marker count before make, and add freshness gates for every object that includes a new file ([7.6](#76-build-nativesh-stage-by-stage)).

### 8.3 Changing one line of vm_x64.dasc

This is negctl-bitop.sh's machinery done by hand. Each step is what that script measured in its four vm_x64.dasc arms (WRAP32-INTERP, SHIFTMASK, INEXACT-INTERP, INEXACT-BNOT) on Windows and Linux [M]; the recipe as written was not run end to end.

```sh
# 0. A fresh scratch copy in $OCLJ_BUILD's layout (7.4), mtimes kept; record the canonical objects.
S=<fresh scratch dir>; W=$S/luajit-windows-x86_64        # never under build/, never reused
mkdir -p "$W" && cp -rp build/native/luajit-windows-x86_64/. "$W/" && cp -rp build/native/obj-windows-x86_64 "$S/" && cd "$W/src"
md5sum *.o host/*.o | tr -d '*' > ../canon.md5          # 77 lines
cp vm_x64.dasc ../vm_x64.dasc.canon                      # LF already: 0 CR bytes in the patched copy

# 1. One line, anchored, exactly once, every other line unchanged. Use negctl's sabotage():
#    awk with whole-line comparison, the old and new text passed in ENVIRON, @T@ for a tab,
#    no backslashes. Tag the new line, e.g. '    |  cmp RA, RA@T@@T@// PROBE-1: ...'.
#    Check it: diff ../vm_x64.dasc.canon vm_x64.dasc shows exactly one < and one >.

# 2. Make make see it, whatever the mtimes say:
rm -f host/buildvm_arch.h host/buildvm.o lj_vm.o lj_bc.o
mingw32-make BUILDMODE=static XCFLAGS= "Q=" -j4 > ../build.log 2>&1

# 3. Did it land?
grep -E -- '-o host/buildvm_arch[.]h vm_x64[.]dasc' ../build.log   # DynASM ran
grep -c -F 'PROBE-1:' host/buildvm_arch.h                         # 1: DynASM read the line
md5sum *.o host/*.o | tr -d '*' | diff ../canon.md5 -             # lj_vm.o and host/buildvm.o differ;
                                                                  # lj_bc.o too iff an offset moved; nothing else
nm -n lj_vm.o | grep -A1 ' lj_BC_BSHL$'                           # then objdump -d -M intel --start-address=...

# 4. Run the behaviour on ./luajit.exe (from src/, so jit/*.lua load): -joff against JIT on, and the catchers
#    (OCLJ_BUILD=$S with a fresh *_OUT, as in 7.4).

# 5. Put it back with a FRESH mtime, rebuild the same way, and require every object to reproduce:
cp ../vm_x64.dasc.canon vm_x64.dasc
rm -f host/buildvm_arch.h host/buildvm.o lj_vm.o lj_bc.o
mingw32-make BUILDMODE=static XCFLAGS= "Q=" -j4 > ../restore.log 2>&1
md5sum *.o host/*.o | tr -d '*' | diff ../canon.md5 -             # must print nothing
```

- If no object changed, the change never reached the code; negctl calls such an arm BROKEN [S]. A pure comment change, whether a `|//` line or a trailing `// ...`, emits no action bytes and leaves lj_vm.o unchanged [I].
- If an object outside the expected set changed, something else changed too (negctl's STRAY) [S].
- Step 5 is negctl's canon and restore check: on Windows and Linux every object reproduced [M] (logs/suite-native-2/negctl-bitop.log, logs/linux-negctl/).
- To ship the change, it goes into a patch script ([8.2](#82-writing-a-patch-script)), never into the build copy by hand (P44).

### 8.4 Adding a fold rule safely

1. **Find the key.** If a function already owns it, extend that function; a second `LJFOLD` line with the same key is a build error. Keep `LJFOLD` lines and rule bodies in `lj_opt_fold.c`. Helpers may live in an `#include`d file, but delete `lj_opt_fold.o` after editing one ([3.6](#36-how-an-instruction-is-folded), P4, P14).
2. **Return an existing ref, or change `fins` and return `RETRYFOLD`.** If the new instruction uses `fleft->op1` or `fright->op1`, put `PHIBARRIER` on that operand (requirement 2, [3.8](#38-what-a-rule-returns-and-upstreams-requirements)).
3. **Preserve the destination type**, including the case where an int ref stands in for an int64 (x64 `simplify_conv_sext`). Across a PHI, check the type of the returned ref (S4).
4. **Below a PHI-marked operand, read only opcodes, types and constants (S5).** Write down every way a value can enter the trace (S6).
5. **Compare modes under the right mask**: `MODEMASK` for identity, `SRCMASK`/`DSTMASK` for types. Never use `==` on a whole op2 unless upstream does (S3).
6. **Do not let a guard's own justification remove that guard (S2).**
7. **Grep every function you call for `LJ_HASFFI`** (P1).
8. **Prove the rule can fail.** Add a one-line sabotage arm to `negctl-bitop.sh` ([11.7](#117-negctl-one-line-sabotages)), caught by a suite that holds the rule's boundary, and see the catcher fail before you trust it ([11.8](#118-fail-first)). Use the generator (`test/native/bitop/gen.lua`) with a boundary template (S7) where the rule's consumers occur in generated loops; otherwise a floor suite built for it (the index fold needs `t_idx.lua` and `t_cnt33.lua`, because gen's index atoms mask with `& 7` and `& 15`; [11.4](#114-the-generator), [8.8](#88-where-the-crc32-follow-up-starts)).
9. **Run the option sets** ([11.3](#113-option-sets)), plus `-O-fold`, `-O-cse` and `-O-loop`, under which the results must still be correct, only slower.
10. **Read the IR** with `-jdump=+rsT`. Remember it prints KINT64s as the trace number and hides bit 0x400; use `traceir` when a mark matters ([12.6](#126-reading-the-exact-mark)).
11. **Run the three runners on the build**: run-bitop.sh, run-bitjit.sh with its fix1 part, and run-bitfuzz.sh (fuzz mode U is the fold engine's). Then run the whole negctl-bitop.sh sweep, canon included, from the main session. If the rule can return or build on a pre-roll ref, add a `p4v`-style loop that asserts trace events (a `stop`, 0 TYPEINS, JFORL), because differential tests cannot see TYPEINS (S4). For a speed rule, measure ([11.12](#1112-measuring-speed)).

### 8.4a Emitting instructions or a guard from a fold rule

No round-3 rule emits IR: both of its rules return an existing ref. review1's two prototypes do ([8.8](#88-where-the-crc32-follow-up-starts)), so these are the facts a rule that emits needs [S]:

- **`fins`, `fleft` and `fright` are `J->fold.ins`, `J->fold.left` and `J->fold.right`**, one slot per `jit_State` (lj_opt_fold.c ~:138-140). A nested `emitir` (`lj_ir_set` + `lj_opt_fold`) overwrites them. Copy every field you need into locals first, as `simplify_shiftk_andk` (~:1689) saves `fleft->ot` before its inner `lj_opt_fold(J)`; then set `fins` again and return `RETRYFOLD`, or return a ref.
- **New instructions land before the folded one**, so a guard emitted there precedes the value's uses (S1).
- **`J->chain[IR_LOOP] != 0` means the rule runs in `loop_unroll`'s copy**: LOOP is emitted before the copy starts (lj_opt_loop.c ~:286), and `loop_undo`'s rollback restores the chain on a retry (`lj_ir_rollback`). The pre-roll and side traces have no LOOP.
- **A guard emitted in the copy exits through the newest substituted snapshot**: `loop_unroll` calls `loop_subst_snap` (~:208) as the copy reaches each recorded snapshot's ref (~:315-316). S8 must hold from that snapshot's pc.
- **Requirement 2 applies to each new instruction**: none may take `fleft->op1` of a PHI-marked `fleft` without `PHIBARRIER` or a written argument (S4, S5).

### 8.5 Adding a recorder path

1. **Find the entry.** A bytecode is a case of `lj_record_ins` (lj_record.c ~:2227); a fast function is a `recff_*` in lj_ffrecord.c, tied to its library function by `buildvm -m recdef` [S]. Put the new code in an `oclj_*_rec.c` that the patched file includes after its `emitir` macros, and reduce the patched case to one call, as round 3 did [S].
2. **Decide at record time from the runtime values** (`rbv`, `rcv`): the recorder runs before the interpreter executes the instruction, so they are exactly this iteration's operands ([2.5](#25-hot-counting-and-trace-start)) [S]. For anything you will not compile, call `lj_trace_err(J, LJ_TRERR_BADTYPE)` (or `NYI`) before emitting IR: the trace aborts and the interpreter runs the instruction [S].
3. **Specialize with guards.** What you assumed from a runtime value must be guarded, because the next iteration may differ: round 3's variable shift count becomes `CONV int.num check` plus `ULT cnt, 64` ([8.6](#86-adding-a-guard)) [S].
4. **Emit through `emitir`**, so every instruction folds and CSEs; use `emitir_raw` only to bypass folding on purpose [S]. Make constants with `lj_ir_kint`, `lj_ir_kint64` and `lj_ir_knum` [S].
5. **Return what the slot holds.** Without DUALNUM every Lua number in a slot is `IRT_NUM`, so round 3 returns the double `d`, never the int64: `J->base[ra] = rc` puts it in the slot, and snapshots name it (S6) [S].
6. **After a side effect, set `J->needsnap = 1`**, so the next instruction starts with a snapshot and an exit never re-executes the effect ([4.3](#43-snapshots)) [S].
7. **Test** with `-jv` for the abort reasons, under every option set, against `-joff` and the PUC twin, and add a negctl arm per decision the path makes ([11](#11-verification-discipline)).

### 8.6 Adding a guard

1. **A guard is an instruction with `IRT_GUARD`** (`IRTG(o,t)`, `IRTGI(o)`). When it fails, the trace leaves through the newest snapshot and the interpreter resumes at that snapshot's pc ([4.3](#43-snapshots), [4.7](#47-exits)) [S].
2. **Make sure the interpreter does the right thing from there**: it re-executes from the snapshot's pc and must compute the guarded operation and fail the way 5.3.6 does (S8).
3. **Emit it right after the value it guards** (S1). Between them there must be no snapshot: nothing you call in between may reach `lj_snap_add` (`rec_comp_prep`, `rec_for`, `rec_itern` and `lj_record_ret` do; [4.3](#43-snapshots)) [S].
4. **Use a compare the backend emits**: `EQ`/`NE`/`LT`/`ULT`/... on int, i64 or num; a guarded CONV only from num to int (`asm_conv` ~:902). A number compare exits on NaN through `jpe` as well as the condition's own branch [S].
5. **Expect it to stay.** Guards are side effects to DCE ([3.1](#31-the-instruction-irins)), so a guard costs even when its value is unused. To remove one you need an independent proof, like the width rule, never a fact the guard itself establishes (S2). An invariant guard's copy in the loop body CSEs to the pre-roll's, which hoists it for free [S].
6. **Test the exit**: a loop that passes the guard more than `hotloop` times and then fails it, under `-Omaxside=0` (exit to the interpreter) and `-Ohotloop=1 -Ohotexit=1` (a side trace from the first exit); compare with `-joff` and PUC; see the exit with `-jdump=x`. Then add a negctl arm that removes the guard (round 3's INEXACT-JIT and NOINT-JIT) [S][M].

### 8.7 Reading a -jdump

```lua
-- guide1.lua
local acc = 0
for i = 1, 300 do
  local x = i * 2654435761         -- a double: MULVN is not narrowed
  acc = (acc ~ (x >> 3)) & 0xFFFF
end
print(acc)                         -- 16565, the same as -joff and PUC 5.3.6
```

The command is `luajit -jdump=+rsT guide1.lua`: `+rs` adds registers and snapshots, and `T` gives plain text, needed because `jit/dump.lua` turns colour on whenever `TERM` contains "color", even through a pipe (P12) [S][M]. Addresses (`0x22f6b370471`, the mcode addresses) change from run to run. The IR [M]:

```
....              SNAP   #0   [ ---- ---- ]
0001 rsi      int SLOAD  #3    CI
0002          u8  XLOAD  [0x22f6b370471]  V
0003          int BAND   0002  +12
0004       >  int EQ     0003  +0
0005 xmm8     num CONV   0001  num.int
0006 xmm8     num MUL    0005  +2654435761
0007 rcx      i64 CONV   0006  i64.num none
0008 xmm5     num CONV   0007  num.i64
0009       >  num EQ     0008  0006
0010 rcx      i64 BSHR   0007  +3
0011 xmm4     num CONV   0010  num.i64
0012 r8       i64 CONV   0011  i64.num none
0013       >  i64 EQ     0012  0010
0014 xmm3  >  num SLOAD  #2    T
0015 rdi      i64 CONV   0014  i64.num none
0016 xmm2     num CONV   0015  num.i64
0017       >  num EQ     0016  0014
0018 rdi      i64 BXOR   0015  0010
0019 xmm1     num CONV   0018  num.i64
0020 rax      i64 CONV   0019  i64.num none
0021       >  i64 EQ     0020  0018
0022 rdi    + i64 BAND   0018  +1
0023 xmm7   + num CONV   0022  num.i64
0024 rsi    + int ADD    0001  +1
....              SNAP   #1   [ ---- ---- 0023 ]
0025       >  int LE     0024  +300
....              SNAP   #2   [ ---- ---- 0023 0024 ---- ---- 0024 ]
0026 ------------ LOOP ------------
0027          u8  XLOAD  [0x22f6b370471]  V
0028          int BAND   0027  +12
0029       >  int EQ     0028  +0
0030 xmm15    num CONV   0024  num.int
0031 xmm15    num MUL    0030  +2654435761
0032 rbp      i64 CONV   0031  i64.num none
0033 xmm6     num CONV   0032  num.i64
0034       >  num EQ     0033  0031
0035 rbp      i64 BSHR   0032  +3
0036 xmm6     num CONV   0035  num.i64
0037 r15      i64 CONV   0036  i64.num none
0038       >  i64 EQ     0037  0035
0039 rdi      i64 BXOR   0035  0022
0040 xmm6     num CONV   0039  num.i64
0041 rbp      i64 CONV   0040  i64.num none
0042       >  i64 EQ     0041  0039
0043 rdi    + i64 BAND   0039  +1
0044 xmm7   + num CONV   0043  num.i64
0045 rsi    + int ADD    0024  +1
....              SNAP   #3   [ ---- ---- 0044 ]
0046       >  int LE     0045  +300
0047 rsi      int PHI    0024  0045
0048 xmm7     num PHI    0023  0044
0049 rdi      i64 PHI    0022  0043
```

`>` marks a guard and `+` a PHI operand. Slot 2 is `acc`, slot 3 the FORL control variable, slot 6 the visible `i`; slots 0-1 are the frame (`J->baseslot` = 1 + FR2) [S].

| ref | what it is, and who emitted it |
|---|---|
| SNAP #0 | `lj_record_setup`'s snapshot; resumes at `MULVN` [M] |
| 0001 | the control variable, narrowed to int by `rec_for_loop`; `C` = `IRSLOAD_CONVERT`, `I` = `IRSLOAD_INHERIT` [S] |
| 0002-0004 | CHECKHOOK, from `lj_record_setup` (~:2953-2973): a volatile load of `hookmask`, AND with `LUA_MASKLINE\|LUA_MASKCOUNT` (12), guard == 0 (P31; [docs/watchdog.md](watchdog.md)). The load is volatile, so `loop_unroll` emits it again at 0027-0029 [S] |
| 0005-0006 | `x` as a double (MULVN is not narrowed) [S] |
| 0007 | `oclj_rec_bitarg`: `i = CONV i64.num x`; "none" is `IRCONV_ANY`, an unchecked `cvttsd2si` (P38) [S][M] |
| 0008 | `back = CONV num.i64 i`, marked exact. The mark is invisible here; `jit.util.traceir` shows op2 = 0x05d5 (P30) [M] |
| 0009 | the operand guard: `x` is integral, in range and not NaN; it exits through #0 [M] |
| 0010 | the shift. The count is constant (a KSHORT-loaded slot), so 5.3.6's rule was decided at record time; `+3` is a `KINT` and prints correctly [S][M] |
| 0011 | `d`, marked (0x05d5): the double the BSHR's destination (bytecode slot 6, IR slot #8) would hold [M] |
| 0012 | the result guard's own check, marked (0x16ae), so the exact-mark rule leaves it alone [M][S] |
| 0013 | the result guard. `BSHR` by 3 bounds at 62 bits > 54, so the width rule kept it [S] |
| 0014-0017 | `acc` enters as a plain double: `sload` with `T`, then its operand guard [S] |
| 0018 | `BXOR 0015 0010`. The second operand is the BSHR's int64 itself: converting `d` (0011) folded to 0010 by the exact-mark rule, its back-conversion commoned with 0011, and `EQ.num 0011, 0011` was dropped [M][S] |
| 0019-0021 | BXOR's `d` and its guard; the bound is max(64, 62) [S] |
| 0022 | `BAND`. `+1` is the KINT64 0xFFFF, printed as the trace number (P3); the machine code says `and rdi, 0xffff` [M] |
| 0023 | BAND's `d`, with no guard: BAND with a non-negative constant bounds at 17 bits, so the guard's check folded to 0022 and `EQ.i64 0022, 0022` folded away [S][M] |
| 0024-0025 | `i + 1` and the loop test; SNAP #1 resumes after the loop [M] |
| SNAP #2 | the loop snapshot (`lj_record_stop`): acc = 0023, the control variable and `i` = 0024; resumes at `MULVN` [M] |
| 0026 | `LOOP`, from `loop_unroll`: everything below is the copy-substituted body [S] |
| 0039 | `BXOR 0035 0022`. `acc`'s SLOAD was forwarded (`fwd_sload`) to 0023, and converting 0023 folded across the PHI to 0022, which fix1 allows because 0022 is int64-typed. `acc`'s operand guard is gone from the loop [M][S] |
| 0043-0044 | BAND and its `d`, again with no guard [M] |
| 0047 | the control variable's PHI [S] |
| 0048 | `acc` as a double. It stays alive because the loop's snapshot names it (SNAP #3 restores slot 2 from 0044) [I] |
| 0049 | `acc` as an int64, what the next iteration's BXOR consumes: what the exact-mark rule buys [M] |

The pre-roll's first operator in machine code is the interpreter's fast path again, with exits in place of `->vmeta_bitop_pc` [M]:

```
test byte [rbx-0xf07], 0xc   ; 0002-0004 CHECKHOOK, fused
jnz ->0
cvttsd2si rcx, xmm8          ; 0007 CONV i64.num
xorps xmm5, xmm5             ; 0008 CONV num.i64 (asm_conv clears the register first)
cvtsi2sd xmm5, rcx
ucomisd xmm5, xmm8           ; 0009 EQ.num: NaN is unordered
jpe ->0
jnz ->0
shr rcx, 0x03                ; 0010 BSHR
xorps xmm4, xmm4             ; 0011 d
cvtsi2sd xmm4, rcx
cvttsd2si r8, xmm4           ; 0012 the guard's check
cmp r8, rcx                  ; 0013 EQ.i64
jnz ->0
...
and rdi, 0xffff              ; 0022 BAND (the IR printed "+1")
```

**Reading caveats** [S][M]:

- **KINT64 constants print as the trace number** (P3). Read the machine code (`and rdi, 0xffff`) or the source instead.
- **The exact mark is not printed** (P30). Use `jit.util.traceir(tr, ref)` and test op2 against 0x400 ([12.6](#126-reading-the-exact-mark)).
- **`i64.num none` is the unchecked conversion** (P38).
- **`KINT` constants print correctly**: the shift count `+3` and the CHECKHOOK `+12` are `KINT`s.
- **A guard's exit resumes at its snapshot's pc**, here `MULVN`, not at the operator (P40). `jit.util.tracesnap(tr, sn, true)` gives each snapshot's pc.

### 8.8 Where the CRC32 follow-up starts

Roadmap row 209, the guide's first real test: win back table-driven CRC32 (7.2 ns per byte now, against 2.8-2.9 with the old 32-bit operators: `bench_bit2.lua`'s `crc-table` field in `bench/runs/2026-10-17-bitop/logs/bench/bench.txt`) [M]. What this guide already knows:

- **review1's material is not in the repo.** Archive what you reuse in the round's `bench/runs/` directory. The record is `bench/runs/2026-10-17-bitop/design/review1-results.json`, keys `review:tablefold` and `verify:tablefold:0`, which names the work directory, `C:/Users/astro/claude-tmp/oclj/r3/review/` on this machine [S]:
  - `tablefold/`: `fold-a.diff` (the index fold), `fold-rg2-over-a.diff` (rg2, on top of fold a; see below), `t_idx.lua` (md5 `6bd231131395`), `bench_tf.lua`, `bench_tf2.lua`, its own `crct.lua`, and `dumps/`;
  - `verify-tablefold-0/suites/`: `t_cnt33.lua` (`ac6597e6a7e9`) and `refidx.lua` (`01761d83168f`, t_idx's PUC reference).
  - All of it was written against the U1-A prototype b1. On the shipped build, `t_idx.lua` runs with JIT = `-joff` (432 lines, 0 differing) and its 24 `w10` lines raise the 53-bit error; `refidx.lua` has no X rule and differs from `-joff` in exactly those 24 lines, so it needs the twin treatment ([11.2](#112-the-puc-twin)) before it can serve as a reference; `t_cnt33.lua` runs with JIT = `-joff` [M].
- **Today's loop, read from the shipped build** [M]. `crcprobe.lua`, run with `-jdump=+rsT`; JIT, `-joff` and PUC 5.3.6 all print 3012454781; the loop is trace 8:

  ```lua
  local T = {}
  for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
      if c & 1 == 1 then c = (c >> 1) ~ 0xedb88320 else c = c >> 1 end
    end
    T[i] = c
  end
  local s = string.rep("The quick brown fox jumps over the lazy dog. ", 64)
  local crc = 0xffffffff
  local len = #s
  for k = 1, 20000 do
    local byte = s:byte((k - 1) % len + 1)
    crc = T[(crc ~ byte) & 0xff] ~ (crc >> 8)
  end
  print(crc ~ 0xffffffff)
  ```

  crc is already carried as an `i64 PHI`, through the exact-mark rule. Each iteration of the loop body keeps:
  - three result guards: `crc ~ byte` (bound 64: crc's width comes from table values and a stack slot, and the byte scores 64, [3.11](#311-oclj_bitwidth-the-bound)), `crc >> 8` (bound 57) and the final BXOR (bound 64);
  - one operand guard on the table value (`CONV i64.num`, `CONV num.i64`, `EQ.num`);
  - the guarded index `int CONV <d> int.num index`. The BAND's own guard is gone (bound 9).
- **What is on the dependency chain** [M from the mcode; the cost split is I]. Later operators read each result's int64 directly (`and rbp, 0xff` reads the xor's `rbp`), so the three result guards run beside the chain. On it are the index round trip (`cvtsi2sd xmm7, rbp; cvttsd2si ebp, xmm7`; its check, `cvtsi2sd` and `ucomisd`, only branches) and the table value's `cvttsd2si`. review1's diagnosis (crc "carried as a double PHI", rounding round trips on the chain) and its 14.10 → 10.85 → 3.55 ns/byte come from the U1-A prototype b1, not from this build. Re-measure both changes on this build before ranking them.
- **The table-index fold** (`fold-a.diff`) lives in `simplify_conv_int_num`, the owner of `LJFOLD(CONV CONV IRCONV_INT_NUM)` (lj_opt_fold.c ~:1128-1129). It turns `CONV int.num (CONV num.i64 y)` into the unguarded `CONV int.i64 y` by `RETRYFOLD` when `oclj_bitwidth(y)` ≤ 32, and never across a PHI (requirement 2: it builds a new instruction on `fleft->op1`) [S].
  - The key ignores the check mode, so the fold reaches every consumer that narrows a bit result to an int: table keys (`lj_opt_narrow_index` ~:451, from `rec_idx_key` ~:1438; INDEX), library integer arguments (`lj_opt_narrow_toint` ~:466; ANY: `string.byte`, `string.sub`), and round 3's own variable shift count (the `CONV int.num check` before `ULT cnt, 64`, oclj_bitop_rec.c ~:141) [S].
  - The bound must stay at 32: an int32 needs 32 bits, where the width rule allows 54 for a double. With 33, `t_idx.lua` sees the index and library-argument cases (21 lines) and no other suite does, fuzzer included. The verifier also found the shift count miscompiled, and t_idx has no such consumer: `0x7fffffff >> (y ~>> 31)` with y = -(2^32-5)*2^31 should give 0 and gave 67108863 compiled (`t_cnt33.lua`) [M review1, `verify:tablefold:0`].
  - Ship both suites, and list both as catchers of the WIDTHIDX33 arm.
  - Write its `CONV int.i64` mode with no check bits ([5.1](#51-our-ir-in-x64)), and change lj_opt_fold.c's patch script to admit a second `oclj_bitwidth` caller above the include ([8.2](#82-writing-a-patch-script), step 0).
- **The rg2 range guard** (`fold-rg2-over-a.diff`): a speculative guard in the integer domain, `(y ~>> 53) + 1 <= 1` unsigned, in the loop body only, in place of the round trip through a double [S]. The shift is arithmetic (`IR_BSAR`, as the prototype emits it), which makes the test true exactly for y in [-2^53, 2^53); with Lua's logical `>>`, as roadmap row 209 wrote it until this guide's commit, every negative y would fail. It replaces the result guard's shape (`CONV i64.num` marked + `EQ.i64`, right after `d`, exiting through the newest snapshot; [2.6](#26-the-recorder)), so S1, S2 and S8 apply.
  - The prototype predates fix1 and U1-B. It sits after the width rule but outside fix1's condition (its context line is the old `(1 || !irt_isphi(fleft->t))`). For a PHI-marked `fleft` whose `op1` is int-typed (p4v's `x = i | 0`), it returns an int ref into an i64 PHI, which is TYPEINS again (S4), and it builds `BSAR y, 53` and the rest on `fleft->op1` across that PHI (requirement 2) [S].
  - Port it inside fix1's condition, or test `irt_isi64(IR(y)->t)` and the PHI case itself; keep run-bitjit.sh's fix1 part among its catchers.
  - It emits a guard from inside a fold during `loop_unroll` ([8.4a](#84a-emitting-instructions-or-a-guard-from-a-fold-rule)).
  - It speculates. Under U1-B a value of 2^53 or more fails the guard and exits even when it is exact (the prototype's comment, "the interpreter then rounds", is U1-A's). So time the loops where it fails, not only CRC32: review1 measured, in the loop-body-only form, xorshift64 at 24.1 ns/it and `h ~ (i<<40) ~ (h>>3)` at 8.9, against 167.7 and 142.9 when the guard is emitted everywhere (variant rg) [M review1].
  - It does not help bit-serial CRC (88.85 against 91.5 ns/byte), whose hot code is in side traces with no LOOP [M review1]. review1 judged it not small enough for round 3, and it has no negctl arm [S].
- **A smaller win, not for this benchmark**: scoring a u8 operand 9 bits and a u16 17, instead of today's 64 (roadmap row 211 (1); [3.11](#311-oclj_bitwidth-the-bound)). review1 measured the gap on crc masked each byte: 11.20-11.30 ns/byte, against 8.25-8.30 with `byte & 0xff` (b1 plus fold a). It does not help the unmasked CRC, where crc's width is unknown anyway [M review1].
- **What it must ship with**: floor suites at both bounds (`t_idx.lua` and `t_cnt33.lua`, adapted to U1-B), generator atoms at the bounds behind a new `GENMODE` ([11.4](#114-the-generator)), a negctl arm per change, the option sets, trace-event checks for anything that can cross a PHI, and a measurement ([11.12](#1112-measuring-speed)) against today's 2.9 ns per byte (roadmap row 209).

## 9. Invariants and soundness arguments

Each pattern gives a rule, the reason it holds, round 3's instance, and what holds it in place. The arguments are the ones settled by review1 (the width fold; `design/review1-results.json`), the implementation review (`design/review2-results.json`) and `design/design-B.md` §3.4. They are numbered S1-S8 so the rest of the guide can cite them.

### 9.1 S1. Guard immediately after the value

- **Rule.** Emit the guard that establishes a property as the very next instructions after the value. Then every use, which is emitted later, comes after the guard.
- **Why it holds** [S]:
  - A trace is straight-line code, the pre-roll and then the loop body, so "earlier in trace order" means "executed first".
  - The loop copy keeps the order, and a hoisted guard's pre-roll copy comes before the whole loop.
  - A value carried by a PHI passed its guard in the pre-roll or in the previous iteration.
  - Store-to-load forwarding returns the stored ref, whose guard came before the store.
  - No snapshot sits between the value and its guard, because `oclj_rec_bitop` calls nothing that adds one, and the destination slot is written after the operator's IR [S][I]. This is a property of the path, not of the recorder: `lj_record_ins` adds a snapshot at an instruction's start when `J->needsnap` is set (~:2284), but some recorders add one mid-instruction, `rec_comp_prep` before every comparison guard (~:2202) among them ([4.3](#43-snapshots)). A new path must call none of them between a value and its guard.
- **Instance.** `oclj_rec_bitop` emits `d`, then `back`, then `EQ.i64`, and an operand's `back` and `EQ.num` the same way.
- **Held by.** INEXACT-JIT (no result guard at all) is caught by gen with at least 511 cases per seed [M].

### 9.2 S2. A fact that a guard justifies must not remove that guard

- **Rule.** A fold may use "past the guard, P holds". It must never use that fact to delete the guard that makes P hold. Only an independent proof may delete the guard.
- **Instance: the exact mark.** The guard's own `CONV i64.num d` carries the mark, and the exact-mark rule requires the outer CONV to be unmarked. So only the width rule, a range proof that reads no guard, removes guards [S].
- **Held by.** The SELFGUARD arm lets the exact-mark rule fold the guard's own check. Every result guard then disappears, and inexact results flow on as rounded doubles; gen catches it with at least 516 cases per seed [M].

### 9.3 S3. A mark that changes what folds may assume belongs in CSE identity, and outside the fold key

- **Rule.** If a bit on an instruction licenses a fold, CSE must not merge marked and unmarked twins, or a request without the licence can get back an instruction that has it. Keep the bit out of the fold key, so existing rules still apply.
- **Instance.** Bit 0x400 is inside `MODEMASK` and outside `0x3ff` ([3.9](#39-cse-and-why-the-exact-mark-is-bit-0x400)).
- **How to check a new bit** [S][M]: grep every use of the field; classify each use as a mask (safe) or an equality (which must not involve your bit); check the backend and jit.dump; show the bit with `traceir`.

### 9.4 S4. Keep types stable across iterations

- **Rule.** A fold that can run in the loop copy and return a pre-roll ref must return a ref of the folded instruction's own type [S]. `loop_unroll` repairs only int↔num and lets I8..INT mismatches through; anything else raises TYPEINS, the loop is retried by recording further, the trace aborts, and after 11 aborts the loop is blacklisted ([4.4](#44-type-instability-typeins-retry-blacklist)).
- **Instance.** fix1. On x64, `simplify_conv_sext` returns an int ref for an i64 conversion, so a fold that crosses a PHI and returns `fleft->op1` must check `irt_isi64(IR(fleft->op1)->t)` ([4.5](#45-fix1-the-worked-case)).
- **Detection.** This is a speed bug, not a wrong value [M review1], so differential tests cannot see it. Assert on trace events instead: `p4v.lua` counts TYPEINS aborts and reads the loop's opcode (JFORL or IFORL), with no timing bound [S].

### 9.5 S5. A fold that crosses a PHI may depend only on opcodes, IR types and constants

- **Rule.** A PHI-marked operand's definition is the pre-roll's, so it describes iteration one. Anything a fold reads from it must hold in every iteration.
- **Why it holds** [S][I]: IR types do not change between iterations (S4); constants are the same in every copy; each instruction in the loop copy computes the same opcode on the copies of its operands; folds and CSE preserve values. By induction over the pre-roll's DAG, a bound computed from opcodes, types and constants covers every iteration's value, which is exactly the set of values the PHI carries.
- **What the code does not rely on**: "a loop copy's bound is at most the pre-roll's" (design.md §3.5); review1 replaced that argument.
- **Requirement 2 still applies.** A *new* instruction built on `fleft->op1` needs `PHIBARRIER`; for that reason review1's table-index fold excluded a PHI-marked `fleft` ([8.8](#88-where-the-crc32-follow-up-starts)).
- **Instance.** `oclj_bitwidth` reads `o`, the `irt_*` types and KINT64/KINT values, never a runtime value.
- **Held by.** The gen arms hold only local rule errors (WIDTH55, WSHR, WSHL0, WBAND and WADD0 are all caught [M]). A sabotage that broke iteration invariance would have to read live values, which the project's rules exclude, so that property rests on reading the source [S review1].

### 9.6 S6. List every way a value can enter the trace, and score each one from its type

- **Rule.** A bound or assumption must hold for values from outside the trace, and that list belongs in the rule's comment. For round 3 [S][M]:

| entry | IR | bound |
|---|---|---|
| a double slot, table load or upvalue load | `num SLOAD/ALOAD/HLOAD/ULOAD`, through `CONV i64.num` | 64 |
| a narrowed int (the loop index, `SLOAD ... C`) | int-typed, used directly after the LEFTFOLD | 33 |
| a u8/u16 load (`string.byte`) | `u8 XLOAD`, used directly after `simplify_conv_sext`'s u8/u16 LEFTFOLD | 64 |
| an int through `CONV i64.int` | | 32 with SEXT, 33 zero-extended |
| a parent trace's snapshot (in side traces) | `lj_snap_replay` (lj_snap.c ~:508) emits an `SLOAD PARENT` of the parent ref's type; for bit results, snapshots hold only `d` (num) or ints | 64 / 33 |
| a forwarded store | the stored ref itself: a marked `d` whose guard came before the store | (S1) |
| a PHI | the pre-roll definition | (S5) |

- **Why the list matters.** Round 3's first comments said every outside value enters through a CONV that scores 64. The implementation review found that int-typed values enter directly. The conclusion survived only because the bound of 33 comes from the type alone [S review2].
- **The int64 never crosses a trace boundary**: slots and snapshots hold the double `d`, so a side trace re-converts it behind a fresh guard ([4.8](#48-side-traces)) [S][M]. That snapshots hold only `d` or ints is read from the recorder and seen in every probe's SNAP lines, not proven for every recorder path [I].

### 9.7 S7. Test at the boundary, with values the lexer can actually spell

- **Rule.** Hold each threshold with a case one step past it, built from operands that really are what the test assumes.
- **Instances** [M review1]:
  - WIDTH55's boundary is tested this way.
  - t_jit2's `rec-m54` was vacuous: its mask `0x3fffffffffffff` has 54 significant bits, so the lexer reads it as 2^54, and x was 0 in all 400 iterations (P47).
  - Four of t_rec's nine masks did not act as masks either.
  - A claim about which results are exact must be checked on chained idioms: the rotate raises for n in 1..10 (P16).
- **Shapes.** Write tests for the shape left after other folds: `simplify_shiftk_andk` rewrites `(x & m) << k`, so a BSHL test needs an operand that is not a BAND ([3.11](#311-oclj_bitwidth-the-bound)).

### 9.8 S8. Know what an exit re-executes

- **Rule.** A guard must exit to where the interpreter recomputes the guarded operation and fails the way 5.3.6 does.
- **Instances:**
  - **Same iteration, same message.** Bit-operator guards exit through the newest snapshot, whose pc is at or before the operator; the instructions in between are re-executable ([4.3](#43-snapshots)), and the interpreter raises in the same iteration with the same message. Measured in [4.7](#47-exits), and by review1 on the U1-A prototype: 25 200 bad-operand placements, with PUC = `-joff` = JIT = `-Ohotloop=1` [M].
  - **Record-time abort.** The recorder aborts when a result is inexact now (`oclj_rec_bitop`), because a trace recorded through it would always leave [S].
  - **No catcher for that abort.** Removing it gives the same raises and changes only the abort's reason (INEXACT-RECABORT; [2.6](#26-the-recorder)) [M].

### 9.9 One source of truth for every C path

- **Rule.** When the parser, the slow path and the recorder each compute an operator in C, they call one function, so they cannot disagree. The fast path in DynASM and the IR cannot call it, so they are tested against it [S].
- **Instance.** `oclj_bitop.h` holds `oclj_bitop64`, `oclj_bit2num` and the shift rules with no Lua state; `foldbitop`, `oclj_meta_bitop` and `oclj_rec_bitop` all call them; `oclj_num53.h`'s readers are shared with `string.pack` [S].
- **Held by.** The arms in the header (NEGSHIFT, SARSHR, RANGE-HI) break all C paths at once and are caught by the matrix and the fuzzer, which compare against PUC [M].

### 9.10 The interpreter's own invariants

- **Store the result last**, after every check that can exit; the slow path then recomputes from untouched operands ([6.5](#65-what-a-handler-may-clobber)) [S].
- **Honour each slow-path label's register contract**, or add a label that reloads (`->vmeta_bitop_pc`) ([6.7](#67-round-3s-checks-instruction-by-instruction)) [S].
- **No push or pop in a handler, and BASE reloaded after every C call** ([6.5](#65-what-a-handler-may-clobber), [6.6](#66-calling-c-from-the-interpreter)) [S][I].
- **Never remove the CHECKHOOK lines** near the head of every trace and after its `LOOP`; the watchdog depends on them (P31, [docs/watchdog.md](watchdog.md)) [S].

## 10. Pitfalls

Each entry gives the symptom, the cause with its evidence, and the fix; where a section already holds the evidence, the entry points there. P1-P18 were known going into this guide (the brief's sixteen, its tenth split three ways); P19 onward were found in round 3's evidence or by this guide's probes. The numbers are stable: cite them, and append new ones at the end.

| area | pitfalls |
|---|---|
| LuaJIT internals without FFI | P1, P3, P9 |
| IR, folds, loops, exits | P2, P29, P32, P38, P40, P41, P42 |
| reading dumps and tools | P10, P11, P12, P30, P31, P35, P36, P39, P48 |
| the build | P4, P5, P13, P14, P15, P19, P43, P44, P45, P46 |
| text, shells and line endings | P7, P8, P18, P20 |
| tests and measurement | P6, P16, P17, P21, P22, P23, P24, P25, P26, P27, P28, P33, P34, P37, P47 |

**P1. Without FFI, the int64 constant folds are stubbed, and one returns a wrong value.** *Symptom:* `BAND`, `BOR` or `BXOR` of two KINT64 constants folds to its left operand, with no error; most other int64 folds return FAILFOLD, which aborts the trace [S]. *Cause:* `kfold_int64arith` (lj_opt_fold.c ~:368) compiles its bit cases only `#if LJ_HASFFI` (~:376); the operator falls into `default: lj_assertJ(0, ...)`, which a release build compiles to `((void)J)` (lj_jit.h ~:522-525), and returns k1. The seven stubs: `kfold_int64arith` ~:376, `kfold_int64shift` ~:432, `kfold_bnot64` ~:444, `kfold_int64comp` ~:471, `kfold_int64comp0` ~:492, `simplify_andor_k64` ~:1746, `reassoc_intarith_k64` ~:1794 [S]. KFOLD64 (the first stub put back) is caught by fuzz mode U (431-436 mismatches) and t_rec (4-14 lines per seed) [M]. *Fix:* round 3 turns the seven into `#if 1` ([3.10](#310-the-two-rules)). Before relying on a LuaJIT function, grep it for `LJ_HASFFI`, `LJ_DUALNUM` and `LJ_GC64` [I]; `narrow_convert` hid an assumption of the same kind (NARROW) [S].

**P2. TYPEINS: a loop-carried value whose IR type changes is unrolled, aborted, then blacklisted.** *Symptom:* a loop never compiles; `-jv` shows "persistent type instability" aborts, then silence, or later `blacklisted at` lines from other recordings (P39). Or a loop compiles with its body recorded twice [S][M]. *Cause:* `loop_unroll` raises `LJ_TRERR_TYPEINS` for any type change it cannot repair: int against i64, true against false, str against num ([4.4](#44-type-instability-typeins-retry-blacklist)). A build without fix1 read `traces=0 typeins=11 loop=IFORL` for 7 of the 8 p4 loops [M] (`impl-C2.json`). *Fix:* never hand a PHI a ref of a different IR type from the pre-roll's (S4, fix1); test such loops with trace events and the JFORL/IFORL opcode, never with a timing (`p4v.lua`) [S].

**P3. `jit.util.tracek` and `-jdump` print a KINT64 constant as the trace number.** *Symptom:* `i64 BAND 0011 +1` where the mask is 0x3FFFC, `BOR 0015 +1` where the constant is 2^32; in trace 2 the same masks print `+2`; in trace 1 a mask looks exactly like a real constant 1 [M]. *Cause:* `lj_ir_kvalue` (lj_ir.c ~:372) has a KINT64 case only `#if LJ_HASFFI` (~:385-391), so without FFI it writes nothing, and `jit_util_tracek` (lib_jit.c ~:319) returns the slot that still holds its first argument, the trace number [S][M]. Walking every `k` with `tracek` also hits the second slot of each 64-bit constant (GC64) [M][I]. Roadmap row 206 records it; values are unaffected [S]. *Fix:* read an int64 constant from the `m` dump (`and rdi, 0x0003fffc`, `mov rcx, 0x0000000100000000`) or from the source; walk constants from IR operands, as dump.lua does [M]. The real fix, a non-FFI KINT64 case in `lj_ir_kvalue`, is not done [I].

**P4. `Makefile.dep` does not know the `#include`d files, so a build can be stale.** *Symptom:* you edit an `oclj_*` file, run make, nothing is recompiled, and the old code runs [M]. *Cause:* `Makefile.dep` is upstream's `gcc -MM` output and mentions no oclj file; a .dasc whose mtime is older than `buildvm_arch.h` is equally invisible ([7.2](#72-dependency-traps)) [M]. *Fix:* delete the including objects yourself ([7.4](#74-running-make-by-hand)); build-native.sh runs `make clean` and gates each object's freshness against every file it includes [S].

**P5. `Q=.` is not `Q=`.** *Symptom:* commands named `.host/minilua.exe`, `.host/buildvm.exe` and `.gcc`, which do not exist; or, with the default `Q=@`, no command lines in the log for the gates to match [M][S]. *Cause:* `Q` (Makefile ~:625) is pasted in front of every command; `mingw32-make -n BUILDMODE=static Q=.` printed `.host/minilua.exe ../dynasm/dynasm.lua ... vm_x64.dasc` and `.gcc ... host/buildvm.c` [M]. A `Q=` at the end of a sentence in prose reads as `Q=.`, as in one implementer's report [S]. *Fix:* pass `Q=` (empty), and write it in a code span [S].

**P6. Hot counters are shared and penalties are random, so "it compiles after N iterations" is approximate.** *Symptom:* exact counts of iterations, traces or aborts differ between processes or between loops; negctl's JIT catchers' margins vary from run to run [M]. *Cause:* the start value is fixed (recording began at iteration 56 in 6 of 6 processes [M]), but the 64 counters are hashed by pc, and each abort penalty adds 4 random bits from a per-state PRNG; one loop's 11th abort came between iterations 38,215 and 42,958 across 6 processes ([2.5](#25-hot-counting-and-trace-start)) [S][M]. *Fix:* option sets and coverage gates, not exact counts; gate negctl catchers on "nonzero"; find where a trace starts from its `start` event; `jit.flush()` between phases; give each measured loop its own prototype [S][I].

**P7. The pristine tree is CRLF, Windows Python writes CRLF, and Git Bash's awk and grep hide CRs.** *Symptom:* an anchor never matches, a patched file turns CRLF, or a CR count says 0 when there are CRs [M]. *Cause:* the pristine checkout is CRLF (lj_opt_fold.c 2653 CR / 2653 LF); Python 3.13 `open(p, 'w')` wrote CR LF, and `newline=''` wrote LF; Git Bash's awk drops a line-end CR unless `-v BINMODE=1`, and `grep -c $'\r'` counts 0 without `-U` ([7.3](#73-line-endings-and-the-git-bash-instrument)) [M]. *Fix:* anchor patch scripts on CR-stripped text and write LF; in Python use `newline=''` for reading and writing; count CRs by bytes (`open(f,'rb').read().count(13)`, `grep -c -U`, `od -c`) [S][M].

**P8. Heredocs eat backslashes in the agent's shell tool, even when quoted.** *Symptom:* `\b` in a regex becomes a literal backspace, or a doubled backslash a single one, silently [M]. *Cause:* through the shell tool, `cat <<'EOF'` turned a doubled backslash before B into a single one, and `python - <<'PY'` with a doubled backslash between `a` and `b` in a string literal gave `'a\x08'` [M]; one negctl probe's awk edit lost its backslashes and the build failed [M] (`impl-C3.json`). That the collapse happens in the tool's transport rather than in bash is inferred [I]. *Fix:* write scripts with a file-writing tool; write patch scripts with no backslashes and no tabs (`@T@` for a tab) [S].

**P9. `jit.util.funcbc` returned signed words, and `jit/bc.lua` broke under 64-bit `>>`.** *Symptom:* before change 12, `luajit -bl` raised at the first forward jump, FORI or negative KSHORT, and `-jdump` printed "VM handler failed: ./jit/bc.lua:68: result of '>>' has more than 53 significant bits" and aborted every trace it recorded [M]. *Cause:* `jit_util_funcbc` used `setintV` (lib_jit.c ~:212-220) and `jit/bc.lua` decodes with `(ins >> 8) & 0xff`; `jit/dump.lua` reads a snapshot entry's slot as `sn >> 24`, so `tracesnap` had the same problem [S]. Re-signing `funcbc`'s words through `LUA_INIT` reproduces both symptoms on today's build [M]. *Fix:* change 12 returns unsigned numbers; the jit tools gate holds `-bl` and `-jdump` [S]. Any tool that shifts bytecode words must mask them first [I].

**P10. `luajit -b` exits 0 when the listing raises.** *Symptom:* a script that runs `luajit -bl` and checks `$?` passes while stderr holds a Lua error [M]. *Cause:* `dobytecode` (luajit.c ~:391-406) returns -1, and `main` fails only for a status above 0 (~:599); bcsave's own checks (missing input, usage, "FFI library required") call `os.exit(1)` [S][M]. *Fix:* gate on empty stderr and on the number of listed lines, as the jit tools gate's `blerr` and `bl` fields do [S].

**P11. `jit.attach` keeps one handler per event.** *Symptom:* `-jv` or `-jdump` prints nothing once a probe attaches its own `"trace"` handler; `-jv -jdump=tT` prints only dump's lines, and `-jdump=tT -jv` only `-jv`'s [M]. *Cause:* `jit_attach` (lib_jit.c ~:123) stores one handler per event name; attaching A then B to `"trace"` called A 0 times and B twice [S][M]. *Fix:* count events in your own handler and print `-jv`-style lines from it; one `-j` module per run; detach with `jit.attach(f)` [S].

**P12. `-jdump=T` only picks plain text, and colour follows `TERM`.** *Symptom:* `-jdump=T` prints the whole default dump, not just trace lines; ANSI codes appear in a log [S][M]. *Cause:* `dumpon` (dump.lua ~:677-690) strips `T`, `A` and `H` from the mode, and an empty rest keeps the default `t b i m`; the colour default comes from `TERM` (ANSI when it contains "color"), and from `COLORTERM` only when `TERM` is unset, whatever the redirection; Git Bash sets `TERM=xterm-256color` [S][M]. *Fix:* `-jdump=tT` for trace lines, `-jdump=+rsT` or similar for logs; always include `T` when grepping or diffing [S].

**P13. `luajit.exe`'s md5 changes on every link.** *Symptom:* two identical builds have different exe md5s. *Cause:* the PE header carries the link time (`objdump -p`: `Time/Date Sat Oct 17 12:29:30 2026`) [M]. *Fix:* compare objects, as `logs/builds-2/natives.md5` and `objects-changed.txt` do [S].

**P14. A `vm_x64.dasc` edit also changes `lj_bc.o`, and `buildvm -m folddef` reads only `lj_opt_fold.c`'s LJFOLD lines.** *Symptom:* an object you did not expect to change does; a fold rule moved into an `#include`d file is silently never registered [M][S]. *Cause:* `lj_bcdef.h` holds the handler offsets, which a 32-bit `and` without REX.W moved [M] (`impl-C3.json`); `buildvm_fold.c` (~:197-220) scans `lj_opt_fold.c` alone for lines that begin `LJFOLD` ([7.2](#72-dependency-traps)) [S]. *Fix:* a `.dasc` change reaches `lj_vm.o`, `lj_bc.o` and `host/buildvm.o`; keep every `LJFOLD` line and rule body in `lj_opt_fold.c` at column 0 and move only helpers out [S].

**P15. bash's `-nt` is true when the second file is missing.** *Symptom:* a freshness gate passes against a file that does not exist. *Cause:* `[ exists -nt missing ]` is true in bash 5.3.15 and in `sh` [M]; build-native.sh ~:801 says so [S]. *Fix:* `[ -f "$src" ] && [ "$obj" -nt "$src" ]` [S].

**P16. Claims about exactness must be checked on chained idioms and products, not single operators.** *Symptom:* the design said that only `>>` of a negative number is inexact with ordinary operands, and that code masked to 32 bits matches 5.3; both hold for one operator and fail for chains [M] (round 3 README). *Cause:* in 5.3's rotate, `((a >> n) | (a << (32 - n))) & 0xFFFFFFFF`, the `|` joins the pieces into up to 64 - n significant bits before the mask; for a = 0xFFFFFFFF or 0xDEADBEEF it raises for n = 1-10, for a = 0x80000001 never [M] (`design/rotate/`). The harness found it in `p1-sha256` after every unit suite passed [M] (`logs/harness-prefix/`). FNV-1a's double product passes 2^53 before the mask, a wrong value without an error [M] (`fix-results.json`, R3-docs). *Fix:* test real idioms with random words, as the generator and the harness do; write the masked forms (`(a >> n) | ((a << (32 - n)) & 0xFFFFFFFF)`); limit any exactness claim to sums and products below 2^53 [S].

**P17. Never edit a script that a running chain executes.** *Symptom:* a chain dies after a long run with "syntax error near unexpected token", exit 2, and its verdict is lost [M] (round 3 README, deviation 9). *Cause:* `sh` reads a script incrementally; `run-bitfuzz.sh` was edited during a 50-seed campaign, and the shell read the new file at a stale offset [M]. *Fix:* finish or copy the running scripts first, and tell agents which files are in use [S].

**P18. Surprising readings are usually the instrument: CRLF from Windows stdout.** *Symptom:* false differences between outputs identical apart from line endings. *Cause:* `luajit.exe -e "print(1)"` and `lua.exe -e "print(1)"` each write 3 bytes, 1 of them a CR; one ad-hoc diff showed 25 false differences [M] (`impl-C2.json`). *Fix:* `tr -d '\r'` on every Windows output before comparing, as each runner's `run()` does; more generally, [11.9](#119-instrument-first) [S].

**P19. `build/native/luajit_build.log` is the last platform's build.** *Symptom:* the DynASM line lacks `-D WIN` and shows `host/minilua` without `.exe` [M]. *Cause:* the log lives in `$OCLJ_BUILD`, not per platform; on 2026-10-17 it held the WSL build while the Windows `luajit.exe` was older [M]. *Fix:* read the log from the round's archive or a per-platform `OCLJ_BUILD`, and check the platform before drawing a conclusion [I].

**P20. Binaries do not survive `.gitattributes`.** *Symptom:* a committed `libluajit.a` fails `ar t` in a clone. *Cause:* `* text eol=lf` rewrites CRLF byte pairs in binaries [S] (`bench/runs/2026-10-16-noffi/README.md`). *Fix:* archive the md5s of binaries; keep the binaries outside the repo [S].

**P21. The Windows PUC 5.3.6 mis-rounds long hex-float strings.** *Symptom:* `"0x1.0000000000000801p52" | 0` gives 4503599627370496 on the Windows PUC, against 4503599627370497 on the Linux PUC and in round 3 [M] (roadmap row 211 (4)). *Fix:* derive any expectation that depends on such a string from a Linux PUC [S].

**P22. `LUA_INIT` reaches both VMs.** *Symptom:* a JIT-on run that is really interpreted, and passes: `LUA_INIT='if jit then jit.off() end'` made `run-bitfuzz.sh` print BITFUZZ PASS with `hotcases 0/300 ... jit off` [M] (review2). *Fix:* run-bitop.sh, run-bitjit.sh and run-bitfuzz.sh unset `LUA_INIT` and `LUA_INIT_5_3`, and the generator and the fuzzer require `jit on` in the JIT-on run's `#cov` line [S]. negctl-bitop.sh does not unset them itself, and its `gate` and `stage4` catchers run luajit.exe directly: unset both before running it ([12.10](#1210-our-runners-and-their-knobs)) [S].

**P23. `%.17g` hides values beyond 2^53.** *Symptom:* PUC's 9007199254740993 and our 9007199254740992 print alike, so three LEX deviations stayed invisible to the provenance check [M] (review2; `fix-results.json` FF-B, FF-C). *Fix:* print integers with `%d` on PUC; count significant bits with integer shifts, as `xrule.lua` does [S].

**P24. An end-anchored error classifier breaks when a message grows.** *Symptom:* after the hint was appended, the old `bitfuzz.lua` classifier reported 1510 mismatches (`E:INEXACT` read as `E:OTHER`; seed 1, 300 cases) on a correct build [M] (`fix-results.json`, R2-tests). *Fix:* classify by a stable prefix, and let one suite pin the whole text (the matrix, `bitop_test.c` BT3) [S].

**P25. A gate that sees only where a loop raised.** *Symptom:* a JIT that computes wrong in-range values but raises at the right iteration passes [M] (review2). *Cause:* the bitops gate's loop kept its sum in a local, which the raise at i = 151 discarded [S]. *Fix:* carry the running result out of the loop (an upvalue `acc`, 43800, PUC's value) and compare it; KFOLD64 now fails the gate with `acc=399431978520 same=false` [S][M].

**P26. A one-way diff, or a short output, compares equal.** *Symptom:* an empty JIT-on output counted as 0 differences [M] (review2: the old `ndiff`). *Fix:* count differences both ways and require the reference's line count; `bitfuzz-cmp.lua` looks for `#end` before it reads any tuple [S].

**P27. A JIT that compiles nothing passes a differential test.** *Symptom:* 0 differences from a build that records no bit operator and traced 30-42 of 2000 loops [M] (`impl-C2.json`). *Fix:* coverage gates (`OCLJ_BITJIT_HOTMIN`, `OCLJ_BITFUZZ_HOTMIN`, 0.25), `jit on` in every `#cov` line, and PROVED NOTHING (exit 2) when they fail [S].

**P28. Test loops that never compile.** *Symptom:* a loop meant to test a guard runs interpreted (`-jv`: `NYI: bytecode FNEW`), or raises before iteration 56 and never reaches the JIT (7 of 20 old loops raised by iteration 71) [M] (`impl-C2.json`). *Fix:* hoist closures out of loops; keep variants whose results are all exact; check coverage with trace events (`stop` in the loop's function) [S].

**P29. Trace numbers are reused.** *Symptom:* per-trace bookkeeping attributes a later trace to an earlier function [I]. *Cause:* `trace_abort` frees the number after its event (lj_trace.c ~:647), and `trace_findfree` (~:61) hands it out again [S]. *Fix:* set per-trace state on the `start` event (the gate's `mine[tr] = (func == hot)`) [S].

**P30. The exact mark is invisible in `-jdump`.** *Symptom:* a marked and an unmarked CONV print alike, `i64 CONV 0012 i64.num none` [M]. *Cause:* dump.lua's CONV formatter (~:282-292) prints the types, `sext` and the check kind, never bit 0x400 [S]. *Fix:* read `op2 & 0x400` through `jit.util.traceir` ([12.6](#126-reading-the-exact-mark)): `0x05d5` and `0x16ae` are marked, `0x12ae` is not [M].

**P31. Every trace carries three hook-check IR lines.** *Symptom:* an `XLOAD`, `BAND +12` and guarded `EQ +0` that no source line explains [M]. *Cause:* CHECKHOOK emits them at the end of `lj_record_setup` (lj_record.c ~:2953-2973), so they come right after what setup emits first: the loop control's SLOADs (and a range guard for a variable stop) in a root trace, the `PI` SLOADs in a side trace (`guide1`: 0002-0004 after `0001 SLOAD`; `side1`'s trace 2: 0003-0005). Being volatile, they are emitted again right after `LOOP` [M][S]. [docs/watchdog.md](watchdog.md) measures their cost [S]. *Fix:* ignore them when reading IR; never remove them [S].

**P32. `PROTO_BITOP` lies inside the closure counter.** *Symptom:* in a function that uses any bitwise operator, immutable upvalues stay loads (`UREFO` or `UREFC` plus `ULOAD`) instead of becoming constants [M] (roadmap row 212). *Cause:* `PROTO_BITOP` is 0x80, inside the 3-bit counter at 0x20..0xe0 ([2.2](#22-lexer-and-parser)) [S]. *Fix:* account for it when reading IR or timing code; upstream's, speed only, not fixed in our fork (the flags byte has no free bit) [S].

**P33. Repeated calls of one loaded chunk run slower and slower.** *Symptom:* reps that climb (0.559, 0.717, 0.941 s) when one loaded chunk is called five times; a `jit.flush()` before each call removed the climb [M] (`docs/in-game-tests.md` ~:294-303). The account, later calls running through traces compiled for earlier closures, is not measured [I]. *Fix:* load the chunk once per rep, or `jit.flush()` between calls, and compare like with like [M].

**P34. A sabotage that changes nothing visible proves nothing.** *Symptom:* an arm "not caught" because it changed no behaviour any test can see, or no code at all: the no-op `1 &&`, or `RANGE-HI`'s obvious `<=`, which does nothing on x86 because `(int64_t)2^63` is INT64_MIN and the round trip refuses it anyway [M][S] (`impl-C3.json`). *Fix:* negctl's object fingerprint marks an arm BROKEN when no reached object changes; drop an arm whose only effect is invisible, such as an abort reason, and record the measurement [S].

**P35. `-O` order matters, and `jit.opt` settings last for the process.** *Symptom:* `-O-loop -O3` runs with loop optimization on; a test that calls `jit.opt.start` changes every later test in the process [M]. *Cause:* `-O0`..`-O3` replace the whole flag set (`jitopt_level`, lib_jit.c ~:438) [S]. *Fix:* levels first, flags after (`-O3 -O-loop`); one option set per process, as the runners do [S].

**P36. `jit.off(f)` acts on the prototype.** *Symptom:* turning off one closure also turns off its siblings from the same prototype and flushes their traces [S] (`setptmode`, lj_dispatch.c ~:225). *Fix:* write a JIT-off twin as a separate function with the same text (the gate's `cold`) [S].

**P37. Hook tests need COUNT or LINE in the mask.** *Symptom:* a hook that should fire inside a compiled loop never does [S] (docs/watchdog.md, failure-mode table). *Cause:* the CHECKHOOK guard tests `hookmask & (LUA_MASKLINE | LUA_MASKCOUNT)` only [S]. *Fix:* set a COUNT hook in tests of hooks inside compiled code, as `bitop_test.c`'s BT5 does (`LUA_MASKCOUNT`, count 500) [S].

**P38. `i64.num none` in a dump is the unchecked conversion, not "no conversion".** *Symptom:* an operand conversion looks free [M]. *Cause:* `IRCONV_NONE` == `IRCONV_ANY` (lj_ir.h ~:263-266), which dump.lua prints as `none`; it is a bare `cvttsd2si` [S][M]. *Fix:* read `none` as "unchecked"; the check is the round trip and `EQ` that follow ([3.4](#34-the-conv-mode-word-op2)) [S].

**P39. `-jv` prints no line when a loop is blacklisted.** *Symptom:* 11 aborts, then silence; the loop looks idle, not refused [M]. *Cause:* `blacklist_pc` (lj_trace.c ~:380) sends no vmevent [S]. A later `-jv` line `[TRACE --- <file>:<n> -- blacklisted at <file>:<loop line>]` is not the blacklisting. It is `LJ_TRERR_BLACKL`: another recording (an enclosing loop, or the function's entry) aborted on reaching the patched `IFORL` (`lj_record_ins`, `case BC_IFORL`, ~:2721-2726), so it appears only when something else records through the loop. A probe whose loop was blacklisted by a shift count of 64 and then called from a hot outer loop printed 11 `bad argument type` aborts, then 5 such lines (3 from the outer loop, 2 from the function's entry). review1's "x11, then `blacklisted at p4.lua:3`" ([4.4](#44-type-instability-typeins-retry-blacklist)) is such a line [S][M]. *Fix:* read the loop's opcode: `IFORL` means blacklisted (`p4v.lua` `loopop`; [12.4](#124-counting-traces-and-aborts-per-function)) [S].

**P40. A guard resumes at the newest snapshot's pc, often several instructions before the operator.** *Symptom:* an exit seems to land at the wrong instruction, or code before the operator runs again [M]. *Cause:* a bit operator takes no snapshot; its guards exit through the newest one, which may be at the start of the loop body ([4.3](#43-snapshots)) [S][M]. *Fix:* `jit.util.tracesnap(tr, sn, true)` gives each snapshot's pc; a new side effect must set `J->needsnap` so it is never re-executed (S8) [S].

**P41. The width rule scores the x64 FORL index 33, not 32.** *Symptom:* `i << 21` has no result guard but `i << 22` keeps one, a bit earlier than expected [M]. *Cause:* `simplify_conv_sext` removes the index's sign extension, and an `IRT_INT` ref scores 33 ([2.6](#26-the-recorder)) [S]. *Fix:* count 33 for the int loop index and 64 for a `string.byte` operand (a `u8 XLOAD`, which is not IRT_INT; [3.11](#311-oclj_bitwidth-the-bound)) when predicting guards; narrower u8/u16 scores are roadmap row 211 (1) [S][M].

**P42. ORDER BIT differs between bytecode and IR.** *Symptom:* a bytecode-to-IR mapping by arithmetic picks the wrong IR op for BNOT or a shift [S]. *Cause:* `IR_BSWAP` sits between `IR_BNOT` and `IR_BAND` (lj_ir.h ~:56-66); `BC_BNOT..BC_BSAR` have no such gap [S]. *Fix:* map by arithmetic only for BAND..BXOR and name the others, as `oclj_rec_bitop` does [S].

**P43. `make clean` deletes `host/buildvm_arch.h`.** *Symptom:* after `make clean`, make regenerates the interpreter from a stale or unpatched .dasc [S]. *Cause:* `buildvm_arch.h` is in ALL_HDRGEN (Makefile :544-548) [S]. *Fix:* re-copy and re-patch the .dasc before `make clean`, as build-native.sh does (:694-733) [S].

**P44. The build copy persists: hand edits to unpatched files survive.** *Symptom:* a build behaves differently from what the repo describes [I]. *Cause:* build-native.sh copies the tree only when the build copy is missing (:496-501) and re-takes only the 12 patched files and our 7 ([7.2](#72-dependency-traps)) [S][M]. *Fix:* never edit `build/`; a round that changes a new upstream file adds it to the re-copy list. Drift check: `diff -rq --strip-trailing-cr prototype/watchdog/luajit/src build/native/luajit-<platform>/src` with build products filtered out [S][M].

**P45. build-native.sh calls `make`; WinLibs ships only `mingw32-make`.** *Symptom:* `make: command not found` in a plain Git Bash [M]. *Cause:* the PREREQUISITES footer says "GNU make comes with it", but the binary is `mingw32-make`; this machine's launchers prepend `/c/Users/astro/claude-tmp/oclj/bin`, which holds a `make` that runs `mingw32-make` [M]. *Fix:* copy `bench/runs/2026-10-13-dispose/scripts/make-shim` (`exec mingw32-make "$@"`, the archived copy of that file) as `make` into a directory you put first on PATH, or call `mingw32-make` by hand [M].

**P46. The DynASM echo proves a line was read, not assembled.** *Symptom:* a sabotaged .dasc line appears in `buildvm_arch.h`, yet nothing changed [I]. *Cause:* DynASM echoes every `|` line as `//|`, including lines in `.if DUALNUM` branches that are not assembled ([6.9](#69-reading-what-you-assembled)) [M]. *Fix:* pair the echo with object checks: lj_vm.o must change (negctl) or be fresh (build-native.sh) [S].

**P47. The lexer rounds a wide literal before any operator sees it.** *Symptom:* `0x00ff00ff00ff00ff & 0xff` is 0; a mask like `0x3fffffffffffff` (54 bits) is really 2^54, so a test built on it is vacuous [M] (S7). *Cause:* every numeral becomes a double in the lexer (U9) [S]. *Fix:* build masks of at most 53 significant bits, or compute them (`2^53 - 1`), and check that a test's operands are what it assumes [S][M].

**P48. Windows `luajit.exe` cannot open MSYS paths inside `-j` arguments.** *Symptom:* `-jdump=+rsT,/c/Users/...` fails to open its file, while the script argument works [M]. *Cause:* Git Bash converts a path that is a whole argument, not one embedded after a comma [I]. *Fix:* pass Windows-style paths (`cygpath -m`) inside `-j` options [M].

## 11. Verification discipline

| rule | what it guards against | where it is enforced |
|---|---|---|
| JIT-on output equals `-joff` output, line for line, under several option sets | a trace that computes what the interpreter does not | `run-bitjit.sh`, `run-bitfuzz.sh`, `run-bitop.sh` part 1 |
| `-joff` equals PUC 5.3.6 with the rule applied per operator (the twin) | an interpreter and a JIT that agree on a wrong value | `run-bitjit.sh` (gen, t_jit2), `run-bitfuzz.sh`, `run-bitop.sh` part 2 |
| expectations come from PUC mechanically, never by hand | a `.expect` line that drifts | `.expect` + `deviations.txt` + `xrule.lua` |
| a differential run proves that the JIT ran | a pass from a JIT that compiled nothing | coverage gates, `jit on` in every `#cov` line |
| every new check is first seen to fail | a gate born unable to fail | `failfirst/`, `failfirst2/`, `negctl-*.sh` |
| every fix site has a one-line sabotage that its catchers catch | tests with no teeth at the fix | `negctl-bitop.sh` (27 arms) |
| a surprising reading is the instrument's until shown otherwise | false findings | controls, `inputs.md5`, the object fingerprint |
| crash fixes are proved by census A/B plus build assertions | — | e.g. `bench/runs/2026-10-05-errmem/` |
| results directories are fresh, never cleared or reused | destroyed evidence | every runner refuses an existing `*_OUT` |
| chains longer than a minute run from the main session | a chain killed when an agent's turn ends | process rule |
| speed is read within one run, against a same-run baseline | a timing that measures the machine, not the change | `bench-r3.sh` ([11.12](#1112-measuring-speed)) |

The suites live in `test/native/` (`run-bitop.sh`, `run-bitjit.sh`, `run-bitfuzz.sh`, `negctl-bitop.sh`) and `test/native/bitop/` [S].

### 11.1 The interpreter is the oracle

- **Compare whole outputs, both ways.** Every JIT suite compares the whole JIT-on output with the `-joff` output of the same script and inputs, and counts differences in both directions [S] (`run-bitjit.sh` `ndiff`). The first `ndiff` counted only lines missing from the reference, so an empty JIT-on output compared equal [M] (review2; P26).
- **The reference must be complete first**: `-joff` must exit 0 with one line per case: `OCLJ_BITJIT_CASES` lines for the generator (2000 by default), and a literal 400 for t_rec, which does not follow that knob (run-bitjit.sh ~:206, ~:263) [S].
- **Strip CR** from every Windows output before comparing (P18) [S].
- **Print enough to localize a difference.** `drv.lua` prints, per start, `x y z h` as `%.17g` or `ERR@<loop variable>:<kind>`; `t_jit2.lua` prints one result per iteration and the iteration of a raise [S]. Before `t_jit2` printed that iteration, a NARROW sabotage that raised at 258 compiled and at 257 interpreted printed the same line both ways, in 3 runs of 3 [M] (`t_jit2.lua` header).
- **Classify an error by a stable prefix**: `INEXACT(<op>)` from "result of '<op>' has more than 53 significant bits" (`drv.lua` `kind`) [S] (P24).
- **`-joff` agreement is necessary, not sufficient**: the interpreter itself is checked against PUC (the twin, the matrix). The oracle also exposes upstream behaviour: on round 2's build (BitOp's 32-bit operators) the generator's JIT-on runs differed from `-joff` in 42-86 loops per seed and option set, because BitOp leaves an operand's conversion beyond ±2^51 unspecified and LuaJIT's narrowing exploits it (`(i * 2^45 - i) | 0` gave -66 compiled and -33 interpreted at i = 66) [M] (`failfirst/run-bitjit.log`; roadmap row 206).
- **A fresh loop starts recording at its 56th iteration**, so a raise after iteration 60 is probably from compiled code [M][I]; the generator counts those raises separately [S].

### 11.2 The PUC twin

- **The twin is the same program on PUC Lua 5.3.6, with U1-B's rule applied at every operator** through `X(r, '<op>')` [S] (`drv.lua`, `bitfuzz.lua`, `t_jit2.lua`):

```lua
X = function(r, op)
  local f = r + 0.0
  if math.tointeger(f) ~= r then
    error("result of '" .. op .. "' has more than 53 significant bits (mask each operand to 32 bits first)", 2)
  end
  return f
end
```

  An r near `math.maxinteger` gives `r + 0.0` = 2^63, which has no integer, so it fails too [S].
- **The twin's text is generated from the same source as ours, never written twice by hand** [S]:
  - `gen.lua`'s builders return both texts at once: ours `(a op b)` and PUC's `X(a op b, 'op')`. `~>>`, which 5.3 lacks, becomes `SAR(a, k)`, drv.lua's 64-bit arithmetic shift under the same rule. Loop indices start as floats (`for i = 1.0, n`) and constants get `+ 0.0`, so 5.3's integer arithmetic between operators becomes the double arithmetic our VM does.
  - `t_jit2.lua` keeps one text with every result wrapped in `X`, and ours drops each `X`. A mechanical check asserts that each `X` wraps exactly one operator at its own top level, or it prints INSTRUMENT and exits 2; the check was seen to fail ("narrow-add: 1 operators but 0 X's") [M] (`impl-C2.json`).
- **The twin is compared with `-joff`, not with the JIT-on run**: PUC checks the interpreter and `-joff` checks the JIT, a triangle [S][I].
- **A checker must not restate the implementation's test.** `xrule.lua` holds X to 5.3.6's own integers and counts significant bits (lowest set bit to highest) with integer shifts, never through a double [S].
- **Expectations that depend on a long hex-float string come from a Linux PUC** (P21).

### 11.3 Option sets

Each option set exercises one path, so each suite runs several [S]:

| name | flags | run by | what it exercises [I] |
|---|---|---|---|
| jon | none (`-O3`, hotloop 56) | gen, t_rec, t_jit2 | the ordinary path |
| hl1 | `-O3 -Ohotloop=1` | gen, t_rec, t_jit2 | recording on the first iteration, specialized to the start values |
| ms0 | `-Omaxside=0` | gen, t_rec, t_jit2 | no side traces: every failing guard exits to the interpreter through a snapshot |
| he1 | `-Ohotloop=1 -Ohotexit=1` | gen, t_jit2 | a side trace from the first taken exit: parent-snapshot values entering a new trace |
| noloop | `-O3 -O-loop` | gen | no loop optimization, so no pre-roll copy and no PHIs: a difference that disappears here points at a PHI-crossing fold |
| O0, O1 | `-O0`, `-O1` | t_jit2 | no FOLD, CSE or DCE at all; then fold, CSE and DCE without narrowing or loop optimization |

The levels are flag sets (lj_jit.h `JIT_F_OPT_1..3`, ~:97-102): `-O1` is fold, cse and dce; `-O2` adds narrow and loop; `-O3` adds fwd, dse, abc, sink and fuse [S]. Order matters (P35).

### 11.4 The generator

`gen.lua` + `drv.lua`: the round-3 width-fold reviewer's adversarial loop generator, in its U1-B form [S].

- **Use.** `luajit gen.lua <seed> <count> <outdir> [phi]` writes `cases_lj.lua` and `cases_puc.lua` into `<outdir>`, which must exist (gen.lua does not create it; run-bitjit.sh does) [S][M]. Each case is a chunk that returns `run(n, x0, y0, z0)`, a getter for the loop variable, and a converter from that value to the iteration count [S].
- **What a loop contains** [S]: carried values in the slots x, y, z and h, in a table t and in an upvalue u; six loop headers (`1, n`; `-7, n - 8`; `n, 1, -1`; `2^40, ...`; a while loop; a float start in the PUC text); branches (side exits and side traces) and a flipped boolean (type instability, so the loop is unrolled); table stores read back next iteration and an inlined helper; inner loops (a constant trip count is unrolled, a variable one gets its own trace); a swap through multiple assignment; int-typed results (the loop index through a bit operator); `string.byte` values (IRT_U8); double arithmetic on bit results; and an uncompiled C call (`table.sort`) that forces stitching.
- **Boundaries** [S]: shift counts cluster at 9-12, 43-46 and 52-54, masks at 2^52-2^54. 26 boundary templates (gen.lua `BT`, ~:92-124): 20 at exactly 55 bits (must not fold), 4 at 54 (fold), and 2 negative masks with no finite bound.
- **phi mode** [S]: `OCLJ_BITJIT_GENMODE=phi` makes half the statements carry a finitely bounded value across the loop's PHI.
- **How drv.lua runs a case** [S]: from **seven starts** of (x, y, z) — {1, 2, 3}, {2^52+1, -3, 7}, {-1, 2^62, -2^63}, {0x7ffffffffffffc00, 12345, -987654321}, {2^53-1, 2^53+2, -2^53}, {0, 0, 0} and {2^52+2^51, 3, 1.5} — for 300 iterations each, in two **closure modes**: `shared` (one closure, so later starts run the first start's traces, side exits and side traces) and `fresh` (the chunk loaded again per start).
- **The comparisons**: `-joff` against the five option sets in both modes, plus the PUC twin in both modes: 12 numbers per seed, all of which must be 0 [S]. A 300-loop run (`OCLJ_BITJIT_PARTS=gen OCLJ_BITJIT_SEEDS=1 OCLJ_BITJIT_CASES=300`, with a fresh `OCLJ_BITJIT_OUT`) read 0 in all 12 (3.4-3.8 s) [M].
- **The coverage gate.** `drv.lua` writes a `#cov` line to stderr: cases, starts, raises, raises after iteration 60, and the cases in which a trace completed. The JIT-on shared run must say `jit on` and complete a trace in at least `OCLJ_BITJIT_HOTMIN` (0.25) of the loops, or the seed PROVED NOTHING (exit 2) [S]. A copy whose recorder refuses every bit operator showed 0 differences with traces in only 1.5-2.1% of the loops; the build traces 67-70% [M] (`run-bitjit.sh` header). Probe, that 300-loop run: `coverage: 300 loops, 2100 runs, 823 raised, 18 after iteration 60; a trace completed in 214 loops`. The traced count varies between runs (212-218 measured, P6); the rest is fixed by the seed [M].
- **Seeds are deterministic**: the PRNG is integer-exact Park-Miller, so a seed generates the same loops on every VM and run [S][M].
- **Campaign**: `OCLJ_BITJIT_SEED=101 OCLJ_BITJIT_SEEDS=20`, then `OCLJ_BITJIT_SEED=201 OCLJ_BITJIT_SEEDS=20 OCLJ_BITJIT_GENMODE=phi`, about 9.6 MB per seed of 2000 loops; the final build showed 0 differences [S][M] (`logs/campaign-2/`, `phi20.log` starts at seed 201).
- **What it catches**: every fold-rule sabotage, the missing guards, NARROW and KFOLD64, in every seed. Fewest differing cases per seed over three runs: WBAND 11, WADD0 11, WSHL0 24, WSHR 70, WIDTH55 168, INEXACT-JIT 511, SELFGUARD 516 [M].
- **Extending it** [S]. The builders `P(lj, puc)`, `B(op, a, b)` and `U(a)` return the pair of texts (gen.lua ~:60-62). Operands come from `atom()` (~:67), and boundary shapes from the `BT` list (~:92-124). The table-index atoms mask with `& 7` and `& 15` (~:74-81, ~:210), widths 4-5, so they cannot tell a bound of 32 from 33. An index fold needs atoms whose index operand bounds at exactly 32 and 33 (review1's `t_idx.lua` cases: `x ~>> 31`, `x & 0xffffffff`, keys near ±2^32), used as table keys, `string.byte`/`string.sub` arguments and shift counts [I].
- **Seeds.** Every added atom or template shifts the PRNG's draws, and the old seeds stop generating round 3's loops, which gen.lua's header promises they do (~:28-30). Add new shapes behind a new `OCLJ_BITJIT_GENMODE` value, as `phi` is [S][I].
- **By hand.** `luajit drv.lua <cases file> <shared|fresh> [N]` (drv.lua's header) runs one case file. Use it for option sets the runner lacks (`GENOPTS` is fixed, run-bitjit.sh ~:184), such as 8.4's `-O-fold` and `-O-cse`, and compare with `-joff` the same way, CR stripped [S].

### 11.5 The floor: t_rec, t_jit2, p4v

Deterministic suites that hold a minimum of coverage whatever the generator draws [I].

| suite | what it is | option sets | what it catches |
|---|---|---|---|
| `t_rec.lua` | loop-carried recurrences `x, y = F(x, y, i), G(x, y, i)`, 400 per seed, 300 iterations, several starts; prints the final x and y and a position-weighted sum of every intermediate x (exact, fmod 2^53); seeds 1-2, and 3-4 in `counts` mode (shift counts negative, 64 or more, and -2^63) | jon, hl1, ms0 | NARROW, KFOLD64, the missing guards, SELFGUARD; not the width rule's off-by-ones, which gen catches [M] |
| `t_jit2.lua` | 27 hand-built loops, one result per iteration, `ERR@<iteration>:<kind>`; the PUC text comes from the one X-wrapped source | jon, O0, O1, hl1, ms0, he1 | NOINT-JIT (guard-exit, in all six sets); NARROW (in some sets only, so gate it as "nonzero in some option set") [M] |
| `p4v.lua` (fix1) | eight loops that set a value from the loop index (seven identity bit operations and one non-identity control) and use it in a bit operator next iteration; each must compile: a `stop` in its function, 0 TYPEINS aborts, its FORL patched to JFORL, not IFORL | default | FIX1 (`traces=0 typeins=11 loop=IFORL` for 7 of 8 without it); a JIT that records no bit operator [M] |

Lessons from building the floor [M] (`impl-C2.json`): a loop that raises before `hotloop` never tests the JIT, so keep a variant whose results are all exact; a closure created inside a loop (`FNEW`) is NYI and keeps the loop from compiling (P28); print the iteration of a raise.

### 11.6 The fuzzer and the matrix

**The fuzzer** (`bitfuzz.lua`, `run-bitfuzz.sh`) draws the same random expression trees on PUC and on ours: the five binary operators and unary `~`, over up to four operands, with 16 operand tuples per case. Its PRNG is integer-exact and literals are printed by exact digit arithmetic, so both VMs read the same text [S]. Ours computes every tuple in five modes [S]:

| mode | how the operands arrive | what it tests |
|---|---|---|
| K | every operand a literal | the parser's constant folding |
| V | as arguments, one call | the interpreter |
| P | as V, with minimal parentheses | the parser's precedence |
| H | as V, in a loop over all tuples, 8 repetitions | the recorder and the assembler |
| U | literals stored to locals in a loop run 120 times (first 3 tuples) | the fold engine (the operands are constants to the recorder) |

- **Reference and coverage** [S]: PUC with `X` at every operator; errors compare by kind. Ours runs twice, JIT on and `-joff`; the JIT-on `#cov` line must say `jit on` and show traces in at least `OCLJ_BITFUZZ_HOTMIN` (0.25) of the H and of the U loops. The build compiles 40-44% of the H loops, and a copy that records no bit operator 5-7% [M] (`impl-C2.json`).
- **Three controls per seed**, with PUC playing the VM [S]: `sim-wrap` (a correct VM) must PASS; `sim-raw` (5.3.6 without the rule) must FAIL in exactly the inexact tuples; `sim-round` (the rejected U1-A) must FAIL in exactly the tuples whose reference is `E:INEXACT`. Probe, seed 1 with `OCLJ_BITFUZZ_CASES=300`: `sim-wrap PASS; sim-raw MISMATCH 1510 of INEXACT 1510; sim-round MISMATCH 1510 of REF E:INEXACT 1510`; at the default 1000 cases the counts read 5159 [M].
- **Crashes**: a nonzero exit from our side is a 1, and an output without `#end` is CRASH (1) before any tuple is compared [S].
- **Campaign**: `OCLJ_BITFUZZ_SEED=11 OCLJ_BITFUZZ_SEEDS=50 OCLJ_BITFUZZ_CASES=20000` ran 16,000,000 tuples, 4,792,268 raising in the reference, 0 mismatches, in 39 min 48 s [M] (round 3 README). It writes about 6.3 GB unless `OCLJ_BITFUZZ_PRUNE=1` [S]. No `~>>` (5.3 has none); t_sar and the generator cover it [S].

**The matrix** (`run-bitop.sh`):

- **Part 1** runs `t_ops` (7467 cases), `t_fold` (63), `t_sar` (437) and `t_bit` (2109, LuaJIT's own `bit` library, unchanged) on the build's luajit.exe, JIT on and `-joff`; each output must equal its `.expect`, then `coerce_agree.lua` runs [M].
- **The `.expect` files** are PUC 5.3.6's output with `X`, reworded to LuaJIT's word order by `reword.lua`, plus the lines `deviations.txt` lists; made mechanically, never by hand [S].
- **Part 2 (provenance)**: PUC with `X`, reworded, must differ from `.expect` in exactly the lines `deviations.txt` lists for the platform (classes LEX, IDIV, RESID-varinfo); and a raw PUC run, printing integers with `%d`, must make `xrule.lua` agree that X raises exactly where an operator's integer has more than 53 significant bits [S] (P23).
- **Part 3** runs `bitop_test.c` through the shim, linked with the objects the DLL links [S].

### 11.7 negctl: one-line sabotages

`negctl-bitop.sh` proves the round's tests have teeth at the fix's own sites [S]:

1. **The copy is the repo's.** The build tree is copied into a fresh work directory; native/luajit's files must `cmp` equal; each patched LuaJIT file must equal what its patch script makes of the pristine file; `eris_lj.o` must carry the serializer hash [S].
2. **One line, anchored.** An arm replaces one line, or a run of consecutive lines, that must occur exactly once in the canonical file; the result must differ in exactly one line, which must say `SABOTAGE <NAME>:`. Anchors write a tab as `@T@`, so the script holds no tab and no backslash, and an anchored file must contain no CR [S].
3. **Only what the file reaches is rebuilt**, from an explicit map, because `Makefile.dep` does not know the included oclj files: the map in [7.4](#74-running-make-by-hand) is this script's [S].
4. **The object fingerprint.** After each build, every `src/*.o` and `src/host/*.o` is compared by md5 with the shipped build's [S]. If no reached object changed, the arm is BROKEN (the sabotage did not reach the code); if any other object changed, BROKEN (something else changed). A `vm_x64.dasc` arm's line must also appear in `host/buildvm_arch.h`, which proves DynASM read it; the object change proves it was assembled (P46). The fingerprint found a gap in the first map: a 32-bit `and` drops REX.W, which moves handler offsets and changes `lj_bc.o` [M] (`impl-C3.json`; P14).
5. **canon and restore.** canon rebuilds every round-3 object from unchanged sources: every catcher must pass and every object must come out byte-identical. After the last arm, every file goes back, and the tree must match the shipped build object for object [S][M].
6. **Every listed catcher must fail at its named check** (`suite:check`, e.g. `fuzz:U`), not just any suite; a listed suite that exits 2 makes the arm FAIL as "proved nothing" [S].
7. **The catchers are the real gates.** The bitops gate and the stage-4 word check are extracted from build-native.sh at run time, so weakening a gate there weakens the catcher here [S].
8. **Memory-safe by construction.** Every sabotage computes a different value, raises a different message or none, writes a different version byte or word token, or only blacklists loops; none touches a bound that guards a read or a write [S] (header). New arms must keep this property.
9. **An arm that proves nothing is dropped, with the measurement.** INEXACT-RECABORT changed only the abort reason: the same raises, 26 starts and 26 aborts on both builds [M]. A selection made with `OCLJ_NEGCTL_ARMS` proves only the arms it ran, and says so [S].
10. **Margins, not verdicts.** The JIT catchers vary from run to run (P6): measure each arm's margin over three runs, and gate on "nonzero", never on a count [M].

**Adding an arm, a catcher, a suite or a file.** Every list is hardcoded [S]:

- **An arm** is one call, `arm <NAME> <file> '<suite:check ...>' '<old line(s)>' '<new line(s)>'` (the comment above `arm()`, ~:474; the calls, ~:547-630). Its new line must contain `SABOTAGE <NAME>:` (~:495). Add a row to the header's arm list, and its measured margin.
- **A new catcher** needs a `run_*` function and a case in `runcatchers`, `rcof`, `check` and `info` (~:317-460). An unknown catcher fails setup with "unknown catcher".
- **A new floor suite** (`t_idx.lua`, `t_cnt33.lua`) goes into `test/native/bitop/` and into run-bitjit.sh's file check and `inputs.md5` (~:120, ~:150). Give it option sets (the runner's own are fixed, ~:183-186), `-joff` as its reference, a PUC twin or a stated reason for none, and a coverage check.
- **A new native/luajit file** goes into build-native.sh's `BITOP_FILES`, its include assertions and its freshness map (~:695-724, ~:792-795), and into negctl's `NATIVE_FILES`, `ALLFILES` and `objs_of` (~:186-189, ~:243-256).
- **A newly patched upstream file** goes into `BITOP_PATCHES` (build-native.sh ~:696) and into negctl's `PATCHED`, `ALLFILES` and `objs_of`.

- **Cost**: a full run takes about 8 minutes (7 min 57 s on Windows, 6 min 20 s on Linux), leaves about 445 MB in its work directory and deletes nothing [M]. It belongs to the main session ([11.11](#1111-long-runs-and-results-directories)).
- **The machinery was fail-firsted too** [M] (`impl-C3.json`, FF1-FF8): setup checks that exit 2 (a copy of the round-2 build, an extra line in `lj_parse.c`, a bogus arm name, a renamed stage-4 block, the wrong `eris_lj.o`); BROKEN arms (a no-op `1 &&`, a missing anchor, a missing marker, a two-line change); an arm held to the wrong catcher (NOT CAUGHT); a restore that skipped one file (FAIL).

### 11.8 Fail-first

Run every new check against a case that must fail it before you trust a pass [S]. Round 3's evidence, all [M]:

| check | the case that must fail | what it read |
|---|---|---|
| `run-bitop.sh` part 1 | round 2's build (32-bit operators) | t_ops 6771 lines, t_fold 45, t_sar 313, coerce_agree 29; t_bit, the unchanged control, passes (`failfirst/run-bitop.log`) |
| the same | round 3's first build, before the hint | exactly the 550/11/5 inexact lines (`failfirst2/run-bitop.log`) |
| `run-bitjit.sh` | round 2's build | every seed FAILs; t_rec 125-141 lines per seed; t_jit2 2 loops, and 25 against PUC (`failfirst/run-bitjit.log`) |
| the fix1 part | a build without fix1 | 7 of 8 FAILED, `traces=0 typeins=11 loop=IFORL` (`impl-C2.json`) |
| the generator's coverage gate | a copy that records no bit operator | 0 differences, traces in 30-42 of 2000 loops: PROVED NOTHING (`impl-C2.json`) |
| `run-bitfuzz.sh` | round 2's build | 12,198 mismatches of 16,000 (`failfirst/run-bitfuzz.log`) |
| the bitops gate | round 2's luajit.exe | `fold=1/-1/1 kx=2147483647 ... dump=2 bit=1 hot=322122623506@300 ...` (`failfirst/bitops-gate.out`) |
| the gate's `acc` field | a KFOLD64 copy | the old gate PASSes; the new one reads `acc=399431978520 same=false` (`fix-results.json`, R1) |
| the jit tools gate | round 3's first build (signed `funcbc`) | `snapend=-16777216 bc=118 bl=0 blerr=1 bldec=0 jd=5/0/4/4 jdb=11/0 jdim=1/1 jdline=0` (`failfirst2/jit-gate.log`) |
| `deviations.txt` provenance | the file without its 3 new LEX lines; `t_fold`'s `fmt` back to `%.17g` | FAIL "differ but not listed"; the old instrument says "listed but agree" (`fix-results.json`, FF-B, FF-C) |

How the round did it [S]: run the fail-first on the build before the change and record which build it was (`failfirst/build-under-test.md5`); use the check's own text, extracting a gate from build-native.sh instead of retyping it (`scripts/run-gate.sh`); include a positive control that must pass in the same run (t_bit; canon in negctl); keep `.exit`, `.start` and `.end` files beside each log.

### 11.9 Instrument-first

When a reading surprises you, suspect the instrument first [S]. In round 3, each of these looked like a fact about the VM and was a fact about the instrument:

| the reading | what it was |
|---|---|
| bit-operator loops "do not compile" under `luajit -jdump` | `jit/bc.lua` raised inside dump's record handler on a signed bytecode word and aborted the trace: the tool changed what the JIT did (P9) [M] |
| 25 differences in an ad-hoc diff | CR from Windows stdout (P18) [M] |
| the fuzzer's JIT-on run passed | `LUA_INIT` had made it a second interpreter run (P22) [M] |
| PUC and ours agreed on `9007199254740993` | `%.17g` printed two different values alike (P23) [M] |
| the bitops gate passed a JIT that computed wrong values | the gate's loop discarded its running sum at the raise (P25) [M] |
| the guard-exit loop looked fine under NOINT-JIT | it never compiled: an `FNEW` in the loop (P28) [M] |
| `-jdump` showed `BAND 0011 +1` for a mask of 0x3FFFC | `tracek` returns the trace number for a KINT64 (P3) [M] |
| `-jv` printed nothing | the probe's own `jit.attach` replaced `-jv`'s handler (P11) [M] |
| `build/native/luajit_build.log` had no `-D WIN` | it was the last platform's build log (P19) [M] |
| an exit probe that "should" raise did not | `x << 20` with x near 2^33 has only 34 significant bits: significant bits run from the top set bit to the lowest [M] |

What to do [S]: ask what else would produce this exact reading; check that the instrument points at the build you mean (run-bitjit.sh and run-bitfuzz.sh write `inputs.md5`, every `#cov` line says `jit on`); build the fingerprint into the check (controls, coverage gates, the object fingerprint); make absence explicit (a check that could not see anything says PROVED NOTHING and exits 2).

### 11.10 Crash fixes

A fix for a native crash is proved by two things: a black-box census A/B (the same unmodified workload, run against the library before and after the fix, abnormal exits counted per process) and the build's content assertions that the fix is present, each seen to fire on a sabotaged copy. It is never proved by a test that forces the crash. The evidence states that it is a census, not a unit test. Example: `bench/runs/2026-10-05-errmem/` (change 2) [S].

### 11.11 Long runs and results directories

- **Anything longer than a minute runs from the main session**: `nohup sh chain.sh > log 2>&1 &`, plus a monitor that waits for a done file [S]. That covers negctl (about 8 minutes) and campaigns (4-40 minutes). When an agent's turn ends, whatever it launched dies; agents write the chain and prove its checks on something short.
- **Never edit a script that a running chain executes** (P17).
- **Results go to a fresh directory.** Every runner refuses an existing `*_OUT` with "exists; results are never overwritten" and exits 2 [M]. Never `rm -rf` a directory and reuse it; if a path must be reused, move the old one aside. Archive the md5s of binaries, not the binaries (P20).
- **As an agent, point `OCLJ_BITOP_OUT`, `OCLJ_BITJIT_OUT` and `OCLJ_BITFUZZ_OUT` at a fresh scratch directory**: their defaults are under `$OCLJ_BUILD` [S].

### 11.12 Measuring speed

- **The tools in the repo** [S]. `bench/runs/2026-10-17-bitop/scripts/bench-r3.sh <fresh outdir>` runs `bench_bit.lua` and `bench_bit2.lua` (its `crc-table` field is the CRC32 row) three times. It alternates the round-2 baseline b0 (`C:/Users/astro/claude-tmp/oclj/r3/synth/b0/build/native/luajit-windows-x86_64/src/luajit.exe`, 32-bit operators) with the build under test, so the two share each run's machine state, and records `inputs.md5` and the running JVMs (`jvms.txt`). For a scratch build, copy the script and change `SH`. Round 3's reading is `logs/bench/bench.txt`: shipped `crc-table` 7.20 ns/byte, b0 2.80-2.90 [M]. review1's `bench_tf.lua` adds crc masked each byte (`crctm`) ([8.8](#88-where-the-crc32-follow-up-starts)).
- **Method.** Alternate builds within each run, take the best of 3, and read ratios within the run, not absolute ns: the bit and RGB rows print a ratio to a same-run arithmetic loop, and the `crc-table` row has none, so compare it with b0 in the same run [S][M]. Use a quiet machine, with no game, harness or campaign running (the script's header). Keep N at 2e7 or below: review1 saw 13-15% mode jumps in some runs at N=5e7 and 1e8 and never at 2e7 (eight processes per build) on this hybrid CPU [M review1]; `bench_bit2.lua` defaults to 1e7. A timing session is a chain and belongs to the main session ([11.11](#1111-long-runs-and-results-directories)).
- **Measure where a speculation breaks**, not only the target. Loops whose values exceed 2^53 (review1's xorshift64 and `h ~ (i<<40) ~ (h>>3)`) and round 3's other rows (shl/xor/and, RGB, bit-serial CRC) must not slow down ([8.8](#88-where-the-crc32-follow-up-starts)) [S].

## 12. Tools

Run `luajit.exe` from the build copy's `src/` with `LUA_PATH='./?.lua'`, so `require("jit.dump")` and the other `jit.*` modules find `src/jit/*.lua` [S] (build-native.sh, jit tools gate). The sandbox has no `jit.*` modules [S]. These modules use the pin's own syntax extensions, `!=`, `..=` and `c ? a : b` (doc/extensions.html), which our luajit accepts [M]; keep that in mind if you patch them.

### 12.1 luajit -jv

One line per trace event [M]:

```
[TRACE   1 p_typeins2.lua:7 loop]                      root trace, links to itself
[TRACE   2 (1/1) (command line):1 -> 1]                side trace of trace 1, exit 1, links to trace 1
[TRACE --- (command line):1 -- NYI: bytecode FNEW  ]   recording aborted, with the reason
```

`LUAJIT_VERBOSEFILE` redirects the output, overwritten at each start (`jit/v.lua`) [S]. `-jv` attaches to `"trace"` (`jit/v.lua` ~:164), so a probe that attaches to `"trace"` silences it (P11). It prints no line for the blacklisting itself; a later `blacklisted at` line is another recording's abort (P39).

### 12.2 luajit -jdump

| char | default | what it dumps |
|---|---|---|
| `t` | yes | a line for each trace start, stop and abort |
| `b` | yes | the recorded bytecode (through `jit/bc.lua`: P9) |
| `i` | yes | the IR |
| `r` | | the IR with register and stack slots |
| `s` | | the snapshot map |
| `m` | yes | the machine code |
| `x`, `X` | | each taken trace exit; `X` adds every register |
| `a` | | the IR of aborted traces too |
| `T`, `A`, `H` | | plain text, ANSI colour, HTML |

[S] `jit/dump.lua` header.

- **The mode string**: `-jdump=is` replaces the default set, `+s` adds to it and `-b` removes from it. A second argument after a comma, or `LUAJIT_DUMPFILE`, names the output file, overwritten at each start [S]. Inside `-j` arguments, use Windows paths (P48).
- **Colour** comes from `TERM`, regardless of redirection; add `T` for logs and greps. `-jdump=T` alone is the default set in plain text (P12).
- **One handler per event**: `-jdump` attaches to `"trace"`, to `"record"` (for `b`) and to `"texit"` (for `x`); the last `-j` module on the command line wins `"trace"` (P11) [S][M].
- **Reading it**: [3.5](#35-reading-a-dump) and the annotated trace in [8.7](#87-reading-a--jdump). Every trace contains the CHECKHOOK lines near its head, and again after LOOP (P31); KINT64 constants print as the trace number (P3); the exact mark is never shown (P30).

### 12.3 luajit -b

- `-bl file.lua` lists a file's bytecode, `-bl -e "chunk"` a string's; the parser's folding shows there (`1 << 40` lists as `KNUM ... ; 1099511627776`) [M].
- `-b in out` writes a raw dump, whose header is `0x1b 'L' 'J'` followed by `BCDUMP_VERSION` 0x80 [M].
- `-b -t obj` (or `-t o`) needs FFI: "FFI library required to write this file type", exit 1 [M]. So does a raw dump to stdout on Windows (`-b in.lua -`: "FFI library required to write binary file to stdout", exit 1) [M]. `-t c` and `-t h` (a C source and a header array) work without FFI, exit 0 [M]. The checks are in jit/bcsave.lua's `bcsave_obj` (~:531) and `bcsave_raw` (~:153) [S].
- **Exit status**: an error raised while listing is reported and luajit exits 0 (P10). Gate on stderr, not on the exit code.

### 12.4 Counting traces and aborts per function

**Events** [S]:

| event | callback arguments | sent by |
|---|---|---|
| `"trace"` | `("start", tr, func, pc[, parent, exitno])`, `("stop", tr, func)`, `("abort", tr, func, pc, code, info)`, `("flush")` | lj_trace.c `trace_start` ~:470, `trace_stop` ~:562, `trace_abort` ~:622, the flush ~:299 |
| `"record"` | `(tr, func, pc, depth)`, once per recorded bytecode | lj_trace.c ~:701 |
| `"texit"` | `(tr, exitno, ngpr, nfpr, gpr values..., fpr values...)`, 16 and 16 on x64 (jit/dump.lua `dump_texit`) | `lj_trace_exit`, lj_trace.c ~:928 |
| `"bc"` | a new prototype from the parser | lj_parse.c ~:1736 |

- **One handler per event** (`jit_attach`, lib_jit.c ~:123): a second attach to the same event replaces the first; `jit.attach(f)` without an event detaches `f` [S][M] (P11).
- **Trace numbers are reused** (P29): key per-trace state on the `start` event.
- **Abort codes**: `require("jit.vmdef").traceerr[code]` gives the reason, a format string that takes `info`; `p4v.lua` finds TYPEINS by its message, "persistent type instability" [S].

The bitops gate's pattern (build-native.sh) [S]:

```lua
local jutil = require("jit.util")
local st, mine = { root = 0, loop = 0, stitch = 0, abort = 0 }, {}
local function cb(what, tr, func)
  if what == "start" then mine[tr] = (func == target)          -- numbers are reused: key on start
  elseif what == "stop" and mine[tr] then
    local lt = jutil.traceinfo(tr).linktype
    st[lt] = (st[lt] or 0) + 1
  elseif what == "abort" and mine[tr] then st.abort = st.abort + 1 end
end
jit.flush()               -- no traces left over from earlier code
jit.attach(cb, "trace")   -- this replaces -jv's or -jdump's handler
target()
jit.attach(cb)            -- detach
```

- **Blacklisting** shows in the loop's opcode: `JFORL` means a trace is attached, `IFORL` blacklisted. Read it with `jutil.funcbc(f, pc) % 256` and `vmdef.bcnames:sub(op * 6 + 1, op * 6 + 6)` (`p4v.lua` `loopop`) [S].
- **A JIT-off twin** must be a separate function with the same text, not a second closure of one prototype (P36) [S].

### 12.5 jit.util

| function | returns | on this build |
|---|---|---|
| `funcinfo(f[, pc])` | a table: `linedefined`, `bytecodes`, `params`, `children`, `currentline`, ... [S] | `bytecodes` includes the header instruction (the jit tools gate subtracts 1) [S] |
| `funcbc(f, pc)` | `ins, mode` [S] | `ins` is a non-negative number since change 12 (upstream returned it signed) [M]; decode with `% 256` or masks |
| `funck(f, k)` | a number constant for k ≥ 0, a GC constant for k < 0 [S] | |
| `funcuvname(f, k)` | an upvalue's name [S] | |
| `traceinfo(tr)` | `{nins, nk, link, nexit, linktype}`, or nil [S] | `linktype` is one of none, root, loop, tail-recursion, up-recursion, down-recursion, interpreter, return, stitch (lib_jit.c ~:275-292) [S] |
| `traceir(tr, ref)` | `m, ot, op1, op2, ridsp` [S] | the opcode is `ot >> 8` (its name is 6 characters at that index in `jit.vmdef.irnames`), the type `ot & 31`, a guard `ot & 128`, a PHI operand `ot & 64` [S][M] |
| `tracek(tr, k)` | `value, irtype[, slot]` [S] | wrong for KINT64 (P3) |
| `tracesnap(tr, sn)` | a table of snapshot entries [S] | entries and the end marker are unsigned (the end marker is 4278190080) [M]; `tracesnap(tr, sn, true)` gives the resume pc ([4.3](#43-snapshots)) |
| `tracemc(tr)` | `mcode, address, loop offset` [S] | |
| `traceexitstub(exitno)`, `ircalladdr(idx)` | addresses [S] | x64 has shared exit stubs (`EXITSTUBS_PER_GROUP`), so `traceexitstub` reads argument 1 as the exit number; the `(tr, exitno)` form is for per-trace targets (lib_jit.c `jit_util_traceexitstub`) [S] |

`jit.vmdef` (generated by `buildvm -m vmdef`) provides `bcnames`, `irnames` and `traceerr`, among others [S].

### 12.6 Reading the exact mark

```lua
-- run from the build's src/; not together with -jdump (one handler per event)
local jutil, vmdef = require("jit.util"), require("jit.vmdef")
jit.attach(function(what, tr)
  if what ~= "stop" then return end
  for ref = 1, jutil.traceinfo(tr).nins do
    local m, ot, op1, op2 = jutil.traceir(tr, ref)
    if vmdef.irnames:sub((ot >> 8) * 6 + 1, (ot >> 8) * 6 + 6) == "CONV  " then
      print(tr, ref, op1, string.format("0x%04x", op2), (op2 & 0x400) ~= 0 and "EXACT" or "")
    end
  end
end, "trace")
```

On a bit-operator loop this read `0x05d5` (num.i64, marked) for each result conversion, `0x16ae` (i64.num, ANY, marked) for the guard's own conversion back, and `0x12ae` (unmarked) for an operand's conversion of a slot [M], as `oclj_bitop_rec.c` describes [S].

### 12.7 jit.flush, jit.off, jit.on

- `jit.flush()` flushes every trace, `jit.flush(n)` trace n, and `jit.flush(f)` the traces of f's prototype [S] (lib_jit.c `jit_flush` ~:78; lj_dispatch.c `setptmode` ~:225).
- `jit.off(f)` sets `PROTO_NOJIT` on f's prototype, covering every closure of it, and flushes its traces; `jit.off(f, true)` applies to f's sub-functions too; `jit.on(f)` re-enables it and unpatches the loop bytecodes. `-joff` and `jit.off()` turn the whole engine off [S] (P36).
- A JIT off-to-on transition re-initializes the hot counters (lj_dispatch.c ~:209-211) [S].

### 12.8 jit.opt.start and -O

- **How `-O` reaches the JIT**: each `-O` argument goes to `jit.opt.start`, and commas split it, so `-Ohotloop=1,-loop` works [S][M] (luajit.c `dojitopt`).
- **Levels**: `-O0` to `-O3` replace the whole flag set (`jitopt_level`, lib_jit.c ~:438), so order matters (P35) [S][M].
- **Flags**: `fold cse dce fwd dse narrow loop abc sink fuse fma`, prefixed `+`, `-` or `no` (lj_jit.h ~:80-90); the default is `-O3`. `jit.status()` here reads `fold cse dce fwd dse narrow loop abc sink fuse` [S][M].
- **Parameters** (lj_jit.h `JIT_PARAMDEF`, ~:108-128) [S]:

| param | default | param | default |
|---|---|---|---|
| maxtrace | 1000 | hotexit | 10 |
| maxrecord | 4000 | tryside | 4 |
| maxirconst | 500 | instunroll | 4 |
| maxside | 100 | loopunroll | 15 |
| maxsnap | 500 | callunroll | 3 |
| minstitch | 0 | recunroll | 2 |
| hotloop | 56 | sizemcode, maxmcode | 64, 2048 |

- **Side effects**: setting `hotloop` re-initializes every hot counter (`jitopt_param`, lib_jit.c ~:503-504); with no arguments `jit.opt.start` resets the flags only; settings last for the whole process (P35); an unknown name raises "unknown or malformed optimization flag 'bogus'" [S][M].

### 12.9 -jp

The profiler is in this build and runs on Windows: `luajit -jp=f -e "<loop>"` prints a per-function profile, and `jit.profile` loads [M].

### 12.10 Our runners and their knobs

What each does [S]:

- **run-bitjit.sh and run-bitfuzz.sh** unset `LUA_INIT` and `LUA_INIT_5_3`, strip CR before comparing, refuse a zero seed, case or tuple count, refuse an existing output directory, write `inputs.md5`, and exit **0** for pass, **1** for fail (or a crash), **2** for proved nothing.
- **run-bitop.sh** does the same, except that it has no counts to refuse and writes no `inputs.md5`.
- **negctl-bitop.sh** refuses an existing work directory and exits 2 on a setup failure, but does not unset `LUA_INIT` itself. Its catchers that are runners do; its `gate` and `stage4` catchers run luajit.exe directly (~:336-356), so unset `LUA_INIT` and `LUA_INIT_5_3` before running it (P22).

| runner | knob | default | meaning |
|---|---|---|---|
| all | `OCLJ_BUILD` | `build/native` | where the luajit.exe, the archive and the objects are |
| all | `OCLJ_LUA53` | `bench/vendor/lua-5.3.6/src/lua.exe` | PUC 5.3.6; refused unless `-v` says "Lua 5.3.6" |
| `run-bitop.sh` | `OCLJ_BITOP_OUT`, `OCLJ_JNI`, `OCLJ_SHIM`, `CC` | fresh `$OCLJ_BUILD/bitop-<stamp>` | part 3 needs `jni.h`; without PUC, part 2 says SKIPPED |
| `run-bitjit.sh` | `OCLJ_BITJIT_PARTS` | `gen floor fix1` | a subset proves only its parts, and says so |
| | `OCLJ_BITJIT_SEED`, `_SEEDS`, `_CASES` | 1, 4, 2000 | the generator's size (about 40 s, about 42 MB) |
| | `OCLJ_BITJIT_GENMODE` | empty | `phi`: PHI-heavy statements |
| | `OCLJ_BITJIT_HOTMIN` | 0.25 | the coverage gate |
| | `OCLJ_BITJIT_OUT` | fresh `$OCLJ_BUILD/bitjit-<stamp>` | |
| `run-bitfuzz.sh` | `OCLJ_BITFUZZ_SEED`, `_SEEDS`, `_CASES`, `_TUPLES` | 1, 1, 1000, 16 | PUC is required (otherwise exit 2) |
| | `OCLJ_BITFUZZ_HOTMIN` | 0.25 | the coverage gate, for H and for U |
| | `OCLJ_BITFUZZ_STRICT` | 0 | 1: also compare the type error's verb |
| | `OCLJ_BITFUZZ_PRUNE` | 0 | 1: delete a passing seed's tuple files |
| | `OCLJ_BITFUZZ_OUT` | fresh `$OCLJ_BUILD/bitfuzz-<stamp>` | |
| `negctl-bitop.sh` | `OCLJ_NEGCTL_ARMS` | every arm | canon always runs |
| | `NEGCTL_GEN_SEEDS`, `NEGCTL_FUZZ_CASES` | 4, 1000 | every other runner knob is pinned |
| | `OCLJ_LUAJIT`, `OCLJ_SER`, `OCLJ_JNI`, `JOBS` | pristine tree, `serializer/`, auto, 4 | its work directory is `$OCLJ_BUILD/negctl-bitop/<stamp>-<pid>` |

## Appendix A. File map: where each round-3 piece lives

| piece | repo file | lands in (build copy) | key functions | held by |
|---|---|---|---|---|
| the rules | `native/luajit/oclj_bitop.h` | included by lj_parse.c, lj_record.c and lj_opt_fold.c (each by its patch script) and by oclj_bitop_meta.c | `oclj_bitop64`, `oclj_bit2num`, `OCLJ_IRCONV_EXACT` | matrix, fuzzer; NEGSHIFT, SARSHR |
| 5.3.6 number readers | `native/luajit/oclj_num53.h` | included by oclj_bitop.h and oclj_strpack.c | `oclj_flt2int`, the string readers | RANGE-HI |
| parser folding | `native/luajit/patch-bitop-parse.sh` | `lj_parse.c` | `foldbitop`, the unary `~` fold in `bcemit_unop` | t_fold, fuzz K; WRAP32-FOLD, NOINT-FOLD, INEXACT-FOLD |
| interpreter fast path | `native/luajit/patch-bitop-vm.sh` | `vm_x64.dasc` | `BC_BNOT`, `ins_bitop`, `->vmeta_bitop_pc` | t_ops, fuzz V; WRAP32-INTERP, SHIFTMASK, INEXACT-INTERP, INEXACT-BNOT |
| slow path | `native/luajit/oclj_bitop_meta.c`, `patch-bitop-meta.sh` | `lj_meta.c` | `lj_meta_bitop` → `oclj_meta_bitop`, `ob_toint`, `ob_errv` | t_ops-str, coerce; STRCOERCE, ERROPERAND, INEXACT-SLOW |
| recorder | `native/luajit/oclj_bitop_rec.c`, `patch-bitop-record.sh` | `lj_record.c` | `oclj_rec_bitop`, `oclj_rec_bitarg`, `oclj_rec_bitval`, `oclj_rec_bitcount` | gen, t_rec, t_jit2; NOINT-JIT, SARCONST, INEXACT-JIT |
| fold engine | `native/luajit/patch-bitop-fold.sh`, `oclj_bitop_fold.c` | `lj_opt_fold.c` | `simplify_conv_i64_num`, `oclj_bitwidth`, `narrow_convert`, the seven int64 folds | gen, t_rec, fuzz U, p4v; NARROW, KFOLD64, SELFGUARD, WIDTH55, WSHR, WBAND, WADD0, WSHL0, FIX1 |
| dump version | `native/luajit/patch-bitop-bcdump.sh` | `lj_bcdump.h` | `BCDUMP_VERSION` 0x80 | security FF12, gate `dump=`; BCDUMP |
| jit tools | `native/luajit/patch-bitop-jitlib.sh` | `lib_jit.c` | `jit_util_funcbc`, `jit_util_tracesnap` | the jit tools gate |
| feature word | `native/luajit/oclj_features.h` | included by lj_arch.h | `OCLJ_OPS_BIT64` | the `-dM` gate |
| fingerprint token | `serializer/eris_lj.c` | `eris_lj.o` | `ELJ_W_BIT` (`bit64`) | stage 4; WORDTOKEN |
| build gates | `native/build-native.sh` | — | stage 1 freshness, echo, feature, warning and luajit.exe gates | their fail-firsts |
| tests | `test/native/run-bitop.sh`, `run-bitjit.sh`, `run-bitfuzz.sh`, `bitop/*`, `bitop_test.c` | — | [11](#11-verification-discipline) | fail-firsts |
| proof | `test/native/negctl-bitop.sh` | — | 27 arms, canon and restore | its own FF1-FF8 |
| evidence | `bench/runs/2026-10-17-bitop/` | — | README, `design/`, `failfirst*/`, `logs/` | the review |

## Appendix B. Glossary

- **arm (negctl)**: a one-line sabotage of a fix site, with the checks that must catch it. **BROKEN**: the arm changed no reached object, or changed an unreached one. **canon / restore**: rebuilding from unchanged sources must reproduce every object, before and after the arms. ([11.7](#117-negctl-one-line-sabotages))
- **blacklist**: `blacklist_pc` turns `FORL` into `IFORL` after 11 aborts; the loop is never recorded again ([2.5](#25-hot-counting-and-trace-start)).
- **build copy**: `build/native/luajit-<platform>`, the pristine tree plus our twelve changes and seven files ([1.2](#12-our-twelve-changes-to-luajit)).
- **census A/B**: the same unmodified workload run before and after a fix, abnormal exits counted per process: how crash fixes are proved ([11.10](#1110-crash-fixes)).
- **CHECKHOOK**: the hook-mask check near the head of every trace and again after its `LOOP` (P31; [docs/watchdog.md](watchdog.md)).
- **coverage gate**: a check that the JIT actually compiled a quarter of the loops; failing it makes a run PROVED NOTHING (exit 2) (P27).
- **CSE**: common-subexpression elimination, `lj_opt_cse` and `cse_conv` ([3.9](#39-cse-and-why-the-exact-mark-is-bit-0x400)).
- **exact mark**: bit 0x400 (`OCLJ_IRCONV_EXACT`) of a CONV's op2; on `num.i64` it says the double equals its int64 wherever used; on `i64.num` it marks a guard's own check ([3.9](#39-cse-and-why-the-exact-mark-is-bit-0x400)).
- **exit / exit stub**: the code a failed guard jumps to; it restores the interpreter state from a snapshot ([4.7](#47-exits)).
- **fail-first**: running a new check against a case that must fail it before trusting a pass ([11.8](#118-fail-first)).
- **fix1**: the type-stability condition on `simplify_conv_i64_num`: across a PHI, fold only to an int64-typed ref ([4.5](#45-fix1-the-worked-case)).
- **fold key**: `o << 17 | left->o << 10 | right->o`, with a literal op2 contributing `op2 & 0x3ff` ([3.6](#36-how-an-instruction-is-folded)).
- **guard**: an IR instruction with `IRT_GUARD`; if it fails, the trace exits ([8.6](#86-adding-a-guard)).
- **hunk engine**: the shared awk core of round 3's patch scripts ([7.5](#75-the-patch-script-engine)).
- **KINT / KINT64 / KNUM**: interned int32, int64 and double constants ([3.3](#33-references-constants-literals-trefs)).
- **marker**: the string a patch script leaves in its output, counted by the script and by build-native.sh.
- **option set**: a set of `-O` flags under which a suite runs, each exercising one path ([11.3](#113-option-sets)).
- **PHI / PHIBARRIER**: a loop-carried value at the loop branch; `PHIBARRIER` stops a rule from building a new instruction on a PHI operand's operand ([3.8](#38-what-a-rule-returns-and-upstreams-requirements), [4.2](#42-phis)).
- **pre-roll**: the recorded iteration, which runs once before the `LOOP` copy ([4.1](#41-copy-substitution)).
- **pristine tree**: `prototype/watchdog/luajit` at `1ee778a4`, tracked sources only ([1.1](#11-what-the-fork-is)).
- **side trace**: a trace recorded from a hot exit of its parent ([4.8](#48-side-traces)).
- **snapshot**: the slot→ref map and resume pc an exit restores ([4.3](#43-snapshots)).
- **stitch**: a trace that ends at a call the recorder cannot follow and links to the next trace ([4.6](#46-closing-a-trace-and-linking-it)).
- **TRef**: a ref plus its IR type and flags, what the recorder passes around ([3.3](#33-references-constants-literals-trefs)).
- **twin**: the same test program on PUC 5.3.6, generated from the same source, with the rule applied per operator ([11.2](#112-the-puc-twin)).
- **TYPEINS**: `LJ_TRERR_TYPEINS`, a loop-carried value whose IR type changes between the pre-roll and the copy ([4.4](#44-type-instability-typeins-retry-blacklist)).
- **U1-B**: the user's 2026-10-17 decision: a result with more than 53 significant bits raises, every other result is 5.3.6's.
- **width rule**: fold `(i64)(num)y` to `y` when `oclj_bitwidth(y)` ≤ 54 ([3.11](#311-oclj_bitwidth-the-bound)).

## Open questions

Claims this guide could not settle, and gaps it found. Each unsettled claim is marked [I] where it appears.

1. **The `num PHI` that stays alive** (0048 in [8.7](#87-reading-a--jdump)): attributed to SNAP #3 naming it; `loop_emit_phi`'s redundancy passes were not traced.
2. **`exit 5` once, then `exit 1` ten times** in `side1` ([4.8](#48-side-traces)): explained by later iterations entering through `JFORL` at the trace head; consistent with the dump, not traced in code.
3. **Re-executability between a snapshot and a guard** ([4.3](#43-snapshots)): read from the `needsnap` sites and stated as LuaJIT's design; not audited exhaustively.
4. **The `jp` after `ucomisd`** in the interpreter ([6.7](#67-round-3s-checks-instruction-by-instruction)): necessary by the ISA; no negctl arm removes it.
5. **Int-typed operands under spill pressure** ([5.1](#51-our-ir-in-x64)): no test forces register pressure and spilling of a zero-extended index into an int64 op.
6. **The hunk engine's `ncr()` check cannot fail on Git Bash** ([7.3](#73-line-endings-and-the-git-bash-instrument)): a prove-a-check-can-fail gap. A fix (`awk -v BINMODE=1`, or a byte count) changes all seven scripts identically and needs its own fail-first.
7. **GC64 pointer arithmetic that reassociates KINT64 constants now folds** ([3.10](#310-the-two-rules)): from the implementation review's reading; not measured.
8. **`oclj_bitop.h`'s list of `IRCONV_NUM_INT` equality tests omits lj_asm_x86.h ~:1993** (`asm_x87load`, 32-bit only, harmless): a comment fix for the next round that touches the header.
9. **Compound bitwise assignments have no suite** ([2.2](#22-lexer-and-parser)): `&= |= ~= <<= >>= ~>>=` reach the same emitter and were probed by hand for this guide, but PUC 5.3 has no such forms, so the twin, the generator and the fuzzer cannot produce them, and no file in `test/native/bitop/` uses one.
10. **review1's CRC32 material lives outside the repo** ([8.8](#88-where-the-crc32-follow-up-starts)): `t_idx.lua`, `t_cnt33.lua`, `refidx.lua` and both prototype diffs sit in this machine's work directory, written against the U1-A prototype. The CRC32 round archives what it reuses and adapts `refidx.lua` to U1-B; whether t_idx's other cases need new expectations under U1-B has been checked only as JIT = `-joff` on the shipped build.
11. **The rg2 speculation's cost under U1-B is unmeasured**: review1's timings ([8.8](#88-where-the-crc32-follow-up-starts)) are from the U1-A prototype, where crc was a double PHI; on this build crc is already an i64 PHI and the result guards sit beside the chain, so the gain may differ.
12. **Some [M] probes are described, not printed**: 2.2's upvalue loop, 2.5's hot-count and FNEW loops, 12.1's `p_typeins2.lua` and P39's blacklist probe live only in this guide's scratch directories. The four the pipeline sections lean on most (`side1`, `side2`, `exit1`, `abort2`), `guide1` and `crcprobe` are printed in full; a review re-creates the others from their descriptions.
