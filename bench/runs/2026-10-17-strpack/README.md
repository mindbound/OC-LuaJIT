# 2026-10-17 -- string.pack, string.unpack and string.packsize: Lua 5.3.6's, in our fork's string library

The evidence behind the roadmap row "`string.pack`, `string.unpack` and `string.packsize`: Lua 5.3.6's,
in our fork's string library" (directly after the FFI row). Our LuaJIT's own string library now has
the three, with Lua 5.3.6's whole format language:

- `native/luajit/oclj_strpack.c` is the port of 5.3.6's `lstrlib.c` PACK/UNPACK section, with the
  argument conversions of its `lauxlib.c`, `lobject.c` and `lvm.c`.
- `native/luajit/patch-strpack-register.sh` (the fifth LuaJIT change) adds three `LJLIB_CF`
  registrations to the build copy's `lib_string.c`, so `luaopen_string` carries them everywhere.
- `oclj_features.h` names the addition (`OCLJ_LIB_STRPACK 1`), and the fingerprint word gains a
  `pack1` token.
- Two decided deviations from 5.3.6: an unpacked integer beyond 2^53 is the nearest double of
  5.3.6's (wrapping) 64-bit value, and `l`/`L` are 8 bytes everywhere. The VM residuals are listed
  in `test/native/pack/deviations.txt` and the README's "Lua dialect".

Implemented in the working tree on 5d782d7 (round 1, committed), uncommitted.

How it was run:

- **Harness:** on ocelot-brain, with JDK 8 (1.8.0_504) on Windows 11 and the Windows DLLs, one JVM
  at a time, not core-pinned: functional runs.
- **Native tests:** on Windows in place, and on Linux in WSL (Ubuntu 26.04). No harness run loaded
  the Linux .so.
- **Reference:** PUC Lua 5.3.6, `bench/vendor/lua-5.3.6/src/lua.exe` on Windows; on Linux a 5.3.6
  built by the design's port investigator (`C:/Users/astro/claude-tmp/oclj/puc536-linux/lua`).

## The builds

**Round 1, the fail-first:** round 1's natives, frozen at `C:/Users/astro/claude-tmp/oclj/new-r1-aa0f3fa9`
(additive `aa0f3fa9`, dropin `a0bbb5fa`), which `build/native` still held when the fail-firsts ran
(`failfirst/build-under-test.md5`).

**This build:**

| native | md5 | size |
|---|---|---|
| Windows additive DLL | `0f55e727` | 732 544 B |
| Windows dropin DLL | `f554beeb` | 729 380 B |
| Linux additive .so | `036165c2` | 729 456 B |
| Linux dropin .so | `fc057735` | |

- The md5s are in `logs/builds/natives.md5` and `logs/linux/host.txt`.
- The serializer hash is `baf083da`, as the contract predicted. The fingerprint is
  `1ee778a4|LuaJIT 2.1.ROLLING|baf083da|ffi0.lua52.gc64.fr2.dn0.le.p64.pack1`.
- **Windows:** dropin, then additive, so `obj-windows-x86_64/` and every Windows native test hold
  the ADDITIVE variant's objects. The harness ran the DLLs from a frozen copy, `new-r2-0f55e727/`.
- **Linux:** built afterwards in WSL, dropin then additive (`logs/linux/`), with Ubuntu 26.04's
  glibc 2.43 and gcc 15.2. Both .so files need GLIBC_2.38 (`logs/linux/glibc.txt`), so neither
  would load on Ubuntu 22.04, Debian 12 or RHEL 9. That is not this round's (round 1's .so needed
  the same); building against a glibc floor is a separate change. No JVM has loaded them.
- **Sources:** md5s at build time in `logs/builds/sources.md5` (the docs were edited after the
  builds; no source the builds read was).
- **The jar:** `build/libs/ocluajit-5d782d7-master+5d782d7e09-dirty.jar`, md5 `0d37e346`. A
  dirty-tree build, not installed in the game.

## Results

