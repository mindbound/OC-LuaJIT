# OC-LuaJIT round 1: implementation contract

**LuaJIT without FFI: one feature header, the `%x` patch, the VM-features word, and layout gates**

- **Base:** OC-LuaJIT HEAD `62970a0`; `git status` is clean. The pinned LuaJIT `1ee778a4` at `prototype/watchdog/luajit` is pristine apart from its pre-existing untracked `.stamp`.
- **Written:** 2026-10-16, by the designer, from the five investigator reports. Every load-bearing claim was re-opened or re-run in `C:/Users/astro/claude-tmp/oclj/r1/synth/`.
- **Status of this contract:** every repo file this round changes exists as a TARGET under `C:/Users/astro/claude-tmp/oclj/r1/synth/target/`, at the same relative path, with the md5 listed in the appendix.
  - Run end to end in scratch, on a scratch repo tree (`synth/repo`) and the real pinned checkout, read-only: `build-native.sh` (dropin and additive), the seven native suites, `negative-control.sh`, the serializer `make test` and `make negctl`.
  - Not run anywhere yet: the harness (`OcljSmoke.scala`), gradle (its check was emulated on real DLL bytes) and anything on Linux.

Legend: **[M]** measured (who, where); **[S]** read in source (file:line); **[I]** inferred.

---

## 0. Scope and rules

### In scope

The user decided these on 2026-10-13. Do not relitigate them.

1. Build the native with `LUAJIT_DISABLE_FFI`.
2. Carry the one-line LuaJIT patch that keeps `string.format`'s non-`%d` integer conversions compiled.
3. Add a VM-features word to the blob fingerprint.
4. Add layout gates, so that every translation unit that includes LuaJIT's internal headers is compiled with the archive's feature set.
5. Add tests that fail on HEAD first.

The mod is unreleased (README.md:9), so a one-time cross-build break is free. The first native built from this round refuses every existing dev-world blob, for two independent reasons: the serializer hash moves from `8c5a1168` to `8c9d50bc`, and the word is new. Those machines reboot.

### Not in this round: the relayed `string.pack` request

The user's request this turn asks for the full 5.3.6 `string.pack` format language. That is the NEXT round, and this round is its prerequisite:

- With FFI off there is no 64-bit integer type at all. That is why the user's decisions stand that `unpack` rounds values above 2^53 and that `'l'`/`'L'` are 8 bytes.
- When `string.pack`, `unpack` and `packsize` land, they add C functions reachable from `_G`, so the permanent set grows. This is the class of change roadmap row 196 describes, and it is checked by name only.
- Whether the shim or the LuaJIT patch set then joins the fingerprint is decided with that work, depending on where `pack` lives.
- The VM-features word gets no `pack` token.

### Rules for implementers

- Edit only your own files (§8). Write LF line endings. Use no git commands.
- Never write under `build/` or into `serializer/` at run time. Never run `negative-control.sh`, the harness or gradle: those belong to the main session.
- You MAY build and run in your own scratch directory.
  - **Reference build tree:** `C:/Users/astro/claude-tmp/oclj/r1/synth/repo/build/native`. It is a complete `build-native.sh` output: windows-x86_64, last variant additive, from exactly the target files. Copy it into your scratch before pointing anything at it.
  - Running `OCLJ_BUILD=<your scratch>/build/native sh native/build-native.sh` is allowed. Every write goes under `OCLJ_BUILD`, and one variant takes about 14 s.
  - JDK headers: `C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include`.
  - OC-JNLua: `C:/Users/astro/Downloads/OC-JNLua`.
  - `make`: prepend `/c/Users/astro/claude-tmp/oclj/bin` to `PATH`. Use the POSIX form: an entry with `C:` breaks `PATH`.
- **Targets are normative.** For each file in §8:
  1. Put the target's bytes at the repo path and `cmp` them.
  2. Read `diff` HEAD..target, and confirm that every hunk is one this contract describes.
  3. If you find a defect, fix it in the repo file and report the deviation with the reason. Never edit `synth/`.
- Never use a shell heredoc to write a file that contains backslashes (memory: heredocs eat backslashes). Use the Write or Edit tool.

---

## 1. Facts this rests on

**F1 [S][M] On HEAD the lexer mints cdata with no `ffi` in scope.**
- `lj_lex.c:116` enables `STRSCAN_OPT_LL|IMAG` only under `LJ_HASFFI`.
- `:127` calls `ctype_loadffi`.
- `:141` raises `LJ_ERR_XNUMBER` otherwise.
- Measured today:
  - HEAD's `build/native/luajit-windows-x86_64/src/luajit.exe` on the gate script (§4.3) prints `lit=ACCEPTED preload=function: … loaded=table: … s=0/1/0 x=1/0/0 same=true`.
  - The TARGET `security_test.c`, linked against HEAD's build objects (`build/native/obj-windows-x86_64/*.o` plus the archive), reports **55 checks, 14 failures**: exactly FF1-FF8, FF10, FF11 and BF1-BF4.

**F2 [S]/[I] Defects reachable today.**
- (a) A cdata alive at save time hits the `default:` case of `persist_typed`, `eris_lj.c:1715` (`"eris-lj: cannot persist %s"`). `LuaJITArchitecture.java:645-650` catches the `LuaRuntimeException` and removes `state`. The computer comes back off, with its RAM gone. This path was read, not run.
- (b) A cdata argument to a component call on the synchronized path ends in `LuaType.values()[10]`, then an `InternalError`. Source: the prior assessment, `C:/Users/astro/claude-tmp/oclj/ideas/synth/results.json` key `noffi`. [I], not re-read this round.

**F3 [S][M] Layout.**
- `GCROOT_FFI_FIN` exists only `#if LJ_HASFFI` (`lj_obj.h:583-585`, the slot at :584).
- `MMDEF_PAIRS` is under `#if LJ_52 || LJ_HASFFI` (`lj_obj.h:549-555`).
- `sizeof(GG_State)`, measured [M] (flags investigator, `r1/flags/probe/matrix.txt`):

  | flags | GG_State | GG_OFS(J) |
  |---|---|---|
  | none | 6384 | 840 |
  | 52+CH | 6384 | 840 |
  | 52+CH+NOFFI | **6376** | **832** |
  | NOFFI only | 6360 | 816 |

  Re-measured today:
  - The extended stage-1b probe reads `FOREIGN-ALLOC-OK GG=6376` on the no-FFI archive.
  - Its negative arm reads `GG-LAYOUT-MISMATCH lib=6376 tu=6384`.
- jit_State's own layout is invariant: sizeof 3128, with the same field offsets.
- The readers, all re-opened:
  - `lj52shim.c:1750` (`G2J`), `:2323` (`L2J`), and `:1763` (`sizeof(GCtrace)`).
  - `eris_lj.c:952` (`L2J`).
  - `penalty_test.c:116`, `:134`, `:145` and `:191` (`L2J`).
- `race_test.c` and `wd_test.c` touch only `hookmask`, which sits at offset 145 in every configuration. Their objects are identical across flag sets [M flags].

**F4 [S][M] Today's LUA52COMPAT mismatch is real but inert.**
- HEAD's build copy, preprocessed the way the shim sees it, says `LJ_52 0` and `LJ_HASFFI 1` (re-measured today). The archive has `LJ_52 1`.
- The objects are byte-identical either way [M flags], because `lj_obj.h:549`'s `|| LJ_HASFFI` masks the difference.
- With FFI off, the mask is gone: 6360 vs 6376.

**F5 [M][S] A GG_State size check alone is blind** to four things:
- `LJ_52` while FFI is on (6384 both ways);
- `LUAJIT_USE_GDBJIT` (it grows GCtrace: `lj_jit.h:283-285`);
- `LUAJIT_DISABLE_BUFFER` (fast-function and error ids);
- `LUAJIT_NUMMODE`.

Hence one channel plus a refusal list (§3).

**F6 [M] The header channel is equivalent to the -D channel.**
- 77 of 77 objects, `buildvm_arch.h` and the generated headers are identical between a build that gets its flags from an `lj_arch.h` include and the `-D` build [flags, `r1/flags/objcmp`].
- Re-measured today on the scratch build (`XCFLAGS=""`):
  - The log carries no LuaJIT feature `-D`. The only `-D`s are `-D_FILE_OFFSET_BITS`, `-D_LARGEFILE_SOURCE`, `-DLUAJIT_TARGET`, `-DLJ_ARCH_HASFPU` and `-DLJ_ABI_SOFTFP`.
  - The DynASM line has no `-D FFI`.
  - The `-dM` verdict is `OCLJ_LUAJIT_FEATURES 1`, `LJ_52 1`, `LJ_HASFFI 0`, `LJ_HASJIT 1`, `LJ_GC64 1`.
  - `nm` shows `T lua_newstate`, and neither `luaopen_ffi` nor `lj_ccallback_new`.
  - CHECKHOOK reads 80000 ticks, and `table.unpack` is present.
  - The additive DLL is 723 142 bytes, against HEAD's 839 353.

**F7 [S] Compile-site census** (flags investigator; spot-checked): see the table in §3. Every site passes either `-I<build copy>/src` or the pristine tree (the serializer Makefile, the prototypes).
- `bench/runs/2026-10-05-errmem/census/build.sh:23-25` hard-codes `-DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_CHECKHOOK` while recompiling `lj_err.c`.

