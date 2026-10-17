# 2026-10-17 -- Lua 5.3's bitwise operators with 64-bit results, in the parser, the interpreter and the JIT

The evidence behind the roadmap row "Lua 5.3's bitwise operators with 64-bit results" (row 208).
`&`, `|`, `~` (binary and unary), `<<` and `>>`, and LuaJIT's own `~>>`, compute Lua 5.3.6's
64-bit integer results on our no-FFI LuaJIT, in the parser's constant folding, the interpreter
(the `vm_x64.dasc` fast path and a C slow path) and the JIT.

- **The rule (U1-B, decided by the user 2026-10-17):** every number is still a double, so a result
  with more than 53 significant bits raises `result of '<op>' has more than 53 significant bits
  (mask each operand to 32 bits first)`. Every result that does not raise is exactly 5.3.6's. The
  hint was added after the harness found the rotate idiom (below).
- **The code:** `native/luajit/oclj_bitop.h` (the rules), `oclj_bitop_meta.c` (the slow path),
  `oclj_bitop_rec.c` (the recorder), `oclj_bitop_fold.c` (the fold engine's width bound) and
  `oclj_num53.h` (the number readers, now shared with `string.pack`). Seven LuaJIT patches,
  `native/luajit/patch-bitop-{parse,vm,meta,record,fold,bcdump,jitlib}.sh`, change the build copy's
  `lj_parse.c`, `vm_x64.dasc`, `lj_meta.c`, `lj_record.c`, `lj_opt_fold.c`, `lj_bcdump.h` and `lib_jit.c`.
- **The JIT:** an operator's int64 result becomes a double through a conversion marked
  `OCLJ_IRCONV_EXACT` (op2 bit 0x400), followed at once by a guard that converts it back and
  compares. A marked conversion's round trip folds away, so chained operators stay in int64; the
  width rule drops the guard where a result provably has at most 54 bits. fix1 (the review's
  type-instability fix) is in.
- **Persistence:** `BCDUMP_VERSION` is 0x80, and the blob fingerprint's word gains a ninth token,
  `bit64`.

Implemented in the working tree on c9ae4f9 (round 2, committed), uncommitted.

How it was run:

- **Harness:** on ocelot-brain, with JDK 8 (1.8.0_504) on Windows 11 and the Windows DLLs, one JVM
  at a time, not core-pinned: functional runs.
- **Native tests:** on Windows in place, and on Linux in WSL (Ubuntu 26.04). No harness run loaded
  the Linux .so.
- **Reference:** PUC Lua 5.3.6, `bench/vendor/lua-5.3.6/src/lua.exe` on Windows and
  `C:/Users/astro/claude-tmp/oclj/puc536-linux/lua` on Linux.

## The builds

- **Round 2, the fail-first:** round 2's natives in `build/native` when the fail-firsts ran (additive
  `0f55e727`, dropin `f554beeb`, luajit.exe `c33d49d1`; `failfirst/build-under-test.md5`), frozen at
  `C:/Users/astro/claude-tmp/oclj/new-r2-0f55e727`.
- **Round 3's first build** (`logs/builds/`): additive `8c272b0b`, dropin `f7be192f`, frozen at
  `new-r3-8c272b0b`. All 77 LuaJIT objects are byte-identical to the implementer's scratch build
  that the 26-arm negctl ran against. It ran every suite, the first campaign and the first harness
  chain, which found the rotate idiom.
- **The final build** (`logs/builds-2/`), after the hint, the tooling patch and the review's fixes.
  The harness ran its DLLs from a frozen copy, `new-r3f-9ae455ce/`.

| native | md5 | size |
|---|---|---|
| Windows additive DLL | `9ae455ce` | 739 237 B |
| Windows dropin DLL | `2c37a7a1` | 736 585 B |
| Linux additive .so | `7e8b8b89` | 734 096 B |
| Linux dropin .so | `cdad2167` | 732 992 B |

- Against the first build only `lj_meta.o` (the message) and `lib_jit.o` (the tooling patch) changed
  among the 77 LuaJIT objects (`logs/builds-2/objects-changed.txt`). So the code the JIT generates is
  the first build's, and the first campaign covers it too.
