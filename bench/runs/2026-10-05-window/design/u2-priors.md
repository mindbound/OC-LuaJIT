# u2-priors: what the first design round (2026-10-04) proposed, scored and decided

Read-only survey for round 2 (the open row "A refusal at a credit tier's top can land outside
the program's handler"). Nothing was built or run. The aim is that round 2 does not re-propose
a rejected idea unless it brings a new argument.

**Abbreviations used for citations**

| Short | File |
|---|---|
| REQ | `bench/runs/2026-10-04-wall/design/REQUIREMENTS.md` |
| SP | `bench/runs/2026-10-04-wall/design/d-safe-point.md` |
| SO | `bench/runs/2026-10-04-wall/design/d-shim-only.md` |
| VF | `bench/runs/2026-10-04-wall/design/d-vm-faithful.md` |
| J | `bench/runs/2026-10-04-wall/design/judges.txt` |
| UH / UL / UP / US / UT | the round-1 surveys `u-history.md`, `u-luajit-gc.md`, `u-puc-stock.md`, `u-shim-collector.md`, `u-tests.md` (all at bd302f2, so their shim line numbers are stale) |
| RES | `bench/results-wall-2026-10-04.md` |
| RM | `docs/roadmap.md` (row 158 is THE COLLECTOR AT THE WALL, 159 is the open row, 160 is the boot-assertion row) |
| S | `native/lj52shim.c` at HEAD d9080d4 |
| LJ | `prototype/watchdog/luajit/src` |

**A caveat about the archive.** `judges.txt` cuts each per-requirement line at about 300
characters. The cut lines are J:5, 7, 8, 12, 20, 21, 23, 33, 38, 98-102, 111, 112, 114, 116,
117, 118, 124 and 129; for example, J:5 ends "...never reac". The FATAL lines, the
recommendations and the questions are complete. I searched this project's scratchpads for an
uncut copy of the judges' output and found none. Wherever I quote a cut line, the text after
the cut is **not recoverable**.

---

## 1. The three designs: rules, carriers, scores

The judges' overall scores:
- the **safety** judge: shim-only 6, safe-point 7, vm-faithful 3 (J:4, :19, :32);
- the **practice** judge: shim-only 7, safe-point 6, vm-faithful 3 (J:97, :110, :123).

### 1a. shim-only (SO): bounded credit, hysteresis, park reset

**Grant rule.** A positive request that would pass the cap is granted if
`used + delta <= total + credit` (SO:11). The credit depends on the tier:
- BURST, the default, gives G/2.
- RESERVE, after a refusal, gives G.
- The credit is 0 under HOOK_GC, under a host GCSTOP, or when `M->L == NULL` (SO:12-14).

G = clamp(total/16, 32 KB, 512 KB) (SO:26-29). The bound is absolute:
`used <= total + G + W_nr` (SO:31-35).

**Tier transitions** (SO:16-19):
- A refusal moves the record to RESERVE.
- A proof that finds `used <= total` moves it back to BURST.
- A proof that finds `used > total` changes nothing: **RESERVE survives proofs**.

**Refusal.** Anything past the credit is refused, and every refusal arms "from any headroom"
(SO:15).

**Retry.** There is none in the allocator. A retry made by the program succeeds after the
next checkpoint has run the armed cycle (SO:37-38).

**Carrier.** Today's checkpoint arm (`stepmul=0`, `threshold=gc.total`). The VM collects at
its own next GC checkpoint (SO:15).

**Cadence.** Arming uses hysteresis on headroom. In the RESERVE band, "`used > total`: every
grant arms (the stock cost per attempt)" (SO:45-50).

**P4.** `jit.flush()` before the baseline yield (SO:66-68).

**Scores, both judges:**

| R | safety | practice |
|---|---|---|
| R1 | PARTLY. The probe's recovery shape works by the allocate-first argument. "Three gaps. (1) A refused allocate-first call retried in a tight pcall loop ... never reac[h]..." (J:5, cut) | PARTLY. It fixes "recovery refused" by reading (J:98, cut) |
| R2 | PARTLY. "The RESERVE band re-arms on every grant while used > total, so a program holding data over the cap pays one full cycle per checkpoint" (J:6) | PARTLY. 2x stock's cycle count under churn, roughly 1.2-2x stock's time, "arithmetic, not a [measurement]" (J:99) |
| R5 | MET. "The bound is absolute ... Sandbox code cannot ratchet it. No new refusal sites" (J:9) | MET. The same bound; a side effect is that a program can hold up to G/2 before its first refusal (J:102, cut) |
| R6 | MET. "writes only the same two scalars ... Nothing collects in the allocator" (J:10) | MET. "A trace exit's sunk-object restore draws on credit instead of raising ERRMEM" (J:103) |
| R7 | MET. Zero LuaJIT lines, about 80 shim lines, the gate untouched (J:11) | MET (J:104) |
| R8 | PARTLY. The RESERVE state does not cross eris, but the over-cap data does (J:12, cut) | MET (J:105) |
| R10 | PARTLY. "W2c is shaped to pass ... Nothing tests an allocate-first retry or a reload over the cap, which is exactly where this design breaks" (J:14) | MET. "Missing: a test of recovery with no checkpoint, which is exactly where this design breaks" (J:107) |

**FATAL findings** (safety judge only; practice gave none):
- "The reserve credit is history that does not cross eris, while the over-cap live data it
  allowed does. After a reload the first allocation is refused without a collection,
  typically a Java signal push or the kernel's table.pack, so the machine goes down." (J:16)
- "An allocate-first call refused in a checkpoint-free retry loop spins until the deadline,
  because the arm only ever runs at a checkpoint. Stock collects and succeeds on the first
  retry." (J:17)

### 1b. safe-point (SP): a full collection from the watchdog's count hook

**What a crossing is.** A call with `acct && delta>0 && !norefuse && used+delta > total`
(SP:38).

**Grant rule** (SP:39-42). A crossing is granted only if all three hold:
- the collector is running;
- HOOK_GC is clear;
- the hook is ours or free.

In addition, one of two bands must have room:
- **Sandbox band:** `gc_credit` is set and `used+delta <= total + 16 KiB`. The grant sets
  `gc_granted`.
- **Kernel band:** the running thread is the kernel's (`cur_L == wd_kernel` or
  `wd_depth == 0`) and `used+delta <= total + 32 KiB`.

