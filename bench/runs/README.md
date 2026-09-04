# `bench/runs/` — the measurements the documents cite

Every number in `bench/results-*.md` and `docs/research/memory-accounting.md`
came out of a run of `bench/oc/matrix.sh`. This directory holds enough of each
of those runs that a claim can be checked against the thing it was derived
from, **in the repository**, without needing the machine it was measured on.

## Why this exists

It exists because the evidence was being lost, twice over and in two different
ways, and both were discovered the hard way on 2026-09-04.

**The harness wrote into a session-scoped scratch directory.** Committed
documents across this repository cite paths like `matrix3/B-sieve.smoke.log` and
`scratchpad/verify/…`. Those live under the agent session's temp directory.
They do not survive the session. A reader coming to
`results-in-machine-phase1-2026-09-04.md` a week later and trying to check the
`sieve` claim would find the citation resolves to nothing — and a
`docs/research/` grep shows dozens of older citations already in that state.

**And the driver cleared its own output directory to re-run.** `matrix.sh` used
a fixed `OUT` path, so starting a new run began with `rm -rf`. On 2026-09-04
that destroyed the six logs behind a claim this repository had already
committed — "`sieve` fails on our native 6 of 6". The claim survived only
because it could be re-measured; nothing about the workflow guaranteed that.

`matrix.sh` now derives `OUT` from a timestamp and refuses to write into a
directory that already has results in it, so neither failure can recur by
accident. This directory is the other half: the run outlives the machine.

## What goes in, and what does not

A full 78-run matrix is about 1 MB of logs, and almost none of it is ever read.
So the rule is by *citation*, not by completeness:

| file | committed? |
|---|---|
| `rows.tsv` — one line per run, the tabulated result | **always** |
| `progress.txt` — the human-readable run log with timings and box meters | **always** |
| `<cell>-<bench>.smoke.log` — the full machine log for one run | **only if a document quotes it** |

The first two are a few KB per run and are what every table is actually built
from. The third is 12 KB each and is what you need when a *specific* run is the
evidence — a machine that died, a milestone that failed, a `JIT PROBE` line that
rules out a mechanism.

When you write a claim that rests on one run, commit that run's log **in the
same change as the claim**. A citation added later, to a file that was never
committed, is the failure this directory exists to prevent.

## What is here

| run | what it was | why it is cited |
|---|---|---|
| `2026-09-04-matrix-shared-machine` | the first design, all nine benchmarks in one machine — **superseded** | the cell-B deaths that were wrongly explained as accumulated garbage; `B1.smoke.log` shows the machine dying on `sieve`, the *second* benchmark, with 1003 KB free |
| `2026-09-04-matrix3-fresh-machine` | one benchmark per machine, before the harness wedge was fixed | the `sieve` A-lives/B-and-C-die pair, and the §8d persistence-path OOM in `B-strings.smoke.log` |
| `2026-09-04-matrix-rerun-fixed-harness` | 78 runs on the fixed harness — **the Phase 1 table** | every ratio in `results-in-machine-phase1-2026-09-04.md`; `n=3` on every row |
| `2026-09-04-sieve-trio` | `sieve` ×3 per cell with the guard's units corrected | the emergency-GC case (memory-accounting.md §8c). All nine logs are here because the claims rest on them individually — cell B's `jit.status()=false` is what excludes trace memory |

`rows.tsv` columns are: cell, benchmark, replicate, box meter, milestone
failures, machines lost, then the `PHASE1 ROW` payload as
`name/status/CHECK/min/max/freeKB/reps`.

## Reading a run without the machine

```sh
# the table, as the results document computes it
awk -F'\t' '{split($7,a,"/"); print $1, $2, a[2], a[4]}' rows.tsv

# every run that was not a clean pass
grep -v '/ok/' rows.tsv

# intra-run spread, which decides whether a ratio is quotable at all
awk -F'\t' '{split($7,a,"/"); if(a[2]=="ok") printf "%s %s %.2f\n",$1,$2,a[5]/a[4]}' rows.tsv
```

The box meter (column 4) is a fixed 2M-iteration sandbox loop run before any
benchmark, so it calibrates each boot against its own cell's median. It is
comparable **within** a cell and not across cells, because each cell runs it on
its own VM. Check a row against its cell median before quoting its ratio; this
is what caught a `mandelbrot` A/C of 28× as a fast-box artefact.