- The serializer hash is `412be694`. The fingerprint is
  `1ee778a4|LuaJIT 2.1.ROLLING|412be694|ffi0.lua52.gc64.fr2.dn0.le.p64.pack1.bit64`. GG_State is
  6376, unchanged. The ABI surface is 87/89 (dropin) and 91/93 (additive).
- **Windows:** dropin, then additive, so `obj-windows-x86_64/` and every Windows native test hold
  the ADDITIVE variant's objects.
- **Linux:** built afterwards in WSL, dropin then additive (`logs/linux/`), the first ELF run of
  round 3's `build-native.sh` (`lj_vm.S` and its freshness check, the DynASM echo gate). Both .so
  files still need GLIBC_2.38 (`logs/linux/glibc.txt`), as in round 2; the glibc round comes next.
- **The jar:** `build/libs/ocluajit-c9ae4f9-master+c9ae4f972e-dirty.jar`, md5 `497ec707`, 703 895 B. A
  dirty-tree build, not installed in the game.

## The rotate idiom, and the user's decision

The first harness chain (`logs/harness-prefix/`) failed `p1-sha256` in every arm that runs it:
`[string "compat-bitops"]:11: result of '|' has more than 53 significant bits`. Line 11 of the
benchmark's `bench/oc/compat.lua` is 5.3's usual rotate, `((a >> n) | (a << (32 - n))) &
0xFFFFFFFF`. The `|` joins the two pieces into up to 64 - n significant bits before the mask, so a
right rotation by 1 to 10 raises, and so does a left rotation by 22 to 31. `design/rotate/` has the
measurement: 10 000 random 32-bit words, at SHA-256's rotation counts.

| VM | by 2, 6, 7 | by 11 or more | masked form `(a >> n) \| ((a << (32 - n)) & 0xFFFFFFFF)` |
|---|---|---|---|
| this build (U1-B) | raises for 9890, 8924, 8162 | exact | exact |
| the A prototype (rounding) | silently wrong for the same words | exact | exact |
| the round-2 tree (32-bit) | right modulo 2^32 (BitOp's signed form: the probe's "wrong" counts are the negative results) | the same | the same |
| PUC 5.3.6 | exact | exact | exact |

