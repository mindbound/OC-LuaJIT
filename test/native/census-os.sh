#!/bin/sh
# test/native/census-os.sh -- boot a real third-party OpenComputers OS on our
# native and report what it costs.
#
#     sh test/native/census-os.sh <kernel-root> <name> <eeprom.lua> [ticks]
#
# It is a thin wrapper over smoke-test.sh, which does all the work that is the
# same whatever we boot: the classpath, the generated ocelot-brain config, the
# ramScale pin, and the native selection.  A separate driver would be a second
# copy of that and would drift.
#
# WHY IT EXISTS.  The previous runner for this lived in ocelot-brain's demo
# tree as totoro.ocelot.demo.CustomOs.  It is gone, and it took with it the
# ability to check its one finding: axis-os panicking with "not enough memory"
# four times during PatchGuard's Tier3 file hashing (2026-09-02).  That is the
# same durability failure bench/runs/ exists to prevent, one layer up -- the
# TOOL was lost, not just the output.  This one is in the repository.
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ $# -ge 3 ] || { echo "usage: census-os.sh <kernel-root> <name> <eeprom.lua> [ticks]" >&2; exit 2; }
ROOT=$1; NAME=$2; EEPROM=$3; TICKS=${4:-2000}
[ -d "$ROOT" ]   || { echo "census-os.sh: no kernel root at $ROOT" >&2; exit 2; }
case "$EEPROM" in bios|-) ;; *) [ -f "$EEPROM" ] || { echo "census-os.sh: no eeprom at $EEPROM (pass 'bios' for OC's Lua BIOS)" >&2; exit 2; };; esac
export OCLJ_SRC="$SELF_DIR/CensusOs.scala"
export OCLJ_MAIN="ocljit.census.CensusOs"
export OCLJ_MAIN_CLASSFILE='ocljit/census/CensusOs$.class'
export OCLJ_MAIN_ARGS="$ROOT $NAME $EEPROM $TICKS"
exec sh "$SELF_DIR/smoke-test.sh"
