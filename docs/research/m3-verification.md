##### FOUNDATION #####

### CONFIRMED: CLAIM 1: the cont_stitch aux slot at framebase-5 must be raw u64 == 0 (+0.0), NOT a zero-payload LJ_TTRACE ref, because LJ_TTRACE satisfies tvisgcv() 
EVIDENCE: SOURCE (C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit/src): lj_obj.h:812 tvisgcv(o) = ((itype(o)-LJ_TISGCV) > (LJ_TNUMX-LJ_TISGCV)) with LJ_TISGCV = LJ_TSTR+1 (0xfffffffc); LJ_TTRACE = ~9u = 0xfffffff6 lies inside LJ_TSTR..LJ_TUDATA, so tvisgcv is TRUE for it. lj_gc.h:35 tviswhite(x) = tvisgcv(x) && iswhite(gcV(x)); lj_gc.h:32 iswhite reads (x)->gch.marked; lj_obj.h:836 gcval() = gcrefu & LJ_GCVMASK -> NULL for a zero payload. lj_gc.c:45 gc_marktv's lj_assertG compiles to ((void)g) in release (lj_def.h:372), so nothing catches it. lj_gc.c:310-312 gc_traverse_thread gc_marktv's EVERY slot in [stack+1+LJ_FR2, th->top), which contains framebase-5. vm_x64.dasc:690-693 cont_dispatch sets RB = meta base; vm_x64.dasc:2376-2406 cont_stitch does 'mov TRACE:ITYPE,[RB-40]' (= framebase-5), cleartp, then 'test/jz ->cont_nop', so u64==0 routes to cont_nop.

MY PROBES (all built in the scratchpad against libluajit_stock.a, gcc -O2):
(1) claim1c.c isolates the macro chain with no GC involved: tviswhite(+0.0) = 0, no fault; tviswhite(trace|NULL) SIGSEGVs (exit 139) reading *(uint8_t*)8, and offsetof(GChead,marked) printed as 8. That is the claimed fault, byte for byte.
(2) Reproduced the cited measurement exactly (prototype/coclone/m3/m3trace.c rebuilt and run by me): 'tab A' exit 139 Segmentation fault, 'tab B' exit 0 SURVIVED; 'co A' exit 139, 'co B' exit 0 SURVIVED.
(3) STRONGER, on a GENUINE JIT-stitched thread (400 resumes of a yielding loop makes recff_stitch fire; my frame walk shows the top frame is FRAME_CONT with cont == lj_cont_stitch): the REAL aux slot holds raw=0xfffb0202'6bccc128, itype=0xfffffff6, tvisgcv=1, gcval non-NULL (a live GCtrace). Overwriting it with ((uint64_t)LJ_TTRACE<<47) -> SIGSEGV on the very next lua_gc(LUA_GCCOLLECT). Overwriting with +0.0 -> 'SURVIVED the full GC' and then resumes with exactly the original sequence 80601, 81003, 81406, 81810. Setting it to nil -> SIGSEGV on resume even with NO GC (cleartp(nil) = 0x7fffffffffff), so +0.0 is not interchangeable with nil.
(4) END-TO-END on the shipped code: eris.persist/eris.unpersist of a real stitch-frame coroutine -> 437-byte blob, two full collectgarbage('collect') after restore, then 4 resumes producing 80601,81003,81406,81810 == the untouched twin. MATCH. (tests/m3.lua still reports ALL 33 TESTS PASS.)
IMPACT: No change needed. eris_lj.c:1366-1369 is correct and load-bearing; the comment there is accurate. Two things worth recording rather than acting on: (a) the +0.0 deliberately discards the saved-trace link, so a restored stitch frame re-enters via cont_nop (interpreter) instead of jumping to the stitched trace - I measured the resumed yield sequence to be identical, so this is a pure performance/JIT-warmup degradation, not a semantic one; (b) p_thread (eris_lj.c:730-736) persists EVERY slot in [1+LJ_FR2, top), which includes that aux slot while it still holds a live LJ_TTRACE value. That happens to be benign because lua_type() maps LJ_TTRACE to LUA_TNIL (lj_api.c:222-243, tag-conversion nibble 9 = 0), so it serializes as nil and pass 3 overwrites it with 0 - confirmed by the end-to-end round trip above. It is worth a comment, because it is an internal GC type reaching the generic persist dispatcher by accident rather than by design.

### CONFIRMED: CLAIM 2: an in-range-but-wrong FRAME_LUA bytecode offset is memory-unsafe (BC_RET_Z computes base = base-(bc_a+2)*8 then dereferences [base-16] as a L
EVIDENCE: SOURCE: vm_x64.dasc:4478-4525 (BC_RET / BC_RET_Z) - 'mov PC,[BASE-8]' loads the return pc from the frame word, then 'movzx RAd, PC_RA; neg RA; lea BASE,[BASE+RA*8-16]   // base = base - (RA+2)*8' followed by 'mov LFUNC:KBASE,[BASE-16]; cleartp LFUNC:KBASE; mov KBASE, LFUNC:KBASE->pc; mov KBASE,[KBASE+PC2PROTO(k)]' - two chained dereferences off a base derived solely from bc_a of the instruction before the return pc. PC_RA is 'byte [PC-3]' (vm_x64.dasc:316), i.e. the A field of pc[-1]. lj_frame.h:107 frame_prevl(f) = f - (1+LJ_FR2+bc_a(frame_pc(f)[-1])) uses the identical quantity, so the check is exactly 'the pc's A agrees with the stored link'. The number of nil-fill results comes from PC_RB, which is why the op must also be a real call.

MY PROBES:
(1) MEMORY-UNSAFETY reproduced directly: claim2.c installs a rejected in-range offset on a live suspended thread and resumes. bcofs 2, 5 and 11 in my dup proto and bcofs 5 in the plain proto all give exit 139 Segmentation fault; bcofs 1 (pc[-1] = FUNCF A=3) gives 'PANIC: unprotected error in call to Lua API (5)', exit 1. So an accepted-by-range but wrong offset really does corrupt execution.
(2) THE 103 SWEEP reproduced independently (claim2b.c, my own replica of the eris_lj.c predicate, same 8 scenarios as prototype/coclone/m3/m3frames.c): TOTAL tried=103, rejected by the PAIR = 103, accepted = 0. Per-scenario: 30, 7, 7, 11, 10, 26, 12, 0. Re-running m3frames.exe itself also prints the same per-scenario counts summing to 103 and 'RESULT: OK (0 failures)'.
(3) BOTH CHECKS ARE NECESSARY, quantified: frame_prevl alone rejects only 76/103; the call-op check alone rejects only 100/103. Neither is sufficient.
(4) 'prevl alone missed 2 of the first 3' reproduced exactly: global try #1 bcofs=1 pc[-1]=FUNCV A=7 prevl_ok=0; try #2 bcofs=2 pc[-1]=GGET A=0 prevl_ok=1 (missed); try #3 bcofs=3 pc[-1]=TGETS A=0 prevl_ok=1 (missed). 2 of 3.
IMPACT: Do not remove or weaken either check at eris_lj.c:1353-1360 - I reproduced the SIGSEGV they prevent, and measured that each one catches cases the other does not (76/103 vs 100/103). The claim is accurate as stated and as measured. See the next entry for the one place where its wording over-promises.

### REFUTED: CLAIM 2, sub-claim: that the pair of checks 'is required to reject' an in-range-but-wrong FRAME_LUA offset - i.e. that 103/103 generalises to the pair
EVIDENCE: 103/103 is an artifact of the eight probe protos: none of them contains two call sites at the same base register. I built one that does. Source: 'local t = 0; t = t + f(); t = t + f(); t = t + f(); return t' compiles to CALL A=1 B=2 at bc 3, 6 and 9 (dumped by my probe), so three distinct return offsets (4, 7, 10) all satisfy bc_a == link-2 AND bc_op == BC_CALL.

(1) My replica sweep on that proto: tried=10, rejected by the PAIR = 8, ACCEPTED = 2 - offsets 7 and 10 pass both checks.
(2) Confirmed against the SHIPPED serializer, not just my replica: I persisted that coroutine with eris.persist (581-byte blob), located the FR_LUA record (tag 0, uleb link=24, uleb bcofs=4) at offset 570, rewrote the bcofs byte and recomputed the trailing CRC32 in Lua. Results from erislj_test.exe:
   bcofs 4->7  : ACCEPTED, resume(5) -> yields 'Y', status suspended (one yield skipped)
   bcofs 4->10 : ACCEPTED, resume(5) -> returns 5, status DEAD (two yields skipped, function returned early)
   bcofs 4->5  : REJECTED 'eris-lj: frame 0 pc disagrees with its link'
   bcofs 4->11 : REJECTED 'eris-lj: frame 0 pc disagrees with its link'
No crash in the accepted cases, before or after collectgarbage('collect').
CORRECTION: The pair of checks rejects the MEMORY-UNSAFE wrong offsets (those that would mis-restore BASE or mis-size the result fill); it is not a complete filter on wrong offsets. Any other call site in the same prototype whose base register matches the stored link is accepted, and the restored thread silently resumes at that other call site. The correct statement is 'the pair is what makes an in-range-but-wrong pc memory-safe', not 'the pair rejects an in-range-but-wrong pc'.
IMPACT: eris_lj.c:1353-1360 is not wrong and needs no fix for memory safety - I could not produce a crash through the accepted offsets. What must change is the claim recorded in the design notes (docs/research/m3-frame-codec.md) and the comment at eris_lj.c:1350-1352, which currently read as if the checks reject in-range-but-wrong offsets outright. Concretely: a tampered blob can move any Lua frame's resume point to any other same-base-register call site in the same proto, and the restored coroutine will resume there - in my test the coroutine returned early and went dead instead of yielding twice more. The CRC32 at eris_lj.c:1705 is a corruption check, not a MAC, and is trivially recomputable (I did it in 20 lines of Lua), so it does not close this. If M3's threat model includes hostile blobs rather than only corrupted ones, closing it needs either an authenticated blob or a per-frame witness stronger than the pc (the pc alone is not uniquely determined by link + proto). If the threat model is corruption-only, this is acceptable and should just be documented as a known limit. Separately and NOT verified by me: the call-op check is applied only inside the 'kind == FR_LUA' branch, so a FRAME_CONT continuation pc is range-checked but not op-checked; the CONT base is restored from the link rather than from bc_a so the BC_RET_Z hazard does not apply there, but I did not audit what a wrong contpc's PC_RA/PC_RB can do in cont_ra/cont_cat.

### CONFIRMED: CLAIM 1: For every FRAME_LUA, the proto owning the return PC is uniformly funcproto(frame_func(frame_prevl(f))) — including when frame_prevl lands on 
EVIDENCE: SOURCE (definitive, not inference): the rule IS the VM's own return protocol. BC_RET_Z, prototype/watchdog/luajit/src/vm_x64.dasc:4518-4525 — `movzx RAd, PC_RA; neg RA; lea BASE,[BASE+RA*8-16]; mov LFUNC:KBASE,[BASE-16]; mov KBASE, LFUNC:KBASE->pc; mov KBASE,[KBASE+PC2PROTO(k)]; ins_next`. The VM computes the caller base exactly as frame_prevl does (lj_frame.h:108, prev = f-(2+bc_a(pc[-1])) = newBASE-1), reloads the function from [prev-1], takes THAT proto's constant table, and then continues executing the stored PC. If the PC did not belong to that proto the interpreter would run with a mismatched KBASE. FRAME_VARG sub-case confirmed at vm_x64.dasc:4845-4870: `mov LFUNC:KBASE,[BASE-16]; mov [RD-16], LFUNC:KBASE` copies the LFUNC into the VARG frame's func slot, and the stored delta (RD-BASE) makes frame_prevd(VARG) land on the vararg function's own FRAME_LUA word.
PROBE (mine, independent of the rule): scratchpad/vfy/fv.c + shapes.lua + c1.lua. 29 adversarially chosen suspended-coroutine shapes (vararg entry/nested/tailcall-out-of-vararg, pcall, xpcall, pcall of a C function, coroutine.create(pcall), coroutine.create(<C fn that calls lua_yield>), __index/__concat/__newindex/__lt/__le/__add/__call metamethods, 2-deep metamethod chains, VARG over CONT, ITERC, pairs loops, JIT hot loops, cont_stitch, 8-deep recursion, kitchen sink). For every FRAME_LUA the C side answers "which proto REALLY owns this pc" by scanning every GCproto on g->gc.root (protos are linked there by lj_mem_newgco, lj_gc.c:884-896) and comparing to the rule-derived proto. Result: 95 frames, 42 FRAME_LUA, 0 violations. prev-frame coverage: LUA=11, CP=14, VARG=6, CONT=7, PCALL=4 — all five enumerated cases exercised, every one with a Lua function in the func slot.
DECODE SIDE: 1953 in-range-but-wrong FRAME_LUA bcofs mutations of real blobs fed to the SHIPPED deserializer (scratchpad/vfy/mut.lua): 1953/1953 rejected, 0 accepted, no crash. (The report's 103/103 sweep reproduced and exceeded.)
CORRECTION: The claim holds, but the design report's supporting PREMISE for the FRAME_CP case is false. m3-frame-codec.md §1 asserts "A coroutine whose body is a C function can never be suspended (yield across a C boundary errors), so frame_func(prev) for a FRAME_LUA is always a Lua function". Measured counterexamples: `coroutine.create(pcall)` and `coroutine.create(<plain C function that calls lua_yield>)` both suspend normally, and their bottom FRAME_CP frame's func slot holds a C function (probe prints `funcslot=cfn`). Fast functions and VM-dispatched C functions push no cframe, so lua_yield's cframe_canyield test (lj_api.c:1188-1203) passes. Likewise `pcall(coroutine.yield, x)` leaves a FRAME_PCALL whose func slot is a C function, and after ANY yield the topmost frame word is a FRAME_LUA whose own func slot is the C function coroutine.yield (vm_x64.dasc:1703-1713 sets L->base to the ffunc's base). The rule survives for a different reason than the report gives: a C function executes no CALL bytecode, so frame_prevl can never land on a frame whose func slot is a C function.
IMPACT: No code change required in serializer/eris_lj.c. The encoder (p_thread, ~line 749) and pass 3 of u_thread already check `tvisfunc(prev-1) && isluafunc(funcV(prev-1))` only on `prev`, and only `tvisfunc(f-1)` on the frame's own func slot — which is exactly the invariant that actually holds. Do NOT tighten the f-1 check to isluafunc: that would reject the (legal, round-trippable) shapes above. Worth fixing the comment/premise in docs/research/m3-frame-codec.md §1 so a future maintainer does not "simplify" the check on that false basis.

### CONFIRMED: CLAIM 2: A genuine cross-process symbolic frame round trip works for 8 frame shapes (vararg+tailcall+pcall, cont_ra/cat/nop/condf, ITERC, FRAME_PCALL,
EVIDENCE: Reproduced with the SHIPPED serializer (serializer/eris_lj.c), not a probe re-implementation, and across genuinely separate OS processes. scratchpad/vfy/x.lua: `fv.exe x.lua save <n> <file>` persists shape n and records its address-free frame encoding plus the results the ORIGINAL produces when drained; a second, independent `fv.exe x.lua load <n> <file>` unpersists and drains. 28 of 29 shapes: symbolic encoding (kind/link/bcofs/op/prev-kind/func-slot-kind) identical, continuation results identical, and the raw FRAME_LUA ftsz words DIFFER in every case (proof the PC was rebuilt, not copied). All 8 named shapes covered — vararg+tailcall+pcall (3 variants), cont_ra, cont_cat, cont_nop, cont_condf (from both __lt and __le), ITERC (op[-1]=ITERC measured), FRAME_PCALL (pcall and xpcall), cont_stitch — plus 20 more.
Fresh-proto condition verified directly (in-process control, x.lua inproc): every frame func slot's GCproto is a NEW object after the round trip — fresh=1..9 per shape, shared=0 across all 29 shapes, and 0 FRAME_LUA raw ftsz words equal.
cont_stitch specifically: I measured the ORIGINAL aux slot as 0xfffb020bbb560020 — itype ~9 = LJ_TTRACE, i.e. a live GCtrace, exactly the report's premise (recff_stitch's IR, lj_ffrecord.c:110-140, is what plants it at runtime; the C-level frame it builds is undone at :145-148). After restore in a fresh process the aux slot is 0x0000000000000000, the thread survives three full collectgarbage("collect") passes, and resumes to 80601 — byte-identical to the value the report cites.
CORRECTION: "Zero frame words copied raw" is true of the frame RECORDS but false of the blob. p_thread (serializer/eris_lj.c, the slot loop at ~line 730) persists every slot in [1+LJ_FR2, top_ofs) with no frame-word skipping, and a frame word reads as a denormal double (itype 0), so each one travels as a TAG_NUM with its 8 raw bytes. Measured by searching the blob for the exact little-endian words (scratchpad/vfy/leak.lua): the "plain" blob contains FRAME_LUA ftsz 0x00000276d20f1d34 (a pointer into proto bytecode); the cont-ra blob contains the raw continuation address 0x00007ff707f07df2 (an lj_cont_* address inside the executable) and the raw contpc. The design report's §3 pass 2 explicitly specified skipping frame-word slots ("every slot ... whose isframeword[] bit is clear"); the shipped code does not.
IMPACT: Two things to act on in serializer/eris_lj.c.
(1) The unskipped frame-word slots are harmless for correctness — pass 3 of u_thread overwrites every one, and I confirmed no restore path reads them — but they mean (a) an OC save file leaks LuaJIT heap addresses AND executable code addresses, i.e. a free ASLR oracle for anyone who can read a save file, (b) blobs for identical states are not byte-reproducible across processes, so any hashing/dedup/diffing of blobs is broken, (c) ~9 wasted bytes per frame. Implement the isframeword[] skip the design called for: mark f, and for CONT also f-2/f-3 (and f-4 when stitch), and write a 1-byte placeholder instead.
(2) A hole the 8-shape sweep never touched, and which OC will hit: a coroutine suspended ANYWHERE inside `for k,v in pairs(t)` or `for k,v in next,t` cannot be persisted at all. BC_ISNEXT (vm_x64.dasc:4378-4379) writes (uint64_t)LJ_KEYINDEX<<32 (lj_obj.h:288, 0xfffe7fff) into the loop's control slot; that TValue reads as light userdata and p_thread raises "cannot persist light userdata by value" (measured: slot 7 = fffe7fff00000002). `for i,v in ipairs(t)` fails differently — the iterator slot holds the internal ipairs_aux C function, unreachable from _G and so impossible to put in perms: "cannot persist a C function by value". Only the manually split form (`local f,s,c = pairs(t)`) survives. tests/m3.lua has no pairs/ipairs-with-yield case, so 33/33 green hides this. Fix: give the LJ_KEYINDEX control value its own wire tag (restore as (uint64_t)LJ_KEYINDEX<<32 | idx) and give the internal iterator C functions built-in permanent ids. Also note tests/m3.lua covers neither ITERC nor cont_stitch — the only coverage those have is the throwaway probe, so they are worth porting into the suite.
Minor: the CS_HOOK refusal looks like dead code on this build — every way I tried to yield from a debug hook (count and line hooks, set inside and outside the coroutine) fails with "attempt to yield across C-call boundary". Keep the check, but the report's warning that "the CHECKHOOK watchdog hook must never call coroutine.yield" is moot here: it cannot.

### CONFIRMED: CLAIM 1: cframe != NULL is the necessary and sufficient test for a thread that is running or resuming another, but it does NOT catch the main thread: 
EVIDENCE: SOURCE. lj_vm_resume sets L->cframe = rsp|CFRAME_RESUME (vm_x64.dasc:583,590); vm_call/vm_pcall set L->cframe = rsp (vm_x64.dasc:632); the coroutine_yield ffunc explicitly zeroes it (`xor RDd,RDd` then `mov aword L:RB->cframe, RD`, vm_x64.dasc:1709-1710); lua_yield sets L->cframe = NULL (lj_api.c:1201); unwinding out of a resume restores SAVE_CFRAME, which vm_resume had set to 0 (vm_x64.dasc:585-587). lua_status is literally `return L->status` (lj_api.c:97-100). g->cur_L is written on VM ENTRY only (vm_x64.dasc:595 vm_resume, 636 vm_call, 674 vm_cpcall), restored after a C-function call (4917) and after the coroutine.resume ffunc (1625) — but lua_resume (lj_api.c:1229-1239) contains no restore.

PROBE c1.c (scratchpad/verify/c1.c). Reproduced m3probe2 Q3 exactly: with `lua_resume(co)` driven straight from C, the main thread is `status=0 cframe=NULL base_ofs=2 top_ofs=3`, and lib_base.c:574-579's chain classifies it "suspended" from the coroutine's vantage. After lua_resume returns to C, `g->cur_L == co`, NOT main — measured stale, so unusable. status==LUA_OK was observed simultaneously on running, "normal", never-started and dead-by-return threads — unusable. P4 found no quiescent thread that retains a cframe: yield-from-Lua, yield-from-metamethod, dead-by-error, lua_pcall-on-a-coroutine and lj_state_cpgrowstack overflow all end cframe==NULL.

PROBE c1b.c (biconditional sweep). 76 thread observations over 11 shapes (plain pcall, depth-1/2/3 resume chains, coroutine.wrap, pcall-inside-coro, __index metamethod, for-iterator, xpcall handler, live yielded sibling, sibling dead by error, C-driven resume). `cframe != NULL <=> coroutine.status in {running, normal}` held in 75/75 non-exception cases, and produced exactly ONE exception — the idle main thread under a C-driven resume. 0 failures.