Every grant files a WALL request (SP:42). The hard bound is
`used <= total + 33.5 KiB` (SP:35).

**Refusal** (SP:43). Anything else is refused: `refusals++`, `gc_credit=1`, `gc_granted=0`,
and a REFUSE request is filed.

**Settling: the "decide at the collection" semantics** (SP:44-47). Only a fresh collection
settles a request: the hook's fullgc, or a proven checkpoint cycle whose arm found GCSpause.
The outcomes:
- If `used <= total`, credit stays open.
- If `used > total` and `gc_granted` is set, **credit closes**, and the next sandbox crossing
  refuses.
- A free that brings `used <= total`, or a refusal, reopens credit.

**Retry.** The refusal's collection runs at the next instruction boundary, so "an immediate
retry succeeds" (SP:49).

**Carriers** (SP:11-15). There are two, and the first able to decide wins:
- the **checkpoint carrier**, today's arm, unchanged;
- the **hook carrier**: a count=1 hook installed through `lj52_wd_inject`, with
  `lua_gc(L, LUA_GCCOLLECT, 0)` inside `lj52_wd_hook` at the next instruction boundary.

`_OCLJ_WATCHDOG.arm`/`disarm` are backstops. The build gate is re-scoped to allow exactly one
`lua_gc` (SP:158-167).

**Other parts:**
- **P2:** hysteresis via `gc_next = after + max((total-after)/2, SAND)`, plus a **back-off**
  for unproductive pre-emptive cycles (SP:53-58).
- **P3:** the park reset; the valve is deleted (SP:60-63).
- **P4:** `jit.off()` through kernel init (SP:65-67).

**Scores, both judges:**

| R | safety | practice |
|---|---|---|
| R1 | PARTLY. "**Strongest of the three.** A refusal files a REFUSE request, so a full collection runs at the next instruction boundary and an immediate retry succeeds, including the allocate-first pcall loop. The kernel band cannot be reached by sandbox threads: cur_L is restored to the resumer at vm_x64.dasc:1624, a[...]" (J:20, cut) | PARTLY. "The hook carrier collects at the next instruction boundary, so a recovery with no checkpoint works (X1f) ... But by reading[...]" (J:111, cut; the FATAL below finishes the thought) |
| R2 | PARTLY. "A new risk: each hook inject while the recorder is active aborts the recording (callhook calls lj_trace_abort ...). At the wall, repeated requests could bl[acklist ...]" (J:21, cut) | PARTLY. Deduplication gives about stock's rate; the back-off makes it "the best of the two shim designs" (J:112) |
| R5 | MET. "total+33.5 KiB, a compile-time constant ... A refusal loop costs one collection per attempt, which is PUC's rate." (J:24) | MET (J:115) |
| R6 | MET. "lua_gc(COLLECT) runs only from a count hook, which is ordinary API use ... lj_dispatch_ins fixes top ... Recording is aborted. HOOK_ACTIVE excludes finalizers" (J:25) | MET. "exactly a Lua debug hook calling collectgarbage(), which LuaJIT has to support" (J:116, cut) |
| R7 | PARTLY. "Zero VM lines, but about 150 shim lines and coupling to the watchdog hook (hookown, wd_fired races). The gate is deliberately re-scoped" (J:26) | PARTLY. "It edits lj52_wd_hook, wd_arm, wd_disarm and wd_program, which is the deadline-enforcement path whose thread filter took three tries. It adds about ten interacting flags" (J:117, cut) |
| R8 | MET (J:27) | *(no R8 line in the archive: J:117 is followed by R9 at J:118)* |
| R9 | MET (J:28) | MET, with an untested cost: each hook call aborts and penalises any recording in flight, so "Repeated wall events could blacklist a hot fill loop" (J:118, cut) |
| R10 | MET. "Missing: a stress mode with a must-crash canary for the hook carrier itself, and a check for trace blacklisting at the wall." (J:29) | MET. "It lacks a test for allocating between catching and dropping, and a blacklisting check." (J:119) |

