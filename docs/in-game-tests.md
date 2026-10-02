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
     of computer`, or the machine coming back `Stopped`.

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
0.411 s in the pinned harness; not yet re-measured in game, see T8).
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

**Result: pending.**
