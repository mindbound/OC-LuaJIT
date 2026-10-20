# Pin round 5: the claims table

Every sentence in README.md, CLAUDE.md, docs/jit-guide.md (header, checklist item 2, 1.1, 7 and
7.1-7.7, P44, open questions 13-15) and docs/roadmap.md row 203 that states what the pin or the
build's guards guarantee, with what backs it.  Texts as of build-native.sh `47b9c52e`.

How to read the evidence column:

- `run-impl X` is the line `X` of `claude-tmp/oclj/pin5/final/run-impl/summary.txt`, final-check2.sh
  (md5 `52f404b1`) on the final text: 79 PASS, 0 FAIL, 555 s.
- `ff X` is the same line of `pin5/ff-7c3c/summary.txt`, the same chain on round 4's text
  (`7c3c2683`): 65 PASS, 14 FAIL, 687 s; the 14 are MO-ignored-line, MO-objects, MO-no-O0, U2L-clone-untouched, U2L-build, U2L-objects, T1-trailing-dot, T2-junction-dotdot, T4-nonascii-both-new, SHIM-dot, SER-dot, H2-self-repo, H2-self-repo-dist and ALMA-T4.  A claim that round 5 made true shows FAIL there.
- `extra xN` is a line of `pin5/extra-impl2/summary.txt` (`pin5/scripts/extra.sh` on the final
  text, all 15 PASS); `pin5/extra-7c3c2/` is the same on round 4's text, where x8 and x10 FAIL
  and the other 13 PASS (there x10 built with the decoy shim compiled: `x10.txt`, one marker line
  in `lj52shim.o`).  (`extra-impl/` and `extra-7c3c/` are v1 of the script, which passed no
  `OCLJ_REPO`, so the copy of round 4's text stopped at its own missing pin file: an instrument
  fault, kept as it ran.)
- `fn` is `pin5/fn/fn-{win,almalinux,ubuntu}-new.log` (21 of 21 cases in Git Bash, AlmaLinux 8's
  sh and Ubuntu's dash; round 4's text 18 of 21, `fn-*-7c3c.log`).
- Paths under `pin`, `pin2`, `pin3`, `pin4` are earlier rounds' scratch evidence in
  `claude-tmp/oclj/`, cited where the docs cite them.
