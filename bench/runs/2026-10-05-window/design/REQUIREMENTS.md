# The refusal outside the handler: requirements for a design (round 2, 2026-10-04)

Read first, in this directory: u2-shim-now.md, u2-checkpoints.md, u2-stalls.md, u2-priors.md,
u2-repro.md (surveys of HEAD d9080d4, which carries stages A-C of the collector at the wall).
The previous round's requirements (bench/runs/2026-10-04-wall/design/REQUIREMENTS.md, R1-R11)
still bind; they are restated here where this row sharpens them.

## The problem (docs/roadmap.md, "A refusal at a credit tier's top can land outside the
## program's handler")

P5. We refuse when LIVE DATA PLUS THE GARBAGE SINCE THE LAST PROVEN CYCLE crosses a tier's top
(total + G/2, or total + G after a refusal, + 16 KB for the kernel). Stock PUC refuses only when,
after the full collection it runs at the refusal, live data plus the request does not fit. The
garbage term makes our refusals (a) earlier than stock's, at points where stock would collect
and carry on, and (b) spread over every allocation site in proportion to the bytes it allocates,
so some land in code with no handler: the capacity probe's own step between batches (a
"stall": machine up, timer chain broken), or OpenOS/kernel code (the dropin went down once).
Measured: stage B 3 stalls + 1 dropin down in 68 of our runs; stage C 1 stall in 49; stock 0 of
40.

## Requirements (score every design against each: MET / PARTLY / NOT MET, and why)

R1  Observable contract like stock: "not enough memory" only when, after a full collection, the
    live data plus the request does not fit under the tier top. A crossing that garbage covers
    is not refused. Where a refusal does happen, it happens at an allocation no earlier in
    program order than stock's would (or the design states by how much, and why that is
    bounded and harmless).
R1b Stage B's recovery stays: a program that catches the refusal, formats a message and drops
    its data carries on (mem_test W2b/W2c and the "catch, format, drop" cases); the kernel
    never dies on the sandbox's refusal (the kernel slice, X9-style).
R5  The cap stays a bounded ceiling: every excursion past it is bounded by a cap-relative or
    compile-time constant (today: used <= total + G + KSLICE outside the norefuse window),
    charged (getFreeMemory reads 0, never negative), and caught refusals cannot ratchet it
    (W7). State the new bound as an inequality.
R6  VM safety: C1-C7 respected (no collection inside the allocator; L->top stale; objects
    partially built). On-trace behaviour and the host GCSTOP / HOOK_GC states defined.
R7  Minimal and reviewable: zero LuaJIT lines preferred; each VM line needs its own
    justification; build-native.sh's collector gate stays.
R8  Persistence and host states: nothing that must cross eris lives only in global_State;
    OC's Int.MaxValue cap around persist; GCSTOP/GCRESTART; a state eris loaded over its cap
    (the fresh-record rule).
R9  Throughput and collection cost unchanged far from the wall, and near it within stage C's
    figures (THE CADENCE: log2 cycles per tier, ~2 cycles per (cap - live) bytes below the
    cap); no new thrash at idle on a 192 KB stick (stage C: ~20 arms, 0 flushes per 10 s).
R10 Testable fail-first: a hermetic mem_test case reproducing "refused although a collection
    would have made room" that FAILS on the stage-C object (scratchpad wall2/objC, md5
    0259f0d1) and passes after; every existing W/P/C/M case passes or is re-scoped with a
    stated reason; negative-control sabotages that make the new case fail; and an in-machine
    gate: the capacity matrix, plus an amplified probe that makes out-of-handler exposure
    frequent so a stall-rate difference is measurable against stock.
R11 Defaults: OC's ramScaleFor64Bit inherited; no player-facing knob.
R12 Capacity and near-wall time no worse than stage C's (capacity at least stock's in every
    cell; last-five-batches time within stage C's ratios), measured.

## What to produce

A design document: the rule (when a crossing is granted, when refused, how tiers/windows
open and close), the exact code change (functions, fields, lines), the bound (R5) with its
derivation, every state transition including on-trace, GCSTOP, HOOK_GC, norefuse, csync and
legacy mode, the kernel slice, the fresh-record rule, the flush predicate and THE CADENCE's
interplay; the residual (what it still does not fix), stated in one sentence; the tests
(new hermetic cases with expected numbers on the old and new object; which existing cases
change and why; sabotages); and the in-machine gate.
