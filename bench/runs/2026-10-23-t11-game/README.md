# 2026-10-23 -- T11 in game on all three CPUs: LuaJIT, Lua 5.3 and Lua 5.4

The record behind [docs/in-game-tests.md](../../../docs/in-game-tests.md) T11's 2026-10-23 Result and the
2026-10-23 notes on the roadmap's in-game validation, in-game benchmark and cross-build blob compatibility rows. One
game session, 2026-10-23, local time (`log-excerpts.txt`): the game started at 09:31:37 (`fml-client-latest.log`:1),
the world was joined at 09:35:28 (`latest.log`:63), saved at 09:38:17 and saved again on exit at 09:40:30-31. It ran
T11 once on each CPU of the same computer, in this order by the results files' mtimes: LuaJIT 09:36:24, Lua 5.3
09:37:12, Lua 5.4 09:37:44 (`md5s.txt`). This is the session the 2026-10-22 record asked for: both of T11's arms,
LuaJIT then Lua 5.3, in one game session on the same jar ([`../2026-10-22-t11-game/`](../2026-10-22-t11-game/README.md),
which holds that day's LuaJIT arm alone). Lua 5.4 is a third arm, beyond T11's procedure.

- `ingame-bitops-luajit-2.txt`, `ingame-bitops-lua53.txt`, `ingame-bitops-lua54.txt`: the results files, byte for
  byte, copied from the save's `opencomputers/<address>/home/` after the game exited. `-2` because the computer's
  disk still holds 2026-10-22's `ingame-bitops-luajit.txt`, which the script never overwrites.
- `log-excerpts.txt`: the log lines cited here, with their line numbers, from this session's logs and the two
  2026-10-22 sessions' (rotated names as of 2026-10-23, as its header says).
- `md5s.txt`: the jar, its natives and kernel; OC's Lua 5.3 and 5.4 natives, checked against the harness's
  `DIGESTS.txt`, and OC's kernel against ocelot-brain's, with the lines they differ in; the script the runs read;
  the results files and their mtimes; OC's per-machine save files (sizes and mtimes); FML's mod count and its mod
  list against 2026-10-22's; and the log counts.
- `probe-lua54.txt`: the check T11 skips on a Lua 5.4 CPU, `'0x10' | 0`, run standalone on the vendored Lua
  5.4.8 and 5.3.6 interpreters, with the md5s of each front end and the VM DLL it loads.
- `ratios.txt` (made by `scripts/ratios.py`): each row's three arms with their rep spreads, the ratios between
  them, the LuaJIT arm against 2026-10-22's game run and against run 3 of
  [`../2026-10-22-t11/`](../2026-10-22-t11/README.md) (standalone `luajit.exe`, its `-joff`, the harness's LuaJIT
  arm), the Lua 5.3 arm against run 3's harness Lua 5.3 arm and standalone PUC 5.3.6, each from the printed
  medians and from the medians of the reps, and each arm's crc32 / pack+unpack ratio.
- `scripts/mkgame.py`: wrote every file here but this README, from the save, the logs, the jars, the repo's
  `bench/oc/ingame-bitops.lua`, the vendored interpreters, ocelot-brain's kernel,
  [`../2026-10-22-t11/`](../2026-10-22-t11/README.md)'s `DIGESTS.txt` and run 3's results files, 2026-10-22's
  game results file, and `scripts/ratios.py` beside it. Its optional second argument is the directory holding the copies
  of the three results files the user sent with the request for this record; `md5s.txt`'s line comparing them
  with the save's needs it, and a run without it leaves that line out.

The OC source cited below is 1.12.58-GTNH's, the one in hand; the game ran 1.12.64-GTNH, and that the cited code
behaves the same there is [I] (on 2026-10-22, 1.12.64's trace through `Machine.load` matched 1.12.58's source,
`../2026-10-22-t11-game/`).

## What the session shows

- **The jar and the pack** [M: `md5s.txt`, `log-excerpts.txt`]. `mods/` holds one OC-LuaJIT jar,
  `ocluajit-19a7806.jar`, md5 `1e02e032`, the same file as `build/libs/ocluajit-19a7806.jar` and as on 2026-10-22
  (DLL `9ac03aeb`, .so `f91700bd`, kernel `1d12c322`). The log has the mod at version 19a7806
  (`fml-client-latest.log`:8978) and the architecture registered (:21684). FML identified 244 mods, as on
  2026-10-22 (:7976; `fml-client-3.log`:7984). Its mod list, API list and state table (582 lines each day) differ
  from that day's T11 session in one mod, Hodgepodge 2.7.218 to 2.7.219 (:8810; the world's one `ModTracker`
  line, :35819), and in the jar named for three APIs that several mods embed (CoFHAPI, CoFHAPI|energy,
  Thaumcraft|API). All six jars those lines name are in both days' lists, so those three lines record which
  embedding jar FML picked, not a mod added or removed; with Thaumcraft|API's jar, the version FML registered
  for it moved too, from 4.2.2.0 to 4.2.0.0.
