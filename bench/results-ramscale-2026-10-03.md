# The RAM scale, measured: OC's own is enough (2026-10-03)

**Decision: the LuaJIT architecture inherits OpenComputers' `ramScaleFor64Bit`, as OC's own
CPUs do; there is no override in `LuaJITArchitecture`. The harness, which had pinned 3.0
since 2026-09-03, now runs at OC's default 1.8.** At 1.8 a LuaJIT computer holds at least
what a stock PUC 5.2 computer holds in every measured cell but one (closures on a 1024 KB
stick, about 0.92-0.98x once stock's own holder-doubling refusal is allowed for), and up to
2.75x as much with no help from the JIT. The 2026-09-03
reading that OpenOS booted 1 time in 6 at 1.8 predates the emergency collector, the
per-machine arena and the shim-held accounting, and did not reproduce: the shipped
configuration booted OpenOS at 1.8 in every run on the 192, 256 and 1024 KB sticks.

What the measurement found instead is not a scale problem, and no scale fixes it: **at the
memory wall our machine fails where stock recovers.** A program that catches "not enough
memory" and drops its data has its own next allocation refused (PUC collects and retries
there; we refuse), or a refusal lands where none of the program's handlers catches it and
takes the machine down: 20 of our 60 runs (19 fills and one boot) against 0 of 20 on stock. And in the last quarter of
memory our emergency collector runs a full cycle at every checkpoint, so a filling program
runs 20-120x slower there than on stock. Both are the next roadmap item.

Two more findings, neither about memory: **MineOS does not boot on the architecture we
ship** (it tests `computer.getArchitecture() ~= "Lua 5.2"`, takes its Lua 5.3 code path
because we are named "LuaJIT", and that code cannot compile on LuaJIT), and `CensusOs`'s
verdict passed that run because it looks only for panic text.

All harness runs: ocelot-brain, JDK 8, launched pinned to the performance cores (`affrun
C03C03`), the shipping additive DLL `cb29485d` (= `build/native/dist`), the watchdog
kernel on ours and OC's own on stock. The object-size runs were standalone processes. Archive: [runs/2026-10-03-ramscale/](runs/2026-10-03-ramscale/).

## What OC's scale does, from the source

GTNH OpenComputers 1.12.55 sources (identical in 1.12.58), `NativeLuaArchitecture.scala`:

- `initialize()` sets `ramScale = ramScaleFor64Bit` for every 64-bit native architecture
  (`:317`); the setter `ramScale_$eq` is public at the JVM level, so a subclass could set
  its own value right after `super.initialize()` -- nothing reads the scale in between.
  Not needed, as it turned out.
- `kernelMemory` is measured once per boot, after a full collect at the kernel's first
  yield, before the BIOS or any OS runs (`:207-222`), and is granted **on top**:
  the cap is `kernelMemory + ceil(installed RAM x ramScale)` (`:158`). So the scale pays
  only for what the OS and programs allocate after that point. Our kernel being ~1.85x
  PUC's -- the basis of the ~3.3 that memory-accounting.md section 11 proposed -- is
  therefore not what the scale has to cover.
- The sandbox sees `computer.totalMemory() = (total - kernelMemory) / ramScale` and
  `freeMemory()` likewise (`ComputerAPI.scala:42-55`): the scale changes the real bytes
  behind the number, never the number. NBT stores `kernelMemory / ramScale` and restores
  it times the scale current at load; the scale itself is never saved.

## Object sizes, standalone

`bench/oc/checks/objsize.lua` on PUC 5.2.4 (built from `JNLua-Natives/lua/src`, mingw gcc
-O2) and on our LuaJIT build copy with `-joff`, bytes per live object after three full
collects, one run each:

| shape | PUC 5.2 | LuaJIT GC64 | ratio |
|---|---|---|---|
| empty table | 56 | 64 | 1.14 |
| array of 4 / 16 / 256 numbers | 120 / 312 / 4152 | 104 / 200 / 2120 | 0.87 / 0.64 / 0.51 |
| hash of 4 / 16 string keys | 216 / 696 | 160 / 448 | 0.74 / 0.64 |
| string of 8 / 32 / 256 bytes | 46 / 68 / 275 | 49 / 73 / 295 | 1.06-1.07 |
| closure, 1 / 3 fresh upvalues | 80 / 176 | 96 / 208 | 1.20 / 1.18 |
| suspended coroutine | 992 | 520 | 0.52 |
| record `{name=str, size=n, flags={..}}` | 354 | 300 | 0.85 |
| 126 of OpenOS's 127 sources, compiled (one fails on both VMs) | 738 862 | 506 804 | 0.69 |