PROBE c3.c (against the real serializer). eris.persist(main) called FROM A COROUTINE — OC's exact pattern, the only route that reaches check_persistable_thread's mainthread branch — is refused with "eris-lj: cannot persist the main thread".
CORRECTION: One phrasing refinement, not a refutation: coroutine.status derives "normal" from `co->base > stack+1+LJ_FR2` (lib_base.c:577), NOT from cframe. cframe is the correct predicate for the live-C-stack question the gate is asking, but the two are separate signals, and that separation is what makes the restore-side hole below exploitable.
IMPACT: No code change needed for the gate itself: C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c:685-701 implements exactly the right predicate, and the co==L check is not redundant (it is the only thing covering a host that calls the persist C function directly on a non-main lua_State, where cframe is also NULL). Two nuances worth recording. (1) cframe_canyield is NOT a substitute: a main thread inside lua_pcall has cframe != NULL with canyield == 0 (measured c1 P2), so the code's use of plain `cframe != NULL` rather than the CFRAME_RESUME bit is correct. (2) TEST GAP: serializer/tests/m3.lua:246-258 does not actually exercise the mainthread branch. It calls eris.persist from the main thread, so `co == L` fires first and yields the "running" message; the test's own comment accepts either. Replace it with the c3.c shape — pass the main thread into a coroutine and persist from there — which is what OC does and which is currently unverified by the suite.

### CONFIRMED: CLAIM 2: coclone2's report that a normally-finished coroutine "prints as suspended" was a C-API artifact, not a real ambiguity: coroutine.status is de
EVIDENCE: MECHANISM, at source. lib_base.c:566-580 confirms coroutine.status is pure derived state. The coroutine.resume ffunc clears the callee stack in the VM: `mov RA, L:PC->base / mov KBASE, L:PC->top / mov L:PC->top, RA  // Clear coroutine stack.` (vm_x64.dasc:1626-1628), after copying the results out. lua_resume (lj_api.c:1229) has no equivalent step.

