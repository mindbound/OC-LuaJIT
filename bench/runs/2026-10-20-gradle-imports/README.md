# 2026-10-20 -- gradle refuses a Linux .so with an unversioned import

The evidence behind the glibc row's closed item 3 in [docs/roadmap.md](../../../docs/roadmap.md) ("Whether
gradle should also refuse unversioned imports").

- **The defect.** `native/build-native.sh` refuses a .so with a non-weak import that carries no symbol version
  (its ELF import gate, added by the glibc round). But `verifyModAssets` packages whatever sits in
  `build/native/dist`, and it did not check imports. The AlmaLinux 8 trial .so, linked with round 3's flags
  and so with six pthread imports without a version, passed every gradle check, because its serializer hash
  and VM-features word are this tree's.
- **The change** (`build.gradle.kts`, md5 `942605fc`, +105/-8):
  - Inside the existing ELF check, gradle reads the single `SHT_DYNSYM` section (24-byte entries, a string
    table in range) and the `SHT_GNU_versym` section (one 16-bit entry per symbol).
  - It refuses any undefined, non-weak, named symbol whose version index, masked with 0x7fff, is 0 or 1. A
    .so without `.gnu.version` counts every such import as unversioned.
  - An index of 2 or more that no `.gnu.version_r` entry defines is refused as corrupt, and so is a
    `.dynsym` with no imports at all, so the check cannot pass vacuously.
  - Every read is bounds-checked and every loop bounded, as in the floor check.
  - The refusal names the symbols, at most 12. The passing line gains "N imports, every non-weak one
    versioned (weak and unversioned: ...)".
  - The import verdict comes after the glibc-floor verdicts, so every .so the floor refused before is refused
    in the same words.

Implemented on c813296 (the glibc round, committed), uncommitted.

## Results

The real task, `./gradlew --offline --no-daemon verifyModAssets`, on fresh natives directories (`logs/`):

| natives | HEAD's `build.gradle.kts` (`67153bd5`) | this one |
|---|---|---|
| the AlmaLinux 8 trial .so (`bf0d0916`) | BUILD SUCCESSFUL (`head-trial.log`) | refused: `imports 6 symbols with NO version: pthread_attr_setstacksize, pthread_condattr_setclock, pthread_create, pthread_join, pthread_setname_np, pthread_sigmask` (`trial.log`) |
| the release .so (`6c888050`) | -- | accepted: `needs at most GLIBC_2.17 ...; 110 imports, every non-weak one versioned (weak and unversioned: _ITM_deregisterTMCloneTable, _ITM_registerTMCloneTable, __gmon_start__)` (`release.log`) |
| the default `build/native/dist` (the release .so and the Windows DLL `3174ef37`) | -- | accepted, the same line (`dist.log`) |

- **The jar builds** (`build.log`): `ocluajit-c813296-master+c8132963ba-dirty.jar`, md5 `bb1bf51f`.
- **The fail-first's swap was restored exactly.** HEAD's `build.gradle.kts` was put in place for the one
  `head-trial` run, then the new file restored and checked by `cmp` (`summary.txt`: `restored
  build.gradle.kts: 942605fc`).

The implementer's and the verifier's evidence is in `design/reports.json`. It was produced in
`claude-tmp/oclj/gradle-unv/`.

- **Mutants of the release .so, real task:**
  - Refused as unversioned, each naming the symbol: an import's version set to 1, set to 0, set to 0x8001
    (hidden bit, masking to 1), or the whole `.gnu.version` hidden.
  - Accepted: a weak import's version set to 1, and the hidden bit on a valid index.
  - Refused as unreadable, each with gradle's own reason: a wrong `sh_entsize`, a mismatched versym size,
    `sh_link` out of range, a name past its string table, a dangling version index, two `.dynsym`
    sections, no imports at all, and extreme sizes and offsets. No log shows exception text, and none
    hung.
- **No regression.** The glibc round's 34 gradle cases give their old verdicts and messages. The only
  differences are the trial .so, now refused, and the import count on passing lines.
- **The adversarial verifier.**
  - It built a faithful Python reimplementation of the new block. It reproduces the real task's verdict on
    all 29 real-task cases.
  - Against readelf it found no false accept and no false refuse over 3219 real files: AlmaLinux 8's and
    Ubuntu's libraries and binaries, and OC's own stock `libjnlua52-linux-x86_64.so` (which passes).
  - **A shared limitation, outside the threat model.** gradle, readelf and `build-native.sh`'s gate find
    `.gnu.version` through the section headers, while the dynamic loader uses `DT_VERSYM`. A deliberately
    inconsistent ELF could therefore pass all three. That is not a stale or mis-linked build, which is what
    this gate is for.

| path | what |
|---|---|
| `logs/` | `summary.txt`; `trial.log`, `release.log`, `dist.log`, `head-trial.log`, `build.log`; `inputs.md5` (the .so files, dist, both `build.gradle.kts` versions); `build.gradle.kts.new` (the file restored after the swap) |
| `design/reports.json` | the implementer's and the adversarial verifier's reports |
| `scripts/check.sh` | this run |

The two .so copies the run used were moved out of the archive, to
`claude-tmp/oclj/gradle-unv/archive-binaries/`; their md5s are in `logs/inputs.md5`.
