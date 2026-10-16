# 2026-10-16 -- LuaJIT without FFI, from one feature header

The evidence behind the roadmap row "LuaJIT is built without FFI, from one feature header"
(directly after "Sandbox constraints"). The LuaJIT build copy now reads its whole feature set from
`native/luajit/oclj_features.h`: LUA52COMPAT, CHECKHOOK and DISABLE_FFI, plus an `#error` for
every other option. Its `lj_arch.h` includes that header (`native/luajit/patch-features-include.sh`).

The rest of the round:

- A third LuaJIT patch keeps `string.format`'s integer conversions compiled without FFI
  (`native/luajit/patch-strfmt-xint-noffi.sh`).
- The blob fingerprint ends in a VM-features word.
- Every object that reads LuaJIT's internals is checked against the archive's GG_State size, at
  build time and in `lj52_newstate`.

Implemented in the working tree on HEAD 62970a0, uncommitted.

How it was run:

- **Harness:** on ocelot-brain, with JDK 8 (1.8.0_504) on Windows 11 and the Windows DLLs. The
  watchdog kernel ran on ours and OC's own kernel on stock. One JVM at a time, not core-pinned:
  functional runs.
- **Native tests:** on Windows in place, and on Linux in WSL. No harness run loaded the Linux .so.

## The builds

**HEAD, the fail-first:**

- HEAD 62970a0's natives, frozen at `C:/Users/astro/claude-tmp/oclj/new-6445f2e4`: additive
  `6445f2e4`, dropin `60a8a522`.
- HEAD's `build/native` artifacts, saved before the rebuild: `libluajit.a`, `luajit.exe`,
  `eris_lj.o`, the dropin's `lj52shim.o` and `luajit_build.log`. Their md5s are in
  `failfirst/head.md5`.