- [S] means read in the script (the section named); [I] inferred.  Historical sentences ("until
  2026-10-20 ...", "on fc4e465d ...") are backed by the earlier rounds' logs they cite and are not
  listed one by one; the table lists every present-tense guarantee.

## README.md

| # | claim (line 65-67) | backed by |
|---|---|---|
| R1 | with `OCLJ_VARIANT=additive` it leaves the library in `build/native/dist/` | run-impl W1-win-dist (in its `OCLJ_BUILD`'s `dist`, md5 equal to its own output) [M]; [S] COLLECT ADDITIVE ARTIFACTS |
| R2 | `make -C prototype/watchdog luajit-src` clones LuaJIT and checks that commit out | `pin/impl/mk-stamp-3` [M] (guide 1.1) |
| R3 | `build-native.sh` needs git and refuses a checkout whose HEAD is any other commit (naming both commits and the file) | run-impl F7-forged-head [M]; `pin/impl/win-1/new-parent`, `pin2/impl/v6/win-nogit.log` [M] |
| R4 | the LuaJIT source it compiles is that commit's tree ... checked object by object ... byte for byte up to a SHA-1 collision | run-impl W1-win-export, R3-forgeblob, R2-envcfg, EI-infoattr, EI-tree [M]; `pin3/impl/fc4e-w2/forgesub.log` [M]; [S] links 1-4 |
| R5 | the build then changes that tree with its twelve patch scripts and compiles it with its own flags | run-impl W1-win-additive-objects, W1-alma-so-additive [M]; [S] stage 1 |
| R6 | anything that would change the exported files (a git filter or line-ending attribute, an export-ignore, a forged object) stops the build | filter: run-impl R2-envcfg, `pin3/impl/fc4e-w2/filter.log`; export-ignore: EI-infoattr, EI-tree; forged object: R3-forgeblob, `forgesub.log` [M]; a line-ending attribute: [S] link 4 hashes every byte, and the host's `core.autocrlf=true` leaves the export byte-identical to AlmaLinux 8's (`pin3/impl/fc4e-w1/export-win-vs-alma.txt`) [M] |
| R7 | a replace ref is ignored | run-impl R1-replace, R1-replace-objects [M] |
| R8 | a local edit in the checkout is reported with a warning and not built | run-impl F2-dirty, F2-dirty-objects [M] |
| R9 | the variables on the script's list (... `MAKEOVERRIDES` ...), in any letter case, are dropped, and the log names them | run-impl G2-ignored-line, G2-objects, G2-no-marker (`cpath` in lower case), MO-ignored-line, MO-objects, MO-no-O0 [M]; ff MO-* FAIL [M] |
| R10 | the list is what was found, not every name make or gcc can read | [S] THE BUILD ENVIRONMENT; guide OQ15 [I] (rewritten this round from "Compiler and linker settings ... are dropped") |
| R11 | the toolchain is not pinned: release DLL gcc 16.2.0, .so gcc 8.5.0 | `pin4/impl/exp/release-gcc-strings.txt` [M] |
| R12 | these checks guard against ... directories named through symlinks, junctions, `..` or another letter case | run-impl U2-junction-dotdot, U2-nonascii-case, U3-*, G3-case, G3-junction, U2L-*, T2-junction-dotdot, T4-nonascii-both-new; ALMA-U2-*, ALMA-U3-*, ALMA-G3-symlink, ALMA-T4 [M] (rewritten from "paths spelled through symlinks, junctions or another letter case") |
| R13 | every directory the script is given is taken at its physical path before it is checked and used | [S] THE INPUT DIRECTORIES; run-impl U2L-*, T2-junction-dotdot [M]; extra x8 (OCLJ_REPO through a junction read at its physical path), x10 (OCLJ_SHIM through `<junction>/..`: gcc compiles the shim the shell read) [M]; ff U2L-*, T2 FAIL; extra-7c3c2 x8, x10 FAIL (x10 compiled the decoy) [M] |
| R14 | on Windows a path with a name ending in a dot or a space is refused | run-impl T1-trailing-dot, SHIM-dot, SER-dot [M]; ff the same FAIL [M]; a space: [S] winname's `*' /'*` arm, not measured |
| R15 | it removes only the three directories it remakes in its build directory and files of its own names | [S] every `rm` in the script: `rm -rf` of `$LJ_WORK`, `$LJ_EXPORT`, `$NEGI` and `$LJ_WORK/.git`, `rm -f` of fixed names in `$OCLJ_BUILD`, `$OBJ` and `$OCLJ_OUT/$DLL_NAME`, and `make clean` inside `$LJ_WORK` |
| R16 | writes files of its own names only | [S] the write targets (fixed names in `$OCLJ_BUILD`, `$OBJ`, `$OCLJ_OUT`, `$DIST`, and make inside `$LJ_WORK`) [S]; run-impl U2L-clone-untouched (make writes only where the guards looked) [M] |
| R17 | refuses a checkout inside those three | run-impl U2-junction-dotdot, U2-nonascii-case, ALMA-U2-* [M]; extra x3, x4 (export path, inside layoutneg) [M] |
| R18 | refuses a build directory inside the LuaJIT checkout | extra x1, x1-intact [M] |
| R19 | ... or inside the repository outside `build/` (`OCLJ_REPO`'s, and the one the script lives in) | run-impl G3-in, G3-case, G3-junction, G3-nothing-created, G3-under-build-allowed, H2-self-repo, ALMA-G3-* [M]; extra x5 [M]; ff H2-self-repo FAIL [M] |
| R20 | refuses an output directory inside a `dist` directory | run-impl U3-*, T1-trailing-dot, T4-nonascii-both-new, H2-self-repo-dist, ALMA-U3-*, ALMA-T4 [M]; extra x2, x6p, x6u [M]; ff T1, T4, H2-self-repo-dist FAIL [M] |
| R21 | so it removes or overwrites no file of the checkout or of the repository | R15-R20; run-impl CENSUS-pristine-stat, CENSUS-pristine-git, CENSUS-build (the pristine checkout and build/ unchanged across the chain) [M]; the generalisation from the cases [I] |
| R22 | only a pinned additive build replaces the library in `build/native/dist/` | run-impl W1-win-dist, UNP-build (unpinned not collected), T1, T2, U3-*, H2-self-repo-dist (dist intact) [M] |
| R23 | what the checks leave is listed in the guide's open question 15 | guide OQ15 (written this round) |
| R24 | `OCLJ_LUAJIT_UNPINNED=1` ... names the commit `unpinned`, not collected, `./gradlew build` refuses it | run-impl UNP-build, GRADLE-refuses-unpinned [M] |
| R25 | its saved machines and a pinned native's cannot restore on each other | `pin2/impl/v5/` [M]; [S] eris_lj.c compares the whole fingerprint |
| R26 | the jar build checks every native's commit against the file | run-impl GRADLE-accepts-pinned, GRADLE-refuses-unpinned [M]; `pin/impl/gruns-new-1` [M] |

## CLAUDE.md

| # | claim | backed by |
|---|---|---|
| C1 | (line 3) build-native.sh compiles that commit's tree, checked object by object against its 40 digits | as R4 |
| C2 | with our twelve patch scripts and its own flags (it drops CFLAGS, CPATH, MAKEFLAGS and the other compiler and make variables on its list from the environment | as R9, R10 (rewritten from "its own flags only (it drops ... and the like)") |
| C3 | and takes every directory it is given at its physical path) | as R13 (added this round) |
| C4 | and refuses a checkout whose HEAD is another | as R3 |
| C5 | and the jar build refuses a native stamped with another; the toolchain is not pinned | as R26, R11 |
| C6 | (line 5) an unpinned native is stamped `unpinned` and never ships | as R24 |
| C7 | (line 17) build-native.sh remakes the build copy on every run, from the pin's tree as committed, so an edit there is lost, and an edit in the pristine checkout is never built by a pinned run | `pin2/impl/v2/new-step2.log`, `pin3/impl/fc4e-w2f1/` [M]; run-impl F2-dirty, F2-dirty-objects [M] |

## docs/jit-guide.md

| # | where | claim | backed by |
|---|---|---|---|
| G1 | header, The pin | refuses a checkout whose HEAD is any other commit | as R3 |
| G2 | header | the source it compiles is the tree the pin's 40 digits name, byte for byte up to a SHA-1 collision before our twelve changes; checked object by object; never the working tree; a filter, attribute or forged object is a BUILD FAIL; replace refs ignored | as R4, R6, R7, R8 |
| G3 | header | compiles with its own flags, and drops the variables its list names; a name that is not a shell identifier it cannot drop | as R9, R10 (rewritten from "its own flags only: the environment's make, gcc and ld variables ... are dropped") |
| G4 | header | every directory is taken at its physical path before the guards check it and the tools use it; on Windows a name ending in a dot or a space is refused | as R13, R14 (added) |
| G5 | header | the jar build refuses a native whose fingerprint names anything but the pin | as R26 |
| G6 | header, Citations | build-native.sh's cites re-derived ... to round 5's (md5 `47b9c52e`) | `pin5/remap5-write.txt` (39 moved, 1 HAND) and `pin5/cite-check.txt`: 47 cites, 0 not found or wrong first line [M]; the same check against `7c3c2683` finds 40 wrong (`pin5/cite-check-ff-7c3c.txt`) [M] |
| G7 | checklist 2 | refuses another HEAD, compiles the pin's committed tree checked object by object, with our twelve changes and its own flags (drops ... the rest of its list, takes every directory at its physical path); an edit is reported and not built; anything that would change the export stops the build; replace refs ignored | as R3-R9, R13 |
| G8 | 1.1, the pin is one file; every reader reads it | Makefile stamp, build.bat, serializer banner | `pin/impl/mk-stamp-3`, `bat-reader-2`, `pin2/impl/v8/bat-runs.txt`, `pin/impl/ser-banner-2` [M] |
| G9 | 1.1 | preflight refuses a malformed pin file | `pin/impl/malformed-new` [M] |
| G10 | 1.1 | a pinned build needs git, refuses a wrong HEAD or a `.git` without the pin's commit, and starts from exactly the tree the pin names (rewritten from "compiles exactly the tree") | run-impl F7-forged-head [M]; `pin2/impl/v4/nopin-new.log`, `pin3/impl/fc4e-w2/f7-nopin.log` [M] |
| G11 | 1.1 | What is verified: links 1-4; the export is the pin's committed tree byte for byte | run-impl W1-win-export, R2-envcfg, R3-forgeblob, EI-* [M]; links 1 and 2: `pin3/impl/fc4e-w2/forgeobj.log`, `forgepack.log`, `forgepacktree.log`, `pin3/impl/fc4e-w2ff/forgepack.log` [M] |
| G12 | 1.1 | not compared: modes and timestamps | [S] |
| G13 | 1.1 | the working tree is never compiled; a differing tracked file is named in a WARNING | run-impl F2-dirty, F2-dirty-objects [M] |
| G14 | 1.1 | What is compiled: that tree with the twelve changes, with the script's flags; it unsets the variables of its list, whatever the case, and prints the names; the list is what was found (round 4's missed MAKEOVERRIDES); a non-identifier name cannot be unset | run-impl G2-*, MO-*; ff MO-* FAIL; `pin4/verify/runs/env2-new/` [M]; non-identifier names [I] (rewritten from "every variable that make or gcc would take from the environment") |
| G15 | 1.1 | the toolchain is not pinned; release compilers | as R11 |
| G16 | 1.1, threat model | guard against accidents and plausible configurations, the variables of the list, directories through symlinks, junctions, `..` or other case | as R12 (rewritten from "paths spelled through symlinks, junctions or another letter case") |
| G17 | 1.1, threat model | since round 5 every directory at its physical path; a trailing dot or space refused | as R13, R14 |
| G18 | 1.1, threat model | removes only the three directories and files of its fixed names; writes files of its fixed names only, in `$OCLJ_BUILD`, `$OCLJ_OUT`, `$OCLJ_BUILD/dist` | as R15, R16 |
| G19 | 1.1, threat model | its guards refuse a checkout inside a directory it remakes, an `$OCLJ_BUILD` inside the checkout or a repository (`OCLJ_REPO`'s or the script's own) outside `build/`, an `$OCLJ_OUT` in either `dist` | as R17-R20 |
| G20 | 1.1, threat model | so it removes or overwrites no file of the checkout or of a repository, and only a pinned additive build replaces the library in a `dist` | as R21, R22 (rewritten from "the build removes or overwrites only its own products (never the checkout or a file the repository tracks ...)") |
| G21 | 1.1, threat model | not covered: an unrelated file of one of the build's names in an `$OCLJ_BUILD` outside the repositories is overwritten; OQ15 | [S] (added) |
| G22 | 1.1 | gradle refuses a native whose commit field is not the pin's first 8 | as R26 |
| G23 | 1.1 | `OCLJ_LUAJIT_UNPINNED=1`: warns, stamps `unpinned`, not collected; gradle refuses; blobs do not cross; needs no git; other values refused | run-impl UNP-build, GRADLE-refuses-unpinned [M]; `pin2/impl/v2/new-step1.log`, `pin2/impl/v5/`, `pin2/impl/preflight/`, `pin2/impl/v6/win-nogit-new-unpinned.log` [M] |
| G24 | 1.1 | the preprocessor's verdict and what every build checks (`-dM` gate) | [S] feature-channel gates (`~:1586`); run-impl W1-* (every gate passed) [M] |
| G25 | 1.1, platforms | build-native.sh refuses any machine but x86_64 | [S] `:1418-1420` |
| G26 | 7 intro | the copy is made afresh each run from the pin's committed tree, checked; the variables of its list are dropped; every directory at its physical path | as C7, R9, R13 (rewritten from "the environment's make, gcc and ld variables are dropped first") |
| G27 | 7.2 row | the build copy is remade on every run; a hand edit in build/ is gone; an edit in the checkout is never built | as C7 |
| G28 | 7.3 | the pin's export is the committed bytes on every host; both build copies LF; objects equal | `pin3/impl/fc4e-w1/` (`ls-files-eol.txt`, `cr-census-win.txt`, `export-win-vs-alma.txt`), `fc4e-alma-w1/` [M]; run-impl W1-win-additive-objects, W1-alma-so-* [M] |
| G29 | 7.4 | build-native.sh drops the variables of its list; a make run by hand does not | as R9 (rewritten from "drops the environment's make, gcc and ld variables"); `pin4/impl/exp/mkn-win/summary.txt` [M] |
| G30 | 7.6 build environment | unsets the variables of the list (those measured or read to change the build), prints the names | as G14 (rewritten from "every variable that make or gcc reads") |
| G31 | 7.6 build environment | make's own, now with MAKEOVERRIDES: round 4's review measurement; now W1's objects | `pin4/verify/runs/env2-new/`, `alma-mo-new/`, `pin4/verify/exp/mkexport/` [M]; run-impl MO-*, ff MO-* FAIL [M] |
| G32 | 7.6 build environment | whatever the case of the name; kept names; none set on either host; canonical builds unchanged | `pin4/impl/exp/caseenv.log`, `exp/win-host.txt`, `exp/alma/probe.txt` [M]; run-impl W1-win-ignored-none, W1-alma-ignored-none [M] |
| G33 | 7.6 build environment | a non-identifier name cannot be unset; make takes such names (`-*-command-variables-*-`) | [S][I] (added); OQ15 |
| G34 | 7.6 build environment | the injected environment builds the canonical objects with no marker | run-impl G2-* [M]; `pin4/impl/ff2-new/summary.txt` [M] |
| G35 | 7.6 input directories | every directory input becomes its physical path, the guards compare those, every later command gets them; one naming no directory is left for its check | [S] THE INPUT DIRECTORIES `:481-571`; extra x8, x10 [M] |
| G36 | 7.6 input directories | on Windows winname refuses a name ending in a dot or a space before anything is created | run-impl T1-trailing-dot, SHIM-dot, SER-dot [M] |
| G37 | 7.6 input directories | Why: Git Bash hands `<x>/<junction>/..` as written, Win32 takes `..` by spelling; a trailing dot or space kept by the shell, dropped by Win32 | `pin4/verify/exp/dd1/`, `dot1/`, `dot2/` [M] |
| G38 | 7.6 input directories | on 7c3c2683: T2 regression, T1 (also a scratch repository's dist), U2L | `pin4/verify/runs/u3-new/`, `u3-fc4e/`, `repo-new2/`, `more-new/` [M]; ff T1, T2, U2L-* FAIL [M] |
| G39 | 7.6 input directories | on round 5's text: T1 refused, T2 links into the physical else/dist, U2L builds in the target with W1's objects and the clone unchanged, SHIM/SER dots refused; each fails on 7c3c2683 | run-impl T1-trailing-dot, T2-junction-dotdot, U2L-*, SHIM-dot, SER-dot; ff the same FAIL [M] |
| G40 | 7.6 directories | what is refused (checkout inside the three, OCLJ_BUILD inside the checkout, OCLJ_OUT in the dists incl. the script's own repository's, OCLJ_BUILD in a repository outside build/ incl. the script's own) | as R17-R20 |
| G41 | 7.6 directories | the script's own repository: H2 measured; on 7c3c2683 the first built into the scratch repository and the second replaced its dist's DLL | run-impl H2-self-repo, H2-self-repo-dist; ff H2-* FAIL [M] |
| G42 | 7.6 directories | a copy of the script guards its own parent directory as a repository | [S] `SELF_REPO=$SELF_DIR/..` |
| G43 | 7.6 directories | the comparison is by identity on the physical paths; `pathkey` folds A-Z and reads bytes outside printable ASCII as `?` | [S] `inside`, `pathkey`; fn [M] (rewritten from "every path is resolved with cd -P, which takes .. where the file system does") |
| G44 | 7.6 directories | A-Z folding alone let the both-new non-ASCII pair through; now refused on Windows and in AlmaLinux 8 | `pin4/verify/runs/u3-new/` t4 [M]; run-impl T4-nonascii-both-new, ALMA-T4; ff T4 and ALMA-T4 FAIL [M] |
| G45 | 7.6 directories | the cost: a false refusal of two names differing only outside printable ASCII, never a pass | fn, the "documented cost" case [M]; [S] |
| G46 | 7.6 directories | cd -P and test -ef alike in three shells | `pin4/impl/exp/ef-win.log`, `exp/alma/probe.txt`, `exp/ubuntu/probe.txt` [M] |
| G47 | 7.6 directories | physpath/inside: 17 cases on round 4's text; 21 on round 5's in three shells, 18 on 7c3c2683 | `pin4/impl/exp/fn3-*.log`; fn [M] |
| G48 | 7.6 directories | each refusal held on round 4's text, and again on round 5's, with AlmaLinux 8 replays | `pin4/final/run-impl/`; run-impl U2-*, U3-*, G3-*, ALMA-* [M] |
| G49 | 7.6 directories | round 4's "[I] the identity comparison refuses everything the string comparison did" | rewritten: refuted by `pin4/verify/runs/u3-new/` t2 against `u3-fc4e/` t2 [M]; replaced by "the tools are handed the same physical paths, so `..` and a trailing dot or space can no longer be read two ways", run-impl T2-junction-dotdot, U2L-*, T1-trailing-dot, SHIM-dot, SER-dot [M]; other Win32 readings OQ15 [I] |
| G50 | 7.6 pinned build | every git call through ljgit; refusals in order; the `pin = met` line | `pin2/impl/v6/`, `pin/impl/win-1/new-parent`, `pin2/impl/v4/`, `pin3/impl/fc4e-w2/` [M]; run-impl F7-forged-head [M] |
| G51 | 7.6 unpinned | skips the git checks; warning; unpinned stamp; not collected; values refused | as G23 |
| G52 | 7.6 canonical build | equals build/native's on Windows; release .so files in AlmaLinux 8; again on round 5's text | run-impl W1-win-additive-objects, W1-win-dropin-objects, W1-alma-so-additive, W1-alma-so-dropin, W1-alma-objects, W1-win-dist [M]; `pin5/alma-jni-path.txt` (OCLJ_JNI's physical path in AlmaLinux 8 is the resolved symlink) [M] |
| G53 | 7.6 stage 1 | build copy made afresh; links 3 and 4; the tree not the commit; export byte for byte; WARNING only; unpinned copy never the checkout's path; symlinks refused | run-impl W1-win-export, EI-*, R2-envcfg, R3-forgeblob, F2-dirty [M]; `pin2/impl/win-v1/commitarch-additive.log`, `pin3/impl/fc4e-w2/`, `fc4e-alma-w2/`, `fc4e-alma-w3/`, `fc4e-w3win/` [M] |
| G54 | 7.6 running it outside build/ | keep the clone and OCLJ_BUILD apart, outside the repository (and the one a copy sits in) unless under build/; a dot or space name is refused | as R17-R20, R14 |
| G55 | 7.7 | the commit in the blob fingerprint is the pin's first 8 (pinned), `unpinned` otherwise | run-impl W1-win-stamp, UNP-build [M] |
| G56 | 7.7 packaging | verifyModAssets refuses a .so above the floor or with an unversioned import; refuses a fingerprint commit that is not the pin's | `bench/runs/2026-10-20-gradle-imports/` [M]; run-impl GRADLE-* [M]; `pin/impl/gruns-*` [M] |
| G57 | 7.7 | it checks a name, not code: that the name stands for the pin's source tree, changed by the twelve patch scripts and compiled with build-native.sh's flags, is build-native.sh's part | as R4, R5, R9 |
| G58 | P44 | fix: every run removes the build copy and makes it afresh, a pinned run from the pin's checked export | `pin2/impl/v2/new-step2.log`, `pin3/impl/fc4e-w2f1/` [M]; run-impl F2-dirty-objects [M] |
| G59 | OQ13 | the export no longer depends on the host's git | `pin3/impl/fc4e-w1/export-win-vs-alma.txt`, `fc4e-w2/` [M]; the export-subst behaviour of other gits [I] |
| G60 | OQ14 | no lock for two runs in one OCLJ_BUILD | [I] (unchanged) |
| G61 | OQ15 | the residuals: non-identifier names; binutils variables; other Win32 readings; false refusals of the spelling comparison; the script's own repository's guard on a copy; unrelated files of the build's names; planted symlinks | each item marked in place: MAKEOVERRIDES [M] (`pin4/verify/runs/env2-new/`), the false refusal [M] (fn), the rest [S]/[I] (rewritten and extended this round) |

## docs/roadmap.md row 203

| # | claim | backed by |
|---|---|---|
| M1 | Status 2026-10-20 (pin enforced), build-copy round, export check: the measured holes and fixes | the logs each cites, `pin/impl`, `pin2/impl`, `pin3/impl` [M]; run-impl R1-*, R2-*, R3-*, F2-*, F7-*, EI-*, UNP-build, GRADLE-* repeat them on the final text [M] |
| M2 | Round 4: the guards resolve every path with cd -P and compare by identity; the script unsets the variables of a list found to change the build (rewritten from "every variable that make, gcc or ld reads") | `pin4/final/run-impl/` [M]; as G30 |
| M3 | Round 4: "the environment's flags on its list are dropped" (rewritten from "the environment's flags are dropped") | as R9 |
| M4 | Round 4's threat-model sentence, "the build removes or overwrites only its own products", now annotated: its review measured four ways past it and a variable the list missed; round 5 closes them and narrows both claims | `pin4/verify/runs/` [M]; round 5 below |
| M5 | Round 5: the review's measurements on 7c3c2683 (T2 regression, T1, the repository dist, U2L, MAKEOVERRIDES, T4) | `pin4/verify/runs/u3-new/`, `repo-new2/`, `more-new/`, `env2-new/` [M]; ff T1, T2, T4, U2L-*, MO-* FAIL [M] |
| M6 | Round 5: every directory input at its physical path once; trailing dot or space refused; pathkey `?`; MAKEOVERRIDES dropped; the script's own repository guarded | [S] THE INPUT DIRECTORIES, THE DIRECTORIES THIS SCRIPT REMOVES, THE BUILD ENVIRONMENT; run-impl (all lines) [M] |
| M7 | Round 5: final-check2 on 47b9c52e gives 79 PASS, 0 FAIL in 555 s; canonical builds unchanged on both hosts; on 7c3c2683 65 PASS and 14 FAIL, the 14 being the lines for what round 5 adds, round 4's lines and the AlmaLinux 8 replays passing | run-impl summary.txt, ALL.done (`PASS 79 FAIL 0 secs 555 build-native.sh 47b9c52e...`); ff summary.txt, ALL.done (`PASS 65 FAIL 14 secs 687 build-native.sh 7c3c2683...`) [M] |
