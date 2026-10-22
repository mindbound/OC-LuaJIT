# 2026-10-22 -- T11: the bitwise operators and their speed, on OC's Lua 5.3 CPU and on ours

The evidence behind [docs/in-game-tests.md](../../../docs/in-game-tests.md) T11 (its readings table, its
FIX-NUMCONV paragraph, its yield-gap figure and its `[M: the T11 review]` claims) and the 2026-10-22 status notes on
the roadmap's T10, in-game validation and in-game benchmark rows. T11 runs one file, `bench/oc/ingame-bitops.lua`,
unchanged on OpenComputers' Lua 5.3 CPU and on our LuaJIT CPU. Nothing here ran in Minecraft: these are the
standalone and harness runs made before the procedure was handed over. The in-game run's results files go in a
directory of their own (`bench/runs/<date>-t11-game/`).

- **How it was made.** One agent wrote the draft script and section on 2026-10-22 (`scripts/ingame-bitops-draft.lua`,
  md5 `7471d6a6`; `design/t10-section-draft.md`, still named T10 then) and ran it standalone (`run-1/standalone/`),
  under a stub `computer` (`stub/draft-a`, `stub/draft-b`) and in the harness (`run-1/ig-*`). Three read-only
  reviewers checked it (`design/review.txt`, their snippets in `design/review-snippets/`): every doc claim against
  its source, the script's correctness on both CPUs, and whether it measures what it says. They found 35 issues,
  and the main session applied them to the reviewed script (md5 `c7b444af`, the one runs 3, `fail-first/` and
  `stub/reviewed` read) and the section. Two read-only verifiers then checked the landed text, the roadmap notes,
  this directory and the change set (`design/verify.txt`, two of their snippets in `design/verify-snippets/`); their
  21 findings were applied the same day. One was a wrong comment: the header said that standalone the results file
  goes next to the script, which a review finding had proposed from a probe that called `debug.getinfo` directly;
  through the script's `pcall(debug.getinfo, 1, "S")` it describes `pcall`, so standalone the file goes to the
  current directory. The committed script, `bench/oc/ingame-bitops.lua` (md5 `661c51bd`), differs from `c7b444af`
  in comments only (`design/script-comment-diff.txt`). Not taken: an edit of in-game-tests.md's preamble (it would
  move lines the roadmap cites; the section says itself that T11 is not one fix's test), the optional `parts = nil`
  in the setup and the old `n >= 1e8` calibration backstop (replaced by the clock check below); `msgof`'s prefix
  stripping is unchanged.
- **The name.** The draft was T10, but the roadmap's T10 row already names the next per-fix in-game session (its
  items: the shipped kernel's boot, memory recovery on a 256 KB stick, a save near the cap, handle disposal), so the
  test became T11. The section says the two can run in one game session on the same jar.
