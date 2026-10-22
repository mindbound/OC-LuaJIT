# In-game tests

The harness (`test/native/OcljSmoke.scala`, ocelot-brain) is where every
persistence fix is gated. These are the few things it cannot show: the real
mod loader, the real `SaveHandler`, a real world save-and-reload, a player at
the keyboard. Each test below is the smallest in-game shape that exercises one
fix; each is run once after the fix ships and recorded here with its result.

## Before every test

1. **Install the jar**: replace the previous `ocluajit-*.jar` in
   `C:/Games/Minecraft/instances/Main/minecraft/mods/` (a Prism instance; it
   lived under `D:/Minecraft/...` before the 2026-09-29 machine migration) with
   the one from `build/libs/` (the non-`-dev` one). One jar at a time.
2. Launch, load the OC experiment save, open the computer.
3. **Power-cycle the computer** (shut it down, then start it) **before the
   test.** A machine restored from a save runs the kernel it was *saved* with —
   `NativeLuaArchitecture.load` unpersists the saved kernel over the freshly
   initialised one — so a kernel fix is not in effect until the computer has
   booted once under the new jar. Skipping this step makes a fixed kernel look
   broken.
4. Run `lua` to get the `lua>` REPL.
5. To take the save: **Save & Quit to Title**, then reload the world. (A plain
   pause/autosave persists the machine too, but quit-and-reload is the shape
   that proved every defect so far and is what the results below refer to.)