**FATAL findings** (practice judge only; safety gave none):
- "By reading, the **credit-close rule** recreates the exact measured 'recovery refused'
  symptom whenever a program allocates between catching the refusal and dropping its data;
  the probe and X1 never exercise this. It can be fixed by grafting shim-only's RESERVE
  rule." (J:121)

### 1c. vm-faithful (VF): emergency collect-and-retry inside `lj_mem_realloc`

**VM half, interpreter only** (VF:16-31). When `allocf` returns NULL, `lj_mem_realloc` and
`lj_mem_newgco` call `lj_gc_emergency(L)` and retry once, if `lj_gc_canemerg(g)` holds. That
needs all of these:
- `vmstate == ~LJ_VMST_INTERP`;
- `jit_base == NULL`;
- HOOK_GC clear and no GCSTOP;
- the recorder idle;
- no-collect depth 0.

The emergency is `lj_gc_fullgc` with no finalizers. It skips the three shrinks (C7). Before
the cycle it raises the allocating thread's top to `base + cur_topslot`. It brackets three
constructors (`newtab`, `lj_func_newL_gc`, `lj_str_resize`). The cost is about 70 VM lines in
9 files and a 25-function audit (VF:11, :64-84, :160-162).

**Shim half: loans** (VF:33-49). The lending states are OPEN / LOAN / FULL / REFUSED, with
`L = max(32 KB, total/32)`:
- A crossing outside the interpreter is lent up to total + L, and the arm repays it.
- A cycle that ends with `used > total` sets FULL, and the next crossing is refused.
- After an error the state is REFUSED, which allows up to 2L for recovery.

**Carrier.** Inside the allocator path, in the VM. Outside the interpreter, the checkpoint
arm.

**P2: the watermark arm is deleted** (VF:51). Arms happen only on a loan, a refusal or a
flush.

**P3:** the re-poke while armed, and a valve that counts growing calls only (VF:53-55).

**P4:** `jit.flush()`, plus a flush rule based on trace size against headroom (VF:57-60).

**Scores, both judges:**

| R | safety | practice |
|---|---|---|
| R1 | PARTLY. "Exact in the interpreter. But deleting the watermark arm means that with live > cap/2 the threshold (2 x estimate) is never reached, so the heap sits at the wall full of garbage. Every borrowing-context burst larger than L is then refused even though garbage would cover it" (J:33, cut) | PARTLY. "exact only under vmstate INTERP. With the JIT on, most hot code is a borrowing context" (J:124, cut) |
| R2 | MET (J:34) | MET (J:125) |
| R5 | PARTLY. "Host safety now rests on a hand audit of VM C paths: any miss is a use-after-free or a wrong-top mark inside the JVM process." (J:37) | PARTLY. "one missed unanchored object is a use-after-free inside the JVM process, strictly worse than today's refusal" (J:128) |
| R6 | **NOT MET.** "The collection runs inside lj_mem_realloc, which R6 forbids ... The written top-raise rule ... is wrong in two places. Fast-function C halves run under INTERP (fff_fallback sets no vmstate, vm_x64.dasc:2190-2203)..." (J:38, cut) | **NOT MET.** "C5 and C6 rest on a hand audit. A concrete gap: fast-function C fallbacks run under INTERP ... and fff_newstr calls lj[...]" (J:129, cut) |
| R7 | **NOT MET.** "About 70 VM lines in 9 files, plus a 25-function audit to repeat on every LuaJIT bump." (J:39) | **NOT MET** (J:130) |
| R8 | PARTLY. The REFUSED state's 2L allowance does not cross eris (J:40) | MET (J:131) |
| R10 | MET. "The stress gate with must-crash canaries is the right method" (J:42) | PARTLY. It also needs a stress build, canaries and a second reviewer on every bump (J:133) |

**FATAL findings, safety judge** (J:44-46):
- The top raise uses `cur_topslot` on non-Lua frames: "ffh_resume calls
  lj_state_cpgrowstack(co) under INTERP with L=co, and fast-function C halves also run under
  INTERP. That is a crash path reachable from the kernel's own coroutine.resume at the wall."
- "Deleting the watermark leaves the heap full of garbage at the wall whenever live > cap/2.
  The documented 'burst > L in a borrowing context' residual then becomes the common case."
- "It violates R6 (collection inside the allocator path) and R7 (VM patch plus an audit
  repeated on every LuaJIT bump)."

**FATAL findings, practice judge** (J:135-137):
- "Memory safety at the wall rests on a hand audit, and there is at least one apparent gap:
  stale-top fast-function frames under INTERP, where cur_topslot is undefined. A miss is a
  use-after-free that can take down the JVM."
- R7 NOT MET.
- "Deleting the watermark makes refused C-context bursts larger than L more frequent than
  they are today."