PROBE c2.c — coclone2 section C re-measured. never-started: status=0 base_ofs=2 top_ofs=3 -> "suspended". Finished by lua_resume from C with 1 result: status=0 base_ofs=2 top_ofs=3, result still at base -> "suspended" (coclone2's report REPRODUCED). The identical coroutine finished through coroutine.resume: base_ofs=2 top_ofs=2 -> "dead". Finished by lua_resume from C with ZERO results: top==base -> "dead", so the discriminator really is "results left on the stack", not "which API finished it". Section F: hand-writing co->top = co->base flips the answer to "dead" and co->top = co->base+1 flips it back to "suspended", with the thread still resumable — top vs base is the whole signal.

OPERATIVE CONCLUSION HOLDS, and the shipped code honours it. PROBE c3.c against the real serializer: a thread finished by lua_resume from C with two results round-trips 2/4 -> 2/4 (base_ofs/top_ofs byte-faithful), status preserved, coroutine.status identical, and resuming source and restored gives byte-identical results (both `false, "attempt to call a string value"`). The function-result variant round-trips 2/3 -> 2/3 and both source and restored return `CALLED:9`.
CORRECTION: The PREMISE is refuted; the CONCLUSION is confirmed. It is a real ambiguity in LuaJIT's thread representation, not merely a C-API display artifact. Probe c2.c section D: a coroutine that RETURNED A FUNCTION and was finished by lua_resume is bit-identical to a never-started coroutine — same status (0), same base_ofs (2), same top-base (1), a GCfunc at base. Nothing in the lua_State separates them. lua_resume on the dead one takes the `status == LUA_OK` "initial resume (like a call)" branch (vm_x64.dasc:589-592) and CALLS the returned function: measured `lua_resume(dead, 1 arg) -> st=0, result="CALLED-THE-RESULT:7"`. So "top == base is the only thing distinguishing dead from never-started" is true as a statement about the only available signal and false as a statement that the signal is reliable — when results are present, the signal is simply absent and LuaJIT guesses "never-started".
IMPACT: No change needed to the persist/restore of base_ofs and top_ofs in eris_lj.c:719-727 and 1413-1414 — they are correct as written, and normalising either would resurrect a dead thread or kill a never-started one. But the premise being wrong changes what the docs should say and what hosts must be told: the serializer faithfully reproduces a LuaJIT ambiguity it did not create and cannot fix, so the note already at m3-oc-shapes.md:190 ("hosts that C-resume a restored thread should check coroutine.status first") should be strengthened — checking coroutine.status does NOT help here, because status itself says "suspended" for this shape. The only safe host rule is: do not C-resume a thread you finished with lua_resume; drain its results (or use coroutine.resume) before persisting.

### CONFIRMED: DERIVED FINDING (consequence of CLAIM 2 being right about not normalising): u_thread validates base_ofs for suspended threads only. Design rule T4 (m3
EVIDENCE: CODE. eris_lj.c:1225-1227 constrains base_ofs only to `>= 1+LJ_FR2` and `<= top_ofs <= need`. eris_lj.c:1258-1263 enforces `nframes == 0` for any non-LUA_YIELD status. But the chain-termination check that would pin base_ofs, eris_lj.c:1320-1321 `if (nframes && at != LJ_FR2)`, is guarded by nframes — so with zero frames base_ofs is completely unconstrained. Because base/top are carried on the wire rather than derived (correctly, per CLAIM 2), the restore is the ONLY thing that can constrain them, and here it does not.

REPRODUCED SIGSEGV. scratchpad/verify/craft.lua takes a legitimate blob for a never-started coroutine (`tag=12 status=0 need=39 base_ofs=2 top_ofs=3`), changes ONE byte (base_ofs 2 -> 3), recomputes the CRC-32 (poly 0xEDB88320, eris_lj.c:190-207), and calls eris.unpersist. Result: ACCEPTED. The restored thread reports `coroutine.status == "normal"` (lib_base.c:577 fires on base > stack+1+LJ_FR2). `collectgarbage("collect")` then segfaults. gdb backtrace: `SIGSEGV in propagatemark <- lj_gc_fullgc <- lua_gc <- lj_cf_collectgarbage`. Mechanism: gc_traverse_frames (lj_gc.c:295) walks `frame = th->base-1` while `frame > bot+LJ_FR2` and calls `frame_func(frame)`, which for base_ofs=3 reads the nil FR2 slot at stack+1; gcval() of a nil TValue is NULL, and `funcproto(fn)->framesize` (lj_gc.c:298) dereferences it.

REACHABILITY. Not producible by persist: the gate requires cframe == NULL, and every cframe==NULL thread with base > stack+1+LJ_FR2 is either LUA_YIELD (frames validated) or dead-by-error (refused — measured c2 section E, both the C and ffunc paths leave base != top). So this is crafted/corrupt-blob robustness — precisely the threat model the T1-T5/F1-F8/U1-U2 tables were written for, and the trailing CRC-32 is a corruption check, not a MAC.

FIX VERIFIED on a scratch copy (scratchpad/verify/eris_fix.c), inserted immediately after the base/top range check in u_thread:
  if (status != LUA_YIELD && base_ofs != (uint64_t)(1 + LJ_FR2))
    luaL_error(L, "eris-lj: non-suspended thread must have base at the stack "
                  "bottom (got %d)", (int)base_ofs);
With it: M1 82/82, M2 55/55, M3 33/33 still pass, and the crafted blob is rejected cleanly instead of segfaulting.
CORRECTION: Not a correction to CLAIM 2 — this is the unpaid half of its bill. Choosing not to normalise base_ofs/top_ofs (correctly) transfers the entire validation burden to u_thread, and u_thread discharges it only for status == LUA_YIELD.
IMPACT: Apply the three-line check above to C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c, right after line 1227. Verified non-breaking against all 170 existing tests. Second, smaller item found in the same sweep: check_persistable_thread's `&& !(co->base == co->top)` at eris_lj.c:698 is dead code. Measured (c2 section E) that a dead-by-error thread always has base != top — C lua_resume leaves base_ofs=6 top_ofs=8, and the coroutine.resume ffunc leaves base_ofs=6 top_ofs=7 because its error path pops only the message (vm_x64.dasc:1670-1680). So the condition is in practice a blanket refusal of every dead-by-error thread (c3 section 4 confirms: "cannot persist a thread with a pending error status and a live stack"). Either drop the misleading sub-condition and say plainly that dead-by-error is refused, or decide that a crashed OC kernel should be persistable — note the asymmetry that u_thread ACCEPTS LUA_ERRRUN/ERRMEM/ERRERR blobs that persist can never emit.

### CONFIRMED: CLAIM 1 (empirical core): two lua_loadx closures joined to one CLOSED upvalue can be re-pointed to a fresh OPEN upvalue on a thread stack slot; they s
EVIDENCE: Reproduced from scratch, not trusted: C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\probeC_backpatch.c (25/25 checks pass). Real string.dump bytecode loaded twice with lua_loadx(mode "b") -> two closures with DISTINCT upvalues; lua_upvaluejoin merges them onto one CLOSED upvalue (verified closed==1); a byte-for-byte replica of eris_lj.c's elj_finduv creates an OPEN upvalue on co's live slot; setgcref + lj_gc_objbarrier on each referrer. Then: both lua_upvalueid()s equal and equal to the new uv; survives 3 full GCs, a 3000-iteration driven incremental cycle, and 3 more full GCs; still OPEN and still aliasing the same slot; present on co->openupval and on the g->uvhead ring and absent from g->gc.root (correct for an open uv); f1(1) drove the THREAD slot 5->6, f2(10) saw it and drove it 6->16, and a raw C write of 42 to the slot was visible through f1; lj_func_closeuv(co, slot) then closed it in place, unlinked it from both chains, moved it onto gc.root, and both closures kept sharing (43, 44) through 3 more full GCs. End-to-end through the SHIPPED serializer: C:\Users\astro\...\scratchpad\probeD_ordering.lua, 13/13 pass, exercising the actual cross-thread ordering (escapee persisted first, sibling closures living only on the coroutine's own stack, table-held siblings, two threads, GC between every step).
IMPACT: None — this part of the foundation holds exactly as described.

### CONFIRMED: CLAIM 1 (necessity): the closed->open back-patch is required; without it the cross-thread ordering case is broken.
EVIDENCE: A/B on a scratchpad copy of the shipped file (C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\nobp_eris_lj.c) with elj_repoint_referrers gated off by an env var. With it: probeD 13/13. Without it: 5 failures ('attempt to perform arithmetic on upvalue v (a nil value)'), and the shipped C:\Users\astro\Downloads\OC-LuaJIT\serializer\tests\m3.lua dies at line 167. Note a detail the claim understates: the back-patch is not just for the joined siblings — u_function's TAG_UPVALOPEN branch never calls lua_setupvalue, so without elj_repoint_referrers even the OWNING closure keeps the lua_loadx placeholder and never sees the open upvalue at all.
IMPACT: None — confirms the code as shipped. Worth knowing that tests/m3.lua already regression-guards this (it errors out, not just fails an assert).

### CONFIRMED: CLAIM 1 (barrier): lj_gc_objbarrier on each referrer is required.
EVIDENCE: Demonstrated as a real use-after-free, not argued: C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\probeE_barrier.c drives the incremental collector with direct lj_gc_step calls (stepmul=1, 60k-object heap) until gc.state==GCSpropagate with the referrer closure BLACK, then stores a freshly allocated (white) open upvalue into its uvptr. WITH the barrier: uv goes white->gray, survives the cycle, closure call returns 8. WITHOUT it: uv stays white, the SAME cycle collects it, co->openupval comes back EMPTY and the closure's uvptr dangles. Root cause verified in C:\Users\astro\Downloads\OC-LuaJIT\prototype\watchdog\luajit\src\lj_gc.c: gc_traverse_thread does NOT mark a thread's open upvalues, gc_fullsweep(g, &gco2th(o)->openupval) sweeps them, and gc_mark_uv only re-marks GRAY ones — so the referrer closure is the open upvalue's only marker.
IMPACT: None — the barrier calls in elj_repoint_referrers are load-bearing and must not be 'simplified' away. For reference, lua_upvaluejoin (lj_api.c:917-928) is literally the same pair of operations: setgcrefr + lj_gc_objbarrier.

### CONFIRMED: CLAIM 1 (why not in-place): in-place closed->open mutation is unsafe because gc_mark blackens closed upvalues while lj_func_closeuv asserts open ones 
EVIDENCE: Both halves are real. lj_gc.c gc_mark: 'else if (gct == ~LJ_TUPVAL) { gc_marktv(g, uvval(uv)); if (uv->closed) gray2black(o); }'. lj_func.c lj_func_closeuv: 'lj_assertG(!isblack(o), "bad black upvalue")'. Blackening also observed at runtime (probeC: 'a CLOSED upvalue is observed BLACK during a GC cycle').
CORRECTION: The stated reason is the weaker of the two and would not bite on the shipped build. lj_assertG compiles out unless LUA_USE_ASSERT, and libluajit_stock.a is built without it — that assert can never fire in production. The decisive reason is list membership, which the claim omits: a CLOSED upvalue is linked into g->gc.root through GCHeader.nextgc (lj_gc_closeuv: 'setgcrefr(o->gch.nextgc, g->gc.root); setgcref(g->gc.root, o)'), and probeC confirmed the placeholder sits 4 nodes into gc.root at runtime; an OPEN upvalue must instead live on L->openupval through that SAME nextgc field, plus the g->uvhead doubly linked ring. Converting in place therefore needs an O(heap) unlink from a singly linked gc.root with no back pointer, and getting it wrong corrupts the root list (objects lost or swept twice) in a release build rather than tripping an assertion.
IMPACT: No code change. The conclusion the code was built on is correct and in fact stronger than stated; only the comment/rationale is understated. If anyone ever revisits this, the argument to write down is 'a closed upvalue is on gc.root, an open one is on openupval+uvhead through the same link field', not the assert.

### CONFIRMED: CLAIM 2 (LuaJIT half): a cont_hook frame is reachable ONLY from a native C hook calling lua_yield; a Lua hook installed with debug.sethook cannot yiel
EVIDENCE: Structural: across the whole pinned tree, 'setcont(top, lj_cont_hook)' occurs exactly once — lj_api.c:1208, inside lua_yield's 'Yield from hook' branch, reached only when cframe_canyield(cf) AND hook_active(g). The asm fast path .ffunc coroutine_yield (vm_x64.dasc:1703-1714) has no hook branch at all — it only tests CFRAME_RESUME — so Lua-level coroutine.yield can never build this frame; only the C-API lua_yield can. Reproduced both directions in C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\probeB_conthook.c: a native C hook (lua_sethook(co, chook, LUA_MASKCOUNT, 20)) calling lua_yield gives lua_resume -> LUA_YIELD with top frame FRAME_CONT, cont == lj_cont_hook (chain CONT/VARG/CP); and the same shape via debug.sethook gives 'attempt to yield across C-call boundary', coroutine dead. Widened in probeA_hook.lua: count, line, call and return masks all fail identically. The shipped guard was verified to fire — with real (_G-flattened) perms, eris.persist on the C-hook-yielded thread returns 'eris-lj: cannot persist a thread yielded from a hook' (eris_lj.c:771); the read side refuses CS_HOOK too (eris_lj.c:1287).
CORRECTION: One level of misattribution in the mechanism: callhook (lj_dispatch.c:366-392) calls g->hookf DIRECTLY. It is lib_debug.c's hookf trampoline (lines 288-301) that runs the Lua function through lua_call(L, 2, 0), which is what pushes a cframe without CFRAME_RESUME so cframe_canyield (lj_frame.h:292) is false. Same conclusion, one frame lower. Also worth recording: debug.sethook routes a C-function hook through that same trampoline, so even debug.sethook(co, <a C function>, ...) cannot yield.
IMPACT: None for eris_lj.c — the persist and unpersist guards are correct and were observed to fire.

### REFUTED: CLAIM 2 (OC half): OpenComputers installs only Lua hooks, so it can never produce a cont_hook frame.
EVIDENCE: True for STOCK OC, which I could check directly against sources present on this machine: machine.lua's hook is the Lua function checkDeadline (debug.sethook(co, checkDeadline, "", hookInterval) at lines 847, 718, 1532; the count=1 re-arm at line 47), and jnlua.c contains no lua_sethook at all — the Java side never installs a native hook. FALSE for OC-LuaJIT as designed: C:\Users\astro\Downloads\OC-LuaJIT\prototype\watchdog\harness.c installs watchdog_hook, a NATIVE C hook, via lua_sethook(co, watchdog_hook, LUA_MASKCOUNT|CALL|RET|LINE, 1) from another thread (definition at line 247, arming at 482 and re-arming at 494), and docs/watchdog.md plus docs/research/wd-checkhook-internals.md make that the shipped watchdog design. It cannot produce a cont_hook frame only because watchdog_hook raises a catchable error with lua_error and never calls lua_yield. Two further facts I verified that sharpen this: (1) jnlua.c:2209 shows OC's Java-backed functions yield through the C-API lua_yield — the very function with the hook branch — so the separation rests entirely on cframe_canyield being false inside a Lua hook; (2) hook_active does not leak when checkDeadline's error is swallowed by a sandbox pcall — err_unwind calls hook_leave for FRAME_CP-with-resume (lj_err.c:155) and for FRAME_PCALL (lj_err.c:181), while FRAME_PCALLH deliberately does not, and vm_x64.dasc:1531-1534 shows the pcall ffunc folding the HOOK_ACTIVE bit into the frame type to make that distinction. I checked (2) specifically because a leak there would turn any later JNLua component call into a cont_hook frame; it does not leak. Separately confirmed at runtime (probeB part d): LuaJIT hook state is GLOBAL (g->hookmask/g->hookf) — debug.sethook's thread argument is discarded, so a hook 'armed on a coroutine' fires on every thread.
CORRECTION: The invariant that actually protects the M3 guard is not 'OC installs only Lua hooks' — this port installs a native C hook by design. It is 'no hook in this system may call lua_yield'. Stock OC satisfies it because its hook is a Lua function; OC-LuaJIT satisfies it because watchdog_hook raises an error instead of yielding.
IMPACT: No code change in C:\Users\astro\Downloads\OC-LuaJIT\serializer\eris_lj.c — the CS_HOOK refusals at lines 771 and 1287 are correct and were observed firing. What changes is their status: they are NOT unreachable belt-and-braces for this port. Two follow-ons worth acting on: (a) make 'the watchdog hook must never call lua_yield' an explicit, stated constraint on prototype/watchdog/harness.c and on any future 'yield to the host on deadline' variant of the watchdog — the moment such a hook yields, every snapshot taken while the coroutine is suspended in it becomes unpersistable; (b) the guard message 'cannot persist a thread yielded from a hook' is the error a server operator would see, so it should name the watchdog as the likely cause rather than reading like an impossible case.

### CONFIRMED: CLAIM 1: The OC kernel is suspended at machine.lua:1540 (coroutine.yield(result[2])) inside pcall(main) at machine.lua:1548, and its frame chain is ex
EVIDENCE: SOURCE (fetched from the GTNH repo and line-numbered myself, never trusting the report): machine.lua:1510 `local function main()`; :1512 `coroutine.yield()` (the boot yield); :1540 `args = table.pack(coroutine.yield(result[2])) -- system yielded value`, sitting directly in main's `while true` loop `else` branch; :1548 `return pcallTimeoutCheck(pcall(main))`. Every other coroutine.yield call site (703 sgcco, 856 sandbox resume wrapper, 879, 1094 synchronized-call invoke, 1409/1418/1448 pullSignal) runs in a CHILD coroutine, so 1512 and 1540 really are the kernel's only two yield points. NativeLuaArchitecture.scala:321-322 settles the VARG question: `lua.load(... machine.lua, "=machine", "t")` then `lua.newThread() // Left as the first value on the stack.` -- the compiled CHUNK itself is the thread body -- driven by `lua.resume(1, ...)` (L204/209/233/235) and saved with `persistence.persist(1)` (L407).

PROBE (mine, written from scratch against lj_frame.h, not copied from m3frames.c/framewalk.c): C:/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/vprobe/kframes.c replicates OC's exact drive pattern (lua_newthread + luaL_loadbuffer + lua_resume from C). Result at BOTH the 1512 boot yield and the 1540 system yield, and again after further loop iterations:
   [0] slot=20 LUA   link=48  func=C ffid=35 (coroutine.yield)
   [1] slot=14 PCALL link=16  func=Lua      (main)
   [2] slot=12 LUA   link=56  func=C ffid=21 (pcall)
   [3] slot= 5 VARG  link=16  func=Lua      (the chunk)
   [4] slot= 3 CP    link=16
   depth=5, chain ends at slot 1 == stack+LJ_FR2
Exactly the claimed order and depth. A second probe (rtcmp.c, same directory) round-trips that thread through the real eris_lj and the RESTORED chain is identical word for word: LUA@19/40 PCALL@14/16 LUA@12/56 VARG@5/16 CP@3/16, same base/top, and it resumes, loops, and unwinds back out through PCALL+VARG+CP returning through pcall.
CORRECTION: Two wording/fragility nuances, neither of which makes the claim false. (a) The FRAME_VARG frame arises because the entry function is VARARG, not because it is a chunk. Probe P4: a plain `function(...) ... end` coroutine body produces the identical 5-frame chain including VARG; probe P3: `function() ... end` produces 4 frames with no VARG. Main chunks are always vararg, so the conclusion holds, but the stated cause is loose -- and it matters for test design (a closure-bodied 'mini kernel' does not exercise the path). (b) Depth 5 holds only because `pcall` at :1548 is a NON-tail call, which is true solely because of the `pcallTimeoutCheck(...)` wrapper. Probe P2: with a plain `return pcall(main)` BC_CALLT consumes both the chunk frame and the VARG frame and the chain collapses to 3 frames -- LUA(yield)/PCALL(main)/CP -- with the pcall C function sitting in the CP frame's func slot.
IMPACT: No code change needed: eris_lj.c is generic over the chain and I proved it round-trips the real shape. The gap is COVERAGE. serializer/tests/m3.lua's 'mini-kernel (machine.lua's shape)' builds the thread with coroutine.create(closure), so it never produces the entry-VARG frame that every real OC save has -- the actual OC shape was untested until this session. My replacement test (22/22 passing) is at .../scratchpad/vprobe/kernel_rt.lua: it builds the kernel with load()+coroutine.create(chunk), round-trips at both the 1512 and 1540 yields, plus the tail-call variant, VARG-over-VARG nesting, and fresh/dead threads. Worth folding into tests/m3.lua. Also worth a note in the docs that the 5-frame shape is contingent on GTNH's pcallTimeoutCheck wrapper.

### CONFIRMED: CLAIM 2: Frames should be emitted top-down with NO stored stack positions -- only a per-frame link (bytes to the next-outer frame word) -- with positi
EVIDENCE: MECHANISM, in the shipped code: p_thread (eris_lj.c:740-789) walks `for (f = co->base - 1; f > bot; ...)` top-down and writes only kind + link (`(char*)f - (char*)prev` for FR_LUA, `frame_sized(f)` for delta frames) + a bytecode offset -- no address reaches the wire. u_thread (eris_lj.c:1300-1326) derives `at = base_ofs-1`, then `prev_at = at - link/8`, requiring `prev_at < at` (strict descent), `at > LJ_FR2`, `at < top_ofs`, and finally `at == LJ_FR2` exactly. co->base/co->top/co->status/cframe are set only at the very end (1408-1412); co->top is advanced after every pass-1 slot write (1252). All as claimed.

WHY THE EXACT-TERMINATION RULE IS RIGHT (source, mine): lj_gc.c:292-306 gc_traverse_frames loops `for (frame = th->base-1; frame > bot+LJ_FR2; frame = frame_prev(frame))`, dereferencing frame_func(frame) and funcproto(fn)->framesize on every frame and feeding lj_state_shrinkstack -- so a chain that misses stack+LJ_FR2 is walked by the GC, and the func-slot check is load-bearing too.

WHY IT IS STRUCTURALLY GUARANTEED, not luck: lj_state.c:173-185 sets base = stack+1+LJ_FR2; lj_api.c:1229-1234 lua_resume passes api_call_base(L,nargs) (lj_api.c:1100-1107 -- it returns the NEW base, func at newbase-2); vm_x64.dasc:581,635-640 sets PC = FRAME_CP + RA - L->base and ins_call stores it at newbase-1. So prev = (newbase-1) - (newbase - base) = base-1 = stack+LJ_FR2 for any thread that has never had a frame pushed. Measured CP link = 16 in every shape I probed.

ADVERSARIAL: mut.lua (scratchpad/vprobe) corrupts frame records and RE-SEALS the CRC (I reimplemented eris_crc32 in Lua and asserted it reproduces the serializer's own checksum, otherwise every mutation was masked by 'checksum mismatch'). Every targeted corruption is rejected with a precise error: bottom kind -> VARG/LUA/PCALL => 'bottom frame is not a resume frame'; link 16->24 or ->32 => 'frame chain does not descend'; link ->8/->17/->0 => 'frame link N is not a valid frame size'. Then an EXHAUSTIVE single-byte sweep of the entire frame region (blob bytes 355-387 = nframes, all four frame records, nuv, env tag), all 255 values per byte, CRC re-sealed: 8415 mutations, 6373 refused, 2042 produced threads that I resumed twice and GC'd -- ZERO faults. The `link < 16` floor rejects nothing legitimate: the minimum real link is 16 bytes for every frame kind (FRAME_LUA is (1+LJ_FR2+bc_a)*8 with bc_a=0; VARG/PCALL/CP deltas are 2 slots), which I measured directly in probe P7.

Baseline preserved: tests/m3.lua still 33/33; tests/m1.lua/m2.lua untouched.
CORRECTION: THE PASS ORDER IN THE CLAIM IS INVERTED RELATIVE TO WHAT SHIPS. The claim -- and the design doc it came from, docs/research/m3-frame-codec.md:259-274 ('pass 1 read the frame records ... using link ONLY / pass 2 read the stack values') -- says derive+validate first, slot values second. eris_lj.c does the opposite: p_thread emits the slot values (line 731) BEFORE the frame count and records (line 745), and u_thread reads them in that order (Pass 1 slots at 1248, Pass 2 frames at 1259). The wire format forces it, so this is not a coding slip that can be patched in place. Secondary, smaller: FR_C is accepted as the bottom frame (`fr[nframes-1].kind != FR_C && != FR_CP`), but no live suspended thread can have one -- vm_resume unconditionally sets FRAME_CP (vm_x64.dasc:581) and anything entered via vm_call/vm_pcall has cframe != NULL and is refused by check_persistable_thread. I confirmed it is reachable: flipping the bottom kind byte 5->1 in a re-sealed blob is ACCEPTED and yields a 'suspended' thread that resumes, returns, dies and survives a full GC (benign here, but an unreachable-in-practice shape the validator lets through). Cosmetic third: 'NO stored stack positions' is true of frames only -- base_ofs, top_ofs and open-upvalue slots are stored as offsets (never addresses), and base_ofs is redundant given the links (base_ofs = LJ_FR2+1+sum(links)/8) but is not cross-checked against the derived chain; a wrong base_ofs still fails the chain checks, so it is harmless.
IMPACT: 1) The ordering matters if you relied on 'nothing happens until the chain validates'. As shipped, the ENTIRE slot graph is unpersisted -- including any spkey/__persist reconstruction closures the blob asks to be CALLED -- before a single frame-chain check runs. A blob with a clean slot section and a garbage frame chain still gets to run its restore closures and allocate the full graph before being rejected. If that property is wanted, the frame block has to move ahead of the slot block in the wire format (p_thread ~line 731 vs 745, u_thread Pass 1 vs Pass 2) and ERIS_LJ_FORMAT must be bumped. If it is not wanted, fix the sentence in docs/research/m3-frame-codec.md:259-274 and :395 so the doc stops describing an order the code does not implement. 2) Tighten the bottom-frame check in u_thread (eris_lj.c:1323-1325) to FR_CP only -- it costs nothing and removes the only hole the sweep found. 3) Context you should have when reading the sweep numbers: the frame region is clean, but re-sealed single-byte mutations elsewhere in the blob DO SIGSEGV -- they land in the embedded raw LuaJIT bytecode dump (blob bytes 78+ begin with ESC 'L' 'J'). That is the trust boundary eris_lj.c's own header already states ('blobs must come from trusted storage'), and the CRC is explicitly a checksum, not a MAC, so any blob can be re-sealed. The frame codec's structural validation is defence-in-depth on top of a trusted-input assumption, and it holds; the bytecode loader is the part that does not, and nothing in M3 changes that.


##### REVIEW #####

######## LENS: codec-fidelity ########

### [critical] real-bug : Restore is not GC-safe: lj_state_shrinkstack can halve the thread's stack mid slot-pass (heap overflow, no tampering needed)
FIX: Minimal fix, entirely inside `u_thread`'s pass 1 in C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c (currently lines 1262-1270). Replace:

```c
  for (i = 1 + LJ_FR2; i < (ptrdiff_t)top_ofs; i++) {
    unpersist(I);                       /* ... value */
    stack = tvref(co->stack);
    copyTV(co, stack + i, L->top - 1);  /* NOBARRIER: threads are never black */
    co->top = stack + i + 1;
    lua_pop(L, 1);
  }
  stack = tvref(co->stack);
  for (i = (ptrdiff_t)top_ofs; i < (ptrdiff_t)need; i++) setnilV(stack + i);
```

with:

```c
  /* Publish the whole declared span BEFORE the first value. co->base is still
   * at the bottom, so gc_traverse_frames' answer is just co->top - stack, and
   * gc_traverse_thread ends in lj_state_shrinkstack(th, that). Holding top at
   * top_ofs keeps `used` maximal, and LuaJIT's own guard (4*used < stacksize)
   * then guarantees any halving still contains every slot this pass writes.
   * The slots are already nil: stack_init and resizestack clear what they
   * hand out, and GCSatomic keeps everything above top nil. */
  stack = tvref(co->stack);
  co->top = stack + top_ofs;
  for (i = 1 + LJ_FR2; i < (ptrdiff_t)top_ofs; i++) {
    unpersist(I);                       /* ... value */
    stack = tvref(co->stack);
    copyTV(co, stack + i, L->top - 1);  /* NOBARRIER: threads are never black */
    lua_pop(L, 1);
  }
  /* A GC may still legitimately have shrunk the stack below `need` when
   * top_ofs is small, so clamp this fill to the real allocation. */
  stack = tvref(co->stack);
  {
    ptrdiff_t lim = mref(co->maxstack, TValue) - stack;
    if ((ptrdiff_t)need < lim) lim = (ptrdiff_t)need;
    for (i = (ptrdiff_t)top_ofs; i < lim; i++) setnilV(stack + i);
  }
```

Two changes: (1) publish `co->top = stack + top_ofs` up front and stop advancing it per slot, so `lj_state_shrinkstack` can never halve below what the pass writes; (2) clamp the trailing nil-fill to `co->maxstack` instead of the wire's `need`, which is the second overflow site.

The existing comment above the loop ("co->top is kept above every written slot, because gc_traverse_thread nils everything from top upwards during GCSatomic") documents only half of `gc_traverse_thread`; it should be extended to name the `lj_state_shrinkstack` tail as the reason top is published early. Passes 2-5 need no change: they re-fetch `tvref(co->stack)` after every allocating step and only address slots below `top_ofs`.

Worth adding to `serializer/tests/m3.lua`: the existing 33 tests all use shallow coroutines, so nothing there can reach the `2*(LJ_STACK_START+LJ_STACK_EXTRA) < stacksize` guard. A deep-coroutine round-trip (~40 frames) plus a large-payload one would have caught this.
EVIDENCE: CONFIRMED, and it is worse than claimed: no `__persist` hook and no `collectgarbage()` call are needed.

## 1. Black-box reproduction (stock `serializer/erislj_test.exe`)

The claim's own repro segfaults for me:
```
$ ./erislj_test.exe .../rev/c.lua
Segmentation fault      EXIT=139
```

But the explicit `collectgarbage("collect")` in a `__persist` closure is not required. My probe `nat.lua` has **no spkey hook and no GC call anywhere** — just an ordinary ~40-frame-deep suspended coroutine carrying a plain table of N strings, so that `unpersist`'s *own* allocation drives an incremental GC step into the slot pass:
```
STOCK erislj_test.exe N=2000 exit=139   (Segmentation fault)
STOCK erislj_test.exe N=8000 exit=139   (Segmentation fault)
  resume1:  true  0  1  2  3  4
  blob bytes:  62577 / 248577
```
Rebuilt from the current head of `serializer/eris_lj.c` (the file is being edited concurrently by a sibling session; the slot pass is byte-identical, now at lines 1262-1270): still `exit=139` at N=2000 and N=8000.

When it does not segfault it silently returns garbage. `resume` on a coroutine that yields **2** values returns **4480**:
```
  unpersist ok?    true   thread: 0x014f283211d8
  resume2 nresults: 4480
  resume2 [1..8]:  true  1.48e-323  7.11e-312  nil  nil  nil  9.93e-322  true
```

## 2. Mechanism proven directly (instrumented build)

I built an instrumented copy of `eris_lj.c` printing `co->stacksize` around each slot write:
```
[INST] enter slotpass: need=438 top_ofs=336 stacksize=456
[INST] *** stacksize CHANGED at i=4: 456 -> 127 (stack 0x...5f98 -> 0x...5f98)
[INST] !!! OUT-OF-BOUNDS WRITE: slot 127 >= stacksize 127
   ... 209 OOB writes, slots 127..335 ...
[INST] leave slotpass: stacksize=127 need=438
```
Exactly the claimed chain. `u_thread` grows to 456, then at `i=4` a GC traverses `co`; because `co->base` is still at the bottom, `gc_traverse_frames` (lj_gc.c:145) exits its loop immediately and returns `used = co->top - stack = 5`; `gc_traverse_thread` (lj_gc.c:319) then calls `lj_state_shrinkstack(th, 5)`, whose guard `4*used < stacksize && 2*(LJ_STACK_START+LJ_STACK_EXTRA) < stacksize` (lj_state.c:102-106) holds (20 < 456), and `resizestack(co, 228)` halves the block. The realloc shrank **in place** (same base address), so there is no crash on the write itself — 209 `copyTV`s silently smash the freed tail of the heap block.

## 3. Controls isolate both variables

| variant | stacksize | OOB | resume2 results |
|---|---|---|---|
| depth 40, GC in slot pass | 456 -> **127** | **209** | **4183 garbage** |
| depth 40, **no** GC | 456 (no shrink) | 0 | 2, correct table |
| depth **2**, GC | 48 (guard `96 < stacksize` fails) | 0 | 2, correct table |

## 4. A second overflow site in the same window (not in the claim)

The trailing fill `for (i = top_ofs; i < need; i++) setnilV(stack + i)` also runs against a possibly-shrunk allocation, and this one does **not** need a deep live top. My `narrow.lua` (recurse to depth 200, unwind fully, then yield — so `need` is large but `top_ofs` is 7):
```
[INST] *** stacksize CHANGED at i=4: 1824 -> 469
[INST] !!! TRAILING NIL-FILL OVERFLOW: fills slots 7..1805 into an allocation of
       only 469 slots (1337 slots past the end = 10696 bytes)
```
10.7 KB of heap overwritten with nil TValues. It happened to survive that run only because the nils landed in benign memory.

## 5. Fix validated

With the patch below (built `-Wall -Wextra`, no warnings):
- `nat.lua` at N=2000/8000/30000: `exit=0`, `OOB=0`, stacksize stays 456, `resume2 nresults: 2`, correct table.
- `rep.lua` depth 40 + explicit GC: `exit=0`, `OOB=0`, 2 correct results.
- the claim's `rev/c.lua`: `resume2: true  table: 0x...`, `exit=0`.
- `narrow.lua`: the shrink still fires (1824 -> 469, which is legitimate here) but every write stays in bounds; round-trips correctly.
- Regression: `m1 82/82`, `m2 55/55`, `m3 33/33` all pass.

Why holding `co->top` at `top_ofs` is sufficient and not just a narrowing: while `co->base` is at the bottom, `used` is exactly `top_ofs`, and LuaJIT only shrinks when `4*used < stacksize`, i.e. `top_ofs < stacksize/4`; the halved allocation is still `> stacksize/2 > 2*top_ofs`, so every slot `i < top_ofs` remains addressable, and this holds inductively across repeated halvings. The clamp is what covers the trailing fill, whose bound is `need`, not `top_ofs`.

Working tree left as found; probe binaries deleted. Probes are at `C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\v\` (`nat.lua`, `rep.lua`, `narrow.lua`, `fix.py`).

### [high] real-bug : T4 half-missing: base_ofs is not pinned to 1+LJ_FR2 when the thread has no frames; the next GC walks blob values as a frame chain
FIX: In u_thread (C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c), right after the existing status/nframes cross-check at line 1265 and before `if (nframes > need)`:

  /* T4, second half: with no frames the thread never entered its body, so
   * base MUST sit at the stack bottom. gc_traverse_frames walks `base-1`
   * down to `stack+LJ_FR2` unconditionally -- it consults neither the status
   * nor whether any frame word was ever written -- so a higher base makes it
   * read a plain value slot as a frame word and dereference gcval() of the
   * slot below it as a GCfunc. (On the writer side this is a tautology:
   * p_thread counts frames by walking from base-1 down to the bottom, so
   * nframes == 0 already implies base_ofs == 1+LJ_FR2.) */
  if (nframes == 0 && base_ofs != (uint64_t)(1 + LJ_FR2))
    luaL_error(L, "eris-lj: thread has no frames but base is at %d, not the "
                  "stack bottom (%d)", (int)base_ofs, 1 + LJ_FR2);

Placing it here is important: it fires before co->base is moved off the bottom, so a rejected blob leaves the half-built thread inert (base == top == stack+1+LJ_FR2), which is the "catchable error leaving a usable state" the M3 design requires.

Optionally mirror it as a persist-side assert in p_thread after the nframes walk (eris_lj.c:745), where it is a tautology, to document the invariant:
  if (nframes == 0 && base_ofs != 1 + LJ_FR2)
    luaL_error(L, "eris-lj: internal: frameless thread with base at %d", (int)base_ofs);

Suggested regression test for serializer/tests/m3.lua (the "malformed input" section): persist a never-started coroutine, flip the base_ofs byte 2 -> 3, reseal the CRC, and assert that eris.unpersist fails; then collectgarbage("collect") to prove the process survives.
EVIDENCE: REPRODUCED — segfault in the GC, mechanism confirmed instruction-by-instruction.

1) The gap in the code. C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c:1259-1267 is the ONLY place nframes is cross-checked:

    nframes = r_uleb(I);
    if (status == LUA_YIELD) {
      if (nframes == 0) luaL_error(L, "eris-lj: suspended thread with no frames");
    } else if (nframes != 0) {
      luaL_error(L, "eris-lj: non-suspended thread must have no frames");
    }
    if (nframes > need) ...

base_ofs is bounded only by T3 in the header block (`base_ofs >= 1+LJ_FR2 && top_ofs >= base_ofs && top_ofs <= need`). The whole "Derive positions" validator that follows is guarded by `if (nframes && ...)`, so with nframes == 0 nothing constrains base_ofs at all, and u_thread's final block still sets `co->base = stack + base_ofs`.

2) Repro (the suggested test, run unmodified as .../scratchpad/v/d.lua). Persist a never-started coroutine, flip the single base_ofs byte 0x02 -> 0x03, reseal the CRC32:

  record tag =    12  status = 0  need = 39  base_ofs = 2  top_ofs = 3
  unpersist accepted the patched blob?   true    thread: 0x01da98eee0a8
  status: normal
  running a full GC over it ... Segmentation fault
  EXITCODE=139

Confirmed twice: against the binary built from the source as I found it, and again against the current tree binary (eris_lj.c md5 f7b56aa3a424357f4a2bb54eb041ec97) — the gap is still live.

3) Fault site, under gdb:

  Thread 1 received signal SIGSEGV
  #0 propagatemark ()          <- gc_traverse_thread/gc_traverse_frames inlined at -O2
  #1 lj_gc_fullgc () #2 lua_gc () #3 lj_cf_collectgarbage ()
  => 0x...<propagatemark+1599>: cmpb $0x0,0xa(%r10)
  r10 = 0x7fffffffffff
  $1 = 0x800000000009        (the address actually loaded)

That instruction is `isluafunc(fn)` — `fn->c.ffid == FF_LUA`, ffid at offset 10 of GCfuncC. r10 = 0x00007fffffffffff is exactly `gcval(nil)`: setnilV writes it64 = ~0, and gcval masks with LJ_GCVMASK = (1<<47)-1. So the mechanism is precisely as claimed.

Why that nil: lj_state.c:173-185 stack_init puts the thread itself at stack[0] and, under LJ_FR2, nil at stack[1]; base starts at stack+2. u_thread's slot pass writes only [1+LJ_FR2, top_ofs) = slot 2 upward, so stack[1] stays nil. gc_traverse_frames (lj_gc.c:291-305) loops `for (frame = th->base-1; frame > bot+LJ_FR2; ...)` with no reference to th->status or to any frame count: base = stack+3 makes stack+2 > stack+1, the body runs once, frame_func(stack+2) = &gcval(stack+1)->fn = 0x7fffffffffff, and isluafunc dereferences it. gc_traverse_thread calls this on every reachable thread on every GC cycle, before any resume — and coroutine.status reports the restored thread "normal", so resume is not even the vector.

4) The fix is not over-restrictive — it mirrors a writer-side tautology. p_thread (eris_lj.c:740-745) counts frames by walking `for (f = co->base-1; f > bot; ...)`, so nframes == 0 already implies base_ofs <= 1+LJ_FR2, i.e. exactly 1+LJ_FR2 given T3. Measured over every persistable shape:

  never-started     status=0 base_ofs=2 top_ofs=3     (nframes 0)
  dead-normal       status=0 base_ofs=2 top_ofs=2     (nframes 0)
  dead-normal-args  status=0 base_ofs=2 top_ofs=2     (nframes 0)
  dead-error        PERSIST REFUSED (pending error status and a live stack)
  dead-error-deep   status=2 base_ofs=12 top_ofs=12   -> unpersist already rejects:
                    "eris-lj: non-suspended thread must have no frames"
  suspended         status=1 base_ofs=8 top_ofs=8     (nframes > 0)

No legitimate blob with nframes == 0 has base_ofs != 2, so the check rejects nothing that round-trips today.

5) Fix verified. With the one check added, the same patched blob is rejected cleanly instead of crashing:

  unpersist accepted the patched blob?  false
    eris-lj: thread has no frames but base is at 3, not the stack bottom (2)

and all suites still pass: M1 82/82, M2 55/55, M3 33/33.

6) In-scope: serializer/README.md:111-113 states the threat model explicitly — "A checksum is not a MAC. CRC32 catches corruption, not tampering — any save can be re-sealed by an attacker. Parser robustness, not the checksum, is what makes crafted blobs safe." A resealed one-byte edit is exactly the input class u_thread's other ~15 validators exist to reject.

WORKING TREE: restored. I applied the fix only to measure it, then confirmed by grep that no trace of my edit remains in serializer/eris_lj.c (its nframes block is byte-identical to how I found it, lines 1259-1267 above). Note for the orchestrator: another agent was writing serializer/eris_lj.c concurrently during this session (it changed under me from 65498 -> 65693 -> 64046 bytes between 18:26 and 18:32, and my edit was reverted by that agent's own restore, not by me), so I deliberately did not overwrite the file with my backup. All probes live only in .../scratchpad/v/ (d.lua, shapes.lua, err.lua); no probe binaries were created in the repo.

### [high] real-bug : FRAME_CONT link is only bounded by link >= 16, so the validated cont/contpc/aux words get overwritten by the next-outer frame's ftsz (wild jmp)
FIX: In `C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c`, in the per-frame decode loop, immediately after the generic link check (currently line 1295):

    if ((fr[k].link & 7) != 0 || fr[k].link < 16)
      luaL_error(L, "eris-lj: frame link %d is not a valid frame size",
                 (int)fr[k].link);
+   /* A continuation frame owns f-3..f (f-4..f for stitch): the caller's
+    * frame word must sit strictly below them. With link == 24 the next
+    * outer frame's ftsz lands on the slot pass 3 wrote the continuation
+    * address into, and cont_dispatch then jumps to link|kind. */
+   if (fr[k].kind == FR_CONT &&
+       fr[k].link < (uint64_t)(fr[k].cs == CS_STITCH ? 40 : 32))
+     luaL_error(L, "eris-lj: continuation frame link %d overlaps its own "
+                   "continuation words", (int)fr[k].link);
  }

Placed here it runs after `fr[k].cs` is read and range-checked, and before any position is derived. Equivalent phrasing if you prefer it in the derive loop next to F10: assert `prev_at < at - 3`, and `prev_at < at - 4` when `cs == CS_STITCH`.

Verified: builds clean with `-Wall -Wextra`, all 33 M3 tests still pass, and the crashing blob is rejected with "eris-lj: continuation frame link 24 overlaps its own continuation words" instead of being accepted.

Also update `C:/Users/astro/Downloads/OC-LuaJIT/docs/research/m3-frame-codec.md` §4 F10, which currently states only the stack-bottom constraint, to require the CONT frame's link to clear its own continuation words.
EVIDENCE: REPRODUCED end-to-end. The claim is correct in every particular, including the exact faulting value.

## The gap

`C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c:1295` is the only lower bound on a frame link:

    if ((fr[k].link & 7) != 0 || fr[k].link < 16)
      luaL_error(L, "eris-lj: frame link %d is not a valid frame size", (int)fr[k].link);

`link >= 16` is exactly right for FR_LUA / FR_C / FR_CP / FR_VARG / FR_PCALL(H), which occupy only `f-1..f`. It is too weak for FR_CONT. Confirmed against the pinned VM's own layout in `C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit/src/lj_frame.h:90,91,97` (LJ_FR2 branch):

    #define frame_contpc(f)   (frame_pc((f)-2))
    #define frame_contv(f)    (((f)-3)->u64)
    #define frame_contf(f)    ((ASMFunction)(uintptr_t)((f)-3)->u64)

so a CONT frame owns `f-3..f` (`f-4..f` for stitch), and its `prev` must be strictly below that: `prev <= f-4`, i.e. `link >= 32` (`>= 40` for CS_STITCH). Nothing enforces it. The F10 check at :1316-1318 only guards the stack *bottom* (`at-3 <= LJ_FR2`), and the descent check at :1310-1312 only requires `prev_at < at`, so `prev_at == at-3` passes.

Pass 3 walks frames top-down, so for a CONT with link 24 the inner frame writes the continuation address at `f-3` (:1362 in the 1771-line revision / :1389 and :1362 as the file churned) and the next-outer frame's `setframe_ftsz(f, link | kind)` then lands on that very slot. `cont_dispatch` (vm_x64.dasc) ends in `jmp RA` on that word.

## Reproduction

Binary built from the in-tree source, out-of-tree so the shared working tree was never written to. Snapshot used for the final run: `serializer/eris_lj.c` md5 `f7b56aa3a424357f4a2bb54eb041ec97` (1737 lines; the file was being edited concurrently by another process during the session — the gap at :1295 was present in every revision I saw).

Unpatched (`now.exe`), running the suggested probe `.../scratchpad/rev/l.lua`, which takes a *genuine* `cont_condf` blob and rewrites only the CONT link 112 -> 24 and the CP link 16 -> 104:

    -- m3 suite:
       EXIT=0 :: M3 RESULT: ALL 33 TESTS PASS
    -- repro (l.lua, CONT link 112 -> 24):
    need=39 base_ofs=18 top_ofs=18 ; CONT link=112 cs=4 cbcofs=5
    patched: CONT at 17 link 24 -> prev 14 ; CP at 14 link 104 -> bottom 1
    unpersist accepted?  true   thread: 0x02383f68d2d0
    status:  suspended
    resuming ... Segmentation fault
       EXIT=139

Every `u_thread` check passes, `unpersist` hands back a thread that reports `suspended`, and `coroutine.resume` dies. Under gdb the wild jump target is exactly as predicted:

    Thread 1 received signal SIGSEGV, Segmentation fault.
    0x000000000000006d in ?? ()
    rip            0x6d                0x6d
    Cannot access memory at address 0x6d

0x6d == 109 == 104 | 5 == (CP link) | FRAME_CP — the literal `link | kind` word from :1364/:1394, executed as code.

## Control: it is the overlap, not the patching

Same specimen, same cs, same continuation bcofs, same machinery — only the CONT link varies (`prev` moves down one slot at a time):

    CONT link=24  -> prev slot 14 == f-3 (clobbers the cont word)  : accepted, SIGSEGV, EXIT=139
    CONT link=32  -> prev slot 13 == f-4 (no overlap)              : rejected by an unrelated check, no crash
    CONT link=40  -> prev slot 12 == f-5 (no overlap)              : accepted, resumed, ran, returned a normal Lua
                                                                     error ("attempt to compare number with
                                                                     function") — "survived", EXIT=0

The crash appears only when `prev` lands on `f-3`. That isolates the cause to the overlap.

## The fix works and costs nothing

Patched build (`nowfix.exe`, same snapshot + the two-line bound below):

    -- m3 suite:
       EXIT=0 :: M3 RESULT: ALL 33 TESTS PASS
    -- repro (l.lua, CONT link 112 -> 24):
       EXIT=0
    unpersist accepted?  false  eris-lj: continuation frame link 24 overlaps its own continuation words

All 33 M3 tests still pass, so the bound never rejects an encoding the persist side actually emits. It cannot: a metamethod's continuation words are written into the caller's own stack slots, which are at or above the caller's base `prev+1`, so `f-3 >= prev+1` — i.e. `link >= 32` — holds for every genuine CONT frame by construction.

## Severity

The FR_CP case above writes a small integer, so it faults immediately. The claimed worse variant is real too: only the *bottom* frame is required to be C/CP (:1313), so the overwriting frame may be FR_LUA, whose `setframe_pc` (:1350) writes a live `BCIns*` into the cont slot — `jmp` into the bytecode array, i.e. bytecode bytes executed as x86. This is reachable from any untrusted blob, which is the threat model the surrounding code explicitly adopts ("must resolve inside the closed symbol set and never be a raw value", "an in-range-but-wrong pc is memory-unsafe").

Also a gap in the design doc: `C:/Users/astro/Downloads/OC-LuaJIT/docs/research/m3-frame-codec.md` §4 F10 states only the stack-bottom constraint; it needs the `prev < f-3` (`prev < f-4` for stitch) constraint too.

### [high] real-bug : TAG_UPVALOPEN validates the slot against the owner's still-moving co->top, so ordinary coroutines fail to restore
FIX: Carry the in-flight declared top on Info and bound the slot with it (5 hunks, ~25 lines, in C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c):

1. Next to PendingRef (before the Info typedef, ~line 172):

/* Threads whose restore is still in flight. u_thread publishes the DECLARED
 * final top before it writes any slot: a closure living in one of those slots
 * can hold an open upvalue over a slot the write cursor has not reached yet,
 * and until pass 5 co->top is only that cursor. Linked through the C stack,
 * like PendingRef, so a longjmp discards it with the frames that own it. */
typedef struct RThread {
  lua_State *co;
  uint64_t top_ofs;
  struct RThread *prev;
} RThread;

2. In Info, after `PendingRef *pending;`:

  RThread *rthreads;          /* unpersist: threads still being restored */

(both unpersist entry points memset(&I, 0, sizeof(I)), so it is NULL-initialised for free)

3. Immediately before u_function:

/* The live-stack bound for an open-upvalue slot. A thread still being
 * restored has co->top parked at the write cursor, so the declared top is the
 * only truthful bound; once the restore is done co->top is the real one. */
static uint64_t elj_live_top(Info *I, lua_State *co)
{
  RThread *r;
  for (r = I->rthreads; r != NULL; r = r->prev)
    if (r->co == co) return r->top_ofs;
  return (uint64_t)(co->top - tvref(co->stack));
}

4. Replace the check at eris_lj.c:1123-1124:

-      if (slot < (uint64_t)(1 + LJ_FR2) ||
-          slot >= (uint64_t)(owner->top - tvref(owner->stack)))
+      if (slot < (uint64_t)(1 + LJ_FR2) || slot >= elj_live_top(I, owner))

5. In u_thread: add `RThread rt;` to the locals; publish it after the one-shot
   grow and BEFORE pass 1:

  rt.co = co;
  rt.top_ofs = top_ofs;
  rt.prev = I->rthreads;
  I->rthreads = &rt;

   and unpublish as the last statement of u_thread, after `co->cframe = NULL;`:

  I->rthreads = rt.prev;

The list is a C-stack chain, so it nests correctly for coroutines restored inside coroutines and is discarded by the longjmp on any error, exactly like PendingRef. Pass 4's own bound (eris_lj.c:1391, `slot >= top_ofs`) is already correct and needs no change.

Worth adding to tests/m3.lua alongside the existing open-upvalue cases: the same program in both register orders, since only one of them exercises this path.
EVIDENCE: CONFIRMED. Reproduced from a clean build of the exact current source (C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c, md5 f7b56aa3a424357f4a2bb54eb041ec97), compiled with the Makefile's own flags into a scratchpad binary.

The offending code, eris_lj.c:1122-1126 (u_function, TAG_UPVALOPEN):

      slot = r_uleb(I);
      if (slot < (uint64_t)(1 + LJ_FR2) ||
          slot >= (uint64_t)(owner->top - tvref(owner->stack)))
        luaL_error(L, "eris-lj: open upvalue slot %d outside the thread's "
                      "live stack", (int)slot);

`owner->top` is the WRITE CURSOR during u_thread's pass 1 (eris_lj.c:1245-1252: `co->top = stack + i + 1` after each slot), not the thread's final live top. The final top is only installed in pass 5 at eris_lj.c:1413.

== Reproduction (baseline build of the current source) ==

FAIL  A  container below captured local              eris-lj: open upvalue slot 5 outside the thread's live stack
ok    A' captured local below container              -> 41
FAIL  A2 array container below captured local        eris-lj: open upvalue slot 5 outside the thread's live stack
FAIL  A3 shared open upvalue via low table           eris-lj: open upvalue slot 5 outside the thread's live stack
FAIL  A4 container 3 registers below the local       eris-lj: open upvalue slot 8 outside the thread's live stack
ok    B  closure reached from outside the thread     -> 5

repro: 2 pass, 4 fail

Case A is `coroutine.create(function() local t = {}; local x = 41; t.get = function() return x end; coroutine.yield(); return t.get() end)`. A' is the identical program with the two locals swapped, and it round-trips. So the failure is decided purely by register allocation order.

== Mechanism, proved by an instrumented build ==
An fprintf at the check prints, for the same two programs:

--- restoring case A ---
[uvopen] slot=5  owner->top-stack=4  owner->base-stack=2  maxstack=39  status=0
--- restoring case A-control ---
[uvopen] slot=4  owner->top-stack=5  owner->base-stack=2  maxstack=39  status=0

Case A: the upvalue slot is 5 but `owner->top - stack` is 4, i.e. pass 1 has just written slot 3 (the table `t`) and the closure is being unpersisted from inside that table's value, before slot 5 (`x`) exists. `status=0` (not yet LUA_YIELD) and `maxstack=39` confirm the thread is mid-restore and the stack is already grown to its final size — slot 5 is inside the allocation and below the declared final top (6, per the control's layout); only the moving cursor rejects it. Case A-control: slot 4 < cursor 5, so it passes.

The M3 suite does not cover this: `./erislj_test.exe tests/m3.lua` reports "M3 RESULT: ALL 33 TESTS PASS" on the same buggy binary. Its open-upvalue cases all declare the captured local before the container that reaches the closure.

Impact: any suspended coroutine in which a value at a lower register transitively reaches a closure over a still-open local at a higher register fails to restore. That is the ordinary `local t = {} ... local x ... t.f = function() ... x ... end` module/object shape, i.e. exactly what an OC kernel yields with.

== Fix verified ==
Applying the patch below (deferring to the thread's DECLARED top while it is in flight) makes all six repro cases pass, and all three suites still pass:

ok    A  container below captured local              -> 41
ok    A' captured local below container              -> 41
ok    A2 array container below captured local        -> 42
ok    A3 shared open upvalue via low table           -> 12
ok    A4 container 3 registers below the local       -> 13
ok    B  closure reached from outside the thread     -> 5
repro: 6 pass, 0 fail

M1 RESULT: ALL 82 TESTS PASS
M2 RESULT: ALL 55 TESTS PASS
M3 RESULT: ALL 33 TESTS PASS

The restored upvalue is genuinely open and correctly aliased, not merely accepted — a separate probe mutates x through the restored closure and then reads the register directly from the coroutine body, and also forces a resizestack (400-deep recursion) plus full GC after restore:

base:   FAIL alias: mutate via closure, read register  (slot 5 outside ...)
        FAIL alias survives resizestack               (slot 5 outside ...)
        FAIL two low-container coroutines             (slot 5 outside ...)
        ok   container holds the coroutine too -> 9
fixed:  ok alias: mutate via closure, read register -> 43
        ok alias survives resizestack -> 2
        ok two low-container coroutines -> 10/4
        ok container holds the coroutine too -> 9

U1 is preserved: the new bound is `top_ofs`, which u_thread already validates as `base_ofs <= top_ofs <= need` (eris_lj.c:1226) with the stack grown to `need`, slots [top_ofs, need) nil'd, and the final `co->top = stack + top_ofs`. So every accepted slot is still strictly below the thread's live top, which is what lj_state_shrinkstack's `used` and resizestack's blind uv->v relocation require. The bound is NOT relaxed to `need`.

Artifacts (all in the scratchpad; the repo tree is untouched — md5 of serializer/eris_lj.c is unchanged and git status matches the session start):
  .../scratchpad/vfyA/repro.lua, alias.lua, oneA.lua  (tests)
  .../scratchpad/vfyA/mkfix.py, mkinstr.py            (patch + instrumentation scripts)
  .../scratchpad/vfyA/base.exe, fixed.exe, instr.exe  (builds)

Note: another agent is concurrently rewriting serializer/eris_lj.c in place (its mtime moved twice during this session while the bytes stayed identical to my baseline, and an early read of the file transiently showed this very fix already applied and then reverted). All results above are from my own snapshot of the current bytes, not from the shared erislj_test.exe.

### [medium] real-bug : F18 omitted entirely: FRAME_PCALLH is accepted on both sides with no hook check
FIX: Two lines, mirroring F18 on both sides. `hook_active` comes from lj_obj.h, already included.

Encode side, in `p_thread` (eris_lj.c, right after the `unsupported frame type` check at :779-782):
```c
        if (kind != FR_C && kind != FR_CP && kind != FR_VARG &&
            kind != FR_PCALL && kind != FR_PCALLH)
          luaL_error(L, "eris-lj: unsupported frame type %d", kind);
+       /* F18: PCALLH means "a hook was active when this pcall was entered",
+        * and lj_err.c:184 skips hook_leave() for it. That is only right while
+        * that hook is still on the stack; a restored PCALLH latches
+        * HOOK_ACTIVE on the first error and kills all hook dispatch. */
+       if (kind == FR_PCALLH && !hook_active(G(L)))
+         luaL_error(L, "eris-lj: cannot persist a pcall frame entered "
+                       "inside a debug hook");
```

Decode side, in `u_thread`'s per-frame record loop (immediately after the `illegal frame kind` branch closes at :1292):
```c
      luaL_error(L, "eris-lj: illegal frame kind %d", (int)fr[k].kind);
    }
