# In-game tests

The harness (`test/native/OcljSmoke.scala`, ocelot-brain) is where every
persistence fix is gated. These are the few things it cannot show: the real
mod loader, the real `SaveHandler`, a real world save-and-reload, a player at
the keyboard. Each test below is the smallest in-game shape that exercises one
fix; each is run once after the fix ships and recorded here with its result.

## Before every test

1. **Install the jar**: replace the previous `ocluajit-*.jar` in
   `D:/Minecraft/instances/Main/minecraft/mods/` with the one from
   `build/libs/` (the non-`-dev` one). One jar at a time.
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
   (`D:/Minecraft/instances/Main/minecraft/logs/latest.log` or `fml-client-latest.log`):
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
