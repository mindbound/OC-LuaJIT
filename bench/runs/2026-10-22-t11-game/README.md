# 2026-10-22 -- T11 in game: the LuaJIT arm

The record behind [docs/in-game-tests.md](../../../docs/in-game-tests.md) T11's Result and the 2026-10-22 in-game
notes on the roadmap's T10, in-game validation, in-game benchmark and cross-build blob compatibility rows. Two game
sessions on 2026-10-22, local time (`log-excerpts.txt`):

- **13:17-13:32, on the previous jar**, `ocluajit-a4994e6.jar` (`fml-client-3.log`:8988). It loaded the world
  (joined 13:21:33), saved it at 13:22:26, 13:22:28 and 13:32:46-47, and exited at 13:32:48 (`2026-10-22-1.log.gz`,
  the session's `latest.log`). That last save wrote the computer state the next session refused. It logged no
  `eris-lj` text (`md5s.txt`).
- **13:35-13:42, T11's session, on `ocluajit-19a7806.jar`.** The game started at 13:35:56
  (`fml-client-latest.log`:1), the world was joined at 13:39:30 (`latest.log`:63), and the game saved and exited at
  13:42:48-13:42:50. It ran T11 once, on the LuaJIT CPU; the results file's mtime is 13:40:29, the run's last
  flush.

The Lua 5.3 arm was not run: the computer's `home/` holds no results file but `ingame-bitops-luajit.txt`
(`md5s.txt`), so there is no in-game Lua 5.3 / LuaJIT ratio yet. The pre-game runs (standalone and harness) are in
[`../2026-10-22-t11/`](../2026-10-22-t11/README.md).

- `ingame-bitops-luajit.txt`: the results file, byte for byte (md5 `93b7c961`), copied from the save's
  `opencomputers/<address>/home/` after the game exited.
- `log-excerpts.txt`: the log lines cited here, with their line numbers, from both sessions' logs.
- `md5s.txt`: the jar, its natives and kernel, the script the run read, and the log counts.
- `ratios.txt` (made by `scripts/ratios.py`): each row against run 3 of `../2026-10-22-t11/` (standalone
  `luajit.exe`, its `-joff`, the harness's LuaJIT arm) from the printed medians and from the medians of the reps,
  each row's rep spread, and the crc32 / pack+unpack ratio.
- `scripts/mkgame.py`: built this directory from the save, both sessions' logs, the jar and `scripts/ratios.py`
  beside it.

## What the session shows

- **The jar** [M: `md5s.txt`]. `mods/` holds one OC-LuaJIT jar, `ocluajit-19a7806.jar`, 681 124 bytes, md5
  `1e02e032`, the same file as `build/libs/ocluajit-19a7806.jar`; it carries DLL `9ac03aeb`, .so `f91700bd` and kernel
  `1d12c322`, the identity T11's setup names. The log has the architecture registered once at startup
  (`fml-client-latest.log`:21684) and the mod at version 19a7806 (:35819). OpenComputers in the instance is
  `OpenComputers-1.12.64-GTNH.jar`; the OC source the docs cite is 1.12.58-GTNH.
- **The script** [M: `md5s.txt`]. The copy on the computer's disk is `661c51bd`, byte-identical to the repo's
  `bench/oc/ingame-bitops.lua` at 928a119. Run 3 of `../2026-10-22-t11/` read `c7b444af`, which differs from it in
  comments only (that directory's `design/script-comment-diff.txt`).
- **The machine.** The results file's second line: `RAM 16384 KB free 16012 KB`, `_VERSION=Lua 5.2`,
  `jit global=false`, `reps=5` [M]. The pack's largest stick is 8192 KB (`config/OpenComputers.cfg` `ramSizes`), and
  the computer's case holds two identical memory items (slots 3 and 4, item damage 39) [M: the `oc:case` tile
  entity in the save as written at exit], so two of them [I].
- **The state refused, and the boot** (the T10 row's item (1)). The world had been saved under a4994e6's jar
  (above, and `fml-client-latest.log`:35819). When the computer's chunk loaded, our native refused its saved state at
  the blob's header: `eris-lj: build fingerprint mismatch: serializer hash differs (blob '8c5a1168', this build
  '412be694'); the blob is from a different natives build` (:46039-46044, :46085-46090) [M]. `8c5a1168` is the
  serializer hash a4994e6's natives stamp and `412be694` round 3's, which 19a7806 carries (the roadmap's cross-build
  blob compatibility row, its 2026-10-10 and 2026-10-17 notes) [S]. The message names the first field that differs
  (`serializer/eris_lj.c`, `fp_mismatch`) [S]. The path is `LuaJITArchitecture.load`'s unpersist (:684 in the
  trace), rethrown at :735, and OC's `Machine.load`, which logs `Unexpected error loading a state of computer` and
  closes the machine (`Machine.scala`:808-813 in 1.12.58-GTNH; the 1.12.64 trace's :774-775 match it), so the
  computer is left stopped [S]. This is the one-time refusal the cross-build blob row predicts for every blob
  written before round 3 moved the serializer hash, seen in game for the first time. It was the session's only
  `Unexpected error loading a state` line and its only `eris-lj` text (two lines, the exception and its cause), and
  the only error any computer logged [M: `md5s.txt`; the log's other `ERROR` lines are other mods']. With no saved
  state, the computer's next start was a fresh boot on the jar's kernel `1d12c322` [I: a machine keeps its saved
  kernel only through a restored state; in-game-tests.md, Before every test, step 3]. It booted OpenOS and ran T11
  [I: the results file exists; no screenshot or log line shows the boot].
- **Part 1** [M]. `Part 1: 38 PASS, 0 FAIL, 5 deviation as documented, 0 SKIP`, and no `FAIL` or `SKIP`
  line. Its `PASS`, `DEV` and summary lines are identical to those of run 3's harness LuaJIT arm
  (`../2026-10-22-t11/run-3/ig-luajit/home/`), and its `PASS` lines to those of run 3's harness Lua 5.3 arm, whose
  five `DEV` lines give 5.3.6's values as documented. The hot loop raised at `i = 1000`, the iteration the
  interpreter raises at.
- **Part 2** [M]. All five rows `ok`, `Part 2: 5 benches, 0 BAD, ERR or NOT TIMED`, `verdict: PASS  (LuaJIT, in
  game)`. Medians / mins, ns per operation; the percentages are from the medians of the reps (`ratios.txt`), the
  `-joff` factor from the printed medians:

| bench (per) | in game | luajit.exe | game / standalone | harness, LuaJIT | game / harness | `-joff` / game |
|---|---:|---:|---:|---:|---:|---:|
| crc32 table (byte) | 3.82 / 3.77 | 3.76 | +2% | 3.44 | +11% | 6.0x |
| xorshift32 (step) | 2.05 / 2.00 | 2.30 | -11% | 2.37 | -14% | 21.7x |
| pack+unpack (word) | 4.94 / 4.88 | 5.39 | -8% | 5.42 | -9% | 13.5x |
| x \| 0 (op) | 0.62 / 0.62 | 0.56 | +10% | 0.56 | +10% | 9.9x |
| select(i,...) (call) | 2.36 / 2.34 | 1.61 | +46% | 1.93 | +22% | 5.3x |

- **Reading it.** Each row's five reps lie within 1.4-3.5% of each other (max over min) [M]; no single rep was
  disturbed [I] (a game busy throughout would also give a tight spread). Every row is 5.3x to 21.7x faster than the
  `-joff` column, so by T11's rule all five ran compiled [I: no `-jdump` in game]. Four rows lie within 14% of the
  harness, in both directions, as a different core or clock would move them (T7-T9) [I]. The crc32 / pack+unpack
  ratio, the cross-row check T11 gives for the table-index fold, reads 0.77, against 0.70 standalone and 0.63 in the
  harness [M]. An absent fold would roughly double the crc32 figure, and with it this ratio [I, as T11 says], so
  0.77 is consistent with the fold in effect [I]. `select` is the row furthest from standalone (+46%). About half of
  that gap was already in the harness (1.93 against 1.61, +20%), and the game reads +22% over the harness [M]. By
  T11's Reading Part 2 that is a finding to follow up standalone, not a FAIL; it has not been followed up.

## Not here

- The Lua 5.3 arm, and with it the ratio T11 exists for, which must come from one game session for both arms.
- A screenshot: none was taken (the instance's `screenshots/` has none from 2026-10-22). The results file holds
  everything the screen showed but its last line, the file's path.
- Pinning: the game ran on whatever cores Windows gave it, as the harness runs of `../2026-10-22-t11/` did.
- The logs themselves (6.6 MB and 30 KB for T11's session); `log-excerpts.txt` keeps the cited lines.