- **OC's natives and kernel** [M: `md5s.txt`]. The Lua 5.3 native in `OpenComputers-1.12.64-GTNH.jar` is
  `e06224de` (`Lua+Eris 5.3.6`), the same file as the one run 3's harness Lua 5.3 arm ran
  (`../2026-10-22-t11/DIGESTS.txt`:30), and the game loaded the jar's copy (`fml-client-latest.log`:16306). Its
  Lua 5.4 native is `9e2dc8b6` (`Lua+Eris 5.4.4`), the same file as the one in that run's directory
  (`DIGESTS.txt`:31); the harness had no Lua 5.4 arm. OC's kernel in the jar (`becc713a`) differs from
  ocelot-brain's (`3694690a`), the harness's stock kernel, in one line only once CRLF is read as LF: the sandbox's
  `realTime = computer.realTime,`. The count hook and everything else in the two kernels are the same text.
- **The script** [M: `md5s.txt`]. The copy on the computer's disk is `661c51bd`, byte-identical to the repo's
  `bench/oc/ingame-bitops.lua`.
- **The machine** [M]. Each results file's second line: `RAM 16384 KB`, with 15983 KB free on LuaJIT, 15891 KB
  on Lua 5.3 and 16096 KB on Lua 5.4; `_VERSION` `Lua 5.2`, `Lua 5.3` and `Lua 5.4`; `jit global=false`;
  `reps=5`. Each file's first line names the CPU that ran it, from `computer.getArchitecture()`
  (`ingame-bitops.lua`:74-78 [S]).
- **The load: a state saved under this jar, restored** [M: `log-excerpts.txt`, unless marked]. The world this
  session loaded was last saved on 2026-10-22 at 13:42:48-49, under this same jar (`2026-10-22-2.log.gz`:74,
  :102). The computer was running when the user reached it [M: the user's report]. OC leaves a computer whose
  state fails to load stopped (`Machine.scala`:808-813 [S]), as it did on 2026-10-22, so our native restored the
  state its own build had saved [I]. The session logged no `eris-lj` text and no `Unexpected error loading a
  state` [M: `md5s.txt`], and the computer came back running, so none of Before every test, step 6's three failure
  signs appeared. Its one OpenComputers `ERROR` is a recipe that failed at startup (`ritegUpgrade`, :20877),
  logged by the 2026-10-22 session too. The logs agree with the
  report [I]. OC's glyph-width cache, which initializes on first use (`FontUtils.scala`:224-230 [S]), was first
  used on a computer thread 3 s after the join (:46090). Hodgepodge first decoded OC's `computer_running` sound,
  which the client starts for a computer whose tile says it is running (`Computer.scala`:179-186 [S]), 6 s after
  the join (:46125). On 2026-10-22, with the state refused and the computer stopped until started by hand, the
  first came from the client's font loader 8 s after the join, and the second 31 s after it
  (`fml-client-3.log`:46214, :46252). The restored machine had booted on 2026-10-22 on this jar's kernel
  `1d12c322` ([`../2026-10-22-t11-game/`](../2026-10-22-t11-game/README.md)) [I].
- **The arms, and the switches between them.** The LuaJIT arm ran first, on the restored computer, with no power
  cycle before it [M: the user's report]. That departs from T11's Setup, step 4, and Running it, step 2: the arm
  began from a restored state, not a fresh boot. It kept Before every test, step 3's purpose, the jar's kernel in
  effect: the restored machine was the one that booted fresh on 2026-10-22 on this jar's kernel `1d12c322` [I].
  Our CPU's rows read within 2.4% of that fresh-boot run (Reading it). To switch, the user turned the
  computer off and cycled the CPU's architecture by right-clicks until it named the next one [M: the user's
  report], so the Lua 5.3 and Lua 5.4 arms each began from a fresh boot [I] and booted OpenOS [I: each results file
  exists]. `latest.log` has OC's chat line for each click: Lua 5.3 at 09:36:40, between the LuaJIT file's last
  write (09:36:24) and the Lua 5.3 file's, and Lua 5.4 at 09:37:22, after the Lua 5.3 file's (09:37:12) (:74-75)
  [M]. OC sends that line only for a sneaking right-click with the CPU in hand, T11's Running it, step 1, the
  first way (`CPULike.scala`:28-40 [S]), and taking the CPU out of the case stops the machine (`Case.scala`:105-115
  [S]). After the Lua 5.4 run, three more clicks set the CPU back to LuaJIT (09:37:51-53, :76-78) [M].
- **The state left for the next session.** OC's `Machine.save`, at every save it does not skip (it skips one
  while the machine is executing or when saving for clients, `Machine.scala`:826-830), writes the machine's
  `_tmp`, and only for a machine that is not stopped calls the architecture's save, which writes `_kernel`
  (:853-856; `NativeLuaArchitecture.scala`:407, and ours, `LuaJITArchitecture.java`:600-605) [S]. The computer's
  `_kernel` was last written at 09:37:44.10, during the Lua 5.4 run's last bench [M: `md5s.txt`'s listing of
  `opencomputers/state/`], so an autosave, which the log does not mark, persisted the running Lua 5.4 machine
  [I]. It left no mark in the reps: the last three of that bench's read 0.300 s [M], and `os.clock()` counts only
  the machine's own run time (T11's timer paragraph) [S]. The 09:38:17 save rewrote `_tmp` and not
  `_kernel`, so the computer was stopped then [I], and the CPU was set to LuaJIT (above). The next session's load
  should therefore restore no machine state [I].
