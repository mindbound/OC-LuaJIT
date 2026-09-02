# OS shape census: what Lua shapes real OpenComputers systems produce

Two real operating systems -- QuickOS (an OpenOS derivative) and axis-os (built
from scratch, architecturally unlike OpenOS) -- plus the OpenComputers API
itself, censused for shapes that touch the serializer contract. Risky shapes
were reproduced standalone and RUN against the real serializer rather than
reasoned about. 2026-09-01.

This replaces "does OpenOS work" as the test target.

## The shape space

CONSOLIDATED SHAPE SPACE — the test target that replaces "does OpenOS work". Verdicts are against eris-lj 0.3 (M3, format 2) on LuaJIT 2.1.1787165859 built with -DLUAJIT_ENABLE_LUA52COMPAT (prototype/watchdog/Makefile:16-17). Four classes: HANDLED (exact), SEMANTICS-CHANGE (loads, meaning differs), REFUSED (save raises, computer comes back off), SILENT-GAP (saves and loads, resumes wrong).

== A. VALUES ==
HANDLED: nil/boolean/number/string (embedded NULs, 100KB); tables with metatables, cycles, shared refs; __metatable protection (round-trips as the lie, e.g. "file"/"userdata"); __mode preserved so weak tables become weak again; the spkey/__persist protocol; Lua closures with upvalue IDENTITY across closures and with function environments; setfenv/getfenv-built envs; dead threads normalised; bit.* results; table.new/table.clear results; the `jit` table; a bare closure or table as the persist root (OC's SynchronizedCall/Return save points).
SEMANTICS-CHANGE: weak tables are persisted STRONGLY — one-shot resurrection with original identity, then weakness resumes (measured: __mode='k' with 8 dead thread keys goes 8->0 on the first gc after restore). Tables carrying __gc persist and __gc comes back as a function, but LuaJIT finalizes only userdata/cdata — I measured 0 firings in 200 tables even under 5.2 compat, so machine.lua's entire sgc/sgcco apparatus (machine.lua:699-729, 776-808) is dead code on this arch and userdataWrapper.__gc (machine.lua:1124-1128) never calls Java-side Value.dispose(): every component userdata leaks host-side until the machine closes.
REFUSED: userdata of any kind (wire tag 14 reserved, unimplemented) including newproxy and string.buffer objects; cdata of any kind including a bare `1LL` literal; light userdata; any C function not in perms — which in practice means C CLOSURES MINTED AT RUNTIME, of which ordinary code produces exactly two: native string.gmatch iterators and raw coroutine.wrap wrappers.
SILENT-GAP: math.random's PRNG state lives in a userdata upvalue of the builtin (lib_math.c:135,186); math.random is a perms entry so it is never traversed and the state is never saved. Every program's random stream restarts on world reload.

== B. THREADS AND FRAMES ==
HANDLED: suspended threads with slots, frame chains, open upvalues aliasing live frames, FR_LUA/FR_C/FR_CP/FR_VARG/FR_PCALL frames, continuation frames from metamethods; nested coroutine chains 6 deep with thread objects travelling as yield values; recursion depth 2000 (34.7KB); a thread that is an interior node of its own graph and a table key (AxisOS kernel.tProcessTable[0].co = coroutine.running()) — fine under OC's host-drives-a-coroutine pattern.
REFUSED: the running thread; the main thread; a thread with cframe != NULL (running or resuming another) — measured refused both as a direct root and via a whole-machine root; interior C frames; a thread yielded from inside a debug hook; FFI continuations; unknown continuations; a pcall frame entered inside a hook.
Every thread-level refusal is UNREACHABLE in stock OC, and that is structural, not luck: the yield-pump invariant (no thread is ever mid-resume at a yield) is independently re-implemented at four layers — host machine.lua:848-856, QuickOS pipe.lua:28-42, QuickOS process.lua:143-156, AxisOS's own scheduler — because OC yields do not cross coroutine boundaries. AxisOS's kernel_host_yield (kernel.lua:2548, exposed to rings 0/1, called by nothing) is the one loaded gun that would break it.

== C. YIELD CONTEXTS (what LuaJIT even permits) ==
The generalisation: LuaJIT permits a yield through a Lua-level METAMETHOD dispatch (continuation frame) and refuses one through a C function that calls back into Lua. So "yield inside a metamethod" is an everyday shape; "yield inside a C-driven callback" is not a shape at all.
HANDLED: plain yield; inside pcall; inside an xpcall'd function, with debug.traceback (a C function) live in the handler slot; inside __index/__newindex/__call/__add/__concat/__eq/__lt; inside __tostring via tostring(); inside a pure-Lua gsub callback (OC's own pattern port, #s>=500); inside a vararg frame; inside a load()ed chunk; from a coroutine resumed by another with sysyield bubbling.
CANNOT OCCUR (so the matching refusals are correct backstops, not live risk): inside the xpcall message handler; inside __tostring via string.format("%s"); inside table.sort's comparator; inside a native string.gsub callback; inside a debug hook; inside an FFI callback; inside a table __gc finalizer.

== D. GENERIC FOR-IN — the whole ballgame ==
HANDLED, exact: `for k,v in pairs(t)` and `for k,v in next,t` — the replay iterator snapshots unvisited keys instead of carrying a hash position (1088 fresh-process restores, exact key multiset every time; the negative control diverges in 60+/64). Delete-as-you-go works. `for i,v in ipairs(t)` — the control is an integer — PROVIDED the ipairs aux is in perms.
HANDLED: a for-in whose iterator is a pure-Lua closure with its own state (AxisOS's replacement ipairs, kernel.lua:1786-1790; OC's internet response __call iterator with the yield INSIDE the iterator, internet.lua:34-62 / wget's `for chunk in response do` — every chunk delivered exactly once).
REFUSED: `for w in s:gmatch(p)` where #s < 500 — machine.lua:554-560 delegates to native gmatch below SHORT_STRING, and a native gmatch iterator is a fresh C closure per call, unreachable by any perms sweep. Same source line succeeds above 500 chars. Also: holding a gmatch iterator in a live local across a yield.
REFUSED: `for _,v in ipairs(t)` under a naive perms table, because the ipairs aux is a hidden C singleton no name in _G reaches. Fixed by sweeping function-valued upvalues of every named builtin (exactly two objects on this build: `next` and the aux). Real OC's PersistenceAPI.scala does NOT do this sweep, so the refusal is live against stock OC, on QuickOS's boot path (base.lua:440).
SILENT-GAP (the residual, deliberately not closed because it is not soundly distinguishable from a legitimate custom iterator): a for-in whose iterator is a LUA CLOSURE, or a TABLE with __call, WRAPPING next. Its ffid is not FF_next_N so the scan cannot see it, yet its control slot carries the same hash-layout dependence. Four realisations, two of them in the platform:
  - component.list() — machine.lua:1309-1319, a __call table over a next-closure with a `key` upvalue. Measured 18/20 and 20/20 pads wrong; one pad visited exactly the right COUNT while having dropped 3 components and duplicated 3.
  - componentProxy.__pairs — machine.lua:1269-1282, a two-phase closure walking self then self.fields with three mutable upvalues. Measured 20/20 pads wrong, losing AND duplicating simultaneously. NEW: I measured that our build honours __pairs (5.2 compat is on), so this is live code on our arch, not the dead code an earlier arm assumed.
  - an OS's own such iterator, e.g. lua_shell.lua:17-30 reassigning its own `t` upvalue across env -> _ENV -> package.loaded mid-walk: 20/20 wrong, the only case with no passing pad.
  - the benign member: QuickOS filesystem.list (lib/filesystem.lua:261-265) deletes the key it returns and restarts from the head, so a rehash reorders but every entry is visited exactly once — 20/20 exact. Membership-safe, order-divergent.
REFUSED rather than guessed: a frame whose bytecode position cannot be recovered while holding an unmarked (next, table, key) triple.
Numeric for, while, repeat: fine.

== E. THINGS THAT ARE NOT LUA SHAPES BUT DECIDE THE OUTCOME ==
SILENT-GAP: function POINTER IDENTITY. We preserve function identity; nothing preserves `tostring(f)`. AxisOS's PatchGuard snapshots tostring() of every kernel function and re-checks on nearly every scheduler pass (patchguard.lua:241/657/1054); a mismatch bugchecks into a permanent halt loop. Measured primitive: a Lua closure's tostring() changes across a round trip in-process and cross-process; a permed builtin's does not. So the save succeeds, the blob is correct, and the machine comes back and immediately halts. This is the only defeat in the census that costs the user their computer with no serializer defect at all.
SILENT-GAP: ABSOLUTE TIME. Every OS with timeouts computes deadlines from raw computer.uptime() and nothing rebases them. If uptime advances across the save, every in-flight IPC wait, connect timeout and idle warner fires at once on the first post-restore pass; if it resets to zero, every waiter hangs forever with no log line at all. Neither is a serializer failure and neither is fixable in the serializer.
REFUSED (host-side, mine, new): a perms table built by a naive pairs() walk of _G is NOT stable across processes. `unpack` and `table.unpack` are the same object; which dotted name wins depends on the per-process string-hash seed. Measured 11/12 vs 1/12 on the name, and 5/10 fresh-process loads failing with "unknown permanent (not in the perms table)" — a correct blob that cannot be read. Exactly 3 ambiguous objects exist in a bare _G (_G/_G._G, package.loaders/package.searchers, unpack/table.unpack). Real OC is immune: PersistenceAPI.scala:60-72 sorts child keys with an explicit determinism comment. But OUR harness (serializer/tests/m3.lua:21-61) uses the naive form, so our own regression suite is nondeterministic, and the Java flattener we have to write for the LuaJIT arch must copy the sort.

== F. STILL UNKNOWN ==
Whether a restored table's __gc would ever fire if we later enabled table finalizers (untested; moot while LuaJIT doesn't). Whether debug-hook state survives a round trip (not a well-formed question on LuaJIT — hooks are VM-global, not per-thread — but it means the CHECKHOOK watchdog's armed state is not preserved and silently disarms on load). Whether OC mints a fresh Java Value userdata per call, which would make perms useless for userdata the way it is for gmatch. Nothing else in the OC-forced space is both constructible and untested.

## What the real systems produced that our invented corpus did not

WHAT THE REAL OPERATING SYSTEMS PRODUCED THAT OUR INVENTED CORPUS DID NOT — six things, then three new measurements of my own.

1. THE YIELD-POINT PREMISE WAS WRONG, AND IT IS WHAT MAKES THE FOR-IN GAPS REACHABLE. Our corpus assumed pullSignal is the save point. QuickOS has five or six distinct ones, and the decisive one is machine.lua:1080-1103: EVERY indirect component call does `coroutine.yield(function() ... end)`. So saves land inside gpu.set during terminal output, inside fs.list during a directory listing, inside getKeyboards. That is precisely what converts an innocuous `for k,v in pairs(t) do io.write(...) end` (bin/components.lua:24-25, bin/ps.lua:144) or `for name in fs.list(p) do` into a for-in loop with a yield in the body. An invented corpus writes `coroutine.yield()` where the author chose to; a real OS puts a yield under every print statement.

2. THE DANGEROUS ITERATORS ARE IN THE PLATFORM, NOT IN ANY OS. Neither OS wrote component.list's __call-over-next or componentProxy.__pairs. Both inherit them from machine.lua. This is the finding that changes our test strategy: auditing an operating system cannot discover either defect, because the defect ships with OpenComputers. It is also why the fix is cheap — one library line, not a serializer feature.

3. SOURCE-LEVEL PREEMPTION MAKES THE YIELD CENSUS A WHOLE-LANGUAGE CENSUS. AxisOS's preempt.lua rewrites every ring>=2.5 program, injecting a yield checkpoint after every do/then/else/repeat and at every function entry. The population of "what can be on a suspended stack" is therefore not the yield sites the author wrote — it is every basic-block boundary in every program. Our corpus enumerated syntactic contexts one at a time; AxisOS makes all of them simultaneously live. It is also what makes the gmatch refusal routine rather than exotic: the shell's PATH loop becomes `for d in gmatch(PATH,"[^:]+") do _pc(); ...`, and a player typing a command while the world saves is enough to lose the machine.

4. REAL OSes DEFINE CORRECTNESS IN TERMS OF PROPERTIES A SERIALIZER NECESSARILY BREAKS. Two of them, neither a Lua shape, neither in any corpus we would have invented: pointer stability (AxisOS's PatchGuard fingerprints kernel functions by tostring(f) and bugchecks on mismatch — the save is perfect and the machine halts permanently), and absolute time (an entire timing layer of unrebased computer.uptime() deltas, which after a save either fires every timeout at once or hangs every waiter forever). We were testing "can we round-trip the graph". The OSes were asking "is the machine still itself".

5. THE INVARIANT THAT SAVES US IS DESIGNED, NOT LUCKY. Our corpus treated "no thread is mid-resume at a save" as a happy accident. It is re-implemented independently at four layers (host machine.lua:848-856, QuickOS pipe.lua:28-42 and process.lua:143-156, AxisOS's scheduler) for the same reason: OC yields do not cross coroutine boundaries, so every level must hand-pump. That makes it a property we can rely on and state as a contract, not a coincidence to hedge against — and it tells us exactly which future change would void it (AxisOS's unused kernel_host_yield, kernel.lua:2548).

6. OC'S AUTHORS ALREADY WROTE CODE AROUND A SERIALIZER. machine.lua:1086/1097/1109 explicitly nil out upvalues with the comment "avoids trying to persist it"; machine.lua:1055-1067 and 1134-1142 use persistKey/__persist as the escape hatch that hides raw userdata behind a weak table. Our spkey support is not a nice-to-have — it is the interface OpenComputers already expects. Relatedly, three layers lie about metatables (__metatable="file" on every QuickOS buffer, "userdata" on every host proxy, and sandbox.getmetatable returning mt.mt), so any part of our persist logic written in Lua rather than C will be fooled; ours is in C, which is now a load-bearing reason rather than an implementation detail.

--- NEW MEASUREMENTS (mine, this session, against serializer/erislj_test.exe) ---

N1. OUR BUILD HONOURS __pairs, AND THAT PROMOTES A GAP FROM DEAD TO LIVE. The OC-API arm's checklist row says "__len / __pairs — LuaJIT does not honour these on tables at all". That is false for us: prototype/watchdog/Makefile:16-17 sets -DLUAJIT_ENABLE_LUA52COMPAT on BOTH the stock and checkhook variants, and I measured __pairs, __ipairs and __len on tables all firing. Consequence: machine.lua:1269-1282's componentProxy.__pairs is live code on our architecture, and `for k,v in pairs(proxy)` takes the silent-gap path. Measured, 6 fresh-process restores of a coroutine suspended 3 keys into a 12-key walk: the __pairs-returns-a-closure-over-next form gave 10, 11, 12, 12, 14-with-2-duplicates, 14-with-2-duplicates; the __pairs-returns-raw-`next,t,nil` form gave 12/12 exact with identical order, six times out of six. That is the recommended sandbox constraint validated directly, and it is a one-line change.

N2. THE PERMS-NONDETERMINISM FINDING REPRODUCES, BUT IT IS OUR BUG, NOT OC'S — AND THAT MATTERS MORE, NOT LESS. `unpack` and `table.unpack` are rawequal on this build. Under a naive pairs()-walk flattener the winning dotted name flipped 11/12 vs 1/12 across fresh processes, and a blob holding that builtin as a live value failed to load in 5 of 10 fresh processes with "eris-lj: unknown permanent (not in the perms table)" — a correct blob that is unreadable, which is the write-only-save-data class this project already rated critical once. But real OC is immune: PersistenceAPI.scala:60-72 collects child keys, sorts them, and recurses in sorted order, with the comment "Enforce a deterministic order ... to ensure the keys are the same when unpersisting again". So the defect lives in serializer/tests/m3.lua:21-61 (our own build_perms) — meaning our regression suite is nondeterministic today — and it will live in the Java flattener we must write for the LuaJIT arch unless we copy that sort. Blast radius is small and enumerable: exactly 3 ambiguous objects in a bare _G (_G/_G._G, package.loaders/package.searchers, unpack/table.unpack), plus whatever aliases OC's own injected tables add.

N3. STOCK OC'S PERMS CANNOT PERSIST AN ipairs LOOP. Reading PersistenceAPI.scala confirms it does the sorted DFS but does NOT sweep the function-valued upvalues of named builtins. The ipairs aux is therefore absent from real OC's perms, so `for _,run in ipairs(pendingAutoruns) do xpcall(shell.execute, ...) end` — QuickOS base.lua:440, on the boot path — is a hard save failure against the real host, not just against our test harness. The fix is the arm already in serializer/tests/m3.lua:48-59 and it needs to be ported into the Java side, alongside the sort. Two independent one-line-class fixes, both required, neither optional.

Also confirmed incidentally: 0 __gc firings in 200 tables even under 5.2 compat, so machine.lua's sandboxed-finalizer machinery is inert and Java-side Value.dispose() never runs — a host-side leak that is not a persistence bug but is caused by the same VM property.

## Ranked by probability x badness

- 1. SILENT — component.list()'s __call-over-next iterator (machine.lua:1309-1319). Probability ~1: it is the canonical OC idiom, on QuickOS's boot path at base.lua:530 where it emits every component_added signal, at 9 further QuickOS call sites, and at AxisOS kernel.lua:332/354/666. Badness maximal: measured 18/20 and 20/20 pads visiting the wrong key multiset, and one pad visited the RIGHT COUNT while having dropped 3 components and duplicated 3 — a world where the OS's device table quietly disagrees with reality and nothing ever reports an error. FIX: change libcomponent.list to return `next, list, nil` (or snapshot addresses into an array). One line in machine.lua, no serializer change; the pairs() contrast test is 16/16 exact vs 15/16 diverging.
- 2. REFUSED — the ipairs aux is not in real OC's perms (PersistenceAPI.scala does the sorted DFS but no builtin-upvalue sweep). Probability ~1: `for _,run in ipairs(pendingAutoruns) do xpcall(shell.execute,...) end` is QuickOS base.lua:440, on the boot path, and ipairs-with-a-yield-in-the-body appears in dozens of places once you accept that io.write yields. Badness: save fails, computer comes back switched off. Ranked above the other refusals only because its probability is 1 and its fix is the smallest in this list. FIX: port the m3.lua:48-59 upvalue sweep into the Java flattener; two objects on this build (`next` and the aux). Measured working both ways (named sweep, and one explicit perms entry).
- 3. SILENT — componentProxy.__pairs (machine.lua:1269-1282), a two-phase closure over next with three mutable upvalues. NEWLY PROMOTED: I measured that our build sets -DLUAJIT_ENABLE_LUA52COMPAT so __pairs really is honoured, refuting the earlier assumption that this was dead code on LuaJIT. Probability moderate (fewer call sites than list(), but `for k,v in pairs(proxy)` is ordinary), badness worse than #1 — most pads lose AND duplicate simultaneously, which is the phase flag flipping at the wrong moment. FIX: make it `return next, self, nil`, or delete it and pre-flatten fields into the proxy. Measured 6/6 exact after the fix vs 4/6 wrong before.
- 4. REFUSED — `for w in s:gmatch(p) do <yield> end` with #s < 500 (machine.lua:554-560 delegates below SHORT_STRING to native gmatch, whose iterator is a fresh C closure). Probability high and rising: it is the shell's PATH split (AxisOS sh.lua:145/236), and under source-level preemption instrumentation the first statement of EVERY gmatch body is a yield, so a player typing a command during a world save loses the machine. Badness: refusal. Uniquely nasty because the same source line succeeds above 500 characters, so it is untestable by inspection. FIX: put the pure-Lua gmatch on the sandbox unconditionally, or set SHORT_STRING to 0.
- 5. SILENT — unrebased computer.uptime() deadlines. Probability ~1 for any OS with timeouts (AxisOS's watchdog, IPC waits, swap eviction, connect deadlines; QuickOS's event timers). Badness high and bimodal: if uptime advances across the save, every in-flight wait fires at once on the first post-restore pass; if it resets, every waiter hangs forever with no log line at all. Not a serializer defect — the scheduler state round-trips perfectly — which is exactly why it will not be caught by any serializer test. FIX is architectural: freeze uptime across the save, or push a resumed/uptime_shift signal so an OS can rebase. Stock OC does neither.
- 6. REFUSED — our own perms flattener is nondeterministic across processes. Measured: `unpack`/`table.unpack` are the same object, the winning name flipped 11/12 vs 1/12, and 5 of 10 fresh-process loads failed with 'unknown permanent'. Probability 1 in our harness TODAY (serializer/tests/m3.lua:21-61 uses the naive walk, so the regression suite is nondeterministic and can mask or invent failures); probability 0 against real OC, which sorts. Badness: write-only save data, the class this project already rated critical once. FIX: copy PersistenceAPI.scala:60-72's sorted DFS into the Java flattener AND into m3.lua. Only 3 ambiguous objects exist in a bare _G, so the fix is complete, not best-effort.
- 7. SILENT — math.random's PRNG state is never saved (it lives in a userdata upvalue of the builtin, which is a permanent and therefore never traversed). Probability 1, badness low-to-medium: nobody's world is corrupted, but every program that relies on a seeded stream diverges after a reload, silently. Ranked here rather than lower because it is unfixable in Lua and needs a host-side hook that must be designed now. FIX: have the architecture snapshot and restore the PRNG state alongside the blob.
- 8. REFUSED — raw userdata live at a save: OC internet handles and data-card ECDSA keys held across a yield (AxisOS internet.sys.lua:112-146/288-300, crypto.lua:97/138). Probability low in stock OC (machine.lua wraps every Value into a table proxy before user code sees it) but 1 for any OS that keeps a handle across a yield, which HTTP inherently does — every in-flight request is an unsavable interval. Badness: refusal. Measured refused as a suspended stack, as module state, and as a whole-machine root. FIX is not ours: document the pattern, and give the sandbox a __persist-backed handle wrapper (measured working: a __persist table hides the userdata from the walker; __persist on a userdata METATABLE is ignored and still refuses).
- 9. SILENT — an OS's own Lua-closure-over-next iterator (QuickOS lua_shell.lua:17-30 reassigning its `t` upvalue across env -> _ENV -> package.loaded mid-walk: 20/20 pads wrong, the only case with no passing pad). Probability OS-specific, badness high. We cannot fix this: it is not soundly distinguishable from a legitimate custom iterator with its own ordering, and rewriting the latter would silently change its semantics. What we CAN do is stop generating the shape ourselves (#1, #3) so the only remaining instances are the OS author's, then give them a diagnostic: an opt-in save-time warning when a for-in's iterator is a Lua closure whose body reaches `next` on its own loop state.
- 10. SILENT — assumptions about pointer identity and process-local addresses (AxisOS PatchGuard's tostring(f) fingerprints: save succeeds, blob is correct, machine comes back and bugchecks into a permanent halt). Probability OS-specific and low today, badness total. Unfixable by construction — a serializer is guaranteed to break address strings — so the only response is a written contract: 'function identity is preserved; function ADDRESSES are not, and neither is any string derived from one'. Ranked last because it is a documentation deliverable, not an engineering one, but it must ship WITH the feature, because an OS author who learns it afterwards has already shipped the bugcheck.

## Userdata

NO — userdata does not block us, and the reason is structural rather than lucky: OpenComputers already treats userdata as unpersistable and built the wrapping to prove it. But the answer splits three ways and the third part is the one that needs a decision.

(1) HOST-INJECTED GLOBALS: not userdata at all, and open-and-shut. I re-checked the injection census: everything the host puts in the sandbox is a TABLE or a C FUNCTION — print, persistKey, system, component, computer, userdata, unicode, the os.clock/date/time overwrites, eris, and the stdlib. Not one userdata global, and not one host-owned metatable on the LuaJIT path (on JNLua the Java-object userdata carry a JNLua metatable and the string metatable is hidden; on a LuaJIT arch we own all of them). All of it is reachable from _G when the flattener runs, so all of it becomes permanent and is never traversed. Zero work.

(2) JAVA `Value` OBJECTS — the only userdata that exists: bounded, and already handled by OC, not by us. Userdata enters Lua at exactly two places, both lua.pushJavaObjectRaw: UserdataAPI.scala:277 (userdata.load) and ExtendedLuaState.scala:56 (a Value returned from a component or userdata call, gated on Settings.allowUserdata). machine.lua converts every one of them into a TABLE proxy the instant it crosses the boundary (wrapSingleUserdata at 1167-1185, wrapUserdata recursing over every returned table at 1187-1203, and machine.lua:1541 wrapping the args of every resume), and parks the raw handle in a weak-keyed table (machine.lua:1055-1069, __mode='k') whose spkey handler emits a fresh empty table on restore. Raw userdata is therefore unreachable from any persist root BY CONSTRUCTION, not by accident. Signals cannot smuggle it in either: Machine.scala convertArg (318-333) admits only Boolean/Character/Byte/Short/Integer/Long/Number/String/byte[]/NBTTagCompound, so a signal delivers nil, boolean, number, string and nested tables and nothing else. Both real operating systems confirm this empirically from the other side: I have a grep of all 119 QuickOS .lua files finding no newproxy, no userdata, no light userdata, no __gc and no debug.sethook anywhere — component proxies, internet request handles and file handles are all plain tables.

So the platform's userdata is a handful of host objects behind one wrapping layer, and OC's authors already reached for exactly the two mechanisms we support: perms for the injected C functions, and the persistKey/__persist protocol for the wrapped handles (machine.lua:1055-1067 and 1134-1142). Our spkey support is not a nice-to-have — it is the interface OpenComputers was written against. Measured: perming a userdata round-trips it by name with identity preserved; __persist on a TABLE works and hides an embedded handle from the walker; __persist on a USERDATA metatable is IGNORED and still refuses (confirmed in the source — p_table is the only spkey call site, not just by experiment). That last asymmetry is worth knowing before someone designs around it.

(3) WHERE IT DOES BITE, AND IT IS NOT OPEN-ENDED EITHER: an OS that holds a wrapped handle's UNDERLYING object across a yield. AxisOS does this in two places — internet handles kept in the AxisNet driver's session table and live as a local across syscall("process_yield") (internet.sys.lua:112-146, 288-300), and data-card ECDSA key objects live between deserialization and use (crypto.lua:97/138, used from xpm/sign/manifest/dkms_sec). Measured refused as a suspended stack, as module state on its own, and as a whole-machine root. Every in-flight HTTP or TCP request is an unsavable interval, and the window closes only when the handle is dropped. This is a real cost but a BOUNDED one: it is not "userdata is open-ended", it is "network and crypto handles have a save-hostile window", which is a property of asynchronous I/O in a persisted VM and would be true of any serializer.

WHAT IS ACTUALLY OPEN-ENDED IS cdata, NOT userdata — and only if we choose to make it so. See the FFI answer: ffi.new, ffi.cast, a bare `1LL` literal and string.buffer objects are all refusals today and are unreachable today, because nothing exposes them. That stays true only as long as the architecture keeps them out.

TWO CAVEATS I WOULD NOT SHIP WITHOUT CHECKING. First, every userdata measurement in this census used stand-ins (newproxy(true) and io.open FILE* handles). They are genuinely LUA_TUSERDATA so the refusal is the real refusal on the real type tag, but they are not Java Value objects. Specifically: if OC mints a FRESH Value userdata per call — the way string.gmatch mints a fresh C closure per call — then perming a userdata is as useless there as perming a gmatch iterator, and the (2) story above survives only because of the table-proxy wrapping, with no perms fallback underneath it. That is a one-hour check on the Java side and it should be done before anyone relies on perms for userdata. Second, the proxypairs reproduction used a plain Lua table for `self`; a real componentProxy's fields could reach userdata, which would turn that case from resumed-wrong into refused. Worth confirming, because it changes which of the two failure modes a user actually sees.

RECOMMENDATION: implement wire tag 14 as a REFUSAL WITH A GOOD MESSAGE, not as a feature. Naming the object and its path ("userdata at machine.lua's wrappedUserdata registry" vs "a userdata your program is holding") converts an opaque save failure into an actionable one, and it costs nothing. Actual userdata serialization has no customer here: the platform's own design says these objects do not survive, and both operating systems agree.

## Sandbox constraints the architecture should impose

- RETURN THE RAW `next` FROM EVERY ITERATOR THE SANDBOX OWNS. Two concrete edits, both one-liners, and together they remove the two highest-ranked defects in the whole census. (a) machine.lua:1309-1319 libcomponent.list must return `next, list, nil` (or snapshot the addresses into an array and hand back a numeric for) instead of a __call table over a next-closure. (b) machine.lua:1269-1282 componentProxy.__pairs must `return next, self, nil`, or be deleted in favour of pre-flattening `fields` into the proxy table. Measured directly this session: the closure form gave 4 wrong restores out of 6 (10, 11, 14+2dup, 14+2dup keys of 12); the raw-next form gave 12/12 exact six times out of six. Then make it a rule with teeth: no __pairs and no iterator-returning library function in the sandbox may wrap `next` in a Lua closure, ever, and add a boot-time assertion that walks the sandbox looking for one.
- FLATTEN PERMS DETERMINISTICALLY *AND* SWEEP BUILTIN UPVALUES. Both, not one. (a) Copy PersistenceAPI.scala:60-72's sorted depth-first walk into the Java flattener we write for the LuaJIT arch — I measured that a naive pairs() walk makes `unpack` win a different dotted name in 1 process out of 12 and fails 5 of 10 fresh-process loads with 'unknown permanent'. Also fix serializer/tests/m3.lua:21-61, which uses the naive form today and therefore has a nondeterministic regression suite. (b) Add the arm real OC lacks: sweep the function-valued upvalues of every named builtin, which picks up `next` and the ipairs aux (exactly two objects on this build) and is the only thing that makes a coroutine suspended mid-ipairs persistable at all. Without (b), QuickOS's boot path at base.lua:440 is a hard save failure against the real host.
- PUT A PERSISTABLE PURE-LUA `gmatch` ON THE SANDBOX UNCONDITIONALLY, or set SHORT_STRING to 0. Today machine.lua:554-560 delegates to native gmatch below 500 characters, so `for w in s:gmatch(p) do ... end` is a save failure for short strings and a success for long ones from the same source line — the shell's PATH split, and under source-level preemption the first statement of every gmatch body is a yield. Extend the audit to every stdlib entry point that can return a runtime-minted C closure and make sure the sandbox's version returns a Lua closure instead; the two ordinary code produces are gmatch and raw coroutine.wrap, and machine.lua:867-877 already does the right thing for wrap — keep it, and add a test that pins it.
- REBASE TIME ACROSS THE SAVE, OR TELL THE OS THAT TIME MOVED. This is the one architectural gap that no serializer feature can close and that breaks both operating systems. Either keep computer.uptime() monotonic and continuous across a save/restore (freeze it over the gap), or push a `resumed` signal carrying the shift so an OS can rebase its own deadlines. Stock OC does neither, and the result is bimodal and silent: uptime advancing fires every in-flight IPC wait, connect timeout and idle warner on the first post-restore pass; uptime resetting leaves every waiter hanging forever with no log line at all. Pick one, document it, and ship a reference rebase helper in the sandbox so OS authors do not each invent a different wrong answer.
- KEEP THE CAPABILITY SURFACE CLOSED: no `newproxy`, no `ffi`, no `string.buffer`, no `jit.util`, no `debug.sethook`. LuaJIT adds newproxy to the BASE library and it creates real userdata with a settable __gc, so it must be removed explicitly rather than assumed absent. Closing the names is not enough — scrub `package.preload` and `package.loaders`/`package.searchers` too, because `require('ffi')` and `require('string.buffer')` both succeed on a stock build (I confirmed both load in the test harness). Every one of these is a hard save failure the moment a user touches it, and none of them buys an OC program anything it cannot get from `bit.*` (which returns plain numbers and persists fine) or table.new/table.clear (which return ordinary tables).
- NEVER INSTALL A DEBUG HOOK THAT CAN YIELD, AND TREAT THAT AS A CROSS-COMPONENT INVARIANT, NOT A CODING STYLE. The serializer's CS_HOOK and FR_PCALLH refusals are backstops, not the guarantee — the guarantee is that our CHECKHOOK watchdog hook RAISES and never yields. The M3 design review already caught this once: the claim 'a cont_hook frame is unreachable because OC installs only Lua hooks' is true of stock OC and false of this port, whose watchdog installs a native C hook. Two consequences for the architecture: record the invariant where the watchdog code lives (docs/watchdog.md does), and delete machine.lua's standing debug.sethook around resumes, because LuaJIT's hooks are VM-global — the clear-after-resume silently disarms the timeout for the outer thread after any inner coroutine returns, which is a spin-forever hole reachable from user code.
- SNAPSHOT AND RESTORE THE math.random PRNG STATE ALONGSIDE THE BLOB. The state lives in a userdata upvalue of the builtin (lib_math.c:135,186); math.random is a perms entry, so the serializer never traverses it and never can. This is a silent divergence on every save for every program that seeded a stream, it is invisible from Lua, and it is a few lines on the Java side (read the state out, store it next to the blob, write it back on load). Do it now rather than after someone ships a world-generation script.
- DECIDE WHAT `__gc` MEANS ON THIS ARCH AND SAY SO, BECAUSE THE ANSWER IS 'NOTHING'. I measured 0 finalizer firings in 200 tables even with 5.2 compat on — LuaJIT finalizes only userdata and cdata. So machine.lua's entire sandboxed-finalizer apparatus (sgc/sgcco at 699-729, the setmetatable interception at 776-808) is dead code, tables carrying __gc persist fine and come back inert, and — the real cost — userdataWrapper.__gc at 1124-1128 never runs, so Java-side Value.dispose() is never called and every component userdata leaks host-side until the machine closes. Either dispose Values explicitly from the Java side on machine close and on proxy replacement, or accept the leak deliberately; do not leave it resting on a metamethod this VM will never call. Keep user __gc disabled regardless (allowGC=false), since hooks are suppressed during finalizers and a malicious __gc would be uninterruptible by the watchdog.

## FFI

DO NOT EXPOSE. Not "defer", not "expose behind a setting" — keep it out, and write the reason into the architecture doc so nobody re-litigates it in a year.

THE PERSISTENCE ARGUMENT, WHICH IS DECISIVE ON ITS OWN. Every cdata value is an unconditional refusal today, and it is not a gap we could close cheaply if we wanted to. A cdata is an arbitrary C-typed object: pointers into this process's address space have no cross-process meaning, ctypes are interned per-VM with process-local ids, and a cdata with a __gc finalizer or an embedded callback has no restorable identity at all. Contrast that with everything else we refuse: userdata is a handful of host objects the platform already wraps away, and native gmatch iterators are one library function we can replace with a Lua one. Neither is open-ended. cdata is.

And the exposure is not exotic — it is a NUMBER LITERAL. `1LL` and `2ULL` are cdata. So is anything ffi.new or ffi.cast returns, and so is a string.buffer object. The failure mode is the worst one we have: the save raises, the save fails, and in OpenComputers the computer comes back switched off with its RAM gone. A user writes `local mask = 1LL << 40` because they wanted a 64-bit integer, the world saves while that value is in a slot, and they lose the machine. The guarantee we are selling is "your computer resumes exactly where it left off". A guarantee with a user-reachable exception that costs the entire RAM state, triggered by ordinary-looking code, is not a guarantee — it is a footnote, and users will find it the way they found every other one.

THE WATCHDOG ARGUMENT, WHICH IS INDEPENDENT AND ALSO DECISIVE. FFI breaks the timeout, not just the save. A debug hook cannot fire inside a C call, and an FFI callback cannot yield at all (measured: the shape cannot occur). So a machine sitting inside an FFI call at the deadline is unreachable by the CHECKHOOK design — this is exactly the C-boundary blind spot already recorded as the highest-severity row in the watchdog threat model, and FFI widens it from "the native pattern matcher" to "anything the user calls". Worse, it reaches the abandonment path: a wedged FFI call means the resume never returns, we cannot lua_close, and we leak a runner thread per hung machine. We would be trading a bounded, enumerable set of uninterruptible builtins for an unbounded one the user chooses.

THE SANDBOX ARGUMENT, WHICH ENDS THE DISCUSSION FOR A MULTIPLAYER MOD. FFI is arbitrary memory read and write plus `ffi.C.system`. It is a total escape from the Lua sandbox into the JVM's address space, from a script any player can put on a floppy disk. No amount of persistence engineering makes that acceptable, and OpenComputers' whole security posture — the wrapped userdata, the metatable hiding, the bytecode setting — assumes the opposite.

THE COUNTER-ARGUMENT, STATED FAIRLY AND THEN DISMISSED. The honest case for FFI is performance: it is why people want LuaJIT. But the performance an OC program actually needs is already there without cdata. `bit.*` gives the bitwise operations and returns plain numbers that persist exactly. `table.new` and `table.clear` return ordinary tables and persist exactly. The JIT itself — the reason this architecture exists — is unaffected by whether ffi is loadable. What FFI adds beyond that is struct layout and native calls, and native calls are precisely the thing that must not exist in a world that saves. So we are not giving up the LuaJIT value proposition; we are declining the one part of it that is incompatible with the product.

WHAT "DO NOT EXPOSE" HAS TO MEAN OPERATIONALLY, BECAUSE THE DEFAULT IS NOT SAFE. I confirmed this session that on a stock build both `require('ffi')` and `require('string.buffer')` succeed. Removing the `ffi` global is therefore not sufficient. The architecture must also scrub `package.preload` and `package.loaders`/`package.searchers` so no loader can reach either module, remove `newproxy` (LuaJIT adds it to the BASE library and it mints real userdata with a settable __gc), and keep `jit.util` out. Add a boot-time assertion that `pcall(require,'ffi')` fails in the sandbox, and a regression test that fails loudly if a LuaJIT upgrade re-adds a path. Keep the serializer's cdata refusal exactly as it is — it is a correct backstop, and the message should name the type so that if one ever does leak through, the bug report says "cdata" rather than something opaque.

IF THE PRODUCT EVER DEMANDS IT. The only defensible form is not `require('ffi')` at all: it is a curated, host-defined façade of specific operations, returning only plain Lua values, with any handle behind the __persist/spkey protocol the way OC already hides Java Value objects. That is a feature we could design deliberately, per capability, with a save story for each. It shares a name with FFI and nothing else. Do not let "we might want FFI someday" become a reason to leave the door ajar now — the door is what turns a bounded refusal list into an unbounded one.


---

# Follow-up measurements

Added after the census, to refine claims it stated more broadly than the
evidence supported. Measured against the shipped serializer
(`eris-lj 0.3`, format 2); probe at `scratchpad/gm.lua`.

## The native-gmatch refusal is about REACHABILITY, not presence

The census lists `for w in s:gmatch(p)` under REFUSED, which reads as though
any code containing such a loop cannot be saved. It is narrower than that: the
native iterator is a C closure in the loop's hidden func slot, so it only
blocks a save while it is still **live**.

| shape | outcome |
|---|---|
| loop completed, then yield | persists (464 B) |
| yield **inside** the gmatch body | REFUSED |
| iterator held in a local across a yield | REFUSED |
| iterator created, set to nil, then yield | persists (441 B) |
| gmatch inside a function that already returned | persists (766 B) |
| yield inside an equivalent **pure-Lua** iterator | persists (1104 B) |

A completed loop leaves nothing behind, because its hidden slots are clobbered
by later register use -- the same invariant the for-in detection relies on.

So the exposure is conditional on a yield occurring *inside* the loop body (or
the iterator being stored and held). That is what makes AxisOS the severe case
rather than the general one: its source-level preemption instrumentation
inserts a yield as the first statement of every loop body, which turns every
short-string gmatch loop into a save-failure window. An OS without that
instrumentation is exposed only where the body itself yields -- a component
call, `io.write`.

The fix is unchanged and still cheap: put the pure-Lua gmatch on the sandbox
unconditionally, or set `SHORT_STRING` to 0. The last row above shows why --
the pure-Lua iterator is ordinary persistable state.

## cdata: the wall is the general case, not every value

The FFI section calls every cdata an unconditional refusal. True today, but
the reasoning should not rest on it being *theoretically* impossible: a scalar
cdata of a primitive type (`1LL` is `int64_t` 1) could be persisted as a type
name plus its bytes and rebuilt with `ffi.new`.

The wall is the general case -- types are user-defined at runtime via
`ffi.cdef`, a cdata is opaque bytes whose interpretation lives in a ctype the
user wrote, some of those bytes may be process-local pointers with no way to
identify them without parsing that ctype, the ctype is itself per-VM interned,
and a cdata may carry a `__gc` finalizer or an FFI callback with no restorable
identity.

Which makes the decisive argument this one: **a partial solution is worse than
none.** "64-bit integers survive a save; a struct containing a pointer
silently does not; you cannot tell which you have by looking" is exactly the
conditional guarantee this project has spent its whole life eliminating.

## The watchdog blind spot is the OUTBOUND call, not the callback

The FFI section says an FFI callback cannot yield, so a machine inside one is
unreachable by CHECKHOOK. Those are two different situations and only one is
the problem:

- **Lua calls out to C** (`ffi.C.something()`): the machine is executing
  foreign C, no Lua bytecode is running, no hook can fire, and CHECKHOOK makes
  *compiled traces* poll `hookmask` -- we are not in a trace. The watchdog
  cannot interrupt at all, `resume` never returns, we cannot `lua_close`, and a
  runner thread leaks per wedged machine. **This is the real hazard.**
- **C calls back into Lua** (an FFI callback): Lua *is* running and a hook can
  fire; the constraint is only that the callback cannot yield, so the abort's
  unwind path is limited.

The first is what makes FFI different in kind rather than degree: it takes the
set of uninterruptible operations from an enumerable list of native builtins
we already know about to "whatever C function the user chose to call".


## Correction: the __gc / dispose aside was wrong in three places

The census's SEMANTICS-CHANGE entry claims machine.lua's sgc/sgcco apparatus is
"dead code on this arch" and that "every component userdata leaks host-side
until the machine closes". That was an unverified aside in a report about
something else. A dedicated investigation
([gc-dispose-leak.md](gc-dispose-leak.md)) re-measured it and found:

1. **sgc/sgcco being dead is NOT a regression.** It is not a disposal path -- it
   is a deadline sandbox for USER-written `__gc` callbacks, and it is already
   unreachable on stock OpenComputers, which ships `allowGC: false`
   (`application.conf:224`); machine.lua then strips `__gc` from user
   metatables outright. Losing it on LuaJIT costs zero. Nothing in the roadmap
   should describe it as something LuaJIT breaks.
2. **"every component userdata leaks" is false.** Of 15 `Value` classes only 5
   have a non-trivial `dispose`; `AbstractValue.dispose` is a no-op. And our
   *userdata* `__gc` still fires, so JNLua's `DeleteGlobalRef` still runs and
   most Values become JVM garbage normally.
3. **"until the machine closes" is wrong in both directions.** File handles and
   internet sockets are reclaimed on BOTH `computer.stopped` and
   `computer.started`, so exposure is one uptime window and never cumulative --
   but machine close does *not* dispose anything either, which IS a regression
   against stock, where `lua_close` finalizes tables.

What the aside missed is the part that actually matters: the AE2
`NetworkControl.NetworkContents` iterator self-registers as an ME grid listener
and unregisters only via `dispose()`. Unreachable disposal means AE2 never drops
the listener and every leaked instance re-sorts the whole ME item list on every
network change -- an unbounded, compounding **CPU** leak on the server thread,
with no backstop, GTNH-fork-specific.

Also settled here, and useful elsewhere: `-DLUAJIT_ENABLE_LUA52COMPAT` cannot
change table finalization (`LJ_52` has zero use sites in `lj_gc.c`/`lj_api.c`),
and the repo's `libluajit_stock.a` is itself already a LUA52COMPAT build -- so
an earlier "A/B" between the two was not an A/B at all.


## Correction: the `computer.uptime()` model in the ranked list is wrong

Ranked item #5 assumes a bimodal failure -- "if uptime advances across the save,
every in-flight wait fires at once; if it resets, every waiter hangs forever".
Read from OC source during the MineOS census
([mineos-census.md](mineos-census.md)), neither happens.

`Machine.scala`: uptime is a tick counter (`:89`), incremented at `:525`,
exposed as `upTime() = uptime/20.0` (`:182`), **saved** with
`nbt.setLong("uptime", uptime)` (`:886`) and **restored** with
`nbt.getLong("uptime")` (`:799`), and zeroed only at machine *start* (`:239`)
and *stop* (`:948`). So across a world reload uptime **freezes and resumes from
the saved value** -- it neither resets nor jumps, and in-flight deltas survive
approximately correctly.

What survives of the item, and is now the whole of it: **state that mixes a
persisted uptime with a non-persisted real-world epoch.** MineOS seeds
`bootRealTime` once at boot from a tmpfs file's mtime (`System.lua:3304-3311`)
and computes `system.getTime() = bootRealTime + computer.uptime() + timezone`
(`:52-54`), so after a reload the OS clock silently loses every second the world
was unloaded -- and paints the result on the menu bar.

Net effect: probability stays ~1, **badness drops** from "machine hangs or
storms" to "the machine's clock is wrong", so #5 should move DOWN the ranking.
Keep the reset model documented beside it, because which model holds is a *host*
fact: the gui arm measured a genuine permanent 100%-CPU wedge under the reset
model (an animation position running to -7499.8 and never reaching 1, with the
workspace busy-spinning on `event.pull(0)` and a full redraw every pass). That
is conditional on breaking uptime continuity -- which is the strongest possible
argument for: **if we ever freeze or rebase uptime, do it deliberately, and
never let it run backwards.**

## Addition: a fifth outcome class

The census classifies outcomes as HANDLED / SEMANTICS-CHANGE / REFUSED /
SILENT-GAP. MineOS forced a fifth, measured: **THE CONSTRUCT IS ILLEGAL AT
RUNTIME.** A `table.sort` comparator that performs a component call
(`Filesystem.lua:455-460`, on the desktop's file-list path) raises `attempt to
yield across C-call boundary`; the coroutine dies and the serializer is never
invoked. The program cannot run *with or without* a save.

The census currently files this under section C's "CANNOT OCCUR", which
conflates two different things: a shape the serializer will never meet because
the VM forbids it, versus a shape that kills the program outright. Identical
after JIT warmup, so not an interpreter artifact; an enclosing `xpcall` does
catch it.