The design had told the user that with ordinary operands only `>>` of a negative number gives an
inexact result, and that code masked to 32 bits matches. Both are true of one operator and false
of chained ones. LuaJIT's own `jit/bc.lua` showed the same class: it shifts signed 32-bit bytecode
words, so `luajit -jdump` aborted traces and `luajit -bl` raised (the review's finding).

The user kept U1-B and chose a hint in the message. Then:

- `bench/compat.lua` and `bench/oc/compat.lua` rotate in the masked form, which gives the reference
  digest on PUC 5.3.6, on this build and on the round-2 build.
- A seventh patch, `patch-bitop-jitlib.sh`, makes `jit.util.funcbc` and `jit.util.tracesnap` return
  their bit-field words unsigned, so `jit/bc.lua` and `jit/dump.lua` stay exact. A new build gate
  checks that `-bl` and `-jdump` work.
- The README documents the rotate and its remedy.

## Results

| check | fail-first | this build |
|---|---|---|
| `run-bitop.sh` part 1: `t_ops` (7467 cases), `t_fold` (63), `t_sar` (437), `t_bit` (2109), exact against the `.expect` files, JIT on and `-joff`; `coerce_agree` | round 2: FAIL `t_ops` 6771 lines, `t_fold` 45, `t_sar` 313, `coerce_agree` 29 disagreements; `t_bit` passes (`failfirst/run-bitop.log`). First build: FAIL exactly the 550/11/5 inexact lines, which want the hint (`failfirst2/run-bitop.log`) | PASS, 550/11/5 of them raising; Windows and Linux |
| part 2, provenance against PUC 5.3.6: PUC with the rule differs from the `.expect` files in exactly `deviations.txt`'s lines; `xrule.lua` checks the rule against PUC's own integers | PASS (it judges the files) | Windows 2/10/0 lines, Linux 2/10/0; `xrule` agrees on every line |
| part 3, `bitop_test.c` through the shim (12) | round 2: 11 failures; BT4b, the instrument's control, passes. First build: BT3a-d (the hint) | 12/0, Windows and Linux |
| `run-bitjit.sh`: the generator (4 seeds x 2000 loops, 5 option sets x 2 closure modes, and the PUC twin), the floor (`t_rec`, `t_jit2`), fix1 | round 2: every seed FAILs; `t_rec` 125-141 lines per seed; `t_jit2` 2 lines and 25 against PUC (`failfirst/run-bitjit.log`) | PASS; a trace completed in 67-69% of the generated loops |
| `run-bitfuzz.sh`, default (1000 cases x 16 tuples, five modes, three controls) | round 2: 12 198 mismatches of 16 000 (`failfirst/run-bitfuzz.log`) | 0, controls as designed; Windows and Linux |
| `security_test.c` (56) | round 2: FF9, FF10 and FF12 fail (the 0x80 fixtures) | 56/0 |
| the build's bitwise-operator gate | round 2: `fold=1/-1/1 kx=2147483647 ... dump=2 ... hot=322122623506@300` (`failfirst/bitops-gate.out`) | `... dump=128 bit=1 hot=X>>@151 acc=43800 jit=1/0/0 same=true` |
| the build's jit tools gate | first build: `bl=0 blerr=1 bldec=0 jd=5/0/4/4` (`failfirst2/jit-gate.log`) | `bl=118 blerr=0 bldec=3 jd=1/1/0/0 jdb=12/1`, Windows and Linux |
| the VM-features word | round 2: `...pack1` (eight tokens) | `...pack1.bit64`; `luajit.exe` agrees on bit64 |
| serializer `tests/bitop.lua` (7) | round 2: 3 failures (`failfirst/serializer-test.log`); first build: the message check (`failfirst2/serializer-test.log`) | 7/7, Windows and Linux |
| serializer `tests/fingerprint.lua` (20) | round 2: 20/20, see deviation 8 | 20/20, Windows and Linux |
| for-in fixture | regenerated with the first build (`logs/fixture-2/`): 8 bytes differ, the three dumps' version bytes 0x02 to 0x80 and five in the masked frame-link payload | for-in exact, Windows and Linux |
| gradle `verifyModAssets` (the whole word, exactly) | round 2's natives refused (`failfirst/gradle-r2.log`); this build's DLL with both `.pack1.bit64` edited to `.pack1.bit32`, its serializer hash still right, refused (`logs/gradle/bit32.log`, the real task) | accepted: `native fingerprint matches the serializer sources and the LuaJIT feature set (412be694\|ffi0.lua52.gc64.fr2.dn0.le.p64.pack1.bit64)` (`logs/gradle/control.log`) |
| harness `d5-sandbox-bitwise`, additive | round 2: FAIL, the 32-bit line, 82 checks / 1 failure (`failfirst/harness/`) | PASS `ok/1:0/-2147483648:0/inexact>>/inexact\|/0:0/0:1/noint/0:16/11:98566144/2097151:4294967295/0:16777215` |
| harness d5, stock | PASS `absent`, 53 / 0 | PASS `absent` |
| harness `p1-sha256` | first build: FAIL in five arms, the rotate (`logs/harness-prefix/`) | PASS |

**Native suites:**

- **Windows** (`logs/suite-native-2/`): shim 57/0, security 56/0, race 2/0, mem 86/0, vgc 47/0,
  wd 35/0, penalty 6/0, run-pack 13/0, the pack fuzz default 0 mismatches; `negative-control.sh`
  56 `RESULT: PASS`.
- **Linux** (`logs/linux/`): the same suites but race, which exits 2 (Win32-only, as designed), and
  run-bitop, run-bitjit and run-bitfuzz with the Linux PUC; the serializer `make test` and
  `make negctl`.
- **Serializer negctl:** `NEGCTL-FINGERPRINT: PASS (all four sabotages caught)`, the new `bitword`
  arm among them, Windows and Linux.

**`negctl-bitop.sh`:** 27 one-line sabotages. Each is anchored and changes one line. Only the
objects it reaches are rebuilt, and every other object must stay byte-identical. Each must be
caught by every catcher named for it. Results:

| arms | caught by |
|---|---|
| WRAP32-INTERP, SHIFTMASK, INEXACT-INTERP, INEXACT-BNOT (`vm_x64.dasc`) | the matrix and the fuzzer's V mode |
| WRAP32-FOLD, NOINT-FOLD, INEXACT-FOLD (`lj_parse.c`) | `t_fold`, the fuzzer's K mode |
| NEGSHIFT, SARSHR (`oclj_bitop.h`); RANGE-HI (`oclj_num53.h`); STRCOERCE, ERROPERAND, INEXACT-SLOW (`oclj_bitop_meta.c`) | the matrix, `coerce_agree`, the fuzzer |
| NOINT-JIT, SARCONST, INEXACT-JIT (`oclj_bitop_rec.c`) | `t_jit2`'s guard-exit loop, `t_rec`'s counts seeds, the generator |
| NARROW, KFOLD64, SELFGUARD, WIDTH55, FIX1 (`lj_opt_fold.c`); WSHR, WBAND, WADD0, WSHL0 (`oclj_bitop_fold.c`) | the floor, the fuzzer's U mode, the generator, fix1 |
| BCDUMP (`lj_bcdump.h`); WORDTOKEN (`eris_lj.c`) | security FF12 and the gate's dump field; stage 4 |

Canon and restore reproduce every object. Every arm passes, on Windows in 7 min 57 s
(`logs/suite-native-2/negctl-bitop.log`) and on Linux in 6 min 20 s (`logs/linux-negctl/`); Linux is
the first ELF run, where `lj_vm.o` comes from `lj_vm.S`. `negctl-pack.sh` passes its 28 arms, with
`oclj_num53.h` shared.

**Harness, this build** (`logs/harness/`):

| arm | checks / failures |
|---|---|
| additive, JIT on | 82 / 0 |
| dropin | 69 / 0 |
| additive, JIT off | 80 / 0 |
| sieve | 76 / 0 |
| stock | 53 / 0 |
| disposeoff (`OCLJ_DISPOSE=off`) | 82 / 0 |
| bundleoff (`OCLJ_PERSIST_BUNDLE=off`) | 82 / 3: stk-2, stk-3 and stk-4, the expected three |

Each arm has one more check than round 2: d5. d3 and d4 pass on every arm as before.

**Campaigns:**

- **The first build** (`logs/campaign/`):
  - the generator, seeds 101-120 x 2000 loops (plain) and 201-220 (PHI-heavy): 0 differences in
    every option set and the PUC twin;
  - `t_rec`, 400 recurrences on 40 seeds (101-120, and 121-140 with out-of-range counts), under the
    default options, `-O3 -Ohotloop=1` and `-Omaxside=0`: 0 lines differ from `-joff`;
  - the fuzzer, seeds 11-60 x 20 000 cases x 16 tuples: 16 000 000 tuples, 0 mismatches in every
    mode, every control as designed (`sim-raw` and `sim-round` each fail in exactly the INEXACT
    tuples). The run's verdict line is lost: see deviation 9.
- **The final build** (`logs/campaign-2/`), the same four, with the tagged result directories:
  the generator 20 + 20 seeds, 0 differences; `t_rec` 40 seeds, 0 lines; the fuzzer, seeds 11-60:
  16 000 000 tuples, 4 792 268 of them raising the 53-bit error in the reference, 0 mismatches in
  every mode, `BITFUZZ PASS`, in 39 min 48 s.

**Speed** (`logs/bench/`, unpinned, the round-2 tree and this build alternating in one run):
three runs each (`logs/bench/bench.txt`):

| | round-2 tree (32-bit) | this build |
|---|---|---|
| masked bit loop, ns per iteration | 0.30-0.35 | 0.30-0.40 |
| RGB pack/unpack, ns | 3.7 | 3.7 |
| CRC32 by table, ns per byte | 2.8-2.9 | 7.2 |
| CRC32 bit-serial, ns per byte | 48-49 | 69.5-70 |

The prototype's figures, as expected: the JIT's objects are its. The table CRC pays for the table
index's conversion and for exactness guards on values read from the table, whose width the fold
cannot bound: the CRC32 follow-up row. The two CRC results are equal modulo 2^32 (3386490367 here, -908476929 in BitOp's
signed form). Two idle Gradle daemons from the jar build were running (`logs/bench/jvms.txt`).

## Deviations from the contract (`design/design.md`, `design/design-B.md`)

The contract was reviewed twice. `design/review1-results.json` is the design-stage review: the
width fold's soundness, the paths, the strings and the table-index fold. `design/review2-results.json`
is the implementation review: five dimensions, each with an adversarial verifier; no high-severity
defect, 18 findings, 17 confirmed and 1 refuted. The six implementers' reports are in
`design/impl-reports/` and the three fixers' in `design/fix-results.json`.

1. **The hint**, the user's decision after the rotate finding (above). The message is the contract's
   followed by ` (mask each operand to 32 bits first)`. The matrices pin it exactly (re-derived from
   PUC, the same 550/11/5 lines with the hint appended), and so do `bitop_test.c` BT3a-d and
   `serializer/tests/bitop.lua`. The generator and the fuzzer classify by the text up to `bits`.
2. **The tooling patch**, the seventh: not in the contract. Without it, `-jdump` aborts the traces
   it should show and `-bl` raises. `jit.util.tracek` still returns no value for KINT64 without
   FFI, so `-jdump` prints int64 constants wrongly; this is roadmap row 206's gap, unchanged.
   `luajit -b` to object files needs FFI (`bcsave.lua`), so its `bswap(x) >> 16` is unreachable.
3. **The bitops gate gains `acc`**, the running sum of the hot loop's 150 exact iterations (43800,
   from PUC). Before it, the gate could not see a wrong in-range value; KFOLD64 now fails it.
