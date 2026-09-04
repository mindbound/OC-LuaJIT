# OC's deadline hook and the JIT are in direct conflict

**Status: FIXED (§7), 2026-09-03.** Steps 0-2 of the plan in §5 are done and
measured inside a real machine: the sandbox loop that was 18.8x *slower* with
the JIT on is now 6x *faster* than the interpreter and 170x faster than under
OC's kernel, OpenOS boots as fast as it does interpreted, and the deadline
still fires. Step 3 -- real workloads -- is next.

Found while reviewing the memory-accounting change; unrelated to it.

---

## 1. The claim

OpenComputers arms a **count hook** on the sandbox coroutine immediately before
every resume, and never clears it. LuaJIT, with the `LUAJIT_ENABLE_CHECKHOOK`
patch this project requires in order to boot at all, responds to an armed hook
by forcing instruction dispatch for the whole VM *and* by making compiled
traces exit to the interpreter on entry.

The two compose into something worse than either: the JIT keeps recording
traces that cannot be entered, and pays for it forever.

## 2. The mechanism, verified in our own vendored source

**OC arms the hook and leaves it armed.** `machine.lua:1531`, in the main
kernel loop:

```lua
debug.sethook(co, checkDeadline, "", hookInterval)
local result = table.pack(coroutine.resume(co, table.unpack(args, 1, args.n)))
```

There is no matching `debug.sethook(co)` afterwards. Compare `machine.lua:847`
and `:850`, which do pair arm with clear around a nested resume — so the
omission in the main loop is a difference, not a house style.

**An armed count hook forces instruction dispatch.**
`lj_dispatch.c:121`:

```c
mode |= (g->hookmask & (LUA_MASKLINE|LUA_MASKCOUNT)) ? DISPMODE_INS : 0;
```

`lj_dispatch_update` then rewrites the dynamic dispatch table so every bytecode
goes through the hook-checking path.

**CHECKHOOK makes compiled traces bail out when a hook is set**, and its own
comment in `lj_record.c:2953-2965` states the design assumption in as many
words:

> Regularly check for instruction/line hooks from compiled code and exit to the
> interpreter if the hooks are set. […] **Note this is only useful if hooks are
> *not* set most of the time. Use this only if you want to *asynchronously*
> interrupt the execution.**

CHECKHOOK was written for a Ctrl-C handler poking the hook from another thread.
OC arms it continuously, which is the case the comment explicitly excludes.

## 3. What it costs, measured

`build/native/luajit/src/luajit.exe` — the exact LuaJIT this project's DLL
links, CHECKHOOK and LUA52COMPAT on. A hot numeric loop, 4 000 000 iterations,
run inside a coroutine, with and without a count hook armed on that coroutine
exactly as `machine.lua` arms it:

| configuration | time | traces recorded |
|---|---|---|
| JIT on, no hook | 0.008 s | 2 |
| JIT **off**, no hook (pure interpreter) | 0.030 s | 0 |
| JIT on, **count hook armed** (interval 1e6) | 0.928 s | 204 |
| JIT on, **count hook armed** (interval 1e4) | 0.783 s | 408 |
| JIT off, count hook armed | 0.030 s | 0 |

Read the two rows that matter together:

* the JIT is worth **3.8×** over the interpreter when no hook is armed — the
  project's premise, and it holds;
* with a hook armed, turning the JIT **on** makes the same loop **31× slower
  than turning it off**.

The hook itself is nearly free (`0.030 s` either way with the JIT off). The
entire cost is the JIT: 204–408 traces recorded where an unhooked run records
2. Traces are compiled, entered, immediately bounced by the CHECKHOOK guard,
and then recorded again — the bytecode never aborts, so nothing gets
blacklisted, so it never stops. It is not "the JIT is disabled"; it is "the JIT
is thrashing".

## 4. What was not established at the time

(Written before §6, and kept as the record of what the standalone number did and did not prove. §6 closes the first two points.)

* **Nothing here was measured inside a machine.** This is standalone LuaJIT
  with a hand-armed hook, not OpenOS on ocelot-brain. `hookInterval` in a real
  machine is computed from OC's settings and `checkDeadline` does real work; the
  loop above is deliberately trace-friendly in a way sandbox code may not be.
* **The trace count during a real boot is unknown.** The decisive measurement is
  `jit.attach` a trace counter onto the machine's state and boot OpenOS. That
  has not been done. Until it is, the size of the effect on real workloads is
  an extrapolation from a microbenchmark.
* This says nothing about correctness. Everything the smoke test asserts still
  passes; the machine boots, persists and resumes. The claim is about speed
  only — but speed is the entire reason this project exists.

## 5. Remediation plan

