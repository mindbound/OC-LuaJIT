#!/bin/sh
# ffrun.sh <case> <base|proto> -- one fail-first: a mutated copy of the
# round's test/native (ffmut.py) under ff/<case>, its run-bitjit.sh part
# cse on build/native (base, read only) or the prototype (proto) into
# runs/ff-<case>; the verdict lines on stdout.
set -u
T=/c/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests
C=${1:?usage: ffrun.sh <case> <base|proto>}
case ${2:?usage: ffrun.sh <case> <base|proto>} in
  base) B=/c/Users/astro/Downloads/OC-LuaJIT/build/native ;;
  proto) B=$T/proto-fix ;;
  *) echo "base or proto"; exit 98 ;;
esac
python "$T/scripts/ffmut.py" "$C" "$T/ff/$C" || exit 98
sh "$T/scripts/csepart.sh" "ff-$C" "$B" cse "$T/ff/$C"