4. **The review's test fixes:**
   - `run-bitjit.sh` counts differences in both directions;
   - a crash on our side makes a fuzz seed 1, not 2;
   - the fuzzer checks that its JIT-on run had the JIT on;
   - zero-size knobs are refused;
   - `LUA_INIT` is unset;
   - three wide decimal and hex literals are now visible to the provenance and listed in
     `deviations.txt` as LEX (`t_fold` 10 lines, was 7);
   - INEXACT-BNOT is a new negctl arm.
5. **INEXACT-RECABORT is dropped** from negctl, as design-B allowed: measured uncatchable, since only
   the abort reason changes. With INEXACT-BNOT added, there are 27 arms.
6. **`1 &&` is dropped** from the fold rule's two conditions, a leftover of the prototype's variant
   switch: `lj_opt_fold.o` is byte-identical.
7. **The figures moved:**
   - `fingerprint.lua` has 20 checks (the contract said 19);
   - `serializer/tests/bitop.lua` has 7 (6), re-derived for U1-B;
   - `t_jit2.lua` was rebuilt, 27 loops with the iteration of each raise (the A-era file had lost
     its teeth under U1-B);
   - the fuzzer's coverage gate is 0.25 (0.5);
   - the harness probe runs each row in its own pcall.
8. **The fingerprint fail-first is the implementer's.** Run here on round 2's archive, the new
   `fingerprint.lua` passes 20/20 (`failfirst/serializer-test.log`). That `eris_lj.o` reads round 2's
   feature header, says `bit32`, and agrees with 32-bit operators, which is the check working. The
   fail-firsts against an eight-token word and a word claiming bit64 over a 32-bit archive are in
   `design/impl-reports/impl-B.json`.