+   /* F18, decode side: see p_thread. */
+   if (fr[k].kind == FR_PCALLH && !hook_active(G(L)))
+     luaL_error(L, "eris-lj: FRAME_PCALLH frame with no active hook");
```

Since HOOK_ACTIVE is clear at any normal save or load point, both checks reject every PCALLH frame in practice, which is what the design intends: the save fails loudly instead of producing a blob that silently disables the watchdog. Worth also correcting the F18 rationale in docs/research/m3-frame-codec.md:327 — vm_returnp does not take a "hooked path"; the sole difference is the skipped `hook_leave` on the error path in lj_err.c:184.
EVIDENCE: CONFIRMED by experiment. F18 is genuinely absent, `FRAME_PCALLH` frames both persist and restore unchecked, and a restored one provably latches HOOK_ACTIVE on and kills all hook dispatch.

## 1. Code state (C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c)

`grep -n 'PCALLH|hook_active' eris_lj.c` returns only three lines: the `#define FR_PCALLH 7` at :145, the encode whitelist at :781 (`kind != FR_PCALL && kind != FR_PCALLH`) and the decode whitelist at :1290 (`fr[k].kind != FR_PCALLH`). No hookmask/hook_active reference anywhere.

## 2. The claim's correction to the design rationale is right

`vm_x64.dasc:397-408` (`->vm_returnp`) does `and PC, -8` and never looks at the low bit, so the normal return path is identical for PCALL and PCALLH. The *only* place in the whole VM+runtime that distinguishes them is `lj_err.c:184`:
```c
    case FRAME_PCALL:  case FRAME_PCALLH:
      ...
      if (frame_typep(frame) == FRAME_PCALL)
        hook_leave(g);
```
and `lj_obj.h:686` `#define hook_leave(g) ((g)->hookmask &= ~HOOK_ACTIVE)`, with `lj_dispatch.c:370` `if (hookf && !hook_active(g))` — HOOK_ACTIVE latched on suppresses every hook call.

## 3. Such a thread is reachable from pure Lua

`HOOK_ACTIVE` lives in `global_State`, so resuming a coroutine from inside a debug hook makes that coroutine's `pcall` build a PCALLH frame. Probe output (frame kinds read with `frame_typep` through a scratchpad harness):
```
hookactive at start:    false   0
plain frames :          LUA PCALL LUA CP
  inside hook, hookactive:      true    16
  resume from hook ->   true    in-pcall
hookactive after hook:  false   0
hooked frames:          LUA PCALLH LUA CP      <-- suspended, hook gone
hooked status:          suspended
```

## 4. The failure, after a real round trip (jit.off; watchdog = count hook that errors)

```
======== plain ========            (round-tripped FRAME_PCALL)
frames             : LUA PCALL LUA CP
resume returned    : true  false  watchdog: ran too long
HOOK_ACTIVE after  : false 0
later hook fires   : 2000   ok

======== pcallh ========           (round-tripped FRAME_PCALLH)
frames             : LUA PCALLH LUA CP
HOOK_ACTIVE before : false 0
resume returned    : true  false  watchdog: ran too long
HOOK_ACTIVE after  : true  16
later hook fires   : 0      <== WATCHDOG IS DEAD
```
The pcall catches the watchdog error, `hook_leave` is skipped because the frame says PCALLH, HOOK_ACTIVE stays set with no hook on the stack, and CHECKHOOK never fires again — exactly the failure the project cannot afford.

## 5. The serializer manufactures the hazard from nothing

A thread that never went near a hook, persisted normally (blob 557 bytes, FRAME_PCALL), with one frame-kind byte flipped 6 -> 7 and the trailing crc32 repaired:
```
original frames    : LUA PCALL LUA CP
flipped byte offset: 544  (6 -> 7), crc32 repaired
decoder verdict    : ACCEPTED (no error raised)
forged frames      : LUA PCALLH LUA CP
resume returned    : true  false  watchdog: ran too long
HOOK_ACTIVE after  : true  16
later hook fires   : 0      <== WATCHDOG IS DEAD
```
So the missing decode-side check is load-bearing on its own: a CRC-valid blob (world save, edited on disk) turns one byte into a permanent watchdog kill.

Honest caveat on severity: a third run of the same experiment on the *un-round-tripped* coroutine (`CASE=live`) latches identically, so the underlying hazard is a latent LuaJIT property (`lj_err.c:170` even says "Assumes nobody uses coroutines inside hooks"), not something the serializer invents in the save path. What the serializer does is (a) faithfully re-materialise a stale PCALLH whose owning hook is long gone, where the design says to refuse, and (b) accept a forged one, which is entirely serializer-created. Medium is the right rating.

## 6. Fix verified