- **Part 1** [M].
  - LuaJIT: `38 PASS, 0 FAIL, 5 deviation as documented, 0 SKIP`. Its Part 1 lines are identical to
    2026-10-22's game run and to run 3's harness LuaJIT arm. The hot loop raised at `i = 1000`, the iteration the
    interpreter raises at.
  - Lua 5.3: `38 PASS, 0 FAIL, 5 deviation as documented, 0 SKIP`. Its Part 1 lines are identical to run 3's
    harness Lua 5.3 arm, and its `PASS` lines to the LuaJIT arm's. The five `DEV` lines give 5.3.6's values, as
    T11's Expected table says, and the hot loop ran to `i = 2000`.
  - Lua 5.4: `37 PASS, 0 FAIL, 5 deviation as documented, 1 SKIP`. The `SKIP` is `'0x10' | 0`, by the script's
    design. On a CPU whose name contains `5.4` it skips that check (`ingame-bitops.lua`:413-415), and its verdict
    accepts any `SKIP` there (:533) [S]; this run had the one. Lua 5.4 converts bitwise operands without string
    coercion, and its string library gives strings arithmetic metamethods only (5.4.8's `lvm.c`:136-139,
    `ltm.c`:150-157, `lstrlib.c`:330-339 [S]). Standalone, `bench/vendor/lua-5.4.8/src/lua.exe` raises `attempt to
    perform bitwise operation on a string value` there, where 5.3.6 returns 16 [M: `probe-lua54.txt`]. The game's 5.4 is
    `Lua+Eris 5.4.4`, and the run does not test it there, since the check is skipped. Its other 37 `PASS` lines
    and its `DEV` lines are identical to the Lua 5.3 arm's, including the header `5.3 gives the 64-bit integer`
    and `5.3.6's value`, the script's wording for any CPU but ours.
- **Part 2** [M]. All fifteen rows `ok`; each file's `Part 2: 5 benches, 0 BAD, ERR or NOT TIMED` and
  `verdict: PASS`. Medians / mins, ns per operation; the ratios are of the printed medians (`ratios.txt` gives
  them from the reps too, within 0.8%):

| bench (per) | LuaJIT | Lua 5.3 | Lua 5.4 | Lua 5.3 / LuaJIT | Lua 5.4 / LuaJIT | harness: Lua 5.3 / LuaJIT |
|---|---:|---:|---:|---:|---:|---:|
| crc32 table (byte) | 3.76 / 3.74 | 32.90 / 32.87 | 30.59 / 30.42 | 8.8x | 8.1x | 10.9x |
| xorshift32 (step) | 2.00 / 1.99 | 20.76 / 20.64 | 17.21 / 17.19 | 10.4x | 8.6x | 13.0x |
| pack+unpack (word) | 4.94 / 4.88 | 68.86 / 67.58 | 56.93 / 56.35 | 13.9x | 11.5x | 16.7x |
| x \| 0 (op) | 0.61 / 0.61 | 11.45 / 11.43 | 9.54 / 9.48 | 18.8x | 15.6x | 23.7x |
| select(i,...) (call) | 2.36 / 2.35 | 42.53 / 42.09 | 43.92 / 43.83 | 18.0x | 18.6x | 22.1x |

And each arm against the earlier readings. The percentages are from the medians of the reps, as in
`../2026-10-22-t11-game/`; the `-joff` factor is from the printed medians:

| bench | LuaJIT vs 2026-10-22's game run | LuaJIT vs harness | LuaJIT vs standalone | `-joff` / LuaJIT | Lua 5.3 vs harness Lua 5.3 | Lua 5.3 vs PUC 5.3.6 | Lua 5.4 vs Lua 5.3 |
|---|---:|---:|---:|---:|---:|---:|---:|
| crc32 table | -1.5% | +9.2% | +0.2% | 6.1x | -12.6% | +44.0% | -7.0% |
| xorshift32 | -2.3% | -15.9% | -13.2% | 22.3x | -32.8% | +27.3% | -17.1% |
| pack+unpack | +0.0% | -8.9% | -8.3% | 13.5x | -23.5% | -0.4% | -17.4% |
| x \| 0 | -0.2% | +9.3% | +9.9% | 10.1x | -13.5% | +33.1% | -16.9% |
| select(i,...) | -0.1% | +22.4% | +46.0% | 5.3x | -0.5% | +72.9% | +3.2% |

## Reading it

- **The ratio T11 exists for**, Lua 5.3 / LuaJIT from one game session, reads 8.8x to 18.8x [M]. In the harness
  it read 10.9x to 23.7x. The game's ratio is 0.79 to 0.84 of the harness's on every row (from the reps) [M], and
  the two CPUs moved together from row to row: against the harness, both gained most on xorshift32 and least on
  `select` (the second table) [M]. Split by arm, the change is mostly OC's Lua 5.3's on xorshift32, pack+unpack
  and x | 0, where it reads 13.5-33% faster in game, and all ours on `select` (Lua 5.3 -0.5%, our CPU +22.4%).
  A uniform shift of about a fifth between the two CPUs, on top of a per-row factor both share, fits the same
  numbers; the two readings are not separated [I]. On crc32 the harness's own Lua 5.3 median is in doubt besides:
  it came from one rep of 0.304 s and then four of 0.348-0.353 s, and its min, 32.73, is at the game's median, 32.90
  (run 3's `ig-lua53/home/`). The two Lua 5.3s are the same native under the same stock kernel but for one sandbox
  line (above). What differs between the runs, not separated [I], includes the machine (1 MB in the harness
  against 16 MB in game, and the harness's copy of ocelot-brain's OpenOS, which started the file from
  `/home/.shrc`), Minecraft's JVM and OC 1.12.64's Java side against the harness's JVM and ocelot-brain's, the
  core each thread ran on, and the box's load. In game, OC's Lua 5.3 reads up to 73% over standalone PUC 5.3.6;
  the stock kernel's count hook is one candidate (T11's Reading Part 2) [I].
- **Our CPU, a day apart.** Every row is within 2.3% of 2026-10-22's game run from the reps (2.4% on the printed
  medians) [M], across a game restart, the Hodgepodge update and a restored machine against a fresh boot [I:
  restored, above]. Every row is 5.3x to 22.3x faster than the `-joff` column, so by T11's rule all five ran
  compiled [I: no `-jdump` in game]. The crc32 / pack+unpack ratio reads 0.76 (0.77 on 2026-10-22, 0.70
  standalone, 0.63 in the harness) [M], consistent with the table-index fold in effect [I, as on 2026-10-22].
  `select` again reads +22% over the harness and +46% over standalone. It repeated in a second session, so it is
  not one busy session [I]. By T11's Reading Part 2 it is a finding to follow up standalone, not a FAIL; it has
  not been followed up.
- **Rep spread.** Our CPU's five reps lie within 0.3-1.7% of each other on every row. Lua 5.3's and Lua 5.4's lie
  within 1.2-8.6%: in nine of their ten rows one or two reps read 5-9% above the fastest [M]. The median of five
  sets aside up to two slow reps, so these do not move the figures recorded [M: the reps are in each file]. Why
  the stock CPUs have them, a collection in their VM or the server's tick, is not separated [I].
- **Lua 5.4**, beyond T11's procedure, reads 8.1x to 18.6x ours: 7-17% faster than Lua 5.3 on four rows and 3%
  slower on `select` [M]. There is no harness column for it. The one standalone reading, the T11 draft's on PUC
  5.4.8 (`../2026-10-22-t11/run-1/standalone/lua548/`: a draft script, 3 reps, its inputs' md5s not recorded), is
  not like for like with this run.

## Not here

- A screenshot: none was taken (the instance's `screenshots/` has none since 2026-10-06). The results files hold
  everything the screen showed but its last line, the file's path.
- Pinning: the game ran on whatever cores Windows gave it, as 2026-10-22's game and harness runs did.
- A harness Lua 5.4 run, and a standalone Lua 5.4 run of the committed script.
- The logs themselves (6.6 MB and 30 KB for this session); `log-excerpts.txt` keeps the cited lines.
