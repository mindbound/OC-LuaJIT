# shell-fill prototype artifacts

Spec: docs/shell-fill.md. Rationale: docs/research/persistence-clean-slate.md.

- eris_lj_SHELL.diff  verified prototype vs eris_lj.c (94 lines); SHELL.exe md5 83763275
- mkshell.py          anchored patcher that produces it (apply to a COPY of eris_lj.c)
- shell.lua           the failing-first test (= tests/shell.lua); shell_stress.lua its companion
- rig.lua             D4 rig: RIG_MODE=orig reproduces the in-game error; to become tests/userdata.lua
- walker/             D3 reachability walker (once_drain.inc) for the step-4 graft, with the
                      delete-one-edge negative control as a diff