Applied to a scratchpad copy (working tree untouched, probe binaries deleted): 82 + 55 + 33 tests still pass; `CASE=pcallh` now fails at save with `eris-lj: cannot persist a pcall frame entered inside a debug hook`; every forged-byte variant is rejected on load ("could not forge a PCALLH byte"); the `plain` control is unaffected (`later hook fires: 2000 ok`).

######## LENS: hostile-blobs ########

### [critical] real-bug : FR_CONT continuation symbol is trusted without checking it matches the continuation site, producing a resumable coroutine that segfaults the host on resume
FIX: In `C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c`, `u_thread` Pass 3, at the start of the `else` (FR_CONT) branch — currently line 1361, immediately before `(f - 3)->u64 = ...cont_addr[fr[k].cs];`. `MMS`, `MM_*` and `bcmode_mm` are already reachable via the existing `lj_obj.h` / `lj_bc.h` includes; no new headers.

```c
      } else {
        /* An in-set-but-WRONG continuation symbol is memory-unsafe for the
         * same reason an in-range-but-wrong FR_LUA pc is: cont_dispatch jumps
         * straight to cont_addr[cs], and every handler decodes the bytecode
         * around contpc assuming it is the site that attached it (cont_cat
         * reads bc_b(pc[-1]) as a concat base, cont_ra writes the result to
         * bc_a(pc[-1]), cont_cond* branch on bc_d(pc[0]) as if it were a JMP,
         * cont_stitch shuffles results using bc_a/bc_b(pc[-1])). contpc always
         * points one instruction PAST the triggering opcode -- for comparisons
         * at the JMP that follows it -- so the site identifies the symbol. */
        MMS mm = bcmode_mm(bc_op(pc[-1]));
        int consistent;
        switch (fr[k].cs) {
          case CS_CAT:    consistent = (mm == MM_concat); break;
          case CS_RA:     consistent = (mm == MM_index || mm == MM_len ||
                                        (mm >= MM_add && mm <= MM_unm)); break;
          case CS_NOP:    consistent = (mm == MM_newindex); break;
          case CS_CONDT:
          case CS_CONDF:  consistent = ((mm == MM_eq || mm == MM_lt ||
                                         mm == MM_le) &&
                                        bc_op(pc[0]) == BC_JMP); break;
          case CS_STITCH: consistent = (mm == MM_call); break;
          default:        consistent = 0; break;
        }
        if (!consistent)
          luaL_error(L, "eris-lj: frame %d continuation symbol %d does not "
                        "match the opcode at its continuation site",
                     (int)k, (int)fr[k].cs);
        (f - 3)->u64 = (uint64_t)(uintptr_t)cont_addr[fr[k].cs];
        setframe_pc(f - 2, pc);
        ...unchanged...
```

`bcmode_mm` returns `MM____` (== `MM__MAX`, out of enum range) for every opcode that attaches no metamethod, so all comparisons fail closed. `pc[0]` is always in bounds because the existing check already requires `1 <= bcofs < pt->sizebc`. The `bc_op(pc[0]) == BC_JMP` clause is the one that actually stops the crashes: `cont_condt`/`cont_condf` do `add PC,4` and then `branchPC PC_RD`, taking the D field of a non-JMP instruction as a jump displacement.

Two follow-ups worth considering but deliberately out of this minimal patch:
1. `CS_CONDT` vs `CS_CONDF` are still interchangeable over the same comparison site (wrong branch, no memory unsafety). Distinguishing them would need the sense of `bc_op(pc[-1])` (odd opcode -> CONDF) — cheap to add: `consistent = ... && ((bc_op(pc[-1]) & 1) == (fr[k].cs == CS_CONDF));` — but verify against `ISEQ*`/`ISNE*` pairs before adopting.
2. Add the mismatch cases to `tests/m3.lua` as hostile-record tests; `scratchpad/vfy_one.lua` drives the whole 5 x 8 matrix already.
EVIDENCE: REPRODUCED. A single re-sealable byte turns a valid blob into a coroutine that `eris.unpersist` accepts as `suspended` and that kills the host with SIGSEGV on resume — uncatchable by `pcall`.

## The gap in the code

`C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c`, `u_thread` Pass 3. The FR_LUA branch validates the *site* the pc names (lines 1350-1360):

```c
        /* An in-range-but-wrong pc is memory-unsafe: BC_RET_Z shifts BASE by
         * bc_a(pc[-1]) and then dereferences [BASE-16] as a closure. These
         * two checks together are what reject it. */
        if (frame_prevl(f) != prev) ...
        switch (bc_op(pc[-1])) {
          case BC_CALL: case BC_CALLM: case BC_ITERC: case BC_ITERN: break;
          default: luaL_error(L, "eris-lj: frame %d return pc does not follow a call", ...);
        }
```

The FR_CONT branch immediately below (1361-1370) does no equivalent — the symbol is only checked for set membership (`cs < CS_MAX`, `cs != CS_HOOK`) back at line 1283-1288, and is then dereferenced straight into the frame word:

```c
      } else {
        (f - 3)->u64 = (uint64_t)(uintptr_t)cont_addr[fr[k].cs];
        setframe_pc(f - 2, pc);
```

Same hazard class, one branch hardened, the other not.

## Reproduction (my own script, `scratchpad/vfy_repro.lua`)

Built clean at commit-pinned LuaJIT 1ee778a4; baseline 82+55+33 = 170/170 tests pass. Script persists `coroutine.create(function() return t.wanted end)` suspended inside `__index`, flips the FR_CONT symbol byte CS_RA(1) -> CS_CONDT(3), recomputes the CRC with the `tests/m2.lua` helper, and asserts the diff is exactly one byte.

```
$ RESUME=0 ./erislj_test.exe .../vfy_repro.lua
CONTROL untampered: unpersist ok, resume -> true V:wanted
located FR_CONT frame: body offset 534  real cs=1  contpc bcofs=3
bytes changed in the record body: 1 (at offset 534: 1 -> 3)
UNPERSIST ACCEPTED. type=thread status=suspended

$ RESUME=1 NEWCS=3 ./erislj_test.exe .../vfy_repro.lua
...
UNPERSIST ACCEPTED. type=thread status=suspended
resuming the tampered coroutine now...
/usr/bin/bash: line 1:  1042 Segmentation fault  ./erislj_test.exe ...
PROCESS EXIT=139
```

The resume is inside `pcall` and is not caught: the process dies.

## Full matrix, each case in its own process (`scratchpad/vfy_one.lua`)

5 metamethod specimens x 6 symbols, current code:

```
exit=139  index     real=1 try=3 : accepted; resume ->
exit=139  concat    real=0 try=3 : accepted; resume ->
exit=139  concat    real=0 try=6 : accepted; resume ->
exit=139  newindex  real=2 try=4 : accepted; resume ->
exit=139  arith     real=1 try=3 : accepted; resume ->
exit=0    index     real=1 try=2 : ... val=table: 0x01df93d9b598  <<< WRONG VALUE (expected V:wanted)
exit=0    concat    real=0 try=2 : ... val=6.9515870014326e-310   <<< WRONG VALUE (expected CAT)
exit=0    newindex  real=2 try=3 : ... val=table: 0x0242c830d2f0  <<< WRONG VALUE (expected done)
exit=0    arith     real=1 try=2 : ... val=table: 0x02123a9dd290  <<< WRONG VALUE (expected 5)
exit=0    lt        real=4 try=1/2/3/6 : val=GE  <<< WRONG VALUE (expected L)
```

Five hard crashes, plus type confusion: `cont_ra` over a `TSETS` site hands Lua a raw pointer as a `table`, and `cont_nop` over a `CAT` site surfaces uninitialised stack memory as the double `6.95e-310`. `concat` + `cs=6` confirms the existing CS_STITCH neutralisation (`(f-4)->u64 = 0`, line 1365-1369) is not sufficient outside a genuine stitch frame.

## Why this is not just the conceded bytecode-ACE boundary

The module header declares two *separate* properties. One is the M2 trust boundary ("A tampered blob is therefore equivalent to arbitrary code execution"). The other is unconditional and is what `u_thread`'s ~120 lines of frame validation exist to deliver: "every wire byte that indexes anything is range-checked ... so a malformed blob raises a catchable Lua error rather than crashing." The `cs` byte *is* range-checked, yet the frame it builds is not internally consistent, and the result is an uncatchable host crash. Every one of the other ~160 malformed-thread mutations in this record raises a catchable error; this one uniquely does not. The design doc's own line 315 (`docs/research/m3-frame-codec.md`, check F11) treats the symbol check as "the difference between a corrupt coroutine and arbitrary code execution" — it stops at set membership because it did not account for handlers decoding the bytecode *around* contpc.

Honest scope note: an attacker who can tamper and re-seal already has bytecode ACE under the declared boundary, so this does not enlarge their capability. What it breaks is the internal structural-robustness invariant and defence in depth, and it is inconsistent with the FR_LUA sibling check three lines above.

## Ground truth for the fix, measured

`scratchpad/vfy_contop.c` (linked against the pinned `libluajit_stock.a`) walks each live specimen's frames and prints the symbol next to the opcodes around `contpc`:

```
index     cs=1(RA    ) bcofs=3/4  pc[-1]=TGETS  mm=index      pc[0]=...
concat    cs=0(CAT   ) bcofs=4/5  pc[-1]=CAT    mm=concat
lt        cs=4(CONDF ) bcofs=4/9  pc[-1]=ISGE   mm=lt         pc[0]=JMP
le        cs=4(CONDF ) bcofs=4/9  pc[-1]=ISGT   mm=le         pc[0]=JMP
eq        cs=4(CONDF ) bcofs=4/9  pc[-1]=ISNEV  mm=eq         pc[0]=JMP
newindex  cs=2(NOP   ) bcofs=4/6  pc[-1]=TSETS  mm=newindex
arith     cs=1(RA    ) bcofs=3/4  pc[-1]=ADDVN  mm=add
unm/len   cs=1(RA    )            pc[-1]=UNM/LEN mm=unm/len
```

`contpc` always points one instruction past the triggering opcode (for comparisons, at the `JMP`), so `bcmode_mm(bc_op(pc[-1]))` identifies the symbol exactly. This matches `vm_x64.dasc`: `PC_RA = byte [PC-3]`, `PC_RB = byte [PC-1]`, `PC_RD = word [PC-2]`; `cont_cat` reads `PC_RB`, `cont_ra` writes to `PC_RA`, `cont_cond*` do `add PC,4` then `branchPC PC_RD` (so `pc[0]` must be a `BC_JMP`), `cont_stitch` uses `PC_RA`/`PC_RB` of a call.

## Fix verified

With the patch applied (built to a separate binary; tree since restored):
- 82 + 55 + 33 = 170/170 existing tests still pass.
- Positive sweep of all 19 continuation-attaching metamethod kinds (index/gget/tgetv/tgetb, concat, lt/le/eq, newindex/tsetv/gset, add/sub/mul/div/mod/pow/unm/len) still round-trips and resumes to the right value — no false rejections.
- Matrix rerun over cs in {0..7}: zero non-zero exits; every mismatched symbol now gives `eris-lj: frame 1 continuation symbol 3 does not match the opcode at its continuation site`.
- The one-byte reproducer: `UNPERSIST REJECTED: eris-lj: frame 1 continuation symbol 3 does not match the opcode at its continuation site`.

Residual after the fix: `lt real=4 try=3` (CONDF -> CONDT) is still accepted and returns `GE` instead of `L`. Both symbols are legal over an `ISGE`+`JMP` site and differ only in branch sense, so this is semantic corruption with no memory unsafety — the same class as flipping the comparison opcode itself, which is squarely inside the declared bytecode boundary. The CS_STITCH branch of the rule is derived from `recff_stitch` (`lj_ffrecord.c:112-140`, `pc = frame_pc(base-1)`) rather than exercised, since the suite has no live stitch frame.

Working tree restored: `serializer/eris_lj.c` sha1 `74bf45b315bf092ea9830cbe7f9e718cc163393c` (byte-identical to the pre-session backup), `erislj_test.exe` rebuilt from it, 170/170 pass, probe binaries deleted. Reproducers left at `scratchpad/vfy_repro.lua`, `vfy_one.lua`, `vfy_positive.lua`, `vfy_contop.c`.

######## LENS: gc-and-memory ########

### [critical] real-bug : u_thread: a GC during pass 1 shrinks the coroutine stack out from under the restore — heap buffer overflow
FIX: Park co->top at the end of the reserved span for the WHOLE restore and lower it to the real top only in pass 5. That makes gc_traverse_frames report `used = need`, so `4*used < stacksize` can never hold (stacksize is need+1+LJ_STACK_EXTRA at most after the grow) and shrinkstack cannot fire at any point in u_thread. It also makes the trailing nil-fill unnecessary: stack_init (lj_state.c:181-183) and resizestack (lj_state.c:78-79) both nil every slot they hand out, so [1+LJ_FR2, stacksize) is already all-nil and safe for gc_traverse_thread to mark.

In C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c, replace lines 1244-1256:

-  /* Pass 1: slot values. co->top is kept above every written slot, because
-   * gc_traverse_thread nils everything from top upwards during GCSatomic;
-   * co->base stays at the bottom until the frames are in place, so a GC can
-   * never walk a half-written frame chain. */
+  /* co->top is parked at the very end of the reserved span for the whole
+   * restore, and only lowered to the real top in pass 5. Two reasons:
+   * gc_traverse_thread nils everything from top upwards during GCSatomic, and
+   * -- the one that bites -- it also calls lj_state_shrinkstack() with
+   * `used = top - stack` (co->base is at the bottom, so no frame is walked).
+   * With top just above the last written slot that `used` is tiny, and any GC
+   * landing mid-restore halves the block while `need` stays fixed, so every
+   * later write runs off the end. Parking top at stack+need makes `used`
+   * reflect the real requirement, and 4*need >= stacksize always holds.
+   * Every slot in [1+LJ_FR2, stacksize) is already nil: stack_init and
+   * resizestack both clear what they hand out. */
+  co->top = tvref(co->stack) + need;
+
+  /* Pass 1: slot values. co->base stays at the bottom until the frames are in
+   * place, so a GC can never walk a half-written frame chain. */
   for (i = 1 + LJ_FR2; i < (ptrdiff_t)top_ofs; i++) {
     unpersist(I);                       /* ... value */
     stack = tvref(co->stack);
     copyTV(co, stack + i, L->top - 1);  /* NOBARRIER: threads are never black */
-    co->top = stack + i + 1;
+    co->top = stack + need;             /* re-assert: unpersist can realloc */
     lua_pop(L, 1);
   }
-  stack = tvref(co->stack);
-  for (i = (ptrdiff_t)top_ofs; i < (ptrdiff_t)need; i++) setnilV(stack + i);

Nothing else changes: the existing `co->top = stack + top_ofs;` in pass 5 (line 1414) is already the only other write to co->top, so it becomes the single point where the real top is installed. Passes 2-4 are then covered too, which matters because they allocate as well (FrameRec userdata, elj_finduv, env unpersist).

Optional hardening, cheap and independent: after the grow, assert the postcondition once —
  if ((MSize)(mref(co->maxstack, TValue) - tvref(co->stack)) < (MSize)need)
    luaL_error(L, "eris-lj: restored thread stack too small");
so any future path that lets the size drift is caught rather than silently overflowing.
EVIDENCE: CONFIRMED by experiment on the stock, unmodified harness, then confirmed again by mechanism instrumentation and by a fix that makes it go away.

== 1. The crash is real and deterministic ==
Rebuilt the stock harness from the current tree (`touch eris_lj.c && make CC=gcc`) and ran the suggested repro:

  $ ./erislj_test.exe .../scratchpad/gclens/repro_min.lua
  persisting...
  blob bytes:     124597
  unpersisting...
  restored:       thread   suspended
  resuming...
  Segmentation fault ... exit=139

3/3 runs, exit 139 every time. repro_min.lua is an ordinary coroutine (recurses 40 deep, yields holding a 4000-entry table), no eris settings changed, no crafted blob, GC left alone.

== 2. The mechanism is exactly as claimed ==
Instrumented copy of eris_lj.c (scratchpad only; working tree untouched) that logs co->stacksize across pass 1 and aborts *before* the first out-of-bounds write:

  [DBG] u_thread: need=894 base_ofs=488 top_ofs=488 after-grow stacksize=912 maxstack_ofs=903
  [DBG]   stacksize CHANGED 912 -> 465 at i=5 (maxstack_ofs=456)
  [DBG]   *** OOB WRITE slot 456 into block whose maxstack_ofs is 456 (stacksize=465)

After only 4 slots had been written, a GC traversal halved the block. `need` stayed 894. Root cause chain verified in the pinned sources at prototype/watchdog/luajit/src:
 - lj_gc.c:319  gc_traverse_thread -> lj_state_shrinkstack(th, gc_traverse_frames(g, th))
 - gc_traverse_frames: `for (frame = th->base-1; frame > bot+LJ_FR2; ...)`. u_thread deliberately leaves co->base at the bottom during pass 1, so the loop body never runs and it returns `used = co->top - stack` — which trails the write cursor and is tiny.
 - lj_state.c:100 shrinkstack: `4*used < stacksize && 2*(LJ_STACK_START+LJ_STACK_EXTRA) < stacksize` -> resizestack(stacksize >> 1). With LJ_STACK_START=40 (lj_state.c:38, LUA_MINSTACK=20) and LJ_STACK_EXTRA=5+3*LJ_FR2=8 (lj_def.h:72), the second guard is `96 < stacksize`. A default thread is 48 slots, which is why every coroutine in tests/m3.lua is immune — the claim's explanation of the test-suite blind spot is correct.

== 3. Blast radius, measured (writes suppressed so the heap was not corrupted) ==
  [MEAS] need=894 base_ofs=488 top_ofs=488 | after grow: stacksize=912 (14592 bytes)
  [MEAS]   i=5    stacksize 912 -> 465
  [MEAS] pass-1 slot writes past the block: 23 slots = 368 bytes
  [MEAS] trailing nil-fill [488,894) would write 429 slots = 6864 bytes past the block
  [MEAS] final co->top = stack+488 lands 23 slots past the block end -- next gc_traverse_thread marks off-heap TValues
All three write sites named in the report (eris_lj.c:1250-1252, :1256, :1413-1414) confirmed. (Reported figure was 6568 bytes; I measure 6864 — same defect, same order.)

== 4. One correction to the report, and one addition ==
CORRECTION: variant B's conclusion is too strong. I tested collectgarbage("stop") before the restore on the plain no-blob path: it SURVIVES (true 6560 / survived). With the threshold at LJ_MAX_MEM the incremental GC never steps, so no shrink fires. The report is right that lua_gc(LUA_GCCOLLECT) -> lj_gc_fullgc runs regardless (lj_api.c:1254), but that path needs a crafted spkey closure calling collectgarbage("collect") inside the restore. So: GC-off does mitigate the no-blob path; it does not mitigate a crafted blob. Verdict unchanged — the default configuration crashes on ordinary input.

ADDITION: the exposure is not confined to pass 1, so the report's fix option 1 ("re-grow inside the pass-1 loop") is insufficient on its own. Passes 2-4 also allocate — lua_newuserdata for the FrameRec scratch (:1270), elj_finduv creating GCupvals (:1397), unpersist of the thread env (:1405) — while co->top is only stack+top_ofs. For a thread whose stack grew deep and then unwound before yielding (small top_ofs, large stacksize — exactly OC's kernel-coroutine shape), 4*top_ofs < stacksize holds and the shrink fires there instead, making the frame writes at :1331 and the final co->top at :1414 out of bounds. Any fix must hold the size invariant through pass 5, not just pass 1. Option 2 does this by construction.

== 5. Fix verified ==
Applied the fix below to a scratchpad copy and rebuilt:
 - repro_min.lua: runs clean, and the resumed coroutine returns the CORRECT value `true 6560` (= 8 * sum(1..40) = 8*820), so the restore is semantically right, not merely non-crashing.
 - A shrink detector on the fixed build: `[FIXCHK] need=894 stacksize after grow=912` / `stacksize at end of restore=912 -- UNCHANGED, no shrink fired`.
 - No regressions: M1 82/82, M2 55/55, M3 33/33 all pass on the fixed build (identical to stock).

Working tree left exactly as found (git status unchanged: M .gitignore, M serializer/eris_lj.c, M serializer/tests/m1.lua, plus the same four untracked entries); all probe binaries deleted.

Key file: C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c, u_thread, lines 1244-1256.

### [high] real-bug : u_function's TAG_UPVALOPEN slot check uses the partially-raised co->top, so a closure below the local it captures cannot be restored
FIX: Bound the slot by the owner thread's declared live span instead of its transient co->top. Since threads can nest (thread A's slot holds thread B whose closure captures a slot of A), carry the in-progress threads on a C-stack list, matching the existing PendingRef pattern in this file.

1. After the PendingRef typedef (~line 172):

  typedef struct RThread {
    lua_State *co;
    uint64_t top_ofs;
    struct RThread *prev;
  } RThread;

2. In Info, next to `PendingRef *pending;`:

  RThread *rthreads;          /* unpersist: threads still being restored */

  (Both Info sites already memset to 0, so no extra init is needed.)

3. Just before u_function (~line 1027):

  static uint64_t elj_live_top(Info *I, lua_State *co)
  {
    RThread *r;
    for (r = I->rthreads; r != NULL; r = r->prev)
      if (r->co == co) return r->top_ofs;
    return (uint64_t)(co->top - tvref(co->stack));
  }

