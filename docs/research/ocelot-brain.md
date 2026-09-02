# ocelot-brain as a test harness and development environment

ocelot-brain (gitlab.com/cc-ru/ocelot/ocelot-brain, MIT) is OpenComputers
decoupled from Minecraft, as a JVM library, shipping Eris on Lua 5.2/5.3/5.4.
Evaluated 2026-09-01 as an answer to the project's structural weakness: every
verification claim we had was one step removed from reality, because we had
never run a real OpenComputers machine.

**Verdict: ADOPT.** It builds headless (sbt 2 + JDK 21), boots OpenOS from a
`main`, exposes a public unlocked architecture registry (`MachineAPI.add`), and
genuinely resumes a running machine mid-execution through the real Eris path.

## What to use it for

- Differential oracle against real Eris — highest value per unit of work; the only instrument that can compare our accept/refuse and post-restore observables against the genuine article on the same host, same workload, same save point
- Source of real machine states — the perms table, the kernel coroutine shape, the sandbox as machine.lua actually leaves it; replaces the invented corpus with measurements (I settled two census items in one 90-second run)
- Primary development environment for the Java/integration side — the 132-line stub becomes testable today instead of after a Minecraft round trip
- CI gate on persistence regressions — boot, run to a chosen instant, persist, restore, continue; fast enough with executionDelay:0
- Conformance harness for the Java perms flattener and the bit32 shim, checked against the live host tables rather than against our own reimplementation of them
- NOT for: energy, world-save timing/ordering, chunk unload, GTNH-specific subsystems, or anything Minecraft-lifecycle-shaped

## What it settled, empirically

I verified the load-bearing claims myself rather than accepting the arms' summaries, and the harness immediately paid for itself.

RAN: booted a real OC machine on ocelot-brain (Case T3 + CPU T3 + GPU + RAM + HDD + Lua BIOS + OpenOS floppy), forced it onto NativeLua52Architecture — GTNH's default Lua version — reflected into the live LuaState and read the real perms table. `_VERSION = "Lua+Eris 5.2"`, 165 perms entries. Probe at scratchpad/arm5/ob/src/main/scala/totoro/ocelot/arm5/Probe4.scala; log at tasks/bvtw4qj5b.output.

SETTLED EMPIRICALLY (roadmap M4 / census):
1. census N3, "stock OC's perms cannot persist an ipairs loop" — was a code-reading inference, is now a measurement. `perms[ipairs aux] = nil` on a live machine, while `perms[ipairs] = _G.ipairs`. I also measured that the aux IS a stable per-call object (`ipairs({}) == ipairs({})` is true), so it could be permed and simply isn't. Our Java flattener must sweep function-valued upvalues of named builtins. Confirmed.
2. census F, "whether the ipairs aux is absent from real perms" — closed, answer yes.
3. census N2, alias nondeterminism — real OC's flattener does sort (PersistenceAPI.scala, sorted-DFS with the explicit determinism comment; I read it), and on real OC 5.2 `unpack ~= table.unpack` (false), so the hazard does NOT exist on the host. It exists on OUR LuaJIT build, where they are rawequal. The sort is still mandatory in our Java flattener; the specific unpack collision is ours alone.
4. NEW, and neither arm found it, and it changes M4/M4.5: `perms[string.gmatch] = nil` on a live machine, while `perms[string] = _G.string` and `perms[string.format] = _G.string.format`. Cause: machine.lua:682-685 overwrites string.find/match/gmatch/gsub with its own Lua closures AFTER PersistenceAPI built perms. So on every real OC save those four platform functions are serialized as CODE, not resolved as permanents — they are in essentially every blob. And machine.lua:558-559 splits on `#s < SHORT_STRING` (500): short strings tail-return the native C iterator (unpersistable), long strings return a pure-Lua closure iterator (persistable). The gmatch refusal is therefore data-length-dependent, not categorical — a sharper statement than the census's.