| check | round 1's build (fail-first) | this build |
|---|---|---|
| `run-pack.sh` part 1: `conformance.lua` (308 cases) and `conf-extra.lua` (411), exact against the checked-in `.expect` | FAIL both: `string.pack/unpack/packsize missing` (`failfirst/run-pack.log`) | PASS both, Windows and Linux |
| part 2, provenance against PUC 5.3.6: the lines PUC differs in are exactly `deviations.txt`'s; with D1/D2 applied PUC equals the `.expect` but for the RESID lines | PASS (it judges the files, not the build) | Windows: 4 and 21 lines; applied, equal but 0 and 8 RESID lines. Linux: 2 and 16 lines; applied, equal but 0 and 8 |
| part 3, `pack_test.c` through the shim and the RAM cap | `FAIL PT1 ... 0 of 3 are functions` | 13/0 (PT1-PT7d), Windows and Linux |
| `run-packfuzz.sh`, default (seed 1 x 20 000 + ~240 edges) | exit 1, `no output from our side` (`failfirst/run-packfuzz.log`) | `seed 1: 0 -- lines 33953: EXACT 32749, DEVIATION 1204, SECONDARY 0, MISMATCH 0`, Windows and Linux |
| the fuzz campaign (`logs/fuzz/`) | -- | default profile, seeds 1000-1049 x 100 000 random cases and the fixed edges: 8 422 984 compared results, EXACT 8 127 399, DEVIATION 295 585 (D1's rounding), MISMATCH 0, in 13 min 26 s; `long` (5 x 300, strings to 16 MiB): MISMATCH 0; `coerce` and `limits` each exit 1 with exactly their one documented class, numbers given to `c`/`s`/`z` and unpack past 8000 results |
| `negctl-pack.sh`: 28 one-line sabotages of `oclj_strpack.c` and the unregistered library | -- | every one caught, canon passes (`logs/native-win/negctl-pack.log`; table below) |
| the build's string.pack gate (`failfirst/strpack-gate.lua`) | `fn=nil/nil/nil` (`failfirst/strpack-gate.out`) | `fn=function/function/function i4=feffffff method=true u=-2/5 I8max=true l=8/8 short=true int=true hot=14000 jit=0/1/0`, Windows and Linux |
| `FFDEF(string_pack...)` in the generated `lj_ffdef.h` | 0 (`failfirst/ffdef-string_pack.count`) | 3 |
| the `-dM` verdict | no `OCLJ_LIB_STRPACK` (design stage, `design/synth/gatecheck.log`) | `..., LJ_GC64 1, OCLJ_LIB_STRPACK 1` |
| the VM-features word | `...p64` (seven tokens) | `...p64.pack1`; `luajit.exe` agrees on pack1 |
| serializer `tests/fingerprint.lua` (18) | round 1's `eris_lj.c`: 3 failures, shape, pack agreement, eight tokens (design stage, `design/synth/failfirst-r1-fingerprint.log`); see deviation 3 | 18/0, Windows and Linux |
| serializer `tests/strpack.lua` (11) | stops at check 1, `nil/nil/nil` (`failfirst/serializer-test.log`) | 11/0, Windows and Linux |
| gradle's `verifyModAssets` (`<hash>\|ffi0.lua52.` and a word ending `.pack1`) | round 1's DLL refused; this DLL with both `.p64.pack1` edited to `.p64.pack0`, its serializer hash still right, refused (`logs/builds/gradle-failfirst.txt`, the real task) | accepted: `native fingerprint matches the serializer sources and the LuaJIT feature set (baf083da\|ffi0.lua52....pack1)` (`logs/builds/gradle-build.log`) |
| harness `d4-sandbox-string-pack`, additive | FAIL `absent`, 81 checks / 1 failure (`failfirst/harness/r2ff-additive-on-a`) | PASS `ok/feffffff/-2/5/true/true/l8/short` |
| harness d4, stock (OC's PUC 5.2 native) | PASS `absent`, 52 / 0 | PASS `absent` |

**Native suites:**

- **Windows** (`logs/native-win/`): shim 57/0, security 55/0, race 2/0, mem 86/0, vgc 47/0,
  wd 35/0, penalty 6/0 -- round 1's counts.
- **Serializer on Windows:** `make test` gives m1 82, m2 56, m3 79, stack-universe `FAILS: 0`,
  fingerprint 18/18, strpack 11/11 and for-in exact. `make negctl` gives `NEGCTL-FINGERPRINT: PASS
  (all three sabotages caught)`, `packword` among them.
- **`negative-control.sh`:** 56 `RESULT: PASS`, 0 FAIL, unchanged from round 1.
- **Linux** (`logs/linux/`): shim 57/0, security 55/0, mem 86/0, vgc 47/0, wd 35/0, penalty 6/0;
  race exits 2, Win32-only, as designed; `run-pack.sh` and the default fuzz run pass; the serializer
  `make test` (fingerprint 18, strpack 11) and `make negctl` pass.

**Harness, this build** (`logs/suite/`):

| arm | checks / failures |
|---|---|
| additive, JIT on | 81 / 0 |
| dropin | 68 / 0 |
| additive, JIT off | 79 / 0 |
| sieve | 75 / 0 |
| stock | 52 / 0 |
| disposeoff (`OCLJ_DISPOSE=off`) | 81 / 0 |
| bundleoff (`OCLJ_PERSIST_BUNDLE=off`) | 81 / 3: stk-2, stk-3 and stk-4, the expected three |

Each arm has one more check than round 1: d4. d3 passes on every arm as before.

**`negctl-pack.sh`, per arm** (each a one-line edit of `oclj_strpack.c`, anchored and asserted
once): conf-extra alone catches 26 of the 28; DOUBLEBUF is caught only by `pack_test.c` PT3 and
D4OFFBY1 only by PT7a/PT7b. The fuzzer catches 24 (not ORDER54, NONAME, DOUBLEBUF, D4OFFBY1);
LJCOERCE only through its random cases, since the review's change to the default profile.

**Cross-build fingerprint** (design stage, `design/synth/xbuild-matrix.out`, three runs alike):
without the `pack` token, a blob saved on a build without pack restored on a build with it, its
sandbox lacking `string.pack` until a reboot, and the other direction failed mid-restore on an
unknown permanent. With the token, both crossings are refused at the header.

**Consumers** (design stage, `logs/consumers/`): the real Plan9k `17_gpt.lua` passes its 14 GPT
tests on this VM for both Plan9k copies (`gpt-brain.out`, `gpt-gtnh.out`) and fails on round 1's
(`gpt-r1.out`). Plan9k's FAT driver now takes its 5.3 path and inherits a Plan9k bug there:
`final.out:40` (`unsigned overflow` in `setFATEntry12`) against the bit32 path at `:57`; PUC 5.3.6
raises the same (`ref536-win64.out:40`, `ref536-lp64.out:40`), and round 1's VM took the fallback
(`proto-nopack.out:40`).

## Deviations from the contract (`design/design.md`)

The contract was written before the review (`design/review-findings.json`: four reviewers, each
reviewer's findings put to a skeptic, and a completeness critic; 27 findings, 26 confirmed, 1
refuted). The fixes were applied from `design/fix/fixes.md` by six implementers and checked by
three verifiers (`design/fix/fix-result.json`); the main session then fixed the verifiers' 13
remaining points by hand (`design/fix/fix_docs.py`, `devbad-proof.txt`).

1. **D3's text carried a position.** The port raised 5.3.6's "memory allocation error: block too
   big" with `luaL_error`, which prefixes the caller's `chunk:line:`; 5.3.6 raises it from
   `luaM_toobig`, which adds none when a C function is running. Every normaliser stripped the
   prefix, so no test could see it. Now `lua_pushliteral` + `lua_error`, and a new conf-extra case
   records the raw message of a non-tail call; on the old line it differs (verified by building
   it).
2. **Tests that could not fail, or tested less than they said.**
   - D4 (a result of `LJ_MAX_STR` or more) had no test: `pack_test.c` PT7a-d, and arm D4OFFBY1.
   - Provenance checked only which lines differ from PUC, not how: part 2 now runs PUC with D1/D2
     applied and requires equality outside the RESID lines. A RESID class now needs a RESID id, or
     a DEV line could have been refiled as RESID with a wrong value (`design/fix/devbad-proof.txt`).
   - The fuzzer's default profile never drew the strings where 5.3.6's coercion differs from
     LuaJIT's: it does now, and the default run catches LJCOERCE.
   - A crash on our side made the comparator exit 2 ("proved nothing"): now 1.
   - Build gates: the `lib_string.c` log check matched buildvm's command lines and could not fail
     (now anchored on the compile line); the string.pack gate passed with the JIT off (now
     `jit=0/1/0`); the patch script accepted a second module define above its block (now refused).
   - `serializer/tests/strpack.lua`: its alias check counted a table that could not hold an alias,
     and its "C functions are refused" check was refused for unrelated reasons; now 11 checks, the
     refusal isolated.
   - `negctl-pack.sh`: four new arms (D6WIDE, JUNS, TIESAWAY, D4OFFBY1), 28 in all; arm selection
     `OCLJ_NEGCTL_ARMS`.
3. **The fingerprint fail-first is the design stage's.** Run here, the new `fingerprint.lua` with
   round 2's `eris_lj.c` against round 1's archive passes 18/18 (`failfirst/serializer-test.log`):
   that `eris_lj.o` reads round 1's feature header, says `pack0`, and agrees with an archive without
   pack, which is the check working. The fail-first against round 1's own `eris_lj.c` is
   `design/synth/failfirst-r1-fingerprint.log`.
4. **The figures moved:** conf-extra 411 cases (was 409); provenance 21 lines on Windows (was 20)
   and 16 on Linux, measured (the contract derived 15); `PACK TESTS` 13 (was 8); `strpack.lua` 11
   (was 10); the gate line ends `jit=0/1/0` (was `abort=0`); 28 sabotage arms (was 24).
5. **Docs the review corrected:** pack's time per call is not bounded by its output (it converts
   every string argument to a numeric option in both walks; 7.0-7.8 s measured for one call, past
   OC's 5 s timeout, a linear class it shares with `string.format`; wd-blind-spots 1c and 1g,
   roadmap row 205); the README's residual list and its D2 cause; Plan9k's FAT path; the 512-byte
   qualifier on "charged before anything is written"; moved cites.
6. **The scanner residual is wider than the contract said:** LuaJIT's scanner refuses a numeral
   with 2^20 or more digits after the radix point, not only an exponent of 2^20 or more
   (`lj_strscan.c:449-453` and `:468`). It is filed as `RESID-scan`, a choice of the port (D5),
   not of the VM, with a conf-extra case.

## Not done

- **No JVM has loaded the Linux .so,** and the .so needs glibc 2.38.
- **Not tried in the game:** boot, save and restore on the new jar; a Plan9k boot.
- **No ASan or sanitizer run** of `oclj_strpack.c`: proving such a run can fail would need an
  invalid access, by design. Every read is behind 5.3.6's own bounds checks or a bounded `memchr`
  (read, and reviewed).
- **Pathological decimal strings,** where MinGW's `strtod` (the Windows reference) and LuaJIT's
  scanner might round differently, were not searched for; the fuzzer's coercion strings, hex floats
  and boundary decimals match.
- **`tonumber(s, 16)` saturating at 4294967295 on Win64** (roadmap row 146) is recorded, not fixed.

| path | what |
|---|---|
| `failfirst/` | `build-under-test.md5` (round 1's build in `build/native`); `run-pack.log`, `run-packfuzz.log`, `serializer-test.log` and their `.exit`; `strpack-gate.lua`/`.out` (the build's gate on round 1's `luajit.exe`); `ffdef-string_pack.count`; `harness/` (the round-2 harness on round 1's natives, additive and stock, and its chain log) |
| `logs/builds/` | the Windows build logs and LuaJIT logs of both variants; `natives.md5`; `sources.md5`; `gradle-build.log`; `gradle-failfirst.txt` and its raw outputs |
| `logs/native-win/` | every Windows native suite in place, `run-pack`, `run-packfuzz`, `negctl-pack`, the serializer `ser-test` and `ser-negctl`, and `negctl.log` (`negative-control.sh`); one `.log`, `.rc`, `.start` and `.end` each |
| `logs/linux/` | the WSL build logs and LuaJIT logs of both variants, every Linux suite, `run-pack`, `run-packfuzz`, the serializer; `summary.txt`; `host.txt` (object and .so md5s); `glibc.txt` |
| `logs/suite/` | the seven harness arms: `run.log`, `args.txt`, `env.txt` where set, `native.md5`, `exit.txt`, `started.txt` and `finished.txt` (UTC); `chain-r2-a.txt` |
| `logs/fuzz/` | the campaign: `default50`, `long5`, `coerce2`, `limits1` (`.log`, `.rc`, `.start`, `.end`); `inputs.md5` |
| `logs/consumers/` | the design stage's consumer run on the round-2 VM (`final.out`, `compare-final.txt`), PUC 5.3.6 (`ref536-*.out`), round 1's VM (`proto-nopack.out`), and the Plan9k GPT tests |
| `design/` | `design.md` (the contract); `review-findings.json`; `fix/` (`fixes.md`, `fix-result.json`, `fix_docs.py`, the validator proof); `synth/` (the design stage's fail-firsts, gate checks, cross-build matrix, gradle emulation, speed) |
| `scripts/` | `full.sh` (one harness run); `chain-r2ff.sh` (the fail-first arms); `chain-r2.sh` (the seven arms); `ff-r2.sh` (the native fail-firsts); `build-r2.sh`; `native-tests-r2.sh`; `wsl-r2.sh` (the Linux build and suites); `campaign-r2.sh` |

The scripts hard-code local paths: the work tree under `C:/Users/astro/claude-tmp/oclj`, the repo,
OC-JNLua, ocelot-brain and the JDK. Windows logs are CRLF in the working tree; `.gitattributes`
normalizes them on commit, as for every earlier archive.