This is not a new problem. The feasibility study (2026-09-01) named it as *the*
crux in one line -- "machine.lua's always-armed count hook aborts trace
recording; correct design: no standing hook; Java watchdog thread injects
lua_sethook(count=1) asynchronously + CHECKHOOK build" -- and
`prototype/watchdog/` validated that design on hardware: a compiled
`while true do end` interrupted in 0.025 ms, pcall-swallow re-arm working,
CHECKHOOK tax ~0% on real work.

What happened since is that the binding work took the expedient route to get
OpenOS booting: OC's stock `machine.lua`, standing hook and all. CHECKHOOK was
then recorded as "required to boot", which is true -- but only *because* the
standing hook exists. In the intended design there is no standing hook, the
guard almost never fires, and traces run. The engine is right; it is being
driven with the handbrake on. The plan is to wire in the design that already
exists, not to invent one.

### Step 0 -- confirm it inside a machine (half a day)

Everything in §3 is standalone LuaJIT. Before anything is built on it:

* `jit.attach` a trace counter to the machine's state, on the quiesced raw
  state after `machine.lua` has built its sandbox, and boot OpenOS. Count
  start/stop/abort events over the boot.
* Run a compute-bound loop from **inside the sandbox** (where the real hook is
  armed, with OC's real `hookInterval` and the real `checkDeadline`), timed with
  the sandbox's `os.clock`.
* Do both twice: once as shipped, once with `jit.off(); jit.flush()` applied to
  the same state at the same moment. That is the control.

The harness carries this as a `-Docljit.jit=on|off` switch (`OCLJ_JIT` from
`smoke-test.sh`) and reports a `JIT PROBE:` line; the results are in §6.

If JIT-on is slower than JIT-off *inside the machine*, the rest of this plan is
a week. If it is not, the microbenchmark overstated it and the plan shrinks to a
note.

*Steps 1 and 2 below are DONE; the implementation and its measurements are in
§7. The text is kept as the design record.*

### Step 1 -- no standing hook

Sandbox resumes with the hook **clear**. `machine.lua:1531`'s arm goes; the
`checkDeadline` function itself stays, because it is still what gets called
when the deadline expires -- what changes is who arms it. Our architecture loads
its own kernel, so this is a one-line variant of OC's `machine.lua`, not a fork,
and the census argument (run OC's real kernel semantics, do not couple to one
OS) is untouched.

### Step 2 -- the async watchdog arms it

A watchdog with the deadline. On expiry it calls
`lua_sethook(L, hook, LUA_MASKCOUNT, 1)` from **outside** the VM -- the exact
case CHECKHOOK was written for (`lj_record.c:2963`: "set the instruction hook
via lua_sethook() with a count of 1 from a signal handler or another native
thread"). The next trace-entry guard fails, the trace exits, the hook fires on
the next instruction, `checkDeadline` raises "too long without yielding" --
identical to today from the sandbox's point of view. Between deadlines the
hookmask is zero and traces run at full speed.

Open design question, and the only one: **where the watchdog lives.** jnlua does
not expose `sethook` to Java, so it is either one deliberately added export on
our DLL (the 89-export gate in `build-native.sh` would be bumped *on purpose*)
or a C-side timer thread inside the shim, armed from a Lua-visible call at
resume time. The study said Java thread; the prototype is the starting point
either way. Whichever it is, the deadline value comes from OC's own settings, as
now.

What must survive from the current behaviour, and be tested: the pcall-swallow
re-arm (a sandbox `pcall` that eats the timeout error must not disarm the
deadline -- the prototype covers this), and persistence across a resume that
was interrupted.

### Step 3 -- measure on real workloads

Not the loop from §3. OpenOS boot, the three census OSes, and the benchmark set
from `bench/`. The study's own numbers say the win is bimodal -- 3-15x on
compute-bound Lua, ~zero on component-call-bound programs whose per-tick call
budget dominates -- so expect that shape, and report the shape rather than a
single number.

### Effort and review

Steps 1-2: two to four days. Then the same adversarial review every other
milestone got, because the thing under review is a cross-thread write into a
running VM -- `lua_sethook` from another thread calls `lj_dispatch_update`,
which rewrites the dispatch table while the interpreter may be reading it. That
is documented as supported (it is how `luajit.c`'s Ctrl-C handler works on
Windows, where the handler runs on its own thread), and the prototype relied on
it, but "the prototype worked" is not "it is correct under OC's scheduler".

### What this makes worse, deliberately listed

Once traces actually run, two things §9 notes as *currently masked* (now measured in §8) stop being
masked: the RAM cap's blindness to JIT machine code, and allocation from inside
a compiled trace. Both go on the list for immediately after Step 2. Neither is a
reason to delay it.


## 6. Step 0 result: confirmed in a real machine

Real OpenOS 1.8.9 on ocelot-brain, the shipped DLL, OC's real `machine.lua`
with its real `hookInterval` and `checkDeadline`. The harness attaches a trace
counter to the quiesced raw state after `machine.lua` has built its sandbox,
then boots; `autorun.lua` runs a 2 000 000-iteration numeric loop **inside the
sandbox** three times and reports the best `os.clock` delta. `OCLJ_JIT=off`
applies `jit.off(); jit.flush()` to the same state at the same moment, as the
control. Two runs each, alternating:

| | traces over the boot (start / stop / abort) | sandbox loop, best of 3 | boot to shell |
|---|---|---|---|
| **JIT on**, run 1 | 2765 / 2536 / 229 | **0.485 s** | 220 ticks, 6.58 s |
| **JIT on**, run 3 | 2711 / 2465 / 246 | **0.486 s** | 220 ticks, 6.60 s |
| JIT off, run 2 | 0 / 0 / 0 | 0.026 s | 160 ticks, 4.71 s |
| JIT off, run 4 | 0 / 0 / 0 | 0.025 s | 160 ticks, 4.72 s |

Stable to about 1% across runs. Read it as three facts:

* **Inside the sandbox, under OC's real hook, the JIT makes compute-bound Lua
  18.8x slower than the plain interpreter.** Same loop, same state, same
  moment. The standalone number (§3, 31x) was in the right direction and the
  right order of magnitude; the real `hookInterval` and `checkDeadline` change
  the constant, not the conclusion.
* **It is not only a microbenchmark. OpenOS itself boots 40% slower with the
  JIT on** -- 6.6 s against 4.7 s, 220 ticks against 160 -- on a workload that
  is mostly I/O, string handling and component calls, i.e. the kind the study
  predicted the JIT would do *nothing* for. It is doing worse than nothing.
* **~2 700 traces are recorded and thrown away in one boot.** Roughly one in
  eleven aborts; the rest complete, get entered, hit the CHECKHOOK guard and are
  recorded again. The thrash mechanism of §3 is what happens in production.

Every other milestone still passes in both modes (20/20), and `j0` asserts the
control took. The measurement is now part of the harness and re-runs with
`OCLJ_JIT=on|off`; after steps 1-2 land, the "JIT on" row of this table is the
number to beat, and "JIT off" is the floor it must clear.

Caveat carried forward from §4: kernel init runs with the JIT on in both modes,
because the switch can only be applied once the state exists. That is upstream
of everything measured here and does not affect the comparison.

## 7. Steps 1-2: the watchdog, landed and measured

### What landed

* **`native/lj52shim.c`, the deadline watchdog.** `_OCLJ_WATCHDOG.arm(seconds,
  fn)` programs a one-shot Win32 timer-queue timer and touches no hook. On
  expiry the callback -- on a thread that is not the Lua thread -- calls
  `lua_sethook(L, hook, LUA_MASKCOUNT, 1)`; the trace exits at the CHECKHOOK
  guard, the interpreter fires the hook on the next instruction, and the hook
  calls `fn`. `fn` is `machine.lua`'s **own, unchanged** `checkDeadline`: the
  sentinel, the 0.5 s grace and its own count=1 re-arm against pcall-swallowing
  loops all stay exactly as OC wrote them. `disarm()` cancels the timer
  (blocking until an in-flight callback has finished) and clears whatever hook
  is set. Arms nest as a stack of absolute deadlines. `lj52_close` cancels
  before `lua_close`. The full rationale is the section comment in the file.
* **`native/kernel/patch-machine-lua.lua`.** Derives the OC-LuaJIT kernel from
  OC's `machine.lua` at build time. Four sites, one change: each
  `debug.sethook(co, checkDeadline, "", hookInterval)` / `debug.sethook(co)`
  becomes `watchdog.arm(deadline - computer.realTime(), checkDeadline)` /
  `watchdog.disarm()`, plus a `disarm()` after the main-loop resume that OC
  never had. Every anchor must match exactly once, and exactly three
  `debug.sethook(` calls must remain (the bogomips loop and `checkDeadline`'s
  own re-arm), or it refuses -- so an OpenComputers bump fails at build time
  rather than shipping a kernel that arms the old hook somewhere. It runs on
  the `luajit.exe` the build already produces. CRLF in, CRLF out.
* **The harness.** `OCLJ_KERNEL=watchdog|stock` (the patched kernel is placed
  first on the classpath, where `getResourceAsStream` finds it before
  ocelot-brain's; ocelot-brain is untouched), a deadline probe that spins in a
  `pcall` inside the sandbox and must come back with `too long without
  yielding` (**k1**), and two thrash milestones that only run under the
  watchdog kernel with the JIT on (**k2**: completed traces during boot < 300;
  **k3**: sandbox loop < 0.1 s).
* **`test/native/wd_test.c`**, 32 hermetic checks: a 50 ms deadline interrupts
  a compiled `while true do end` in ~60 ms; the count=1 re-arm is in place
  afterwards and `disarm()` is reachable through the grace; disarm before
  expiry really cancels; arms nest and pop; and -- the point -- 4M iterations
  run in 6-8 ms with **1 trace** while a deadline is armed, against ~900 ms
  and ~200 traces under a standing hook. The test carries a 10 s alarm of its
  own, so a watchdog that never fires ends the process with exit 99 instead
  of hanging.
* **Two negative controls in `test/native/negative-control.sh`**, both
  observed to fail. `standinghook` makes `arm()` also install OC's standing
  count hook -- the "before" picture -- and must fail exactly W6b: the deadline
  still fires, `disarm` still clears, only the JIT thrashes. `notimer` empties
  the timer callback, and then nothing ever interrupts `while true do end`:
  the run must end by the test's alarm, exit 99, summary never reached. That
  is "without the asynchronous injection, the deadline is not enforced",
  demonstrated rather than described.

### The numbers

Same harness as §6. `OCLJ_KERNEL` selects the kernel, `OCLJ_JIT` the control.
Watchdog-kernel JIT-on rows are four consecutive runs; the others as in §6.

| kernel | JIT | traces over boot (start / stop / abort) | sandbox loop, best of 3 | boot to shell | deadline probe |
|---|---|---|---|---|---|
| stock (OC's) | on | 2741 / 2510 / 231 | **0.473 s** | 220 ticks, 6.55 s | fires |
| stock (OC's) | off | 0 | 0.026 s | 160 ticks, 4.71 s | fires |
| **watchdog** | **on** | 263 / 109 / 154 | **0.0028 s** | 180 ticks, 4.76 s | fires |
| **watchdog** | **on** | 221 / 105 / 116 | **0.0043 s** | 160 ticks, 4.71 s | fires |
| **watchdog** | **on** | 257 / 116 / 141 | **0.0040 s** | 160 ticks, 4.70 s | fires |
| **watchdog** | **on** | 245 / 120 / 125 | **0.0046 s** | 180 ticks, 5.29 s | fires |
| watchdog | off | 0 | 0.0168 s | 180 ticks, 5.01 s | fires |

Read as four facts:

* **The sandbox loop is 100-170x faster than under OC's kernel and 6x faster
  than the plain interpreter.** 2M iterations in 3-5 ms, from inside the sandbox,
  under OC's real deadline. This is the row the whole project exists for.
* **The boot penalty is gone.** 4.7 s against 6.55 s -- and against 4.71 s
  interpreted, which is the right comparison: OpenOS boot is I/O, string
  handling and component calls, exactly what the study said the JIT would do
  nothing for. Parity is the correct outcome; the 40% *penalty* was the bug.
* **The JIT is compiling real code now.** ~110 traces completed per boot, with
  aborts a normal minority, where before it completed ~2 500 and threw every
  one of them away.
* **The standing hook was costing the interpreter too.** JIT off, the same loop
  goes from 0.026 s under OC's kernel to 0.017 s under the watchdog kernel:
  35% of interpreter time was the hook machinery, before the JIT ever entered
  the picture.

And the thing that must not change did not: `pcall(while true do end)` inside
the sandbox is interrupted with `too long without yielding` under both kernels
and the machine survives it (**k1**, 23/23 with the watchdog kernel, 21/21
with the stock one).

### Every threshold observed to fail

The first pass of this harness had a threshold the review caught at once: k3
asserted the sandbox loop under 0.1 s, which is *above* the interpreter's
0.026 s -- it would have passed with no compiled code running at all. And
k2/k3 were skipped in every control polarity, so nothing had ever seen them
fail. Both fixed, and the fix is the shape of every milestone here now: the
same threshold is asserted in one polarity and asserted *inverted* in the
others, so each is observed to fail where the thrash is real.

| milestone | watchdog, JIT on | stock, JIT on (control) | watchdog, JIT off (control) |
|---|---|---|---|
| **k0** kernel *observed* (`_OCLJ_KERNEL` read back from raw `_G`) | `watchdog` | `nil` | `watchdog` |
| **k2** traces completed during boot (< 300) | **112** | **2541** (must be >= 300) | -- |
| **k3** sandbox loop (< 0.010 s; interpreter is 0.017-0.026) | **0.0042 s** | **0.458 s** (must be >= 0.010) | **0.0179 s** (must be >= 0.010) |
| **k1** `pcall(while true do end)` -> "too long without yielding" | fires, machine survives | fires, machine survives | fires, machine survives |
| **k4** the loop again, on the resume *after* the timeout (< 0.010 s) | **0.0050 s** | **0.592 s** (must not be fast) | **0.0188 s** (must not be fast) |

k0 exists because "kernel=watchdog" in a log was, until then, only the echo of
a command-line flag; the patched kernel now plants a marker as its first act
and the harness reads it back. k4 exists because nothing had measured speed
*after* a timeout: `checkDeadline` re-arms a count=1 hook when it fires, and a
`disarm()` that failed to clear it would have been invisible. Under the stock
kernel the post-timeout resume is slower still than the pre-timeout one --
OC's re-arm lingers until the next `hookInterval` arm -- while under the
watchdog the very next resume is back at compiled speed.

`wd_test`'s bounds were tightened for the same reason: W2's latency bound
from 1000 ms to 300 ms (measured ~60), and W6b's from 100 ms to 20 ms so that
"traces run" is asserted on time -- compiled 6-8 ms against ~30 ms interpreted
-- and not merely inferred from "traces were compiled".

### What the adversarial review found, and what changed

Five reviewers, five lenses, each told to break this; every finding then went
to two independent refuters, one primed to confirm. The findings that
survived changed the code, and each change is asserted by a test that was
observed to fail first. In the order they were found:

**1. The stack could leak, and a leak would fire spuriously later** (kernel
lens). LuaJIT's hooks are global, so after a timeout `checkDeadline`'s count=1
re-arm also fires on the *kernel's* instructions between a resume returning
and `disarm()`. Past the 0.5 s grace it errors there, `disarm()` is skipped,
and if a sandbox `pcall` swallows the error (OpenOS's event loop does) the
machine lives on with a stale entry on the stack. Pop-one semantics would
deepen the stack per leak and re-program the stale, expired deadline the next
time a legitimate one popped -- a spurious "too long without yielding". OC's
stock kernel is immune by accident: no stack, and its next arm overwrites the
one hook. Now `arm()` returns a depth token, `disarm(token)` restores *to*
that level, and the main loop's `outermost` arm resets the stack and clears
any lingering hook first. `wd_test` W8a-d, each against the behaviour it
replaced; W8c failed the first time, on exactly the lingering hook.

**2. `arm()` cancelled the live timer before failing the depth cap** (fatal;
introduced by fix 1's own rework). A sandbox nested past the cap had its
timer deleted and then got an error a `pcall` could swallow -- undefended
forever. The cap check now precedes anything destructive, the cap is 256
(above PUC's ~200 nested resumes), and past it `arm()` pushes nothing and
hands back a token `disarm` treats as a no-op: the enclosing deadline stays
live, which is what a nested arm would have set anyway. W11a-c.

**3. A fire landing between the sandbox yielding and the kernel's
`disarm()`** would raise the timeout inside `main()` and crash a machine that
had yielded on time -- a microsecond window, but OC machines run for days,
and OC's design excludes it (PUC hooks are per-thread). The first fix
recorded the coroutine each arm was *for* and fired only on it -- and a
refuter reproduced the hole in that: a coroutine nested past the depth cap
has no entry, so its fires matched nothing and it ran 1500 ms under a 300 ms
deadline with `checkDeadline` called zero times. The one thread on which a
fire is spurious is the thread that *armed* -- the parent, running on after
its child yielded -- so that is the only thread the hook now skips; every
other thread fires, entry or not. W10a-e, with W10d the refuter's shape.

**4. The cross-thread `lua_sethook` loses updates in both directions**
(threads lens; the confirming refuter found the half that mattered).
`g->hookmask` is one byte carrying the event bits *and* LuaJIT's state bits
-- `HOOK_ACTIVE` while a hook runs, `HOOK_GC` in a finaliser, `HOOK_VMEVENT`
in a VM event -- and the Lua thread read-modify-writes it constantly without
`lua_sethook`, `hook_enter`/`hook_leave` around every hook call above all.
`lua_sethook` is a plain RMW too (`lj_dispatch.c:344`). Direction one: the
Lua thread's restore lands last and the count bit is gone; a one-shot timer
then never fires, and `while true do pcall(error, 0) end` -- the exact spin
the deadline exists to stop -- performs that RMW millions of times a second.
So the timer **re-fires every 50 ms until disarmed**, the escalation the
study's prototype ran and the port had dropped; a lost update costs one
interval. W9: fire, clear the hook from C as if the update were lost, require
it back (it is, within 170 ms), require `disarm` to end it. Direction two,
which the re-fire *multiplies*: the callback's stale byte lands last and
resurrects a `HOOK_ACTIVE` the Lua thread had just cleared -- and a hook that
LuaJIT believes is already running is a hook that never runs again, on any
path, for the life of the state. During the grace, with the count=1 re-arm
putting the Lua thread in `hook_enter`/`hook_leave` on every instruction, ten
re-fires per grace land plain RMWs into that stream. LuaJIT's own profiler,
the one sanctioned cross-thread writer of this byte, holds a mutex around
both its RMW and the Lua thread's pair (`lj_profile.c:98-131`); we cannot
have that mutex, so the timer thread **no longer calls `lua_sethook` at
all**: it stores `hookf` and `hookcount` and atomically ORs the single count
bit into `hookmask` (`lj52_wd_inject`). An OR can neither resurrect a cleared
bit nor clear a set one. W13: a second of hook-per-instruction under twenty
re-fires, then the state bits must be clean and the next deadline must fire.
Two smaller findings from the same lens -- a torn dispatch table if the
callback's `lj_dispatch_update` interleaves a trace-end on the Lua thread; a
non-atomic `lj_trace_abort` racing the recorder -- were assessed at ~1e-9 per
overrun, self-heal on the next hot event, and are recorded.

**5. `(DWORD)(remaining + 5.0)` for a huge timeout** (persistence lens,
confirmed empirically on the build's own compiler): `computer.timeout` has no
upper bound, values past 2^32 ms come out mod 2^32 and past 2^63 come out
**0** -- a timer that fires at once, a count=1 hook for the whole tick, the
JIT off. Past what a DWORD holds there is no deadline to enforce; `arm()`
now programs no timer. W12.

**6. The tests proved less than they claimed** (evidence lens). k3's
threshold sat above the interpreter; k2/k3 were never seen to fail;
"kernel=watchdog" was a command-line echo; nothing measured speed after a
timeout; `wd_test`'s bounds did not separate compiled from interpreted; and
the watchdog had no sabotage variant. All in the polarity table and the
negative controls above, plus `_OCLJ_WATCHDOG.stats()`, whose fire counters
the harness reads back after the timeout probe (k5).

Refuted, and worth knowing why: "the JIT pays off" claims rest on runs that
do not exist -- they did not, at the time; §7 above is those runs. The sgc
site is dead on LuaJIT (no table `__gc`), so its arm is harmless. A kernel
that arms more than 0.5 s late cannot reach `disarm()` -- true, and not a
reachable state, since the kernel sets `deadline` on the line before.

### The one finding that needed its own instrument

Finding 4's HOOK_ACTIVE half is a 1-in-3000 event. `wd_test` W13 drives about
twenty re-fires and the smoke test none at all, so neither could tell the two
injections apart -- W13 would pass on the broken code. The refuter that
confirmed the finding did not argue it; it built a probe. That probe is now
`test/native/race_test.c`, and it runs **both injections back to back**:

| injection | wedged | re-fires | state afterwards |
|---|---|---|---|
| `lua_sethook` -- the old one | **4 / 4**, after 34-792 ms | 15 396 | `hookmask=0x18` (`HOOK_ACTIVE|MASKCOUNT`), **0** hook calls; a coroutine dying with an error heals it to `0x08`, 406 calls |
| atomic OR -- the current one | **0 / 4** | **119 393** | `hookmask=0x08`, 406 hook calls, alive throughout |

Both halves are asserted. R1 requires the old injection to wedge -- if it does
not, the probe has no teeth and R2 proves nothing -- and R2 requires the
current one not to, over 7.75x as many re-fires as the old one needed to wedge
four times. The fingerprint matches the prediction exactly in every one of the
four wedges, including the heal path (`lj_err.c:155`, the one `hook_leave` a
wedged mask can still reach).

### What the numbers do not say

* One machine configuration, one OS, one microbenchmark inside the sandbox.
  Step 3 -- real workloads, the three census OSes, `bench/` -- is what turns
  "the JIT runs" into "the JIT pays off for OpenComputers programs", and the
  study's own prediction is that the answer is bimodal.
* Everything cross-thread here rests on x86-TSO ordering and on LuaJIT
  tolerating a count hook installed from another core. The atomic OR removes
  the one lost-update direction with no recovery; the other is recovered by
  the re-fire; the dispatch-table tear is bounded. None of that is a proof,
  and the k1 probe is run in every polarity of every smoke run for exactly
  that reason.
* **Timer delivery is best-effort, and under load it shows.** One run in five
  during a batch that shared the machine with concurrent builds and JVMs
  reported `fires=0`: the timer had not been delivered inside the harness's
  15 s window, so the probe loop simply kept running. Six consecutive runs
  with nothing else on the machine were 6/6 with `fires=1`, so this is
  scheduling latency rather than a logic defect -- but a Minecraft server is
  a loaded machine, and an enforcement mechanism that depends on a thread-pool
  callback inherits that pool's latency. Stock OC's standing hook does not.
  Worth measuring under deliberate load before this ships.
* The post-timeout probe (k4) schedules itself from inside the callback that
  just took the timeout, so it races `checkDeadline`'s 0.5 s grace and
  sometimes never registers. k4 therefore tolerates a *missing* number but
  still fails a *slow* one. Registering it up front instead -- the obvious
  tidier shape -- made every run end in a kernel panic with the deadline never
  reported at all; the comment in `AutorunLua` says so, so that nobody tidies
  it again.

### One pre-existing divergence, now understood

LuaJIT's hooks are global to the state, not per-thread. So after a timeout,
`checkDeadline`'s count=1 re-arm hits the **kernel's** instructions too --
including the ones that call `disarm()` -- and the only reason the kernel gets
through is the 0.5 s grace `checkDeadline` grants on the first hit. That was
already true of OC's stock kernel on LuaJIT; the watchdog neither causes nor
cures it, and `wd_test` W3 exercises exactly that path. A kernel that arms more
than 0.5 s late cannot reach `disarm()` -- which, since the kernel sets
`deadline = realTime + timeout` immediately before arming, is not a reachable
state in practice. Recorded so nobody rediscovers it.

## 8. Step 3, first results: what the working JIT actually costs

Both of these were recorded as "currently masked because traces never run".
They are no longer masked, and both now have numbers instead of arguments.
Measured with `_OCLJ_JITSTATS()`, a raw-global accessor added for this --
`J->szallmcarea` (`lj_jit.h:510`) plus the trace count -- because `jit.util`
is deliberately kept out of the sandbox.

### A world save throws away every compiled trace

| | before the save | after |
|---|---|---|
| watchdog kernel, JIT on | 196 608 B mcode, 349 traces | **0 B, 0 traces** |
| stock kernel, JIT on | 196 608 - 458 752 B, 101-776 traces | **0 B, 0 traces** |

The flush is real and it fires on an ordinary OpenOS save. It is *not*
unconditional: `eris_lj.c:1209` flushes only when the coroutine being
persisted is suspended inside a generic-for loop, and `:2127` only when the
restored slots hold a replay iterator. A booted OpenOS evidently satisfies the
first, every time.

**What it costs is still open, and the obvious measurement is a trap.**
Watching an *idle* machine after the flush says nothing: an idle OpenOS has
nothing hot to compile, so "no machine code three seconds later" means "had no
work", not "stays interpreted". A first draft of this measurement asserted
recovery and would have **rewarded the broken build** -- the stock kernel
"recovered" 131 072 B in 250 ms only because thrashing recompiles wastefully,
while the working kernel legitimately sat idle and failed. The harness now
reports that line and asserts nothing. Real recovery has to be measured with a
workload after the save, and belongs to the benchmark harness.

### The RAM cap is blind to ~192 KB per machine

A booted OpenOS on the watchdog kernel holds **196 608 B** of machine code
(stable across six consecutive runs) against a `maxmcode` ceiling of
2 097 152 B. None of it passes `g->allocf`, so the per-machine cap charges for
none of it. For a machine advertising 1024 KB that is roughly a fifth of its
stated RAM, uncharged and invisible to an operator sizing a server -- and the
ceiling is 2 MB, twice the advertised size.

Worth noting for its own sake: the *thrashing* stock kernel holds as much
machine code and sometimes far more (up to 458 752 B with 776 traces, though
it varies a lot run to run where the watchdog kernel does not). Thrashing does
not stop the compiler; it stops traces being *entered*. The standing hook was
paying for machine code it could never run.

### Timer delivery degrades under load, measurably

| condition | wall time | runs with `fires=0` |
|---|---|---|
| serial, nothing else on the machine | 20.2 s | **0 of 12** |
| sharing the machine with builds and other JVMs | 54.6 s | 2 of ~6 |

`fires=0` means the watchdog's timer-queue callback was never delivered inside
the harness's 15 s window, so a runaway loop simply kept running. It is
scheduling latency rather than a logic defect -- the correlation with a 2.7x
wall-time inflation is unambiguous -- but a Minecraft server is a loaded
machine, and OC's standing hook does not inherit a thread pool's latency where
this does. This needs a deliberate load test before shipping, not a hope.

### Step 3 Phase 0: the premise holds, and it is bimodal

Full record: [../../bench/results-in-machine-2026-09-03.md](../../bench/results-in-machine-2026-09-03.md).
Three cells, three runs each, inside a real machine:

| | compute (mandelbrot) | component (fs.list walk) |
|---|---:|---:|
| PUC Lua 5.2 — what players run today | 1.820 s | 6.35 s |
| ours, JIT off (watchdog kernel) | 0.707 s — 2.58x | 6.32 s — 1.00x |
| ours, JIT on | **0.104 s — 17.5x** | **6.38 s — 1.00x** |

The compiler is worth 6.8x on top of the interpreter, and the in-machine
compiled time is within 7% of the same benchmark's standalone compiled time --
so a trace inside an OpenComputers sandbox runs at essentially bare-VM speed.
And component-bound work is flat across a VM change *and* a compiler, because
an indirect component call costs a game tick regardless.

### Step 3 Phase 1: the suite exists, and it is built and verified

`bench/oc/` now holds nine benchmarks, a pinned bit-ops module, a runner and a
reference file. Every CHECK is identical on our LuaJIT compiled, our LuaJIT
under `-joff`, PUC lua5.3 and PUC lua5.4, loaded exactly the way the machine
loads them — `sh bench/oc/run-standalone.sh check` asserts it and passes.
Three rows carry their **published** references unchanged (`mandelbrot`,
`nqueens`, `sha256`), so reproducing them in-machine will be evidence about the
VM rather than about this directory.

Standalone, against the PUC baseline a player runs today — min of 3, one fresh
process per run. These are an upper bound and not the answer: no sandbox, no
deadline, no RAM accounting. The in-machine numbers are what Phase 1 is for.

| | luajit | -joff | vs lua5.3 |
|---|---:|---:|---:|
| sha256 | 0.044 | 1.018 | **33.5×** |
| mandelbrot | 0.093 | 0.511 | 13.7× |
| trampoline | 0.008 | 0.051 | 12.9× |
| matmul | 0.120 | 0.734 | 11.4× |
| sieve | 0.098 | 0.591 | 9.2× |
| binarytrees | 0.249 | 0.315 | 3.8× |
| strings2 | 0.187 | 0.406 | 3.4× |
| nqueens | 1.559 | 1.022 | 1.1× |
| **strings** | **2.727** | **0.423** | **0.27×** |

The rescaling needed to fit an OpenComputers machine preserved the published
ratios closely (`strings` 0.27× against a published 0.25×, `strings2` 3.4×
against 3.70×, `nqueens` 1.09× against 1.18×), which is the best evidence
available that the ports are faithful. **No geomean should be quoted from
this**: the spread is 120× wide and bimodal by design.

The `strings`/`strings2` pair survived, and it is the suite's only oracle that
does not rest on one implementation — two different codings of one computation,
returning one identical checksum, 13× apart in speed. `strings` is
**quarantined** (a leading `!` in `references.txt`): standalone it allocates
3064 KB at return against 90 KB with `-joff`, and the machine has 865–1024 KB
free, so it is expected to exhaust the machine. That is worth measuring and is
not worth measuring in the same run as the persist milestones, which run after
the suite. See `memory-accounting.md` §8a — the churn is charged through
`lj52_alloc`, which refuses rather than collecting, and LuaJIT has no emergency
GC where PUC does.

### Phase 1 RAN, 2026-09-04

Full record: [../../bench/results-in-machine-phase1-2026-09-04.md](../../bench/results-in-machine-phase1-2026-09-04.md).
78 runs, one benchmark per freshly booted 1 MB machine, three cells
interleaved, three replicates, every boot carrying a fixed 2M-iteration loop as
a box-speed meter.

**B/C is the clean compiler experiment** — same binary, same watchdog kernel,
same source, only `jit.off()` differing — and it reproduces the standalone
ratio where the work stays in the VM:

| | in-machine B/C | standalone -joff/compiled |
|---|---:|---:|
| sha256 | **22.6x** | 23.1x |
| mandelbrot | 5.13x | 5.49x |
| matmul | 4.79x | 6.12x |
| strings2 | 1.80x | 2.19x |
| nqueens | 1.44x | 0.66x (sign reverses, unexplained) |
| binarytrees | 1.08x | 1.27x |
| trampoline | 1.08x | 6.4x |

Against the PUC 5.2 a player runs today: mandelbrot **12.3x**, matmul
**11.0x**. (An earlier pass reported mandelbrot at 28x; that was two cells
landing in a fast box window, which is what the meter exists to catch.)

**The two rows that do not have a time are the more important ones.** `sieve`
fails on our native 6 runs out of 6 and runs on PUC in 2.6 s -- the
emergency-GC divergence of §8 with a control built in. And `strings` is
unrunnable with the compiler on and fine with it off, while its idiomatic twin
`strings2` -- identical checksum -- runs everywhere and is 1.80x faster under
that same compiler. See §8/§8a/§8b of memory-accounting.md.

**And the ceiling:** `trampoline` runs 0.62 s in-machine compiled against
0.051 s standalone interpreted, twelve times slower inside the sandbox than
outside it with the compiler off, while mandelbrot is the same in and out. For
`pcall`-heavy work the surcharge is paid outside the VM and no compiler
reaches it -- the same shape as Phase 0's component-call result.

**Phase 0's harness claims, superseded.** The harness carries the suite driver
(one benchmark per timer callback, so each gets a fresh 5 s deadline and an
overrun costs its own row rather than the run), the RAM guard, and an *encore*
probe that measures post-save recovery by riding on the feature under test: a
repeating timer holding a Lua closure is exactly what eris must serialise, so
it survives the persist and fires again unprompted, and Java compares the warm
samples with the first one whose sequence number advanced.

## 9. Interaction with memory accounting

Mild, and in our favour. Every design reviewed for the RAM cap flagged
"allocation from inside a compiled trace" as an unmeasured hazard. If traces
effectively never execute under an armed hook, that hazard is much smaller than
feared — but it is an accident, not a design, and it evaporates the moment this
is fixed. Do not lean on it.

Relatedly: JIT machine code is `VirtualAlloc`'d and never passes `g->allocf`
(`lj_mcode.c`, `maxmcode` 2048 KB at `lj_jit.h`), so the RAM cap is structurally
blind to it — up to 2 MB per state, which exceeds a 1 MB machine's entire
advertised RAM. Also currently masked by traces not running. Also should be
measured (`J->szallmcarea` after a boot) rather than assumed.