4. Replace the check at eris_lj.c:1123-1126 with:

  if (slot < (uint64_t)(1 + LJ_FR2) || slot >= elj_live_top(I, owner))
    luaL_error(L, "eris-lj: open upvalue slot %d outside the thread's "
                  "live stack", (int)slot);

5. In u_thread, declare `RThread rt;` with the other locals, publish it after the stack growth and immediately before pass 1:

  rt.co = co; rt.top_ofs = top_ofs; rt.prev = I->rthreads; I->rthreads = &rt;

  and pop it on the normal exit path, after `co->cframe = NULL;`:

  I->rthreads = rt.prev;

  (An error longjmps out of the whole unpersist, so the list dies with the frames that own it, exactly like PendingRef.)

Worth adding to tests/m3.lua's "open upvalues" section: the forward-declaration case, the `local function` self-reference case, and the mutual-recursion case, each asserting the restored thread resumes to the right value — currently none of the 33 M3 tests places a closure at or below the slot it captures.
EVIDENCE: REPRODUCED. `C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c:1123-1126` (u_function, TAG_UPVALOPEN) bounds the open-upvalue slot against `owner->top - tvref(owner->stack)`. While u_thread is inside pass 1 (line 1248-1254), `co->top` is only the write cursor (`stack + i + 1` after each slot), so for the thread being restored that expression evaluates to the current loop index, not the thread's real top. A closure occupying a slot at or below the local it captures therefore names a slot the pass has not reached, and the load is rejected.

Probe (scratchpad p6_highslot.lua, run with the unmodified ./erislj_test.exe):

  == A. closure BELOW the local it captures (forward declaration) ==
    resume 1:	true	suspended
    round trip:	false	eris-lj: open upvalue slot 5 outside the thread's live stack
  == B. control: closure ABOVE the local it captures ==
    resume 1:	true	suspended
    round trip:	true	thread: 0x012ca51e1000
    resume 2 (restored):	true	100
  == C. local function f() ... f ... end (self reference) ==
    round trip:	false	eris-lj: open upvalue slot 4 outside the thread's live stack
  == D. mutual recursion (both forward-declared) ==
    round trip:	false	eris-lj: open upvalue slot 5 outside the thread's live stack

A and B differ only in the declaration order of `local f` and `local x = 99`. C is plain `local function f(n) ... f(n-1) ... end` — the recursive-local idiom, which always puts the closure in the same slot as its own upvalue and so also trips the check (`slot >= i` when slot == i). D is ordinary mutual recursion.

The failure is on the way back in, not on the way out. Splitting the halves (scratchpad p7_split.lua):

  resume 1:	true	suspended
  persist ok:	true	blob bytes:	599
  unpersist ok:	false	eris-lj: open upvalue slot 5 outside the thread's live stack

