#!/bin/sh
# build.sh <dropin|additive> <log>
# build-native.sh on Windows with this box's toolchain; make is a shim over mingw32-make.
set -u
case "$2" in /*) LOGF="$2";; *) LOGF="$(pwd)/$2";; esac
export PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export OCLJ_JNLUA=C:/Users/astro/Downloads/OC-JNLua
export OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include"
export OCLJ_VARIANT="$1"
export OCLJ_PYTHON=python
cd /c/Users/astro/Downloads/OC-LuaJIT || exit 97
{
  date -u +%Y-%m-%dT%H:%M:%SZ
  sh native/build-native.sh
  echo "=== exit $? ==="
  date -u +%Y-%m-%dT%H:%M:%SZ
} > "$LOGF" 2>&1
