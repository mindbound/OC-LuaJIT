# 2026-10-03 -- the RAM scale, measured

The evidence behind [../../results-ramscale-2026-10-03.md](../../results-ramscale-2026-10-03.md).
All harness runs on ocelot-brain with JDK 8, launched pinned to the performance cores
(`affrun C03C03`; the java process inherits the mask), additive DLL `cb29485d`
(= `build/native/dist`), watchdog kernel on ours, OC's own kernel on stock. The
object-size runs (`objsize-2026-10-03.txt`) were standalone processes, not harness runs.

| file | what |
|---|---|
| `chain1.log` | the capacity matrix (`OCLJ_PROBE=capacity`), 82 runs, 20:55-22:22: one summary line per run plus its `CAP-IDLE` / `CAP-LIVE` lines; the summary line's `SMOKE\| C` prefix is cut, so it reads `APACITY\|` |
| `chain1-tables.md` | `scripts/analyze.py chain1.log`: every run classified (clean / recovery refused / machine down / boot failed), then held counts, live sets, near-the-wall times and idle counters |
| `chain2.log` | the census OSes at 1.8, stock and ours (AxisOS 1 x 1024 KB, MineOS 2 x 1024 KB), 14 000 ticks each |
| `chain3.log` | the full harness suite at the new default scale 1.8: ours JIT on, JIT off, sieve only, and stock |
| `chain4.log` | two more JIT-on full-suite runs at 1.8, on `mem-2`'s new clause |
| `objsize-2026-10-03.txt` | `bench/oc/checks/objsize.lua` on PUC 5.2.4 and on our LuaJIT (`-joff`, then JIT on), with OpenOS's sources |
| `scripts/` | the launchers (`cap.sh`, `census.sh`, `full.sh`), the chains and `analyze.py`; they hard-code this session's scratchpad paths for `affrun.exe` and `OCLJ_LIBS` |
| `logs/` | the full harness log of every run the results document quotes, including three earlier 2026-10-03 runs (`prior-accsync-*`, from the accounting change's gate chain at scale 3.0) that it cites for `mem-2` |

Arms in the matrix: S stock PUC 5.2; D ours as shipped; E ours with `OCLJ_JIT_EARLY=off`
(JIT off through kernel init, on once `kernelMemory` is taken); O ours with the JIT off
throughout. Run names are `<stick>-<shape>-r<rep>-<arm>`; sticks `one` 192 KB, `onehalf`
256 KB, `threehalf` 1024 KB; all at `ramScaleFor64Bit` 1.8 except the two `scale1.0` runs.

`chain1` ran an earlier revision of `capacityProbe` whose `cap-1` milestone message called
every unclean ending "the fill never finished"; the `CAPACITY`, `CAP-IDLE` and `CAP-LIVE`
fields are the same, and the classification in `chain1-tables.md` is `analyze.py`'s, from
those fields. The current source names each outcome itself; `logs/final-check-one-record-D.log`, run on the final source, is a recovery-refused run that the new message names as such.

Two notes on `chain3`. The harness source was edited while it ran -- `mem-2`'s second
clause changed from "a read of exactly 0 live traces" to "a read at most max(2, 5% of the
count before)" -- and each run compiles the harness afresh. All three runs of ours compiled
the OLD clause (the sieve run's `mem-2` line has no near-empty field, so the edit landed
after it started); the stock run skips `mem-2` either way. And one unpinned standalone
`luajit.exe` run of `objsize.lua` (about a second) overlapped `full18-additive-on`, whose
one failure was that clause's race; `full18-additive-on-r2` (chain4), with no overlap, also
never read 0.