so eris.persist happily writes a well-formed 599-byte save that eris.unpersist refuses — an unloadable save, which for OC means a world that persists and then cannot be restored. (The error text is the u_function one, "outside the thread's live stack"; u_thread's pass-4 check at line 1391 has different wording, "outside the live stack", so the site is unambiguous.)

Root cause confirmed by fixing it: bounding against the thread's DECLARED span (top_ofs from the header, already validated at 1225-1227 as base_ofs <= top_ofs <= need < LUAI_MAXSTACK, with the stack grown to `need` at 1235-1242) makes all four cases round-trip and resume with the right values (100, 100, 10, true/false), and tests/m1.lua (82), m2.lua (55), m3.lua (33) all still pass.

The guard is not weakened. With the fix in place, patching the TAG_UPVALOPEN ULEB slot byte in the case-A blob and resealing the CRC (scratchpad p8_adversarial.lua; top_ofs is 8 here):

  slot byte at offset:	560	value:	5
  unpatched reseal loads:	true
    slot -> 8    loaded=false  eris-lj: open upvalue slot 8 outside the thread's live stack
    slot -> 40   loaded=false  eris-lj: open upvalue slot 40 outside the thread's live stack
    slot -> 100  loaded=false  eris-lj: open upvalue slot 100 outside the thread's live stack
    slot -> 0    loaded=false  eris-lj: open upvalue slot 0 outside the thread's live stack
    slot -> 1    loaded=false  eris-lj: open upvalue slot 1 outside the thread's live stack
  survived a full GC

Aliasing a slot pass 1 has not written yet is safe: the whole span is nil-initialised by lua_newthread/resizestack, and pass 1's copyTV later fills the slot the upvalue points at, which is why the restored closures read the correct values.

Working tree restored: eris_lj.c is byte-identical to how I found it, the binary was rebuilt from it (m3 33/33), git status is unchanged, and no probe binaries were left behind. Probes live only in the scratchpad.

Side note, not part of this defect: elj_finduv returns an existing upvalue without applying the `immutable` argument, so the flag recorded per open upvalue in u_thread's pass 4 (line 1390/1397-1399) is always dropped whenever u_function created the same upvalue during pass 1 — which is every open upvalue of a restored thread, including the currently-passing case B. That only costs a JIT optimisation, never correctness.

### [medium] real-bug : elj_finduv drops func_finduv's resurrect branch, but pass-4 upvalues really can be dead-coloured
FIX: Restore func_finduv's resurrect branch in elj_finduv (C:\Users\astro\Downloads\OC-LuaJIT\serializer\eris_lj.c:664-667), and drop the stale rationale in the comment at line 652.

-    if (uvval(p) == slot) return p;     /* already open for this slot */
+    if (uvval(p) == slot) {
+      /* Pass 4 creates open upvalues that nothing references yet — they are
+       * unreachable for marking until elj_repoint_referrers attaches them —
+       * so a cycle flipping currentwhite in between leaves this one dead,
+       * and gc_sweep (lj_gc.c:411) frees open upvalues off the thread's own
+       * list. Resurrect, exactly as func_finduv does. */
+      if (isdead(g, obj2gco(p))) flipwhite(obj2gco(p));
+      return p;     /* already open for this slot */
+    }

and at line 652 replace
  " *  - no resurrect branch: a thread we are building has no dead upvalues;"
with a note that the resurrect branch is kept because pass-4 upvalues are unreferenced until the join.

That is the memory-safety fix and it is sufficient (verified: 8/8 clean runs plus the forced-window stress). Optional hardening, not required: pass 4 could defer creation to the join, or anchor the upvalues it creates, which would also remove the wasted allocation in the case where a full cycle completes in the window and the sweeper deletes the orphan.
EVIDENCE: REPRODUCED on the pristine repo build, with the stock GC and no injected timing — the reviewer's "analysis-only, narrow and timing-dependent" caveat is too generous; the defect fires spontaneously.

WHY THE EARLY-RETURN PATH IS HOT (not exotic)
elj_finduv is called TWICE for the same slot on every restore that has an open upvalue:
  - C:\Users\astro\Downloads\OC-LuaJIT\serializer\eris_lj.c:1397 — u_thread pass 4
  - C:\Users\astro\Downloads\OC-LuaJIT\serializer\eris_lj.c:1127 — u_function's TAG_UPVALOPEN join
Instrumented counters over every probe: created == found == (number of open upvalues), i.e. line 665 is taken once per open upvalue, always.

Which call runs first depends on graph order. When the thread is serialized before the escaping closure (array slot 1 = thread), pass 4 creates the upvalue with NO referrer — traced:
  [DBG] finduv site=4 co=...d508 slot=4 -> CREATED ...d388 marked=02 cw=22 gcs=0
  [DBG] finduv site=1 co=...d508 slot=4 -> FOUND   ...d388 marked=02 cw=21 gcs=3 *** DEAD ***
(cw 22 -> 21 = currentwhite flipped by atomic(); gcs=3 = GCSsweepstring). Right after the restore, eris.__fnuvinfo(esc,1) reports dead=true.

CORRECTION TO THE CLAIMED HARM MECHANISM — it is worse than stated
It is not lj_func_closeuv at unwind time. gc_sweep frees open upvalues directly:
  lj_gc.c:411-412  if (o->gch.gct == ~LJ_TTHREAD)  /* Need to sweep open upvalues, too. */
                     gc_fullsweep(g, &gco2th(o)->openupval);
So the next sweep step that reaches the restored thread calls lj_func_freeuv on it — no resume, no unwind needed. Measured: after one ordinary collectgarbage("collect"), the thread's open-upvalue list is EMPTY while the restored closure still holds the freed address (uv->closed is still 0, so it was freed, not closed).

OBSERVABLE CORRUPTION, PRISTINE BUILD, NO INSTRUMENTATION, NO INJECTION
Probe: 500 round-trips of {suspended coroutine holding local n=41, closure over n that escaped off its stack via a permanent sink}, then ordinary heap churn, then check esc()==42 and resume(co)==42.
  PRISTINE (C:\Users\astro\Downloads\OC-LuaJIT\serializer\eris_lj.c, byte-identical copy): FAIL in 7 of 8 runs, e.g.
    BAD #113: esc() -> true 42 ; resume(co) -> true 41      (closure and frame no longer share the slot)
    BAD #114: esc() -> true 43                              (two restores writing one recycled GCupval)
    BAD #199: esc() -> true 1
    BAD #200: esc() -> false ... attempt to compare two function values   (the upvalue now holds an unrelated object)
  Same probe on a build with only the 2-line fix: PASS 0 wrong, 8 of 8 runs.
With an instrumented build that parks the collector at GCSsweepstring inside the window, 12 restores give DEAD-found=6, 6 closures whose upvalue the sweep freed, then SIGSEGV (exit 139); at N=200 it segfaults every time. With the fix and the same forced window: DEAD-found=101, 0 dead-held, 0 freed, 0 wrong, no crash.

Regression check on the fixed build: m1 82/82, m2 55/55, m3 33/33.

SECONDARY CONFIRMATION THAT THE PREMISE IS FALSE
Forcing a FULL cycle (not just to sweepstring) after pass 4 shows the sweeper deleting the orphan before the join ever sees it — elj_finduv then builds a second upvalue for the same slot on an empty list:
  site=4 ... CREATED ...8059a8   /  site=1 ... CREATED ...805458 (openupval was <empty>)
Benign for the shapes tested, but it proves "a thread we are building has no dead upvalues" (eris_lj.c:652) is simply untrue: pass-4 upvalues are unreferenced, unmarked garbage until a closure joins them (gc_traverse_thread does not walk co->openupval; gc_mark_uv only marks the VALUE of already-gray upvalues — both confirmed in lj_gc.c:309-321 and :116-125).

Probes left in the scratchpad (repo untouched):
  ...\scratchpad\p6_pure.lua                (pure-Lua repro, run against pristine and fixed trees)
  ...\scratchpad\lab\p2_trace.lua, p3_uaf.lua, p4_alias.lua, p5_stress.lua
  ...\scratchpad\pristine\ and ...\scratchpad\fixed\  (build trees; binaries deleted)
The repo working tree is exactly as found — I only ever copied out of it. (Note: `git status` shows uncommitted M3 work in serializer/eris_lj.c, .gitignore and tests/m1.lua; that pre-existed and is not mine — my pristine copy is byte-identical to the current repo file.)

### [medium] real-bug : p_thread holds `bot` across the slot-persist loop, which can realloc the coroutine's stack
FIX: Minimal fix — re-derive `bot` (and `stack`, in case the loop body never ran) immediately before the frame walks in p_thread, C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c. Insert directly above the `/* Frames, walked top-down. ... */` comment (currently line 757):

  /* persist() can run the GC, and a GC that traverses `co` shrinks its stack
   * (lj_state_shrinkstack -> resizestack -> lj_mem_realloc), which may MOVE
   * the block: the stock lj_alloc cannot shrink a direct (>=128K, mmap'd)
   * chunk in place. base/top are carried along by resizestack, so the
   * offsets stay valid, but `bot` must be re-derived. */
  stack = tvref(co->stack);
  bot = stack + LJ_FR2;

Verified: with this applied to the current file, the reproducer's frame walk finds all 4 frames despite the move and the round trip resumes correctly, and tests/m1.lua + m2.lua + m3.lua still report 82 + 55 + 33 ALL PASS.

Note that `base_ofs`/`top_ofs` genuinely do not need re-reading — resizestack shifts co->base and co->top by the same delta, which the probe confirms (base_ofs stays 13 across the move).

Separately (not this finding, but same root cause and it bites right after): u_thread must stop trusting the up-front grow. Either re-check and re-grow before the `for (i = top_ofs; i < need; i++) setnilV(stack + i);` fill, or hold the GC off across pass 1; and p_thread should write `need` from a stacksize read after the slot loop rather than before it (which requires moving that header field after the loop).

Probe sources are left in the session scratchpad at C:/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/bot (probe_main.c with the lj.stackinfo helper, p0-p4.lua, instr.py/fix.py). All probe binaries were deleted and no file in the working tree was created or modified.
EVIDENCE: CONFIRMED, and stronger than claimed: no debug allocator is needed — the STOCK lj_alloc moves the block, and both predicted failure modes occur (silent unloadable blob, and a SIGSEGV inside p_thread's frame walk).

## Why the stock allocator moves it

A coroutine stack that has grown past 128 KB is a DIRECT (mmap'd) chunk. Shrinking one cannot happen in place:
- prototype/watchdog/luajit/src/lj_alloc.c:845 `direct_resize()` keeps the old chunk only if `(oldsize - nb) <= (DEFAULT_GRANULARITY >> 1)` (64 KB); a halving of a >=128 KB chunk always exceeds that.
- lj_alloc.c:387 — on Windows `CALL_MREMAP` is `MFAIL`.
- lj_alloc.c:1459-1466 — so `lj_alloc_realloc` falls through to malloc-copy-free. The block MOVES.

Bare demonstration (probe with an `lj.stackinfo()` C helper; a coroutine that recurses ~4000 deep, unwinds, then yields shallow):

    stackinfo: 0x7ff446ea0010 ss=58359 base=15 top=15 frames=4
    after gc : 0x0232034f0bf8 ss=14603 base=15 top=15 frames=4   <-- moved

## The blob p_thread writes after that move

Instrumented build of eris_lj.c (printf of stack/bot/co->base around the walk), with an spkey `__persist` on a table sitting in one of the coroutine's slots that calls `collectgarbage("collect")` — i.e. the GC runs squarely inside the slot loop:

CONTROL (no GC inside the loop):
    before persist: addr=0x7ff44b430010 stacksize=58359 base=13 top=13 frames=4
    [dbg] p_thread ENTER   stack=00007ff44b4b0010 bot=00007ff44b4b0018 base_ofs=13 top_ofs=13 stacksize=29188
    [dbg] p_thread WALK    stack=00007ff44b4b0010 bot=00007ff44b4b0018 co->base=00007ff44b4b0078 -> nframes=4
    [dbg] u_thread nframes=4 need=29179 base_ofs=13 top_ofs=13
    unpersist ok, status=suspended
    resume -> true, done                                  <-- round trip works

TEST (GC inside the loop, downward move):
    [trap] before gc: addr=0x7ff4c5690010 stacksize=29188 base=13 top=13 frames=4
    [trap] after  gc: addr=0x024e421d56c0 stacksize=7310  base=13 top=13 frames=4
    [trap] *** STACK MOVED 0x7ff4c5690010 -> 0x024e421d56c0
    after  persist: blob=989 bytes                        <-- persist SUCCEEDS
    [dbg] p_thread ENTER   stack=00007ff4c5690010 bot=00007ff4c5690018 ... stacksize=29188
    [dbg] p_thread WALK    stack=0000024e421d56c0 bot=00007ff4c5690018 co->base=0000024e421d5728 -> nframes=0
    [dbg] u_thread nframes=0 need=29179 base_ofs=13 top_ofs=13
    UNPERSIST FAILED: eris-lj: suspended thread with no frames

`stack` is refreshed to the new block; `bot` is still 0x00007ff4c5690018, an address inside the freed block. `co->base - 1 > bot` is false immediately, so a thread with 4 live frames is written as nframes == 0. Exactly the "save that silently cannot be loaded" the report predicts. Reproduced 100% of runs.

UPWARD move (stop the GC, then single-step it until the block moves — one halving of a 467 KB direct chunk lands on another direct chunk at a higher address):
    before persist: addr=0x7ff429ae0010 stacksize=58359 base=13 top=13 frames=4
    [trap] moved after 10 steps: 0x7ff429ae0010 -> 0x7ff429b60010 (UPWARD)
    Segmentation fault (exit=139)
The walk runs off the bottom of the new block and decodes unmapped memory as frame words. This is the memory-unsafe half of the finding, and it crashes inside p_thread during eris.persist.

## Currency of the result

C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c was edited by a concurrent process three times while I worked (a "dead thread" branch was added; the walk start became `stack + base_ofs - 1`). I re-ran the whole experiment against the file as it stands now — `bot` is still computed once at line 731 and never refreshed — with the same result: broken blob 950 bytes / "suspended thread with no frames" (unfixed), 961 bytes / "resume -> true, done" (fixed), and the same SIGSEGV on the upward move.

## Second claim ("need over-claims") is NOT harmless

`need` is written at line 741-742 from the pre-loop stacksize (58350) while the stack ends at 29188. That combines with a separate, previously unreported defect in u_thread: its "grow once, up front" is undone by a GC during pass 1, because the restored thread's `used` is tiny and gc_traverse_thread -> lj_state_shrinkstack shrinks it right back. gdb at the nil-fill (eris_lj.c `for (i = top_ofs; i < need; i++) setnilV(stack + i);`):
    $1 = need           58350
    $2 = co->stacksize  14605
    $3 = maxstack-stack 14596
-> a 350 KB heap overflow, SIGSEGV in u_thread. This still happens with the p_thread fix applied, so it is a distinct bug worth its own finding; the over-claimed `need` only widens it.

### [low] real-bug : The `immutable` flag is lost on a restored open upvalue
FIX: One hunk, in u_thread's pass 4 (the `(void)elj_finduv(L, co, ...)` call; ~line 1430 in the snapshot I tested, but the file is being edited concurrently so match on the code, not the line number). Make the recorded bit authoritative, mirroring lj_func_newL_gc:

-      (void)elj_finduv(L, co, tvref(co->stack) + slot,
-                       (uint32_t)(uintptr_t)(tvref(co->stack) + slot),
-                       immutable);
+      {
+        GCupval *uv = elj_finduv(L, co, tvref(co->stack) + slot,
+                                 (uint32_t)(uintptr_t)(tvref(co->stack) + slot),
+                                 immutable);
+        /* Pass 1 may already have created this upvalue, for a closure that
+         * lives in the thread's own stack; elj_finduv's early return leaves
+         * an existing object alone, so apply the recorded bit here. This is
+         * what lj_func_newL_gc does too: it overwrites immutable on whatever
+         * func_finduv hands back. */
+        uv->immutable = (uint8_t)immutable;
+      }

Do NOT instead move the assignment into elj_finduv's early-return path: u_function's TAG_UPVALOPEN site passes a hardcoded 0, so that would clobber a correct 1 written by pass 4 whenever the closure is restored after the thread (the section-2 ordering). Pass 4 is the only site that knows the true bit, and it is also the site that runs after pass 1, so it is the right place.

Optional regression test for tests/m3.lua's "open upvalues" section: the bit is not visible from Lua, so asserting it needs a C hook like the probe's uvlens(); if that is not wanted, a comment at the TAG_UPVALOPEN `0` argument noting that pass 4 owns the bit is the cheap alternative.

No change needed for dhash.
EVIDENCE: REPRODUCED. Built an inspector harness (scratchpad `uvprobe/uvlens.c` = test_main.c plus `uvlens(thread)`, which walks `co->openupval` and prints slot/immutable/closed/dhash straight off each GCupval) linked against an unmodified copy of C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c, and ran the coroutine from the report (`local x = 42; local mut = 1; reader = function() return x end; writer = function() mut = mut + 1 end`, yielded with the closures live).

UNPATCHED, current source:
  === section 1: closures live INSIDE the thread's own stack ===
  original    openuv=2  | slot=5 imm=0 closed=0 dhash=0x825bcb50  | slot=4 imm=1 closed=0 dhash=0x835bcb50
  restored    openuv=2  | slot=5 imm=0 closed=0 dhash=0x835bd350  | slot=4 imm=0 closed=0 dhash=0x835bd348
    resume ->	true	42	1
  === section 2: same shape, closures reachable only from OUTSIDE ===
  original    openuv=2  | slot=6 imm=0 closed=0 dhash=0x815bdcc8  | slot=5 imm=1 closed=0 dhash=0x825bdcc8
  restored    openuv=2  | slot=6 imm=0 closed=0 dhash=0x835c02d0  | slot=5 imm=0 closed=0 dhash=0x835c02c8

slot 4 (`x`) is immutable on the original and imm=0 on the restore, exactly as claimed. Semantics are unaffected (`resume -> true 42 1`), so it is a fidelity/JIT-pessimization defect, not a miscompile.

MECHANISM CONFIRMED. `elj_finduv`'s early return (`if (uvval(p) == slot) return p;`) hands back an existing object untouched, so whichever call site runs first fixes the bit forever. u_thread pass 1 restores the thread's slot values, and any closure sitting in those slots reaches u_function's TAG_UPVALOPEN path, which calls `elj_finduv(..., 0)` with the immutable argument hardcoded to 0. Pass 4 then re-reads the recorded byte and calls `elj_finduv` again, hits the early return, and the recorded bit is dropped. (An earlier snapshot of the file, before it was edited under me, still preserved imm=1 in section 2 because there the upvalue was first created by pass 4; on the current source both sections lose it. Either way the recorded byte is dead weight in the common case.)

FIX VERIFIED. With the one-hunk patch below applied to a scratch copy of the *current* source: section 1 restored `slot=4 imm=1`, section 2 restored `slot=5 imm=1` (both matching their originals), and tests/m3.lua 33/33, tests/m2.lua 55/55, tests/m1.lua 82/82 all still pass.

SOUNDNESS OF WRITING THE RECORDED BIT: lj_parse.c fs_fixup_uv2 sets PROTO_UV_IMMUTABLE from the enclosing function's per-variable VSTACK_VAR_RW flag, and that fixup runs when the *parent* prototype closes, so every closure capturing a given slot of a given activation agrees on the bit — there is no "one reader, one writer, conflicting bits" case. And stock LuaJIT does exactly this write itself: lj_func_newL_gc unconditionally does `uv->immutable = ((v / PROTO_UV_IMMUTABLE) & 1);` on whatever func_finduv hands back, existing object or not. `immutable` has only one consumer in the whole VM (rec_upvalue_constify in lj_record.c; grep finds no other reader, none in the interpreter dasc, lj_snap, lj_asm), which is why the loss is safe-direction.

THE dhash SUB-CLAIM IS PARTLY WRONG AND NOT A DEFECT. "different across the two call sites for the very same upvalue" does not happen: a given GCupval is created exactly once, and both sites evaluate the same expression over a stack that u_thread grows once up front and never reallocates (pass 1 only fills slots), so they necessarily agree — the measured restored pairs are literally consecutive slot addresses (0x...d348 / 0x...d350, 8 bytes apart). "Non-deterministic across restores" is true, but equally true of stock LuaJIT, whose dhash is `(uintptr_t)pt` or `(uintptr_t)mref(parent->pc)` XOR the descriptor — also a runtime address, also different every process. And distinct upvalues always get distinct slot addresses, so the address-derived value disambiguates at least as well; dhash only seeds a guarded CSE key in rec_upvalue. Cosmetic at most, no fix required.

Files: probe sources left in the scratchpad at C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\uvprobe\ (uvlens.c, p_uv.lua); all probe binaries deleted. The repo working tree was never written by me.

######## LENS: semantics-at-scale ########

### [critical] real-bug : GC shrinks the restored thread's stack in the middle of u_thread — heap buffer overflow
FIX: Minimal fix — replace serializer/eris_lj.c:1244-1256 (the Pass 1 block) with:

  /* Clear the dead span and publish the FINAL live top before anything else
   * can allocate. Every unpersist() below can run lj_gc_step, and propagating
   * this (reachable) thread calls
   *   gc_traverse_thread -> lj_state_shrinkstack(co, gc_traverse_frames(co))
   * which, with co->base still at the bottom, reports used == co->top - stack
   * and HALVES the allocation whenever 4*used < co->stacksize. Publishing
   * top_ofs up front pins used at top_ofs, and a halved stack always keeps
   * more than 2*top_ofs slots, so every slot this function writes stays
   * inside the allocation no matter how often the collector shrinks it.
   * (Slots below top are still nil here, so marking them is harmless.) */
  stack = tvref(co->stack);
  for (i = (ptrdiff_t)top_ofs; i < (ptrdiff_t)need; i++) setnilV(stack + i);
  co->top = stack + top_ofs;

  /* Pass 1: slot values. co->base stays at the bottom until the frames are in
   * place, so a GC can never walk a half-written frame chain. */
  for (i = 1 + LJ_FR2; i < (ptrdiff_t)top_ofs; i++) {
    unpersist(I);                       /* ... value */
    stack = tvref(co->stack);
    copyTV(co, stack + i, L->top - 1);  /* NOBARRIER: threads are never black */
    lua_pop(L, 1);
  }
  /* A shrink during Pass 1 may have given up the spare capacity the source
   * had; restore it so the thread resumes with the stack it was saved with. */
  {
    MSize cur = (MSize)(mref(co->maxstack, TValue) - tvref(co->stack));
    if ((MSize)need > cur) {
      int rc = lj_state_cpgrowstack(co, (MSize)need - cur);
      if (rc != LUA_OK)
        luaL_error(L, "eris-lj: cannot grow the restored thread stack");
    }
  }
  stack = tvref(co->stack);

(The two changes: the nil fill + `co->top = stack + top_ofs` move BEFORE Pass 1, and `co->top = stack + i + 1` is dropped from the loop body. The trailing re-grow is only for capacity fidelity.)

Why this is sufficient for every remaining write: after the publication, shrink can only fire while 4*top_ofs < co->stacksize, and resizestack(co, stacksize>>1) leaves maxstack at index stacksize>>1 > 2*top_ofs. Every write after Pass 1 — the frame words at fr[k].at, the continuation words at at-3/at-4, the Pass 4 upvalue slots, and the final co->base/co->top — is at an index < top_ofs, so it stays in bounds through any number of shrinks. The only writes above top_ofs are the nil fill, which now runs while the up-front grow's capacity is still guaranteed.

Suggested regression test for tests/m3.lua: persist/unpersist a coroutine that has grown its stack (recursion depth ~40, or unpack() of a 300-element array) and then run a few collectgarbage("step") cycles after the restore. Any such case has need >= 88 and trips the shrink; every current m3 thread has need = 39.

Verification artifacts left in the scratchpad (sources only, binaries deleted):
  .../scratchpad/verify/vp_shrink2.lua, vp_shrink3.lua, vp_shrink.lua   (probes)
  .../scratchpad/verify/eris_lj_probe.c        (shrink watcher, bails before corrupting)
  .../scratchpad/verify/eris_lj_stock_assert.c (unmodified source + bounds assertions)
  .../scratchpad/verify/eris_lj_myfix.c, eris_lj_myfix_assert.c (the fix, with and without assertions)
Build line: gcc -std=c11 -O2 -g -Wall -Wextra -I ../prototype/watchdog/luajit/src -DERIS_LJ_COMMIT='"1ee778a4e37122d8ca7d5733c590a47dafd6b15c"' <file>.c test_main.c ../prototype/watchdog/libluajit_stock.a -lm -o <out>.exe  (run from serializer/)
EVIDENCE: REPRODUCED INDEPENDENTLY AND DETERMINISTICALLY. I wrote my own probes and my own instrumentation rather than using the ones named in the claim.

== 1. The threshold arithmetic checks out on this pinned build ==
prototype/watchdog/luajit/src/lj_def.h:72  LJ_STACK_EXTRA = (5+3*LJ_FR2) = 8
lj_state.c:36-38                            LJ_STACK_START = 2*LUA_MINSTACK = 40
lj_state.c:98-105  lj_state_shrinkstack: `4*used < L->stacksize && 2*(LJ_STACK_START+LJ_STACK_EXTRA) < L->stacksize` -> fires for stacksize > 96.
lj_gc.c:309-321 gc_traverse_thread ends with lj_state_shrinkstack(th, gc_traverse_frames(g, th)); lj_gc.c:346-352 propagatemark reaches it for any reachable thread.
lj_state.c:173-185 stack_init: a fresh coroutine is stacksize 48 (safe), but the FIRST growth goes to 96+1+8 = 105 -> every coroutine that has ever grown its stack is in the danger zone.
gc_traverse_frames (lj_gc.c:292-306) walks `frame = th->base-1; frame > bot+LJ_FR2` — with co->base still at stack_init's bottom it walks nothing and returns `co->top - stack`, exactly as claimed.

== 2. Non-corrupting instrumented proof (my own copy, scratchpad/verify/eris_lj_probe.c) ==
A copy of eris_lj.c that only WATCHES co->stacksize and bails out on the first change, so it never performs the bad writes.

scratchpad/verify/vp_shrink2.lua (coroutine grows via unpack(), unwinds, yields shallow holding a 400-entry table):
  [probe] u_thread: need=660 base_ofs=9 top_ofs=9  stacksize after grow = 678 slots (5424 bytes)
  [probe] !!! SHRINK at Pass 1 (slot unpersist): stacksize 678 -> 348 slots (buffer 5424 -> 2784 bytes), maxstack idx 339
  [probe]     u_thread still believes it owns 660 slots and will write up to index 659  =>  312 slots (2496 bytes) PAST THE END

scratchpad/verify/vp_shrink3.lua (the REALISTIC OC-kernel shape: suspended 40 frames deep, large live top):
  [probe] u_thread: need=438 base_ofs=328 top_ofs=328  stacksize after grow = 456 slots (3648 bytes)
  [probe] !!! SHRINK at Pass 1 (slot unpersist): stacksize 456 -> 127 slots (buffer 3648 -> 1016 bytes), maxstack idx 118
  [probe]     ... will write up to index 437  =>  311 slots (2488 bytes) PAST THE END
(456 -> 237 -> 127: the collector shrank it TWICE inside Pass 1.)

== 3. Bounds-assert build on the UNMODIFIED source (scratchpad/verify/eris_lj_stock_assert.c) ==
Same file, plus `ELJ_BOUND(idx)` before every stack write. First violation:
  vp_shrink2: [assert] OUT OF BOUNDS stack write at slot 348 (allocation is 348 slots) at line 1258  <- the nil-fill loop
  vp_shrink3: [assert] OUT OF BOUNDS stack write at slot 127 (allocation is 127 slots) at line 1252  <- Pass 1's copyTV itself
  tests/m1.lua 82/82, m2.lua 55/55, m3.lua 33/33 all still pass -> the assertion is not spurious.

== 4. Real corruption on the stock binary (serializer/erislj_test.exe as built in the tree) ==
  ./erislj_test.exe .../vp_shrink3.lua  x8 -> 139 139 139 139 139 139 139 139   (8/8 SIGSEGV)
  ./erislj_test.exe .../vp_shrink2.lua  x8 -> 139 139 139 139 139 139 139 139   (8/8 SIGSEGV)
  ./erislj_test.exe tests/m3.lua        x8 -> 0 0 0 0 0 0 0 0
Before the crash the restore itself "succeeds" and resumes correctly; the process dies in the next GC:
  gdb -batch -ex run -ex bt --args ./erislj_test.exe .../vp_shrink2.lua
  Thread 1 received signal SIGSEGV
  #0 gc_sweep ()  #1 gc_onestep ()  #2 lj_gc_step ()  #3 lj_gc_step_jit ()
  rbx  0xffffffffffffffff        <- a nil TValue read as a GCRef, i.e. the OOB nil-fill wrote over adjacent GC object headers
Re-confirmed against the freshest revision of eris_lj.c/erislj_test.exe in the tree (another agent rebuilt them mid-session at 18:36:41): the vulnerable code at eris_lj.c:1233-1256 is unchanged and still crashes 8/8.

== 5. Why the suite misses it (claim confirmed) ==
Instrumented run of tests/m3.lua: all 16 restored threads report `need=39 ... stacksize after grow = 48`. Max need across the whole suite = 39. 48 < 96, so lj_state_shrinkstack can never fire there.

== 6. Bonus defect found by the same probe ==
scratchpad/verify/vp_shrink.lua puts a self-recursive `local function` in the coroutine's own stack. Stock fails 10/10 with
  "eris-lj: open upvalue slot 5 outside the thread's live stack"
because u_function's TAG_UPVALOPEN check (eris_lj.c:1123-1126) compares the slot against `owner->top`, which during Pass 1 is only `stack + i` — the slot being written. The same reordering fixes it (the fixed build restores and resumes that coroutine).

== 7. Fix verified ==
scratchpad/verify/eris_lj_myfix.c (+ the assert variant): tests/m1 82/82, m2 55/55, m3 33/33; vp_shrink2 and vp_shrink3 8/8 clean each with full bounds assertions armed; vp_shrink3 still computes the right answer (3520 = sum_{n=1..40}(4n+6)); vp_shrink.lua now round-trips.

== One correction to the claim ==
The claim's "re-grow after Pass 1" is NOT sufficient by itself: in the deep-stack (OC-kernel) shape the first out-of-bounds write happens INSIDE Pass 1 at eris_lj.c:1251 (assert fired at line 1252 of the instrumented copy), long before any post-loop re-grow could run. The load-bearing half of the fix is moving the `co->top = stack + top_ofs` publication (and the nil fill) AHEAD of Pass 1. The claim does include that change, so the combined fix is correct — but the ordering, not the re-grow, is what closes the hole.

### [critical] real-bug : A recursive `local function` on a suspended stack makes the blob unloadable
FIX: Minimal fix in u_thread: raise co->top to the DECLARED top before Pass 1 instead of dragging it behind the write cursor, and nil the live span up front. Replace eris_lj.c:1248-1256 with:

  stack = tvref(co->stack);
  for (i = 1 + LJ_FR2; i < (ptrdiff_t)need; i++) setnilV(stack + i);
  co->top = stack + top_ofs;
  for (i = 1 + LJ_FR2; i < (ptrdiff_t)top_ofs; i++) {
    unpersist(I);                       /* ... value */
    stack = tvref(co->stack);
    copyTV(co, stack + i, L->top - 1);  /* NOBARRIER: threads are never black */
    lua_pop(L, 1);
  }

(the `co->top = stack + i + 1;` inside the loop and the trailing `for (i = top_ofs; i < need; i++) setnilV(...)` both go away).

Why it is safe: top_ofs is already range-checked against need at eris_lj.c:1225, so the u_function bound stays tight -- a forged slot >= top_ofs is still rejected; only the legal window widens from "slots already filled" to "slots that will be live", which is correct because an open upvalue is an alias, not a copy. Nil slots are safe for a mid-restore GC: gc_traverse_thread marks [stack+1+LJ_FR2, top) and only clears ABOVE top, and co->base still stays at the stack bottom until Pass 3, so no half-written frame chain can be walked.

Also update the Pass 1 comment at eris_lj.c:1244-1247, which currently explains the old invariant: it should say the top is the declared top and that a slot may legally hold a closure whose open upvalue aliases a slot Pass 1 has not reached yet (`local function f` with f recursive captures its own slot).

Coverage gap to close: tests/m3.lua only ever captures earlier slots (`local n = 0; local bump = function() n = n + 1 end`). Add a recursive `local function`, a forward-declared local whose captured variable is declared after it, and mutual recursion -- all on a suspended stack.

SECONDARY, NOT VERIFIED, worth a separate look: in the stock ordering the tail nil-fill runs after Pass 1, while gc_traverse_frames returns th->top - bot, which during Pass 1 is the small running i. If lj_state_shrinkstack fires on that (4*used < stacksize), the stack can shrink below `need` and that fill writes past the allocation. The fix above incidentally closes it, since the fill then precedes any unpersist and every later write is bounded by top_ofs.
EVIDENCE: REPRODUCED independently, then fix confirmed. To rule out a stale/tampered in-tree binary I compiled out-of-tree from the exact current serializer/eris_lj.c (sha256 c9674a4893ab6b407258ee91ea3c1471ed235a30c29925025ff34ae9d473df5d) and wrote my own probes.

MECHANISM: eris_lj.c:1123-1126 (u_function, TAG_UPVALOPEN) bounds the slot by owner->top. When owner is the thread being restored, that is the RUNNING top from u_thread Pass 1 (eris_lj.c:1252 `co->top = stack + i + 1`), so at iteration i the accepted range is [1+LJ_FR2, i) -- strictly below the slot being filled. persist succeeds and writes a well-formed blob; unpersist refuses it.

STOCK (built from current source), probe verify2/v1.lua:
  == A. control: closure over an EARLIER slot (what m3.lua tests) ==
  earlier-slot capture               resume1=true/2 status=suspended
      persist ok, 631 bytes
      restored resume2=true/3
  == B. recursive local function (self-slot capture) ==
  recursive local function           resume1=true/55 status=suspended
      persist ok, 703 bytes
      UNPERSIST FAILED: eris-lj: open upvalue slot 4 outside the thread's live stack
  == C. forward-declared local ==
  forward-declared local             resume1=true/42 status=suspended
      persist ok, 620 bytes
      UNPERSIST FAILED: eris-lj: open upvalue slot 5 outside the thread's live stack
  == D. mutual recursion ==
  mutual recursion                   resume1=true/true status=suspended
      persist ok, 964 bytes
      UNPERSIST FAILED: eris-lj: open upvalue slot 5 outside the thread's live stack
  == E. non-recursive local function ==
      restored resume2=true/8   (passes)

Case C matters: `local getter; local value = 41; getter = function() return value+1 end` puts the captured slot ABOVE the closure's slot but well inside the declared top -- so the bound is provably the running top, not the declared top, and this is not merely a self-reference corner case.

OC SHAPE (verify2/v2.lua, kernel/bios/init/shell/program, each layer built from recursive `local function`s, suspended deep in a call chain):
  STOCK: "UNPERSIST FAILED: eris-lj: open upvalue slot 5 outside the thread's live stack" -- round-trips survived: 0/25
  FIXED: "restored resume2 = kernel#4" -- round-trips survived: 25/25

WITH THE FIX (same source + the patch below): v1 A-E all restore and resume correctly (B resume2=8, C=42, D=true).

SEMANTICS, not just absence of an error (verify2/v3.lua, 9 checks, all pass with the fix): the thread's write to its local slot is read back through the restored closure's upvalue (99); a write through the closure lands in the thread's local (12 both ways); fib(15)=610 continues correctly after restore and the original thread is unaffected; two restored copies advance independently. So the restored upvalue genuinely ALIASES the stack slot rather than becoming a private copy.

NO REGRESSION with the fix: tests/m1.lua 82 pass, tests/m2.lua 55 pass, tests/m3.lua 33 pass.

Working tree left exactly as found (git status identical to session start; eris_lj.c sha unchanged; both probe binaries deleted).

### [high] real-bug : A thread suspended inside any `for ... in pairs()` loop cannot be persisted at all
FIX: Minimal fix, applied and tested in scratchpad/vkey/eris_lj.c (all three suites still green). Three hunks in C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c.

(a) include + tag (add `#include "lj_tab.h"` after lj_vm.h; new tag, 14 stays reserved for userdata):
      TAG_KEYINDEX = 15, /* thread slots only: an ITERN for-in traversal index */
      TAG_MAX_M3 = TAG_KEYINDEX
    This is a wire-format change: bump the format byte, or accept that new blobs will not load in older builds.

(b) p_thread slot loop (eris_lj.c:730, first statement inside `for (i = 1 + LJ_FR2; i < top_ofs; i++)`):

    /* BC_ISNEXT's for-in control slot: a lightud whose high half is the
     * LJ_KEYINDEX marker and whose low half is a raw traversal index into the
     * CURRENT array+node layout of the table being iterated (one slot below,
     * per BC_ITERN's [func][state][ctrl]). The index is meaningless against a
     * rebuilt table, so store the last key returned and re-derive the index
     * with lj_tab_keyindex on restore. */
    if (tvislightud(stack + i) && (stack + i)->u32.hi == LJ_KEYINDEX) {
      uint32_t idx = (stack + i)->u32.lo;
      TValue *st = stack + (i - 1);
      GCtab *t;
      if (i - 1 < 1 + LJ_FR2 || !tvistab(st))
        luaL_error(L, "eris-lj: for-in control slot %d has no table in the "
                      "state slot below it", (int)i);
      t = tabV(st);
      w_byte(I, TAG_KEYINDEX);
      if (idx == 0) {                   /* traversal has not started */
        w_byte(I, 0);
      } else {
        uint32_t p = idx - 1;           /* position of the last key returned */
        w_byte(I, 1);
        if (p < t->asize) {
          setintV(L->top, (int32_t)p);
        } else if ((uint64_t)p - t->asize <= (uint64_t)t->hmask) {
          Node *n = &noderef(t->node)[p - t->asize];
          if (tvisnil(&n->key))
            luaL_error(L, "eris-lj: for-in traversal index names an empty "
                          "table slot");
          copyTV(L, L->top, (TValue *)&n->key);
        } else {
          luaL_error(L, "eris-lj: for-in traversal index %d out of range for "
                        "its table", (int)idx);
        }
        L->top++;
        persist(I);
        lua_pop(L, 1);
        stack = tvref(co->stack);
      }
      continue;
    }

(c) u_thread pass 1 (eris_lj.c:1246, first statement inside the mirroring loop):

    r_need(I, 1);
    if (I->in[I->pos] == TAG_KEYINDEX) {  /* for-in control slot */
      uint32_t idx;
      (void)r_byte(I);
      if (r_byte(I) == 0) {
        idx = 0;
      } else {
        TValue *st;
        unpersist(I);                     /* ... lastkey */
        stack = tvref(co->stack);
        st = stack + (i - 1);
        if (i - 1 < 1 + LJ_FR2 || !tvistab(st))
          luaL_error(L, "eris-lj: for-in control slot %d has no table in the "
                        "state slot below it", (int)i);
        idx = lj_tab_keyindex(tabV(st), L->top - 1);
        if (idx == ~0u)
          luaL_error(L, "eris-lj: the key a for-in loop was suspended on is "
                        "no longer in its table");
        lua_pop(L, 1);
      }
      stack = tvref(co->stack);
      (stack + i)->u64 = ((uint64_t)LJ_KEYINDEX << 32) | idx;
      co->top = stack + i + 1;
      continue;
    }

Notes on why this is safe: slots are written and read in ascending order, so the state table at i-1 is fully restored before the control slot is decoded; lj_tab_keyindex either returns an in-range index or ~0u, which is rejected, so no out-of-range index can reach BC_ITERN; TAG_KEYINDEX is absent from the generic unpersist() switch, so it still hits the `unknown tag` default anywhere outside a thread slot. Adjacent, cheap wins worth taking in the same change: add `ipairs`'s aux closure (obtainable as `ipairs({})`) to the host's default perms so for-in over ipairs stops failing, and add pairs/next/nested/callee-yield cases to tests/m3.lua — the suite currently has none.

If (b)/(c) are judged out of scope for M3, the strict minimum is to make the diagnosis honest, since the current text sends the operator after a perms entry that cannot exist. In persist_typed's LUA_TLIGHTUSERDATA arm:

    case LUA_TLIGHTUSERDATA: {
      const TValue *o = (const TValue *)lua_topointer(I->L, -1); /* or check at the p_thread call site */
      if (o->u32.hi == LJ_KEYINDEX)
        luaL_error(I->L, "eris-lj: thread is suspended inside a `for ... in "
                         "pairs/next` loop; the for-in traversal index is not "
                         "persistable (no perms entry can help)");
      luaL_error(I->L, "eris-lj: cannot persist light userdata by value "
                       "(process-local pointer); put it in the perms table");
      break;
    }
  (cleanest placement is the p_thread slot loop, where the raw TValue is in hand.)
EVIDENCE: REPRODUCED on the stock binary (C:/Users/astro/Downloads/OC-LuaJIT/serializer/erislj_test.exe, built from the unmodified tree).

1) Minimal repro (probe: C:/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/verify/min.lua)
   local t={a=1}
   local co=coroutine.create(function() for k,v in pairs(t) do coroutine.yield(k) end end)
   coroutine.resume(co); eris.persist(perms, co)   -- perms = flattened _G
Output:
   resume1:  true  a
   status:   suspended
   persist ok?  false
   err: eris-lj: cannot persist light userdata by value (process-local pointer); put it in the perms table

2) The refused TValue really is the ITERN control slot. C probe (mine, written for this check, mirrors prototype/framewalk): scratchpad/verify/slotdump.c dumps the live slots of the suspended thread:
   status=1 base_ofs=11 top_ofs=11
   BIG: asize=0 hmask=7 ; LJ_KEYINDEX = 0xfffe7fff
     slot  4  ...  func C ffid=4          <- FF_next_N (lj_bc.h:240 `#define FF_next_N 4`)
     slot  5  ...  table                  <- the iterated table (state)
     slot  6  raw=0xfffe7fff00000001  LIGHTUD  <== ITERN CONTROL SLOT, traversal index = 1
   control index = 1 ; key at index-1: 'k4' ; re-derived lj_tab_keyindex = 1 (want 1)
So the marker is exactly as claimed: tvislightud() true, u32.hi == LJ_KEYINDEX, u32.lo a raw array+node position. p_thread (eris_lj.c:730-736) pushes every slot in [1+LJ_FR2, top) through the generic persist(), so slot 6 lands in persist_typed()'s LUA_TLIGHTUSERDATA arm (eris_lj.c:860-863) and refuses.

3) Suggested test confirms the spread — `./erislj_test.exe scratchpad/m3lens/p9_iter.lua` -> exit 5, "P9: 5 passed, 5 FAILED":
   for k,v in pairs(t)            FAIL  light userdata
   for k,v in next, t             FAIL  light userdata
   for i,v in ipairs(t)           FAIL  (different cause: C function by value)
   numeric for                    ok
   pairs() but yield in a CALLEE   FAIL  light userdata
   nested pairs()                 FAIL  light userdata