- **What the review changed in the script.** Part 2 now catches a bench that raises and prints an `ERR` row
  instead of stopping without a verdict; if `os.clock()` does not advance, calibration stops at its first run of at
  least 4e6 operations and prints `NOT TIMED`; a `SKIP` counts against the verdict, except on a Lua 5.4 CPU, where
  Part 1 skips its string-coercion check by design (the draft's PUC 5.4.8 run: 37 PASS, 1 SKIP, PASS); the
  99-names case says why no results file was written; the header says where the results file goes (always `/home`
  in game, where OC's sandboxed `debug.getinfo` describes `machine.lua`) and that Part 1's one-shot checks run in
  our interpreter. The benches, the checks and their references are the draft's.

## Runs

| dir | script | natives | what |
|---|---|---|---|
| `run-1/` | draft `7471d6a6` | the select release: DLL `b5ff2d18`, `luajit.exe` `17f96322` | harness, both arms (`ig-luajit`, `ig-lua53`); `standalone/`: the draft agent's runs on `luajit.exe` (JIT on, `-joff`, twice in one directory to check the `-2` name), PUC 5.3.6, 5.4.8 and 5.2.4 (neither the script's md5 nor the PUC interpreters' were recorded) |
| `run-2/` | draft `7471d6a6` | FIX-NUMCONV's release (19a7806): DLL `9ac03aeb`, `luajit.exe` `f4038cd6` | standalone (JIT on, `-joff`, PUC 5.3.6) and both harness arms (`scripts/chain2.sh`), then `gradle verifyModAssets` and `build` on the clean tree: `ocluajit-19a7806.jar`, 681 124 bytes, md5 `1e02e032`, carrying DLL `9ac03aeb` and .so `f91700bd` (`jar.md5`, `jar-list.txt`) |
| `run-3/` | reviewed `c7b444af` | as run 2 | the readings in in-game-tests.md (`scripts/chain3.sh`): standalone (JIT on, `-joff`, PUC 5.3.6, PUC 5.2.4) and both harness arms; `jar-kernel.md5`: the jar's kernel is `1d12c322` |
| `fail-first/` | reviewed `c7b444af` | `luajit.exe` `f4038cd6`, PUC 5.3.6 | `scripts/ff.lua` wraps the script from outside: `none` (control), `err` (bench 2 raises), `bad` (bench 4 returns its value plus 1), `clock` (`os.clock` returns 0), `skip` (no `string.pack`), on both CPUs (`scripts/ff.sh`) |
| `stub/` | `draft-b`: draft `7471d6a6` [I: the draft's last edit, 00:57:50, precedes it]; `draft-a`: an earlier draft (it ran at 00:56-00:57, before that edit; not recorded); `reviewed`: `c7b444af` | `luajit.exe` (`f4038cd6` for `reviewed`), PUC 5.3.6 | `scripts/stubrun.lua` (the draft agent's instrument) runs the script standalone with a stub `computer` naming the architecture and an `os.sleep` that records the longest stretch between yields (`scripts/stub.sh` for `reviewed`) |

Each harness directory holds the census's `run.log` (the screen, which scrolls and drops lines), the results file
the program wrote (`home/ingame-bitops-*.txt`, the one to read), `home/.shrc`, `inputs.md5` (the script and the copy
the run read; on the LuaJIT arms also our DLL and `luajit.exe`; the Lua 5.3 arm's native, ocelot-brain's
`Ocelot-0.24.2-53-libjnlua53-windows-x86_64.dll`, is a md5 in `DIGESTS.txt`) and the harness's `work/javac.log`;
run 3 also keeps `work/ocljit.conf`. Every text file was copied with its line ends normalized to LF (Windows'
`print` and the harness's config write CRLF), so the md5s taken before the copy, in `DIGESTS.txt` and the runs'
`inputs.md5`, are of the CRLF originals: run 3's `work/ocljit.conf` hashes to `926ac7e1` (LuaJIT) and `151903fc`
(Lua 5.3) here, and to `66b63165` and `05b18412` as the harness wrote them. Runs 1 and 2's configs, kept as md5s,
differ from run 3's only in the LuaJIT arm's `forceNativeLibPathFirst` path. `design/verify.txt` names the strings
the verifiers scanned for; they are replaced by placeholders here, and `DIGESTS.txt` holds its md5 before and after.

## Results

**Run 3, the reviewed script on FIX-NUMCONV's natives** (2026-10-22 03:52-03:54Z, unpinned): every arm reads
`Part 1: 38 PASS, 0 FAIL, 5 deviation as documented, 0 SKIP`, `Part 2: 5 benches, 0 BAD, ERR or NOT TIMED` and
`verdict: PASS`; the 38 `PASS` lines of the two harness results files are identical; PUC 5.2.4 prints
`needs Lua 5.3 or LuaJIT` and `verdict: not run`. Medians / mins of 5 reps, ns per operation (`-joff`: 3 reps,
median):

| bench (per) | luajit.exe | luajit.exe `-joff` | PUC 5.3.6 | harness, LuaJIT | harness, Lua 5.3 |
|---|---:|---:|---:|---:|---:|
| crc32 table (byte) | 3.76 / 3.74 | 22.80 | 22.82 / 22.82 | 3.44 / 3.42 | 37.60 / 32.73 |
| xorshift32 (step) | 2.30 / 1.99 | 44.58 | 16.33 / 13.59 | 2.37 / 2.36 | 30.88 / 30.74 |
| pack+unpack (word) | 5.39 / 5.37 | 66.50 | 69.16 / 68.93 | 5.42 / 5.39 | 90.25 / 89.94 |
| x \| 0 (op) | 0.56 / 0.56 | 6.16 | 8.62 / 8.59 | 0.56 / 0.56 | 13.27 / 13.24 |
| select(i,...) (call) | 1.61 / 1.59 | 12.58 | 24.58 / 24.50 | 1.93 / 1.91 | 42.74 / 42.67 |

By medians, in the harness Lua 5.3 reads 10.9-23.7x LuaJIT, and 1.30-1.89x standalone PUC 5.3.6
(`scripts/table.py`).

**FIX-NUMCONV in `x | 0`.** The same draft script on the two releases' DLLs: the harness's `x | 0` read 0.75 ns
on `b5ff2d18` (run 1) and 0.57 on `9ac03aeb` (run 2); the other four rows moved by 6% or less (`select`, 1.93 to
1.82, the most). Standalone, `luajit.exe` read 0.75 (`17f96322`, run 1) and 0.56 (`f4038cd6`, run 2).

**The fail-first** (`fail-first/summary.txt`): the control passes on both CPUs; `err` prints
`ERR ... sabotage: bench raised` on the xorshift32 row, `bad` prints `BAD 38401` on the `x | 0` row, `clock` prints
`NOT TIMED: os.clock() did not advance` on all five rows, and `skip` prints one `SKIP` line in Part 1; each of the
four reads `verdict: FAIL` on both CPUs.

**The yield gap** (`stub/*/*/stdout.txt`, the `STUB:` lines): the longest stretch without a yield was 0.361 s on
`luajit.exe` and 0.379 s on PUC 5.3.6 with the reviewed script (`stub/reviewed/summary.txt`), 0.346-0.380 s on the
draft (`draft-b`) and 0.301-0.365 s on the earlier draft (`draft-a`). The arms whose stub names the interpreter's
own architecture read `verdict: PASS`; the crossed arms (`c-lj-stubLua53`, `d-puc-stubLuaJIT`,
`g-lua52-stubLuaJIT`: the draft agent's check that a wrong architecture is caught) read `verdict: FAIL`, as they
must, and Lua 5.2 named as itself reads `verdict: not run`.

## Not here

- Binaries: the harness's DLL copies, the jar and the interpreters are md5s in `DIGESTS.txt` and the runs'
  `inputs.md5`, except run 1's standalone PUC 5.3.6, 5.4.8 and 5.2.4, which were not recorded. The OpenOS trees the
  harness booted are ocelot-brain's bundled OpenOS, copied per run and not kept; the copy of the script each harness
  run read is a md5 in `DIGESTS.txt`.
- Three earlier attempts at this directory (one stopped by its own scan, one with six copies of the 78 KB harness
  config, one before the verification's additions) were moved aside to scratch, not deleted.