I checked two of these against the pinned source:
- `fff_fallback` (LJ vm_x64.dasc:2190-2205) has no `set_vmstate`.
- `ffh_resume`'s C half calls `lj_state_cpgrowstack(co, ...)` (LJ lib_base.c:629).

---

## 2. What won, what was staged, what was left

**The judges disagreed.**
- **Safety** recommended safe-point: "Shim-only is safer to write but has two failures that
  safe-point avoids by construction: credit lost across eris, and allocate-first retries that
  never reach a checkpoint. vm-faithful should not be built." (J:48). Its fallback "if
  safe-point's hook coupling is rejected" was shim-only plus two fixes: (a) derive RESERVE
  from `used > total + G/2` on the first call after settotal/load; (b) test the
  allocate-first retry loop and accept it as a residual (J:84-86).
- **Practice** recommended shim-only as the base, "with four zero-gate grafts from
  safe-point. Keep safe-point's hook carrier as a conditional stage 2. Do not pursue
  vm-faithful." (J:139). Its reason: "Every advantage safe-point has on R2 and R4 comes from
  parts that can be lifted out of it without its costly hook machinery. The hook carrier buys
  only one thing: recovery when no checkpoint runs." (J:141)

**What was chosen:** practice's plan.
- RM:158: "in the shim only, no LuaJIT change, the collector gate kept ... A collection
  carried by the watchdog hook stays a later stage, for if the credit falls short."
- RES:90-104: "vm-faithful was rejected: it breaks R6 and R7 and has an unaudited host-crash
  path. The choice was shim-only, with the judges' grafts". The decisions taken were "Bounded
  credit first. The shim only; no build-gate change", G two-tier, and `kernelMemory`
  trace-free and unpadded.

**The stages that were built**, in practice's order (J:145-176):

| Stage | What | Evidence |
|---|---|---|
| 0 | The instrument: `CAP-*` prints the collector's state; negative-control.sh paths fixed | RES:142-189 |
| A (d705515) | The park reset (with a `gc_moved` guard the designs lacked) and the valve counting attempts only. A reduced matrix first, as practice asked (J:158-159, :184): the park never occurred in the machine; the downs are P1 | RES:109-238; S:1169-1186 |
| B (f21a64b) | Shim-only's credit with grafts (details below) | RES:240-501; S:925-1116, :1192-1206 |
| C (85faa0e) | P4 via **safe-point's** `jit.off()` through kernel init, restoring the prior JIT state as practice asked (J:181); flush at **half the watermark** | RES:503-641 |

**Stage B's grafts and changes:**
- **Kept:** RESERVE survives proofs (S:939-942). The kernel's slice, as a scalar test with no
  hook (practice graft (b), J:163): 16 KB, `wd_depth == 0 || cur_L == wd_by[0]` (S:1079-1083).
- **The reload rule, narrowed.** Safety's fix (a) was applied to **fresh records only**
  (S:943-950, :1066-1077). The heap-only first draft failed W1, W1L, W1j and W8 (RES:379-383).
- **Hysteresis became halving.** Below the cap the gate is half the post-cycle headroom.
  Past the cap the arm fires when the distance to the tier's top has halved (S:968-981,
  :1192-1206). Shim-only's "every grant arms" in RESERVE was **not** kept (RES:374-378).
- **The back-off** (safe-point, endorsed by both judges: J:78, :162) was built and **removed**:
  it suppressed the proofs the trace flush needs (harness mem-2; W13, W14) (RES:275-279;
  S:987-1000).

**The hook carrier (practice's stage 2) was not built.**
- The collector gate still forbids `lua_gc` (native/build-native.sh:340-341), and the shim
  calls no collector.
- Practice's trigger for stage 2 was "only if test (ii) or the matrix shows refusals that
  the credit cannot cover" (J:172).
- The matrix since shows such refusals: 3 stalls and 1 dropin down in 68 (stage B), 1 stall
  in 49 (stage C) (RES:425-430, :590-599).
- The record now argues the carrier would not help: "The hook carrier would not change it:
  the refused allocation still fails, however soon a collection follows" (RES:451-453; also
  RM:158 and :159).

**Residuals left explicitly:**
- **The allocate-first retry with no checkpoint** (safety FATAL J:17, fix (b) J:86). Kept as
  mem_test W9, "printed, not asserted", "because only a collection outside the checkpoints
  (the hook carrier, stage 2) would turn it into a pass" (test/native/mem_test.c:1335-1339;
  S:963-966; RES:338).
- **A single request larger than headroom + credit, covered only by garbage** (practice Q4,
  J:182; SO:257-258; SP:251-252; S:963-966).
- **The outside-the-handler stall/down**, found after the round (RES:436-455; RM:159). The
  idea on record, "lend the first crossing after each proof and let the cycle it arms
  decide", is "not built" (RES:453-455).
- **Recorder buffers** left after a flush, **mcode outside the cap**, and the
  **`lj_tab_resize` hidden-keys order** (SO:261-265; SP:256).