6. Afterwards, read the client log
   (`C:/Games/Minecraft/instances/Main/minecraft/logs/latest.log` or `fml-client-latest.log`):
   - expected: `[ocluajit/ocluajit]: Registered the LuaJIT architecture with
     OpenComputers.` once at startup (the mod prints nothing per save; the
     `bundled roots ON` banner is the harness adapter's);
   - a failure is any `eris-lj:` text, any `Unexpected error loading a state
     of computer`, or the machine coming back `Stopped`. One exception, by
     design (the roadmap's cross-build blob compatibility row): on the first
     load after a jar change whose natives stamp another build fingerprint,
     our native refuses the saved state of each LuaJIT computer that was
     running when the world was saved, naming the first field that differs
     (`eris-lj: build fingerprint mismatch: <field> differs (blob '...', this
     build '...'); the blob is from a different natives build`; or, if the
     new jar also changes the blob format, which is checked first,
     `eris-lj: format version mismatch (expected N)`). OC logs it as
     `Unexpected error loading a state of computer` and the computer is left
     stopped. Check that the blob's value is the old jar's (the
     `fml.ModTracker` line names the version the world was saved with) and
     the other the new jar's. A refusal on a reload under the same jar, or
     any other `eris-lj:` text, is still a failure. T11's session met the
     exception (its Result).

## T1 — a `__persist` value with host-side state survives (shell-fill)

Shape: the REPL holds an `io.open` handle (a `__persist` userdata whose recipe
must run *after* the upvalue it calls exists — the 09-16 failure).

```lua
persist_marker = "shell-fill-1"
f = io.open("/lib/core/boot.lua")    -- any file with more than 40 bytes
= f:read(20)
```
Save & Quit, reload, then:
```lua
= persist_marker          -- "shell-fill-1"
= f:read(20)              -- the NEXT 20 characters, i.e. bytes 21-40
f:close()                 -- no error
```

Signals: the REPL comes back at `lua>` (not a reboot); the second `read`
continues where the first stopped, which means the host-side file position
came through the save; no error from `close`.

**Result: PASS, 2026-09-17, jar `cefe308`.** Marker intact, `f:read(20)`
continued at byte 21, `close` clean, no state-load error in the log. The same
shape on the 09-16 jar failed at load with `machine:1162: attempt to call
upvalue 'wrapSingleUserdata' (a nil value)` and left the screen unresponsive.

## T2 — a save landing inside a synchronous call resumes (the `_stack` universe)

Shape: a loop that spends nearly all its time in `SynchronizedCall`, so the
save lands while OC's index-2 root (the pending call closure) is live.

```lua
for i = 1, 2000 do local h = io.open("/lib/core/boot.lua") h:read(1) h:close() end
```
Save & Quit while it runs (it takes long enough to hit), reload.

Signals: the loop **finishes** after the reload (prompt returns, no error);
T1's marker and handle still work; the log has no state-load error. The
decisive signature is in the save's state directory: `_kernel` is written and
**no new `_stack`** appears (under the old two-call shape a mid-sync-call save
wrote a `_stack` about the size of `_kernel`, a second copy of the kernel).

**Result: PASS, 2026-09-19, jar `c9c5cd8`.** Loop resumed and finished;
marker survived; `_kernel` 183139 B written, no `_stack` written (the only
`_stack` present was byte-identical to the 09-16 file, mtime bumped by
`SaveHandler.onWorldLoad`).

## T3 — a save landing inside `component.list` / `pairs(proxy)` walks (M4.5 kernel half)

Shape: OC's two platform iterators used to keep a `next` cursor in a closure
upvalue, invisible to the for-in replay; a save inside the loop resumed against
the restored table's different hash layout and visited the wrong keys, silently.
Kernel sites 10–11 make both walk a snapshot by integer index.

**Requires the power-cycle in step 3** — this is a kernel change.

Site 10, one component every 3 s:
```lua
n = 0 for a, t in component.list() do n = n + 1 print(n, a:sub(1, 8), t) os.sleep(3) end
```
After two or three lines have printed, Save & Quit, reload.

Signals: the loop continues from where it stopped — `n` keeps climbing, every
address printed **exactly once**, and the total equals what a plain
`for a, t in component.list() do print(a:sub(1, 8), t) end` prints afterwards.
A repeated address, a missing one, or a loop that ends early is the old
failure. Log: no `eris-lj` lines.

Site 11, one key every second (a gpu proxy has about 33):
```lua
n = 0 for k in pairs(component.proxy(component.list("gpu")())) do n = n + 1 print(n, k) os.sleep(1) end
```
Save & Quit mid-walk, reload. Same signals: resumes, every key once, finishes
at the same count as an uninterrupted walk.

**Result: PASS, 2026-09-19, jar `b67a73b`** (kernel 51147 B, 11 sites; native
unchanged from `c9c5cd8`, DLL `49ead6cc`). Both walks were saved mid-loop and
reloaded (server stop/start at 15:34:26/15:34:33 and 15:35:10/15:35:17 in
`fml-client-latest.log`). `component.list`: 7 components, numbered 1–7, each
address once (computer, filesystem x2, screen, keyboard, gpu, eeprom).
`pairs(gpu proxy)`: 33 keys, numbered 1–33, each once, `allocateBuffer` through
`setPaletteColor`. Log clean: no `eris-lj:` text, no state-load error, no
exception. Harness equivalent: `fi-1/2/3`, 45/0, with the negative control
(sites 10–11 removed) failing `fi-2`/`fi-3` on the wrong-sequence symptom.

## T4 — a caught timeout that outlives its grace crashes cleanly (kernel site 12)

Shape: OC kills a program that catches `too long without yielding` and keeps
running past the 0.5 s grace. On the 11-site kernel that kill escaped the kernel
itself (LuaJIT's hooks are per-VM, and `checkDeadline`'s own count=1 re-arm
hooked the kernel thread), so the computer died with **`kernel panic: this is a
bug, check your log file and report it`** instead of the clean error stock OC
gives.

**Requires the power-cycle in step 3** — this is a kernel change.

At `lua>`, paste (nothing between the catch and the end of the spin may yield):
```lua
pcall(function() while true do end end) local t = computer.uptime() while computer.uptime() - t < 1 do end
```

Signals: after ~5.5 s the computer stops with the red **Unrecoverable Error**
screen reading **`too long without yielding`** — the same screen stock OC shows.
A screen reading `kernel panic: this is a bug ...` is the old failure, and the
log then carries `Kernel crashed. This is a bug!`. Either way the computer is
stopped; sneak-right-click restarts it. Log check: no `Kernel crashed` line.

**Result: PASS, 2026-09-22, jar built from the site-12 change** (kernel 51952 B,
12 sites; natives unchanged, DLL `49ead6cc`). The REPL line ran, the computer
stopped on the blue *Unrecoverable Error* screen reading `too long without
yielding` — the same screen stock OC shows — and rebooted normally afterwards.
Log: no `Kernel crashed` line. Harness equivalent: `OCLJ_PROBE=grace`
— `k6` FAIL on the 11-site kernel (kernel panic, 5411 ms), PASS on stock (5415 ms)
and on the 12-site kernel 4/4 (5402–5421 ms).

## T5 — a program re-run many times stays compiled (the penalty-cache cure)

Shape: LuaJIT's trace-abort penalty cache is keyed by bytecode address and was
never scrubbed when a prototype died; on a heap that hands a freed block
straight back (the machine's was the C library's until 2026-10-02 and is now
its own `lj_alloc` arena, which usually does the same) a re-loaded program
inherits the dead one's abort history and is blacklisted to the interpreter
around its 9th run. Before 2026-09-22 the per-save trace flush reset it once per
autosave, so the symptom needed ~9 runs between two saves; now the cure is in the
native (`lj_func_freeproto` scrubs the slots) and the flush is gone.

**Requires the new natives** (the jar built from this change, serializer hash
`8c5a1168`; the mod refuses to load a stale one).

Write `/home/bench.lua` (any compute loop with an inner loop that exits early is
the shape; this one is `bench/oc/mandelbrot.lua`'s):
```lua
local t0 = os.clock()
local n, sum = 300, 0
for py = 0, n - 1 do for px = 0, n - 1 do
  local zr, zi, cr, ci, it = 0, 0, 2 * px / n - 1.5, 2 * py / n - 1, 0
  while it < 50 and zr * zr + zi * zi <= 4 do zr, zi, it = zr * zr - zi * zi + cr, 2 * zr * zi + ci, it + 1 end
  sum = sum + it
end end
print(string.format("%d %.3f s", sum, os.clock() - t0))
```
Then run it fifteen times. Two things shape how: OpenOS's `lua` takes only a
file path (no `-e`), its `sh` has no `for`, `collectgarbage` is not in the
sandbox, and the kernel runs a full GC every 10 sandbox resumes
(`machine.lua:1527`) — that GC is what frees the dead prototype so the next
load can land at the same address, and it only happens between resumes.

A, from the shell (the shape that bit): at `/home #` type `bench` fifteen
times (PATH includes `.`, so it resolves to `./bench.lua`; ↑ + Enter repeats).
Each invocation is a fresh `load` with its own resumes.

B, one REPL line: `lua`, then
```lua
for i = 1, 15 do dofile("/home/bench.lua") os.sleep(0.5) end
```
`dofile` loads fresh each time and the `os.sleep` yields so the kernel's GC can
run between runs; without the sleep the loop is one resume, the dead
prototypes are not collected in time, and the test is vacuous on both natives.

Signals: every run prints the same checksum and about the same time (the first
one or two a little slower while the JIT warms). The old failure is a jump to
~5–8x the time from around the 9th run that never recovers, with the checksum
unchanged. Harness equivalent: `test/native/run-penalty.sh` (unpatched lib:
first blacklist at run 11, 5.97x; patched: 40/40 clean).

**Result: PASS, 2026-09-22, the native-bump jar (serializer hash `8c5a1168`).**
Both forms, 15 runs each: checksum `2196322` every time, 0.005–0.008 s per run
with no trend (A from the shell: 0.006/0.007/0.006/0.006/0.006/0.006/0.006/
0.006/0.006/0.006/0.006/0.007/0.007/0.005/0.007; B in the REPL with the
`os.sleep`: 0.007/0.006/0.007/0.006/0.006/0.006/0.007/0.007/0.008/0.007/0.006/
0.006/0.006/0.006/0.007). 6 ms for ~2.2 M inner iterations is compiled speed —
an interpreted run of this shape is about ten times that — so every re-load
stayed on the JIT.

## T6 — the for-in diagnostic names an OS-authored `next` wrapper (opt-in)

Shape: OpenOS's `boot/04_component.lua` installs a `__pairs` on the `component`
library that is a Lua closure over `next`; a save landing inside
`for k in pairs(component)` cannot be replayed, and with
`-Docluajit.forin=warn` the mod says so in the server log, once per machine.

Add `-Docluajit.forin=warn` to the instance's JVM arguments, launch, then at `lua>`:
```lua
for k in pairs(require("component")) do os.sleep(1) end
```
While it runs, save (Save & Quit is enough; the diagnostic is emitted by the
save itself). Signal: one line in the log of the form `OC-LuaJIT computer <addr>
(for-in diagnostic, -Docluajit.forin=warn): for-in loop at <chunk>:<line>
iterates with a Lua closure (boot/04_component.lua:18) that calls next; ...`.
Without the property, no line. Harness equivalent: `dg-1`.

**Result: PASS, 2026-09-22, the native-bump jar with `-Docluajit.forin=warn`.**
The server log carried exactly one line: `[Server thread/WARN] [ocluajit]:
Computer 1bac88a3-... @ (-353.500, 4.50000, 1137.50, 0) (for-in diagnostic,
-Docluajit.forin=warn): for-in loop at stdin:1 iterates with a Lua closure
(boot/04_component.lua:18) that calls next; its position is not replayable and
resumes against a different hash layout after a reload -- return next, t, nil
from the iterator, or walk a snapshot array by index`. `stdin:1` is the REPL
line's chunk name; `boot/04_component.lua:18` is OpenOS's `__pairs` closure.

## T7 — the in-game column of the sandbox-tax ladder

Shape: [bench/results-ladder-2026-09-22.md](../bench/results-ladder-2026-09-22.md)
measured our LuaJIT rung by rung up to the ocelot-brain machine, where on the
old, busy box the machine read 1.7–2.1x the capped host on the pure loops and
2.9x on binarytrees; re-measured on the new machine with the box idle
([bench/results-ladder-2026-09-29.md](../bench/results-ladder-2026-09-29.md))
the same rung reads mandelbrot 1.15x, sha256 1.39x, matmul 1.64x and
binarytrees 1.76x the capped host, which against plain LuaJIT is 1.15 / 1.39 /
2.0 / 3.7x. Whether what remains is the sandbox or the harness's own JVM
(a poller waking every 25 ms beside the machine) is what the in-game numbers
were to decide (the result below narrows it without separating it), and
Minecraft now runs on the same box as the rungs, so the column is directly
comparable. This is a measurement, not a pass/fail.

Copy `bench/oc/mandelbrot.lua`, `matmul.lua`, `binarytrees.lua` and
`ingame-ladder.lua` into the computer's `/home` — an OC hard disk is the
directory `saves/<world>/opencomputers/<address>/` on the host (the one that
already holds `home/bench.lua`); do it at the title screen. **On a re-run,
copy `ingame-ladder.lua` again first**: the disk still holds the load-once
version the 2026-10-02 run used (`91a25f2`), whose binarytrees reps after the
first are comparable only with standalone re-calls of one loaded chunk (see
the result). Then at the shell:
```
ingame-ladder
```
It prints, per bench, the CHECK and the min of 5 reps, each a fresh load of
the file, with a yield between reps. Expected CHECKs: mandelbrot `37904620`,
matmul `481.0000`, binarytrees `7038400`; expect binarytrees' reps not to
climb from the second (on the C-allocator host, fresh reps after the first
ran up to 1.27x faster than the first, so a step down is possible). For
comparison on this box
(2026-09-29, min of 5, same files, mandelbrot / matmul / binarytrees): plain
`luajit.exe` 0.065 / 0.080 / 0.192 s;
our binary in a bare C host with the accounting allocator 0.065 / 0.097 /
0.409 s; the ocelot-brain machine 0.075 / 0.161 / 0.715 s. (The old box read
0.091 / 0.135 / 0.286, 0.094 / 0.160 / 0.564 and 0.157 / 0.335 / 1.833.)
sha256 is left out (it would need compat.lua copied too; compat takes the
same `operators` path in the sandbox as standalone), sieve is quarantined.

**Result: measured 2026-10-02** (the `91a25f2` runner; the 2026-09-29 jar,
whose DLL `bcf8715c` is the one the harness's rung 4 ran; a 16 MB machine;
Minecraft in-world). CHECKs as expected. mandelbrot 0.0626 s, matmul
0.1031 s, binarytrees 0.5586 s: 0.963 / 1.052 / 1.376x the capped host
(0.065 / 0.098 / 0.406 s), 0.963 / 1.289 / 2.909x plain LuaJIT, and
0.839 / 0.641 / 0.782x the ocelot-brain machine. The game is faster than the
harness on all three, so on this box rung 4 overstates what a player pays;
which of the harness's differences accounts for that (a hidden background
JVM on a hybrid CPU, its JVM flags, its poller, ocelot-brain against GTNH
OC) is not separated (**2026-10-02:** core placement — pinned to the
performance cores, the harness reads mandelbrot 0.0661, matmul 0.1049 and
binarytrees 0.5168 s, near the game's; see T8 and the roadmap). The pure
loop shows no cost in the game — it reads 2–5% faster than every
standalone process, which is not explained and may
sit in every in-game ratio — and the largest factor in binarytrees' 2.9x is
still the allocator rung (1.92x), not the in-game rung (1.38x)
(**2026-10-02:** each machine's own `lj_alloc` arena removes most of that
rung — 1.92x to 1.08x our `luajit.exe` standalone, and binarytrees 0.539 to
0.411 s in the pinned harness; not yet re-measured in game, see T8;
**2026-10-03:** T8 reads 0.4202 s in game, against this run's 0.5586).
binarytrees' reps climbed (0.559 → 0.717 → 0.941 / 0.898 / 0.921) the way one
loaded chunk called five times climbs standalone on all three builds run,
upstream included. Standalone, a `jit.flush()` before each call removed the
climb with the closure count past LuaJIT's threshold (later calls within
1.08x of the first on `luajit.exe` and upstream, against ~2x without), so
the climb needs the trace state the earlier calls leave behind, not the
closure count; the account, not measured, is that later calls run through
the traces compiled for the earlier calls' closures, and the game had no
flush arm. Only binarytrees' first rep is comparable; the runner now loads
per rep.
Detail: [bench/results-ladder-2026-09-29.md](../bench/results-ladder-2026-09-29.md),
"The in-game column".

## T9 — the accounting without a JNI crossing, in game

Shape: until this change every allocation a machine made crossed into the JVM
to keep jnlua's two memory fields current; now `LuaStateLuaJIT` hands the cap
to the shim and reads the used figure back only when `getFreeMemory()` is
called, and the allocations in between are plain C
([docs/accounting-sync.md](accounting-sync.md),
[bench/results-accounting-2026-10-03.md](../bench/results-accounting-2026-10-03.md)).
In the ocelot-brain harness pinned to the performance cores -- which predicted
T7 and T8 -- with the class the only difference: binarytrees 0.2500–0.2564 s
against 0.4239–0.4247, matmul 0.0881–0.0888 against 0.0947–0.0957,
mandelbrot 0.0643–0.0665 against 0.0632–0.0636. So the prediction for the
game: binarytrees near 0.25 s (T8: 0.4202), matmul near 0.089 (T8: 0.0946),
mandelbrot unchanged (T8: 0.0637). A measurement, not a pass/fail, beyond the
CHECKs.

1. **With the game closed**, in
   `C:/Games/Minecraft/instances/Main/minecraft/mods/` remove
   `ocluajit-d20a14d-master+d20a14d376-dirty.jar` (T8's) and put
   `build/libs/ocluajit-0c656ac-master+0c656aca22-dirty.jar` in its place
   (782 707 bytes; the non-`-dev` one). It carries the DLL `cb29485d`; the
   serializer hash (`8c5a1168`) and the kernel (`089dcbde`) are unchanged, so
   T8's world loads as it was. `bench/oc/ingame-ladder.lua` has not changed
   since T8 and stays.
2. Launch, load the world, open the computer and power-cycle it (Before every
   test, step 3).
3. At the shell: `ingame-ladder` (or `lua /home/ingame-ladder.lua`).

Also worth a glance, not part of the measurement: `computer.freeMemory()` at
the shell still falls as a program allocates and recovers after it ends, as
before -- the figure is now read from the shim, and the harness asserts it is
exact to the byte.

**Result: measured 2026-10-03**, in the game session that began at 15:36
(`latest.log`: world joined 15:39:50, screenshot saved 15:41:02), in the same
world and on the same 16 MB machine as T7 and T8. Checked before the result
was written: the `0c656ac` jar (782 707 bytes) is the only `ocluajit-*.jar`
in `mods/`, its Windows native is `cb29485d` and its kernel `089dcbde`; the
runner on the disk is byte-identical to the repo's
`bench/oc/ingame-ladder.lua` (`a20fdf67`). CHECKs as expected. Min of 5,
seconds; the harness column is T9's pair in the pinned three-arm chain run
right after the game (five runs, min–max of their minimums):

| benchmark | T9 | T8 | T7 | pinned harness, T9's pair | T9/T8 |
|---|---:|---:|---:|---:|---:|
| mandelbrot | 0.0657 | 0.0637 | 0.0626 | 0.0631–0.0731 | 1.031 |
| matmul | 0.0862 | 0.0946 | 0.1031 | 0.0862–0.0934 | 0.911 |
| binarytrees | 0.2521 | 0.4202 | 0.5586 | 0.2431–0.2485 | 0.600 |

The prediction is met on binarytrees, which fell to 0.2521 s (predicted near
0.25), and beaten on matmul, 0.0862 (near 0.089); binarytrees' reps are flat
(0.252–0.260) and its first rep is its min. The pinned harness tracked the
game a third time, closely rather than exactly: before the game, h3's two runs
held binarytrees (0.2500–0.2564) and read matmul 2.2% above it
(0.0881–0.0888); the chain after it reads matmul on the game's value and
binarytrees 1.4% under it (1.7% leaving out one disturbed run). mandelbrot read 1.031x,
not the "unchanged" predicted, and not this change: it makes under 800
allocator calls a run, the chain reads it 1.003 with the class the only
difference, and the library change moves it the other way in the harness
(0.958 at the medians); read as variation between game sessions (0.0626,
0.0637, 0.0657 across T7–T9), not separated. Against the arena host with the
accounting the game now reads 1.011 / 1.014 / 1.064x, and what binarytrees
pays over it fell from 0.183 s a run to 0.015 s. The runner's first line read
`free=15888 KB` (T8: 16133); the harness shows no dependence of the
post-boot figures on the mode, so this is one reading of what the sandbox
held at that moment.
Detail: [bench/results-accounting-2026-10-03.md](../bench/results-accounting-2026-10-03.md#in-game-t9-2026-10-03),
"In game (T9, 2026-10-03)".

## T8 — the allocator change in game

Shape: until 2026-10-02 every machine's heap was the C library's
(`realloc`/`free`, jnlua's convention); since then each machine's blocks live
in its own `lj_alloc` arena — LuaJIT's own allocator — under the same
accounting (`lj52_back` in `native/lj52shim.c`;
[bench/results-allocator-2026-10-02.md](../bench/results-allocator-2026-10-02.md)).
Standalone, that took binarytrees from 1.92x our `luajit.exe` to 1.08x (accounting
off; 1.22x with it). In the ocelot-brain harness pinned to the performance
cores — which, pinned, reproduced T7's in-game figures (mandelbrot 0.0661,
matmul 0.1049, binarytrees 0.5168 s against the game's 0.0626 / 0.1031 /
0.5586) — the shipping native, against the pre-arena DLL in the same
fingerprinted chain, reads binarytrees 0.4127–0.4295 s (pre-arena 0.5671),
matmul 0.0954–0.0978 (0.1102), strings2 0.2383–0.2509 (0.2737), mandelbrot
0.0637–0.0638 (0.0671). This test is the game's side of that: a measurement, not a
pass/fail, beyond the CHECKs.

1. **With the game closed**, in
   `C:/Games/Minecraft/instances/Main/minecraft/mods/` remove
   `ocluajit-f32897a-master+f32897a824-dirty.jar` and put
   `build/libs/ocluajit-d20a14d-master+d20a14d376-dirty.jar` in its place
   (780 887 bytes; the non-`-dev` one). It carries the DLL `88b50796`; the
   serializer hash is unchanged (`8c5a1168`), so saves the T7 jar wrote are
   read by the same serializer.
2. Also with the game closed, copy the repo's current
   `bench/oc/ingame-ladder.lua` into the computer's `/home` on the host
   (`saves/<world>/opencomputers/<address>/home/`, the disk that holds T7's
   files), replacing the load-once copy the T7 run used: the new one loads
   the file afresh for every rep. `mandelbrot.lua`, `matmul.lua` and
   `binarytrees.lua` have not changed since T7 and stay.
3. Launch, load the world, open the computer and power-cycle it (Before every
   test, step 3).
4. At the shell: `ingame-ladder` (or `lua /home/ingame-ladder.lua`).

Nothing in the game says which native is loaded: the serializer hash did not
change, and `_OCLJ_GCSTATS`, whose 14th value names the heap (1 = the arena),
is a raw global the sandbox never sees. The check is that the `d20a14d` jar is
the only `ocluajit-*.jar` in `mods/`.

Expected — a prediction from the pinned harness, not a measurement: CHECKs
mandelbrot `37904620`, matmul `481.0000`, binarytrees `7038400`; binarytrees
from T7's 0.5586 s (its first rep) toward ~0.44 s, matmul from 0.1031 toward
~0.095 s, mandelbrot unchanged (~0.063 s) — if the game tracks the pinned
harness as it did at T7. With a fresh load per rep, binarytrees' reps should
not climb.

**Result: measured 2026-10-03**, in the game session that began at 10:20
(`latest.log`: world joined 10:24:36, screenshot saved 10:25:10), in the same
world and on the same 16 MB machine as T7.
Checked before the result was written: the `d20a14d` jar (780 887 bytes) is
the only `ocluajit-*.jar` in `mods/`, and its Windows native is `88b50796`,
the shipping DLL the pinned harness ran; the runner on the disk is
byte-identical to the repo's `bench/oc/ingame-ladder.lua` (`a20fdf67`, the
per-rep one). CHECKs as expected. Min of 5, seconds; T7's binarytrees is its
first rep:

| benchmark | T8 | T7 | pinned harness, shipping DLL (ship-1 / ship-2) | T8/T7 |
|---|---:|---:|---:|---:|
| mandelbrot | 0.0637 | 0.0626 | 0.0637 / 0.0638 | 1.018 |
| matmul | 0.0946 | 0.1031 | 0.0978 / 0.0954 | 0.918 |
| binarytrees | 0.4202 | 0.5586 | 0.4295 / 0.4127 | 0.752 |

The prediction is met: binarytrees fell to 0.4202 s, a little below the
~0.44 expected (rep 1 against rep 1, the only comparable pair, 0.751x),
matmul to 0.0946, and mandelbrot, which barely allocates, read 1.018x. The
pinned harness predicted the game again: binarytrees (between 0.4127 and
0.4295) and mandelbrot (on 0.0637–0.0638) sit within the two shipping runs'
mins, matmul 0.8% below the faster. binarytrees' reps are flat — 0.420,
0.424, 0.432, 0.428, 0.426 (1.03x), where T7's climbed to 1.68x the first —
consistent in game with the climb being the load-once runner's shape, as
the standalone runs predicted (T7's result); the DLL changed too, but
standalone the climb appeared on `lj_alloc` and the C library alike while
fresh loads did not climb on either. T8's first rep is its min: no step down either.
matmul's third rep read 0.116 against 0.095–0.097 for the other four; one
rep, not explained. Against plain LuaJIT the game now reads 0.98 / 1.18 /
2.19x (T7: 0.96 / 1.29 / 2.91x); what it pays over the arena host on
binarytrees, about 0.18 s a run, is not separated (the candidates are in the
detail).
Detail: [bench/results-allocator-2026-10-02.md](../bench/results-allocator-2026-10-02.md#in-game-t8-2026-10-03),
"In game (T8, 2026-10-03)".

## T11 — the bitwise operators and their speed, on OC's Lua 5.3 CPU and on ours

Shape: one file, `bench/oc/ingame-bitops.lua`, run unchanged on OpenComputers'
own **Lua 5.3** CPU and on our **LuaJIT** CPU, on the same computer. Like T7
it is not one fix's test, but where T7 measured our CPU against plain LuaJIT,
it compares the two CPUs on Lua 5.3's bitwise operators, the first in-game comparison with the Lua 5.3 CPU, the CPU GTNH
crafts by default (the roadmap's in-game benchmark row). It is T11 because the
roadmap's T10 row holds the next per-fix session; the two can run in one game
session on the same jar. It shows two things in game.

- **Part 1** checks Lua 5.3's bitwise operators against known answers, as a
  player's program meets them: CRC32 of `"123456789"` (`0xCBF43926`) both
  table-driven and bit by bit, and of a 4 KB buffer; shifts by 31, 32 and 63
  bits (`1 << 63` compared with `-2^63`), by 64 or more and by negative
  counts; masks, xor and `~`; packing and unpacking bytes and 24-bit colours
  with `<< >> & |`; xorshift32's first step; the masked rotate and mask-first
  remedies the README recommends; `string.pack` and `string.unpack` of `<I4`
  and `>i8` with known bytes; and `1.5 & 1` raising `number (field 'f15') has
  no integer representation` (the file matches `has no integer
  representation`). Every line must PASS on both CPUs. Then it runs five
  **deviation** cases, where the two CPUs must differ as documented (README,
  Lua dialect; the JIT guide's U1-B): `2^53 | 1`, `-1 >> 1`, `~0 >> 1`, the
  unmasked 32-bit rotate `((x >> 7) | (x << 25)) & 0xFFFFFFFF`, and a loop of
  2000 iterations whose `(2^53 - 1000 + i) | 1` first passes 53 significant
  bits at i = 1000. Lua 5.3 returns 5.3.6's 64-bit integers. Our CPU raises
  `result of '<op>' has more than 53 significant bits (mask each operand to 32
  bits first)`, and in the loop it raises at exactly i = 1000. Standalone, our
  `luajit.exe` starts recording a trace of that loop at i = 56, completes it
  at i = 57 and runs the loop compiled from i = 58 [M: 2026-10-22,
  `jit.attach`, the T11 review and its verification]. The interpreter also
  raises at i = 1000, so in game the line shows compiled code agreeing with
  the interpreter only if the loop compiled there as it does standalone.
- **Part 2** times five loops, in nanoseconds per operation: a table-driven
  CRC32 over 4 KB (per byte), xorshift32 (per step), packing four bytes into a
  word and unpacking it (per word), the `x | 0` float-to-int idiom on integral
  doubles (per operation), and `select(i, ...)` in a vararg function (per
  call). Two of them are what the 2026-10 work on our fork sped up: `crc32
  table` by the table-index fold (e7eb613) and `x | 0` by FIX-NUMCONV's
  identity fold (19a7806). The `select` row times the common path, an index
  within the varargs, which the select fix (209aa95) left as upstream compiled
  it apart from a record-time bound; it neither times nor checks the cases
  that fix closed (an index beyond the varargs, at most 0, or above 2^27),
  which `run-bitjit.sh`'s sel part holds. Each loop's result is checked
  against a reference computed without bit operators (CRC32 and xorshift32
  against PUC Lua 5.3.6's values), so a compiled loop that computes a wrong
  value shows as `BAD`, and one that raises shows as `ERR`.

What it cannot show. The sandbox has no `jit` table, so a program cannot turn
the JIT off or ask what it compiled. T11 compares **CPUs**, not JIT settings.
Part 1's checks each run once, so on our CPU they test the interpreter: only
the two 4 KB CRC32 checks and the deviations' hot loop run long enough to be
compiled (standalone, the only Part 1 traces that complete are in those; one
more starts in the 9-byte bitwise CRC32 and aborts [M: 2026-10-22,
`jit.attach`, the T11 review and its verification]). What compiled code computes is checked by
those three lines and by Part 2's `check` column. That a Part 2 loop was
compiled on our CPU is only inferred from its speed: the standalone `-joff`
column below is what the same loop costs interpreted. It does not save or
reload a world (T1–T3 cover persistence).

The timer is the same on both CPUs. In game `os.clock()` is not the C
library's but OpenComputers' own, which returns `machine.cpuTime()`: the wall
time the computer has spent running, measured with `System.nanoTime()` and
summed over its run slices [S: OC GTNH 1.12.58,
`li/cil/oc/server/machine/luac/OSAPI.scala`:13-19 and `Machine.scala`:185,
:997, :1068; the sandbox's `clock = os.clock`, `machine.lua`:983, and in our
kernel `1d12c322` :1028;
`LuaJITArchitecture` (`LuaJITArchitecture.java`:86) extends
`NativeLuaArchitecture`, whose `apis` include `OSAPI` (:49-52, set up at
:319)]. ocelot-brain's `OSAPI.scala` and `Machine.scala`:148 are the same, so
the harness columns below use this timer too. The timer therefore means the
same on a Windows host and on a Linux server (every T11 reading so far is
from Windows, and no Minecraft server has loaded the Linux library yet,
README). Only the
standalone runs below use the C library's `os.clock()`: wall time on Windows,
where they were taken, and process CPU time on Linux.

How the file is written, and why (its header says the same):

- The operators live in a string chunk that the file compiles with `load()`.
  On a **Lua 5.2** CPU, which cannot parse them, it prints `needs Lua 5.3 or
  LuaJIT` and `verdict: not run`, instead of failing to compile. The chunk uses
  only Lua 5.3 syntax: no `~>>`, no compound assignment, and no `//` (our CPU
  has none).
- Operands come from `tonumber()` of strings, from a table or from
  `string.byte`, because both CPUs' parsers fold a constant bit expression at
  compile time (ours and PUC 5.3.6's: `1 << 4` compiles to the constant 16 on
  both [M: the T11 review]). A check written on literals would test the
  folder.
- The architecture comes from `computer.getArchitecture()`. Standalone, with no
  `computer`, it is inferred from `jit` and `_VERSION`. In game nothing depends
  on `jit`.
- The timer and the yield follow `ingame-ladder.lua` (T7): `os.clock()`
  brackets each rep, and `os.sleep(0)` between reps yields. Unlike T7's
  runner, which prints the min of 5 and loads each bench afresh per rep, T11
  reports the median and the min, writes a results file, and calls the same
  closures every rep. Each bench's iteration count is calibrated so that a rep
  takes about 0.3 s. One uncounted warm-up rep checks the count and rescales
  it once if the rep fell outside 0.2–0.5 s. Then REPS reps run (5 by
  default). That stays far under OC's 5 s no-yield timeout and our watchdog
  ([docs/watchdog.md](watchdog.md)): standalone, with a stub `os.sleep` that
  recorded the gaps, the longest stretch without a yield was at most 0.38 s,
  on our `luajit.exe` and on PUC Lua 5.3.6 (0.36 and 0.38 s on this script,
  0.35–0.38 s on its draft) [M: 2026-10-22, `bench/runs/2026-10-22-t11/`'s
  `stub/`]. If `os.clock()` does not advance, calibration stops at its first
  run of at least 4e6 operations (at most 2.6e7, for `select`) and the row
  reads `NOT TIMED` instead of running into the timeout.
- Everything it prints also goes to a results file in `/home`,
  `/home/ingame-bitops-luajit.txt` or `/home/ingame-bitops-lua53.txt`,
  wherever the script itself is (in game the sandbox's `debug.getinfo`
  describes `machine.lua`, not the script). If that name is taken it writes
  `-2`, `-3` and so on, and never overwrites an earlier result. The file also
  holds each bench's iteration count, its warm-up time and every rep's time.

**Setup.**

1. **The jar.** With the game closed, replace the `ocluajit-*.jar` in
   `C:/Games/Minecraft/instances/Main/minecraft/mods/` with the one from
   `build/libs/` (Before every test, step 1), built from the commit whose
   native you want to see, and make sure it is the only `ocluajit-*.jar`
   there. Record its name and size, its Windows native's md5
   (`unzip -p <jar> assets/opencomputers/lib/libjnluajit52-windows-x86_64.dll | md5sum`)
   and its kernel's (`unzip -p <jar> assets/ocluajit/lua/machine.lua | md5sum`).
   For FIX-NUMCONV's natives that jar is `build/libs/ocluajit-19a7806.jar`
   (681 124 bytes, md5 `1e02e032`), built from the clean 19a7806 on
   2026-10-22: DLL `9ac03aeb`, .so `f91700bd`, kernel `1d12c322`. It has the
   table-index fold, the select fix and FIX-NUMCONV, and its DLL is the one the
   harness readings below ran.
2. **The file.** Also with the game closed, copy `bench/oc/ingame-bitops.lua`
   into the computer's `/home`, the directory
   `saves/<world>/opencomputers/<address>/home/` on the host (the disk that
   holds T5's `bench.lua` and T7's files). Check it is byte-identical to the
   repo's (`md5sum`).
3. **The machine.** Give it at least 512 KB of RAM (the harness ran 1 MB).
   While it runs, the file keeps about 160 KB live on standalone PUC 5.3.6
   (126 KB from its setup, 33 KB of compiled code) and about 90 KB on our
   `luajit.exe` (76 + 15), and its setup allocates 223 KB in all on PUC
   [M: the T11 review's `mem.lua`], so a 192 KB or 256 KB machine running
   OpenOS may run out of memory [I].
4. Launch, load the world, open the computer, and **power-cycle it** (Before
   every test, step 3). That a power-cycled machine boots to the shell on this
   jar is also item (1) of the roadmap's T10 row.

**Running it.** On each CPU in turn, LuaJIT first:

1. **Choose the architecture.** Either take the CPU out of the computer,
   shift+right-click with it in hand until its tooltip names the architecture,
   and put it back; or, at the `lua>` REPL, run
   `computer.setArchitecture("Lua 5.3")` (or `"LuaJIT"`), which, if the name
   differs from the CPU's current one, sets it on the installed CPU and
   reboots the computer (OC's `machine.lua`:1441-1450: `libcomputer.setArchitecture`
   yields `true`, the reboot request; `ComputerAPI.scala`:139-158 [S]). The
   current name does nothing and returns no value (`machine.lua`:1442-1446
   drops the callback's `false`); an unknown name returns
   `nil, "unknown architecture"`. `computer.getArchitectures()` lists the
   names the CPU accepts.
2. **Power-cycle the computer** (shut it down, then start it), as Before every
   test, step 3, says, so that each arm starts from a fresh boot.
3. At the shell, in `/home`: `ingame-bitops` (or `lua /home/ingame-bitops.lua`).
   `ingame-bitops 3` runs 3 reps instead of 5. A run takes about 10–20 s
   [I: 10 s standalone on either CPU, at about 0.3 s a rep]. The screen
   scrolls (Part 1 alone is 46 lines), so read the results file; the last
   lines on screen are the Part 2 table, its `Part 2: 5 benches, ...` line,
   the `verdict:` line and the file's path (the one line the file does not
   hold). When it ends, take a screenshot (F2): the path on the last line names
   the file this run wrote.

A **Lua 5.2** CPU is not part of the test. On one, the file prints its two
header lines, `needs Lua 5.3 or LuaJIT: ...`, the load error and
`verdict: not run`, and writes them to `/home/ingame-bitops-lua52.txt` (checked
on PUC Lua 5.2.4 standalone, 2026-10-22).

**Expected.** Part 1, on both CPUs: `Part 1: 38 PASS, 0 FAIL, 5 deviation as
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
`ob_err_inexact`'s, in `native/luajit/oclj_bitop_meta.c` :129-134 [S].

Part 2: the `check` column reads `ok` on all five rows, on both CPUs, then
`Part 2: 5 benches, 0 BAD, ERR or NOT TIMED` and `verdict: PASS`. The figures
are measurements, not a pass/fail. For comparison, smoke readings on this box
on 2026-10-22, on FIX-NUMCONV's natives, unpinned (median / min of 5 reps, ns
per operation; `-joff` 3 reps, medians) [M: `bench/runs/2026-10-22-t11/`]:

| bench (per) | luajit.exe | luajit.exe `-joff` | PUC 5.3.6 | harness, LuaJIT | harness, Lua 5.3 |
|---|---:|---:|---:|---:|---:|
| crc32 table (byte) | 3.76 / 3.74 | 22.80 | 22.82 / 22.82 | 3.44 / 3.42 | 37.60 / 32.73 |
| xorshift32 (step) | 2.30 / 1.99 | 44.58 | 16.33 / 13.59 | 2.37 / 2.36 | 30.88 / 30.74 |
| pack+unpack (word) | 5.39 / 5.37 | 66.50 | 69.16 / 68.93 | 5.42 / 5.39 | 90.25 / 89.94 |
| x \| 0 (op) | 0.56 / 0.56 | 6.16 | 8.62 / 8.59 | 0.56 / 0.56 | 13.27 / 13.24 |
| select(i,...) (call) | 1.61 / 1.59 | 12.58 | 24.58 / 24.50 | 1.93 / 1.91 | 42.74 / 42.67 |

`luajit.exe` is `build/native/luajit-windows-x86_64/src/luajit.exe`
(`f4038cd6`, the build of FIX-NUMCONV's release); PUC 5.3.6 is
`bench/vendor/lua-5.3.6/src/lua.exe`. "harness" is the ocelot-brain census:
`test/native/census-os.sh <copy of ocelot-brain's OpenOS> OpenOS bios 3000`,
with `OCLJ_NATIVE=additive OCLJ_CENSUS_ARCH=luajit` and the DLL's directory in
`OCLJ_LIBDIR`, or `OCLJ_NATIVE=stock OCLJ_CENSUS_ARCH=53`; `/home/.shrc` starts
the file; a 1 MB machine (the wrapper is in the archive's `scripts/`). Its
LuaJIT arm ran our DLL `9ac03aeb` under the watchdog kernel. Its Lua 5.3 arm
ran ocelot-brain's bundled native (Lua+Eris 5.3.6) under OC's stock kernel,
and read 1.3–1.9x the standalone PUC 5.3.6 (medians); the stock kernel's count hook and
a different build of the native are candidates, not separated [I]. Both arms
gave Part 1 38 / 0 / 5 / 0, with every `PASS` line identical between their
results files, all checks `ok`, and `verdict: PASS`; in the harness Lua 5.3
reads 11–24x LuaJIT (medians). The harness has predicted the game closely before,
pinned to the performance cores (T7–T9); these runs were not pinned.

FIX-NUMCONV shows in the `x | 0` row: on the select release's DLL
(`b5ff2d18`) the harness read 0.75 ns there, and on FIX-NUMCONV's (`9ac03aeb`)
0.57, with the other four rows within 6% [M: the archive's `run-1/` and
`run-2/`, the same draft script on each DLL; standalone, `luajit.exe` read
0.75 and 0.56].

**Reading Part 2.**

- The **median** is the figure to record; the **min** is the best rep. A wide
  gap between them means the game or the box was busy during a rep. The file
  holds every rep's time.
- The ratio that matters is **Lua 5.3 / LuaJIT** per row, both from the same
  game session. It compares the CPUs as a player gets them, kernels included:
  OC's stock kernel sets a count hook on the computer's coroutine at every
  resume (its `machine.lua`:1532), which standalone PUC 5.3.6 does not pay;
  ours sets none.
- A LuaJIT row near the `-joff` column most likely ran interpreted in game: it
  was not compiled, it was blacklisted, or, on a small machine, its traces
  were flushed under memory pressure. Our kernel sets no standing hook, so
  interpreted code should cost in game about what `-joff` costs standalone
  [S: docs/watchdog.md]; that is not measured [I]. A row well above the
  compiled column but well below `-joff` is compiled code running slower: a
  busy box, a slower core or a different trace. Either is a finding to follow
  up standalone, not a FAIL.
- `crc32 table` is the row the table-index fold (e7eb613) speeds: in this
  file's loop the table key converts without a guard (`CONV int.i64`, read
  with `-jdump` on the standalone build [M: the T11 review]), and with the fold
  the loop reads 3.4–3.8 ns per byte standalone and in the harness [M, above].
  e7eb613's 7.2 ns per byte before the fold and 3.7 after are another CRC32
  loop's (`bench_bit2.lua`'s crc-table, with a modulo per byte). This loop was
  never timed without the fold, so reading about twice its standalone figure
  as a missing fold is [I]. To judge it, take its ratio to the same session's
  pack+unpack row, which the fold does not touch, and compare that with the
  same ratio above (0.70 standalone, 0.63 in the harness), rather than an
  absolute figure, which moves with the core the machine thread runs on
  (T7–T9). That is the one comparison across rows worth making.
- The units differ between rows, so compare a row with itself across CPUs,
  never across rows. Each figure includes its loop's overhead: one crc32 byte
  is a `string.byte` call, a table load, two xors, a shift and a mask; one
  xorshift32 step is three shift-and-xor pairs and two 32-bit masks; one
  pack+unpack word is four table loads, three shifts and three `|` to pack,
  three shift-and-mask pairs and one mask to unpack, and five adds; one `x | 0`
  operation includes a table load and an add (on our CPU the `|` itself leaves
  only the check that the double is an integer); one `select(i, ...)` call
  includes the vararg loop's add and an eighth of a call to the vararg
  function with eight arguments, its `select("#", ...)` and the caller's add.

**What to record, and where.** The date and game session, from `latest.log`
(world joined) and the screenshot; the jar's name, size, its DLL's md5 and its
kernel's md5, and that it is the only `ocluajit-*.jar` in `mods/`; that the
power-cycled machine booted to the shell; that the copy on the disk is
byte-identical to the repo's `bench/oc/ingame-bitops.lua` (md5); the machine's
RAM (the second line prints it); and, from each CPU's results file, the
`Part 1: N PASS, ...` summary line, any line that is not `PASS` or `DEV`, the
Part 2 table and the `verdict:` line. Copy the two results files from the
save's `home/` into `bench/runs/<date>-t11-game/`, and write the Result
paragraph here:

| bench (per) | LuaJIT median / min | Lua 5.3 median / min | Lua 5.3 / LuaJIT (medians) |
|---|---:|---:|---:|
| crc32 table (byte) | | | |
| xorshift32 (step) | | | |
| pack+unpack (word) | | | |
| x \| 0 (op) | | | |
| select(i,...) (call) | | | |
| Part 1 (PASS / FAIL / DEV / SKIP) | | | — |
| verdict | | | — |

**What a FAIL means.** Check the instrument first: run the same file
standalone on the jar's native (`luajit.exe` of the same build) and on PUC Lua
5.3.6, where every line passed on 2026-10-22.

- **A Part 1 `FAIL` on LuaJIT only.** Our CPU computes a value, or raises an
  error, that 5.3.6 does not, in a case the README says matches. It is a bug
  in the parser or the interpreter (or, in the two 4 KB CRC32 lines, the JIT).
  The line prints what it got.
- **A Part 1 `FAIL` on Lua 5.3 only.** OC's 5.3 native differs from 5.3.6 on
  that case, or the expectation is wrong. It says nothing about our CPU, but
  the expectation must be rechecked against PUC 5.3.6.
- **A `DEV` line that FAILs on LuaJIT.** The case returned a value where it
  must raise, or it raised another message, or the loop raised at an
  iteration other than 1000. The first is the worst outcome: a double cannot
  hold a result of more than 53 significant bits, so the value returned is
  not 5.3.6's, and nothing said so. The last means compiled code and the
  interpreter disagree (if the loop compiled, as it does standalone from
  i = 58), or else an interpreter bug.
- **A `DEV` line that FAILs on Lua 5.3.** OC's 5.3 does not give 5.3.6's
  64-bit value.
- **`BAD` in Part 2.** A bench returned a value other than its reference. On
  LuaJIT that is almost certainly a compiled loop computing a wrong value: the
  most serious result T11 can give. Reproduce it standalone with and without
  `-joff`.
- **`ERR` in Part 2.** A bench raised an error instead of returning, and the
  row prints the message. Every bench's values stay exact, so on LuaJIT
  `result of '<op>' has more than 53 significant bits` here means a compiled
  loop raised where the interpreter does not, as serious as `BAD`. Reproduce
  it standalone with and without `-joff`.
- **`NOT TIMED` in Part 2.** `os.clock()` did not advance, so nothing was
  timed. It says nothing about the operators.
- **`needs Lua 5.3 or LuaJIT` with `FAIL: the LuaJIT CPU should have them`.**
  The jar's native has no 5.3 operators: a wrong or stale jar.
- **`not enough memory`**, in the setup's `FAIL` line or as an error. The
  machine is too small. It says nothing about the operators: add RAM and run
  again.
- **`too long without yielding`, as a crash screen or in an `ERR` row.**
  Something ran for 5 s without yielding (OC's timeout; the pack's
  `timeout=5`), where no stretch should pass about 0.4 s. It should not
  happen. Keep the log and the results file, which is flushed after every
  section.

**Result: the LuaJIT arm PASS, 2026-10-22, jar `ocluajit-19a7806.jar`; the
Lua 5.3 arm not yet run.** [M: `bench/runs/2026-10-22-t11-game/`, unless
marked] One game session, started 13:35:56 local time, world joined 13:39:30,
saved and exited 13:42:50. The jar was the only `ocluajit-*.jar` in `mods/`:
681 124 bytes, md5 `1e02e032`, DLL `9ac03aeb`, kernel `1d12c322`. The copy on
the computer's disk was byte-identical to the repo's (`661c51bd`), and the
machine had 16384 KB of RAM. An earlier session that day, 13:17 to 13:32, had
loaded and saved the world under a4994e6's jar. So on load our native refused
the computer's state at the header (`build fingerprint mismatch: serializer
hash differs (blob '8c5a1168', this build '412be694')`). This is the one
exception in Before every test, step 6: `8c5a1168` is the serializer hash
a4994e6's natives stamp and `412be694` the one 19a7806's carry [S: the
roadmap's cross-build blob compatibility row]. It was the session's only `eris-lj:` text and its
only `Unexpected error loading a state`. The computer was left stopped [S: OC
`Machine.scala`:808-813 in 1.12.58-GTNH], then started; with no saved state
it ran the jar's kernel [I: Before every test, step 3] and booted OpenOS [I:
the results file exists], the roadmap T10 row's item (1). No screenshot was
taken; the results file holds everything the screen showed but its last line,
the file's path.

| bench (per) | LuaJIT median / min | Lua 5.3 median / min | Lua 5.3 / LuaJIT (medians) |
|---|---:|---:|---:|
| crc32 table (byte) | 3.82 / 3.77 | not run | — |
| xorshift32 (step) | 2.05 / 2.00 | not run | — |
| pack+unpack (word) | 4.94 / 4.88 | not run | — |
| x \| 0 (op) | 0.62 / 0.62 | not run | — |
| select(i,...) (call) | 2.36 / 2.34 | not run | — |
| Part 1 (PASS / FAIL / DEV / SKIP) | 38 / 0 / 5 / 0 | not run | — |
| verdict | PASS | not run | — |

Part 1 printed no `FAIL` or `SKIP` line, and its `PASS`, `DEV` and summary
lines are identical to the harness LuaJIT arm's (run 3 of
`bench/runs/2026-10-22-t11/`); the hot loop raised at i = 1000. Each row's
five reps lie within 3.5% of each other. From the medians of the reps, the
rows read +11%, -14%, -9%, +10% and +22% against the harness's LuaJIT arm,
and +2%, -11%, -8%, +10% and +46% against standalone `luajit.exe`. Every row
is 5.3 to 21.7 times faster than the `-joff` column, so all five ran compiled
[I]. The crc32 / pack+unpack ratio is 0.77, against 0.70 standalone and 0.63
in the harness. An absent fold would roughly double the crc32 figure, and
with it this ratio [I, Reading Part 2], so 0.77 is consistent with the
table-index fold in effect [I]. `select` is furthest from standalone. About
half of that gap was already in the harness (1.93 against 1.61, +20%), and
the game reads +22% over the harness. By Reading Part 2 that is a finding to
follow up standalone, not a FAIL; it has not been followed up.

The comparison T11 exists for needs both arms from one game session (Reading
Part 2). A later session on the same jar follows Running it on both CPUs,
LuaJIT then Lua 5.3, and copies both results files into a new directory, never into
`2026-10-22-t11-game/`. On this computer's disk the LuaJIT file will be
`ingame-bitops-luajit-2.txt`; the last screen line names it.
