## T10 — the bitwise operators and their speed, on OC's Lua 5.3 CPU and on ours

Shape: one file, `bench/oc/ingame-bitops.lua`, run unchanged on OpenComputers'
own **Lua 5.3** CPU and on our **LuaJIT** CPU, on the same computer. It shows
two things in game.

- **Part 1** checks Lua 5.3's bitwise operators against known answers, as a
  player's program meets them: CRC32 of `"123456789"` (`0xCBF43926`) both
  table-driven and bit by bit, and of a 4 KB buffer; shifts by 31, 32 and 63
  bits (`1 << 63` compared with `-2^63`), by 64 or more and by negative
  counts; masks, xor and `~`; packing and unpacking bytes and 24-bit colours
  with `<< >> & |`; xorshift32's first step; the masked rotate and mask-first
  remedies the README recommends; `string.pack` and `string.unpack` of `<I4`
  and `>i8` with known bytes; and `1.5 & 1` raising `number has no integer
  representation`. Every line must PASS on both CPUs. Then it runs five
  **deviation** cases, where the two CPUs must differ as documented (README,
  Lua dialect; the JIT guide's U1-B): `2^53 | 1`, `-1 >> 1`, `~0 >> 1`, the
  unmasked 32-bit rotate `((x >> 7) | (x << 25)) & 0xFFFFFFFF`, and a loop of
  2000 iterations whose `(2^53 - 1000 + i) | 1` first passes 53 significant
  bits at i = 1000. Lua 5.3 returns 5.3.6's 64-bit integers. Our CPU raises
  `result of '<op>' has more than 53 significant bits (mask each operand to 32
  bits first)`, and in the loop it raises at exactly i = 1000, after the loop
  has had time to be compiled.
- **Part 2** times five loops, in nanoseconds per operation: a table-driven
  CRC32 over 4 KB (per byte), xorshift32 (per step), packing four bytes into a
  word and unpacking it (per word), the `x | 0` float-to-int idiom on integral
  doubles (per operation), and `select(i, ...)` in a vararg function (per
  call). These are the loops that the 2026-10 work on our fork is about: the
  table-index fold (e7eb613), the select fix (209aa95) and, once it ships, the
  identity fold of FIX-NUMCONV (roadmap row 211, uncommitted on 2026-10-22).
  Each loop's result is checked against a reference computed without bit
  operators (CRC32 and xorshift32 against PUC Lua 5.3.6's values), so a
  compiled loop that computes a wrong value shows as `BAD`.

What it cannot show. The sandbox has no `jit` table, so a program cannot turn
the JIT off or ask what it compiled. T10 compares **CPUs**, not JIT settings.
That a loop was compiled on our CPU is only inferred from its speed: the
standalone `-joff` column below is what the same loop costs interpreted. It
does not save or reload a world (T1–T3 cover persistence).

The timer is the same on both CPUs. In game `os.clock()` is not the C
library's but OpenComputers' own, which returns `machine.cpuTime()`: the wall
time the computer has spent running, measured with `System.nanoTime()` and
summed over its run slices [S: OC GTNH 1.12.58,
`li/cil/oc/server/machine/luac/OSAPI.scala`'s `os.clock` and `Machine.scala`'s
`cpuTime`; `LuaJITArchitecture` extends luac's `NativeLuaArchitecture`, whose
APIs include it]. So Part 2 reads alike on a Windows host and on a Linux
server. Only the standalone runs below use the C library's `os.clock()`: wall
time on Windows, where they were taken, and process CPU time on Linux.

How the file is written, and why (its header says the same):

- The operators live in a string chunk that the file compiles with `load()`.
  On a **Lua 5.2** CPU, which cannot parse them, it prints `needs Lua 5.3 or
  LuaJIT` and `verdict: not run`, instead of failing to compile. The chunk uses
  only Lua 5.3 syntax: no `~>>`, no compound assignment, and no `//` (our CPU
  has none).
- Operands come from `tonumber()` of strings or from a table, because our
  parser folds a constant bit expression at compile time. A check written on
  literals would test the folder, not the interpreter or the JIT.
- The architecture comes from `computer.getArchitecture()`. Standalone, with no
  `computer`, it is inferred from `jit` and `_VERSION`. In game nothing depends
  on `jit`.
- The timer, the yield and the output follow `ingame-ladder.lua` (T7):
  `os.clock()` brackets each rep, and `os.sleep(0)` between reps yields. Each
  bench's iteration count is calibrated so that a rep takes about 0.3 s. One
  uncounted warm-up rep checks the count and rescales it once if the rep fell
  outside 0.2–0.5 s. Then REPS reps run (5 by default). That stays far under
  OC's 5 s no-yield timeout and our watchdog ([docs/watchdog.md](watchdog.md)):
  standalone, with a stub `os.sleep` that recorded the gaps, the longest
  stretch without a yield was at most 0.38 s, on our `luajit.exe` and on PUC
  Lua 5.3.6 [M: 2026-10-22].
- Everything it prints also goes to a results file next to it,
  `/home/ingame-bitops-luajit.txt` or `/home/ingame-bitops-lua53.txt`. If that
  name is taken it writes `-2`, `-3` and so on, and never overwrites an
  earlier result. The file also holds each bench's iteration count, its
  warm-up time and every rep's time.

### Setup

1. **The jar.** With the game closed, replace the `ocluajit-*.jar` in
   `C:/Games/Minecraft/instances/Main/minecraft/mods/` with the one from
   `build/libs/` (the non-`-dev` one; Before every test, step 1), built from
   the commit whose native you want to see. Record its name and size, and its
   Windows native's md5
   (`unzip -p <jar> assets/opencomputers/lib/libjnluajit52-windows-x86_64.dll | md5sum`).
   On 2026-10-22 the newest jar there was
   `ocluajit-e7eb613-master+e7eb613299-dirty.jar` (681 013 bytes). It carries
   the DLL `b5ff2d18`, the select release's native and the one the harness
   readings below ran. It has the table-index fold and the select fix, and not
   FIX-NUMCONV, which was uncommitted that day.
2. **The file.** Also with the game closed, copy `bench/oc/ingame-bitops.lua`
   into the computer's `/home`, the directory
   `saves/<world>/opencomputers/<address>/home/` on the host (the disk that
   holds T5's `bench.lua` and T7's files). Check it is byte-identical to the
   repo's (`md5sum`).
3. Launch, load the world, open the computer, and **power-cycle it** (Before
   every test, step 3).

### Running it

On each CPU in turn, LuaJIT first:

1. **Choose the architecture.** Either take the CPU out of the computer,
   shift+right-click with it in hand until its tooltip names the architecture,
   and put it back; or, at the `lua>` REPL, run
   `computer.setArchitecture("Lua 5.3")` (or `"LuaJIT"`), which sets it on the
   installed CPU and reboots the computer (OC's `machine.lua`: its
   `libcomputer.setArchitecture` yields `true`, the reboot request [S]).
   `computer.getArchitectures()` lists the names the CPU accepts.
2. **Power-cycle the computer** (shut it down, then start it), as Before every
   test, step 3, says, so that each arm starts from a fresh boot.
3. At the shell, in `/home`: `ingame-bitops` (or `lua /home/ingame-bitops.lua`).
   `ingame-bitops 3` runs 3 reps instead of 5. A run takes about 10–20 s
   [I: 10 s standalone on either CPU, at about 0.3 s a rep]. The screen
   scrolls (Part 1 alone is 46 lines), so read the results file; the last
   lines on screen are the Part 2 table, the `verdict:` line and the file's
   path.

A **Lua 5.2** CPU is not part of the test. On one, the file prints only its
`needs Lua 5.3 or LuaJIT` line (checked on PUC Lua 5.2.4 standalone,
2026-10-22).

### Expected

**Part 1, on both CPUs:** `Part 1: 38 PASS, 0 FAIL, 5 deviation as
documented, 0 SKIP`. The checks' lines are identical on the two CPUs. The five
`DEV` lines differ as documented:

| case | Lua 5.3 | LuaJIT |
|---|---|---|
| `2^53 \| 1` | `5.3.6's value 9007199254740993` | `raised: result of '\|' has more than 53 significant bits (mask each operand to 32 bits first)` |
| `-1 >> 1` | `5.3.6's value 9223372036854775807` | `raised: result of '>>' has more ...` |
| `~0 >> 1` | `5.3.6's value 9223372036854775807` | `raised: result of '>>' has more ...` |
| `rotr(0xDEADBEEF, 7) unmasked` | `5.3.6's value 3753728893` | `raised: result of '\|' has more ...` |
| `hot loop (2^53-1000+i) \| 1` | `5.3.6's value 9007199254741993 (loop ran to i = 2000)` | `raised: result of '\|' has more ... (at i = 1000, want 1000)` |

The file matches the stable part of our message, `result of '<op>' has more
than 53 significant bits`, with the operator in it. The full text is
`ob_err_inexact`'s, in `native/luajit/oclj_bitop_meta.c` ~:130-134 [S].

**Part 2:** the `check` column reads `ok` on all five rows, on both CPUs, and
the last line reads `verdict: PASS`. The figures are measurements, not a
pass/fail. For comparison, smoke readings on this box on 2026-10-22,
unpinned, while other work ran on the machine (median / min of 5 reps, ns per
operation; `-joff` 3 reps, medians) [M]:

| bench (per) | luajit.exe | luajit.exe `-joff` | PUC 5.3.6 | harness, LuaJIT | harness, Lua 5.3 |
|---|---:|---:|---:|---:|---:|
| crc32 table (byte) | 3.92 / 3.80 | 22.74 | 24.08 / 23.92 | 3.41 / 3.41 | 37.42 / 32.99 |
| xorshift32 (step) | 2.34 / 2.09 | 45.32 | 16.24 / 14.21 | 2.39 / 2.38 | 30.98 / 30.61 |
| pack+unpack (word) | 5.46 / 5.41 | 66.45 | 70.33 / 70.10 | 5.43 / 5.41 | 90.11 / 89.54 |
| x \| 0 (op) | 0.75 / 0.75 | 6.07 | 8.64 / 8.64 | 0.75 / 0.74 | 13.24 / 13.21 |
| select(i,...) (call) | 1.60 / 1.60 | 12.69 | 24.59 / 24.43 | 1.93 / 1.91 | 41.97 / 41.70 |

`luajit.exe` is `build/native/luajit-windows-x86_64/src/luajit.exe`
(`17f96322`, the build of the select release); PUC 5.3.6 is
`bench/vendor/lua-5.3.6/src/lua.exe`. "harness" is the ocelot-brain census
(`test/native/census-os.sh` on a scratch copy of OpenOS, with `/home/.shrc`
starting the file, 3000 ticks, a 1 MB machine). Its LuaJIT arm ran our DLL
`b5ff2d18` under the watchdog kernel. Its Lua 5.3 arm ran ocelot-brain's
bundled PUC 5.3 native under OC's stock kernel, and read 1.3–1.9x the
standalone PUC 5.3.6; the stock kernel's standing count hook and a different
build of the native are candidates, not separated [I]. Both arms gave Part 1
38 / 0 / 5 / 0, with every `PASS` line identical between them, all checks
`ok`, and `verdict: PASS`; in the harness Lua 5.3 reads 11–22x LuaJIT. The
harness has predicted the game closely before, pinned to the performance
cores (T7–T9); these runs were not pinned.

### Reading Part 2

- The **median** is the figure to record; the **min** is the best rep. A wide
  gap between them means the game or the box was busy during a rep. The file
  holds every rep's time.
- The ratio that matters is **Lua 5.3 / LuaJIT** per row, both from the same
  game session.
- A LuaJIT row near the `-joff` column means that loop ran interpreted in
  game: it was not compiled, or it was blacklisted. That is a finding to
  follow up standalone, not a FAIL.
- `crc32 table` on LuaJIT near 3.4–3.9 ns per byte is the table-index fold
  working (e7eb613 measured 7.2 ns per byte before it and 3.7 after).
- The units differ between rows, so compare a row with itself across CPUs,
  never across rows. Each figure includes its loop's overhead: one xorshift32
  step is three xor-shift pairs; one pack+unpack word is four shifts and three
  `|` to pack, four shift-and-mask pairs to unpack, and the sums; one `x | 0`
  operation includes a table load and an add; one `select` call includes the
  vararg loop's add.

### What to record, and where

The date and game session, from `latest.log` (world joined, screenshot); the
jar's name, size and its DLL's md5; that the copy on the disk is
byte-identical to the repo's `bench/oc/ingame-bitops.lua` (md5); the machine's
RAM (the first lines print it); and, from each CPU's results file, the
`Part 1:` line, any line that is not `PASS` or `DEV`, the `Part 2` table and
the `verdict:` line. Copy the two results files from the save's `home/` into
`bench/runs/<date>-t10/`, and write the Result paragraph here:

| bench (per) | LuaJIT median / min | Lua 5.3 median / min | Lua 5.3 / LuaJIT (medians) |
|---|---:|---:|---:|
| crc32 table (byte) | | | |
| xorshift32 (step) | | | |
| pack+unpack (word) | | | |
| x \| 0 (op) | | | |
| select(i,...) (call) | | | |
| Part 1 (PASS / FAIL / DEV / SKIP) | | | — |
| verdict | | | — |

### What a FAIL means

Check the instrument first: run the same file standalone on the jar's native
(`luajit.exe` of the same build) and on PUC Lua 5.3.6, where every line passed
on 2026-10-22.

- **A Part 1 `FAIL` on LuaJIT only.** Our CPU computes a value, or raises an
  error, that 5.3.6 does not, in a case the README says matches. It is a bug
  in the parser, the interpreter or the JIT. The line prints what it got.
- **A Part 1 `FAIL` on Lua 5.3 only.** OC's 5.3 native differs from 5.3.6 on
  that case, or the expectation is wrong. It says nothing about our CPU, but
  the expectation must be rechecked against PUC 5.3.6.
- **A `DEV` line that FAILs on LuaJIT.** The case returned a value where it
  must raise, or it raised another message, or the loop raised at an
  iteration other than 1000. The first is the worst outcome: a double cannot
  hold a result of more than 53 significant bits, so the value returned is
  not 5.3.6's, and nothing said so. The last means compiled code and the
  interpreter disagree.
- **A `DEV` line that FAILs on Lua 5.3.** OC's 5.3 does not give 5.3.6's
  64-bit value.
- **`BAD` in Part 2.** A bench returned a value other than its reference. On
  LuaJIT that is almost certainly a compiled loop computing a wrong value: the
  most serious result T10 can give. Reproduce it standalone with and without
  `-joff`.
- **`needs Lua 5.3 or LuaJIT` with `FAIL: the LuaJIT CPU should have them`.**
  The jar's native has no 5.3 operators: a wrong or stale jar.
- **`too long without yielding`, or a crash screen.** A rep ran far past
  0.5 s. It should not happen. Keep the log and the results file, which is
  flushed after every section.

**Result:** not yet run.
