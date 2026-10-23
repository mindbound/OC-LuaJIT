# 2026-10-23 -- T7's ladder runner in game on LuaJIT, Lua 5.3 and Lua 5.4

The record behind the 2026-10-23 note under [docs/in-game-tests.md](../../../docs/in-game-tests.md) T7 and the later
2026-10-23 notes on the roadmap's in-game validation and in-game benchmark rows. One game session, 2026-10-23, local
time (`log-excerpts.txt`): the game started at 11:07:36 (`fml-client-latest.log`:1), the world was joined at
11:11:13 (`latest.log`:63), and the game saved and exited at 11:14:34-36. On the same computer as T11's sessions,
it ran T7's runner, `bench/oc/ingame-ladder.lua`, on each CPU, LuaJIT first, with the runner's output redirected
into `/home/ladder-<arch>.txt`. The output files' mtimes give the order: LuaJIT 11:11:57, Lua 5.3 11:13:11, Lua 5.4
11:14:05 (`md5s.txt`). `>` truncates, so each file holds its CPU's last run.

- `ladder-luajit.txt`, `ladder-lua53.txt`, `ladder-lua54.txt`: the runner's output, byte for byte, copied from the
  save's `opencomputers/<address>/home/` after the game exited: the machine line, then per bench the CHECK, the
  min of 5 reps and every rep (to 1 ms).
- `log-excerpts.txt`: the log lines cited here, with their line numbers.
- `md5s.txt`: the jar, its DLL and kernel; the runner and the three bench files on the computer's disk against the
  repo's; the output files and their mtimes; OC's per-machine save files (sizes and mtimes); the log counts.
- `ladder-ratios.txt`: per bench and CPU the CHECK, the min and the median of the reps, the rep spread; the
  ratios between the CPUs; our CPU against T9's in-game reading and the pinned harness's last run of these
  benches; Lua 5.3 against that run's stock PUC 5.2 arm.
- `scripts/mkladder.py`: wrote every file here but this README, from the save, the logs, the jar, the repo's
  `bench/oc/` files and the 2026-10-05 harness logs.

The OC source cited below is 1.12.58-GTNH's; the game ran 1.12.64-GTNH, and that the cited code behaves the same
there is [I] (as in [`../2026-10-23-t11-game/`](../2026-10-23-t11-game/README.md)).

## What the session shows

- **The jar and the files** [M: `md5s.txt`]. `mods/` holds one OC-LuaJIT jar, `ocluajit-19a7806.jar`, md5
  `1e02e032`, the jar of T11's 2026-10-22 and 2026-10-23 sessions (DLL `9ac03aeb`, kernel `1d12c322`). The runner
  (`a20fdf67`) and `mandelbrot.lua`, `matmul.lua` and `binarytrees.lua` on the computer's disk are byte-identical
  to the repo's `bench/oc/` copies.
- **The pack** [M: `log-excerpts.txt`]. FML identified 244 mods, as in the morning's session
  (`fml-client-latest.log`:7984). The world's `ModTracker` lines name mods updated since the morning's session:
  NotEnoughItems, Baubles and ProjectRed (:35819-35830). OpenComputers is still `1.12.64-GTNH`.
