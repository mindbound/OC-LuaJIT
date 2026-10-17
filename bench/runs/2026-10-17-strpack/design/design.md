# OC-LuaJIT round 2: implementation contract

**`string.pack`, `string.unpack` and `string.packsize`: Lua 5.3.6's, in our fork's string library**

- **Base:** OC-LuaJIT HEAD `62970a0` plus round 1, uncommitted in the working tree (LuaJIT without FFI; `bench/runs/2026-10-16-noffi/`). The pinned LuaJIT `1ee778a4` at `prototype/watchdog/luajit` is pristine apart from its untracked `.stamp`.
- **Written:** 2026-10-17, by the designer, from the four investigator reports (`port`, `place`, `fuzz`, `consumers`, all under `C:/Users/astro/claude-tmp/oclj/r2/`). Every load-bearing claim was re-opened or re-run in `C:/Users/astro/claude-tmp/oclj/r2/synth/` (below: `synth/`).
- **Status:** every repo file this round adds or changes is a TARGET under `synth/target/<repo path>` (manifest at the end, with md5s). All are LF; none has a CR.
  - **Run end to end in scratch, Windows, MinGW gcc 16.2:** a scratch repo `synth/repo` (the working tree plus the targets), built with `build-native.sh` into `synth/repo/build/native`, dropin then additive; the seven native suites; the serializer `make test` and `make negctl`; the new `run-pack.sh`, `run-packfuzz.sh` (default, a 10-seed x 100 000 sweep, `long`, `coerce`, `limits`) and `negctl-pack.sh` (26 arms); the fail-firsts on round 1's frozen build; a cross-build blob matrix; the gate fail-firsts; gradle's check emulated on the real DLL bytes; the harness COMPILED against the real ocelot-brain classpath. The final chain is `synth/logs/final-20261017-011016/`.
  - **Not run anywhere yet:** the harness (`OcljSmoke.scala`: compiled, not run), gradle, `negative-control.sh`, anything on Linux, anything in game.

Legend: **[M]** measured (where the log is); **[S]** read in source (file:line); **[I]** inferred.

---

## 0. Scope and rules

### In scope (the user's decisions of 2026-10-13; not relitigated)