9. **The first campaign's fuzz verdict:** the fixes were being written while it ran, and
   `run-bitfuzz.sh` changed under the running shell. After seed 60 the shell read the new file at a
   stale offset (`line 193: syntax error near unexpected token 'then'`, exit 2). Every seed's line
   and comparator output is complete and was run by the old script; the final build's campaign
   reruns it whole.

## Not done

- **No JVM has loaded the Linux .so,** and the .so needs glibc 2.38 (the glibc round, next).
- **Not tried in the game:** boot, save and restore on the new jar.
- **The table-driven CRC32 is slower** than with round 2's 32-bit operators (roadmap: the CRC32
  follow-up row, a range guard and a table-index fold).
- **Bitwise metamethods and `//`** are a later round (roadmap row 210).
- **`bench/oc/run-standalone.sh check`** still reports `DRIFT: ingame-ladder.lua ... has no line in
  references.txt`, as it has since d20a14d; not this round's.

| path | what |
|---|---|
| `failfirst/` | the round-3 tests on round 2's build: `run-bitop`, `run-bitjit`, `run-bitfuzz`, `security`, `serializer-test`, `gradle-r2` (`.log`, `.exit`, `.start`, `.end`); `bitops-gate.lua`/`.want`/`.out`/`.verdict` (the build's gate, its own text, on round 2's `luajit.exe`); `build-under-test.md5`; `harness/` (the round-3 harness on round 2's natives, additive and stock, and its chain log) |
| `failfirst2/` | the fixes' fail-firsts on round 3's first build: `run-bitop`, the jit tools gate and the bitops gate (their own text, through `scripts/run-gate.sh`), `serializer-test` |
| `logs/builds/`, `logs/builds-2/` | the Windows build logs and LuaJIT logs of both variants, first and final build; `natives.md5` (DLLs and every object); `sources.md5`; `objects-changed.txt` (builds-2) |
| `logs/fixture-2/` | the for-in fixture's regeneration and its comparison with the old one |
| `logs/suite-native/`, `logs/suite-native-2/` | every Windows native suite, first and final build, with the three negctls and `negative-control.sh`; one `.log`, `.rc`, `.start` and `.end` each |
| `logs/linux/` | the WSL builds, every Linux suite, the round-3 suites, the serializer; `summary.txt`; `host.txt`; `glibc.txt` |
| `logs/linux-negctl/` | `negctl-bitop.sh` on Linux |
| `logs/harness-prefix/`, `logs/harness/` | the seven harness arms on the first build (the rotate) and on the final build: `run.log`, `args.txt`, `env.txt` where set, `native.md5`, `exit.txt`, `started.txt` and `finished.txt` (UTC); the chain logs |
| `logs/campaign/`, `logs/campaign-2/` | the campaigns on the first and the final build |
| `logs/gradle/` | `verifyModAssets` on a bit32-edited DLL and on the build, and the jar build |
| `logs/bench/` | the speed rows |
| `design/` | `design.md`, `design-B.md` (the contract); the two reviews' results; `impl-reports/`; `fix-results.json`; `rotate/` (the rotate probe and its outputs on four VMs) |
| `scripts/` | `full.sh` (one harness run); `chain-r3ff.sh`, `chain-r3.sh` (the harness arms); `ff-r3.sh`, `ff2-r3.sh` (the fail-firsts); `ffall-r3.sh`; `build-r3.sh`; `fixture-r3.sh`, `cmp_forin.py`; `native-tests-r3.sh`; `final-r3.sh`, `post-r3.sh` (the final chains); `wsl-r3.sh`, `wsl-negctl-r3.sh`; `campaign-r3.sh`; `gradle-r3.sh`; `run-gate.sh`; `bench-r3.sh`, `bench_bit.lua`, `bench_bit2.lua` |

The scripts hard-code local paths: the work tree under `C:/Users/astro/claude-tmp/oclj`, the repo,
OC-JNLua, ocelot-brain and the JDK. Windows logs are CRLF in the working tree; `.gitattributes`
normalizes them on commit, as for every earlier archive. The binaries are not archived; their md5s
are. The two the scripts wrote here were moved to `C:/Users/astro/claude-tmp/oclj/r3/archive-binaries/`:
the bit32-edited DLL (`8454031f`, `logs/gradle/bit32-edit.txt`) and the regenerated fixture
(`299c8193`, identical to `serializer/tests/fixtures/forin-identity.blob`).