- **Practice's test (ii)**, a no-checkpoint array-growth recovery sized past G/2 (J:155). A
  grep of mem_test.c for "X1f", "array growth" and "no checkpoint" found only W9. Whether
  (ii) exists under another name was not checked further.

---

## 3. The two specific questions

### 3a. safe-point's "grant until the collection shows the heap still over": semantics or carrier?

Both drew objections, and they are separable.

**Objections to the semantics** (the credit gate itself: grant within a band; close credit
when a fresh collection finds `used > total` after a grant; reopen on a refusal or when
`used <= total`, SP:39-47):
1. **Practice FATAL (J:121).** Closing on a decisive over-cap collection recreates "recovery
   refused" whenever the program allocates between the catch and the drop. Practice's fix was
   to keep shim-only's RESERVE-survives-proofs rule (J:165, :173: "Keep the RESERVE rule
   rather than close-on-decisive"). **Measured since:** the negative control "every proof
   closes the reserve (safe-point's rule)" fails W8 and W11 (RES:359). So a ready-made
   regression gate exists against this semantic.
2. **Safety Q1 (J:89).** This was asked of all three designs, not raised as an objection to
   safe-point alone: "All three designs grant first and decide later. With safe-point, a
   request inside a pcall that goes past the cap by up to 16 KiB succeeds, and 'not enough
   memory' lands on the program's next allocation, **possibly outside the pcall**. Is that
   acceptable, or should a request that alone exceeds headroom plus the band be refused on the
   spot?" This is the open row's failure mode, foreseen. No recorded answer from the user was
   found in RES, RM or the auto-memory note (not checked elsewhere). The built design adopted
   grant-first anyway.

**Objections to the hook carrier, not the semantics:**
- **R7:** about 150 shim lines; the gate re-scope; edits to the deadline path; about ten
  interacting flags (J:26, :117).
- **R2/R9:** recording aborts, then `penalty_pc`, then possible blacklisting of a hot fill
  loop (J:21, :118, :174). I checked in the pinned source: `callhook` calls
  `lj_trace_abort(g)` at LJ lj_dispatch.c:371 (the judges cite :372), and `penalty_pc` is at
  LJ lj_trace.c:609.
- **Missing tests:** a must-crash canary for the carrier and a blacklisting check (J:29).
- **User questions:** lifting the gate (J:90, :180); the coupling with a foreign hook (J:92);
  finalizers at an instruction boundary (J:93).
- **What nobody objected to:** the carrier's VM safety. Both judges scored R6 MET (J:25,
  :116).
- **Its one credited advantage:** recovery with no checkpoint, and the immediate-retry case
  (J:20, :111, :141).

**What this means for the open row** (analysis, labelled):
- The idea on record is a "grant first, let the cycle decide" rule applied at the tier's top
  rather than at the cap. Its closest precedents are safe-point's credit gate (SP:39-47),
  vm-faithful's shim-half LOAN→FULL states (VF:36-45), and the survey's alternative (A)
  "grant ... until the proof, then refuse" (UL:102).
- The objections to those precedents' **semantics** carry over:
  - It must not close RESERVE on an over-top proof (W8/W11).
  - It must face safety Q1: a refusal deferred to "the next allocation after a collection"
    can itself land outside the handler when live data really is at the top.
- The **carrier** objections do not carry over if it keeps the checkpoint carrier.
- **The carrier argument has a gap.** RES:451-453 and RM:159 say a hook carrier "would not
  save the refused allocation". That is true of a collection filed **by the refusal**.
  Safe-point also filed a hook collection on **every grant past the cap** (WALL requests,
  SP:42). That shrinks the "garbage since the last cycle" term at the moment the heap meets
  the top, and that term is the row's stated cause (RM:159). Whether that would lower the
  stall rate is **untested**. A checkpoint-carried cousin, arming at every grant past the cap,
  is the "RESERVE re-arms on every grant" rule. The safety judge objected to it on cost:
  "pays one full cycle per checkpoint" (J:6). HEAD replaced it with halving (S:977-981).

### 3b. vm-faithful's interpreter retry (`lj_gc_canemerg`, vmstate == ~LJ_VMST_INTERP)

**What the judges objected to:**
1. **R6, the requirement as written.** It collects inside `lj_mem_realloc` (J:38, :46, :129).
   REQ:37-38 says "no collection inside the allocator". The design conceded this (VF:201).
2. **The INTERP gate is not the safe set it was claimed to be.** Fast-function C halves run
   under INTERP, because `fff_fallback` sets no vmstate (verified, LJ vm_x64.dasc:2190-2205).
   So `cur_topslot` is undefined for those frames. `ffh_resume` grows the coroutine's stack
   under INTERP (verified, LJ lib_base.c:629). That is "a crash path reachable from the
   kernel's own coroutine.resume" (J:44), and "a use-after-free that can take down the JVM"
   (J:135). The author named the same gate as the least-supported claim (VF:208).
3. **R7 and the audit burden:** about 70 VM lines in 9 files, a 25-function re-audit on every
   LuaJIT bump, a stress build with must-crash canaries, and a second reviewer (J:39, :130,
   :133, :136).
