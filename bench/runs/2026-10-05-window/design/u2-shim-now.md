# u2-shim-now: the shim's collector and credit at HEAD (d9080d4)

Survey for round 2 of the collector at the wall: the row "a refusal at a credit tier's top
can land outside the program's handler". Read-only. Every line number below is at HEAD
d9080d4 (`git log -1`: "The boot that died on OC's assertion was the harness ...").

Files read in full or in the stated ranges:
- `native/lj52shim.c`: 195-476 (record, allocator), 739-1259 (collector, credit, cadence,
  flush), 1639-1749 (watchdog arm/disarm/depth/stats), 1805-1930 (stats readers, install),
  1957-2018 (norefuse), 2035-2079 (newstate).
- `test/native/mem_test.c`: all 1773 lines.
- `test/native/negative-control.sh`: 270-507.
- LuaJIT (`prototype/watchdog/luajit/src`): `lj_gc.c` 505-530, 725-805, 865-900; `lj_gc.h`
  65-70; `lj_api.c` 1248-1256; `vm_x64.dasc` 3775-3845; `lj_func.c` 155-164; `lj_meta.c`
  370-386; `lib_table.c` 272-284; `lib_base.c` 327-339; `lib_string.c` 87-104; `lj_err.c`
  813-829.
- For the trace only: the capacity probe `test/native/OcljSmoke.scala` 3143-3210; OpenOS
  `ocelot-brain/.../loot/openos/lib/event.lua` 10-84 and `lib/core/full_event.lua` 62-75;
  `bench/results-wall-2026-10-04.md` 30-45, 420-470, 585-610.

