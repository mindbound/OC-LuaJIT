# 2026-10-05 -- the unwinder crash, fixed

The evidence behind [../../results-errmem-2026-10-05.md](../../results-errmem-2026-10-05.md):
`lj_err_mem` and `lj_err_err` no longer push their message below the current frame
(`native/luajit/patch-fastfunc-errmem-top.sh`, applied by `native/build-native.sh`). The root
cause and its verification are in [../2026-10-05-window/crash/](../2026-10-05-window/crash/).

The builds:

- **Before:** `libluajit.a` `4745eeb2`, additive `ae3e414b`, dropin `7fa4e8f9` (THE WINDOW as
  committed in 3186e87); the Linux additive in `dist/` was `90be1300` from 2026-10-03.
- **The first build, one clamp (`lj_err_mem`):** `libluajit.a` `a93f546e`, additive `9371db39`,
  dropin `7c3d2e14`, Linux additive `c07d27d0`. Its gates and suites are `logs/one-site/`.
- **The final build, both clamps:** `libluajit.a` `d1547f3a`, additive `d9a51b6b`, dropin
  `8635573e`, Linux additive `21156504`. The shim is unchanged (`332dc85c`).

| path | what |
|---|---|
| `patch/` | `patchcheck.sh` (one site) and `patchcheck2.sh` (both sites) with their logs: the patch script on the pristine `lj_err.c`, in place, on its own output, and the manglings it must refuse; `buildneg.sh`/`buildneg2.sh` and their logs: `build-native.sh` refuses a pinned checkout that already carries the clamp (A; A2: the investigator's `else if` form) and a patch step that exits 0 without patching (B), both before make, while the same scratch setup with the real script builds (C) and rebuilds the archive |
| `dis/` | `lj_err_mem` disassembled: unpatched, the census's fix (the investigator's `else if` form), the first build (a separate `if`) and the final build; `lj_err_err` from the final build. The non-Lua path, the one the crash takes, is the same instruction sequence in every fix |
| `census/` | the black-box A/B: `lj_repro.c` (in [../2026-10-05-window/repro/](../2026-10-05-window/repro/)) with `probe2.lua`, JIT on, batch 10, one process per cap, pinned to the efficiency cores; `build.sh` (random and fixed seed), `build2.sh` (fixed seed, no ASLR, plus a relinked unpatched control), `shipcheck.sh` (the first build's `libluajit.a`; the final build's run is `ship2-*` in `logs/`), `census.sh`/`job.sh` (one cap per process; exit 139 = access violation), `ident.sh` (joins two censuses by offset and compares whole output lines); `clamp_check.txt` (which binaries carry the clamp), `ident_nf.txt` and `ident_nf_more.txt` (every identity check the note cites), `census-counts.txt` (caps and crashes per file), `census-out.tar.gz` (every census's TSV, both shipped-archive runs included) |
| `logs/` | the final build: `build-additive.log`, `build-dropin.log`, `wsl-native.log`, `before.md5`/`after.md5`, `gates/` (Windows: mem, wd, shim, security, race, penalty, the negative control), `wslgates/` (Linux: mem, wd, penalty), `runsE2/` (the five full suites, one log per run), `ship2-*` (the shipped-archive census and its identity check); `one-site/` the same set for the first build |
| `scripts/` | `chainE.sh`, `chainE2.sh`, `wsl-gates.sh`, `gates.sh`, `archive-errmem.sh`, `archive-errmem2.sh`; they hard-code this session's scratchpad paths |

Notes.

- The census's driver links a shim object from the design round: `verdict` is the rejected
  design's object `e387460a` (where the crash was frequent), `window` is THE WINDOW's
  additive object `082ff068`. Neither object is kept; the shim source of the rejected design
  is described in [../2026-10-05-window/design/d2-verdict.md](../2026-10-05-window/design/d2-verdict.md).
- With ASLR on, the same fixed-seed binary does not repeat run to run (5-28 % of lines
  differ), so the identity checks use the no-ASLR builds (`*nf`), which repeat exactly.
- The pinned LuaJIT checkout carries an untracked `libluajit.a` from 2026-09-01; a copy of the
  tree inherits it, so `buildneg*.sh` read "make never ran" as "the build copy's archive is
  still that one"; `buildneg2.sh`'s control shows a real build's archive differs from it.
- The second clamp site (`lj_err_err`, reached inside an `xpcall` message handler) is not
  exercised by any census here.
