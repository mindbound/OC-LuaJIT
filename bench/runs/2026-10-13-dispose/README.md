# 2026-10-13 -- Value disposal

The evidence behind [../../results-dispose-2026-10-13.md](../../results-dispose-2026-10-13.md):
the Value-disposal row ("Value disposal (`__gc`)"), fixed by THE VALUE FINALIZER in
`native/lj52shim.c`, the identity count in the generated `LuaStateLuaJIT`, and a second
`COLLECT` in `LuaJITArchitecture.save`. Implemented in the working tree on aa12418,
uncommitted. All harness runs on ocelot-brain with JDK 8 (1.8.0_504) on Windows 11, with the
Windows DLLs, the watchdog kernel on ours and OC's own on stock, NOT core-pinned: functional
runs, three JVMs at a time, the last three one at a time. No harness run loaded the Linux .so.
The native tests ran on Windows (in place, and three of them against a layout mirror, see the
notes) and in WSL on Linux, also unpinned.

The builds:

- **HEAD, the fail-first:** HEAD aa12418's natives, additive `45eb443b`, dropin `8f9bc419`, Linux
  additive `45b25422` -- the same bytes as the 2026-10-05 reserve round's final build
  ([../2026-10-05-reserve/README.md](../2026-10-05-reserve/README.md)) -- and HEAD's
  `LuaStateLuaJIT.java` `82a7918d`, compiled by the harness in place of the tree's
  (`OCLJ_JAVA_SRC`). The harness is the new one (`logs/failfirst/`), as archived but for one
  message (see the notes).
- **This build:** additive DLL `6445f2e4` (sha256 `73941e09...`), dropin `60a8a522` (sha256
  `886406fc...`), Linux additive .so `0deb53ab` (sha256 `c4574720...`)
  (`logs/builds/natives.md5`, the sha256s in `logs/builds/build-*.log`); the Windows two built
  16:16-16:17 UTC (the build logs' first and last lines), and the harness ran them from a
  frozen copy (`new-6445f2e4/`). The .so was built in WSL and has been loaded by no JVM: its
  evidence is the Linux native gates, C hosts linked against its LuaJIT and shim objects, and
  its export counts (`logs/builds/exportgate-proof-so.txt`). The Windows shim object every
  Windows native test linked is `ace486b4`, the DROPIN variant's (the last Windows build; both
  variants compile into `obj-windows-x86_64/`, so the additive's object, inside DLL `6445f2e4`,
  was not kept); the Linux one, `9f9f009e`, is the additive's (the only Linux build).
- **The sources** of this build, md5 at archive time: `logs/builds/sources.md5` (the shim, the
  header, `build-native.sh`, the generator, `build.gradle.kts`, `LuaStateLuaJIT.java`,
  `LuaJITArchitecture.java`, the harness, the negative control, `vgc_test.c`, `run-vgc.sh`).
- **The jar:** `build/libs/ocluajit-aa12418-master+aa124186c8-dirty.jar`, md5 `c1569833`, a
  dirty-tree build, not installed in the game.