Notation: T = the cap the call sees (`M->total` in C mode, Java's `total` in legacy);
U = `used` as the call sees it; d = the call's delta; G(T) = `lj52_gc_odmax(T)` =
clamp(T >> 4, 32 KiB, 512 KiB) (lj52shim.c:1060-1064, constants :1017-1019);
K = `LJ52_GC_KSLICE` = 16 KiB (:1020); w = max(T/4, 128 KiB) (:1146-1147, :1010).

---------------------------------------------------------------------------------------

## 1. The state machine

### 1.1 Fields

| field | type | written at | read at | meaning |
|---|---|---|---|---|
| `norefuse` | int | ++ :2015, -- :2017 | :398, :460, :1110, :1128 | >0 inside `lj52_pushcfunction`: charge, never refuse, collector state untouched |
| `accounting` | int | :555 (`ud != NULL`), :1946 (close) | :390, :420 | jnlua asked for a capped state |
| `csync` | int | :502 (`lj52_mem_settotal`) | :389, :493 | 1 = C mode (figures in C), 0 = legacy (Java's figures per call) |
| `total` | long long | :501 | :390-399 | the cap in C mode |
| `used` | long long | :395, :405, :436, :457, :472 | :393-399, :495 | every successful delta since birth, both modes |
| `L` | lua_State* | :2076 | :1091, :1110, :1128 | main thread; NULL only before `lua_newstate` returns |
| `wd_depth`, `wd_by[0]` | int, lua_State* | arm :1687, :1695, :1697; disarm :1720 | `lj52_gc_kernel` :1082 | decide the kernel's slice |
| `gc_armed` | int | arm :1054; proof :1153; bailout :1184 | :1114, :1149, :1258, :1856 | a cycle demanded, not yet proven |
| `gc_busy` | int | :1129, :1137, :1188, :1207 | :1110, :1128 | re-entrancy guard; guards nothing today (:1124-1127) |
| `gc_savedmul` | uint32 | arm :1049 | :1152, :1183 | `gc.stepmul` to restore at disarm |
| `gc_white` | uint8 | arm :1050 | :1151 | `gc.currentwhite` latched at arm |
| `gc_armedcalls` | unsigned | arm :1055; ++ :1176 | :1176 | growth attempts (GROW or TRY) since arm: the valve |
| `gc_moved` | int | arm :1053 (`state != GCSpause`); :1150; park reset :1173 | :1169 | collector seen outside GCSpause since the arm |
| `gc_odstate` | int | RESERVE :1073, :1113; BURST :1157 | :1071, :1201, :1902 | credit tier: 0 BURST, 1 RESERVE (:1023-1024) |
| `gc_armby` | int | arm :1048; refusal-while-armed :1114 | :1166, :1907 | why armed: 0 GATE, 1 WALL, 2 FLUSH (:1025-1027) |
| `gc_hyst` | int | proof :1155 (never cleared anywhere) | :1072, :1193-1194, :1908 | 1 once any cycle has been proven on this record |
| `gc_low` | long long | proof :1156; lowered :1193 | :1196-1197, :1204, :1906 | U at the last proof, lowered by later frees while unarmed |
| `gc_seentotal` | long long | :1141 | :1904 only | diagnostics: T of the last pressure call that passed the guards |
| `gc_overdrafts`, `gc_odpeak` | long, long long | :1143-1144 | :1900-1901 | GROWs with U > T, and the largest U - T seen on a GROW |
| `gc_flush_wanted` | int | set :1167; cleared :1224 | :1663, :1862 | a proof left T - U < w/2: flush traces at the next safe point |
| counters | `gc_arms` :1056, `gc_collects` :1154, `gc_bailouts` :1185, `gc_refusals` :1108, `gc_parkresets` :1174, `gc_traceflushes` :1248, `gc_flushrefusals` :1245, `gc_flushbytes` :1249 | | | diagnostics only |

Nothing in the collector state is reset by a cap change: `lj52_mem_settotal` writes only
`total` and `csync` (:498-503). `gc_hyst`, `gc_low`, `gc_odstate`, `gc_armed` carry across
OC's save pattern (cap to Int.MaxValue, persist, cap back) and across `setTotalMemory`.

### 1.2 Who calls what

- `lj52_gc_pressure(M, T, U, kind)` (:1118-1208), kinds `LJ52_GP_FREE/GROW/TRY` (:294-296):
  - C mode: FREE before a free, with the post-free figure `M->used + delta`, only if
    `acct` (:393); GROW (or FREE for a shrink/equal realloc) after a granted realloc, with
    the post-grant figure, only if `acct` (:406); TRY via `lj52_gc_refused` (:400 -> :1109).
  - Legacy, bound and with an env: FREE before a free with Java's `used + delta` (:454);
    GROW/FREE after a grant (:473); TRY via refusal (:466). Never for an unbound record
    (:420-439) or for `M == NULL` (:377).
- `lj52_gc_refused(M, T, U)` (:1105-1116): only from the two refusal branches (:400, :466).
- `lj52_gc_credit(M, T, U)` (:1087-1098): only inside the refusal predicates, and only
  after the fast test `T - U < d` has failed, and (C mode) only when `!norefuse`
  (:398-399), (legacy) only when `norefuse == 0` (:460-461). It has a side effect: the
  fresh-record rule in `lj52_gc_reserve` (:1072-1074).
- `lj52_gc_arm(M, g, why)` (:1046-1057): from the cadence (:1206), from a refusal while
  unarmed (:1115), from the flush at the safe point (:1258).
- `lj52_gc_flushtraces(L, M)` (:1217-1259): from `lj52_wd_arm` only, when
  `gc_flush_wanted` (:1663).

### 1.3 Every condition under which an allocation is refused

The allocator returns NULL for a growth in exactly these cases; LuaJIT then raises
`lj_err_mem` (`lj_mem_realloc` lj_gc.c:874-875, `lj_mem_newgco` :888-889), whose error
object is the preallocated "not enough memory" string (lj52shim.c:2009-2011 citing
lj_state.c:202; `lj_err_mem` lj_err.c:813-829). Frees (`nsize == 0`) are never refused.

**C mode (`M->csync == 1`, :389-409).** Refused iff ALL of:
1. `acct` = `M->accounting && M->total > 0` (:390);
2. `delta > 0` (a new block, or a realloc that grows);
3. `!M->norefuse`;
4. `M->total - M->used < delta` (the fast test);
5. `M->total + credit - M->used < delta`.

Since credit >= 0, (4) and (5) together are exactly **U + d > T + credit**.
Then `lj52_gc_refused` runs and NULL is returned (:400-401); `used` is not touched.

**Legacy mode (`csync == 0`, :411-475).**
- If `M->accounting == 0`, or `javaref == NULL` (unbound, or cleared at close), or
  `envfn()` returns NULL: never refused by the cap; the bytes are banked in `pending`
  (:420-439).
- Otherwise T and U are Java's jints, read per call (:442-444), with any `pending`
  settled first (:445-449). Refused iff NOT any of `T <= 0`, `delta <= 0`, `T - U >= d`,
  `M->norefuse`, `T + credit - U >= d` (:460-461); i.e. again **T > 0, d > 0,
  norefuse == 0, and U + d > T + credit**. Then `lj52_gc_refused`, NULL (:466-467).

**Both modes, a second kind of NULL:** `lj52_back` itself fails (the arena's `lj_alloc_f`
or libc `realloc`; :739-742). No counter moves, nothing arms, no tier opens (:403-408,
:469-475). The program sees the same "not enough memory".

**Never refused:** a state not made by `lj52_newstate` (`M == NULL`, :377: plain libc);
any call inside `lj52_pushcfunction` (norefuse); C mode with accounting off or T <= 0;
legacy unbound or T <= 0; shrinks.

**The credit** (`lj52_gc_credit`, :1087-1098):
- 0 if `M->L == NULL` or T <= 0 (:1091);
- 0 if `g->hookmask & HOOK_GC` (inside a finalizer) or `g->gc.threshold == LJ_MAX_MEM`
  (:1093). The second is true both inside a finalizer (lj_gc.c:516 parks it there for the
  `__gc` call, :526 restores) and after a host `lua_gc(LUA_GCSTOP)` (lj_api.c:1248-1249);
- otherwise c = G(T) (:1094), halved (integer `>>= 1`) unless the record is in RESERVE or
  the fresh-record rule fires (:1095, :1069-1077), plus K if the allocating thread is the
  kernel's (:1096).

So the tier tops a growth is checked against are:

| thread | BURST | RESERVE |
|---|---|---|
| sandbox (`wd_depth > 0` and `cur_L != wd_by[0]`) | T + G/2 | T + G |
| kernel (`wd_depth == 0`, or `cur_L == wd_by[0]`) | T + G/2 + K | T + G + K |
| any thread under HOOK_GC or GCSTOP | T | T |

### 1.4 `lj52_gc_pressure`: the transitions

Guards, in order, under which the call changes nothing at all (no proof, no arm, no
gc_low, no overdraft count, no seentotal): `gc_busy`, `norefuse > 0`, `M->L == NULL`,
T <= 0 (:1128); then HOOK_GC or threshold == LJ_MAX_MEM (:1136-1139).

Past the guards: `gc_seentotal = T` (:1141); if kind == GROW and U > T,
`gc_overdrafts++` and `gc_odpeak = max(gc_odpeak, U - T)` (:1142-1145); w computed
(:1146-1147).

**Armed branch (:1149-1190), any kind:**
- if `gc.state != GCSpause`: `gc_moved = 1` (:1150);
- **PROOF** if `gc.currentwhite != gc_white` and `gc.state == GCSpause` (:1151):
  restore `stepmul` from `gc_savedmul` if it is still 0 (:1152); `gc_armed = 0`;
  `gc_collects++`; `gc_hyst = 1`; `gc_low = U`; if U <= T then `gc_odstate = BURST`
  ("repaid", :1157); if `gc_armby != FLUSH` and T - U < w >> 1, `gc_flush_wanted = 1`
  (:1166-1167). Note T - U < w/2 is true for every proof that finds U > T.
- else **PARK RESET** if `gc_moved` and `gc.state == GCSpause` and
  `gc.threshold > gc.total` (:1169): `gc.threshold = gc.total`, `gc_moved = 0`,
  `gc_parkresets++` (:1172-1174);
- and then (same else-branch) **VALVE**: if kind != FREE and `++gc_armedcalls > 65536`
  (`LJ52_GC_ARMCAP`, :1011): restore stepmul if 0, `gc_armed = 0`, `gc_bailouts++`
  (:1176-1186). No change to tier, gc_hyst or gc_low.
- return. The cadence below does not run on an armed call, so gc_low is not lowered by
  frees while armed (the proof overwrites it anyway).

**Unarmed branch: THE CADENCE (:1192-1206).**
- if `gc_hyst` and U < gc_low: `gc_low = U` (:1193) (any kind; in practice a free).
- Regime F (fresh, `gc_hyst == 0`): arm iff T - U < w (:1194-1195). True whenever U > T.
- Regime B (`gc_hyst` and gc_low < T): gate = min(w, (T - gc_low) >> 1); arm iff
  U > T or T - U < gate (:1196-1199). Any call (FREE included) that finds U > T arms.
- Regime P (`gc_hyst` and gc_low >= T): top = T + (RESERVE ? G : G >> 1) + (kernel ? K : 0);
  arm iff top - U < (top - gc_low) >> 1 (:1200-1205): the distance to the CALLING
  thread's tier top has halved since the proof (or since the lowest point after it).
- arm with `why = (U > T) ? WALL : GATE` (:1206).

`lj52_gc_arm` (:1046-1057): `gc_armby = why`; `gc_savedmul = stepmul`;
`gc_white = currentwhite`; `stepmul = 0`; `threshold = gc.total`;
`gc_moved = (state != GCSpause)`; `gc_armed = 1`; `gc_armedcalls = 0`; `gc_arms++`.
Note what `gc.total` is at that moment. On a growth it is the PRE-call figure:
`lj_mem_realloc` and `lj_mem_newgco` add the new size only after the allocator returns
(lj_gc.c:879, :892), so after an arm on a GROW, gc.total > threshold and the next
checkpoint fires. On a free it depends on the path: `lj_mem_free` lowers gc.total BEFORE
calling the allocator (lj_gc.h:119-123), so the arm sees the post-free figure;
`lj_mem_realloc(..., 0)` lowers it after (lj_gc.c:879), leaving gc.total under the arm's
threshold by the freed size. A later free after an arm also leaves gc.total under the
threshold: the case the park-reset comment describes (:918-921) and `gc_moved` guards.

### 1.5 `lj52_gc_refused` (:1105-1116)

1. `gc_refusals++` unconditionally (:1108).
2. `lj52_gc_pressure(..., TRY)` (:1109): may observe a pending PROOF (and so may close
   RESERVE and set gc_low = the pre-request U), may PARK-RESET, counts toward the VALVE,
   or (unarmed) may arm by the cadence.
3. Return without opening anything if `gc_busy`, `norefuse > 0`, `M->L == NULL`,
   T <= 0 (:1110), HOOK_GC or GCSTOP (:1112). (`norefuse > 0` cannot be true here: no
   refusal happens under norefuse; it is defensive.)
4. `gc_odstate = RESERVE` (:1113).
5. If armed (including armed just now by step 2's cadence): `gc_armby = WALL` (:1114);
   else arm with WALL (:1115). So a refusal that finds the valve just tripped in step 2
   re-arms at once.

### 1.6 What exactly is "a proof"

An allocator call (any kind, through `lj52_gc_pressure`, past the guards of :1128 and
:1136) that finds the record armed AND `g->gc.currentwhite` different from the byte latched
at arm time AND `g->gc.state == GCSpause` (:1151). `atomic()` is the only writer of
currentwhite in normal operation (:792-795), and GCSpause after the flip means the sweep
finished, so the predicate is "a mark + atomic + sweep completed since the arm" (:786-799).
Properties that matter for a design:
- It is observed LAZILY, at the next allocator call after the cycle ends, never at the
  cycle's end. Its `U` is that call's figure: post-grant (GROW), post-free (FREE, computed
  before the free, :393/:454), or pre-request (TRY).
- On a growth the refusal predicate is evaluated BEFORE the pending proof is seen
  (:398-400 then :1109; :460-466). The credit is therefore read with the pre-proof tier
  and `gc_hyst`. Both can only make it larger than the post-proof value (RESERVE may be
  about to close; the fresh rule may be about to stop applying), so this errs toward
  granting. `used` itself is current: the cycle's frees were credited as they happened.
- Two complete cycles with no allocator call at GCSpause between them flip the white back
  to the latched value (the "two-flip alias", :922-923; mem_test's `settle_gc`
  :335-350). The park reset heals it when any call saw the collector mid-cycle
  (`gc_moved`).
- A cycle that LuaJIT runs on its own (unarmed) proves nothing: proofs happen only in the
  armed branch.

### 1.7 RESERVE: opened and closed

- **Opened** by (a) any refusal that passes :1110-1112 (:1113); (b) the fresh-record rule
  inside the credit query: `gc_hyst == 0` and U > T + (G >> 1) (:1072-1074) — note the
  threshold has no K, while the kernel's BURST top has one. (b) does not arm by itself; the
  grant that follows calls the cadence, where regime F arms because U > T (:1195).
- **Closed** only by a PROOF that finds U <= T (:1157). Nothing else closes it: not a cap
  change, not a free that takes U under T, not a bailout, not the flush. A proof that finds
  U > T leaves it open — "what lets 'catch, format the message, drop, carry on' work"
  (:939-942; mem_test W8; sabotage 4.12).
- A record in RESERVE whose live data stays past T stays in RESERVE indefinitely; there is
  no third tier.

### 1.8 The kernel's slice

`lj52_gc_kernel` (:1080-1083): `wd_depth == 0 || cur_L == wd_by[0]`. `wd_by[0]` is the
thread that made the depth-0 arm (:1695); the kernel's main-loop arm passes
`outermost = true` and resets the stack first (:1676-1689, comment :649-652). So K applies:
between resumes (depth 0: Java's signal pushes, the kernel's own work, and in mem_test every
C frame not under an arm), and on the kernel thread after `coroutine.resume` returned and
before the disarm (`cur_L` restored to the resumer, vm_x64.dasc:1625, cited at :955).
It is added in exactly two places: the credit (:1096) and Regime P's top (:1203). It is not
in the fresh-record threshold (:1072) nor in the flush predicate (:1166). Everything the
sandbox runs — the program, OpenOS's dispatcher, user coroutines — gets no slice.

### 1.9 norefuse

Set only by `lj52_pushcfunction` (:2013-2018), which `lj52shim.h:325` substitutes for
jnlua's `lua_pushcfunction` (jnlua's 38 bare-JNI-frame sites; :1957-1996). The counter
covers the whole memo lookup/insert (`lj52_pushcfunction_raw`, :164-189). Effects while
> 0: the refusal predicates are skipped (:398, :460) and the growth is granted and
charged if the backing store succeeds; `lj52_gc_pressure` returns at its first guard
(:1128): no proof observed, no arm, no `gc_low` lowering, and the excursion is NOT
recorded in `gc_overdrafts`/`gc_odpeak`. A GC step can still run inside the window
(`lua_pushcclosure` checks the GC before it allocates, lj_api.c:681-683); its frees reach
the allocator and are credited, but their pressure calls also return at the guard, so a
proof that completes inside the window is observed at the first call after it. Bound stated by the comment:
at most 38 memoised GCfuncs, ~1.5 KB with the memo table's growth (:1981-1984); the GC64
light-userdata interning it mentions (:1989-1995) is not quantified there. Not
re-verified here.

### 1.10 The flush flag and `lj52_wd_arm` / `lj52_wd_disarm`

- Raised only at a PROOF with `gc_armby != FLUSH` and T - U < w >> 1 (:1166-1167).
- Consumed only at `lj52_wd_arm` (:1663), before the depth check and the timer cancel, on
  every arm (outermost or nested). `lj52_gc_flushtraces` clears the flag first (:1224),
  measures resident trace metadata (:1230-1237), returns if 0 (:1238), counts a refusal and
  returns under HOOK_GC or if `luaJIT_setmode(L, 0, LUAJIT_MODE_FLUSH) != 1` (:1244-1247),
  else counts and re-arms with why = FLUSH unless already armed or under GCSTOP (:1258).
- `lj52_wd_disarm` (:1705-1729) touches no collector state; it changes `wd_depth`, and so
  which threads count as the kernel (at depth 0, all).
- A refusal while a FLUSH-armed cycle is pending relabels it WALL (:1114), so that cycle's
  proof CAN raise the flag (see 5.7).

### 1.11 The readers

- `_OCLJ_GCSTATS()` (:1849-1879), 20 values: 1 arms, 2 collects, 3 bailouts, 4 refusals,
  5 armed, 6 gc.total, 7 gc.threshold, 8 gc.stepmul, 9 gc.state, 10 trace_flushes,
  11 flush_wanted, 12 flush_refusals, 13 flush_bytes, 14 heap (1 arena / 0 libc / -1 no
  record), 15 c_total, 16 c_used, 17 csync, 18 used_reads, 19 alloc_calls, 20 alloc_jni.
  Twenty is LUA_MINSTACK, so no checkstack and no allocation (:1870-1871).
- `_OCLJ_WALLSTATS()` (:1898-1910), 9 values: 1 overdrafts, 2 od_peak, 3 od_state,
  4 park_resets, 5 od_limit = G(gc_seentotal) (0 if never set), 6 kernel_slice = K,
  7 gc_low, 8 armby, 9 hyst. Allocates nothing.
- Both are raw globals the sandbox cannot reach (:1847-1848, :1896-1897), installed with
  `_OCLJ_WATCHDOG` and `_OCLJ_JITSTATS` (:1913-1930).

### 1.12 The whole machine, compactly

```
components:  ARM  in {UNARMED, ARMED(why, white, savedmul, moved, armedcalls)}
             TIER in {BURST, RESERVE}
             HIST in {FRESH, PROVEN(gc_low)}
             FLAG in {0, 1}
inputs per allocator call: kind (FREE | GROW | TRY), T, U, thread (kernel?), HOOK_GC,
             GCSTOP (threshold == LJ_MAX_MEM), norefuse, csync/accounting/binding.

growth d>0:  refuse  iff  capped & chargeable & norefuse==0 & U+d > T+credit(TIER,HIST,thread)
             refuse -> refusals++; pressure(TRY); [guards] TIER:=RESERVE; ARMED? why:=WALL : arm(WALL)
             grant  -> charge; pressure(GROW, U+d)
free:        pressure(FREE, U-osize) before the free
pressure (past guards):
  ARMED:   state!=pause -> moved:=1
           white flipped & pause  -> PROOF: UNARMED, HIST:=PROVEN(U), U<=T ? TIER:=BURST,
                                     why!=FLUSH & T-U<w/2 ? FLAG:=1
           else moved & pause & threshold>gc.total -> threshold:=gc.total (park reset)
                kind!=FREE & ++armedcalls>65536   -> UNARMED (bailout)
  UNARMED: PROVEN & U<gc_low -> gc_low:=U
           FRESH:              arm iff T-U < w
           PROVEN, gc_low<T:   arm iff U>T  or  T-U < min(w,(T-gc_low)/2)
           PROVEN, gc_low>=T:  arm iff top-U < (top-gc_low)/2,  top = T+(RESERVE?G:G/2)+(kernel?K:0)
wd_arm:      FLAG=1 -> flush traces; FLAG:=0; UNARMED & !GCSTOP -> arm(FLUSH)
```

---------------------------------------------------------------------------------------

## 2. The bounds

**Per-grant inequality.** For every growth granted by the cap predicate (i.e. not inside
the norefuse window; capped; chargeable):

    U + d  <=  T + credit  <=  T + G(T) + K  <=  T + 512 KiB + 16 KiB

with G(T) = clamp(floor(T/16), 32 KiB, 512 KiB) and K = 16 KiB. Refined by thread and state:
sandbox thread U + d <= T + G(T); kernel thread U + d <= T + G(T) + K; inside a finalizer or
under host GCSTOP U + d <= T. (`G/2` is `G >> 1`, :1095.) This is the comment's claim at
:960-962 and holds by construction: (4)+(5) of 1.3 are exactly `U + d > T + credit`.

**What can put the heap further past the cap than that, without breaking the inequality:**
- the norefuse window: bytes charged inside `lj52_pushcfunction` are never checked
  (:398, :460); bound per its comment ~1.5 KB of memoised GCfuncs (:1981-1984), not
  re-verified, and not recorded in od_peak (:1128 returns before :1142);
- a cap set under the heap: `lj52_mem_settotal` / Java's `setTotalMemory` can lower T to
  any value; no growth was granted past the bound, so U - T is whatever it was (mem_test
  C4b: Int.MaxValue for the persist, then the machine's cap restored under 20 000 live
  tables; W11: T = U - 24 KiB). From there every growth is refused until U + d <= T +
  credit again;
- banking before the binding (legacy, :422-439) is uncapped by design (state creation).

So at any instant: U - T <= max(G(T) + K + NR, an excursion inherited from a cap change),
where NR is the norefuse bytes charged since the heap was last under T + G + K.

**Why caught refusals cannot ratchet it.**
1. A refusal leaves `used` unchanged: it returns before `lj52_back` and before any
   `M->used +=` (:400-401, :466-467).
2. The predicate is absolute: it compares the post-grant U + d with T + credit, and credit
   depends only on T, the tier, the thread, and HOOK_GC/GCSTOP (:1091-1097). It never
   depends on the previous excursion, on `gc_refusals`, or on how many times the program
   has caught.
3. The only credit input a refusal changes is the tier, to RESERVE (:1113), which is the
   maximum and idempotent; a refusal never opens anything larger.
4. Hence after N caught refusals the bound is still T + G (+ K). mem_test W7 pins it:
   4000 caught attempts by the sandbox, od_peak <= G, used <= cap + G + 2048
   (mem_test.c:1687-1690); sabotage 4.9 (credit = T) fails it.

Note on the instrument: `od_peak` is updated only on GROW calls past the guards
(:1142-1145), so it under-reports by the norefuse bytes; `od_limit` is G of
`gc_seentotal`, i.e. the sandbox's bound, without K (:1904-1905; comment :1888-1889).

---------------------------------------------------------------------------------------

## 3. Trace: a batch fill near T + G/2

### 3.0 Where LuaJIT runs a checkpoint relative to an allocation (interpreter)

This decides whether an armed cycle runs before or after the allocation that could cross.
- **Check first, then allocate:** `TNEW`/`TDUP` (vm_x64.dasc:3796-3827, the compare at
  :3800-3803 jumps to `lj_gc_step_fixtop` before `lj_tab_new`); `FNEW` via
  `lj_func_newL_gc` (vm_x64.dasc:3775-3792; lj_func.c:163 checks, :164 allocates);
  `tostring` (lib_base.c:337 checks, :338 allocates); from C, `lua_pushcclosure`
  (lj_api.c:681 then :683) and `lua_createtable` (lj_api.c:710 then :711).
- **Allocate first, then check:** concatenation (`lj_meta_cat` builds the string at
  lj_meta.c:379, checks at :382-385); `string.rep` (lib_string.c:100-102);
  `table.pack` (lib_table.c:276-283).
- **Allocate, no checkpoint at all:** table growth on insert (`lj_tab_resize` through
  `lj_mem_realloc`, the shim's own note :803-805), string functions without an
  `lj_gc_check` (in lib_string.c only `string_rep` :102, `string_dump` :146 and
  `string_format` :666 have one; e.g. `gsub` has none — read from the grep, the full
  function bodies not checked).
- JIT-compiled code places its own GC checks (`asm_gc_check`); not checked here.

### 3.1 The program

Concretely, the harness's capacity probe (`OcljSmoke.scala:3174-3198`), run in the
sandbox as an OpenOS timer callback (no kernel slice): each `step` does

```
local ok, err = pcall(function()            -- FNEW: check first, then a closure (outside)
  for k = 1, BATCH do                        --   inside the program's pcall:
    local o = make(count + 1)                --   TNEW/TDUP (check first) + strings
    held[count + 1] = o                      --   table insert: array doubling, no check
    count = count + 1
    local junk = uniq(24, count) .. "!"      --   tostring (check first), string.rep, CAT
  end
end)
...
stage = "filling/" .. count                  -- CAT: allocate first (outside)
event.timer(0, step)                         -- event.register: TDUP + inserts (outside)
pcall(paint)                                 -- caught by its own pcall
```

and OpenOS's dispatcher (`event.lua:33-84`) runs it: `table.pack(handlers(...))` (:54,
allocate first), `local copy = {}` and `copy[id] = handler` (:56-58), all outside the
dispatcher's own `pcall`, which wraps only the callback (:72). The timer is removed from
`handlers` before the call because `times` is 1 (:64-70); `step` reschedules itself only
on the success path.

Let T be the cap, G = G(T), w = max(T/4, 128 KiB); the program is the sandbox, so the
tier tops are T + G/2 (BURST) and T + G (RESERVE).

### 3.2 Step by step

**A. Far from the wall.** The cadence does not arm (F: T - U >= w; B: T - U >= gate).
LuaJIT's own pacing collects with threshold = estimate x pause / 100 (lj_gc.c:742); once
the live set passes half the cap that threshold is past the cap and LuaJIT's own steps stop
firing before the wall (the shim's own analysis, :900-904).

**B. Below the cap, inside the gate.** The first arm (no proof yet) comes when
T - U < w (:1195), why = GATE. The next checkpoint — in this program within a few
allocations (every `make` and `uniq` has a check-first site) — runs a whole cycle
(stepmul 0, :773-775). The next allocator call proves it (:1151-1167): gc_low = U, BURST,
and the flush flag if T - U < w/2. From now on Regime B: re-arm when half the post-proof
headroom is used (:1197-1199), i.e. about two cycles per (T - live) bytes (:974-976).
Each cycle frees the junk strings, the probe's closures and stage strings, and
everything else that became garbage.

**C. Crossing the cap.** The growth that takes U past T is lent (U + d <= T + G/2) and,
in Regime B, any call with U > T arms, why = WALL (:1199, :1206). The cycle runs at the next
checkpoint. If garbage covered the excursion, the proof finds U <= T and Regime B continues.
Once the live data alone is past T, the proof sets gc_low = U > T: Regime P with
top = T + G/2. Each further cycle runs when the distance to top has halved since the last
proof (:1204): log2 cycles across the burst tier (:977-981).

**D. At the burst tier's top.** The refusal comes at the first allocation, anywhere in the
sandbox, with U + d > T + G/2 (1.3). With the record unarmed in Regime P,
top - U >= (top - gc_low)/2 (otherwise the cadence would have armed at the last grant, if
that grant was the sandbox's: a kernel call evaluates against top + K), so an unarmed
crossing needs d > top - U >= (top - gc_low)/2: a single request larger than half the room
the last proof left. Once armed, any allocation made between the arm and the next
checkpoint can cross (the allocate-first and no-check sites of 3.0: a concatenation,
a `string.rep`, a `table.pack`, and above all `held`'s array doubling, a single realloc
of the array's new half). In both cases what is being refused is LIVE DATA PLUS THE
GARBAGE SINCE THE LAST PROOF, not live data alone: a full collection at that instant
would have freed the garbage term (stock does exactly that, `luaM_realloc_` collecting and
retrying, :748-749). Near the end, as gc_low approaches top, the room left after each
proof shrinks geometrically and the next crossing is "whichever allocation comes next".

**Where it can land, and what the program sees next:**

1. *Inside the batch's `pcall`* (the common case, since almost all bytes are allocated
   there). `lj_err_mem` unwinds to the pcall; `pcall` returns `false, "not enough
   memory"` (the fixed string; returning it allocates nothing). The refusal has set
   RESERVE and armed (or relabelled an existing arm WALL), :1113-1115. The sandbox now has
   T + G - U >= G/2 of room (the refusal happened with U <= T + G/2). The probe's else
   branch reads `computer.freeMemory()` (0: both Java sides clamp, :962-963), drops
   `held = nil`, then `tostring(err)` (check first: the armed cycle runs here, if no
   earlier checkpoint ran it) and `gsub` and two concatenations (allocate first; well
   under G/2). The cycle frees `held`; the next allocator call proves it with U <= T:
   BURST again, gc_low = U. Whether the Java call path of `computer.freeMemory()` reaches
   a checkpoint before `held = nil` was not checked; if it does, the proof finds U > T,
   RESERVE stays open and the drop is repaid within half the reserve tier (the W8 shape,
   below).
2. *Between batches in `step`*, outside the program's `pcall`: the FNEW for the batch
   closure (check first: refused only if no arm was pending at that check, or the cycle
   that ran there left no room), the stage concatenation (allocate first), or inside
   `event.timer` -> `event.register` (TDUP, then inserts into the handler and into
   `handlers` that may resize with no checkpoint; event.lua:11-27). The error unwinds out
   of `step` into the dispatcher's `pcall` (event.lua:72), which calls
   `pcall(event.onError, message)` (:74; it appends to `/tmp/event.log`,
   full_event.lua:62-68, with RESERVE's extra G/2 available and the armed cycle running at
   its checkpoints). `step` was already deregistered and never reached
   `event.timer(0, step)`: no further batch is scheduled. The program's own handler never
   runs, `held` is never dropped (it is an upvalue), so the proof that follows finds
   U > T if the live data is past the cap: RESERVE stays open, gc_low = U, and the
   machine idles in the reserve tier with free memory reading 0. This is the "stall"
   (results-wall-2026-10-04.md:438-442: "Each step of the probe allocates in three places
   outside its `pcall`: the closure it hands to `pcall`, the stage string, and
   `event.timer(0, step)`").
3. *In the dispatcher itself* (event.lua:50-58: `table.pack`, the `copy` table and its
   inserts), outside any pcall of OpenOS's: the error leaves `computer.pullSignal` and
   reaches whoever called it (`event.pull`, `os.sleep`, the shell). Not traced further.
   The results file says the dropin's one machine-down "landed in OpenOS's dispatcher or
   the kernel; the log does not say which", after four refusals with the reserve tier's
   top reached (:443-445).
4. *In `pcall(paint)` or the heartbeat timer's paint*: caught and swallowed by that
   pcall. It still spends the BURST tier's refusal: RESERVE opens and the collector arms
   without the program learning anything. (Reading of the code; not observed in a log.)
5. *In the kernel* after the sandbox yields: the kernel has K more on either tier; a
   refusal there is an error in the kernel's own code (mem_test W10 pins the post-resume
   `table.pack`).

**After the first refusal, if the program keeps its data** (catches and carries on
filling, or the stall left it held): the record is in RESERVE with top T + G, Regime P
halving toward it, and the second refusal at T + G again lands at whichever allocation
comes next. There is no third tier; every later attempt is refused, each refusal arming a
full cycle (W7 bounds collects <= 2 x refusals + 24, mem_test.c:1689).

### 3.3 The same with "catch, drop the data, format a message"

The W1 program (mem_test.c:520-526): fill under pcall until refused, `__h = nil h = nil`,
`string.rep('x', 256)`, a 3-element table, a concatenated result.

- *Refusal inside the pcall* (W1): catch (no allocation), drop (no allocation),
  `string.rep` allocates first (needs <= the reserve room, which is >= G/2) then checks
  (lib_string.c:102): the cycle armed by the refusal runs there, after the drop, frees the
  data; the next call proves U <= T: BURST, gc_low = U. W1 asserts the result string,
  then that `G/64 + 64` more 64-byte tables leave U <= cap (mem_test.c:1393-1402).
- *Format before the drop* (W8, mem_test.c:535-542): `'err: ' .. tostring(err)` reaches a
  checkpoint while the data is still held (tostring checks first, the concatenation
  checks after): the armed cycle runs then, proves U > T, RESERVE stays (:1157 needs
  U <= T), gc_low = U, Regime P with top T + G. After the drop, U does not fall until a
  cycle runs; the re-arm comes once half of (T + G - gc_low) has been allocated; that
  cycle frees the dropped data, its proof closes RESERVE. W8 asserts the same repayment
  within `G/64 + 64` tables (mem_test.c:1573-1587). Sabotage 4.12 (every proof closes
  RESERVE) makes W8 fail: the drop's repayment then needs room the BURST tier no longer
  has.
- *Refusal outside the handler* (3.2 case 2 or 3): the catch, the drop and the formatting
  never run. Nothing in the shim distinguishes this from case 1: the same counters move,
  the same tier opens, the same cycle is armed. The difference is entirely which Lua frame
  was executing the crossing allocation.

---------------------------------------------------------------------------------------

## 4. Constraints: the tests and the sabotages

### 4.1 mem_test.c cases that pin credit, cadence, refusal or the collector

All `ok()` checks; a sabotage's expected failing set must match EXACTLY
(negative-control.sh `expect_mem`, :287-305), so a change that makes any other case fail
under an existing sabotage also breaks that sabotage's verdict.

Helpers that encode the design's numbers: `w_odmax` = G (mem_test.c:467-470);
`w_creditmax` = G + K read from WALLSTATS (:476-479); `w_exhausted(used)` = the T with
T + G(T) + K == used, by fixed-point iteration (:485-493); `wmark` = w (:387-390);
`settle_gc` (:343-350).

**M (main state, legacy mode — never handed over, M9 asserts it).**
- **M5** (:739-746): T = used + 192 KiB; `alloc_tables(10 000 000)` must end LUA_ERRMEM
  with used <= T + G + K.
- **M6a / M6b / M7** (:748-792): after collect, `settle_gc`, collect (unarmed; the comment
  at :752-760 explains why M5's refusal arm must be settled first), 64 KiB live ballast,
  T = `w_exhausted(used)`: a raw `lua_pushcclosure` under pcall must be LUA_ERRMEM (M6b);
  `lua_pushcfunction` (cold memo, norefuse) must succeed (M6a) and raise `used` (M7).
- **M8** (:794-802): javastate cleared: 5000 tables, never charged.

**P (own state, legacy).**
- **P1a** (:856-870): T = base + 1 MiB; churn of 64 KiB tables (<= 400 steps) until a
  collect: status 0, arms and collects advance, bailouts and refusals unchanged.
- **P1b** (:871-874): flush not wanted after that proof. **P1c/P1d**: `arm()` leaves the
  traces; trace_flushes 0.
- **P2a** (:884-900): T = base2 + 256 KiB, then a 200 KiB live table: armed (Regime B,
  headroom 56 KiB < gate).
- **P2b/P2c/P2d** (:901-912): churn of 64 B to a proof: headroom still < w/2 = 64 KiB;
  flush_wanted = 1; no trace flushed yet.
- **P2e/P2f/P2g** (:914-928): one `arm()`: flushes once, 0 traces live, flag consumed,
  re-armed (FLUSH). **P2h** (:931-945): after the re-armed proof, used dropped by
  >= flush_bytes - 1 KiB.

**C (own state, C mode).**
- **C3a** (:1044-1055): T lowered to used + 192 KiB: 10M tables end LUA_ERRMEM with
  used <= T + G + K. **C3b**: T raised to 64 MiB admits at once.
- **C4a/C4b/C4c** (:1063-1093): T = used + 64 KiB; Int.MaxValue; 20 000 tables kept live;
  T restored: free reads 0 and `try_tables(1000)` is LUA_ERRMEM (C4b); after dropping and
  collecting, free > 0 and 100 tables succeed (C4c).
- **C5a** (:1095-1112): T = base + 1 MiB, 64 KiB churn: unarmed before, arms and collects
  advance, status 0. **C5b** (:1114-1134): T = base + 256 KiB, 200 KiB live: armed,
  proven, flush_wanted = 1.
- **C6** (:1140-1162): 64 KiB ballast, T = `w_exhausted(used)`: raw push LUA_ERRMEM,
  memo push succeeds and is charged.
- **C7** (:1164-1175): accounting off with T = used: 5000 tables, nothing refused.

**W (the collector at the wall; each on a fresh state, C mode unless stated).**
- **W5a** (:1227-1257): ~10 000 live tables, the collector stepped into GCSsweep,
  T = used + 200 KiB (inside w): after two checkpoints, park_resets >= 1 and
  (threshold <= gc.total or unarmed).
- **W5b** (:1258-1266): 20 000 x 64 B churn after it: status 0 (never refused), collects
  advance, no bailout.
- **W5c** (:1270-1289): GCSTOP, 100 000 dead tables (~6.4 MB), T = used + 100 KiB,
  GCRESTART, two `try_tables(2)`: no bailout, collects advance.
- **W2b** (:1293-1313): T = base + 1 MiB, 600 KiB of garbage in one block, H = headroom;
  one request of H + G/2 + 64 KiB: unarmed before, LUA_ERRMEM, armed after (a refusal
  arms from any headroom).
- **W2c** (:1314-1316): the same request again: status 0 (reading: the armed cycle runs at
  `lua_createtable`'s check, lj_api.c:710, before the request is allocated).
- **W2d** (:1317-1330): 300 KiB garbage, a live request of H + G/4: granted, used > T
  right after, used <= T after two checkpoints (lent, then repaid).
- **W9** (:1335-1363): INFO only, not counted: `pcall(string.rep, 'z', H + G + 64 KiB)`
  retried up to 20 times in a loop with no checkpoint, 600 KiB garbage: prints the tries.
- **W1 / W1L / W1j** (:1365-1418): holder of 65 536 slots pre-sized, T = used + 512 KiB;
  three rounds (C mode JIT off; legacy JIT off; C mode JIT on), three reps each: the
  program's result begins `"not enough memory|256|3"`; then `G/64 + 64` tables of 64 B
  succeed and leave used <= T; no bailout; and 0 <= od_peak <= od_limit (= G). These run
  on C frames at depth 0, i.e. as the kernel (tops +K); `od_peak <= G` holds because
  G/2 + K < G at these caps (T > 1 MiB, so G > 64 KiB), not by construction.
- **W12** (:1420-1429): the worst W1 round's collects in [1, 32] (measured 21; ~1840 with
  no hysteresis).
- **W13** (:1431-1471): T = base + 1 MiB; fill to T - 60 KiB, drop, collect, safe point;
  then hold to T - 100 KiB (inside w/2): flag 0 before, >= 1 collect, flag 1 after.
- **W14** (:1473-1518): a proof under a tight cap first; then T = base + 2 MiB; live to
  T - w - 50 KiB, garbage to T - w + 150 KiB, live to T - 100 KiB: >= 1 collect and
  flag 1.
- **W15** (:1520-1557): 160 KiB live; T = used + 100 KiB: a proof, flag NOT raised; then
  T = used + 40 KiB: a proof, flag raised.
- **W8** (:1559-1589): W1 with the message formatted before the drop: result begins
  `"err: not enough memory|256|3"`; repaid within `G/64 + 64` tables; no bailout.
- **W3** (:1591-1616): T == used (only the credit left); a compiled loop's exit restores
  a sunk table: status 0, t[1] == 2000, overdrafts >= 1.
- **W4** (:1618-1661): 256 KiB live; far phase T = base + 4 x wmark(...), near phase
  T = base + 64 KiB; 20 000 x 64 B each: near collects in [1, 3 x 19.5 + 2 = 60.6], far
  collects <= 2, both status 0, no refusals, time near/far <= 3.0.
- **W7** (:1664-1691): T = used + 256 KiB; as the sandbox (a coroutine resumed under an
  outermost arm, so no K): 4000 caught attempts to add 64 live tables: status 0, caught
  > 0, refusals advance, 0 <= od_peak <= od_limit (G), used <= T + G + 2048,
  collects <= 2 x refusals + 24.
- **W10** (:1694-1719): T = used + 256 KiB; the sandbox fills until refused twice (both
  tiers); the kernel's `pcall(table.pack, unpack(64 args))` succeeds still armed and
  after the disarm: `"true|true|2|true"`.
- **W11** (:1722-1757): 256 KiB live, a fresh record, T = used - 24 KiB (G = 32 KiB
  floor): as the sandbox, an 8-element table is lent (fresh-record RESERVE) and a
  4096-slot (32 KiB) table is refused; the resume yields: `nreq == 2`.

Not about the credit but bounding the same code: M0-M4c, M9, C0-C2, C8 (accounting
arithmetic and C-mode plumbing), P0 (traces exist).

### 4.2 negative-control.sh sabotages on this code

Each is a `sed` on one exact source line; if the line is reworded the script FAILS with
"the sabotage patch did not apply" (:354, :386, :418, :431, :444, :457). So these lines are
pinned textually:

| # | name | sed target (lj52shim.c line) | what it removes | expected FAIL set |
|---|---|---|---|---|
| 4.1 | stopgap (:342-376) | `M->accounting = ud != NULL;` (:555) | all charging | M3 M3b M3c M4 M4c M5 M6b M7 M9 P1a P2a P2b P2c P2e P2f P2g P2h C0b C0d C3a C4b C5a C5b C6 W1 W1L W1j W2b W2d W3 W4 W5a W5b W5c W7 W8 W10 W11 W12 W13 W14 W15 |
| 4.2 | nopending (:379-411) | `M->pending += delta;` (:435) | pre-binding bank | M4b M5 M3c C0b |
| 4.3 | norefuse (:413-421) | `M->norefuse++` / `--` (:2015, :2017) | the pushcfunction window | must DIE after M5 (`expect_death`, :310-334) |
| 4.4 | nopark (:423-436) | the park-reset `if` (:1169) -> `if (0)` | the park reset | W5a W5b |
| 4.5 | freescount (:438-448) | the valve `if` (:1176) without `kind != LJ52_GP_FREE` | attempts-only valve | W5c |
| 4.6 | nocredit (:461-465) | `c = lj52_gc_odmax(total);` (:1094) -> `return 0;` | the whole credit | W1 W1L W1j W2d W3 W8 W10 W11 |
| 4.7 | norefusedarm (:467-470) | `else lj52_gc_arm(M, g, LJ52_ARM_WALL);` (:1115) -> no-op | a refusal arming when unarmed | W2b W2c |
| 4.8 | nohyst (:472-476) | `if (!M->gc_hyst) {` (:1194) -> `if (1) {` | Regimes B and P (always F) | W4 W12 |
| 4.9 | unbounded (:478-484) | `c = lj52_gc_odmax(total);` (:1094) -> `c = total;` | the bound | C3a M5 W1 W11 W12 W1L W1j W2b W7 |
| 4.10 | nokslice (:486-489) | `if (lj52_gc_kernel(M, g)) c += LJ52_GC_KSLICE;` (:1096) | K in the credit (Regime P's K at :1203 kept) | W10 |
| 4.11 | nofresh (:491-494) | the fresh-record `if` (:1072) -> `if (0)` | the fresh-record RESERVE | W11 |
| 4.12 | closereserve (:496-500) | `if (used <= total) M->gc_odstate = LJ52_OD_BURST;   /* repaid */` (:1157) | RESERVE surviving a proof past T | W8 W11 |
| 4.13 | flushwhole (:502-507) | `#define LJ52_GC_FLUSHSHIFT 1 ` (:1022) -> 0 | half-watermark flush predicate | W15 |

Implications for a change (reading of the script, not run): editing any of :555, :435,
:1022, :1072, :1094, :1096, :1115, :1157, :1169, :1176, :1194, :2015, :2017 textually
requires updating its sabotage; changing what fails under 4.6/4.7/4.9/4.12 (the credit
sabotages) requires updating those expected sets.

---------------------------------------------------------------------------------------

## 5. Code inconsistent with its own comments (or comments with each other)

1. **The allocator's header undercounts its differences.** :332-347 says the allocator
   reproduces `l_alloc_checked` "with two differences, both deliberate" (no Lua API call;
   charge only what it got). It also refuses at T + credit rather than T, and arms the
   collector. The C-mode and legacy comments (:383-386, :462-465) do mention the credit;
   the header was not updated.
2. **`gc_odstate`'s field comment is incomplete.** :273 "LJ52_OD_BURST, or _RESERVE after a
   refusal"; the fresh-record rule also opens RESERVE with no refusal (:1072-1074).
3. **"Live data" where the code tests the heap.** :943-946 ("finds the live data already
   past total + G/2") and :1066-1068 ("whose live data is already past the burst tier")
   describe a test on `used` (:1072), which includes uncollected garbage.
4. **The fresh-record threshold has no kernel slice, the kernel's BURST top does.** The
   comment at :947-950 restricts the rule to fresh records because "the heap passes
   total + G/2 legitimately on the kernel's slice". On a fresh record the same can happen:
   a kernel allocation landing between T + G/2 and T + G/2 + K (:1095-1096) makes the next
   slow-path credit query, by any thread, open RESERVE without a refusal (:1072). Narrow:
   an unproven record arms on any call with U > T (:1195), so it needs the kernel to
   allocate more than G/2 past the cap before a checkpoint proves a cycle. Reading of the
   code; no test covers it.
5. **`gc_seentotal` is not "the cap the last allocator call was under"** (:277). It is set
   only by pressure calls that pass the guards (:1128, :1136, :1141): not under norefuse,
   HOOK_GC, GCSTOP, T <= 0, an unbound legacy record, or C mode with accounting off. The
   WALLSTATS `od_limit` derived from it (:1904) inherits the lag. Diagnostic only.
6. **The valve does not survive a refusal.** :1177-1182 says the armed window "must not be
   allowed to persist if the latch somehow never resolves". When the TRY pressure call
   inside `lj52_gc_refused` trips the valve (:1176-1186), :1115 re-arms on the same call,
   and every later refusal re-arms too: in a refusal storm the window is re-opened at once.
   Observation; whether that matters is a design question (bailouts still count it).
7. **"Never raised by the proof of a cycle the flush itself armed"** (:1164-1165). A
   refusal while a FLUSH-armed cycle is pending relabels it WALL (:1114), so that cycle's
   proof can raise the flag. Probably intended (the machine is at the wall), but "never"
   is not literal.
8. **Stale stats comment.** `_OCLJ_GCSTATS`'s comment (:1835-1837): "a machine whose LIVE
   data alone is past the watermark". Since stage C the predicate is half the watermark
   (:1166; :838-848; and :883-884 was updated to "past half the watermark").
9. **Two counts for one measurement.** lj52shim.c:985 "costs 21 full cycles, against 1554
   before (W12)"; mem_test.c:1424-1425 "21 full cycles ... and 1551 before any of this".
   Which is right was not checked.
10. **Regime P's halving is undefined for a negative distance.** :1204 right-shifts
    `top - M->gc_low`, which is negative when the last proof left the heap past the
    CALLING thread's top: e.g. a proof observed on a kernel allocation inside K, then a
    sandbox call (whose top has no K); or a cap lowered under gc_low - G/2. Right-shifting a
    negative signed value is implementation-defined in ISO C (arithmetic with GCC/MinGW,
    which build-native.sh uses — the compiler flags were not checked). The effect there:
    every unarmed pressure call from that thread re-arms. The comment (:977-981) does not
    cover the case. Since the sandbox is refused on every growth in that state anyway and
    each refusal arms, the extra cost is cycles triggered by its FREE calls. Not tested.
11. **W1's peak check uses the sandbox's bound on a kernel-thread test.** WALLSTATS
    documents `od_limit` as "the sandbox's bound" (:1888-1889); W1/W1L/W1j run on C frames
    at depth 0 (kernel: tops include K) and assert `od_peak <= od_limit`
    (mem_test.c:1412). It passes by margin (see 4.1), not by the bound. A change that lets
    kernel-context grants go deeper (up to its legitimate T + G + K) could fail W1 without
    violating R5.
12. **mem_test.c comment placement.** The W7 program's comment (:528-531) sits above
    `W8_CHUNK` (:535); W7's sandbox comment (:585-588) sits above `W13_FILL` (:591);
    `W7_CHUNK` is at :607-616. Cosmetic.
13. **od_peak under-reports** the true maximum excursion by bytes charged under norefuse
    (:1128 returns before :1142-1145). The comment at :960-963 states the bound "outside
    the norefuse window", so it is consistent; the instrument just does not see the window.

No contradiction found between the code and: the park reset (:895-923 vs :1169-1175),
the valve's attempts-only rule (:1002-1007 vs :1176), THE CADENCE's three bullets
(:972-981 vs :1194-1205), the credit's HOOK_GC/GCSTOP exclusion (:958-959 vs :1093), the
kernel-slice definition (:951-957 vs :1080-1083), the flush ordering (:858-871 vs
:1217-1259), or the safe point (:850-857 vs :1663).

---------------------------------------------------------------------------------------

## 6. Facts a design for this row has to work with (analysis, labelled as such)

These are inferences from sections 1-4, not measurements.

- **What the allocator can know at a crossing:** whether it is armed (`gc_armed`);
  whether a cycle has completed since the arm (the latch, readable at any call); the
  post-proof level `gc_low` and so U - gc_low, the bytes allocated since the last proof
  (net of frees while unarmed). It cannot know how much of that is garbage, nor how much
  data live at the proof has since been dropped: U - gc_low is neither an upper nor a lower
  bound on what a cycle would free.
- **What it cannot do:** collect (C1, C5, C6, :754-764). Any rule that "lets the cycle
  decide" therefore has to GRANT the crossing (some bounded amount past the tier top) and
  refuse a LATER allocation, after a checkpoint has run the cycle and a proof has been
  observed. Proofs are observed lazily (1.6), so "after a collection" means "at an
  allocator call that sees the flipped white at GCSpause".
- **Every existing tier top is checked per growth against an absolute figure** (2). A
  "lend the first crossing after each proof" rule re-enables a lend at every proof; to
  keep W7's non-ratchet property it needs its own absolute ceiling (the comment's
  T + G (+K) or a stated new one), not a per-proof allowance.
- **Tests that encode "the first crossing is refused" today** and that such a rule would
  touch (each needs to pass or be re-scoped with a reason): M6b and C6 (the raw push at an
  exhausted cap right after a settled, unarmed, proven state); W2b (a single request of
  H + G/2 + 64 KiB must be refused and arm); W11 (the 32 KiB request past T + G on a fresh
  record must be refused); M5 and C3a (U <= T + G + K at the end of a fill); W7 (od_peak
  <= G, U <= T + G + 2048, collects <= 2 x refusals + 24); W1's od_peak <= G (5.11); W10
  (two sandbox refusals within ten attempts); W12 (<= 32 cycles per fill); W9 (printed
  only, its number would move). And under the sabotages: 4.6, 4.7, 4.9, 4.12's exact
  failing sets.
- **Where the crossing allocation is matters as much as when.** In the probe, the
  out-of-handler sites are a check-first FNEW and TDUP and allocate-first concatenation
  and table inserts (3.0, 3.1). A check-first site already runs an armed cycle before its
  allocation; only an unarmed record, or an allocate-first or no-check site, is refused
  with garbage still uncollected.