LuaJIT's 8-byte values and smaller prototypes win overall. Caveats: the held slot is not
counted (16 B on PUC, 8 B on GC64); counting it, a held closure is 216 against 192 B (1.13:
LuaJIT fits 0.89x as many) and a held 32-byte string 80.7 against 84.5 B (0.96: it fits
1.05x as many). And in the machine, stock's per-string cost read ~35% above this file's
figure, unexplained. The table says where to look; the machine says what holds.

## The instrument: `OCLJ_PROBE=capacity`

A new harness mode (`test/native/OcljSmoke.scala`, `CapacityAutorunLua` and
`capacityProbe`). It boots OpenOS with a heartbeat-only autorun (the default autorun's
~42 KB of source would be a fifth of a 192 KB stick), with the boot waits 3000/2000 ticks
for every kernel so the arms are scored alike, then takes three readings in order:

- `CAP-IDLE`: the emergency collector's arms and trace flushes over 400 idle ticks;
- `CAP-LIVE`: three full collects on the raw state, then `used`, `kernelMemory` and
  `user = used - kernelMemory` -- works on stock PUC too, unlike MEM-1;
- `CAPACITY`: grow a held structure of one shape (`OCLJ_CAP_SHAPE`) 100 objects per resume,
  with one short-lived string of churn per object, until the allocator refuses; report the
  objects held at the caught refusal, the os.clock() time of the first and last five
  batches, and the collector's counters. Milestone `cap-1-refusal-caught-machine-survives`.