- The binaries are NOT in this directory. `.gitattributes`' `* text eol=lf` would rewrite their
  CRLF byte pairs on commit (a clone's `libluajit.a` fails `ar t`). They are kept at
  `C:/Users/astro/claude-tmp/oclj/head-62970a0/`. Only the build log, which is text, is here.

**This build:**

| native | md5 | size |
|---|---|---|
| Windows additive DLL | `aa0f3fa9` | 723 142 B |
| Windows dropin DLL | `a0bbb5fa` | 720 490 B |
| Linux additive .so | `767a6c1d` | |
| Linux dropin .so | `cb8c8373` | |

- The sha256s are in `logs/builds/natives.md5`.
- The serializer hash is `85097158`. The fingerprint is
  `1ee778a4|LuaJIT 2.1.ROLLING|85097158|ffi0.lua52.gc64.fr2.dn0.le.p64`.
- **Windows:** both variants built 20:14-20:15 UTC, dropin first, so `obj-windows-x86_64/` and
  every Windows native test hold the ADDITIVE variant's objects. The harness ran the DLLs from a
  frozen copy, `new-r1-aa0f3fa9/`.
- **Linux:** the .so files were built afterwards in WSL, again dropin then additive
  (`logs/linux/`). No JVM has loaded them. Their evidence is the Linux native suites, which are C
  hosts linked against those objects, and `make test`.
- **Sources:** the md5s at archive time are in `logs/builds/sources.md5`.
- **The jar:** `build/libs/ocluajit-62970a0-master+62970a0b93-dirty.jar`, md5 `ff55afa0`. It is
  a dirty-tree build and was not installed in the game.

## Results

| check | HEAD 62970a0 (fail-first) | this build |
|---|---|---|
| `security_test.c` (55 checks; FF and BF are new) | 14 failures, exactly FF1-FF8, FF10, FF11, BF1-BF4 (`failfirst/head-security.log`) | 55/0 on Windows and on Linux |
| G3: `-DLUAJIT_*` in the LuaJIT log, except the Makefile's platform macros | 77 `ENABLE_LUA52COMPAT` and 77 `ENABLE_CHECKHOOK` (`logs/builds/g3-allowlist-proof.txt`) | none |
| G2: the `-dM` verdict through `-I$LJ` | `LJ_52 0`, `LJ_HASFFI 1`, no `OCLJ_LUAJIT_FEATURES` (`failfirst/head-gates.txt`) | `OCLJ_LUAJIT_FEATURES 1`, `LJ_52 1`, `LJ_HASFFI 0`, `LJ_HASJIT 1`, `LJ_GC64 1` |
| G5: `nm libluajit.a` | `luaopen_ffi` and `lj_ccallback_new` defined | neither |
| the FFI / integer-format gate (`failfirst/noffi.lua`) | `lit=ACCEPTED`; unpatched no-FFI build `x=0/1/0`; sabotaged builds `same=false` | `lit=refused preload=nil loaded=nil s=0/1/0 x=1/0/0 same=true` |
| stage 1b, the layout gate | blind: it included only `<lua.h>` | `FOREIGN-ALLOC-OK GG=6376`; the negative arm reads `GG-LAYOUT-MISMATCH lib=6376 tu=6384` on every build, Windows and Linux |
| the VM-features word in `eris_lj.o` | none | `ffi0.lua52.gc64.fr2.dn0.le.p64`; `luajit.exe` agrees on ffi0, lua52, fr2 and le |
| `penalty_test` against HEAD's FFI-on archive | — | exit 2: "proved nothing -- libluajit.a laid out a 6384-byte GG_State, this file was compiled for 6376" (`logs/native-win/penalty-headlib.log`) |
| gradle's fingerprint fragment, `<hash>\|ffi0.lua52.` | HEAD's DLL refused, and so is this DLL with `ffi0` edited to `ffi1` (`logs/builds/gradle-failfirst.txt`, the gradle check's exact computation on the real bytes) | accepted: `native fingerprint matches the serializer sources and the LuaJIT feature set (85097158\|ffi0.lua52.)` |
| harness d3, additive | FAIL `ACCEPTED`, 80 checks / 1 failure (`failfirst/harness/r1ff-head-additive-a`) | PASS `refused` |
| harness d3, stock | FAIL `other` under the first classifier; see deviation 1 | PASS `refused-puc` |

**Native suites:**

- **Windows** (`logs/native-win/`): shim 57/0, security 55/0, race 2/0, mem 86/0, vgc 47/0,
  wd 35/0, penalty 6/0.
- **Serializer on Windows:** `make test` gives m1 82, m2 56, m3 79, contract, stack-universe
  `FAILS: 0`, fingerprint 16/16 and for-in exact. `make negctl` gives `NEGCTL-FINGERPRINT: PASS`.
- **`negative-control.sh`:** 56 `RESULT: PASS`, 0 FAIL. The two layout arms each name the half
  that differs: `layout` reads 6376 / 6384 / 6376 (archive / shim / eris), and `layout-eris`
  reads 6376 / 6376 / 6384.
- **Linux** (`logs/linux/`): shim 57/0 and security 55/0 (the first Linux runs of these two
  runners), mem 86/0, vgc 47/0, wd 35/0, penalty 6/0. Race exits 2, Win32-only, as designed. The
  serializer `make test` and `make negctl` pass. That is the first `make test` to pass on Linux:
  its for-in step used to name `erislj_test.exe`.

**Harness, this build** (`logs/suite/`):

| arm | checks / failures |
|---|---|
| additive, JIT on | 80 / 0 |
| dropin | 67 / 0 |
| additive, JIT off | 78 / 0 |
| sieve | 74 / 0 |
| stock | 51 / 0 |
| disposeoff (`OCLJ_DISPOSE=off`) | 80 / 0 |
| bundleoff (`OCLJ_PERSIST_BUNDLE=off`) | 80 / 3: stk-2, stk-3 and stk-4, the expected three |

Each arm has one more check than on 2026-10-13: d3.

**`%x`:**

- In `design/fmtx/results-trace-shapes.txt` (re-run for this archive), 11 of 11 int-operand
  shapes stitch unpatched and compile as a loop patched. The three controls (`%d`, `%02x` of a
  float and `%c`) loop on every build.
- A 2009-case compiled-against-interpreted differential (`results-diff.txt`) shows the same 3
  mismatches on all five builds, the FFI one included. All three are the pre-existing `%c`
  defect near 2^31, recorded as found.
  - The patched branch adds none.
  - The unpatched no-FFI build stitches the 420 integer cases that the patched one compiles as a
    loop.
  - The two sabotages fail it (`results-diff-sab1.txt`, `results-diff-sab2.txt`).
- Speed, unpinned: unpatched against patched is 1.6-2.1x when the formatted strings repeat and
  1.2x when every result is new.

**Fingerprint across builds** (`design/fprint/xbuild-out.txt`):

- Before the word, an FFI-off build restored an FFI-on build's blobs, recipes included, and
  failed only mid-body.
- With the word, all three blobs are refused at the header, and the sentinel stays nil.
- A closure holding a `1LL` constant persisted on HEAD (`ok=true bytes=134`). Only a live cdata
  VALUE reaches the refusal.

## Deviations from the contract (`design/design.md`)

The contract was written before the review (`design/review-findings.json`: six reviewers, each
finding put to a skeptic). These are the places where the code and the measurements differ from
it.

1. **d3 in the stock arm.** The contract predicted that PUC 5.2 also says "malformed number". It
   does not. PUC 5.2's and 5.3's `read_numeral` stops at the first character that is not a hex
   digit, so `return 1LL` is `<eof> expected near 'LL'` (PUC 5.3.6 and 5.4.8 were run;
   5.2.4 was read and built by a reviewer).
   - The fail-first stock run (`failfirst/harness/r1ff-head-stock-a`) shows it: `other`, 51 / 1.
   - The probe now paints `refused` for LuaJIT's message and `refused-puc` for PUC's, and each
     arm wants exactly its own. The stock arm runs OC's PUC native, not ours, so `r1-stock-a` is
     also the HEAD reading.
   - The additive fail-first ran under the first classifier. `ACCEPTED` is the same under both.
   - The false "exactly as in PUC Lua 5.2 and 5.3" was removed from the README, `docs/ffi-decision.md`, `oclj_features.h`, `security_test.c` and the harness.
2. **The serializer hash is `85097158`, not the predicted `8c9d50bc`.** A comment in `eris_lj.c`
   was corrected after the review. No repo file cites either value.
3. **`negative-control.sh` has 56 PASS lines, not 54.** The review found that `lj52_layout_ok`'s
   eris comparison had no permanent arm: a shim with that half deleted passed every existing arm.
   `layout-eris` (3c) is that arm. Both layout verdicts now also require the refusal message's
   three numbers to name the half that differs.
   - Not shown: 3c failing under a shim whose eris half is deleted. That would run a
     layout-mismatched serializer past the gate.
   - What IS shown: 3c's number check rejects 3b's reading (6376 / 6384 / 6376), and `expect`'s
     want-2-got-0 path is the one every other arm uses.
4. **G3 is an allowlist.** Every `-D LUAJIT_*` in the LuaJIT log except `LUAJIT_TARGET` and
   `LUAJIT_UNWIND_EXTERNAL` is refused, with or without a space after `-D`. The contract's
   denylist missed `LUAJIT_NO_UNWIND` and `LUAJIT_UNWIND_INTERNAL`, and `oclj_features.h` now
   refuses those two as well.
5. **Smaller review fixes.**
   - **Gates:**
     - A failed `eris_lj.c` compile no longer leaves the last build's object for the word check
       and the link (shown by sabotage in review). The link likewise removes the old library
       first.
     - The word check refuses a malformed observation.
     - Stage 1b refuses a non-numeric GG size and keeps the negative arm's compiler output.
   - **Messages and comments in the build:** the Linux preflight NOTE (stale since the pthread
     watchdog), the preflight message, and PREREQUISITES 4, which said that a stock clone is
     rejected.
   - **Tests:**
     - FF8 checks the `_PRELOAD` half only.
     - FF10 is attributed to the FFI flag only while its plain-dump control loads.
     - `run-mem.sh` and `run-vgc.sh` refuse a pre-gate shim object paired with an archive without
       FFI.
   - **Serializer:** `make test` passes `BIN` to its for-in step. The Makefile's message names
     the platform.
   - **`bench/oc/run-standalone.sh`** derives the per-platform LuaJIT path.
   - **Docs:**
     - The `%x` figures now give their condition.
     - The save-time loss is marked as read from source, not run.
     - The roadmap rows record their moved line cites.
     - Three defects found this round are recorded, not fixed: `%c` past 2^31, `%x` of inf,
       and `jit.util.tracek` on KINT64.
6. **The penalty A/B archive** must have this build's feature set. The contract's "built through
   the header channel" was too strong: a pristine-tree `make` with the three `-D` flags passes the
   gate.

## Not done

- **No JVM has loaded the Linux .so.**
- **Not tried in the game:** boot, save and restore on the new jar (the roadmap's in-game tests).
- **A full LuaJIT build with a refused flag** was not run. The `#error`s were shown by
  preprocessing a translation unit in review.
- **A refused restore shows the player only a computer that is OFF.** The reason is in the
  server log (`Machine.scala`, read). That is unchanged by this round.

| path | what |
|---|---|
| `failfirst/` | `head.md5` (HEAD's artifacts, kept outside the repo); `head/luajit_build.log`; `head-gates.txt` (G3, G2, G5, the integer-format gate on HEAD, the unpatched build and the two sabotaged builds, and the word); `head-security.log` and `.exit` (the new `security_test.c` against HEAD's objects); `noffi.lua` (the gate script); `harness/` (the new harness on HEAD's natives, and its chain log) |
| `logs/builds/` | the Windows build logs; `gradle-build.log`; `gradle-failfirst.txt`; `g3-allowlist-proof.txt`; `natives.md5`; `sources.md5` |
| `logs/native-win/` | every Windows native suite in place, `penalty-headlib` (HEAD's archive), the serializer `ser-test` and `ser-negctl`, and `negctl.log`; one `.log`, `.rc` and `.start` each |
| `logs/linux/` | the WSL build logs and LuaJIT logs of both variants, every Linux suite, and the serializer; `summary.txt`; `host.txt` (object and .so md5s) |
| `logs/suite/` | the seven harness arms on this build: `run.log`, `args.txt`, `env.txt` where set, `native.md5`, `exit.txt`, `started.txt` and `finished.txt` (UTC); `chain-r1-a.txt` |
| `design/` | `design.md` (the implementation contract); `review-findings.json` (the review and the skeptics' verdicts); `fmtx/` (the `%x` probes, differential and benchmark); `fprint/` (the cross-build fingerprint runs); `fix/` (the scripts that applied the review's fixes, exact-once anchors) |
| `scripts/` | `full.sh` (one harness run); `chain-ff.sh` (the fail-first arms); `chain-r1.sh` (the seven arms); `native-tests-r1.sh`; `build.sh`; `make-shim`; `wsl-r1.sh` (the Linux build and suites) |

The scripts hard-code local paths: the work tree under `C:/Users/astro/claude-tmp/oclj`, the repo,
OC-JNLua, ocelot-brain and the JDK. Windows logs are CRLF in the working tree;
`.gitattributes` normalizes them on commit, as for every earlier archive.