**F8 [S] `lj_arch.h:9`, `#include "lua.h"`, occurs exactly once.**
- `lj_arch.h` is reached by every internal header: `lj_obj.h:14`, `lj_bc.h:10`, `lj_target.h:10`.
- The public headers (`lua.h`, `luaconf.h`, `lauxlib.h`, `lualib.h`, `luajit.h`) test no feature macro (grep).
- The pinned tree's working copy is CRLF: `lj_arch.h` has 778 CRs, and `grep -c $'\r'` reports 0 there, which is the instrument and not the file.

**F9 [S] The `%x` NYI.**
- It is `lj_ffrecord.c:1104-1112`: `#if LJ_HASFFI … #else recff_nyiu(J, rd); /* Don't bother… */ return; #endif`.
- The same NYI comment also appears at `:830` (`bit.tohex`), so a one-line anchor would be ambiguous.
- `handle_num` is at `:1120-1124`, and `id` is set at `:1088` (putfnum_int) and `:1116` (putfnum_uint).
- `%c` is a different case (`:1138-1146`) and is not affected [M tests].

**F10 [M fmtx] The `%x` patch.**
- 11 of 11 int-operand shapes STITCH unpatched and LOOP patched.
- A 2009-case compiled-vs-interpreted differential: 0 rows differ between the ffi, noffi, fmtx, fmtxa and alt builds, and 840 cases go through the patched branch.
- The sabotages fail it: sab1 843 mismatches, sab2 507.
- Speed: unpatched/patched is 1.6-2.1x when strings repeat and 1.2x when every result is a new string. Patched vs the FFI build is 1.02-1.12x (unpinned; noise is about 6%). The memory note's "~3.5x" overstates.

**F11 [M] The merged gate script (§4.3), re-run today, 3 runs each (20 runs for the first two rows):**

| build | output |
|---|---|
| synth (patched, no FFI) | `lit=refused preload=nil loaded=nil s=0/1/0 x=1/0/0 same=true` |
| fmtx/lj-noffi (unpatched) | `… x=0/1/0 same=true` |
| fmtx/lj-sab1, lj-sab2 | `… x=1/0/0 same=false` |
| HEAD and fmtx/lj-ffi | `lit=ACCEPTED preload=function … loaded=table …` |
| fmtx/lj-alt | passes |

**F12 [S][M] Pre-existing, and not this round's to fix.**
- `%c` of an int past 2^31 differs between compiled and interpreted (`lj_opt_narrow.c:474-478`).
- `string.format("%x","inf")` returns `8000000000000000`.
- `jit.util.tracek` misreports KINT64 constants without FFI (`lj_ir.c:385-393`). No project code calls it.

**F13 [S] The fingerprint today.**
- It is defined at `eris_lj.c:101`: `ERIS_LJ_COMMIT "|" LUAJIT_VERSION "|" ERIS_LJ_SERHASH`.
- Unpersist checks it at `:3171-3176`, with one generic message, before the CRC (`:3179-3183`).
- Persist checks the length at run time, `:3099-3100`. `l_version` returns 3 values (`:3194-3199`).
- `LJ_COMMIT` is the pristine checkout's HEAD (`build-native.sh:421`), so the build-copy patches are invisible to it.
- Shipped: `1ee778a4|LuaJIT 2.1.ROLLING|8c5a1168` [M fprint].

**F14 [M fprint] FFI-on and FFI-off builds of one serializer have identical fingerprints today.**
- The FFI-off build restores the other's plain blob and its recipe blob (`sentinel.hit=1`), and fails only mid-body on an FFI prototype (`r1/fprint/xbuild-out.txt`).
- With the word, all three are refused at the header, and the sentinel stays nil.

**F15 [S][M] eris is compiled with no feature flags** (`build-native.sh:799-801`; `serializer/Makefile:15-17`). A word computed from eris's own macros would read `ffi1.lua51` there [M fprint]. The word is only as true as the channel.

**F16 [S] `lj_state.c:269` is lua_newstate's first allocf call:** `allocf(allocd, NULL, 0, sizeof(GG_State))`.
- `lj52_newstate` creates the arena directly (`lj52shim.c:2648`), so `lj52_alloc`'s first call with M is that `:269` allocation, made from `:2650`.
- `:2651` reads `&G(L)->prng`. prng sits before `gcroot` and is layout-stable.
- `mem_calls` is never reset (`:218`, `:405`, `:2406`).

**F17 [M] The runtime refusal path is clean.**
- `lua_close` and `lj_alloc_destroy` run without a crash [gates R2-R7], and again today in synth.
- `security_test` then prints `SETUP FAILURE: luaL_newstate returned NULL` and exits 2.
- stderr reads: `LJ52 LAYOUT: refusing the state -- libluajit.a laid out a 6376-byte GG_State, lj52shim.c was compiled for 6384 and eris_lj.c for 6376. …`

**F18 [S][M] HEAD's stage-1b probe is blind to layout.** It includes only `<lua.h>` (`build-native.sh:587-603`), and against a no-FFI archive it prints `FOREIGN-ALLOC-OK` (re-run today).

**F19 [S] DEFECT TODAY in the test plumbing: three runners use stale paths.**
- `run.sh:22`, `:34-35`, `run-security.sh:29`, `:42-43` and `run-race.sh:22`, `:32` still name `build/native/luajit/src` and `build/native/obj`.
- The 2026-10-13 chain logged `security exit=2` and `race exit=1` (`bench/runs/2026-10-13-dispose/logs/native/win/summary.txt`).
- `security_test.c` ran only inside `negative-control.sh`.

**F20 [S] The serializer suite tests a configuration that does not ship.**
- `serializer/Makefile:4-6` links `prototype/watchdog/libluajit_stock.a`.
- That archive is built with `XCFLAGS_ST=-DLUAJIT_ENABLE_LUA52COMPAT` (`prototype/watchdog/Makefile:17`, `:54-58`): FFI on, no CHECKHOOK, none of our patches, dated Sep 1.
- **Surprise:** `serializer/README.md` is CRLF in the working tree (index LF, `eol=lf`), unlike every other file this round touches.

**F21 [S][M] Harness.**
- d2 runs in every arm: one d2 line in each 2026-10-13 suite log.
- Row 16 is painted at `OcljSmoke.scala:4180`, and `parse()` stops at a space (`:3161-3162`).
- Last CHECKS: additive 79, dropin 66, JIT-off 77, sieve 73, stock 50, disposeoff 79, bundleoff 79 (bundleoff has 3 expected failures).

**F22 [S][M] negative-control.sh.**
- Its sabotages rewrite only the `lua_load` macro or `lua_compare` (`:166-269`).
- FF and BF call `luaL_loadstring` and `lua_loadx` directly.
- Measured today in scratch, with the target shim, `security_test.c` and the new arm: **52 RESULT: PASS, 0 FAIL**, with the two `build-native.sh refuses` checks SKIPPED because `OCLJ_JNLUA` was unset. The last full run had 52 including those two. Expected with `OCLJ_JNLUA` set: **54**.

**F23 [S] Docs that are wrong today.**
- `docs/ffi-decision.md:12`: the architecture does call `luaopen_ffi` through the lexer.
- `docs/ffi-decision.md:25-27` and `:128`: buffer objects are userdata, not cdata (BF0, measured).
- `docs/research/os-shape-census.md:103`, `:126`.
- Roadmap row 148's reason, and row 205's "closed by construction".

**F24 [S] `lj_bcdump.h:36-37`:** "If you perform *any* kind of private modifications to the bytecode itself or to the dump format, you *must* set BCDUMP_VERSION to 0x80 or higher." This matters for the later bitwise-operator fix, not here.

**F25 [M] Existing suites against the scratch build of the targets (Windows):**
- Native: shim 57/0, security 55/0, race 2/0, mem 86/0, vgc 47/0, wd 35/0, penalty 6/0.
- Serializer: m1 82, m2 56, m3 79, contract rc 0, stack-universe 0 FAILS, fingerprint 16/16, for-in "all cases exact across every pad".
- The kernel patcher's output is unchanged under a no-FFI `luajit.exe` (md5 `1d12c32246f22a901a3cbe06ef217cd5`, `r1/tests/kpatch/`).

**F26 [I fprint, from source] What a player sees on a refused restore** (Machine.scala:808-813, :905, :939-956): the computer is simply OFF, with no in-game message; the reason is only in the server log. This is unchanged by this round and is recorded so nobody expects a message.

---

## 2. Decisions (every open question, closed)

