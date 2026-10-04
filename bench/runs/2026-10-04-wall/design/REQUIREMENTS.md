# The collector at the wall: requirements for a design (2026-10-04)

Read first, in this directory: u-shim-collector.md, u-luajit-gc.md, u-puc-stock.md, u-tests.md,
u-history.md (read-only surveys of the code as of HEAD bd302f2, with file:line citations).

## The four problems (docs/roadmap.md row "THE COLLECTOR AT THE WALL")
P1 Recovery at the wall. Our allocator refuses where PUC's luaM_realloc_ runs a non-finalizing full
   collection and retries. A program that catches "not enough memory" and drops its data has its own
   next allocation refused; or a refusal lands where no handler catches it and the machine stops.
   20 of 60 capacity runs vs 0 of 20 on stock. Second shape (new): one request larger than the headroom
   while headroom >= the watermark is refused WITHOUT arming. Third (new): at the cap even an ordinary
   trace exit can raise ERRMEM, because snapshot restore allocates sunk objects.
P2 The last quarter. After a proven cycle that leaves used > total - w (w = max(total/4, 128 KB)), the
   next allocator call re-arms, so every GC checkpoint pays a full O(heap) cycle: 20-120x stock's time.
   Stock does zero GC work between refusals and one full cycle per (cap - live) bytes.
P3 The parked collector (confirmed by reading). An arm landing in GCSsweep/GCSfinalize finishes the old
   cycle without atomic(); the white does not flip, the record stays armed with stepmul 0, and lj_gc_step
   set threshold = 2 x estimate; with live > cap/2 no checkpoint fires until the 65 536-call bailout or the
   kernel's every-tenth-resume collect. Related: the bailout counts the armed cycle's own sweep frees.
P4 The kernelMemory windfall. Kernel-init traces are counted in kernelMemory (granted on top of the
   scaled RAM by OC) and later flushed: bimodal 335-413 KB vs a trace-free 164 393 B; probably host-speed
   dependent. Today it hides P2 on small sticks: without it a 192 KB machine idles in the arm/flush loop
   (1390-2964 arms, 16-29 flushes per 10 s) and failed 1 boot in 12.

## Requirements (score every design against each; say MET / PARTLY / NOT MET and why)
R1 Observable contract like stock: "not enough memory" only when, after a full collection, the live
   data plus the request does not fit; a program that catches the error and drops its data continues.
   Shrinks never fail; frees credit immediately; raising allocates nothing.
R2 Collection work near the wall proportional to bytes allocated, not to checkpoints (stock: one full
   cycle per (cap - live) bytes). Target: our last-five-batch time within ~3x stock's in the same chain.
R3 No parked collector, no false bailouts; collects == arms and bailouts == 0 stay true at rest.
R4 kernelMemory deterministic and trace-free (or a stated reason why not), without exposing P2-type
   idle thrash on a 192 KB stick.
R5 The cap stays a bounded ceiling: any excursion past it is bounded by a compile-time or cap-relative
   constant, charged (freeMemory honest, never negative -- OC clamps at 0), and cannot be driven without
   bound by sandbox code. Host safety: no refusal in a bare JNI frame; nothing kills the JVM.
R6 Safety in the VM: respects C1-C7 (u-luajit-gc.md section 4; C7 = the collector reallocating the very
   block being grown); no collection inside the allocator; on-trace behaviour defined.
R7 Minimal and reviewable: prefer zero LuaJIT lines; every VM line needs its own justification.
   build-native.sh's collector gate (no lj_gc_step/lj_gc_fullgc/lua_gc in the shim) stays, or is
   re-scoped deliberately with its own fail-first.
R8 Persistence: nothing that must cross eris lives only in global_State; save/load (OC lifts the cap to
   Int.MaxValue around persist) still correct; GCRESTART/GCSTOP by the host handled.
R9 Throughput far from the wall unchanged (the arena, the shim-held accounting; P1a: a 64 KB burst with
   1 MB headroom must not refuse or be delayed).
R10 Testable fail-first: each of P1-P4 gets a hermetic mem_test check (no JVM) that FAILS on today's
   DLL cb29485d and passes after, plus the harness capacity matrix (bench/runs/2026-10-03-ramscale/
   scripts/) as the in-machine gate; the dropin arm runs the legacy path and needs the same fix.
R11 Compatibility with default settings is the user's stated priority: OC's ramScaleFor64Bit stays
   inherited; no new player-facing knob unless unavoidable.
