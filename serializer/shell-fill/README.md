# shell-fill prototype artifacts

Spec: docs/shell-fill.md. Rationale: docs/research/persistence-clean-slate.md.

- eris_lj_SHELL.diff  verified prototype vs eris_lj.c (94 lines); SHELL.exe md5 83763275
- mkshell.py          anchored patcher that produces it (apply to a COPY of eris_lj.c)
- shell.lua           the failing-first test (= tests/shell.lua); shell_stress.lua its companion
- rig.lua             D4 rig: RIG_MODE=orig reproduces the in-game error; to become tests/userdata.lua
- walker/             D3 reachability walker (once_drain.inc) for the step-4 graft, with the
                      delete-one-edge negative control as a diff

## step 4 (the walker) -- landed 2026-09-17

- walker/eris_lj_WALKER.diff               the dependency-ordered fill as shipped (regenerated from the final source; includes the two review fixes)
- walker/NOEDGE-negative-control-shellfill.diff   delete the open-upvalue edge: D2 alone goes silent
- walker/order.lua                         the implementer's discriminator (artifact); tests/shell-order.lua is canonical
- walker/once_drain.inc                    D3's original walker, the starting point
