# 2026-10-20 -- the LuaJIT pin, enforced: one file, a pinned build compiles exactly the pin's tree, and the jar build refuses anything else

The evidence behind roadmap row 203's "Status 2026-10-20" and its four notes after it (the build-copy round,
the export check, round 4, round 5), and behind [docs/jit-guide.md](../../../docs/jit-guide.md) 1.1, 7.2-7.6,
P44 and open questions 13-15.

- **The problem.** The pin `1ee778a4` was written out in three build files, and nothing compared it with what
  was built. HEAD's `build-native.sh` built a complete additive DLL from the pin's parent `8c23d6aa`, which
  lacks one fold rule in `lj_opt_mem.c`. It stamped the DLL `8c23d6aa`, and HEAD's gradle accepted it.
- **The decision (the user, 2026-10-20):**
  - The pin lives in one file, `native/luajit/upstream.commit`.
  - `build-native.sh` refuses a checkout at any other commit. `OCLJ_LUAJIT_UNPINNED=1` builds it anyway,
    loudly, for experiments.
  - gradle always refuses a native whose fingerprint does not name the pin.
- **Five rounds.** Each was implemented by an agent, then reviewed by an adversarial verifier; round 5 had an
  implementer only, and this archive's run is its check. Each review measured another way to ship code that
  was not the pin's under the stamp `1ee778a4`, with gradle accepting it, or another way to make the build
  delete or overwrite something outside its own products:

  | round | build-native.sh | what its review measured, closed by the next round |
  |---|---|---|
  | 1, the pin file and the refusals | `b3dc7c1a` | a build copy kept from an unpinned build of `8c23d6aa`, and an uncommitted edit in a checkout at the pin, both shipped the parent's `lj_opt_mem.o` (`05d34fc1`, not `42bd49f9`) |
  | 2, the build copy made afresh from `git archive <pin>^{tree}` | `e1bf77df` | a replace ref, a smudge filter (even one set only in the environment) and a forged loose blob shipped the parent's code through the export; an unpinned build through a symlinked checkout deleted the real `.git` in AlmaLinux 8 |
  | 3, the export checked against the pin, object by object | `fc4e465d` | the directory guards were string compares, bypassed by `<junction>/..` and by non-ASCII case (a throwaway checkout deleted); `CFLAGS` from the environment reached 76 LuaJIT compile lines |
  | 4, identity guards (`cd -P`, `test -ef`) and the environment's flags dropped | `7c3c2683` | the shell and Windows' own programs read `<junction>/..` and a trailing dot differently, so the guards checked one directory and make, gcc and ld wrote another; `MAKEOVERRIDES` still leaked |
  | 5, every input directory at its physical path, names ending in `.` or ` ` refused on Windows | `47b9c52e` | (this archive's run) |

- **What is claimed now** is listed sentence by sentence, each with the check behind it, in
  `design/claims.md`:
  - **The source.** The LuaJIT source a pinned build compiles is the tree the pin's 40 digits name, verified
    by hash up to a SHA-1 collision. It is then changed by the twelve patch scripts and compiled with the
    script's own flags.
  - **The environment.** The environment's compiler, make and linker variables on the script's list are
    dropped.
  - **The toolchain is not pinned.**
  - **What the build touches.** Within the threat model (accidents and plausible configurations, not
    someone who edits the script), the build removes and overwrites only its own products.
  - **What remains** is in open question 15 of the guide.

Implemented in the working tree on 18b57de (the gradle unversioned-import fix, committed), uncommitted.

## Results

`scripts/final-check2.sh` is one chain for all of it. The main session ran it on the final text into a fresh
directory (`logs/final-main/`): **79 PASS, 0 FAIL in 528 s**, `build-native.sh` md5 `47b9c52e`. Lines that
merely contain "BUILD FAIL" describe a refusal the line requires.

| group | lines | what passed |
|---|---|---|
| W1, canonical builds | 15 | Windows additive: 77 LuaJIT objects and the 3 of ours equal `build/native`'s; dropin equal to round 2's dropin reference; stamp `1ee778a4\|LuaJIT 2.1.ROLLING\|412be694`; the export verified (8 trees, 232 files); `dist`'s copy equal to the build's own output. AlmaLinux 8 with `OCLJ_GLIBC_MAX=2.28`: additive .so `6c88805001bae0cd2b385803f5d857c7` and dropin `6c0715d11344c5fe075cd33f4f93cdbc`, the release's byte for byte. Every log: `ignored from the environment: none` |
| the environment | 8 | `CFLAGS='-include <h>'`, a lower-case `cpath` and `MAKEFLAGS='TARGET_CFLAGS=-O0'`: dropped and named, objects equal W1's, no marker; `MAKEOVERRIDES=CFLAGS=-O0`: the same, no `-O0` line |
| the export | 9 | replace ref: builds the pin, objects equal W1's; environment-config filter and forged blob: BUILD FAIL naming `src/lj_opt_mem.c`; HEAD forged to `1ee778a4` plus zeros: refused; dirty checkout: builds the pin, the WARNING names the file; `export-ignore` in the tree and in `.git/info/attributes`: BUILD FAIL, 231 files against 232 |
| directory guards, Windows | 20 | `<junction>/..` and non-ASCII-case spellings of a removed directory or of `dist`: refused, throwaways and `dist` intact; `OCLJ_BUILD=<x>/<junction>/..`: built in the junction's target, the clone at the lexical path untouched; `OCLJ_OUT=<B>/dist.`, `OCLJ_SHIM=<E>/shim.` (with a decoy beside it), `OCLJ_SER=<E>/ser.`: refused; an `OCLJ_BUILD` in the repository outside `build/` (directly, by case, through a junction), and in the script's own repository: refused, nothing created |
| directory guards, AlmaLinux 8 | 10 | the same refusals end to end through symlinks and non-ASCII case on `/mnt/c` |
| unpinned, gradle, negctl | 4 | an unpinned build is stamped `unpinned` and not collected; `verifyModAssets` accepts the pinned DLL and refuses the unpinned one; negctl-bitop's SARCONST arm passes, its pristine files taken from the export |
| hygiene | 13 | `sh -n` in Git Bash, AlmaLinux 8's sh and Ubuntu's dash; 0 CR bytes in the five docs and script files; `git diff --check`; the `build/` md5 census (38985 files) and the pristine checkout's stat and `.git` lists unchanged; the script and the chain unchanged during the run |

**The fail-first** (`logs/fail-first-7c3c2683/`, run by the round 5 implementer with `FC_SCRIPT=` round 4's
text) gives 65 PASS and 14 FAIL. The 14 are exactly the lines for what round 5 adds: T1, T2, T4 and its
AlmaLinux 8 replay, the three U2L lines, three `MAKEOVERRIDES` lines, `SHIM-dot`, `SER-dot`, and the two
lines for the script's own repository. On that text, T1, T2 and the own-repository `dist` case each replaced a
`dist`'s DLL with one stamped `unpinned`. Each earlier round's checks failed first on the text before them;
the rounds' reports name those logs (`design/`).

**DLL md5s differ between builds of the same objects** (the link time is in the PE header, guide P13), so
Windows builds are compared object by object. `logs/final-main/binaries.md5` lists every library the run made.
The release DLL in `build/native/dist` is `3174ef37` and was not rebuilt; nothing under `build/` was written.

## Files

| path | what |
|---|---|
| `logs/final-main/` | the main session's run: `summary.txt` (one line per check), `ALL.done`, `script.txt`, `logs/` (every build and gradle log), `rc/`, `cmp/` (object md5 lists and diffs), `alma/` and `ubuntu/` (the Linux parts), `census/digest.txt`, `binaries.md5` |
| `logs/fail-first-7c3c2683/` | the same chain on round 4's text |
| `scripts/final-check2.sh` | the chain (md5 `52f404b1`); `final-check.sh` is round 4's, which it extends |
| `scripts/extra.sh`, `scripts/fn-test5.sh` | round 5's extra cases (an `OCLJ_SHIM` and an `OCLJ_REPO` given through a junction, among others) and the `physpath`/`inside` function tests in three shells; their runs are in scratch, `claude-tmp/oclj/pin5/extra-impl2/` and `pin5/fn/` |
| `scripts/remap5.py` | the guide's line-cite remap from round 4's text to round 5's |
| `scripts/mkreports.py`, `mkarchive.sh`, `slim.py` | how this archive was made |
| `design/reports-r1-r4.json` | rounds 1-4: each implementer's and verifier's report |
| `design/round5-report.md` | round 5's implementer's report |
| `design/claims.md` | every guarantee sentence in README, CLAUDE.md, the guide and roadmap row 203, with the check behind it |
| `MANIFEST.txt` | every file here |

Not archived:
- the binaries and the scratch build trees (each run's `b/`, `t/`, `alma/b-*`);
- the full `build/` census files, 38985 lines each, of which `census/digest.txt` keeps the line count and md5;
- the rounds' own scratch evidence, which the guide and the roadmap cite by path, under
  `claude-tmp/oclj/pin/`, `pin2/`, `pin3/`, `pin4/` and `pin5/`.

The four gradle logs' CRs were converted to LF for the repo (`slim.py`).

Repo files at the run (md5):
- `native/build-native.sh` `47b9c52e`, `docs/jit-guide.md` `036642bd`, `CLAUDE.md` `0416090c`;
- `docs/roadmap.md` `31ca738f`, and `9a3b152c` after the run, when row 203 gained the pointer to this
  archive;
- `README.md` `98f6042d`: its pin paragraph was split into bullets during the run, with the same claims;
  `CR0-README.md` read this text;
- `build.gradle.kts` `5e5dbe6c`, `prototype/watchdog/Makefile` `8c016d2d`, `prototype/watchdog/build.bat`
  `773d5393`, `prototype/watchdog/README.md` `14d69f43`, `serializer/Makefile` `3426e74e`,
  `test/native/negctl-bitop.sh` `bb16f824`, `test/native/negctl-pack.sh` `1e56aa1e`,
  `native/luajit/upstream.commit` `6ea470c7`.