4. **R5:** host safety rests on that audit (J:37, :128).
5. **The watermark deletion.** This is a FATAL from both judges (J:45, :137), but it belongs
   to vm-faithful's **shim-side P2**, not to the interpreter retry.

**Is any part shippable alone?**
- **The designs' own claim.** "The VM half and the shim half can be adopted separately. The
  shim half on its own is the fallback with zero VM lines." (VF:12). The shim half's loans are
  functionally what shim-only shipped (stage B's tiers), and its FULL/REFUSED machinery was
  not adopted as such.
- **Sub-parts that were shipped in another form:**
  - the re-poke while armed became the park reset with a `gc_moved` guard (S:1169-1175);
  - the growing-calls-only valve became THE VALVE COUNTS ATTEMPTS (S:1002-1007, :1176).
- **A sub-part considered and set aside:** the trace-size-against-headroom flush rule. Safety
  suggested grafting it (J:82), and stage C called it "fragile" and chose half the watermark
  (RES:543-547).
- **The interpreter retry alone** (keeping today's watermark and credit) was **not judged as a
  separate option**. Objections 1-4 apply to it unchanged; only objection 5 drops away.
  Practice asked the user, "Is a LuaJIT VM patch (vm-faithful's emergency collector) ruled out
  whatever fidelity it would buy?" (J:183). The record shows the outcome, "no LuaJIT change"
  (RM:158; RES:100), but no explicit user answer was found (not checked beyond RES, RM and the
  auto-memory note).
- **Why it matters here** (analysis, labelled). It is the only idea in the archive that makes
  **the refused allocation itself** succeed after a collection. That is exactly what the row
  says the hook carrier cannot do.
  - The row's stall sites are interpreter-reachable allocations: the closure handed to
    `pcall` (BC_FNEW), the stage string (BC_CAT, which calls `lj_meta_cat` with no vmstate
    change: LJ vm_x64.dasc:3498-3508), and `event.timer`'s Lua code. So an INTERP-gated retry
    would cover those sites when they run interpreted.
  - It would not cover them on trace, which is VF's borrowing context (VF:190).
  - Any revival needs a **new** argument against objections 1-4, above all the non-Lua-frame
    top problem (J:44).

---

## 4. The judges' open questions and residuals, against this row

| # | Question (judge) | What happened | Bears on this row? |
|---|---|---|---|
| Q1 | Grant first, decide later: "not enough memory" lands on the next allocation, "possibly outside the pcall". Acceptable, or refuse on the spot a request that alone exceeds headroom plus the band? (safety, J:89) | Grant-first was adopted (stage B). No explicit answer found | **Yes, directly.** It is the row's failure mode, predicted. Any "lend more, decide later" fix (the idea on record) moves refusals later still and must answer it |
| Q2 | Accept lifting the collector gate for one `lua_gc` in atsafe? (safety J:90; practice J:180) | Deferred: the gate is unchanged (build-native.sh:340-341) | Yes, if round 2 revisits a hook collection. Note RES:451-453's counter-argument, and its gap (§3a) |
| Q3 | `kernelMemory` with the JIT off through init, ~10 KB under stock: keep, or pad? (safety J:91; practice J:181) | Keep, unpadded (RES:103-104); prior JIT state restored (RES:520-522) | No |
| Q4 | Accept the coupling to the watchdog hook (a foreign hook disables grants)? (safety, J:92) | Moot: no hook carrier | Only with a hook carrier |
| Q5 | Finalizers in the hook's full collection? (safety, J:93) | Moot | Only with a hook carrier |
| Q6 | Over-cap excursion: cap/16 (up to 512 KB), or a small fixed bound like 32 KiB? (practice, J:179) | cap/16, two tiers, plus a 16 KB kernel slice (RES:101-102; S:1017-1020) | Partly. The tops are where the stall happens. Any new lending must restate the R5 bound (REQ:34-36) |
| Q7 | Accept that "a single allocation inside one C call or one instruction, larger than headroom plus credit and covered only by garbage, is refused once where stock would succeed"? (practice, J:182) | Kept as the documented residual (S:963-966; W9) | **Yes, in its wider form.** The row's refusals are *small* allocations covered by garbage at a tier's top, which the accepted residual does not name. SO's one-sentence residual did name the general class: "a request that would fit only after that collection is refused when it exceeds the remaining credit before the checkpoint runs" (SO:267) |
| Q8 | Is a LuaJIT VM patch ruled out whatever fidelity it buys? (practice, J:183) | De facto yes (RM:158) | Yes, if round 2 considers the interpreter retry (§3b) |
| Q9 | Measure P3 alone first? (practice, J:184) | Done (RES:205-238) | No |

**Residuals the designs themselves predicted, which bear on this row:**
- **VF §5, "Late errors"** (VF:184): "A real out-of-memory in those contexts surfaces up to L
  bytes late. It can then land outside the pcall that covered the allocation that crossed the
  cap: a bounded 'machine down' risk." This is the outside-handler mode, predicted for lending
  in general.
- **SP §5** (SP:251-252, :259): a single C call needing more than headroom + 16 KiB with only
  garbage to cover it is still refused; "not enough memory" lands on the next allocation.
- **SO §5** (SO:257-259): checkpoint-free bursts past the credit are refused without a proven
  cycle; a program that creeps live data into the reserve loses the recovery guarantee.
- **Survey UL §5(B)** (UL:109): raising the error at a checkpoint "can fall outside the pcall
  that covered the overdrawn allocation, so the error escapes it — the 'machine down' mode".
  This is the general hazard of any deferred decision.

---

## 5. Table: ideas, verdicts, and whether the reason holds at HEAD (stages A-C landed)

"Holds" means the reason given then is still true of the code and results at d9080d4.

| # | Idea | Where proposed | Verdict | Reason | Does the reason still hold at HEAD? |
|---|---|---|---|---|---|
| 1 | Collect at the refusal inside the allocator (a PUC transliteration) | Earlier rounds (UH:9) | Rejected | C1, C2 and C5/C6 each forbid it (UH:9, :29-34; UL:40-47) | **Holds.** The allocator still never collects (S:398-401, :460-467); the gate is unchanged (build-native.sh:340-341) |
| 2 | VM emergency collect-and-retry gated on `vmstate == INTERP` (`lj_gc_canemerg`) | VF:16-31 | Rejected by both judges ("should not be built", J:48; "Do not pursue", J:139) | R6 NOT MET (collection in the allocator path); a non-Lua-frame top hole leads to a JVM-crash path; R7 NOT MET (70 VM lines, 25-function audit per bump) (J:38-39, :44, :46, :129-130, :135-136) | **Holds.** No LuaJIT change since; the hole was verified in the pinned source (vm_x64.dasc:2190-2205, lib_base.c:629). It is still the only idea that saves the refused allocation itself (§3b) |
| 3 | Delete the watermark arm; collect only at wall events | VF:51 | FATAL from both judges | With live > cap/2 the heap reaches the wall full of garbage, so C-context bursts are refused more often (J:45, :137) | **Holds.** HEAD keeps the watermark and the halving cadence (S:1194-1205). Note that this row's cause is the same garbage term in milder form |
| 4 | `jit.flush()` before the baseline yield (P4) | SO:66-68; VF:57-58 | Not chosen; `jit.off()` through init chosen (both judges, J:23, :114, :168-170) | Recorder buffers and the trace vector survive the flush (J:8, :101) | Moot: stage C shipped `jit.off()` (RES:518-528). Not relevant to the row |
| 5 | Bounded two-tier credit (BURST G/2, RESERVE G); RESERVE survives proofs | SO:11-24 | Adopted (stage B) | Fixes "recovery refused" by the allocate-first argument (J:98) | **Holds.** S:925-950, :1087-1116; W1/W8 pass (RES:325-326) |
| 6 | Close credit when a fresh collection finds `used > total` after a grant | SP:44-47 | Practice FATAL; not adopted | Recreates "recovery refused" if the program allocates between catch and drop (J:121) | **Holds, and measured:** the sabotage "every proof closes the reserve" fails W8 and W11 (RES:359) |
| 7 | Hook carrier: `lua_gc(COLLECT)` from a count hook at the next instruction boundary | SP:11-15, :130-146 | Safety: build it (J:48). Practice: conditional stage 2 (J:172-174). Not built | R7 cost and the gate re-scope; coupling to the deadline path; recording aborts and blacklisting (J:21, :26, :117-118). Its benefit: recovery with no checkpoint (J:141) | **Partly.** The cost reasons hold (gate unchanged; deadline path unchanged). The trigger condition practice set ("refusals the credit cannot cover") has since occurred (RES:425-430, :590-599). The post-round claim that it "would not save the refused allocation" (RES:451-453; RM:159) holds for refusal-filed collections, but does not address grant-filed ones (§3a; untested) |
| 8 | Kernel band/slice via `cur_L`/`wd_depth` | SP:41 | Adopted with no hook (practice graft (b), J:163) | Keeps the kernel's `table.pack`/signal pushes alive after the sandbox spends both tiers | **Holds.** S:951-957, :1079-1083; W10 (RES:333) |
| 9 | Back-off for unproductive pre-emptive cycles | SP:56 | Endorsed by both judges (J:78, :162); built, then removed | It suppressed the proofs the trace flush needs (mem-2; W13, W14) | **Holds.** S:987-1000; W13/W14 kept as regression tests (RES:369-370) |
| 10 | RESERVE: every grant arms (stock's cost per attempt) | SO:50 | Criticised (safety R2, J:6); replaced by halving to the tier's top | One full cycle per checkpoint while holding over the cap | **Holds as a cost argument** (S:977-981; RES:374-378). Relevant: it is the "collect sooner past the cap" lever against this row's garbage term, and reviving it needs a new cost argument (R9 of round 2) |
| 11 | Hysteresis: re-arm after half the post-cycle headroom | SO:45-56; SP:53-58 | Adopted (stage B) | Collection work per byte, not per checkpoint (W4: 10 000 to 39 cycles) | **Holds.** S:1192-1206; RES:331, :470-474 |
| 12 | Park reset / re-poke while armed | SO:60-63; SP:61; VF:53-54 | Adopted (stage A), guarded by `gc_moved` | Ends the parked collector (W5a-c) | **Holds.** S:1169-1175 |
| 13 | Valve counts attempts only (SO, VF) vs delete the valve (SP) | SO:64; VF:55; SP:63 | Attempts-only adopted; the valve kept | Practice: deleting it removes a safety net (J:113) | **Holds.** S:1176-1186 |
| 14 | Every refusal arms, from any headroom (shape 2) | All three; J:58 | Adopted | A retry after the next checkpoint succeeds (W2b/W2c) | **Holds.** S:1105-1116 |
| 15 | Reserve derived from the heap alone after settotal/load | Safety fix (a), J:85 | Adopted only for **fresh** records | The heap-only draft spent the reserve on the kernel's slice (W1/W1L/W1j/W8 failed, RES:379-383) | **Holds.** S:1066-1077 |
| 16 | Flush predicate: fixed 32 KiB (SP; practice graft (c)) / trace size vs headroom (VF; safety J:82) / half the watermark | SP:67; J:164; VF:60 | Half the watermark chosen in stage C | 32 KB fails mem-2 at large caps; trace size vs headroom is fragile (RES:543-547) | **Holds.** S:1022, :1166. Not relevant to the row, except that any new cycle schedule must not starve or flood the flush (W13/W14/W15) |
| 17 | Refuse on the spot a request that alone exceeds headroom plus the band | Safety Q1, J:89 | No decision recorded; HEAD lends within the credit and refuses beyond it | — | Open, and the row's crux. HEAD's choice (grant first) is the mechanism that moves refusals |
| 18 | Raise the error at a checkpoint (VM, about 10 lines in `lj_gc_step`) | UL:109 | Survey only; not designed | The checkpoint can fall outside the pcall (the "machine down" mode) | **Holds.** It is the same hazard as this row |
| 19 | Exit the trace and re-execute from the snapshot | UL:115 | Survey only | Idempotence after a helper has partly run "can't be settled by reading" | Not evaluated since |
| 20 | Lend the first crossing after each proof; let the cycle it arms decide | RES:453-455; RM:159 | Not built, not judged | — | New in name. Its semantics have precedents (#6, VF's LOAN→FULL, UL:102). It must (i) keep #5's RESERVE-survives-proofs rule (W8/W11), (ii) bound the lent crossing's size absolutely (REQ:34-36; for an unbounded single request, see #21), and (iii) answer Q1: the deferred refusal may itself land outside the handler. Analysis, not checked |
| 21 | Allocate-first retry loop with no checkpoint | Safety FATAL on SO (J:17) | Accepted as a residual (W9, printed not asserted) | Only an out-of-checkpoint collection (#7) or a VM retry (#2) cures it | **Holds.** mem_test.c:1335-1339; S:963-966 |
| 22 | GC pacing (`pause`/`stepmul`) instead of a collector | UH:11 | Not shipped | "a real mitigation and provably not a fix"; buys margin with CPU | **Holds.** Not revisited |
| 23 | A larger RAM scale | UH:20; RM:158 | Superseded | "a larger scale moves the wall and changes nothing at it" | **Holds.** The same reasoning applies to raising G: it moves the tops, and the refusal still lands at "whichever allocation comes next" (RM:159). Analysis |

---

## 6. For round 2: what a proposal must argue to avoid repeating round 1 (analysis, labelled)

1. **Closing the reserve on a proof is already refuted.** Any rule with a "cycle decides,
   then close" step must leave RESERVE open across proofs, or W8/W11 and their sabotage will
   fail (RES:359; J:121).
2. **Grant-first was flagged as the way refusals escape handlers** (J:89; VF:184; UL:109).
   Lending more, or longer, is the same lever. A proposal must show it does not merely trade
   a garbage-covered refusal outside the handler for a live-data refusal one allocation later,
   also outside it. Round 2's R1 (refusal "no earlier in program order than stock's") is the
   stated test.
3. **A hook carrier needs a new argument either way.**
   - To revive it, answer R7 (gate, deadline path, flags), blacklisting, and RES:451-453's
     claim that it cannot save the refused allocation. Making the claim precise
     (grant-filed vs refusal-filed) is new.
   - To dismiss it, address the grant-filed variant explicitly; RES/RM do not.
4. **A VM retry needs a new argument against J:44/J:135** (non-Lua frames under INTERP) and
   against R7. Dropping the watermark deletion removes only one of vm-faithful's three FATALs.
5. **Cost levers already scored:**
   - arm at every grant past the cap (safety J:6, replaced by halving);
   - the back-off (removed: mem-2, W13, W14).

   A schedule that shrinks the garbage term near the tops must keep W4/W12's cycle bounds
   and W13-W15's flush behaviour.
