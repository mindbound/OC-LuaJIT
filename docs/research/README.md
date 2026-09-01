# Research reports

Raw per-arm reports from the multi-agent studies (2026-09-01), preserved verbatim
with their file:line citations and adversarial-verification appendices. The digests
live in ../feasibility.md, ../watchdog.md, ../persistence-study.md; these are the
full evidence base.

- `report-*.md` — study 1: overall feasibility (CCLuaJIT internals, OC architecture
  API, Eris/JNLua persistence, OpenPython/OC-Wasm precedents, GTNH build
  practicalities, language compat & performance).
- `wd-*.md` — study 2: the timeout watchdog (CHECKHOOK internals, async-interrupt
  precedents, evasion threat model, prototype harness design).
- `ps-*.md` — study 3: full-VM persistence (object-model serialization map,
  suspended-coroutine frame schema, Eris anatomy & the OC contract, serializer
  foundations & prior art, scope/risk/milestones). ps-coroutine-frames.md contains
  the M0/M3 frame schema including the verifier's cont_stitch amendment.