4) The perms escape hatch genuinely does not exist for this case. `pairs` and `next` are already in the flattened-_G perms table in every failing run above, and it changes nothing — the blocker is the lightud, and Lua has no way to construct or name a lightuserdata value, let alone one per traversal index. Contrast, measured: the adjacent `ipairs` failure IS host-fixable, because the aux function is reachable from Lua — `add(ipairs({}), "ipairs_aux")` makes the same coroutine persist (blob 457) and resume to the correct total 3 (scratchpad/vkey/ipairs_perm.lua). So the error text is actively misleading only for pairs/next, which is the common case.

5) Not a documented limitation: docs/research/m3-frame-codec.md:79 and :325 already whitelist BC_ITERN as a legitimate FRAME_LUA return opcode, i.e. the frame codec expects threads suspended under for-in; nothing in the docs or serializer/README.md carves the control slot out. tests/m3.lua has no pairs()-in-a-coroutine case at all — its only loop-under-yield test is a numeric `for i = 1, 5` (line 60), which is why 33/33 passes.

FIX VALIDATED: I applied the fix below to a scratchpad copy (scratchpad/vkey/eris_lj.c) and built scratchpad/vkey/vkey.exe. Results: tests/m1.lua 82/82, tests/m2.lua 55/55, tests/m3.lua 33/33 still pass; the minimal repro now yields a 293-byte blob; scratchpad/vkey/sem.lua (8 checks) passes, including "resumed loop over the REBUILT table sums 1..20 exactly once" and "nested pairs(): resumes to 64 iterations".

ONE RESIDUAL SEMANTIC, measured, that the claim does not mention and the fix cannot remove: re-deriving the index from the last key restores `next(t,k)` semantics, not "visit each key exactly once", because the rebuilt table has a different node layout. scratchpad/vkey/order.lua: original order `k3,k4,k5,k6,2,1,k1,k2`; after roundtrip `1,2,k3,k4,k5,k6,k1,k2`. scratchpad/vkey/seq.lua then shows the restored loop visiting `k3 k4 k5 k6 k1 k2` = 6 of 8 (keys 1 and 2 skipped, since they moved ahead of the resume point). This is exactly the behaviour PUC-Lua + upstream Eris have (there the for-in control var IS the key), so it is the right target semantics, but it must be documented. It is exact whenever the iterated table is a perms entry — verified in scratchpad/vkey/permtab.lua: visited order identical to the reference, all 8 keys.

Two corrections to the report's fix direction: the iterated table sits ONE slot below the control slot, not two (BC_ITERN's base layout is [func][state][ctrl]; func is two below — vm_x64.dasc:4371-4373 reads [RA*8-24]/[RA*8-16]/[RA*8-8]). Consequently no frame context is needed and the fix fits in the generic slot loop, contrary to "it belongs in the frame codec".

### [medium] not-a-bug : `ipairs`'s aux C function is not reachable for a perms table, so ipairs loops fail too
FIX: No change to eris_lj.c is warranted. The actionable item is host-side, and it is not "know the `(ipairs({}))` trick" — it is one extra branch in the perms flattener, which generalises to every NOREGUV builtin without naming any of them. In OC's own builder (PersistenceAPI.scala `flattenAndStore`, which today recurses only when `lua.isTable(-1)`), and in tests/m3.lua's `build_perms`, add the upvalue arm:

  local function add(v, name) if perms[v] == nil then perms[v] = name; uperms[name] = v end end
  local function walk(v, name, depth)
    local t = type(v)
    if (t ~= "function" and t ~= "table") or seen[v] then return end
    seen[v] = true; add(v, name)
    if depth > 4 then return end
    if t == "table" then
      for k, v2 in pairs(v) do walk(v2, name .. "." .. tostring(k), depth + 1) end
    else                                   -- NEW: C and Lua functions alike
      local j = 1
      while true do
        local nm, uv = debug.getupvalue(v, j); if not nm then break end
        walk(uv, name .. "!uv" .. j, depth + 1); j = j + 1
      end
    end
  end
  walk(_G, "_G", 0)

Verified above: this alone makes the ipairs coroutine persist, restore and resume to the right answer. Keep the existing deterministic key ordering when walking tables; upvalue indices are already deterministic.

Two optional serializer-side improvements, both diagnosability rather than correctness:
1. eris_lj.c:865-868 names no function. Including the identity in the message ("cannot persist C function <function: builtin#6> by value") turns an unactionable error into a lookup. Cheap: pass the result of the same formatter `tostring` uses.
2. Worth documenting in serializer/README.md next to the perms contract: perms must be built by walking upvalues as well as table fields, and per-call C closures (gmatch, coroutine.wrap) are out of reach of perms entirely.
EVIDENCE: REPRODUCED the symptom, REFUTED the premise and the conclusion.

1) The symptom is real. Suggested probe, unmodified:

  $ ./erislj_test.exe .../m3lens/p10_ipairs.lua
    ipairs aux type: function  in base perms? false
    ok  : ipairs loop round-trips once ipairs_aux is a permanent
    ok  : and the loop completes correctly
    ok  : pairs() is still refused: the control slot, not the function
  P10 (ipairs workaround): ALL 3 CHECKS PASS

So a suspended coroutine parked inside `for i,v in ipairs(t)` is refused by a perms table built by the prelude's table-only _G flatten, and adding the aux fixes it. That much stands.

2) The premise — "that function is not a field of any library table, so the _G-flattening every host does never finds it" / "It IS obtainable, just not obviously" — is false. LuaJIT marks it (prototype/watchdog/luajit/src/lib_base.c:113):

    LJLIB_NOREGUV LJLIB_ASM(ipairs_aux)   LJLIB_REC(.)
    LJLIB_PUSH(lastcl)
    LJLIB_ASM(ipairs)                     LJLIB_REC(xpairs 1)

NOREGUV means "not registered as a name, but pushed as an upvalue of the next function defined". The aux is literally upvalue 1 of `ipairs`, retrievable with the standard debug API. My probe .../scratchpad/v_ipairs/r1.lua:

    A. via (ipairs({}))               : function: builtin#6
    B. via debug.getupvalue(ipairs,1) : name=  val=function: builtin#6
      ok  : debug.getupvalue(ipairs,1) IS the aux function
      ok  : aux is a single stable object per state
    C. upvalue 1 of pairs             : function: builtin#4  (== next? true)
      ok  : upvalue-walking perms builder finds the aux
    D. name assigned                  : _G.ipairs!uv1
      ok  : ipairs coroutine round-trips with the generic upvalue-walking perms
      ok  : resumed loop yields the right sum
    R1: ALL 5 CHECKS PASS

The `(ipairs({}))` trick is unnecessary, and no hardcoded knowledge of ipairs is needed: a flattener that recurses into C-function upvalues as well as table fields picks the aux up on its own (as "_G.ipairs!uv1"), deterministically on both sides (upvalue order is index order), and the coroutine round-trips and resumes correctly. The same walk also reaches `pairs`' hidden upvalue (which happens to be `next`, already a global).

3) eris_lj.c is correct. The refusal at eris_lj.c:865-868 ("cannot persist a C function by value; put it in the perms table") is the documented Eris perms contract and is identical to upstream Eris's behaviour for a C function absent from perms; the value genuinely is a process-local pointer with no by-value encoding. Nothing in the M3 thread codec is implicated — the aux simply occupies a stack slot like any other value, and the generic value path handles it correctly once it is a permanent. There is no serializer defect to fix; the reporter's own DETAIL concedes this ("documentation/host-integration gap rather than a serializer defect").

4) The generalisation in the report — "The same applies to any other library function that returns a hidden C closure" — is wrong in a way that matters, and conflates two very different situations. Probe .../scratchpad/v_ipairs/r2.lua:

    ipairs aux         : function: builtin#6  / function: builtin#6   same=true
    gmatch aux         : function: builtin#87 / function: builtin#87  same=false
    coroutine.wrap aux : function: builtin#37 / function: builtin#37  same=false
      ok  : ipairs aux is ONE stable object -> perms can name it
      ok  : gmatch aux is a FRESH closure per call -> perms cannot name it
      gmatch loop persist: false  -- eris-lj: cannot persist a C function by value...
      ok  : gmatch loop in a suspended coroutine is refused
      with a gmatch aux in perms: false  -- eris-lj: cannot persist a C function by value...
      ok  : and naming one gmatch aux does not help another
    R2: ALL 4 CHECKS PASS

`ipairs_aux` (LJLIB_NOREGUV) is one immortal object per state, so perms works. `string_gmatch_aux` and `coroutine_wrap_aux` (LJLIB_NOREG, lib_string.c:527 / lib_base.c:643) are fresh C closures carrying per-call state, minted on every call — "add it to perms" cannot work for them even in principle. `for w in s:gmatch(...) do coroutine.yield(w) end` is therefore a genuine unhandled shape, and it is a different claim from this one (it would need per-call C closures encoded by ffid + upvalues on the pinned build, not a perms entry).

### [medium] real-bug : A thread that died by error can never be persisted, and poisons any graph that merely mentions it
FIX: Minimal fix, all in C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c. Persist an error-dead thread the way a return-dead one already is — status byte plus an empty span — instead of guessing from base/top. (Backup of the tested patched file, for reference: scratchpad/vfy_errdead/eris_lj.c.FIXED; the working tree is left unmodified.)

1) check_persistable_thread (eris_lj.c:707-710) — delete the refusal outright:

```c
-  if (co->status > LUA_YIELD && !(co->base == co->top))
-    luaL_error(L, "eris-lj: cannot persist a thread with a pending error "
-                  "status and a live stack");
```

2) p_thread — add `int dead;` to the locals, then:

```c
  /* A thread that died by ERROR is not resumable -- ffh_resume and
   * coroutine.status both dispatch on `status > LUA_YIELD` alone -- and the
   * unwinder leaves its stack untidied: base/top straddle stale frame words
   * and the error value. None of that is state, so it is persisted the way a
   * return-dead thread already is: an empty slot span, no frames, no open
   * upvalues. */
  dead = (co->status > LUA_YIELD);

  stack = tvref(co->stack);
  bot = stack + LJ_FR2;
  base_ofs = dead ? 1 + LJ_FR2 : co->base - stack;
  top_ofs  = dead ? 1 + LJ_FR2 : co->top  - stack;

  w_byte(I, TAG_THREAD);
  w_byte(I, (unsigned char)co->status);
  /* A dead thread has no slots, and its stacksize may be anything the
   * unwinder left behind -- a stack-overflow death leaves LUAI_MAXSTACK+ --
   * so it asks for the minimum instead. */
  w_uleb(I, (uint64_t)(dead ? 2 + LJ_FR2
                            : co->stacksize - 1 - LJ_STACK_EXTRA));
```

(the `2 + LJ_FR2` clamp is load-bearing: without it a stack-overflow-dead thread writes need=65541 and u_thread rejects it with "thread stack size 65541 out of range".)

3) Both frame walks must start from the derived base, not the live one, or they still find the stale frames:

```c
-  for (f = co->base - 1; f > bot; f = frame_islua(f) ? frame_prevl(f)
+  for (f = stack + base_ofs - 1; f > bot; f = frame_islua(f) ? frame_prevl(f)
                                                     : frame_prevd(f))
     nframes++;
...
-  for (f = co->base - 1; f > bot; ) {
+  for (f = stack + base_ofs - 1; f > bot; ) {
```

4) Open-upvalue block — emit none for a dead thread:

```c
     uint32_t nuv = 0;
-    for (o = gcref(co->openupval); o; o = gcref(o->uv.nextgc)) nuv++;
+    if (!dead)
+      for (o = gcref(co->openupval); o; o = gcref(o->uv.nextgc)) nuv++;
     w_uleb(I, (uint64_t)nuv);
-    for (o = gcref(co->openupval); o; o = gcref(o->uv.nextgc)) {
+    for (o = nuv ? gcref(co->openupval) : NULL; o; o = gcref(o->uv.nextgc)) {
```

5) p_function's open-upvalue owner selection (just before `if (owner != NULL) { w_byte(I, TAG_UPVALOPEN); ... }`) — required by finding 4 above:

```c
  /* An error-dead thread keeps its open upvalues (the unwinder does not
   * close them), but it can never run again, so nothing can ever write that
   * slot: the alias has no observable content beyond the value, and the
   * thread is persisted with an empty span anyway. Fall back to the by-value
   * form, which M2's UPVALREF still keeps shared. */
  if (owner != NULL && owner->status > LUA_YIELD)
    owner = NULL;
```

This is unobservable: a dead thread can never execute again, so nothing can ever write that stack slot, and closure-to-closure sharing is still preserved by M2's TAG_UPVALREF (verified by the get/set test above).

No change is needed on the restore side — u_thread already accepts `base_ofs == top_ofs == 1 + LJ_FR2` with `nframes == 0`, and both `ffh_resume` (lib_base.c:620) and `coroutine_status` (lib_base.c:576) classify the restored thread from `status > LUA_YIELD` alone, so it comes back "dead" and refuses to resume.

Two follow-ups for whoever lands this: invert p8_misc.lua's two refusal assertions, and consider adding a tests/m3.lua case for the error-dead round trip — the suite currently has none, which is how this slipped through.
EVIDENCE: REPRODUCED, and the defect is worse than claimed: the `base == top` escape hatch does not merely refuse some error-dead threads, it also lets others through SAVE and then fails at LOAD.

## 1. The claimed refusal (C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c:707-710)

Minimal probe (scratchpad/vfy_errdead/repro.lua), run against the unmodified build:

```
=== A. dead by RETURN ===
  resume: true  1        status: dead
dead-by-return, direct                      -> OK (84 bytes)
dead-by-return, inside a table              -> OK (118 bytes)

=== B. dead by ERROR ===
  resume: false  ...repro.lua:34: kaboom    status: dead
error-dead, direct                          -> REFUSED: eris-lj: cannot persist a thread with a pending error status and a live stack
error-dead, inside a table                  -> REFUSED: eris-lj: cannot persist a thread with a pending error status and a live stack

=== E. OC-shaped: OpenOS-style process table ===
  good status: suspended   bad status: dead
whole world { processes = ... }             -> REFUSED: eris-lj: cannot persist a thread with a pending error status and a live stack
same world with the crashed one removed     -> OK (371 bytes)
```

The suggested test agrees: `./erislj_test.exe .../m3lens/p5_life.lua` -> `P5 (lifecycle): 23 passed, 1 FAILED  * an error-dead thread re-persists`.

## 2. Root cause, established at C level

C probe (scratchpad/vfy_errdead/inspect.c, linked against ../prototype/watchdog/libluajit_stock.a) dumping `co` after each kind of death:

```
--- return        status=0 base_ofs=2 top_ofs=2 base==top? YES  frames above bottom: 0
--- error_string  status=2 base_ofs=6 top_ofs=7 base==top? NO   frames above bottom: 2
--- error_table   status=2 base_ofs=6 top_ofs=6 base==top? YES  frames above bottom: 2
--- error_nilidx  status=2 base_ofs=4 top_ofs=7 base==top? NO   frames above bottom: 1
--- error_nil     status=2 base_ofs=6 top_ofs=6 base==top? YES  frames above bottom: 2
```

LuaJIT does NOT unwind a coroutine's own stack when it dies by error (`unwindstack`/`lj_func_closeuv` is not reached on that path): `cframe` is NULL, `status` is LUA_ERRRUN, and `base`/`top` are left straddling stale frame words. Whether `base == top` is pure accident of what the error value was — a *string* error leaves the formatted message above the raw one (base != top), a *table* or *nil* error leaves exactly one slot (base == top).

## 3. The escape hatch produces unloadable blobs

scratchpad/vfy_errdead/repro2.lua, unmodified build:

```
error(string)   persist  : REFUSED -- ...pending error status and a live stack
error(table)    persist  : OK, 330 bytes
                unpersist: FAILED -- eris-lj: non-suspended thread must have no frames   <<< saved but cannot load
error(nil)      persist  : OK, 315 bytes
                unpersist: FAILED -- eris-lj: non-suspended thread must have no frames   <<< saved but cannot load
nil-index       persist  : REFUSED -- ...pending error status and a live stack
```

`base == top` says nothing about frames: p_thread still walks 2 stale frames from `co->base - 1`, writes `nframes = 2`, and u_thread (eris_lj.c:1258-1263) rejects any non-LUA_YIELD thread with frames. So the guard's own premise is wrong, and the "loud save-time failure" it was defending is exactly what it fails to provide in those cases. The 330-byte blob also contains raw heap addresses (the stale FRAME words read as denormal doubles).

## 4. One more fact the fix has to respect

scratchpad/vfy_errdead/inspect2.c: an error-dead thread still holds OPEN upvalues.

```
  [suspended, upvalue open] status=1 base_ofs=8 top_ofs=8 open_upvalues=1
  after error resume: false  ...boom-with-live-upvalue
  getter() after the error = 99
  [after the error]         status=2 base_ofs=8 top_ofs=9 open_upvalues=1
```

So "empty slot span" alone breaks the (thread, slot) form in p_function: the slot would sit above the new `top_ofs` and u_thread:1123 would raise "open upvalue slot outside the thread's live stack" at load.

## 5. Fix verified

With the patch below applied and rebuilt: tests/m1.lua 82/82, tests/m2.lua 55/55, tests/m3.lua 33/33 all still pass. p5_life goes 23p/1f -> ALL 25 CHECKS PASS. A new 24-check probe passes in full, including every error flavour (error(string)/table/nil, nil-index, arith-on-nil, stack overflow, error-after-yield) round-tripping to the same 84 bytes as a return-dead thread and coming back `dead` / "cannot resume dead coroutine"; `{ processes = { alive, crashed } }` now saves and the live sibling still resumes to 42; a get/set closure pair open into the error-dead thread round-trips, keeps the value 99, still SHARES one upvalue after restore (g.set(1234) -> g.get() == 1234), and leaves the source world untouched; blob size stable over 4 generations. A 400-thread GC stress (full collect + re-persist + `debug.getinfo`) passes.

No regressions: I ran all ten m3lens probes before and after. p1 28/0, p2 3/4, p3 29/1, p4 11/1, p6 8/1, p7 2/2, p9 5/5, p10 3/0 are byte-identical before and after (their failures belong to other, unrelated claims). Only p5 changes (23/1 -> 25/0) and p8 (16/1 -> 14/3), whose two newly-failing checks are the assertions that literally encode the buggy behaviour ("PERSIST is refused (save-time, not load-time)" and "a table merely holding it cannot be saved either") and must be inverted along with the fix.

