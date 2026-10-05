# The unwinder crash: adversarial verification (2026-10-05)

No-VEH control still segfaults 93/256 (exit 139) — the VEH is exonerated; the crash is genuine. I now have complete evidence. (Per the harness rule I don't write a report `.md`; the full finding and the ≤250-word summary are returned below as my text output.)

---

## Adversarial verification — results

**All runs pinned to E-cores (`affrun 3FC3FC`). Work dir:** `C:/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/crash-verify/`

**Cause — CONFIRMED.**
- **Faulting site, independently:** in the current `ljr_verdict_veh.exe`, `err_unwind+0x110` (VMA 0x140013050) is `movzbl -0x3(%rdx),%edx`, followed by `lea 0x10(,%rdx,8),%rdx` / `sub %rdx,%rax` — exactly `frame = f - (1+LJ_FR2+bc_a(frame_pc(f)[-1]))` (`lj_frame.h:108`, `lj_err.c:131`). The old `veh_128.txt` RVA 0x12e90 was a *stale* capture (exe rebuilt after it); `veh_try.txt` and my fresh capture both land at `+0x110`.
- **Fresh capture from my own binary built from pristine pinned `lj_err.c`:** `L->top==L->base`, frame slot `rax==base-8==top-1`, `*frame==0xfffd81f7ba3e3470` (itype `>>47 == 0x1fffb` = LJ_TSTR box). The boxed GCstr is read whole as a PC → `rdx-3` non-canonical → `#GP` (reported target `0xffff…`).
- **Source asymmetry confirmed:** `ff_tostring` number path sets `L:RB->base` only then `call lj_strfmt_num` (`vm_x64.dasc:1385/1392-1394`); `fff_fallback` (`:2195-2198`) and `fff_gcstep` (`:2248-2251`) set both base and top. `lj_err_mem` skips its top-refresh when `curr_funcisL` is false and pushes at the stale top (`lj_err.c:823-831`) — `ctrl.o` disassembly falls straight to the push with no clamp.
- **JIT required:** my census JIT-off **0/256** vs JIT-on **83/256**.
- **Not a harness artifact:** no-VEH binary (pristine `lj_err`, no `veh.o`) still segfaults **93/256, exit 139**.
- **Shim-placement explains the design spread:** identical `libluajit.a`; verdict shim crashes (my census 63–83/256; report 442/1024 = same order), final shim **0/1024** (report 0/18432). The LuaJIT bug is latent; the final shim merely never refuses at that allocation.

**Fix — CONFIRMED (removes crash; passes shim tests); one scope note.**
- Patch script yields *exactly* the `else if (LJ_UNLIKELY(L->top < L->base)) L->top = L->base;` clamp (diff verified; `fix.o` emits `cmp %rdx,0x28(%rbx)/jb`).
- Census: my-ctrl 83/256 → **my-fix 0/256**; shipped ctrl 63/256 → fix 0/256; patch-produced object 0/128. Formerly-crashing off=32 → clean `status=0 term=1`.
- `mem_test` with the patched `lj_err` overriding the archive (clamp confirmed present in the linked binary; absent in baseline): **76/76 pass**, incl. M5 catchable `LUA_ERRMEM`, M6 coupling, M7 charged. No shim regression.
- **Scope note (not a refutation):** the report named only `ff_tostring`, but the *same class* exists at `fff_newstr` (`string.char`, `vm_x64.dasc:1969/1974` `lj_str_new`) and `ffstring_op` (`string.reverse/lower/upper`, `:2055/2063-2065`). The `lj_err_mem` clamp is generic, so it covers them all — which is a point *for* this fix over a per-site `.dasc` edit.
- **Not reproducible:** the specific "stage-C 1/4096 at off 9488" — current binaries give 0/64 and 0/512. The report already discloses this ("0/40 now").

---

**SUMMARY (≤250 words)**

CAUSE: CONFIRMED. I reproduced the exit-139 segfault from a control I built myself out of the pristine pinned `lj_err.c` (83/256 caps; no-VEH build 93/256, exit 139 — so the VEH is not the cause). A fresh in-process capture shows the fault at `err_unwind+0x110` = `movzbl -0x3(%rdx),%edx`, the `frame_prevl` byte read (`lj_frame.h:108`, `lj_err.c:131`), with `L->top==L->base`, the frame slot `base-1==top-1` holding the NaN-boxed ERRMEM string (itype 0x1fffb). Source confirms `ff_tostring` sets only `L:RB->base` before `lj_strfmt_num` (`vm_x64.dasc:1385-1394`) while `fff_fallback`/`fff_gcstep` set top too; `lj_err_mem` skips its top-refresh for a fast function and pushes at the stale sub-base top (`lj_err.c:823-831`). JIT-on required (0/256 vs 83/256). Rates: verdict frequent and final 0/1024 both reproduce under one identical `libluajit.a`, proving a latent LuaJIT bug the shim only places; the "1/4096 stage-C" figure does NOT reproduce now (0/512), but the report discloses this.

FIX: CONFIRMED. The patch produces exactly the `L->top<L->base` clamp; census my-ctrl 83/256→0/256, shipped 63→0, patch object 0/128; a formerly-crashing offset completes `status=0`. `mem_test` with the patched `lj_err` linked (clamp verified in-binary) passes 76/76 including the LUA_ERRMEM refusal path — no shim regression.

CAVEAT: not only `ff_tostring` — `string.char`/`reverse`/`lower`/`upper` are same-class siblings; the generic `lj_err_mem` clamp covers them, so the fix is complete and preferable to a per-site edit.