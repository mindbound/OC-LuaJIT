# 2026-10-23 -- shifts of an exact operand are exact: the proof, its review and its checks

The record behind [docs/jit-guide.md](../../../docs/jit-guide.md) 3.11's "Shifts of an exact operand" and the
roadmap's notes of 2026-10-23 on round 3's follow-ups (item 6) and on the int/i64 CSE twins. Until this round the
guide said of the shifts "Measured, not proved, and not prototyped: no rule reads it". The round proved the
claim, found two stronger facts, checked all four by machine, and on the way found and confirmed a separate JIT
bug, the CSE twins. No rule was built; nothing in the repo's code changed.

## What is here

- `argue/argument.md` (revision 3, md5 `ddcbacce`): the argument, laid out like FIX-NUMCONV's. Its sections: the
  set D of int64 values that are exactly a double, as the interpreter's check, `oclj_bit2num` and the JIT's result
  guard each test it (Lemma D); the four lemmas and their proofs; every producer of an i64 `BSHL`/`BSAR` on this
  build; which IR operands are exact by construction; the rule a later round could build on it, with its tests
  and negctl arms; platform scope; and section 8, the CSE twins.
- `refute/notes.md`: the adversarial review of revision 1, read against the source. It found no break in the
  lemmas or the sketched rule; its findings (the CSE twins, gaps in the checks, two wordings, a cyclic induction
  step) are applied in revisions 2 and 3 (the argument's section 9 lists them).
- `checks/`: `model.py`, `jitcheck.lua` and `run.sh`, after two rounds of review and fixes, and
  `checks/runs/run-1/`, their one run (`summary.txt`, `run.log`, each part's output; `inputs.md5`, `env.txt`).
- `cse/`: the CSE-twin probes: `cse-fwd.lua` (runtime loop bounds; no twin forms), `cse-fwd2.lua` (constant
  bounds; the twins form), `cse-ir.lua` (one loop for `-jdump`), and their outputs `run-1` to `run-3`.
- `md5s.txt`: every file's md5 as it is in scratch (`claude-tmp/oclj/shiftexact/`), and the binaries the runs
  used. `scripts/mkproof.py` wrote every file here but this README.

## The four lemmas [I: proved in `argue/argument.md`; M: checked below]

Write D for the int64 values a double holds exactly: 0 and every m * 2^e with |m| < 2^53, within
[-2^63, 2^63) (so -2^63 is in D, 2^63 - 1 is not). Counts are taken & 63 everywhere the code shifts.

1. **L1, left shift:** for x in D and every k in 0..63, the wrapped x << k is in D.
2. **L2, arithmetic right shift** (`~>>`, IR `BSAR`): for x in D and every k, floor(x / 2^k) is in D.
3. **L3, a left shift by 10 or more:** x << k is in D for EVERY int64 x when k >= 10, since every multiple of 2^10
   in range is; the bound is tight: (2^54 + 1) << 9 has 54 significant bits.
4. **L4, `&`:** x & y is in D whenever x and y are.

The logical right shift (`>>`, IR `BSHR`) has no such lemma: -1 >> 1 = 2^63 - 1. Nor do `|`, `~` (binary or
unary) or an add of two exact values; the argument gives a counterexample for each.

## The checks [M: `checks/runs/run-1/`, 2026-10-23 10:36:11-10:36:16Z, on `build/native`]

`run.sh` ran `model.py` and then `jitcheck.lua` under seven option sets on `build/native`'s `luajit.exe`
(`f4038cd6`; `lj_opt_fold.o` `f6d916e2`, FIX-NUMCONV's release), with no game running. Verdict: PASS.

- **`model.py`** checks the lemmas in a scaled model, every word width W from 4 to 16 bits and every precision P
  in place of 53, over every operand, and in two 64-bit sweeps at P = 53. Every lemma held in every case: L1 and
  L2 in 7,860,708 model cases each and 438,400 64-bit pairs each; L3 in 17,694,640 model cases and 43,956 64-bit
  pairs (802 of whose operands lie outside D); L4 in 4,141,580 model pairs and 112,400 64-bit pairs. Every
  control found counterexamples where it must: the logical right shift and `x | (1 << k)` (218,473 and 456,109 in
  the model), `x | y` beside L4 (206,876), and L3's tightness at k = W - 2 - P and at k = 9 in the 64-bit sweep
  (the witness (2^54 + 1) << 9, 54 bits). Its instruments compare a second, literal spelling of every operator
  with the fast one, `oclj_bitop.h`'s own shift and round-trip code with the model's, and the case counts with
  their closed forms, each with a control that must differ.
- **`jitcheck.lua`** runs, in compiled loops, x << K and x ~>> K for K in 0..64 on doubles in D and on earlier
  results, negative counts, variable counts, chains of two shifts and masked shapes: 2.0 million operand pairs,
  every one equal to a reference computed without bit operators, under `-joff` and six JIT option sets (default,
  `-O3 -Ohotloop=1`, `-Omaxside=0`, `-Ohotloop=1 -Ohotexit=1`, `-O3 -O-loop`, `-O3 -O-fold`); each compiled run's
  stdout is identical to `-joff`'s. Its coverage instrument reads each compiled trace's IR and maps every trace
  exit to its snapshot. In every one of the six compiled sets, **no result guard of a lemma part ever failed**:
  0 exits through the snapshots holding them (447 to 1250 result guards a set, 305 to 934 of them on an i64
  `BSHL`, `BSAR` or `ADD`). Its two controls, `x >> K` and `x << -K` on negative x, must raise and did (1152 a
  part), and their result guards did fail, 48 to 134 exits a part, through the same kind of snapshot the lemma
  parts are watched through; so the instrument sees a failing result guard when there is one. A `jit.off`'d
  probe read untraced, as it must.

An earlier `model.py` (`bbb2f4d7`, without L3's and L4's instruments) passed a smoke run the same day, kept in
scratch (`precheck-1/`).

## The CSE twins, a separate bug [M: `cse/run-3/`; S; I]

`lj_opt_cse` matches an instruction on its opcode and operands and returns the existing one with its own type
(jit-guide 3.9). After x64's `simplify_conv_sext` lets our i64 op take an int loop index directly, our op and an
int op of LuaJIT's `bit` library on that index can be the same instruction to CSE. On `build/native`'s
`luajit.exe`, with constant loop bounds, `bit.lshift(i, 3)` then `i << 3` in one loop gave 341 wrong values of
401 under the JIT (456 for 4294967752), and `bit.bnot(i)` then `~i` 341 of 401 (4294967237 for -59); `-joff`
and the same loops without `bit` were right, and the IR shows `int BSHL 0001 +3` and `int BNOT 0001` serving the
5.3 operators (`cse/run-3/jdump.txt`, traces 1 and 4). With runtime loop bounds the index keeps its conversion
and no twin forms (`cse/run-1/`). The reverse order, our op first, was not run: the `bit` library would get an
I64-typed result into a Lua slot, which a snapshot restores with no I64 case (argument 8.6) [S]. The game opens
OpenComputers' `bit32`, not LuaJIT's `bit`, and FFI is off [S], so the measured pairs cannot form there. The argument's
8.3 stopped at that; the fix round's design, written after it, took a census of every producer (scratch
`claude-tmp/oclj/csetwin/design.md` 1.4-1.5): in game no wrong value is known, since the pairs the game can form
(`select` beyond its varargs, a library argument narrowed from `x + x`, an inner `for j = x, n, x`) give equal
values in the forward order; but in the reverse order `x << 1` before such an inner loop, recorded in the same
trace, would put an I64 into the inner loop's index slots, a crash candidate by reading, never run [S][I]. Fixing
it is a round of its own (the roadmap's CSE-twin row).

## Not here

- A rule. What a rule could read, where it would sit and what would prove it are in the argument's section 5;
  the measure-first round, with `&` included (the user's decision, 2026-10-23), comes after the CSE-twin fix.
- The IR of the shapes in the argument's section 5.4: not read with `-jdump` yet.
- The scratch smoke run (`precheck-1/`) and a first, incomplete build of this directory (moved aside, not
  deleted).
