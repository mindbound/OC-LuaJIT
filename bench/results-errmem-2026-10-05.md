# A refused allocation in a fast function no longer crashes the process (2026-10-05)

**`lj_err_mem` now never pushes its "not enough memory" message below the current frame.
Before, a refusal inside `tostring` of a number, or `string.char`, `sub`, `reverse`, `lower`
or `upper`, running interpreted, could overwrite the frame link, and LuaJIT's own unwinder
then crashed the process -- in a game, the whole JVM.** The fix is a two-line clamp, at
two places in `lj_err.c` (`native/luajit/patch-fastfunc-errmem-top.sh`). `build-native.sh`
applies it to a pristine copy of the file on every build and platform, the way it applies
the penalty scrub to `lj_func.c`; the pinned checkout stays untouched.

- **The evidence is a census, not a unit test.** On the same driver and shim:
  - unpatched, 1 653 crashes in 4 608 caps;
  - patched, 0 in 4 096.

  On every cap that did not crash, the output was identical with and without the fix (4 809
  caps across three builds, 1 746 more across two), and every cap that crashed unpatched
  ends cleanly patched. The second clamp site, inside an error handler, is not covered by
  the census.
- **The shipped bytes behave like the measured fix:** 0 crashes and 2 048 of 2 048 output
  lines identical.
- **Gates and suites:**
  - Windows: every native gate passes, the negative control 35 of 35;
  - Linux: mem, wd and penalty pass;
  - the five full harness suites pass.
- **The Linux native in `dist/` was from 2026-10-03** (`90be1300`, built before stage A) and
  so carried none of the collector at the wall (stages A-C, THE WINDOW). It is rebuilt here;
  the 81-check mem_test ran on Linux for the first time (it last ran there at 49 checks,
  2026-10-03) and passed.

Archive: [runs/2026-10-05-errmem/](runs/2026-10-05-errmem/). The root cause and its
adversarial verification are in [runs/2026-10-05-window/crash/](runs/2026-10-05-window/crash/),
and the defect's first write-up is the last section of
[results-wall-window-2026-10-05.md](results-wall-window-2026-10-05.md).

## What was wrong

When the allocator refuses, `lj_err_mem` (`lj_err.c:813`) pushes the message at `L->top` and
throws. It refreshes `L->top` from the frame first only when the running function is a Lua
function (`curr_funcisL`, `:823-830`); a C function keeps `L->top` itself. A fast function is
neither:

- **`tostring` of a number** stores `L->base` and not `L->top` before it calls
  `lj_strfmt_num` (`vm_x64.dasc:1370-1394`, "Add frame since C call can throw" at `:1385`).
- **`string.char` and `string.sub`** do the same before `lj_str_new` (`->fff_newstr`,
  `:1967-1974`).
- **`string.reverse`, `lower` and `upper`** do the same before `lj_buf_putstr_*`
  (`ffstring_op`, `:2043-2066`).
- **The other paths store both:** the fallback and GC-step paths (`:2190`, `:2242`).

So when that call's allocation is refused, `L->top` is wherever the last C call left it, and
on some trajectories that is below the fast function's frame; on the crashing trajectory it
is exactly `L->base - 1`. The push then writes a string over the frame link there, and
`err_unwind` (`lj_err.c:109`) reads it as a Lua frame's saved PC and dereferences it
(`frame_prevl`, `lj_frame.h:108`). The process dies inside LuaJIT.

**Inside an `xpcall` message handler there is no refresh at all.** `L->status` is
`LUA_ERRERR` for the whole run of a handler (`lj_err.c:900`), and there `lj_err_mem` hands
straight to `lj_err_err` (`:815-816`), which pushes its own message at `L->top` (`:806-810`),
for a Lua function too. A handler that formats the error is exactly what runs right after a
refusal. The code review of this change found that site; it is clamped the same way, and
it is not covered by the census below.