- **The load** [M: `md5s.txt`, `log-excerpts.txt`, unless marked]. The session logged no `eris-lj` text and no
  `Unexpected error loading a state`; its one OpenComputers `ERROR` is the startup recipe the morning's session
  logged too (:20877). The morning's last save had found the computer stopped
  ([`../2026-10-23-t11-game/`](../2026-10-23-t11-game/README.md), "The state left for the next session") [I], so there was no state to restore and the LuaJIT arm began from a
  fresh boot [I]. The logs agree: OC's glyph-width cache was first used by the client's font loader, 8 s after
  the join (:46180), and OC's `computer_running` sound was first decoded 18 s after it (:46212), as on 2026-10-22
  with a stopped computer started by hand (8 s and 31 s), where the morning's restored, running computer gave 3 s
  on a computer thread and 6 s (that archive's README).
- **The switches** [M: `latest.log`:100-104]. OC's chat line for each architecture click: Lua 5.3 at 11:12:20,
  between the LuaJIT file's last write and the Lua 5.3 file's; Lua 5.4 at 11:13:22, after the Lua 5.3 file's; and
  Lua 5.2, LuaJ and LuaJIT at 11:14:28-29, after the Lua 5.4 file's. The line comes only from cycling a CPU held in
  hand, and taking the CPU out stops the machine (`CPULike.scala`:28-40, `Case.scala`:105-115 [S]), so the Lua 5.3
  and Lua 5.4 arms each began from a fresh boot [I], as in the morning's session.
- **The state left for the next session** [M: `md5s.txt`; I]. The computer's `_kernel` was last written at
  11:14:20, during the Lua 5.4 arm, and the 11:14:34 save wrote `_tmp` but not `_kernel`, so the computer was
  stopped at that save (the reasoning of the morning's README) [I], with its CPU set back to LuaJIT.
- **The machine** [M]. Each file's first line: `machine RAM total=16384 KB`, with 15877 KB free on LuaJIT, 15900 KB
  on Lua 5.3 and 16204 KB on Lua 5.4; `jit global=false`.
- **The results** [M: `ladder-ratios.txt`]. Every CHECK is the expected one (mandelbrot `37904620`, matmul
  `481.0000`, binarytrees `7038400`). Min of 5 reps, the runner's figure, seconds:

| bench | LuaJIT | Lua 5.3 | Lua 5.4 | Lua 5.3 / LuaJIT | Lua 5.4 / LuaJIT | Lua 5.4 / Lua 5.3 |
|---|---:|---:|---:|---:|---:|---:|
| mandelbrot | 0.0638 | 1.3958 | 1.0263 | 21.9x | 16.1x | 0.735 |
| matmul | 0.0893 | 1.6103 | 1.2916 | 18.0x | 14.5x | 0.802 |
| binarytrees | 0.2737 | 1.4403 | 1.4840 | 5.3x | 5.4x | 1.030 |

From the medians of the reps the ratios read 20.9x, 17.8x and 5.2x (Lua 5.3) and 15.6x, 14.3x and 5.3x (Lua 5.4).

## Reading it

- **The stock CPUs against ours.** Lua 5.3 reads 18-22x our CPU on mandelbrot and matmul and 5.3x on binarytrees
  [M]. binarytrees allocates by far the most: 7,038,400 nodes a run, its CHECK, against about 99,000 tables for
  matmul (32 row tables and a matrix table per rep, 3000 reps) and under 800 allocator calls for mandelbrot (T9)
  [S: `bench/oc/binarytrees.lua`, `matmul.lua`:136-163; in-game-tests.md T9]. That the gap narrows there because
  both VMs spend much of that bench allocating and collecting is [I], not measured. T11's bitwise loops, in the
  morning's session, read 8.8-18.8x [M: `../2026-10-23-t11-game/`].
- **Lua 5.4 against Lua 5.3**: 26% and 20% faster on mandelbrot and matmul, 3% slower on binarytrees [M].
- **Our CPU** reads within 1.5% of the pinned harness's last run of these benches, which ran on that day's
  natives (2026-10-05: 0.0647 / 0.0906 / 0.2706 s, `../2026-10-05-reserve/logs/runsF/full/fullF-additive-on.log`,
  DLL `45eb443b`; the game's `9ac03aeb` came ten native commits later) [M]. Against T9 in game (2026-10-03, the
  `0c656ac` jar, kernel `089dcbde`) it reads -2.9%, +3.6% and +8.6%. The harness shows where binarytrees' step
  came from: on stage B's natives it read 0.2497 s with the old kernel and 0.2671 s with the site-13 kernel, and
  0.2682 s on stage C's natives with that kernel (one run each, the additive JIT-on arm,
  `../2026-10-04-wall/logs/chainB`, `chainC0`, `chainC`) [M]. So the step most likely came with kernel site 13
  (85faa0e), which this jar's kernel `1d12c322` carries [I].
- **Rep spread.** In every row the slowest rep reads at most about 5% over the row's min (LuaJIT's mandelbrot:
  0.067 against 0.0638; the reps are printed to 1 ms) [M]; the runner's min is robust to one slow rep.
- **Lua 5.3 against the harness's stock arm.** The pinned harness's stock PUC 5.2 arm read 0.8149 / 1.2205 /
  1.6704 s on 2026-10-05 (`fullF-stock.log`), and the game's Lua 5.3 reads 1.71x / 1.32x / 0.86x of it [M]. Another
  Lua version (PUC 5.2), another machine (1 MB in the harness, 16 MB in game) and a pinned run against an
  unpinned one, so this is context, not a comparison [I].

## Not here

- A screenshot: none was needed; the output files hold everything the runner printed.
- Pinning: the game ran on whatever cores Windows gave it.
- The ladder on Lua 5.3 or Lua 5.4 in the harness, and sha256 (T7 leaves it out).
- The logs themselves; `log-excerpts.txt` keeps the cited lines.