| path | what |
|---|---|
| `design/design.md` | the first design: the defect, facts F1-F11 (each verified in source), the mechanism, the tests, the non-goals |
| `design/review/findings.md` | the four-lens review of `design.md` (C and JNI: C1-C5; OC semantics and persistence: OC-1..OC-5; Java monitors: J1-J7; tests and gates: T1-T14), each finding with its scenario, the change asked for and, where it ran, a skeptic's check |
| `design/review/review-*/` | the reviewers' and the skeptic's probes, run on the pinned LuaJIT: `pushorder.lua` (a re-push counted before or after the push), `boundary.lua` and `boundary2.lua` (one save collect, then close: OC-1), `twocollect.lua` (two save collects, also mid-cycle), `floating.lua` (a drop mid incremental cycle), `preinstall.lua` (a `__gc` swapped after a userdata exists), `witness.lua` (the gc-1/gc-2 witness, T8) |
| `design/design-v2.md` | the implementation contract: the review adopted, per file set and owner. The code deviates from it in eight places, listed in the results note |
| `design/implement-and-crosscheck.json` | the four implementers' reports (shim and gates; the C test; the Java class and the architecture; the harness) and the two cross-checks' issues and verified items, among them the build gates proven able to fail and the missing check that became vd-9 |
| `logs/builds/` | `build-additive.log`, `build-dropin.log` (Windows), `build-linux-additive.log` (WSL); `gradle-build.log` (the jar); `natives.md5` (HEAD's and this build's natives, HEAD's `LuaStateLuaJIT.java`, the jar); `sources.md5`; `exportgate-proof.txt`, `build-native.sh`'s three export-count gates on HEAD's DLLs and this build's, each evaluated on its own (`scripts/exportgate-proof.sh`; its two `so` blocks, see the notes); `exportgate-proof-so.txt`, the oclj and `Java_*` export counts of HEAD's Linux .so `45b25422` (2 and 89, FAIL) and this build's `0deb53ab` (4 and 91, PASS), read in WSL with `nm -D`, plus the four names' matches in each (`scripts/so-exports.sh`) |
| `logs/failfirst/` | the new harness on HEAD's natives and class: `ff-head-additive` (79 / 13, exactly gc-0..3 and vd-1..9), `ff-head-dropin` (66 / 0), `ff-head-stock` (50 / 0) |
| `logs/suite/` | this build: `fix-additive-on-a` (79 / 0), `fix-additive-off-a` (77 / 0), `fix-additive-sieve-a` (73 / 0), `fix-dropin-a` (66 / 0), `fix-stock-a` (50 / 0), `fix-disposeoff-a` (`OCLJ_DISPOSE=off`, 79 / 0 as the negative control), `fix-bundleoff-b` (`OCLJ_PERSIST_BUNDLE=off`, 79 / 3: stk-2/3/4) |
| `logs/sabotage/` | `sab-onecollect-b` (`OcljArch.save` with one collect: 79 / 1, gc-3) and `sab-countafter-b` (`LuaStateLuaJIT` counting after the push: 79 / 1, vd-9) |
| `logs/incident/` | `fix-bundleoff-a`, `sab-onecollect-a`, `sab-countafter-a`: the three runs that stopped at +12 s with no native loaded (see the notes) |
| `logs/*/<run>/` | per run: `run.log` (`smoke-test.sh`'s output, the JVM's log included), `args.txt` (arm, natives, JIT, bench filter, `OCLJ_DISPOSE`, `OCLJ_PERSIST_BUNDLE`, the Java source), `env.txt` (the chain's env switch, where one was set; the one-collect sabotage's `OCLJ_ARCH_SRC` is here and in the chain logs, not in its `args.txt`; the fail-first runs have no `env.txt`, and their `OCLJ_JAVA_SRC` is in `args.txt` and `native.md5`), `native.md5` (the DLL and any substituted Java source; on stock only the Java source, so `ff-head-stock` has one and `fix-stock-a` none), `exit.txt`, `started.txt`, `finished.txt` (UTC) |
| `logs/chain-a.txt`, `logs/chain-b.txt` | the post-fix chains: a, three batches of three JVMs (its third batch is `logs/incident/`); b, those three again one at a time; each run's exit and CHECKS line |
| `logs/native/win/` | in place on Windows: `vgc.log` (47/0), `mem.log` (86/0), `wd.log` (35/0), `penalty.log` (6/0), `negctl.log` (the negative control, PASS; section 7 is Value disposal), `race-layout.log` and `security-layout.log` (the two runners stopping at setup), `summary.txt` (exit codes); `vgc-failfirst/`, `vgc_test` against HEAD aa12418's shim object, compiled from git with `build-native.sh` step 2's dropin line (`summary.txt`: object `79f19c63`, 0 `lj52_vgc_*` symbols; `vgc-head.log`: does not link, "TEST FAIL: test did not build"; `vgc-new.log`: this build's object, 47/0; `head-compile.err`, empty; `scripts/vgc-failfirst.sh`) |
| `logs/native/win-mirror/` | `run.sh`, `run-security.sh` and `run-race.sh` against the layout mirror: `shim.log` (57/0, PASS), `security.log` (37/0, PASS), `race.log` (2/0), `summary.txt`, `objects.md5` (the objects and DLLs the mirror was built from) |
| `logs/native/wsl/` | in WSL on Linux, C hosts linked against the Linux objects: `vgc.log` (47/0), `mem.log` (86/0), `wd.log` (35/0), `penalty.log` (6/0), `host.txt` (the md5s of `libluajit.a` and the shim object the gates link, and of the .so, which they do not load), `summary.txt` |
| `sabotage/` | `onecollect.diff` and `countafter.diff`, the two harness sabotages as diffs against the tree (made by `scripts/archive.sh`); `sabotage.py`, which wrote the two sabotaged sources |
| `scripts/` | `full.sh` (one harness run), `chain-fix.sh` (chain a), `chain-seq.sh` (chain b), `build.sh` (`build-native.sh` with this box's toolchain), `make-shim` (`make` over `mingw32-make`), `native-tests.sh` (the native suites and the negative control in place), `mirror-gates.sh` (the three layout-bound runners against a mirror), `wsl-gates-vgc.sh` (the Linux gates), `exportgate-proof.sh`, `so-exports.sh` (the Linux .so export counts, in WSL), `vgc-failfirst.sh` (`vgc_test` against HEAD's shim object, then this build's), `archive.sh` (this directory; the two scripts before it and their output were added after it ran) |

Notes.

- The scripts hard-code local paths: the work tree under `C:/Users/astro/claude-tmp/oclj`
  (runs, natives, sabotaged sources, `bin/`), the repo, OC-JNLua, ocelot-brain and the JDK.
  `exportgate-proof.txt` read HEAD's natives from a copy in the session's scratchpad, the same
  bytes as `natives.md5`'s `head-aa12418/` entries (`45eb443b`, `8f9bc419`).
- The runs were not core-pinned, and three JVMs shared the machine at a time: no time in these
  logs (WALL, save milliseconds, benchmark rows) is a measurement.
- The understand-phase notes (six investigators and a critic, cited by `design/design.md` as
  `scratchpad/dispose/understand/*.md`) are not archived.
- **The three incident runs** (`logs/incident/`) were chain a's third batch, three JVMs
  started in the same second. All three passed the first two boot milestones and stopped at
  +12 s on the harness's guard, "LuaStateFactory.isAvailable == false: no native loaded",
  before any gc-* or vd-* milestone and with no CHECKS line. Each JVM extracts OC's bundled
  natives into the shared working directory, the repo root (`Ocelot-0.24.2-5x-*.dll`), and two
  of the three logs read "Could not update native library
  'Ocelot-0.24.2-52-libjnlua52-windows-x86_64.dll'!": the likely cause is that extraction
  racing. Not proven: chain a's first two batches also started three JVMs in the same second
  (16:22:47Z, 16:24:42Z; the incident's at 16:26:39Z) and ran. Chain b reran the three one at
  a time, and all three ran (`logs/suite/fix-bundleoff-b/`, `logs/sabotage/`).
- **`run-race.sh`, `run-security.sh` and `run.sh` still name the pre-per-platform layout**
  (`build/native/luajit/src`, `obj/`). In place the first two stop at setup
  (`logs/native/win/summary.txt`: race exit 1, security exit 2; `run.sh` was not run in
  place); `scripts/mirror-gates.sh` built a mirror of that layout from the current Windows
  objects, the 2026-10-05 workaround, and ran all three against it.
- **The harness between the fail-first and the suite.** Exactly one source edit came after the
  fail-first runs and before chain a: the stock wording of gc-0's SKIP line in
  `test/native/OcljSmoke.scala` (the `if (nativeMode != "additive")` gc-0 block, now
  `:5338-5342`). It read "this arm leaks by construction" for every non-additive arm
  (`ff-head-stock`) and now reads "stock PUC disposes through the proxy table's own __gc" for
  stock (`fix-stock-a`). Message text only: no check, expectation or count changed, and the
  SKIP is not counted. Every other source, vd-9 included, was in its final form before the
  fail-first ran; `sources.md5` was taken at archive time.
- `exportgate-proof.txt`'s two `so` blocks are not `exportgate-proof.sh`'s output (it reads a
  PE export table), and the command that printed them is not archived (an inline loop of
  `grep -c -a`, one per name: match counts of each name in the file). The first pointed at a
  wrong path for HEAD's .so and printed no counts at all: its path lacks the
  `libdir-additive/` directory HEAD's DLL was read from, and `natives.md5` lists HEAD's .so
  under `head-aa12418/libdir-additive/`. This build's .so reads 2 for each of the four names.
  The .so proof is `exportgate-proof-so.txt` (`scripts/so-exports.sh`, run in WSL with
  `nm -D`, the reader `build-native.sh` uses on ELF): HEAD's .so `45b25422` reads oclj natives
  2 (want 4) and `Java_*` 89 (want 91), each FAIL, with 0 matches of
  `ocljInstallValueFinalizer` and `ocljValueGcCounters`; this build's `0deb53ab` reads 4 and
  91, PASS, with 2 matches each.
- `vgc_test` against HEAD's shim object (`logs/native/win/vgc-failfirst/`,
  `scripts/vgc-failfirst.sh`): HEAD aa12418's `lj52shim.c` and `.h` from git (md5 `905e1db7`,
  `1e1dba02`), compiled with `build-native.sh` step 2's dropin line, give object `79f19c63`,
  byte-identical to the 2026-10-05 reserve archive's dropin shim object
  ([../2026-10-05-reserve/README.md](../2026-10-05-reserve/README.md): "shim objects
  `1241325b` (additive) / `79f19c63` (dropin)"). It defines 0 `lj52_vgc_*` symbols, and
  `vgc_test` does not link against it ("undefined reference to `lj52_vgc_counters'", "TEST
  FAIL: test did not build", exit 1). Against this build's dropin object (`ace486b4`, the one
  every Windows native gate linked) the same script reads 47/0.
- **No JVM has loaded the Linux .so.** Every harness run's `run.log` reads "os=Windows 11", and
  every native a `native.md5` names is a Windows DLL. The Linux additive .so `0deb53ab` was
  built in WSL; the WSL gates link its LuaJIT and shim objects into C hosts (`vgc_test` with a
  fake JNIEnv), and `host.txt` only hashes the .so. The roadmap row "The Linux native has never
  been loaded by a JVM" stands.
