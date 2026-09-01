# Does stock OpenComputers share the for-in gap?

**YES — and it is strictly worse there than in eris-lj.** Stock PUC Lua + upstream Eris silently corrupts the loop; we refuse. Measured: **0 of 20** restores correct under PUC 5.3.6, versus 4 of 20 for our LuaJIT keyindex patch.

I wrote nothing to the repo — all probes are in `…\scratchpad\puc\`. (Note: `git status` shows `M` on `.gitignore`, `docs/*`, `serializer/*`. Those are not mine: every one has mtime 19:44 or earlier, my first command ran at 19:50, and my last at 19:54. A concurrent session owns them.)

---

## 1. PUC does persist a key, not an index — confirmed

`lvm.c:1255-1261` `OP_TFORLOOP` does `setobjs2s(L, ra, ra + 1)` — the control slot holds the **key** the iterator just returned. `lbaselib.c:226` `luaB_next` → `lua_next` → `luaH_next`. So Eris persists a `TString`, not a raw index. **This does not make it safe.**

## 2. The crux: PUC's layout is not reproducible either

`ltable.c:159-183` `findindex` resolves the key to a node position via `mainposition` → `hashstr(t,str)` = `hashpow2(t, str->hash)` (`ltable.c:60,117-137`), then `luaH_next` walks forward **in node-array order** from there. Identical "resume from this key's slot in the current layout" semantics to LuaJIT's ITERN.

And `str->hash` is seeded per-state:
- `lstring.c:170` — `luaS_hash(str, l, g->seed)` for short strings.
- `lstate.c:311` — `g->seed = makeseed(L)` inside `lua_newstate`.
- `lstate.c:81-90` — `makeseed` = `luaS_hash` over `{time(NULL), &L, &h, luaO_nilobject, &lua_newstate}`. The comment says it outright: it relies on ASLR.

## 3. Experiment — decisive

**3a. Order of a 12-string-key table, same insertion order, 20 fresh processes** (`order.lua`): **20 distinct orders, 0 repeats.** Lua 5.4.8: 10 runs, 10 distinct.

**3b. Faithful Eris round-trip model** (`persist.lua` / `unpersist.lua`, modelling `p_literaltable`+`p_thread` / `u_literaltable`+`u_thread`): persist once mid-loop after 6 of 12 keys, restore in 20 fresh processes.

```
A visited: india bravo foxtrot golf lima kilo   | ctrl=kilo
01 CORRUPT skipped=[delta charlie juliett echo] revisited=[india foxtrot golf]
02 CORRUPT skipped=[delta charlie alpha hotel juliett echo] revisited=[foxtrot]
05 CORRUPT skipped=[] revisited=[india bravo foxtrot golf lima]      <- whole loop replayed
11 CORRUPT skipped=[delta charlie alpha hotel juliett echo] revisited=[]
20 CORRUPT skipped=[] revisited=[india bravo foxtrot golf lima]
=== 0 / 20 restored correctly ===
```

Up to 6 of 12 keys skipped, up to 5 revisited, no error raised. `findindex`'s `"invalid key to 'next'"` never fires — the key *is* in the table, just at a different slot.

**3c. It is per-`lua_State`, not per-process.** `coexist.c` (5 states alive at once, one process): 5 different orders, `orders matching state 1: 0 of 4`. So a stock OC server hits this **without a process restart** — every computer reboot builds a fresh `lua_State` with a fresh seed. Sequential create-then-close in one process *did* match (malloc hands back the same address in the same second), which makes it worse, not better: the failure is intermittent and looks like a flaky mod.

## 4. Build dependence

`luai_makeseed` is guarded only in `lstate.c` (5.3 line 44, 5.4 line 58); it is **not** in `luaconf.h`, and the stock Makefile does not override it. Both 5.3.6 and 5.4.8 randomise by default, with the same code shape. I did not have a 5.2 tree to test — same design as far as I know, but that is unverified here, as are OC's actual native-lua build flags.

`-Dluai_makeseed()=0u` is **not** a fix: 6/6 runs still distinct, because `makeseed` still mixes the ASLR addresses. Pinning `g->seed` outright gives 6/6 identical orders and 8/8 correct round-trips at 12 keys.

## 5. Upstream Eris does nothing special — and a fixed seed still is not enough

`eris_master.c` contains **zero** references to `TFORCALL`, `TFORLOOP`, iterators or loop control. `p_thread` (line 1657) walks `thread->stack` slot-by-slot and persists whatever is there; `u_thread` (line 1828) restores it slot-by-slot. No refusal, no warning, no documented caveat.

The sharper finding: `u_literaltable` (line 944, 974) does `lua_newtable` + `lua_rawset` **in traversal order, with no presize**. Traversal order ≠ original insertion order, so the rebuilt table's node layout differs through rehash timing and `getfreepos` displacement. With the seed pinned and 64 keys, the round trip is **still corrupt — and deterministically so**, identically on all 8 runs (31 skipped, 2 revisited). At 12 keys it happened to survive; that was luck, not correctness.

---

## What this implies

**Severity for us: low, and our refusal is the right call.** Stock OC has shipped this hole for a decade, worse than ours and silent. We are not behind parity; we are ahead of it. This is a property of the whole persist-a-suspended-for-in approach, not of LuaJIT.

**But it also kills the seed-stability framing of our own fix.** The 4/20 result was not bad luck to be engineered away by taming `LUAJIT_SECURITY_STRID`. Any scheme that re-derives a traversal position from a stored key is unsound while the restorer rebuilds the table by re-insertion — result 5 shows the layout moves even with the hash pinned. A real fix has to make the resume point layout-independent: persist the *remaining* key set, or have the restorer reproduce placement exactly (presize plus a placement-preserving insert order), rather than re-deriving an index on the other side.

## Files

- Probes: `C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\puc\` — `order.lua`, `persist.lua`, `unpersist.lua`, `coexist.c`, `twostates.c`, `lstate_pinned.c`, `runs.txt`
- Sources read: `C:\Users\astro\Downloads\OC-LuaJIT\bench\vendor\lua-5.3.6\src\{lstate.c,lstring.c,ltable.c,lvm.c,lbaselib.c}`, `…\lua-5.4.8\src\{lstate.c,ltable.c}`, `…\scratchpad\eris\eris_master.c`

# KEY CLAIMS
- [high] Stock OpenComputers (PUC Lua + upstream Eris) has the same for-in gap, and fails worse: 0 of 20 fresh-process restores were correct under Lua 5.3.6, versus 4 of 20 for our LuaJIT keyindex patch — and it corrupts silently, with no error.
- [high] PUC randomises the string hash seed per lua_State, not per process (lstate.c:311, g->seed = makeseed(L) inside lua_newstate, mixing time(NULL) and ASLR addresses). Five coexisting states in one process produced five different pairs orders.
- [high] Pinning the hash seed does NOT fix Eris. With g->seed constant and a 64-key table, the round trip is still corrupt — deterministically identical on all 8 runs — because u_literaltable rebuilds the table with lua_newtable + lua_rawset in traversal order, with no presize, producing a different node layout.
- [high] Upstream Eris has no handling whatsoever for a thread suspended in a for-in loop: zero references to TFORCALL/TFORLOOP/iterators; p_thread and u_thread copy stack slots blindly. It neither refuses nor warns, and this is not a documented limitation.

## VERIFICATION
CLAIM: Stock OpenComputers (PUC Lua + upstream Eris) has the same for-in gap, and fails worse: 0 of 20 fresh-process restores were correct under Lua 5.3.6, versus 4 of 20 for our LuaJIT keyindex patch — and it corrupts silently, with no error.
VERDICT: confirmed
EVIDENCE: CONFIRMED on the load-bearing points, with two corrections of detail (see CORRECTION). All numbers below are mine, from a real build I made this session — not a model or a simulation. (I found a prior agent's PUC "probe" at scratchpad/puc/{persist,unpersist}.lua; it is a pure-Lua *model* of Eris, not Eris. I ignored it and ran the real thing.)

BUILD (real PUC Lua 5.3.6 + real upstream Eris, cross-checked byte-identical to the supplied source):
- scratchpad/eris/eris_53.c copied unmodified to scratchpad/puc2/eris.c (`cmp` says IDENTICAL), compiled -O2 -std=gnu11 against C:/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/liblua.a (vendor tree untouched) plus scratchpad/puc2/main.c -> scratchpad/puc2/luaeris.exe. Perms = deterministic (sorted) flattened _G, the same shape as OC's PersistenceAPI.flattenAndStore (I checked scratchpad/luac_PersistenceAPI.scala: OC calls `eris.persist` with a flattened perms table over native Lua 5.2/5.3/5.4, and pins no hash seed).
- One deviation, stated: upstream Eris also patches five stdlib .c files to push their *internal C continuation* functions into perms (README_53.md line 171). I supplied those five hooks as no-ops (scratchpad/puc2/stubs.c). They cannot touch table layout or next() semantics, and persist succeeded anyway, so nothing was missing.

1) THE GAP IS THERE, AND IT IS NOT REFUSED. A coroutine suspended inside `for k,v in pairs(t)` over 12 string keys (6 consumed) persisted with no complaint: 1343 bytes. Contrast the shipped LuaJIT serializer, which I ran on the identical shape and which refuses at persist time: "eris-lj: cannot persist a thread suspended inside a generic for-in loop over pairs()/next (its iteration position is an index into the table's current layout)". So the "we refuse, they ship it" framing is real.

2) 0 OF 20 — REPRODUCED, AND STRONGER THAN CLAIMED. One blob, 20 fresh processes: 20/20 CORRUPT (scratchpad/puc2/runs20.txt). I then ran 5 more independent save+20-load trials (fresh blob each): 0/20, 0/20, 0/20, 0/20, 0/20. Plus two other shapes at 20 loads each: a 20-key own table (0/20) and the OC-shaped case where the iterated table is a *perms entry* (the `string` library, 0/20). Total 160 fresh-process restores under Lua 5.3.6 + upstream Eris, 0 correct. Damage per run ranged from 6 keys silently skipped to 5 keys visited twice; e.g. run08 "ret=DONE:6 MISSING=6[bravo,delta,foxtrot,golf,hotel,lima]" and run03 "ret=DONE:17 DUP=5". Harness sanity: the same harness on an array-part table is 20/20 OK cross-process, so it can report success.

3) SILENT — YES, FOR THE ORDINARY LOOP. err=nil and unpersist succeeded in all 160 restores; no warning anywhere. The coroutine itself returns a wrong-but-plausible count ("DONE:6" ... "DONE:17" instead of DONE:12), so even the program's own bookkeeping lies.

4) MECHANISM, ISOLATED. I rebuilt with makeseed() pinned to a constant (scratchpad/puc2/lstate_pin.c, a copy — the vendor tree is untouched) -> luaeris_pin.exe. 10/10 loads then became bit-identical to each other, proving the run-to-run variance is Lua 5.3.6's per-process random hash seed (lstate.c:81 makeseed = time(NULL) + four ASLR addresses). But all 10 were still CORRUPT, deterministically dropping "charlie". So the seed is not the whole story and pinning it would not save OC.

5) BEYOND THE CLAIM: PUC+ERIS CORRUPTS IN A SINGLE lua_State. Persist and unpersist inside one state, string keys: 5 OK / 15 CORRUPT out of 20 (scratchpad/puc2/sameproc20.txt); integer keys 20/20 OK. Eris rebuilds the table by re-inserting in *hash* order, which reshuffles Lua's collision chains even under an identical seed. The LuaJIT keyindex patch was clean same-process every time. This is a harder failure than the claim asserts, and it means an OC world can be corrupted by a save/load inside one JVM run.

WORKING TREE: repo untouched. serializer/eris_lj.c not edited (mtime 19:42, before my first command; md5 7469c7a2d0a16229be50a24c92d72bfb), no `make` run, erislj_test.exe invoked by absolute path with cwd in the scratchpad. Everything I built lives in scratchpad/puc2/ and scratchpad/lj2/.
CORRECTION: Two things in the claim should not be repeated as stated.

(a) "4 of 20 for our LuaJIT keyindex patch" is not a stable figure — do not quote it as the comparator. I measured the same next(t,k)-resume semantics on the pinned LuaJIT myself, using the ITERC/split-`next` form that the shipped eris_lj.c accepts (lj_tab_next IS lj_tab_keyindex + scan, so it is the patch's semantics without the patch): six independent blobs x 20 fresh-process restores gave 0, 1, 1, 5, 1, 1 correct — 9 of 120, about 7.5%, with one blob scoring a flat 0/20. The variance is structural: LuaJIT's hash order is a *rotation* of interning order, so a save whose order happens to be a clean rotation can be matched by a load that lands on the same offset, while a save taken across one of LUAJIT_SECURITY_STRID's mid-sequence reseeds (my first blob had "echo" and "foxtrot" displaced out of the rotation) can never be matched. The defensible comparative statement is qualitative: LuaJIT lands correct a small, setup-dependent fraction of the time (~0-25%), PUC+Eris essentially never (0 of 160). Say that, not "4 vs 0".

(b) "it corrupts silently, with no error" is true for the ordinary loop but not universal — and the exception is worth owning, because it is the same failure class the LuaJIT keyindex patch was rejected for. The everyday sweep idiom `for k in pairs(t) do t[k] = nil end`, suspended mid-sweep, persists fine under PUC+Eris (1142 bytes) and then the restored coroutine dies loudly on resume with "invalid key to 'next'" — 10 of 10 fresh processes, deterministic, with 9 keys left unswept (scratchpad/puc2/delnil.lua). Lua's `t[k]=nil` tombstone keeps the node alive for the live traversal, but Eris rebuilds the table from a lua_next walk that cannot emit a nil-valued pair, so the resume key is simply absent. Stock OC therefore has *both* modes: silent wrong-key-set for a plain pairs loop, and a save that loads into a machine that crashes on its first tick for the sweep idiom.

Neither correction weakens the conclusion. If anything the position is stronger than the claim: refusing at persist time is ahead of a baseline that corrupts in 160 of 160 cross-process restores, corrupts in 15 of 20 same-process restores, and hard-errors on a common idiom.

## VERIFICATION
CLAIM: PUC randomises the string hash seed per lua_State, not per process (lstate.c:311, g->seed = makeseed(L) inside lua_newstate, mixing time(NULL) and ASLR addresses). Five coexisting states in one process produced five different pairs orders.
VERDICT: confirmed
EVIDENCE: CONFIRMED by my own probes. All artifacts in C:/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/seedprobe/ (probe.c/2/3/4), compiled against the prebuilt C:/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/liblua.a and reading G(L)->seed directly via lstate.h. Repo untouched; eris_lj.c not edited.

SOURCE (verified, not assumed). lstate.c:311 `g->seed = makeseed(L);` sits inside lua_newstate. lstate.c:81-91 makeseed mixes luai_makeseed() plus four addresses: L (heap), &h (stack), luaO_nilobject (data), &lua_newstate (code). luaconf.h does NOT define luai_makeseed, so lstate.c:44-47 supplies the default `cast(unsigned int, time(NULL))`. lstring.c:170 `unsigned int h = luaS_hash(str, l, g->seed);` in internshrstr -> short string keys are seed-dependent. So the claim's cited line, function, and ingredients are all accurate.

PART A - the headline test, 5 coexisting states in ONE process, same 14 string keys inserted in identical order:
  state 0 L=...88451268 seed=0x31b432f0 -> delta bravo alpha kilo mike golf hotel ...
  state 1 L=...882e0298 seed=0x31b432e0 -> november delta alpha echo foxtrot mike lima ...
  state 2 L=...882e7738 seed=0x31b4326f -> alpha mike lima kilo bravo november charlie ...
  state 3 L=...882f0758 seed=0x31b432ff -> foxtrot hotel delta bravo mike alpha juliet ...
  state 4 L=...882f93b8 seed=0x31b43273 -> november mike delta charlie alpha india lima ...
  => distinct seeds 5/5, distinct pairs orders 5/5. Exactly as claimed.

PART D - OC-style reboot (close 1 of 5 live states, open a replacement in the same process): seed 0x2f0244d2 -> 0x2f024323, pairs order changed: YES.

PART E - the failure the claim implies, demonstrated WITHIN one process. State A walks 7 of 14 keys and saves control key 'kilo' (what Eris persists in PUC); coexisting state B rebuilds the identical table and resumes via next(t,'kilo'). Result: 3 keys SKIPPED (echo, foxtrot, india), 4 REVISITED (delta, hotel, lima, mike), only 7/14 visited exactly once, no error raised. Same silent-corruption signature as the measured 20-process LuaJIT run, with zero process boundaries crossed.

REFUTATION ATTEMPT THAT NEARLY LANDED, AND WHY IT FAILS. Part C (5 sequential create-then-close, tight loop) gave 1/5 distinct seeds - identical L address, identical order every time - and probe3 gave only 4/50 and 1/50 seed changes in tight close/reopen loops. That looks like "effectively per-process". It is an artifact of the loop: the allocator instantly returns the freed block AND time(NULL) has not ticked. Probe 4 rules it out - 5 reboots spaced 1.1 s apart gave distinct seeds 5/5 and distinct orders 5/5, and reboots 3 and 4 landed on the SAME address (000002bbc74a17c8) yet still got different seeds (0x58e8f082 vs 0x7853c1a6), because time(NULL) advanced 1788281939 -> 1788281940. Wall-clock separation alone is sufficient. Any real OC reboot is separated by far more than one second, so the collision case cannot arise in practice.

Cross-process baseline (6 fresh lua.exe runs) also gave 6 different orders, so per-process randomisation is real too - the claim widens the exposure rather than replacing it.

CONCLUSION ON "why it matters": upheld. A stock-OC computer reboot inside a live server creates a fresh global_State with a fresh seed, so a pairs-mid-traversal blob restored after an in-server reboot corrupts silently exactly as it does across a full server restart. Exposure is per machine-reboot, not per server-restart.
CORRECTION: Verdict is confirmed; two precision refinements, neither of which changes the conclusion.

1. WORDING: it is per global_State (i.e. per lua_newstate call), not per lua_State. In PUC, lua_State is a thread, and lua_newthread (lstate.c:255) reuses G(L) without reseeding. Measured in Part B: parent L=...88451268 seed=0x31b432f0, its coroutine L=...8845bcd8 seed=0x31b432f0 - identical. So coroutines of one machine share an order; only separate lua_newstate calls diverge. Since OC allocates one lua_newstate per machine, the practical claim is unaffected - but "per lua_State" would wrongly predict that two coroutines in one machine disagree.

2. MECHANISM: "mixing time(NULL) and ASLR addresses" is right for the cross-process case but slightly off for the intra-process case the claim rests on. Within a single process, all ASLR-derived inputs (&h, luaO_nilobject, &lua_newstate) are constant. What separates five coexisting states is only the heap address of each new state, L - plus time(NULL) when creations straddle a second boundary. That is precisely why Part C's tight close/reopen loop collided at 1/5 distinct seeds: same address, same second. Worth stating explicitly, because it identifies the one regime where two states DO share an order (a state created immediately after another is closed, same second, address reused) - unreachable for real reboots, but it would silently mask the bug in any fast in-process test loop written to reproduce it.