1. Our LuaJIT is a fork that may take Lua 5.3 functions. This round adds `string.pack`, `string.unpack` and `string.packsize` with **Lua 5.3.6's whole format language**: `< > = ! [n]`, `b B h H l L j J T i[n] I[n] f d n s[n] z x X<op>`, spaces.
2. Everything matches PUC Lua 5.3.6 -- results, and which inputs raise which errors (text, argument number, order) -- except **two deliberate deviations**:
   - **D1:** an unpacked integer whose exact value needs more than 53 bits is ROUNDED to the nearest double, never refused (refusing breaks Plan9k's GPT scanner).
   - **D2:** `l` and `L` are 8 bytes on every platform (PUC: `sizeof(long)`, 4 on Win64).
3. Verified by a differential fuzzer against the repo's PUC 5.3.6 (`bench/vendor/lua-5.3.6/src/lua.exe`) and by the 308-case conformance script, both now repo tests with runners, and both shown to fail first.

### Not in this round

- **Round 3, the 64-bit bitwise operators.** Interaction, recorded: pack converts its integer arguments itself (`pk_checkint`, 5.3.6's rules over doubles) and does not use LuaJIT's `bit` or the 5.3 operators, so round 3 changes nothing here. Round 3 adds its own word token the same way `pack1` was added (§5), and a `BCDUMP_VERSION` bump if it changes what bytecode means (`lj_bcdump.h:36-37`).
- **`tonumber(s, base)` saturating at 4294967295 on Win64** (found by `place` and `consumers`, re-measured here, §1 F14). A separate fork defect; recorded in roadmap row 146.
- `utf8`, `math.type`, `math.tointeger`, the integer subtype, `//`; `string.buffer` exposure.

### Rules for implementers

- Edit only your own files (§8). Write LF. Use no git commands.
- Never write under `build/` or into `serializer/` at run time. Never run `negative-control.sh`, the harness or gradle: those belong to the main session.
- You MAY build and run in your own scratch directory: copy `synth/repo/build/native` (a complete `build-native.sh` output from exactly the targets: windows-x86_64, last variant additive) into your scratch, or run `OCLJ_BUILD=<your scratch>/build/native OCLJ_JNI="/c/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include" OCLJ_JNLUA=C:/Users/astro/Downloads/OC-JNLua OCLJ_VARIANT=additive sh native/build-native.sh` (~16 s; `PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH` for `make`).
- **Targets are normative.** For each of your files: put the target's bytes at the repo path and `cmp` them; read `diff` working-tree..target and confirm every hunk is one this contract describes; if you find a defect, fix it in the repo file and report the deviation with the reason. Never edit `synth/`.
- Never write a file that contains backslashes through a shell heredoc (they get eaten: a `\` + newline was silently joined in this round's own scratch, `synth/` notes in §12). Use the Write or Edit tool; Python with `newline=""`.

---

## 1. Facts this rests on

**F1 [S] The gap.** The kernel already copies all three into the sandbox (`build/native/kernel/machine.lua:946-948`; OC's raw kernel `:901-903` in ocelot-brain's copy), so today they are simply nil there. Plan9k is the consumer: `lib/modules/base/17_gpt.lua:12` unpacks `"\60c8c4I4I4xxxxI8I8I8I8c16I8I4I4I4"` (`\60` is `<`) from 92 bytes of every drive's sector 1 **before** it checks the signature; `msdosfs.lua:23` branches on `if string.pack`; `10_procfs.lua:110` reports 5.3 microcode when it exists. OpenOS never uses `string.pack` (`consumers` census). The sandbox `_VERSION` stays `"Lua 5.2"` (`machine.lua:857`).

**F2 [S] How the string library is opened, everywhere.**
- jnlua's openlib(STRING) is `luaL_requiref(L, "string", luaopen_string, 1)` (OC-JNLua `jnlua.c:440`, `:469`), in both variants.
- The shim's `luaL_requiref` is 5.3's: it calls the opener only if `package.loaded` lacks the module (`lj52shim.c:2923-2941`).
- luajit.exe, every native test and the serializer's `test_main.c` call `luaL_openlibs`, which reaches the same `luaopen_string` inside the archive.
- So the one place that reaches every host is LuaJIT's own `luaopen_string` (pristine `lib_string.c:674-684`), which also installs the table as the string metatable's `__index`.

**F3 [S][M] buildvm.** It reads only the Makefile's `LJLIB_C` files, line by line; every `LJLIB_` prefix it sees is a tag; it never follows an `#include`; an `#if` it does not know counts as true (`host/buildvm_lib.c`). `LJLIB_CF(name)` is `static int lj_cf_##name(lua_State *L)` (`lj_lib.h:81`). `build-native.sh`'s `make clean` regenerates `lj_ffdef.h`, `lj_libdef.h`, `lj_recdef.h` and `jit/vmdef.lua`. Measured on the scratch build: `FFDEF(string_pack)`, `FFDEF(string_packsize)`, `FFDEF(string_unpack)` once each; `string.pack` is `builtin#91`, `string.unpack` `#93`, `string.packsize` `#92`; every builtin after them moves up by 3 (`place`'s `logs/surface-*.out`); no repo code depends on a builtin number (`place`, grep).

**F4 [S][M] The LuaJIT and shim API traps the port avoids.**
- `luaL_checkinteger`/`lua_tointeger` truncate with a bare cast: `lj_api.c:447-463`, `lj_num2int_type` is `((tp)(n))` (`lj_obj.h:1010`). 1.5 gives 1; 2^63, NaN and inf give INT64_MIN (`port`, `probe_api-win.out`).
- `lua_pushinteger` is `(double)i`.
- The shim's `lua_Unsigned` is `unsigned int` (`lj52shim.h:93-94`).
- LuaJIT's `luaL_Buffer` is 5.1's: it concatenates on the Lua stack; LUAL_BUFFERSIZE is 512 on MinGW; 1 MiB peaked at 3.83-4.64x the output (`port`, `mem/`).
- `lua_pushnumber` canonicalizes every NaN (`lj_api.c:624-628`). A C function holds at most `LUAI_MAXCSTACK` = 8000 slots (`luaconf.h:92`, `lj_api.c:104`).
- `lj_str_new` accepts only lengths below `LJ_MAX_STR` (0x7fffff00) and raises `string length overflow` above it **before reading the source** (`lj_str.c:317`, `:352-353`); strings are NUL-terminated (`lj_str.c:299-300`).

**F5 [S] 5.3.6's semantics that matter, re-read in `bench/vendor/lua-5.3.6/src/lstrlib.c`.**
- The section is `:1100-1539`. `str_pack` pushes a nil mark before the walk (`:1337`), so a missing argument reads "got nil".
- `str_unpack`'s general check `(size_t)ntoalign + size > ~pos || pos + ntoalign + size > ld` (`:1488-1489`) is overflow-safe for every `pos` including `ld + 1`, which an unterminated `z` reaches (`:1523-1528`, `strlen` stops at the terminator).
- The `s[n]` check `pos + len + size <= ld` (`:1518`) WRAPS for `len > SIZE_MAX - pos - size`; the check then passes and 5.3.6 survives only because `luaS_newlstr` refuses the length: `memory allocation error: block too big`. Since any wrapped sum is below `pos + size <= ld`, the check passes on EVERY wrap, so "wraps" and "block too big" are the same set of inputs [S, reasoning on `:1518`]. Measured: PUC gives exactly that text for `<s8` of `ff x8 .. "x"`, of `f8 ff x7 ..`, and `data string too short` for a non-wrapping too-long length [M `synth/logs`, run 00:58].
- `packsize` checks `format result too large` before `variable-length format` (`:1425-1435`; 5.4 swapped them).
- A non-printable option byte prints as `<\NNN>` (`lobject.c:413-420`); a type error uses `__name`, then `light userdata` (`lauxlib.c:182-193`); `interror` (`lauxlib.c:422-436`); string-to-integer is `l_str2int` (`lobject.c:299-328`: hex wraps modulo 2^64), then `l_str2d` (`:274-293`, which refuses `inf`/`nan` itself); float-to-integer mode 0 is exact integral values in [-2^63, 2^63) (`lvm.c:94-105`, `luaconf.h:449-451`).

**F6 [M] The port.** `port`'s `lj53pack.c` (718 lines) matched 5.3.6 on 303 of 308 conformance cases, the 5 others exactly D1 x2, D2 x2 and the `s` wrap text (`port/final/20261017-001941/`); conf-extra 386 of 409; 0 warnings under `-Wall -Wextra` on MinGW and Linux; 12 sabotages each caught by some suite. Its prototype predecessor (2026-10-13) had two real bugs: 5.4.8's `z` check, and `l`/`L` at `sizeof(long)` (`fuzz`, `runs/10-proto-20k/causes2.txt`).

**F7 [M] Placement, measured by `place`** (`place/logs/`): with LJLIB_CF registrations in `lib_string.c`, GG_State stays 6376 (an LJLIB_CF adds no ASM fast function); `('<i4'):pack(7)` works through the metatable; the JIT stitches a trace at the call (`recff_nyi`, `lj_ffrecord.c:195`) and does not abort or blacklist; stitched costs about what interpreted does (the C call dominates). A shim wrapper would have left luajit.exe and every `luaL_openlibs` host without the functions (F2).

**F8 [S][M] Persistence.** OC's `PersistenceAPI` walks the raw `_G` after `openLibs`, the first name wins (`ocelot-brain PersistenceAPI.scala:34-88`). eris looks every non-scalar up in perms (`eris_lj.c:1829`), refuses a C function by value (`:1771`, `cannot persist a C function by value`), and on restore refuses an unknown name (`:2932`, `unknown permanent`). Measured here, 3 runs alike (`synth/logs/xbuild-matrix.out`, hosts in `synth/xb/`, one commit and serializer hash for all four): the walk over OC's library set names 135 permanents without pack, 138 with (`_G.string.pack`, `.packsize`, `.unpack`, one name each).

| blob written by -> restored by | result |
|---|---|
| pack build -> pack build (control) | restores; `sandbox.string.pack == string.pack` |
| **without the token:** pack build -> build without pack (same fingerprint) | `eris-lj: unknown permanent (not in the perms table)`, mid-restore |
| **without the token:** build without pack -> pack build (same fingerprint) | RESTORES; `sandbox.string.pack` is nil while `('<i2'):pack(258)` works, until a reboot |
| **with the token:** pack1 -> pack0, and pack0 -> pack1 | refused at the header: `build fingerprint mismatch: VM features differs (blob '...pack1', this build '...pack0')` |

**F9 [M] Layout.** The round-2 build's stage 1b reads `FOREIGN-ALLOC-OK GG=6376`, as round 1's; its negative arm still reads `GG-LAYOUT-MISMATCH lib=6376 tu=6384` (`synth/logs/final-20261017-011016/bn-additive.log`).

**F10 [M] Memory, through the shim with a real cap** (`pack_test.c`, `synth/logs/final-*/run-pack.log`): a 1 MiB pack with the collector stopped charges +2.0001 MiB (one scratch userdata through `lj52_alloc`, plus the interned result); under a cap of heap + 4 MiB, `pack('c16777216', '')` is refused with status `LUA_ERRMEM` and `not enough memory`, and the state packs and unpacks afterwards. `port` measured pack succeeding to 1.9 MiB under that cap where `string.rep` already fails at 1.5 MiB.

**F11 [M] The C stack.** `unpack` with 7990 results returns 7991 values; with 9000 it raises `stack overflow (too many results)` (PT6). 5.3.6 returns ~1e6.

**F12 [M] JIT.** The build gate's hot loop of 2000 `pack("<i4 z", i, "ab")` calls computes 14000 with 0 aborted traces (`string.pack gate: ... hot=14000 abort=0`). Rough per-call cost, unpinned, two `java.exe` processes running: pack of a 3-option format 119 ns, unpack 40 ns, `string.format` control 60 ns; PUC 5.3.6 on the same loop 99 / 53 / 191 ns (`synth/logs/speed.txt`).

**F13 [M] Consumers, on the final luajit.exe** (`synth/consumers/`): `consumers`' GPT test runs the REAL `17_gpt.lua` and `01_util.lua` against mock drives: `GPT RESULT: ALL 14 TESTS PASS` for both Plan9k copies (GTNH and ocelot-brain); round 1's luajit.exe fails 9 of 10 (`attempt to call field 'unpack' (a nil value)`). `consumers.lua` (185 cases over every consumer format) against the 5.3.6 LP64 reference: 182 pass, 0 fail, 0 missing, 3 INFO -- all three outside pack (`tonumber(hex16, 16)`, `uuidBin` through it, LuaJIT's `string.char` truncating 1.5).

**F14 [M] Found, not this round's.** `tonumber("0123456789abcdef", 16)` is 4294967295 on our luajit.exe and 81985529216486895 on PUC 5.3.6 (`lib_base.c:301-307`, `strtoul`, 32-bit `unsigned long` on Win64). Plan9k's `uuidBin` (`01_util.lua:66-71`) depends on it and has no caller.

---

## 2. Decisions (every open question, closed)

| # | Question | Decision | Why |
|---|---|---|---|
| D1 | Placement | LuaJIT's `lib_string.c`: three `LJLIB_CF` registrations, inserted by `native/luajit/patch-strpack-register.sh` on the build copy (the fifth LuaJIT change), calling static functions in a tracked file, `native/luajit/oclj_strpack.c`, which the patched `lib_string.c` `#include`s. Not the shim wrapper (`port`'s option a), not a new lib file. | F2: `luaopen_string` is the one opener every host reaches; luajit.exe then runs the shipped code, so the conformance and fuzz tests need no custom host; eris (which must never see the shim header, `build-native.sh:442`) can name the library in the fingerprint; `('fmt'):pack` works; GG_State unchanged (F7, F9). A new lib file buys nothing and costs a Makefile patch. |
| D2 | The code | `port`'s `lj53pack.c`, restructured: every identifier `pk_`/`PK_`-prefixed (it shares `lib_string.c`'s translation unit); entry points `static int oclj_strpack_pack/packsize/unpack`; `#include "lj_obj.h"` for `LJ_MAX_STR` and the feature set; two `#error`s; the `s[n]` check of D3; `memchr(…, 0, …)` (no backslash in the sabotage anchors). | The port was correct on every measured axis (F6); the rest is placement. |
| D3 | An `s[n]` length that wraps 5.3.6's check | **Same text as 5.3.6:** `memory allocation error: block too big` when `len > SIZE_MAX - pos - size` (exactly the inputs that wrap, F5), `data string too short` (arg #2) otherwise. Neither comparison can wrap; nothing is read. Closes `port`'s open question 1 AGAINST its D3: no third deviation. | "Everything else should match 5.3.6 exactly"; the emulation is two comparisons, and it lets the fuzzer drop its `kstring-wrap` rule (a rule that would have masked a regression). |
| D4 | A result of `LJ_MAX_STR` or more | Refused after the checks, before any allocation: `not enough memory for buffer allocation` (5.3.6's `luaL_Buffer` text, `lauxlib.c:468`). Closes `port`'s open question 2. | The text 5.3.6 raises under OC's cap; LuaJIT cannot hold the string at all. |
| D5 | String arguments to numeric options | 5.3.6's rules inside pack (`"0xFFFFFFFFFFFFFFFF"` packs as -1; `inf`, `nan`, `0b101` are not numbers; decimals that fit int64 are exact), while `tonumber` on the same VM keeps LuaJIT's. Closes `port`'s open question 3. Float numerals go through LuaJIT's locale-free scanner after the two refusals; an exponent of 2^20 or more stays a residual. | Matching 5.3.6 is the decision; measured: the fuzzer's `coerce` profile now differs only in number-to-string formatting (§7). |
| D6 | D1's scope | Every value 5.3.6 represents (64-bit, wrapping like `lua_Integer`: `J` of ff x8 is -1) is rounded to nearest, ties to even. A field 5.3.6 itself refuses -- I9..I16 whose extra bytes are not a sign extension -- stays refused with 5.3.6's `%d-byte integer does not fit into Lua Integer`. Closes `fuzz`'s and `consumers`' shared open question. | The decision was about the prototype refusing above 2^53; "which inputs raise errors" must otherwise match 5.3.6. No consumer uses I9..I16 (`consumers`). **Flagged for the user in the summary**, as a reading of the decision, not a change to it. |
| D7 | NaN payloads, the 8000-slot limit, number formatting, the 2^20 exponent, function names in messages | VM residuals, documented (deviations.txt `RESID`, README, roadmap), not deviations of pack. pack pushes every float through `lua_pushnumber`. | Pushing a payload NaN raw would defeat LuaJIT's NaN-tag safety (`lj_api.c:624-628`). |
| D8 | Fingerprint | An eighth token, **`pack1`**, derived in `eris_lj.c` from `OCLJ_LIB_STRPACK`; a per-feature token (round 3 adds its own). `build-native.sh` observes `string.pack` on luajit.exe and fails a disagreeing word; `fingerprint.lua` checks the token against the archive's string library; `negctl-fingerprint.sh` gains arm `packword`; gradle requires the word to end in `.pack1`. | F8: without it, a blob that crossed the change was checked name by name only, and one direction restored silently into a sandbox that lacked pack. The serializer hash moves anyway (eris_lj.c changed): every earlier blob is refused once, before any release. The general row-196 question (a hash of the permanent names) stays open. |
| D9 | The marker | `#define OCLJ_LIB_STRPACK 1` in `native/luajit/oclj_features.h`, in a new section "OUR ADDITIONS TO LuaJIT'S LIBRARIES", exactly that line (negctl arms toggle it); `oclj_strpack.c` `#error`s without it; the `-dM` gate requires it. | One source of truth, the round-1 pattern. |
| D10 | Tests | **`test/native/run-pack.sh`** (conformance against checked-in `.expect` files, needs no PUC; provenance against PUC 5.3.6 when present; `pack_test.c` through the shim) and **`test/native/run-packfuzz.sh`** (needs PUC; exits 2 without), with the scripts under **`test/native/pack/`**; **`test/native/negctl-pack.sh`** proves both can fail. `serializer/tests/strpack.lua` for persistence. Harness milestone `d4-sandbox-string-pack`. | `.expect` files make the main gate runnable anywhere; the provenance part keeps them honest; conf-extra is the only suite that catches every sabotage alone (§6), so it ships. |
| D11 | Sizes | `run-packfuzz.sh` default 1 seed x 20 000 random cases plus ~240 fixed edges (3.4 s). Campaign: `OCLJ_PACKFUZZ_SEED=1000 OCLJ_PACKFUZZ_SEEDS=50 OCLJ_PACKFUZZ_CASES=100000` (~14 min) and `PROFILE=long SEEDS=5 CASES=300` (~2 min). `negctl-pack.sh` fuzzes 2000 cases per arm. | Measured speeds (§7); the fixed edges catch every arm the fuzzer catches (`fuzz` report, and §6). |
| D12 | No change | `native/lj52shim.c`/`.h`, OC-JNLua, `native/kernel/*`, `LuaJITArchitecture.java`, `serializer/eris_lj.h`, `serializer/test_main.c`, `mem_test.c`, `negative-control.sh`. | The shim's install path is jnlua's call of `luaopen_string`, unchanged. `negative-control.sh` pins exact failing-id sets for its sabotaged shims; a cap check added to `mem_test.c` would flip under its `stopgap` arm, so the cap check lives in `pack_test.c` instead. Whether `negative-control.sh` should call `negctl-pack.sh` is the main session's choice (§12). |
| D13 | The dropin | Gets pack too (same archive). Accepted. | It is the same VM; the stock arm (PUC 5.2.4 + Eris) paints `absent`. |

---

## 3. The implementation: `native/luajit/oclj_strpack.c` (NEW, 769 lines)

The target is the implementation. Its contract is its header comment; its structure:

- **Guards:** `#include "lj_obj.h"`, then `#error` unless `OCLJ_LUAJIT_FEATURES`, and `#error` unless `OCLJ_LIB_STRPACK == 1`. Typedef asserts: `CHAR_BIT == 8`, `lua_Number` is a double, `size_t` is 64-bit.
- **Integers:** `pk_Int` = `int64_t`, `pk_Uns` = `uint64_t`; `pk_u2s` converts without implementation-defined casts. Nothing uses `lua_Integer`, `lua_Unsigned`, `luaL_checkinteger`, `luaL_optinteger`, `lua_tointeger` or `lua_pushinteger` (F4).
- **Argument conversion:** `pk_checkint` = 5.3.6's `luaL_checkinteger` (`pk_tonum`: a number is a float; a string is `pk_str2int` = `l_str2int`, then `pk_str2d` = refuse `n`/`N` before the first of `.xX`, refuse an embedded NUL and `0b`, then LuaJIT's `lua_tonumberx`; `pk_flt2int` = exact integral in [-2^63, 2^63)). `pk_checknumber`, `pk_optint`, `pk_typeerror` (`__name`, `light userdata`), `pk_checklstring` (numbers converted in place, as 5.3.6).
- **Format walk:** `pk_peek` reads only below the format's end and returns NUL there; `pk_getnum`, `pk_getnumlimit`, `pk_getoption` (`l`/`L` = `PK_SZINT`, 8: D2; the non-printable option text), `pk_getdetails` -- 5.3.6's code otherwise.
- **pack:** `pk_walk` runs twice. Pass 1 (`o == NULL`) makes every check in 5.3.6's order and returns the total (uint64, cannot wrap); `total >= LJ_MAX_STR` raises D4's text; then ONE scratch block of exactly `total` bytes (a 512-byte C array, else `lua_newuserdata`, charged by `lj52_alloc`); pass 2 writes through `pk_room`, which refuses any write past the block ("internal error"); then `lua_pushlstring`. The nil mark is pushed before pass 1.
- **packsize:** 5.3.6's order; `lua_pushnumber`.
- **unpack:** 5.3.6's general check kept verbatim (do NOT replace it with 5.4's `ld - pos` form: after an unterminated `z`, `pos` is `ld + 1`); integers pushed as `(lua_Number)res` (D1); `s[n]` per D3; `z` by bounded `memchr`; `luaL_checkstack(L, 2, "too many results")`.
- **Anchors:** `test/native/negctl-pack.sh` replaces 24 exact lines of this file. An edit that changes one of them must change `negctl-pack.sh` with it (the arm then reports `BROKEN (anchor)` and the script fails).

Compiled inside `lib_string.c` with LuaJIT's flags (`-O2 -fomit-frame-pointer -Wall`), and on its own under `-Wall -Wextra` by a build gate (§4): 0 warnings either way [M].

---

## 4. Registration and the build

### 4.1 `native/luajit/patch-strpack-register.sh` (NEW, 154 lines)

`sh patch-strpack-register.sh <in lib_string.c> <out lib_string.c>`; in and out may be the same. Anchored on `#include "lj_libdef.h"` (`lib_string.c:672` at 1ee778a4), exactly once; inserts 22 lines directly above it: a marker comment `OC-LuaJIT (native/luajit/patch-strpack-register.sh)`, `#include "oclj_strpack.c"`, and three stubs `LJLIB_CF(string_pack) { return oclj_strpack_pack(L); }` (and `packsize`, `unpack`). Verifies by content (marker, include and each tag once; module define < include < pack < unpack < anchor) and by diff (22 added, 0 removed; exactly 3 more lines carrying `LJLIB_`). An already-patched input takes a verify-only path. Strips CR; writes LF; no backslashes, no tabs.

Refusals measured [M `synth/ptneg/`]: anchor absent, anchor twice, a `string_pack*` tag already present, a patched file missing one stub, a patched file missing the include -- each rc 1, no output written. CRLF and LF inputs give byte-identical output; the pristine checkout's `lib_string.c` is CRLF.

### 4.2 `native/build-native.sh` (+155 -18)

| hunk | what |
|---|---|
| header `:22-61` | "FOUR changes" -> FIVE; the `lib_string.c` paragraph |
| `:478` | "THE FIRST OF THE FIVE" |
| `:603-641` (before `make clean`) | THE FIFTH: assert the pristine `lib_string.c` carries no marker and the checkout has no `oclj_strpack.c`; re-copy the pristine file; assert the marker absent; copy `native/luajit/oclj_strpack.c` in and `cmp`; patch; assert marker and include exactly once |
| after `lj_ffrecord.o`'s checks | `lib_string.o` newer than both files; `lib_string.c` in the log; `FFDEF(string_pack|packsize|unpack)` once each in `lj_ffdef.h`; no warning in the log naming `lib_string.c` or `oclj_strpack.c` |
| `-dM` loop | adds `OCLJ_LIB_STRPACK 1` |
| after it | the `-Wall -Wextra` gate: a generated `strpack_wgate.c` includes `oclj_strpack.c` and calls the three entry points; 0 warnings required |
| after the `nm` check | the string.pack gate: `strpack.lua` (no backslashes) must print exactly `fn=function/function/function i4=feffffff method=true u=-2/5 I8max=true l=8/8 short=true int=true hot=14000 abort=0`; the failure message explains each field |
| stage 4 | `OBS` gains `string.pack and "pack1" or "pack0"`; the word pattern gains `.pack[01]`; comment |
| PREREQUISITES 4 | five changes |

**Fail-firsts [M `synth/logs/gatecheck.log`, the gates' own commands]:** round 1's luajit.exe prints `fn=nil/nil/nil`; its `lj_ffdef.h` has 0/0/0 FFDEFs; its headers lack `OCLJ_LIB_STRPACK 1`; the shipped eris (pack1) against round 1's luajit.exe fails the word check on token `pack0`, and an eris compiled without the marker (pack0) against the round-2 luajit.exe fails on `pack1`; `oclj_strpack.c` without the marker stops at its `#error`; the `-Wall -Wextra` gate counts 1 on a copy with one unused variable, 0 on the real file.

### 4.3 `native/luajit/oclj_features.h` (+16) and `patch-features-include.sh` (+1 -1)

The features header gains the section "OUR ADDITIONS TO LuaJIT'S LIBRARIES" with `#define OCLJ_LIB_STRPACK 1` and its reason. The include script's header comment names the fifth patch script. Neither changes layout: GG_State 6376 [M].

---

## 5. The fingerprint

- `serializer/eris_lj.c` (+20 -7): `ELJ_W_PACK` is `"pack1"` when `OCLJ_LIB_STRPACK`, else `"pack0"`, appended as the eighth token; the THE VM-FEATURES WORD comment says why. No other hunk.
- **Serializer hash `baf083da`** (sha1 of `eris_lj.c` + the unchanged `eris_lj.h`), if both are byte-identical to the targets. Shipped fingerprint: `1ee778a4|LuaJIT 2.1.ROLLING|baf083da|ffi0.lua52.gc64.fr2.dn0.le.p64.pack1`, 73 bytes (u8 limit 255, compile-time asserted). The serializer test build's: the same with the 40-character commit, 105 bytes.
- `serializer/tests/fingerprint.lua` (+12 -3): the shape pattern gains `%.pack[01]`; a new check, "the pack token agrees with this archive's string library"; `FLIP` gains `pack1`/`pack0`; "eight tokens". **18 checks** (was 16).
- `serializer/tests/negctl-fingerprint.sh` (+34 -8): `nocompare` now wants exit 10 with 10 FAIL lines (8 token, 1 three-field, 1 CRC); new arm **`packword`**: the real `eris_lj.c` against a header copy without `#define OCLJ_LIB_STRPACK 1`, linked with the real (pack) archive, must exit 1 with exactly one failure, the agreement check; `layout` unchanged. "all three sabotages caught".
- `serializer/tests/strpack.lua` (NEW, 10 checks) and `serializer/Makefile` (+1, in `test`): the three are functions; the `_G` walk names them once each; a coroutine holding them as upvalues, frozen between a pack and its unpack, persists, is refused without the perms (C functions), restores with this state's own functions as its upvalues, and resumes to the uninterrupted result; restored where the names are unknown it is refused `unknown permanent`.
- `serializer/README.md`: eight tokens, the `pack` token, `tests/strpack.lua`.
- `build.gradle.kts` (+14 -6): the fragment stays `<hash>|ffi0.lua52.`; some match of `Regex.escape(want) + "[a-z0-9.]*"` must end in `.pack1`. Lifecycle line: `native fingerprint matches the serializer sources and the LuaJIT feature set (baf083da|ffi0.lua52....pack1)`.

**Measured:**
- `make test`: m1 82, m2 56, m3 79, contract rc 0, stack-universe `FAILS: 0`, `FINGERPRINT RESULT: ALL 18 TESTS PASS`, `STRPACK RESULT: ALL 10 TESTS PASS`, for-in exact. `make negctl`: `NEGCTL-FINGERPRINT: PASS (all three sabotages caught)`.
- Fail-first: the new `fingerprint.lua` on round 1's serializer fails 3 (shape, agreement, eight tokens); `strpack.lua` fails its first check and stops (`synth/logs/failfirst-r1-*.log`).
- Gradle, emulated in Python on real bytes (`synth/logs/gradle-emul.txt`): the round-2 additive DLL ACCEPTED; the same DLL with both `.p64.pack1` strings edited to `pack0` REFUSED; round 1's DLL REFUSED even against its own serializer hash `85097158`. The Kotlin itself was not compiled [I].

---

## 6. Tests and their fail-firsts

| Test | Lives in | Round 1's build (fail-first) | Sabotage | This build |
|---|---|---|---|---|
| conformance, 308 cases, exact against `conformance.expect` | `run-pack.sh` part 1; `pack/conformance.lua` | FAIL: `string.pack/unpack/packsize missing` | 17 of 24 arms | PASS |
| conf-extra, 409 cases, exact against `conf-extra.expect` | part 1; `pack/conf-extra.lua` | FAIL, the same | 23 of 24 arms (all but DOUBLEBUF) | PASS |
| provenance: PUC 5.3.6 differs from the `.expect` files in exactly `deviations.txt`'s lines (Windows: 4 and 20) | part 2 | (passes: it judges the files, not the build) | -- | PASS; SKIPPED without PUC |
| shim path: PT1, PT1m, PT2 (GPT text sector), PT3 (2x charge), PT4/PT5 (cap refusal, recovery), PT6a/b (C stack) | part 3; `pack_test.c` | FAIL PT1 `0 of 3 are functions` | PT2 under REFUSE53 and ROUNDDOWN, PT3 under DOUBLEBUF, PT5 under PASS2 | 8/0 |
| differential fuzz, default | `run-packfuzz.sh`; `pack/packfuzz*.lua` | exit 1: no output, pack missing | 20 of 24 arms (not ORDER54, NONAME, LJCOERCE, DOUBLEBUF) | exit 0 |
| all of the above, per arm | `negctl-pack.sh` | arm `unregistered`: both suites exit 1 | 24 arms, each caught | `NEGCTL-PACK: PASS` |
| the token | `fingerprint.lua`, `negctl-fingerprint.sh` packword | 3 failures | packword: exactly the agreement check | 18/0 |
| persistence | `serializer/tests/strpack.lua` | 1 failure, stops | -- | 10/0 |
| in the sandbox, through the JNI-loaded native | `OcljSmoke.scala` `d4-sandbox-string-pack` | additive/dropin: `absent` [M the probe on round 1's luajit.exe]; FAIL [I] | -- | `ok/feffffff/-2/5/true/true/l8/short` [M the probe on the round-2 luajit.exe]; PASS [I] |
| the build gates | `build-native.sh` | §4.2 | §4.2 | pass |

**The 24 sabotages** (`negctl-pack.sh`, each one line of `oclj_strpack.c`, anchored and asserted once; all memory-safe, the header says why): LONG4, REFUSE53, ROUNDDOWN, CHECKINT, U32 (the shim's 32-bit unsigned in the overflow check), NOOVF, SLEN, ZEROS, POW2, NOPRINT, ORDER54, NOMARK, NONAME, LJCOERCE, PADARG, GETNUM, POSCLIP (5.4's clip), I16NEG, XCAP, Z54, KSTR54 (`port`'s 5.4 text), KSTR536 (5.3.6's wrapping check: LuaJIT's `lj_str_new` refuses the length before reading, F4), PASS2 (pass 2 asks one byte more: `pk_room` refuses), DOUBLEBUF (a second scratch block: PT3 reads +3.0001 MiB). Plus `canon` (must pass) and `unregistered` (pristine `lib_string.c`). Per-arm table: `synth/logs/final-20261017-011016/negctl-pack.log` (and the two earlier full runs, `synth/logs/negctl-pack-1.log`, `final-verify.log`, identical verdicts).

The `.expect` files are this build's output, which differs from PUC 5.3.6 (Windows) in exactly these ids [M]: conformance `size l`, `size L` (D2, Windows only), `u 2^53+1`, `u maxint` (D1); conf-extra 6 `DEV1` and 5 `DEV2` (Windows only) ids and 9 `RESID` ids (NaN payload, 9000 results, `1.0` given to `z`, two 2^20 exponents, two tail-call messages). On Linux PUC's `l` is 8, so `deviations.txt` lists the D2 lines for windows only; `port` measured the Linux PUC difference to be exactly that [M `port/final-linux/`], and the port's outputs to be byte-identical across the two platforms; the Linux part-2 run is still to be made [I].

---

## 7. Results in scratch (Windows; `synth/logs/final-20261017-011016/` unless named)

- **Builds:** dropin and additive rc 0. Gate lines: `lib_string.c: registers string.pack/packsize/unpack once`, `lib_string.o recompiled with string.pack/packsize/unpack (FFDEF x3 in lj_ffdef.h, no warnings)`, `-dM: ... OCLJ_LIB_STRPACK 1`, `oclj_strpack.c -Wall -Wextra warnings = 0`, the string.pack gate line, `FOREIGN-ALLOC-OK GG=6376`, `serializer hash = baf083da`, `VM-features word ffi0.lua52.gc64.fr2.dn0.le.p64.pack1 (luajit.exe agrees: ffi0 lua52 fr2 le pack1)`, ABI 87/89 dropin and 91/93 additive. `libluajit.a` 699 888 B (round 1: see its README); dropin DLL 729 380 B, additive 732 544 B. `lib_string.o` md5 `e9036fd3...` identical before and after the last comment-only edit of `oclj_strpack.c`.
- **Native suites:** shim 57/0, security 55/0, mem 86/0, vgc 47/0, wd 35/0, penalty 6/0, race 2/0 -- round 1's counts.
- **run-pack.sh:** conformance 308 and conf-extra 409 exact; provenance 4 and 20 lines exactly as listed; PACK TESTS 8/0.
- **run-packfuzz.sh** default: seed 1, 33 953 lines, EXACT 32 749, DEVIATION 1 204 (round53), MISMATCH 0, 3.4 s.
- **Sweep** (`synth/logs/fuzz-campaign-1.log`): seeds 101-110 x 100 000 = 1 000 000 random cases + edges, 1 684 755 lines, **0 MISMATCH**, 2 min 41 s (~16 s a seed). `long` 3 x 300 (strings to 16 MiB): 0 MISMATCH, 76 s. `coerce` 2 x 20 000: exactly ONE mismatch class, numbers given to `c`/`z` (LuaJIT writes 1e14 as `1e+14`, -0 as `-0`); every string-to-number coercion matches 5.3.6 (D5). `limits`: exactly one class, unpack past 8000 slots.
- **negctl-pack.sh:** canon passes; all 24 sabotages and `unregistered` caught; ~3 min.
- **Serializer:** §5.
- **Cross-build:** F8.
- **Harness:** `OcljSmoke.scala` + `OcljArch.scala` + the generated `LuaStateLuaJIT.java` compile with javac/scalac 2.13.11 against the real ocelot-brain classpath (`synth/scalac.sh`, rc 0, no errors). The d4 probe's Lua, extracted from the Scala, prints `ok/feffffff/-2/5/true/true/l8/short` on the round-2 luajit.exe, `absent` on round 1's, and `ok/feffffff/-2/5/true/false/l4/short` on PUC 5.3.6 (`synth/d4/`).

---

## 8. File ownership (4 implementers, disjoint)

Every file is a TARGET: put its bytes in place, `cmp`, then review the diff against the working tree.

**A: LuaJIT build plumbing**
- NEW `native/luajit/oclj_strpack.c`
- NEW `native/luajit/patch-strpack-register.sh`
- `native/luajit/oclj_features.h`
- `native/luajit/patch-features-include.sh` (comment)
- `native/build-native.sh` (§4.2)
- Self-check: `sh -n`; a scratch `build-native.sh` run per variant; expect §9.2's lines.

**B: serializer and gradle**
- `serializer/eris_lj.c`, `serializer/Makefile`, `serializer/README.md`
- `serializer/tests/fingerprint.lua`, `serializer/tests/negctl-fingerprint.sh`, NEW `serializer/tests/strpack.lua`
- `build.gradle.kts`
- Self-check: in a scratch copy of `serializer/`, `make OCLJ_BUILD=<copy of synth/repo/build/native> CC=gcc test negctl`; FINGERPRINT 18, STRPACK 10, NEGCTL-FINGERPRINT PASS (three arms).

**C: the pack tests**
- NEW `test/native/run-pack.sh`, `test/native/run-packfuzz.sh`, `test/native/negctl-pack.sh`, `test/native/pack_test.c`
- NEW `test/native/pack/conformance.lua`, `conformance.expect`, `conf-extra.lua`, `conf-extra.expect`, `deviations.txt`, `packfuzz.lua`, `packfuzz-cmp.lua`
- `test/native/security_test.c` (one comment: the `lib_string.c` cite)
- Self-check: against a copy of the reference build, `run-pack.sh` 0, `run-packfuzz.sh` 0, `negctl-pack.sh` PASS (needs `make` on PATH and `OCLJ_LUAJIT` for the `unregistered` arm).

**D: harness and docs**
- `test/native/OcljSmoke.scala` (three hunks: the `packRow` probe after `litRow`; row 16 paints ` OCLJPACK=`; milestone `d4-sandbox-string-pack` after d3), `test/native/OcljArch.scala`, `src/main/java/io/github/astronfo/ocluajit/arch/LuaJITStateFactory.java` (comments)
- `README.md`, `NOTICE`, `docs/roadmap.md`, `docs/research/wd-blind-spots.md`
- Self-check: `synth/scalac.sh`'s compile (scalac on the real classpath).

**Interfaces** (fixed by the targets):

| Name | Defined by | Used by |
|---|---|---|
| the exact line `#define OCLJ_LIB_STRPACK 1` | A (`oclj_features.h`) | A (`-dM` gate), A (`oclj_strpack.c` `#error`), B (eris word; `negctl-fingerprint.sh` packword toggles exactly that line) |
| `static int oclj_strpack_pack/packsize/unpack(lua_State *)` | A (`oclj_strpack.c`) | A (the patch script's stubs; the `-Wall -Wextra` gate) |
| marker `OC-LuaJIT (native/luajit/patch-strpack-register.sh)` | A | A (build asserts) |
| the 24 anchor lines of `oclj_strpack.c` | A | C (`negctl-pack.sh`) |
| word token `pack1`/`pack0`, last | B | A (stage-4 check), B (gradle, `fingerprint.lua`) |
| `$OCLJ_BUILD/luajit-<platform>/src/luajit.exe` and `lj52shim.o`/`eris_lj.o` | A (build) | C (all three runners) |
| screen token `OCLJPACK=`, milestone `d4-sandbox-string-pack` | D | README, main session |

---

## 9. What the main session runs

Record everything in a fresh `bench/runs/2026-10-17-strpack/` (`logs/`, `failfirst/`), with a README in round 1's shape. Never clear or reuse a results directory. Build PUC 5.3.6 first if `bench/vendor/lua-5.3.6/src/lua.exe` is gone (it is git-ignored; it is present today).

### 9.1 Fail-first, BEFORE any rebuild (round 1's `build/native` still in place)

1. `OCLJ_JNI=… sh test/native/run-pack.sh` (new runner, round 1's build): exit 1; part 1 `FAIL conformance: luajit.exe raised ... string.pack/unpack/packsize missing` (and conf-extra); part 2 PASS (it judges the files); part 3 `FAIL PT1 ... 0 of 3 are functions`.
2. `sh test/native/run-packfuzz.sh`: exit 1, `seed 1: 1 -- no output from our side`.
3. `build/native/luajit-windows-x86_64/src/luajit.exe synth/repo/build/native/strpack.lua` (or the target build's `strpack.lua` copied into `failfirst/`): `fn=nil/nil/nil`.
4. Harness, new `OcljSmoke.scala` on round 1's natives: additive `d4-sandbox-string-pack: FAIL ... absent`, CHECKS 81, 1 failure; stock d4 PASS `absent`.

### 9.2 Builds

Windows, both variants (`OCLJ_VARIANT=dropin`, then `additive`). Each must exit 0 and print, among round 1's lines:

```
[build]     lib_string.c: pristine copy re-taken; oclj_strpack.c copied from native/luajit
patch-strpack-register.sh: lib_string.c  registers string.pack/packsize/unpack (22 lines above the lj_libdef.h include, of 712); verified by content and diff
[build]     lib_string.c: registers string.pack/packsize/unpack once (asserted by content before make)
[build]     lib_string.o recompiled with string.pack/packsize/unpack (FFDEF x3 in lj_ffdef.h, no warnings)
[build]     feature set through -I$LJ (lj_arch.h -dM): OCLJ_LUAJIT_FEATURES 1, LJ_52 1, LJ_HASFFI 0, LJ_HASJIT 1, LJ_GC64 1, OCLJ_LIB_STRPACK 1
[build]     oclj_strpack.c -Wall -Wextra warnings = 0
[build]     string.pack gate: fn=function/function/function i4=feffffff method=true u=-2/5 I8max=true l=8/8 short=true int=true hot=14000 abort=0
[build]     FOREIGN-ALLOC-OK GG=6376
[build]     serializer hash = baf083da  (blobs are pinned to this)
[build]     VM-features word ffi0.lua52.gc64.fr2.dn0.le.p64.pack1 (luajit.exe agrees: ffi0 lua52 fr2 le pack1)
```

WSL Linux .so (additive): the same lines; the GG number, `hot`, and `abort` printed, not assumed [I: not built on Linux this round].

### 9.3 Suites

- **Windows native**, against the build last run: shim 57/0, security 55/0, race 2/0, mem 86/0, vgc 47/0, wd 35/0, penalty 6/0 (unchanged counts).
- **`sh test/native/run-pack.sh`**: exit 0; `PASS conformance: 308 cases`, `PASS conf-extra: 409 cases`, part 2 `exactly the 4 lines` / `exactly the 20 lines`, `PACK TESTS: 8 checks, 0 failures`. On Linux part 2 wants 2 and 15 lines (if a Linux PUC 5.3.6 is built; else SKIPPED).
- **`sh test/native/run-packfuzz.sh`**: exit 0, `seed 1: 0 -- lines 33953: EXACT 32749, DEVIATION 1204, SECONDARY 0, MISMATCH 0`.
- **Campaign** (nohup + Monitor; memory: long runs belong to the main session): `OCLJ_PACKFUZZ_SEED=1000 OCLJ_PACKFUZZ_SEEDS=50 OCLJ_PACKFUZZ_CASES=100000 sh test/native/run-packfuzz.sh` (~14 min, want PACKFUZZ PASS), then `OCLJ_PACKFUZZ_PROFILE=long OCLJ_PACKFUZZ_SEED=2000 OCLJ_PACKFUZZ_SEEDS=5 OCLJ_PACKFUZZ_CASES=300` (~2 min, PASS). Optionally `coerce` and `limits`: each exits 1 with exactly the one class §7 names.
- **`sh test/native/negctl-pack.sh`** (`make` on PATH, PUC present): `NEGCTL-PACK: PASS`, canon `0 0`, every other arm caught, ~3 min. Expected per-arm verdicts are §6's.
- **`negative-control.sh`**: unchanged; expect round 1's 56 PASS / 0 FAIL (its canon arm now builds against an archive with pack; its checks do not involve pack [I]).
- **Serializer:** `make -C serializer CC=gcc test`: m1 82, m2 56, m3 79, contract rc 0, stack-universe `FAILS: 0`, `FINGERPRINT RESULT: ALL 18 TESTS PASS`, `STRPACK RESULT: ALL 10 TESTS PASS`, for-in exact. `make -C serializer CC=gcc negctl`: `NEGCTL-FINGERPRINT: PASS (all three sabotages caught)`.
- **Harness arms** on the new natives, each one check more than round 1 (d4):

  | arm | CHECKS |
  |---|---|
  | additive JIT on | **81** |
  | dropin | **68** |
  | additive JIT off | **79** |
  | sieve | **75** |
  | stock | **52** (d4 wants `absent`) |
  | disposeoff | **81** |
  | bundleoff | **81** (its 3 expected failures) |

  If any arm reads otherwise, fix README.md:13 ("81 checks") to the measured figure.
- **gradle:** `./gradlew build` after the additive build: `native fingerprint matches the serializer sources and the LuaJIT feature set (baf083da|ffi0.lua52....pack1)`.

### 9.4 Afterwards

- A memory note for this round; correct `fork-extension-decisions-2026-10-13` ("Rounds 2 ... next").
- Recommended, not required for the commit: an in-game boot and save/restore (row T10); a Plan9k boot on the harness (`consumers`: nothing records one); dev-world machines reboot once (hash and word).

---

## 10. Docs (exact text in the targets; dates 2026-10-17)

- **README.md:** the smoke-suite row adds "`string.pack` is in the sandbox and behaves as Lua 5.3.6's" and reads 81 checks; "Lua dialect" gains a paragraph: the fork takes 5.3 functions; the three, with 5.3.6's whole format language; the two deviations; `_VERSION` still 5.2, no `utf8`, no integer subtype, no `//`.
- **NOTICE:** LuaJIT's "Used in" names the feature header and all five changed files (it said `lj_func.c and lj_err.c` only -- round 1 had not updated it); the Lua 5.2/5.3 paragraph adds that `oclj_strpack.c` is ported from Lua 5.3.6's `lstrlib.c`, with argument conversions from its `lauxlib.c`, `lobject.c` and `lvm.c`. Lua 5.3.6's notice (Copyright 1994-2020, `bench/vendor/lua-5.3.6/src/lua.h`) is already reproduced; no new license text.
- **docs/roadmap.md:** `**Status 2026-10-17:**` appended to rows 122 (string.pack no longer optional), 146 (the fork's first 5.3 functions; the factory comment; still absent; Plan9k's 5.3 test; the `tonumber` defect), 196 (the `pack1` token, the measured matrix, what stays outside), 205 (exposure through the metatable, no hooks, bounds, tests; the `:685-686` cite is `:707-708` in the build copy); and a NEW `[x]` row after the FFI row: "`string.pack`, `string.unpack` and `string.packsize`: Lua 5.3.6's, in our fork's string library -- decided 2026-10-13, built 2026-10-17", evidence `bench/runs/2026-10-17-strpack/` (the main session creates it).
- **docs/research/wd-blind-spots.md:** new 1g, pack/unpack/packsize, memory-bounded.
- **LuaJITStateFactory.java / OcljArch.scala:** "OpenComputers' 5.2 library set, exactly" and "fourth dialect" become OC's 5.2 LIST of libraries, whose contents are our fork's (string.pack named).

---

## 11. Commit message draft (the user commits)

```
string.pack, string.unpack and string.packsize, Lua 5.3.6's, in our LuaJIT's own string library: a fifth LuaJIT patch registers them in lib_string.c, native/luajit/oclj_strpack.c is the port, and the blob fingerprint's word gains a pack token

Why: our LuaJIT is a fork that may take Lua 5.3 functions (decided
2026-10-13), and Plan9k needs these: its GPT scanner unpacks I8 fields of
every drive's sector 1 (17_gpt.lua:12), and machine.lua already copies all
three into the sandbox, where they were nil.

- native/luajit/oclj_strpack.c: Lua 5.3.6's PACK/UNPACK section on a VM
  whose numbers are all doubles.  Integers are int64 in C, never
  lua_Integer (LuaJIT's luaL_checkinteger truncates; the shim's
  lua_Unsigned is 32 bits); arguments convert by 5.3.6's rules; pack checks
  and measures, then writes one exact-size block the RAM cap charges first.
  5.3.6's results and errors -- text, argument number, order -- with two
  decided deviations: an unpacked integer beyond 2^53 is the nearest double,
  never refused, and 'l'/'L' are 8 bytes everywhere.  The s[n] length check
  cannot wrap and still raises 5.3.6's text.
- native/luajit/patch-strpack-register.sh: three LJLIB_CF registrations in
  the build copy's lib_string.c, so luaopen_string carries them for jnlua,
  luajit.exe and every test, and ("fmt"):pack works through the metatable.
  oclj_features.h names the addition (OCLJ_LIB_STRPACK).
- build-native.sh: the fifth change, asserted like the other four; FFDEF x3;
  oclj_strpack.c warning-free under -Wall -Wextra; a luajit.exe gate; the
  word's pack token checked against luajit.exe.
- Fingerprint: ...|ffi0.lua52.gc64.fr2.dn0.le.p64.pack1.  Without the token
  a blob saved without pack restored silently on a build with it; now every
  crossing is refused at the header.  gradle wants the word to end in .pack1.
- Tests: test/native/run-pack.sh (308 + 409 conformance cases against
  checked-in expectations, their provenance against PUC 5.3.6, pack_test.c
  through the shim and the cap), run-packfuzz.sh (differential against PUC
  5.3.6), negctl-pack.sh (24 sabotages and the unregistered library, each
  caught); serializer tests/strpack.lua, fingerprint.lua 18, negctl arm
  packword; harness d4-sandbox-string-pack.
- Docs: README "Lua dialect", NOTICE, roadmap rows, the factory comment,
  wd-blind-spots 1g.

Evidence: bench/runs/2026-10-17-strpack/.  Saved dev-world machines reboot
once (serializer hash 85097158 -> baf083da, and the pack token); unreleased.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ToCfjxVT2SZodwDPFEt6Js
```

---

## 12. Open risks and notes

1. **Linux not run.** No Linux build, `run-pack.sh` or fuzz on Linux this round. `port` built a Linux PUC 5.3.6 and found the port's outputs byte-identical to Windows and the Linux PUC difference exactly D1 x2 and the `s` text (now matched) [M `port/final-linux/`]; this design's `deviations.txt` linux rows are derived from that [I].
2. **The harness was compiled, not run** (d4's numbers are predictions [I]). gradle's Kotlin was emulated, not compiled [I].
3. **The fuzzer sees results, not memory.** An out-of-bounds read that returned a plausible value would pass it. Every read in `oclj_strpack.c` is behind 5.3.6's own checks or a bounded `memchr` [S]; an ASan campaign on Linux would test that, but proving it can fail needs an invalid access by definition (`fuzz`'s open question): it needs the user's sign-off.
4. **R9:** the Windows PUC reference converts decimal strings with MinGW's `strtod`; a pathological decimal could round differently from LuaJIT's scanner. Untested.
5. **What the VM decides stays different from 5.3.6:** NaN payloads; 8000 results; numbers given to `c`/`s`/`z` formatted by LuaJIT; exponents of 2^20 or more; function names in error messages (`?` under `pcall`); memory-error thresholds (2x the output here, 5.3.6's buffer doubling there).
6. **D6 is a reading of the user's decision** (fields wider than 64 bits stay refused, as in 5.3.6). If the user meant "never refuse anything", the comparator needs a third rule and `pk_unpackint` a change.
7. **`negative-control.sh` is untouched** and does not run `negctl-pack.sh`. Its arms are unaffected [I]; whether to call `negctl-pack.sh` from it is the main session's decision.
8. **`tonumber(s, base)` on Win64** (F14), unfixed.
9. **The heredoc trap bit this round once,** in a scratch Python patch: a `\` + newline inside a quoted heredoc was joined. The target was repaired with the Edit tool and re-verified; every target was written by the Write/Edit tools or copied.
10. **Investigator open questions, closed:** `port` 1 (D3), 2 (D4), 3 (D5), 4 (F8, tested), 5 (risk 4); `place` dropin (D13), token scheme (D8), aliases (none for pack, F8), `tonumber` (8), gradle word (D8), test location (D10); `fuzz` wide integers (D6), LuaJIT-level differences (D7), default suite (D10: `run-pack.sh` needs no PUC; `run-packfuzz.sh` is separate), Linux (1); `consumers` wide integers (D6), NaN (D7), Plan9k files in the repo (no: `pack_test.c` PT2 reproduces the GPT shape in C, and the consumer suite stays a scratch record), the shim path (PT1, measured).

---

## Appendix: target manifest

All targets are under `C:/Users/astro/claude-tmp/oclj/r2/synth/target/`. md5, first 12 hex digits.

| md5 | target |
|---|---|
| `9a74ade4cbb3` | `NOTICE` |
| `012b5d16ad2d` | `README.md` |
| `a5dc741f1dcb` | `build.gradle.kts` |
| `c6deea8197d6` | `docs/research/wd-blind-spots.md` |
| `d9075304fba8` | `docs/roadmap.md` |
| `e2d31a2a30d2` | `native/build-native.sh` |
| `10097c3a4f5d` | `native/luajit/oclj_features.h` |
| `e97d6ed5fa1b` | `native/luajit/oclj_strpack.c` |
| `74f7ee4452ff` | `native/luajit/patch-features-include.sh` |
| `384dd644908a` | `native/luajit/patch-strpack-register.sh` |
| `a27d2fc7d46c` | `serializer/Makefile` |
| `b178ab5fa7a6` | `serializer/README.md` |
| `a824d16fefd3` | `serializer/eris_lj.c` |
| `e33101628291` | `serializer/tests/fingerprint.lua` |
| `6690deb6c05d` | `serializer/tests/negctl-fingerprint.sh` |
| `67f2b32fa700` | `serializer/tests/strpack.lua` |
| `cdd3611ac810` | `src/main/java/io/github/astronfo/ocluajit/arch/LuaJITStateFactory.java` |
| `1ca75f600f55` | `test/native/OcljArch.scala` |
| `b8eeba62bb17` | `test/native/OcljSmoke.scala` |
| `af113b640cbe` | `test/native/negctl-pack.sh` |
| `35912cc618d0` | `test/native/pack/conf-extra.expect` |
| `9fcd2dee98bf` | `test/native/pack/conf-extra.lua` |
| `542149d1bc40` | `test/native/pack/conformance.expect` |
| `dd9356e3ac87` | `test/native/pack/conformance.lua` |
| `f0be7a996d6e` | `test/native/pack/deviations.txt` |
| `f2a235162b63` | `test/native/pack/packfuzz-cmp.lua` |
| `75553f9d2a28` | `test/native/pack/packfuzz.lua` |
| `5f331f7f9427` | `test/native/pack_test.c` |
| `ad92648551b7` | `test/native/run-pack.sh` |
| `8f3e99dd5d1d` | `test/native/run-packfuzz.sh` |
| `1bea66cedf29` | `test/native/security_test.c` |

Generators and scratch evidence: `synth/mkroadmap.py` (the roadmap hunks, prefix-anchored, exactly once); `synth/gatecheck.sh`, `gradle_emul.py`, `scalac.sh`, `final-chain.sh`, `xb/xb.lua`, `d4/probe.lua`, `speed/speed.lua`; logs in `synth/logs/` (the final chain in `final-20261017-011016/`); the scratch repo and build tree `synth/repo/` (`build/native` is the reference build tree for implementers); round 1's frozen build copied to `synth/r1ff/build/native` for the fail-firsts.