Four arms: **S** stock PUC 5.2; **D** ours as shipped; **E** ours with `OCLJ_JIT_EARLY=off`
(`test/native/OcljArch.scala`: the compiler off through kernel init, so `kernelMemory`
holds no trace metadata, then on again once it is taken); **O** ours with the JIT off
throughout. Direction check: at scale 1.0 on 192 KB stock failed to boot ("not enough
memory") and D held 775 records against 1031-1259 at 1.8.

## Results at OC's 1.8

82 runs, 2026-10-03 20:55-22:22, three replicates on 192 KB and one on 256 and 1024 KB.
The full tables, with every run classified, are
[runs/2026-10-03-ramscale/chain1-tables.md](runs/2026-10-03-ramscale/chain1-tables.md).

**Outcomes.** A *clean* fill ends in a caught refusal with the machine running.
*Recovery refused*: the program caught the refusal and dropped its data, and its own next
allocation was refused. *Down*: a refusal took the machine down.

| stick | arm | clean | recovery refused | machine down | boot failed |
|---|---|---|---|---|---|
| 192 KB | S / D / E / O | 12 / 9 / 5 / 10 | 0 / 3 / 3 / 2 | 0 / 0 / 3 / 0 | 0 / 0 / 1 / 0 |
| 256 KB | S / D / E / O | 4 / 2 / 2 / 3 | 0 / 2 / 1 / 0 | 0 / 0 / 1 / 1 | 0 |
| 1024 KB | S / D / E / O | 4 / 4 / 2 / 3 | 0 / 0 / 0 / 1 | 0 / 0 / 2 / 0 | 0 |

**Objects held at the refusal, clean runs, median, over stock's:**

| stick | shape | stock | D/S | E/S | O/S |
|---|---|---|---|---|---|
| 192 KB | record / array / string / closure | 262 / 287 / 1024 / 508 | 4.37 / 5.46 / 4.49 / 3.10 | 1.93 / 2.55 / 1.95 / 1.37 | 2.09 / 2.75 / 2.00 / 1.49 |
| 256 KB | record / array / string / closure | 536 / 533 / 2048 / 1039 | - / - / 2.77 / 1.97 | 1.61 / - / 1.42 / - | - / 2.51 / 1.42 / 1.24 |
| 1024 KB | record / array / string / closure | 4255 / 4440 / 14822 / 8192 | 1.42 / 2.03 / 1.61 / 1.01 | 1.28 / 1.82 / - / - | - / 1.82 / 1.34 / 0.95 |

(`-`: no clean run in that cell.) Stock's 8192 closures is a refusal of the holder array
doubling (2^13, 23 KB still free), so its closure capacity is understated by roughly 240,
which puts the 1024 KB closure cell at about 0.92 (O) to 0.98 (D). Several other cells
sit on the same power-of-two ceiling -- stock's 1024 and 2048 strings at 192 and 256 KB
(4 and 10 KB still free), O's 2048 strings at 192 KB, D's 2048 closures at 256 KB -- so
their ratios are quantised and the stock-side ones run ~5-10% high; no cell crosses 1.

**The post-boot live set** (`user`, after three collects): stock 256 KB at every stick,
ours with the JIT off 188 KB, ours with the JIT on only after kernel init (E) 201-302 KB.
Stock's `kernelMemory` is 174 605 B in every run; ours with no kernel-init traces (E, O)
164 393 B in every run.
**Ours as shipped (D) has a `kernelMemory` of 335 513-413 193 B, bimodal**: kernel init
compiles traces, they are counted in `kernelMemory` -- which OC grants on top -- and the
pressure flush later releases them while the grant stays. That windfall is all of D's lead
over E and O on the small sticks, and D's capacity follows its `kernelMemory` run by run,
so it is not counted toward parity here. Every run was pinned; whether the windfall moves
with host speed (the loop that compiles it is wall-clock bounded) was not tested.

## What it found instead

**1. The wall.** The probe's own recovery path shows the mechanism: after the batch's
refusal is caught, the program sets two numbers, drops `held`, then builds one short
string. On PUC that allocation fails, `luaM_realloc_` runs a full collection (which frees
`held`) and retries (`lmem.c:85-93`); our allocator refuses and only arms the collector for
the next checkpoint (`lj52shim.c:378-381`, `:440-447`). All 12 "recovery refused" runs
show exactly that signature (`OCLJCAPF` written, the `done` row not), and the 8 failures
that have a clean run to compare with failed at that run's holding count. The 7
machine-down runs show no sign the program reached its recovery path: a refusal was raised
where none of the program's handlers caught it -- OpenOS's dispatcher, the kernel, or the
probe's own unprotected allocations between batches; the logs do not say which. This is the residual memory-accounting.md records as "narrowed, not
closed" (live + the burst between safepoints, against PUC's live + one allocation), and
the probe shows it is not rare. Both modes persist at 1024 KB, where a program has about
10x the room it has at 192 KB (E, O); a larger scale moves the wall and changes nothing at
it.

**2. The last quarter.** Once the heap after a cycle stays above `total - max(total/4,
128 KB)`, the shim re-arms a full cycle at every checkpoint after an allocation
(`lj52_gc_pressure`). The last five batches, clean runs, against stock's: 30-103x at 192
KB, 21-62x at 256 KB, 30-121x at 1024 KB -- with the JIT off as much as on, so it is the
collector, not trace flushing. (At 192 KB stock's record and array fills ran only three
batches, so their 'last five' is three batches and those cells' ratios run high; the range
endpoints come from cells where stock ran at least six.) The cost grows with the heap, so a larger scale makes it
worse for a program that fills memory.

**3. Idle on a small stick.** On 192 KB the arm whose `kernelMemory` holds no traces (E)
sits within 4-22 KB of the
collector's 128 KiB watermark floor after boot: 1390-2964 arms and 16-29 trace flushes in
a 10 s idle window, against 0-20 and 0 for D and ~60 and 0 for O. E also failed one boot
in 12 at 192 KB. The shipped configuration does not see this because of the windfall
above; a host on which kernel init compiles fewer traces would.

**4. A code reading, not observed:** an arm that lands mid-sweep reaches `GCSpause`
without `atomic()`, so the latch stays armed while `lj_gc_step` has just set the threshold
to twice the estimate; with the estimate above half the cap the collector can sit parked
until a refusal, the kernel's every-tenth-resume collect, or the 65 536-call bailout.

## The census OSes at 1.8

`test/native/census-os.sh`, 14 000 ticks, a fresh copy of each OS tree per run:

| OS, RAM | stock PUC 5.2 | ours |
|---|---|---|
| AxisOS, 1 x 1024 KB | could not parse PatchGuard (`patchguard:204: 'end' expected near '~'`) and booted without it; `PANIC: not enough memory` loading the GDI after the scheduler hand-off (23.3 s); peak 2 051 197 B of 2 062 042 | loaded PatchGuard; `PANIC: not enough memory` inside its Tier3 file hashing (20.5 s), before any scheduler hand-off; peak 1 655 964 B of 2 222 630, 1 refusal |
| MineOS, 2 x 1024 KB (its declared floor) | running, no error on screen (78 glyphs, 7 colours; whether that is the finished desktop was not checked), peak 3 688 906 B of 3 949 479 | **dies at boot**: `/Libraries/Color.lua:63: attempt to call a nil value`; peak 1 031 222 B of 4 178 707 |

The two AxisOS boots did different work, so they do not compare like for like. Stock, at
11 KB from its cap, is shown to need more than one stick at 1.8. Ours is not: it was
refused once, with about a quarter of its cap free at the last sample, inside a hashing
loop -- which reads more like the collector-at-the-wall problem than like a lack of memory.
MineOS's failure is the architecture
name: `Color.lua:11` tests `computer.getArchitecture() ~= "Lua 5.2"`, so on "LuaJIT" it
loads its Lua 5.3 bitwise code, which LuaJIT cannot compile. The 2026-09-15 census ran
MineOS on the dropin arm, which reports "Lua 5.2", so the shipped architecture had never
booted it. `CensusOs` scored that run `no panic text on screen`: its verdict does not look
for a stack traceback.

## Validation: the full suite at 1.8

The default harness run (1024 KB stick, every benchmark, every milestone) at the new
default scale, pinned, 2026-10-03 23:55-00:06 ([runs/2026-10-03-ramscale/chain3.log](runs/2026-10-03-ramscale/chain3.log),
[chain4.log](runs/2026-10-03-ramscale/chain4.log)):

| arm | checks | failures |
|---|---|---|
| ours, JIT on | 65 | 1, then 0 and 0 |
| ours, JIT off | 63 | 0 |
| ours, sieve only | 59 | 0 |
| stock PUC 5.2 | 47 | 0 |

The one failure was `mem-2-pressure-flushes-traces`, and it was the milestone's own clause,
not the flush. The flush ran 117 times and took the live trace count from 497 to a minimum
of 1. But the clause demanded a read of exactly 0 while the program ran, and a read lands
between resumes, after the last resume may have recompiled a trace. That race had been lost
once before at 3.0: an earlier 2026-10-03 run flushed 78 times and read a minimum of 1
([logs/prior-accsync-h1-j1-no-freemem-override.log](runs/2026-10-03-ramscale/logs/prior-accsync-h1-j1-no-freemem-override.log)).
The clause now accepts a read of at most max(2, 5% of the count before). A working flush
reads a minimum of 0-1. The runs whose flush never happened (the `h-j3` sabotage, settotal
not forwarded: [logs/prior-accsync-h1-j3-settotal-not-forwarded.log](runs/2026-10-03-ramscale/logs/prior-accsync-h1-j3-settotal-not-forwarded.log)
and its h2 twin) read a minimum of 498, so the new clause fails them. That was evaluated
on their logged values, not run, and those runs also fail the first clause (0 flushes):
nothing yet shows the near-empty clause failing on its own. On the new clause both reruns
pass. One of them again never read 0 (minimum 1, 122 flushes), so the old clause would have
failed it too; the failing run had overlapped a one-second unpinned process, this one did
not. The sieve-only run compiled the old clause and happened to read 0 seven times. The
RAM guard, which runs on our arms only, skipped no benchmark row at 1.8.

## What changed

- `test/native/smoke-test.sh`: `OCLJ_RAM_SCALE` defaults to 1.8 (was 3.0); memory figures
  from earlier runs are not comparable with later ones.
- `test/native/OcljSmoke.scala`: `OCLJ_PROBE=capacity` and `OCLJ_CAP_SHAPE`;
  `test/native/OcljArch.scala`: `OCLJ_JIT_EARLY=off` (harness only, the mod has no such
  switch).
- `bench/oc/checks/objsize.lua`.
- No change to `LuaJITArchitecture`, the shim or the kernel.

## Reproduce

```sh
# one capacity run (runs/2026-10-03-ramscale/scripts/cap.sh has the full environment;
# the scripts hard-code this session's scratchpad paths for affrun.exe and OCLJ_LIBS)
OCLJ_PROBE=capacity OCLJ_CAP_SHAPE=record OCLJ_RAM_TIER=one OCLJ_RAM_SCALE=1.8 \
OCLJ_NATIVE=additive OCLJ_KERNEL=watchdog OCLJ_JIT=on sh test/native/smoke-test.sh
# the matrix: scripts/chain1.sh; the tables: scripts/analyze.py chain1.log
<vm> bench/oc/checks/objsize.lua <openos-dir>
```