| # | Question | Decision | Why |
|---|---|---|---|
| D1 | Feature channel | A tracked header, `native/luajit/oclj_features.h`, included by the build copy's `lj_arch.h` right after `lua.h`. `XCFLAGS` carries only `$PICFLAG`. | Every TU already passes `-I<build copy>/src`, so the shim, eris, the tests, all 4 negctl compile sites and the 22 archived scripts get the set with 0 compile-line edits (F6, F7). A flags file would need 11+ edits and would leave the archived scripts silently wrong. The hybrid keeps two copies. |
| D2 | `LUAJIT_DISABLE_BUFFER` | Refused by `#error`. | `string.buffer`'s exposure is undecided; defining it is a separate decision. |
| D3 | How a TU proves it read the header | The header defines `OCLJ_LUAJIT_FEATURES 1`, and every internal-header TU does `#ifndef OCLJ_LUAJIT_FEATURES #error`. The marker is not the include guard. | The negative arms supply a header copy and need the marker to pass while the values differ. |
| D4 | Negative arms | Never against the pristine tree: its `luajit.h` is a build artifact, absent on a fresh clone. Always against a copy of `$LJ/*.h` whose `oclj_features.h` has exactly the line `#define LUAJIT_DISABLE_FFI 1` removed. Stage 1b runs its arm on **every** build. | Repeatable and platform-neutral. If FFI is ever re-enabled, the arms refuse loudly ("revisit the arm"). |
| D5 | `%x` fix | `goto handle_num;` (fmtx), not widening `#if LJ_HASFFI` with `\|\| LJ_64` ("alt"). | It calls the interpreter's own function with the same double (equal by construction). alt is no faster within the noise and puts 64-bit IR into a no-FFI build. |
| D6 | `%x` differential as a repo test | No. The build gate's `x` and `same` fields cover the patched branch with 7 conversions × 256 values; the 2009-case differential stays a scratch record (`r1/fmtx/`). | Avoids a second LuaJIT build in negctl. |
| D7 | Fingerprint word | Seven tokens, always in order, computed in `eris_lj.c` from its own macros; restore requires an exact match. No format bump: the field structure is self-describing, and SERHASH moves anyway. No hash of `oclj_features.h` or of the patch scripts. | An exact match also forbids an ffi0 to ffi1 restore that would work. That is stated and accepted (unreleased). |
| D8 | Runtime layout gate | Size only: first fresh allocation == shim `sizeof(GG_State)` == `eris_lj_ggsize()`. **No** k64 second look and **no** `-DOCLJ_GG_SIZE` static assert. | No macro left can shift J at equal size: the header refuses the rest. The k64 look would need its own sabotage arm. |
| D9 | What a refusal returns | `lj52_newstate` returns NULL directly, never through the `luaL_newstate` fallback. The fallback itself is unchanged (row 183 (1) still open). | The fallback state would be read through the same wrong layout, unaccounted. |
| D10 | Serializer suite | Moves to the build copy (forced by D3's guard). | It ends test drift: the suite now runs the shipped archive (F20). |
| D11 | Stale runners | Ported now (`run.sh`, `run-security.sh`, `run-race.sh`); `run-race.sh` refuses a non-Windows host with exit 2. | The new FF and BF sections have to run somewhere other than negctl (F19). |
| D12 | Where FF/BF/JX live | FF and BF go in `security_test.c`. JX stays out (the build gate already runs it against the same archive). No `g4` private-state probe. | security_test is the sandbox-safety file and runs in negctl's canon arm. |
| D13 | Harness | Milestone `d3-sandbox-ffi-literal-refused`, in every arm; the stock PUC 5.2 cell is the reference. | It is the only end-to-end proof through the JNI-loaded DLL. |
| D14 | Build-time word check | Check four tokens (ffi, lua52, fr2, le/be) against the build's `luajit.exe` behaviour; dn, gc64 and p64 are covered by the GG gate and the header's refusals. | The independent observable for each token. |
| D15 | gradle | Fragment `<serhash>\|ffi0.lua52.` | Stops a jar from packing an FFI-on native. |
| D16 | No edit | `race_test.c`, `wd_test.c`, `run-mem.sh`, `run-vgc.sh`, `run-wd.sh`, `run-penalty.sh`, jnlua's compile, `prototype/**`, `bench/runs/**`, negctl's existing compile lines, `LuaJITStateFactory.java`. | Measured layout-insensitive, or public-header only, or frozen. |

---

## 3. The single source of truth, and how every compile site gets it

### 3.1 `native/luajit/oclj_features.h` (NEW; target md5 `d01d1a9105ed…`)

The full text is the target. Its substance:

```c
#ifndef OCLJ_FEATURES_H
#define OCLJ_FEATURES_H
#define OCLJ_LUAJIT_FEATURES 1          /* the marker our TUs check (#error without it) */
#define LUAJIT_ENABLE_LUA52COMPAT 1
#define LUAJIT_ENABLE_CHECKHOOK 1
#define LUAJIT_DISABLE_FFI 1            /* EXACTLY this line: three negative arms toggle it */
/* each of these is refused with its own #error and reason: */
LUAJIT_USE_SYSMALLOC; LUAJIT_DISABLE_JIT | LUAJIT_DISABLE_GC64; LUAJIT_NUMMODE;
LUAJIT_ENABLE_TABLE_BUMP | LUAJIT_DISABLE_PROFILE; LUAJIT_USE_GDBJIT; LUAJIT_DISABLE_BUFFER;
LUAJIT_DISABLE_JITUTIL | LUAJIT_DISABLE_VMEVENT; LUAJIT_DISABLE_DEBUGINFO | LUAJIT_DISABLE_TAILCALL;
LUAJIT_SECURITY_PRNG | _STRHASH; LUAJIT_SECURITY_STRID | _MCODE
#endif
```

**Not refused:** `LUA_USE_ASSERT`, `LUA_USE_APICHECK`, `LUAJIT_USE_VALGRIND` and `LUAJIT_USE_PERFTOOLS`. These debug aids have no layout or bytecode effect (`lj_obj.h:724` and `lj_def.h:355` declare functions only).

**Never in this header:** what the Makefile adds by platform: `LUAJIT_TARGET`, `LJ_ARCH_HASFPU`, `LJ_ABI_SOFTFP`, and `LUAJIT_UNWIND_EXTERNAL` on Linux (Makefile:339-343). `LUAJIT_UNWIND_EXTERNAL` gates declarations only in the headers we include (`lj_trace.h:40`, `lj_err.h:45`, `:53`) [I, Linux not built].

The values are `1`, so an old script's identical `-D` is silent (`errmem/census/build.sh:23-25`), while a conflicting `-D` warns. There are no backslashes in the file.

### 3.2 `native/luajit/patch-features-include.sh` (NEW; md5 `aa67722b7ce5…`)

Usage: `sh patch-features-include.sh <in lj_arch.h> <out lj_arch.h>`. `<in>` and `<out>` may be the same file.

- It strips a trailing CR on every line and writes LF.
- The anchor line `#include "lua.h"` must occur exactly once.
- It inserts this line directly after the anchor: `#include "oclj_features.h"  /* OC-LuaJIT (native/luajit/patch-features-include.sh) */`
- It verifies the result: the marker once, the include once, the include directly after `lua.h`, the line count +1, and the diff 1 added / 0 removed.
- An already-patched input takes a verify-only path.
- It contains no backslashes and no tabs.

Refusals proven today: anchor absent (rc 1); anchor twice (rc 1); include misplaced (rc 1). No output file is written on a refusal. CRLF and LF inputs give byte-identical output.

### 3.3 Per compile site

| Site | Includes internals? | Gets the set by | Change this round |
|---|---|---|---|
| LuaJIT `make` (archive, buildvm, TESTARCH), `build-native.sh` :517 | yes | `lj_arch.h` includes `$LJ/oclj_features.h` | `LJ_FLAGS="$PICFLAG"`; the patch steps; gates G2, G3, G5 |
| stage-1b probe (:587-612) | now yes | `-I"$LJ"` | probe extended, plus a negative arm |
| `lj52shim.c` (:625) | yes (:1074-1078) | `-I"$LJ"` | `#error` guard + runtime gate; compile line unchanged (comment only) |
| `jnlua.c` (:723) | no (`lj52shim.h:41-43` is public only; object measured flag-independent) | n/a | none |
| `eris_lj.c` (:799) | yes | `-I"$LJ"` | `#error` guard + word + `eris_lj_ggsize`; compile line unchanged |
| `serializer/Makefile` | yes (eris) | `-I $(LJSRC)` = the build copy | Makefile moves to the build copy |
| `serializer/test_main.c` | no | n/a | GG check through `eris_lj_ggsize()` |
| `penalty_test.c` (`run-penalty.sh:57`) | yes | `-I"$LJ"` | `#error` guard + GG check |
| `race_test.c`, `wd_test.c` | yes, but layout-insensitive (F3) | `-I"$LJ"` | none |
| shim/security/mem/vgc tests | no | n/a | security_test gains FF and BF |
| `negative-control.sh` :98, :279, :644, :757 | yes (shim copies) | `-I"$LJ"` | none; new arm `layout` |
| `bench/runs/**` (22 scripts) | some | `-I<build copy>` | none (they become correct automatically) |
| `prototype/**` | own FFI-on archives | pristine headers | none (frozen; never linked into the DLL) |

---

## 4. The `%x` patch

### 4.1 `native/luajit/patch-strfmt-xint-noffi.sh` (NEW; md5 `af7311cde19e…`)

This is the fmtx investigator's script (`r1/fmtx/patch-strfmt-xint-noffi.sh`) with one header sentence corrected: the scratch-path citation is replaced by the measured speeds.

**Anchor:** the 9 consecutive lines `lj_ffrecord.c:1104-1112`, compared with leading blanks and a trailing CR removed (CR is built as `sprintf("%c",13)`). They must occur exactly once.

**Replacement:** lines 7 and 8 of the window (`recff_nyiu(J, rd);  /* Don't bother… */`, `return;`) become this block, indented with 8 spaces:

```c
        /* OC-LuaJIT (native/luajit/patch-strfmt-xint-noffi.sh): without FFI,
        ** format an int-typed operand the way the interpreter formats every
        ** number on a non-DUALNUM build: as a double, through
        ** lj_strfmt_putfnum_int or lj_strfmt_putfnum_uint (id, set above).
        ** Upstream stitches or stops the trace here instead.
        */
        goto handle_num;
```

**Verification inside the script:**
- the marker once, the patched window once, the unpatched window absent;
- the line count;
- the diff is 1 hunk, 7 added and 2 removed, and the removed lines are exactly the NYI and the return.

The script refuses 8 mutation classes [M fmtx `negctl-patch.sh` 16/16]. It contains 0 backslashes and 0 tabs.

The scratch output equals the reference build's `lj_ffrecord.c` (cmp, today). It is inert in an FFI build, because the patch is inside the `#else`.

### 4.2 `build-native.sh` call and asserts

Target hunks `513a536,591` and `538,547c616,634`. The patch is the third LuaJIT change; the feature include is the fourth. The steps:

1. **Before `make clean`, the third change:**
   - fail if the pristine `lj_ffrecord.c` carries `FMTX_MARK`;
   - `cp -f` the pristine file over `$LJ/lj_ffrecord.c`, and assert the mark is absent;
   - run the script in place;
   - assert `grep -c -F "$FMTX_MARK" = 1`.
2. **After make:** `lj_ffrecord.o` exists, is `-nt` `lj_ffrecord.c`, and `lj_ffrecord.c` appears in `luajit_build.log` (`grep -F`).
3. **After the CHECKHOOK gate:** the functional gate in §4.3.

### 4.3 The differential test: the FFI / integer-format gate

`build-native.sh` writes `$OCLJ_BUILD/noffi.lua` from a quoted heredoc and runs it on `$LJEXE`, which links this `libluajit.a`. It requires the output to be **exactly**:

```
lit=refused preload=nil loaded=nil s=0/1/0 x=1/0/0 same=true
```

The script, verbatim (it is also `synth/repo/build/native/noffi.lua`, written by the scratch build):

```lua
local f, e = load("return 1LL", "=lit")
local lit = f and "ACCEPTED" or (tostring(e):find("malformed number", 1, true) and "refused" or "other")
f = nil
local jutil = require("jit.util")
local fmt = string.format
local s = string.rep(string.char(0, 1, 127, 128, 200, 255), 400)
local function arm(hot)
  local st, mine = { loop = 0, stitch = 0, abort = 0 }, {}
  local function cb(what, tr, func)
    if what == "start" then mine[tr] = (func == hot)
    elseif what == "stop" and mine[tr] then
      local lt = jutil.traceinfo(tr).linktype
      if st[lt] then st[lt] = st[lt] + 1 end
    elseif what == "abort" and mine[tr] then st.abort = st.abort + 1 end
  end
  jit.flush()
  jit.attach(cb, "trace")
  local out = hot(s)
  jit.attach(cb)
  return st.loop .. "/" .. st.stitch .. "/" .. st.abort, out
end
local function hs(str) local n = 0 for i = 1, #str do n = n + #fmt("%s", str:byte(i)) end return n end
local function hx(str) local t = {} for i = 1, #str do local v = str:byte(i) - 128
  t[#t + 1] = fmt("%02x|%X|%#o|%u|%5d|%+d|%-4i;", v, v, v, v, v, v, v) end return table.concat(t) end
local function hi(str) local t = {} for i = 1, #str do local v = str:byte(i) - 128
  t[#t + 1] = fmt("%02x|%X|%#o|%u|%5d|%+d|%-4i;", v, v, v, v, v, v, v) end return table.concat(t) end
jit.off(hi)
local sres = arm(hs)
local xres, xout = arm(hx)
print("lit=" .. lit .. " preload=" .. tostring(package.preload.ffi) .. " loaded=" .. tostring(package.loaded.ffi) ..
  " s=" .. sres .. " x=" .. xres .. " same=" .. tostring(xout == hi(s)))
```

What the fields mean:

- **lit, preload, loaded:** FFI is compiled out. The script never calls `pcall(require,"ffi")`, because a stray `ffi.lua` could answer it.
- **s:** the detector's own control. `%s` of a number stitches on every build.
- **x:** a hot loop of 7 integer conversions on an int-typed operand compiles as one loop.
- **same:** the hot loop's output equals the output of a separately compiled prototype run under `jit.off`. `jit.off` marks a prototype, so a second closure of the same prototype would also run interpreted.

**Fail-first [M], all re-run today:**

| build | reading |
|---|---|
| HEAD | `lit=ACCEPTED …` |
| unpatched no-FFI (`r1/fmtx/lj-noffi`) | `x=0/1/0` |
| sabotage builds (`lj-sab1`, `lj-sab2`) | `same=false` |
| target | passes, 20 of 20 runs |

---

## 5. The fingerprint's VM-features word

### 5.1 Encoding

The wire format stays as it is: `ERIS_LJ_FORMAT 3`, header `'E''L''J' u8 format | u8 fplen | fingerprint | value | u32le crc`.

The fingerprint becomes 4 `|`-separated fields:

```
<LJ_COMMIT>|<LUAJIT_VERSION>|<SERHASH>|<WORD>
```

`WORD` is the 7 tokens below, `.`-joined in this order. A restore requires an exact match.

| token | from | values |
|---|---|---|
| 1 | `LJ_HASFFI` | `ffi1` / `ffi0` |
| 2 | `LJ_52` | `lua52` / `lua51` |
| 3 | `LJ_GC64` | `gc64` / `gc32` |
| 4 | `LJ_FR2` | `fr2` / `fr1` |
| 5 | `LJ_DUALNUM` | `dn1` / `dn0` |
| 6 | `LJ_BE` | `be` / `le` |
| 7 | `LJ_64` | `p64` / `p32` |

Expected values:

| build | fingerprint | length |
|---|---|---|
| shipped (measured today in the scratch additive DLL) | `1ee778a4\|LuaJIT 2.1.ROLLING\|8c9d50bc\|ffi0.lua52.gc64.fr2.dn0.le.p64` | 67 B |
| serializer test build | `1ee778a4e37122d8ca7d5733c590a47dafd6b15c\|LuaJIT 2.1.ROLLING\|8c9d50bc\|ffi0.lua52.gc64.fr2.dn0.le.p64` | 99 B |

The u8 limit is 255. It is enforced at compile time by `_Static_assert(sizeof(ERIS_LJ_FINGERPRINT) - 1 <= 255, …)`, which was proven to fire at 289 bytes [M fprint]. The old runtime check stays as dead code.

### 5.2 Where it is computed: `serializer/eris_lj.c` (target md5 `5df7b22e6f71…`)

The source is fprint's `mkword.py`, with the additions below. The hunks:

1. Under the internal includes, add `#include "lj_dispatch.h"` (after `lj_trace.h`), then the FEATURE CHANNEL comment and `#ifndef OCLJ_LUAJIT_FEATURES #error "eris_lj.c must be compiled against native/build-native.sh's LuaJIT build copy …" #endif`.
2. `:101` becomes:
   - the THE VM-FEATURES WORD comment;
   - 7 `#if` blocks defining `ELJ_W_FFI` through `ELJ_W_PTR`;
   - `#define ERIS_LJ_FEATURES ELJ_W_FFI "." ELJ_W_52 "." ELJ_W_GC "." ELJ_W_FR "." ELJ_W_DN "." ELJ_W_END "." ELJ_W_PTR`;
   - `#define ERIS_LJ_FINGERPRINT ERIS_LJ_COMMIT "|" LUAJIT_VERSION "|" ERIS_LJ_SERHASH "|" ERIS_LJ_FEATURES`;
   - the `_Static_assert`;
   - `size_t eris_lj_ggsize(void) { return sizeof(GG_State); }`.
3. Before `l_unpersist`, add `fp_quote`, `fp_report` and `fp_mismatch`. They walk both fingerprints field by field and raise:

   `eris-lj: build fingerprint mismatch: <LuaJIT commit|LuaJIT version|serializer hash|VM features|extra field> differs (blob '<x>', this build '<y>'); the blob is from a different natives build`

   Each side is capped at 64 bytes. Bytes outside printable ASCII print as `?`. A missing field quotes as `''`.
4. The header check splits into a bounds check (`data too short to be a valid blob`) followed by the compare, which calls `fp_mismatch`. It stays **before** the CRC.
5. `l_version` pushes `ERIS_LJ_FEATURES` as a **4th** return value. `OcljSmoke.scala`'s reader takes three values and is unaffected.
6. Comment fixes:
   - the wire-format comment (`:14-17`) names the 4 fields;
   - the stale `build-native.sh:355` citation (`:92`) becomes "build-native.sh's LJ_COMMIT";
   - the MM citation is `lj_obj.h:549-555`.

`serializer/eris_lj.h` (md5 `c34eccd31c0a…`) gets the fingerprint comment's 4 fields and `size_t eris_lj_ggsize(void);` with its comment. SERHASH becomes **`8c9d50bc`**, provided both files are byte-identical to the targets.

### 5.3 Header limits

`fplen` is a u8 (≤ 255; compile-time asserted). Each side of a mismatch message is capped at 64 bytes and sanitized; blobs are trusted input anyway (`eris_lj.c:31-41`).

The `dn`, `le` and `p` tokens refuse cross-architecture restores (arm64 is `dn1`). That is conservative, because restoring a thread across DUALNUM is untested, and arm64 is parked.

### 5.4 The new serializer test, with its fail-first

**`serializer/tests/fingerprint.lua`** (NEW; md5 `26a3b99d0e2f…`; fprint's file, unchanged). It is word-agnostic and has 16 checks:

- `version()`'s 4th value is the fingerprint's last field, with the documented shape and ≤ 255 bytes.
- The blob carries this build's fingerprint.
- **Control:** re-sealed under its own fingerprint, the blob restores, and its recipe sets a permanent sentinel.
- Each of the 7 tokens, flipped, is refused with `VM features differs`, quoting both words; the sentinel stays nil.
- The pre-word 3-field fingerprint is refused, naming the missing word.
- A word mismatch plus a bad CRC is still reported as a fingerprint mismatch.

Measured results:

| build | result |
|---|---|
| target | ALL 16 PASS |
| HEAD's serializer | 5 FAILED [M fprint, `r1/fprint/runs2/ser-head_*.txt`] |
| compare removed | 9 FAILED (today) |

**`serializer/tests/negctl-fingerprint.sh`** (NEW; md5 `0d1b6590b84d…`). It is run as `make negctl` and writes only under `$(OCLJ_BUILD)/negctl-fingerprint/<stamp>-<pid>/`. It has two arms:

- **nocompare:** the line `    return fp_mismatch(L, in + I.pos, hdr_fplen);` is replaced by `(void)0;` (awk, asserted exactly once). It must exit 9, with exactly 9 `FAIL:` lines: 7 `token`, 1 `three-field` and 1 `CRC`.
- **layout:** the real `eris_lj.c` is compiled against the toggled header copy. It must exit 3 with `LAYOUT MISMATCH` before any test runs.

Both arms PASSED today, against a real `build-native.sh` tree.

**`serializer/test_main.c`** (md5 `6ef0cbc17749…`):
- Before the suite, a throwaway `lua_newstate(gg_alloc, NULL)` records its first fresh allocation size, then closes. If that size differs from `eris_lj_ggsize()`, the binary prints `LAYOUT MISMATCH: …` to stderr and exits **3**.
- It prints the 4th `version()` value and the GG size.

**`serializer/Makefile`** (md5 `4d462e47d0e5…`):
- It derives `OCLJ_OS`/`OCLJ_ARCH` from `uname` (MINGW or MSYS gives windows, Linux gives linux; x86_64 or amd64 gives x86_64).
- `OCLJ_BUILD ?= ../build/native`, `LJSRC := $(OCLJ_BUILD)/luajit-$(OCLJ_OS)-$(OCLJ_ARCH)/src`, `LJLIB := $(LJSRC)/libluajit.a`.
- The missing-archive message says to run `build-native.sh` first.
- `test` adds `./$(BIN) tests/fingerprint.lua`.
- A new target: `negctl: $(LJLIB)` runs `LJSRC='$(LJSRC)' OCLJ_BUILD='$(OCLJ_BUILD)' CC='$(CC)' NEGCTL_LIBS='$(LIBS)' sh tests/negctl-fingerprint.sh`.
- `LJ_COMMIT` stays the 40-character hash.

### 5.5 Build-time check of the word (`build-native.sh` stage 4, hunk `802a1032,1056`)

`OBS` is taken from `$LJEXE`:
- `load("return 1LL")` gives ffi0 or ffi1;
- `table.unpack` gives lua52 or lua51;
- `string.dump(function() end):byte(5)`: `%16 >= 8` gives fr2, `%2 == 1` gives be (`lj_bcdump.h:42`, `:45`).

`WORD` is `grep -a -o -E "[|]$SER_HASH[|]ffi[01][.][a-z0-9.]+" "$OBJ/eris_lj.o"`, with the last field taken. The build fails unless `WORD` matches the 7-token shape and contains every observed token.

Fail-first [M today]:
- HEAD's `eris_lj.o` has no word.
- An eris compiled against the toggled header carries `ffi1…`, against `ffi0` observed.
- The target's eris against HEAD's (FFI) `luajit.exe` disagrees on `ffi1`.

### 5.6 gradle (`build.gradle.kts`, md5 `e8fbb97f46e4…`)

`want` becomes `sha1(eris_lj.c + eris_lj.h)[:8] + "|ffi0.lua52."`. The message and the lifecycle line say "serializer sources and the LuaJIT feature set".

Fail-first, emulated today in Python on real bytes:
- the scratch additive DLL contains the fragment;
- the same DLL with `|ffi0.lua52.` edited to `|ffi1.lua52.` does not;
- HEAD's `dist` DLL does not.

---

## 6. The layout gates

### 6.1 Build time (`build-native.sh`)

**G3, single channel.** Replaces `:539-548`. It fails if `luajit_build.log` matches `-DLUAJIT_(ENABLE|DISABLE|USE|SECURITY)_|-DLUAJIT_NUMMODE`, and prints the counts. It allows `-DLUAJIT_TARGET` and, on Linux, `-DLUAJIT_UNWIND_EXTERNAL`.
- Fail-first [M]: HEAD's log has 77 lines each of LUA52COMPAT and CHECKHOOK.

**G2, preprocessor verdict.** `"$CC" -I"$LJ" -E -dM "$LJ/lj_arch.h"` must contain the lines `#define OCLJ_LUAJIT_FEATURES 1`, `#define LJ_52 1`, `#define LJ_HASFFI 0`, `#define LJ_HASJIT 1` and `#define LJ_GC64 1` (`grep -qx`).
- Fail-first [M]: HEAD gives `LJ_52 0`, `LJ_HASFFI 1`, and no marker.

**G5, symbols.** After the `%x` gate. `nm "$LJ/libluajit.a"` must show `' T lua_newstate$'`, which checks the reader itself. It must show no `' T (luaopen_ffi|lj_ccallback_new)$'`.
- Fail-first [M]: HEAD defines both.

**Patch-step asserts (§3.2, §4.2):**
- the pristine `lj_arch.h` has no include, and the pristine `src/oclj_features.h` does not exist;
- both are re-copied; `oclj_features.h` is `cmp`-equal;
- after patching, the include occurs exactly once, directly after `lua.h` (awk).

**Stage 1b, the layout gate.** Replaces `:579-612`.
- The probe includes `lj_obj.h` and `lj_dispatch.h`, and has `#ifndef OCLJ_LUAJIT_FEATURES #error`.
- Its allocator records the first call's `nsize` when `p == NULL`.
- It prints `FOREIGN-ALLOC-OK GG=<n>`, `FOREIGN-ALLOC-REFUSED` or `GG-LAYOUT-MISMATCH lib=<a> tu=<b>`, and exits 0, 1 or 2.
- The script parses the result with a `case` and keeps the non-GC64 message.

**Negative arm, on every build:**
- `NEGI=$OCLJ_BUILD/layoutneg-$PLATFORM` is recreated, with `cp "$LJ"/*.h`.
- It asserts that `#define LUAJIT_DISABLE_FFI 1` is present, writes `grep -vx` of it into the copy, and asserts the toggle took (the copy is not `cmp`-equal).
- The same probe, compiled with `-I"$NEGI"`, must print `GG-LAYOUT-MISMATCH lib=$LJ_GG tu=<digits>`. Otherwise: `THE LAYOUT GATE CANNOT FAIL`.

Measured today: `FOREIGN-ALLOC-OK GG=6376`, and the negative arm reads `GG-LAYOUT-MISMATCH lib=6376 tu=6384`. HEAD's probe is blind (F18), and HEAD's headers stop at the `#error`.

### 6.2 Run time, in the shim (`native/lj52shim.c`, md5 `3b31a9740457…`)

The hunks, all tested with 0 warnings under `-Wall -Wextra`, in both variants:

1. Comment at `:1-3`: the shim is built with the set in `oclj_features.h` (LUA52COMPAT, CHECKHOOK, DISABLE_FFI) and must be compiled against it.
2. `lj52_mem` gains `size_t gg_seen;` after `heap`.
3. In `lj52_alloc`, `M->mem_calls++;` becomes:

   ```c
   /* The first call on a record is lua_newstate's GG_State (lj_state.c:269):
    * lj52_newstate's layout gate compares its size with ours. */
   if (M->mem_calls++ == 0 && ptr == NULL) M->gg_seen = nsize;
   ```

4. After `#include "lj_prng.h"`: the FEATURE CHANNEL comment, then `#ifndef OCLJ_LUAJIT_FEATURES #error "lj52shim.c must be compiled against native/build-native.sh's LuaJIT build copy …" #endif`.
5. Just above `lj52_newstate`:

   ```c
   static int lj52_layout_ok(const lj52_mem *M) {
     size_t mine = sizeof(GG_State), eris = eris_lj_ggsize();
     if (M->gg_seen == mine && eris == mine) return 1;
     fprintf(stderr, "LJ52 LAYOUT: refusing the state -- libluajit.a laid out a %lu-byte "
             "GG_State, lj52shim.c was compiled for %lu and eris_lj.c for %lu.  Compile both "
             "against native/build-native.sh's LuaJIT build copy (its lj_arch.h includes "
             "native/luajit/oclj_features.h) and link that copy's libluajit.a.\n",
             (unsigned long)M->gg_seen, (unsigned long)mine, (unsigned long)eris);
     fflush(stderr);
     return 0;
   }
   ```

6. In `lj52_newstate`, between `L = lua_newstate(lj52_alloc, M);` and the `&G(L)->prng` line:

   ```c
   if (L != NULL && !lj52_layout_ok(M)) {
     lua_close(L);
     if (M->heap != NULL) lj_alloc_destroy(M->heap);
     free(M);
     return NULL;      /* NOT the luaL_newstate fallback */
   }
   ```

What it covers that a build cannot see: `OCLJ_SHIMOBJ`, stale objects, hand links and the archived scripts. Hot-path cost: one compare on a counter already loaded [I].

**Fail-first [M]:**
- gates R0: HEAD's shim and eris against a no-FFI archive give STATE-OK; the hazard is silent.
- With the gate: R2, R3, R4 and R7 are refused.
- Today: a shim against the toggled header gives exit 2 and the `LJ52 LAYOUT` line; an eris against the toggled header gives the same.

**Permanent negative arm, in `negative-control.sh`:** section `3b. layout`, inserted after `expect le51 …`.
- It copies the canonical `lj52shim.{c,h}` to `$WORK/layout/`, and `$LJ/*.h` to `$WORK/layout/inc/` with the toggled `oclj_features.h`.
- It compiles the shim with `-I"$d/inc"`, and links the canonical `$OBJ/eris_lj.o` with the real archive.
- `expect layout "a shim compiled for another LuaJIT layout gets no state (exit 2, no check runs)" 2`.
- A second verdict requires `^LJ52 LAYOUT: refusing the state` and `luaL_newstate returned NULL` in `run.log`.
- The header comment gains a 3b paragraph and a paragraph saying that FF and BF test the archive.
- Measured in a scratch run of the whole script: both PASS, 52 of 52 total.

### 6.3 eris, and the serializer binary

`eris_lj_ggsize()` (§5.2) is what the shim compares against, and what `test_main.c` compares against (§5.4). Its fail-first is negctl-fingerprint's `layout` arm.

### 6.4 `penalty_test.c` (md5 `524786bfb587…`)

- After `#include "lj_bc.h"`: the `#error` guard.
- `crt_alloc` records its first fresh `nsize`.
- After `lua_newstate`: if that size is not `sizeof(GG_State)`, it prints `penalty_test: proved nothing -- libluajit.a laid out a %lu-byte GG_State, this file was compiled for %lu …`, closes the state and exits **2**.

This protects `run-penalty.sh`'s `OCLJ_LJLIB` A/B. Fail-first [M today]: `OCLJ_LJLIB=<HEAD's FFI-on libluajit.a> sh test/native/run-penalty.sh` gives the "proved nothing … 6384 … 6376" line.

**Consequence:** a future A/B archive for the penalty scrub must itself be built through the header channel.

---

## 7. Behaviour tests

| Test | Lives in | Ids | HEAD (fail-first) | After |
|---|---|---|---|---|
| `1LL`, `2ULL`, `0x10ULL`, `3i`, `1LL << 40` refused as `malformed number` | `test/native/security_test.c` §FF | FF1-FF5 | FAIL: each loads, lua_type 10 | PASS [M today] |
| sandbox-shaped `load('return 1LL','=lit','t',{})` refuses | §FF | FF6 | FAIL | PASS |
| no ffi in `_LOADED` / `_PRELOAD` | §FF | FFP (before), FF7, FF8, FF11 (after the bytecode route) | FF7, FF8, FF11 FAIL | PASS |
| FFI-flagged dump refused in mode `"b"` | §FF | FF10 (FF9 is the plain-dump control; FF0 the plain-literal control) | FF10 FAIL | PASS |
| buffer FFI methods absent | §BF | BF1-BF4 (`reserve`, `commit`, `ref`, `putcdata`); BF0 control: works, objects are `userdata` | BF1-BF4 FAIL | PASS |
| `%x` compiled, and agrees with the interpreter | `build-native.sh` gate (§4.3) | `x=`, `same=` | (HEAD compiles it via FFI IR; the fail-first is the unpatched no-FFI build: `x=0/1/0`) | `x=1/0/0 same=true` |
| FFI gone through the real DLL, in a booted OpenOS | `test/native/OcljSmoke.scala` | `d3-sandbox-ffi-literal-refused` | additive/dropin FAIL `ACCEPTED`; stock PASS [I] | PASS in every arm [I] |

`security_test.c` (md5 `0278c91d1f1d…`) is generated from the tests investigator's `r1/tests/nf_test.c`:
- the two fixture arrays from `:73-81` go above the LE probes, unchanged. They were verified today: HEAD's `luajit.exe` reproduces both dumps byte for byte (25 B with flags `0x0E`; 22 B with `0x0A`);
- the FF and BF blocks, `:152-261`, go after `check("LE8", …)` and before the summary;
- header paragraphs REGRESSION 4 and REGRESSION 5 are added.

The file then has **55 checks**: 37 old + 18 new. Against HEAD's objects it gives exactly 14 failures (F1). It compiles with 0 warnings. Do not change the text `luaL_newstate returned NULL` at `:208`: negctl's layout arm greps it.

`OcljSmoke.scala` (md5 `d50690ad4a8a…`) has three hunks:
1. In `AutorunLua`, after the OCLJGATE block: the probe, `local litRow; do local f, e = load("return 1LL", "=litprobe") … end`. The chunk is loaded and **dropped, never called**.
2. Row 16 paints `gate .. " OCLJLIT=" .. litRow`.
3. After d2: `val lit = parse(txtA2, "OCLJLIT")` and `milestone("d3-sandbox-ffi-literal-refused", lit == "refused", …)`, with detail for `<missing>`, `ACCEPTED` and `other`.

This file is not compiled here: the main session's harness runs compile it.

---

## 8. File ownership (5 implementers, disjoint)

Every file is a TARGET: put its bytes in place, `cmp`, then review the diff against HEAD.

**A: LuaJIT build plumbing**
- NEW `native/luajit/oclj_features.h`
- NEW `native/luajit/patch-features-include.sh`
- NEW `native/luajit/patch-strfmt-xint-noffi.sh`
- `native/build-native.sh`. Its hunks are E1-E16, all in the target diff:
  - E1, E2: header lines 22-23, and after line 48;
  - E3: the `:50-59` paragraph becomes THE LUAJIT FEATURE SET (the false "NOT an upstream option" sentence goes with it);
  - E4: `:242` `LJ_FLAGS="$PICFLAG"` and `LJ_FEATURES_H`;
  - E5: the preflight `[ -f "$LJ_FEATURES_H" ]`;
  - E6: the `:422` say line. Keep its `luajit  = <dir> @` prefix: `negative-control.sh` parses it;
  - E7: print the features;
  - E8: comment;
  - E9: the third and fourth changes;
  - E10: `lj_ffrecord.o` checks;
  - E11: G3 and G2;
  - E12: the `%x`/FFI gate and G5;
  - E13: stage 1b;
  - E14: the shim compile comment;
  - E15: the eris comment and the word check;
  - E16: PREREQUISITES 4.
- Self-check: run `sh -n`, then `OCLJ_BUILD=<scratch> … sh native/build-native.sh` for dropin and for additive, and expect the lines listed in §9.

**B: shim and the internals tests**
- `native/lj52shim.c`
- `test/native/penalty_test.c`
- `test/native/negative-control.sh`
- Self-check: compile the shim in both variants against the reference build tree (0 warnings); link `security_test` with the toggled header and expect exit 2 plus `LJ52 LAYOUT`.

**C: serializer and gradle**
- `serializer/eris_lj.c`
- `serializer/eris_lj.h`
- `serializer/test_main.c`
- `serializer/Makefile`
- `serializer/README.md`: write it LF. The working tree is CRLF today (F20); git normalizes on add.
- NEW `serializer/tests/fingerprint.lua`
- NEW `serializer/tests/negctl-fingerprint.sh`
- `build.gradle.kts`
- Self-check: in a scratch copy of `serializer/`, run `make OCLJ_BUILD=<copy of the reference build> CC=gcc test negctl`.

**D: behaviour tests, runners, harness**
- `test/native/security_test.c`
- `test/native/run.sh`, `run-security.sh`, `run-race.sh`. These are ports to `luajit-$PLATFORM/src` and `obj-$PLATFORM`, with the run-wd.sh platform block and `$TEST_EXTRA`. `run-race.sh` refuses a non-Windows host with exit 2. `run-security.sh` keeps exit 2 for setup failures.
- `test/native/OcljSmoke.scala`
- Self-check: from a scratch copy of `test/native`, with `OCLJ_BUILD=<copy of the reference build>`, `run.sh` gives 57/0, `run-security.sh` 55/0, and `run-race.sh 2 1` gives 2/0.

**E: docs** (§10)
- `README.md`
- `docs/ffi-decision.md`
- `docs/research/os-shape-census.md`
- `docs/roadmap.md`

**Interfaces the implementers rely on** (all fixed by the targets):

| Name | Defined by | Used by |
|---|---|---|
| macro `OCLJ_LUAJIT_FEATURES` (`1`) | A, `oclj_features.h` | B (shim, penalty), C (eris), A (probe, G2) |
| the exact line `#define LUAJIT_DISABLE_FFI 1` | A | A (stage-1b negative arm), B (negctl layout), C (negctl-fingerprint layout) |
| `size_t eris_lj_ggsize(void)` in `eris_lj.h` | C | B (`lj52_layout_ok`), C (`test_main`) |
| stderr prefix `LJ52 LAYOUT: refusing the state` | B | B (negctl) |
| `security_test.c` text `luaL_newstate returned NULL`; ids FF0, FFP, FF1-FF11, BF0-BF4 | D | B (negctl layout arm; the canon arm expects 0 failures) |
| fingerprint `…\|<SERHASH>\|ffi[01].lua5[12].gc..` and `l_version` 4th value | C | A (stage-4 word check), C (gradle, `fingerprint.lua`) |
| `test_main` exit 3 and stderr `LAYOUT MISMATCH` | C | C (negctl-fingerprint) |
| `make negctl` passes `LJSRC`, `OCLJ_BUILD`, `CC`, `NEGCTL_LIBS` | C | C |
| harness token `OCLJLIT=` on row 16, milestone id `d3-sandbox-ffi-literal-refused` | D | E (README count), main session |

Each implementer reports: the `cmp` result for each file, any deviation with its reason, and the self-check outputs.

---

## 9. What the main session runs afterwards

Record everything in a fresh `bench/runs/2026-10-16-noffi/` (`logs/`, `scripts/`, `failfirst/`). Never clear or reuse a results directory.

### 9.1 Fail-first, BEFORE any rebuild (HEAD's `build/native` must still be in place)

1. Save HEAD's artifacts into `failfirst/head/`: `build/native/luajit-windows-x86_64/src/{libluajit.a,luajit.exe}`, `build/native/luajit_build.log`, `build/native/obj-windows-x86_64/eris_lj.o`.
2. `OCLJ_JNI=… sh test/native/run-security.sh` (new runner, new test, HEAD's objects). Expect exit 1, `55 checks, 14 failures`, ids exactly `FF1 FF2 FF3 FF4 FF5 FF6 FF7 FF8 FF10 FF11 BF1 BF2 BF3 BF4`.
3. The build-gate readings on HEAD:
   - `grep -cE -- '-DLUAJIT_(ENABLE|DISABLE|USE|SECURITY)_' build/native/luajit_build.log` gives 77, not 0.
   - `-dM` through HEAD's build copy gives `LJ_52 0`, `LJ_HASFFI 1`, and no `OCLJ_LUAJIT_FEATURES`.
   - `nm` shows `T luaopen_ffi` and `T lj_ccallback_new`.
   - HEAD's `luajit.exe C:/Users/astro/claude-tmp/oclj/r1/synth/repo/build/native/noffi.lua` gives `lit=ACCEPTED …`.
   - The same script on `C:/Users/astro/claude-tmp/oclj/r1/fmtx/lj-noffi/src/luajit.exe` gives `x=0/1/0`; on `lj-sab1` and `lj-sab2` it gives `same=false`.
   - HEAD's `eris_lj.o` has no `|8c5a1168|ffi` word.
4. Harness, new `OcljSmoke.scala` on HEAD's natives:
   - additive, JIT on: `d3-sandbox-ffi-literal-refused: FAIL … ACCEPTED`, CHECKS 80;
   - stock: d3 PASS, CHECKS 51.
   On HEAD, lexing `1LL` loads ffi into the machine (+10.7 KB), so this fail-first asserts only d3.

### 9.2 Builds

Windows, both variants:

```sh
OCLJ_VARIANT=dropin   sh native/build-native.sh
OCLJ_VARIANT=additive sh native/build-native.sh
```

Each must exit 0 and print, among its existing lines:

```
[build] luajit  = …/prototype/watchdog/luajit @ 1ee778a4 (feature set: native/luajit/oclj_features.h)
[build]     features (native/luajit/oclj_features.h): LUAJIT_ENABLE_LUA52COMPAT LUAJIT_ENABLE_CHECKHOOK LUAJIT_DISABLE_FFI
[build]     lj_ffrecord.c: no-FFI integer-format fallback present … ; lj_arch.h: includes oclj_features.h once, right after lua.h …
[build]     feature set through -I$LJ (lj_arch.h -dM): OCLJ_LUAJIT_FEATURES 1, LJ_52 1, LJ_HASFFI 0, LJ_HASJIT 1, LJ_GC64 1
[build]     luajit says: true|Lua 5.1|LuaJIT 2.1.ROLLING|x64
[build]     count-hook ticks over a hot loop: 80000|ok
[build]     FFI / integer-format gate: lit=refused preload=nil loaded=nil s=0/1/0 x=1/0/0 same=true
[build]     libluajit.a: lua_newstate defined; luaopen_ffi and lj_ccallback_new not (FFI compiled out)
[build]     FOREIGN-ALLOC-OK GG=6376
[build]     negative arm (FFI toggled back on in a header copy): GG-LAYOUT-MISMATCH lib=6376 tu=6384 -- the gate can fail
[build]     -Wall -Wextra warnings = 0
[build]     serializer hash = 8c9d50bc  (blobs are pinned to this)
[build]     VM-features word ffi0.lua52.gc64.fr2.dn0.le.p64 (luajit.exe agrees: ffi0 lua52 fr2 le)
[build]     ABI surface: Java_* = 87 (want 87), oclj natives = 0, total = 89      # dropin
[build]     ABI surface: Java_* = 91 (want 91), oclj natives = 4, total = 93      # additive
```

The scratch DLLs were 720 490 B (dropin) and 723 142 B (additive). `dist/`'s DLL fingerprint: `1ee778a4|LuaJIT 2.1.ROLLING|8c9d50bc|ffi0.lua52.gc64.fr2.dn0.le.p64`.

WSL Linux .so (additive; dropin if the chain uses it), via the untracked `build/wsl-build-native.sh`. Expect the same gate lines. **Not measured on Linux:** the GG numbers (the gates print whatever they are and never hard-code them); `-DLUAJIT_UNWIND_EXTERNAL` in the log is allowed; the `x=`/`s=` trace counts.

### 9.3 Suites

- **Windows native**, against the build last run: shim 57/0, **security 55/0**, race 2/0, mem 86/0, vgc 47/0, wd 35/0, penalty 6/0. Absolute byte figures may move by 8 or more, because the GG_State shrinks and the FFI library is gone; the counts must not.
- **Linux native**, as in the last chain: wd 35, vgc 47, mem 86, penalty 6. `run-security.sh` (55 expected) and `run.sh` (57 expected) now have Linux paths and `-pthread`, but neither has been run on Linux yet [I].
- **`negative-control.sh`** with `OCLJ_JNLUA` and `OCLJ_JNI` set: **54 RESULT: PASS, 0 FAIL**, `NEGATIVE CONTROL: PASS`. That is 52 before plus 2 for `layout`. Without `OCLJ_JNLUA` it is 52 (measured).
- **Serializer:** `make -C serializer CC=gcc test` must give m1 82, m2 56, m3 79, contract rc 0, stack-universe `FAILS: 0`, `FINGERPRINT RESULT: ALL 16 TESTS PASS`, and `FOR-IN RESULT: all cases exact across every pad`. `make -C serializer CC=gcc negctl` must print `NEGCTL-FINGERPRINT: PASS (both sabotages caught)`.
- **One-time:** `OCLJ_LJLIB=bench/runs/2026-10-16-noffi/failfirst/head/libluajit.a sh test/native/run-penalty.sh` must give `penalty_test: proved nothing … 6384-byte GG_State … 6376`.
- **Harness arms** on the new natives:

  | arm | CHECKS |
  |---|---|
  | additive JIT on | **80** |
  | dropin | **67** |
  | additive JIT off | **78** |
  | sieve | **74** |
  | stock | **51** |
  | disposeoff | **80** |
  | bundleoff | **80** (with its 3 expected failures) |

  d3 must PASS in every arm. The other arms have 0 failures. Run the arms one at a time where the last chain had to (`chain-seq.sh`: concurrent JVMs race on native extraction).
- **gradle:** `./gradlew build`, after the additive build. Its lifecycle line must read `native fingerprint matches the serializer sources and the LuaJIT feature set (8c9d50bc|ffi0.lua52.)`.
- **Kernel:** the smoke test's `machine.lua` md5 stays `1d12c32246f22a901a3cbe06ef217cd5`.

### 9.4 Afterwards (main session only)

- Correct the memory note `fork-extension-decisions-2026-10-13`. Its "~3.5x slower" should read: 1.6-2.1x when strings repeat, 1.2x when every result is new (measured 2026-10-16). Add a memory for this round.
- Recommended, not required for the commit: an in-game boot and save/restore on the new additive jar (row 210, T10). Old saved machines will reboot.

---

## 10. Docs to change

The exact text is in the targets. All dates are 2026-10-16.

**`README.md`**
- Line 13: "the bytecode gate refuses, **a `1LL` literal is a syntax error,** file handles … — **80 checks**, 0 failures (**2026-10-16**, JIT on)".
- A new section, `## Lua dialect`, before `## Documentation`:

  > The LuaJIT architecture runs LuaJIT 2.1 with its Lua 5.2 compatibility switched on. It has **no FFI**: the native is built without it, so there is no `ffi` module, and LuaJIT's 64-bit and imaginary number literals (`1LL`, `2ULL`, `0x10ULL`, `3i`) are a syntax error, `malformed number`, exactly as in PUC Lua 5.2 and 5.3. The reason is persistence: an FFI value cannot be saved, and one alive when the world saves would cost the computer its state ([docs/ffi-decision.md](docs/ffi-decision.md)).

**`docs/ffi-decision.md`**
- After the Evidence line: "**Enforced by construction since 2026-10-16.** … Until then "not exposed" held for the `ffi` name only: LuaJIT's lexer loaded FFI on demand to make a `1LL` (below)."
- `:12` becomes: "The native is built without FFI (`LUAJIT_DISABLE_FFI`, set in `native/luajit/oclj_features.h`): the library has no `luaopen_ffi`, so nothing -- the sandbox, the architecture, the lexer -- can open it."
- `:25-27`: on a LuaJIT built with FFI, the lexer makes cdata (`lj_lex.c:116`, `:127`), and "(A `string.buffer` object is not `cdata`, as this note said until 2026-10-16: it is userdata, measured.)"
- After `:33`: the threat was reachable until 2026-10-16; now it is a load-time syntax error.
- `:125-128` become two bullets: "Done by construction (2026-10-16) … fail if it comes back", and "`string.buffer` stays unexposed; whether to expose it is undecided. Its objects are userdata, not cdata … (`persist_typed` in `serializer/eris_lj.c`) … (`lib_buffer.c:183-237`)".
- After `:133`: "Done: README.md, "Lua dialect"."

**`docs/research/os-shape-census.md`** (a research record, so the corrections are appended and dated):
- end of `:103`: `[Correction 2026-10-16: …two errors…]`;
- end of `:115`: `[2026-10-16: … no ffi to require …]`;
- end of `:126`: `[Correction 2026-10-16: …]`;
- end of `:134`: `[2026-10-16: done in a stronger form than a pcall(require,'ffi') assertion …]`.

**`docs/roadmap.md`**
- `**Status 2026-10-16:**` paragraphs appended to these rows:
  - 146: the fork decision settles the dialect disagreement; the 5.3 operators lost their 64-bit operand form (`1LL << 40` was `1099511627776LL` on HEAD) and stay 32-bit until the bitwise fix;
  - 183: loose end (2) closed;
  - 196: the word, its message and test, the HEAD measurement, what is still outside the fingerprint, and the `BCDUMP_VERSION` rule;
  - 197: gradle's `<hash>|ffi0.lua52.`;
  - 203: flags no longer passed; the header; G3/G2/FFI gate/nm; re-copied files; the removed false sentence;
  - 205: ffi compiled out and tested; "closed by construction" held for the name, not for cdata;
  - 248: the fingerprint test is in `make test`; the suite links the build copy.
- A `**Correction 2026-10-16:**` appended to row 148: the callback page was unreachable for want of `ffi.cast`, not because `ffi` was never opened.
- A NEW `[x]` row directly after row 205: "**LuaJIT is built without FFI, from one feature header -- decided 2026-10-13, built 2026-10-16.**" It covers the why, what was built, the gates and the tests, with evidence `bench/runs/2026-10-16-noffi/`. The main session must create that directory (§9).

**`serializer/README.md`** (owner C):
- Build & test: requires `build-native.sh` on this platform; `make negctl`.
- API: `eris.version() --> version, build fingerprint, format number, VM-features word`.
- Format: the 4 fields; the word; refusal before the checksum, naming the field. The `dn` token refuses across DUALNUM even though the number encoding is identical.

**Unchanged** (still correct, now as dead backstops): `m3-frame-codec.md:123`, `ps-coroutine-frames.md:64`, `eris_lj.c:1544-1545` "(FFI continuations are not supported)". `LuaJITStateFactory.java:88-95`'s "fourth dialect" comment changes with the first 5.3 addition, not here.

---

## 11. Commit message draft (the user commits)

```
LuaJIT without FFI, from one feature header: native/luajit/oclj_features.h is the feature set and the build copy's lj_arch.h includes it, a third LuaJIT patch keeps string.format's integer conversions compiled, the blob fingerprint ends in a VM-features word, and every object that reads LuaJIT's internals is checked against the archive's layout

Why: with FFI compiled in, LuaJIT's lexer made cdata from 1LL, 2ULL, 0x10ULL
and 3i inside the sandbox, loading ffi on demand (lj_lex.c:116, :127); a cdata
alive at save time costs the machine its state.  And the feature flags reached
the archive alone: the shim and eris_lj.c were compiled without them (LJ_52 0
against the archive's 1, inert only while FFI was on), and FFI off moves
jit_State 8 bytes (GG_State 6384 -> 6376).

- native/luajit/oclj_features.h: LUA52COMPAT, CHECKHOOK, DISABLE_FFI, and an
  #error for every other LuaJIT option that changes a structure, the bytecode
  or a gate's instrument.  patch-features-include.sh makes the build copy's
  lj_arch.h include it, so the archive and every TU compiled with -I<build
  copy> read the same bytes; LJ_FLAGS is $PICFLAG alone.
- native/luajit/patch-strfmt-xint-noffi.sh: recff_format's no-FFI NYI for
  %x %X %o %u (and %d with a flag or width) on an int becomes goto handle_num
  -- the interpreter's own function on the same double.  Unpatched, a hot %02x
  loop stitches and runs 1.6-2.1x slower.
- build-native.sh: refuses any feature -D in the LuaJIT log; the -dM verdict
  through -I$LJ; the FFI / integer-format gate (lit=refused ... x=1/0/0
  same=true); nm finds no luaopen_ffi; stage 1b compares the archive's
  GG_State with the probe's and proves on every build that a toggled header
  mismatches (6376 vs 6384); the VM-features word in eris_lj.o is checked
  against luajit.exe.
- lj52shim.c, eris_lj.c, penalty_test.c: #error without the feature header;
  lj52_newstate refuses a state whose GG_State is not the shim's and eris's
  (NULL, never the luaL_newstate fallback); penalty_test.c and the
  serializer's test_main.c make the same check.
- Fingerprint: COMMIT|LUAJIT_VERSION|SERHASH|ffi0.lua52.gc64.fr2.dn0.le.p64;
  a mismatch is refused at the header naming the field; l_version returns the
  word; the length is a compile-time assert.  gradle wants <hash>|ffi0.lua52.
- Tests: security_test.c FF and BF (55 checks; HEAD fails FF1-FF8, FF10, FF11,
  BF1-BF4); harness d3-sandbox-ffi-literal-refused; serializer
  tests/fingerprint.lua (16; HEAD's serializer fails 5) and
  tests/negctl-fingerprint.sh; negative-control.sh arm 'layout'.  run.sh,
  run-security.sh and run-race.sh read the per-platform build again.  The
  serializer suite links the build copy's archive, not libluajit_stock.a.
- Docs: ffi-decision.md (enforced by construction; buffer objects are
  userdata), the census corrections, README "Lua dialect", roadmap rows.

Evidence: bench/runs/2026-10-16-noffi/.  Saved dev-world machines reboot once
(serializer hash 8c5a1168 -> 8c9d50bc, and the new word); unreleased.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ToCfjxVT2SZodwDPFEt6Js
```

---

## Appendix: target manifest

All targets are under `C:/Users/astro/claude-tmp/oclj/r1/synth/target/`. The md5 values are the first 12 hex digits.

| md5 | target |
|---|---|
| `893f75c3f84c` | `README.md` |
| `e8fbb97f46e4` | `build.gradle.kts` |
| `9ff60927a1d5` | `docs/ffi-decision.md` |
| `6b70f11b014b` | `docs/research/os-shape-census.md` |
| `027916066d83` | `docs/roadmap.md` |
| `89d4c28fa337` | `native/build-native.sh` |
| `3b31a9740457` | `native/lj52shim.c` |
| `d01d1a9105ed` | `native/luajit/oclj_features.h` |
| `aa67722b7ce5` | `native/luajit/patch-features-include.sh` |
| `af7311cde19e` | `native/luajit/patch-strfmt-xint-noffi.sh` |
| `4d462e47d0e5` | `serializer/Makefile` |
| `0e436a215179` | `serializer/README.md` |
| `5df7b22e6f71` | `serializer/eris_lj.c` |
| `c34eccd31c0a` | `serializer/eris_lj.h` |
| `6ef0cbc17749` | `serializer/test_main.c` |
| `26a3b99d0e2f` | `serializer/tests/fingerprint.lua` |
| `0d1b6590b84d` | `serializer/tests/negctl-fingerprint.sh` |
| `d50690ad4a8a` | `test/native/OcljSmoke.scala` |
| `20b77a6324c7` | `test/native/negative-control.sh` |
| `524786bfb587` | `test/native/penalty_test.c` |
| `31a3a62bc97b` | `test/native/run-race.sh` |
| `5bdb5a2b36f7` | `test/native/run-security.sh` |
| `cbaec184d676` | `test/native/run.sh` |
| `0278c91d1f1d` | `test/native/security_test.c` |

Generators, all anchored with exactly-once asserts:
- `synth/mkbn.py` with `synth/bn/E*.sh`;
- `synth/mkshim.py`, `mkpenalty.py`, `mksec.py`, `mksmoke.py`, `mkdocs.py`;
- fprint's `r1/fprint/mkword.py`, plus the edits recorded in §5.2.

Scratch evidence: `synth/bn-dropin.log`, `bn-additive.log`, `rt-*.log`, `ser-make.log`, `nctest/negctl.log`, `negbuild/`, and `repo/build/native/` (the reference build tree).