Who could reach it: any sandbox program near its RAM cap with the JIT on (0 crashes with it
off, 83 of 256 with it on, on the rejected design's shim). How often depends on the binary's
layout:

- **Hermetically** (no JVM), stage C's shim (shipped until 3186e87) hit it a few times in the design
  round's sweeps (once in 4 096 caps in the final census) and not under verification on
  later binaries; THE WINDOW in 0 of 18 432 caps there and 0 in this census (it refuses
  elsewhere); one of the design round's rejected designs in 17-43 % of caps.
- **In the machine** it was never observed: no in-machine chain of the collector-at-the-wall
  work logged a process death.
- **On Linux** the patch applies the same way. The crash itself was only ever seen on
  Windows.

## The fix

Right before the push, if `L->top < L->base`, set `L->top = L->base`. `err_unwind` walks frames
at `L->base - 1` and below, so the message is out of its way, and the error object still
reaches the handler. It does nothing for Lua functions (the refresh leaves `L->top` at or
above `L->base`) or for C functions (their top is never below their base). It is generic, so
it covers every fast function with this pattern, including any not listed above.

**It is shaped like the penalty scrub**:

- **The patch script** (`native/luajit/patch-fastfunc-errmem-top.sh`) anchors on the whole
  four-line body of `lj_err_err` and on `lj_err_mem`'s last three statements: the brace
  closing the `curr_funcisL` block, the push and the throw. Each group must be consecutive
  and occur exactly once. It inserts 4 lines before the first push and 11 before the second
  (a comment and the clamp each) and checks its output by content: the marker and the clamp
  twice, each push once, in order, 15 lines added and none removed. It refuses otherwise.
- **`build-native.sh`**:
  - refuses a pinned checkout that already carries the clamp;
  - re-copies the pristine `lj_err.c` over the build copy;
  - asserts the clamp is absent (in any form), patches, and asserts it present exactly
    twice before make;
  - after make, checks that `lj_err.o` is newer than the patched source and that its
    compile line is in the log.

The investigator's fix was an `else if` on the `curr_funcisL` block, which replaces a line.
The shipped one is a separate `if`, which only inserts, so the house checks apply unchanged.
The two are equivalent: on the non-Lua path, the one the crash takes, both compile to the same
`cmp %rdx,0x28(%rbx); jb` and store. The shipped form also compares once more on the Lua path,
where the comparison can never be true. In `lj_err_err` the clamp is the first thing the
function does (`cmp %rax,0x28(%rcx); jb`). Both are in `dis/` in the archive.

## Measured

**The census** (black-box): `lj_repro.c` with the capacity probe's program (`probe2.lua`),
JIT on, batch 10, the string shape (the record and closure shapes in one row), one process
per cap, pinned to the efficiency cores. The
shim is the rejected verdict design's, where the crash was frequent, or THE WINDOW's. Exit
139 is the access violation.

| shim | seed | unpatched | patched |
|---|---|---|---|
| verdict | random | 1 653 / 4 608 (737, 178, 738) | 0 / 4 096 |
| verdict | fixed | 333 / 2 048 (again: 337) | 0 / 2 048 |
| verdict | fixed, no ASLR, seeds 1 / 2 / 3 | 311 / 2 048, 110 / 1 024, 192 / 1 024 | 0 in each |
| verdict | record and closure shapes | 0 / 512 each | 0 / 512 each |
| THE WINDOW | random, fixed, no ASLR | 0 / 2 048 each | 0 / 2 048 each |

No run in the census exited any other way. The record and closure shapes, and THE WINDOW,
never crash unpatched either, so those rows show only that the fix changes nothing there.

**The identity check.** The same fixed-seed binary does not repeat run to run with ASLR on, so
the check uses no-ASLR builds, which repeat exactly. It compared, cap by cap, the unpatched
build, the same unpatched `lj_err.c` relinked where the fix goes, and the fix:

- every cap that did not crash produced the same whole output line in all three for 4 809
  caps (seed 1: the verdict shim's three shapes and THE WINDOW), and unpatched against
  patched for 1 746 more (seeds 2 and 3, which have no relinked control);
- no cap crashed only when patched;
- each of the 613 caps that crashed unpatched ends patched with `status=0 term=1`: the
  batch's own `pcall` caught the refusal, which is where it belonged;
- the comparison can fail: the verdict shim against THE WINDOW's matched 0 of 1 737 lines;
  seed 1 against seed 2 matched 2 of 512 on THE WINDOW and 2 of 391 on the verdict shim.

**The shipped bytes.** The census's patched side used the investigator's `else if`. Relinked on
the shipped `libluajit.a`, the verdict string census at seed 1 without ASLR crashed 0 times in
2 048 caps (311 unpatched) and matched the measured fix on all 2 048 lines -- twice: on the
first build, which clamped `lj_err_mem` only (`a93f546e`), and on the final one, which clamps
both sites (`d1547f3a`).

**No unit test.** For one binary, seed and ASLR setting the crash repeats exactly (two runs
of 512 caps crashed on the same 84), but which caps crash moves with the seed and with ASLR,
so a reproducer would be tied to one binary; none has been written, and `test/native` has
none for it. The build's content and recompile assertions are what stop the fix from
silently dropping out.

**The patch step can fail.** The patch script was run against the pristine file, in place, on
its own output (left unchanged), and against nine manglings, each of which it must refuse:

- the clamps' assignments altered;
- the `lj_err_mem` push not under the brace;
- a duplicated `lj_err_mem` anchor;
- either throw replaced (two cases);
- the `lj_err_err` push not its first statement;
- a patched file with the `lj_err_err` clamp removed;
- the `lj_err_mem` clamp moved after its push;
- the investigator's `else if` output (same marker, other text).

All refused, and no partial output was left. `build-native.sh` was run on scratch copies:

- a checkout that already carries the clamp, in this form or the investigator's: refused
  before make;
- a patch step that exits 0 without patching: refused before make;
- the same setup with the real script: builds, and its archive differs from the stale one
  the checkout carries, so the "make never ran" comparison can tell them apart.

**The gates**, on the final natives (additive `d9a51b6b`, dropin `8635573e`; the shim unchanged
at `332dc85c`), and before them on the first build (`9371db39` / `7c3d2e14`), with the same
results:

- **Windows:** mem 81/0, wd 35/0, shim PASS, security PASS, race 2/0, penalty 6/0, the
  negative control 35/35.
- **Linux** (WSL, additive `21156504`; the first build `c07d27d0`): mem 81/0, wd 35/0,
  penalty 6/0.
- **The full harness suites**, pinned to the performance cores, 5 of 5 on each build:
  - additive JIT on 66/0;
  - the dropin 63/0;
  - JIT off 64/0;
  - sieve 60/0;
  - stock 47/0.

## What is left

- **The handler site is unmeasured.** The clamp in `lj_err_err` rests on the code reading
  above; no census exercises a refusal inside an `xpcall` message handler.
- **Upstream.** The defect is LuaJIT's, and the clamp is generic. It belongs in the
  upstream-reports row, with the census as its evidence; a reproducer that does not need our
  shim has not been written.
- **The other VMs.** Only `vm_x64.dasc` was read. `lj_err_mem` is shared, so the clamp also
  protects the other architectures' fast functions if they have the same pattern, but we
  build and test only x86-64.