CORRECTED (pluggable arm, "the stock build emits Java 17 bytecode"): ocelot-brain's Scala classes are major 52 (Java 8) — Scala 2.13 targets 8 by default. Its 19 Java sources are major 61, because build.sbt sets no javacOptions release. So the constraint is real but narrower and cheaper than stated: only the Java half needs `--release 8`, and our own javac output does.

CORROBORATED BY READING: the Architecture trait delta is exactly three items (recomputeMemory takes Iterable[Entity], plus abstract freeMemory/totalMemory); `includeLuaJ = !isAvailable || luajRequested`, so the silent-LuaJ-fallback hazard is real as described; and Machine.scala:800-814 has no java.lang.Integer case and falls through to `setByte(-1)`, so the queued-signal Integer loss is a genuine defect, confirmed at source.

## Residual risk -- what a green run does NOT prove

Name the gap precisely, because a good harness is dangerous exactly in proportion to how good it is.

1. THE HARNESS CAN LIE ONE WAY, SILENTLY. `includeLuaJ = !isAvailable` means a failed native load substitutes LuaJ, which has no Eris — every persistence test then passes vacuously. This is the single failure mode that produces false green. Non-negotiable mitigation: every harness entry point asserts `machine.architecture.isInstanceOf[NativeLuaArchitecture]` and dies loudly otherwise. My probe does this; make it a shared base class, not a convention.

2. VERSION, AND IT IS SUBTLER THAN "0.24.2 vs GTNH". ocelot-brain's default is Lua 5.3; GTNH's is 5.2; our target is LuaJIT with 5.1 semantics plus LUA52COMPAT. Three different languages. Pin NativeLua52Architecture for every comparison (I did) and treat any 5.3/5.4 result as inadmissible. Even 5.2 is not our semantics: my own measurement of `unpack ~= table.unpack` on the host versus rawequal on our build is a live example of the two diverging.

3. NOT MINECRAFT, so: no energy (power-loss crash/restore paths untestable), no SaveHandler deferral or world-save ordering (blobs go straight into NBT on the calling thread, so chunk-unload and save-ordering bugs cannot appear), no tile-entity lifecycle, no inventory/driver resolution — which is precisely the one method whose body differs between the two Architecture interfaces, so recomputeMemory is the piece the harness structurally cannot exercise.

4. NOT GTNH, so: `computer.realTime` and GTNH's non-machine subsystems are invisible. Low risk for persistence, non-zero for OS compatibility.

5. NOT DETERMINISTIC per tick. Lua runs on a thread pool against a wall clock, so "how far did it get" varies run to run. Saves cannot tear (Machine.save and Machine.run share the same lock), so "save at a chosen instant" works by waiting on a screen or state condition — but any test that counts ticks will flake, and a flaky persistence test is worse than none.

6. THREE OCELOT-BRAIN DEFECTS THAT WILL BE MISREAD AS OUR BUGS: the Integer signal loss (confirmed at Machine.scala:800-814), `new Memory(ExtendedTier.Creative)` throwing on insert, and brain.conf replacing rather than overriding config. Write them into the harness README on day one.

7. BUS FACTOR. Small team, bursty commits, three dependency jars fetched by direct URL from asie.pl. Pin the commit, vendor the jars.

8. The deepest one: a green ocelot-brain suite proves our architecture satisfies the contract and that machine.lua boots and persists on our VM. It cannot prove the two things the census says actually kill real machines — PatchGuard-style `tostring(f)` pointer fingerprinting and unrebased `computer.uptime()` deadlines. Those are true of real Eris too; the harness will show us passing exactly where stock OC also fails, which is comforting and irrelevant.

## Next step

Build the ocelot-brain adapter and stand up the differential rig. One to two days, in this order:

DAY 1, ~4 hours — the adapter. Split LuaJITArchitecture.java into a host-agnostic core plus two thin shells. The shells are ~60 lines each; the genuinely divergent code is four things: recomputeMemory's body (Iterable<Entity> with `case m: Memory => m.amount * 1024` versus stack→Driver.driverFor→driver.item.Memory), the two extra memory getters, the NBT blob write (direct setByteArray versus SaveHandler.scheduleSave), and the imports. Keep the @Architecture.Name annotation on the class — ocelot ignores it. Register with MachineAPI.add(clazz, "LuaJIT") and cpu.setArchitecture(clazz). Compile the shared core with --release 8 (and note that ocelot-brain's own Scala is already major 52; only its Java half is 61).

DAY 1, ~1 hour — the guard, before anything else runs. A harness base class that asserts NativeLuaArchitecture (or our own class) and pins NativeLua52Architecture for every comparison run. Without this the whole rig can go green for the wrong reason.

DAY 2, ~4 hours — the differential oracle. Probe3 and my Probe4 are already most of the instrument. Drive our architecture and NativeLua52Architecture through the same EEPROM/OS workload in the same host, snapshot at the same screen-state condition, and diff (a) accept versus refuse, (b) post-restore screen buffer, signal queue, component-call sequence, machine state, lastError. Seed it with the shapes the census already rates, starting with the four measurements above.

DAY 2, ~1 hour — port the two one-line-class fixes the census demands into the Java flattener while the live perms table is right there to check against: the sorted DFS, and the function-valued-upvalue sweep for the ipairs aux.

THEN, and this is the item I would add to the roadmap: re-census gmatch/find/match/gsub as machine.lua actually leaves them. They are Lua closures in every blob, and the SHORT_STRING=500 split makes the refusal data-dependent. Half a day, and it is the kind of thing only a real machine tells you.

Explicitly NOT next: touching Minecraft. Nothing on the v1 list except in-game validation needs it.

## Does it change earlier conclusions?

Three previous conclusions move.

1. "DEVELOP AGAINST MINECRAFT DIRECTLY" IS NOW THE WRONG DEFAULT, AND SHOULD BE INVERTED. The roadmap's v1 assumes the JNI bridge is validated in-game. It should be validated here and touch Minecraft only at the final in-game-validation line item. The reason is not convenience, it is epistemic: the project's stated problem is that every verification claim is one step removed from reality, and this closes that gap for the machine layer specifically — the layer where all our risk lives. Minecraft was never going to give us a differential oracle against real Eris; ocelot-brain does.

2. THE BRIDGE SPIKE'S "PLUMBING" VERDICT SURVIVES BUT GETS CHEAPER AND MORE PRECISE. The Architecture contract is not drop-in — three deltas, all mechanical — but it is one shared core with two shells, not two implementations, and the VM lives entirely inside the architecture with nothing above it touching Lua or Eris. Our CHECKHOOK watchdog stays our business, unchanged, on both hosts: neither codebase enforces timeout at the Machine level. The Java-17-bytecode blocker is smaller than reported: ocelot-brain's Scala is already Java 8, only its Java sources and our own javac output need --release 8.

3. TWO CENSUS ROWS AND ONE ROADMAP ITEM CHANGE STATUS. Census N3 moves from inference to measurement (ipairs aux confirmed absent from a live perms table). Census F loses one of its three unknowns. N2's blast radius shrinks on the host side and stays intact on ours — the unpack collision is a LuaJIT-build artifact, not an OC one, which means our own regression suite is the thing that is nondeterministic, exactly as suspected but now for a confirmed reason.

And one genuinely new item for M4/M4.5, which I would not have found by reading and which is the best single argument for adopting: machine.lua replaces string.find/match/gmatch/gsub AFTER perms is built, so those four are Lua closures in every real blob rather than permanents, and the gmatch refusal splits on string length at SHORT_STRING=500. The census treats gmatch as a categorical refusal. It is not. That correction came out of ninety seconds on a real machine, and it is the shape of finding this harness will keep producing.
