# Makefile — eris-lj serializer (Track P).
# Builds against native/build-native.sh's LuaJIT BUILD COPY for this platform,
# build/native/luajit-<os>-<arch>/src: the archive the shipped native links,
# with CHECKHOOK, the build copy's LuaJIT patches and the feature set of
# native/luajit/oclj_features.h, which eris_lj.c refuses to compile without.
# Run native/build-native.sh on this platform first (either variant).  Until
# 2026-10-16 this linked ../prototype/watchdog/libluajit_stock.a instead:
# FFI on, LUA52COMPAT but no CHECKHOOK and none of the patches, with eris_lj.c
# compiled against headers that saw no feature flags at all.

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
ifneq (,$(findstring MINGW,$(UNAME_S)))
  OCLJ_OS := windows
  EXE := .exe
  LIBS := -lm
else ifneq (,$(findstring MSYS,$(UNAME_S)))
  OCLJ_OS := windows
  EXE := .exe
  LIBS := -lm
else ifeq (Linux,$(UNAME_S))
  OCLJ_OS := linux
  EXE :=
  # The test runners' one Linux tail (test/native/run.sh says why).
  LIBS := -lm -pthread -ldl
else
  OCLJ_OS := unsupported-$(UNAME_S)
  EXE :=
  LIBS := -lm -pthread -ldl
endif
ifneq (,$(filter x86_64 amd64,$(UNAME_M)))
  OCLJ_ARCH := x86_64
else
  OCLJ_ARCH := unsupported-$(UNAME_M)
endif

OCLJ_BUILD ?= ../build/native
LJSRC := $(OCLJ_BUILD)/luajit-$(OCLJ_OS)-$(OCLJ_ARCH)/src
LJLIB := $(LJSRC)/libluajit.a
# The pinned LuaJIT commit, all 40 digits, stamped into this test host's blob
# fingerprint (the native stamps the checkout's first 8).  THE PIN is one
# file, native/luajit/upstream.commit, found relative to THIS Makefile so
# `make -C serializer` and a make run in this directory read the same file;
# build-native.sh holds the byte-exact check of its format.
LJ_PIN_FILE := $(dir $(lastword $(MAKEFILE_LIST)))../native/luajit/upstream.commit
LJ_COMMIT := $(shell cat '$(LJ_PIN_FILE)' 2>/dev/null)
ifeq ($(shell printf '%s' '$(LJ_COMMIT)' | grep -xE '[0-9a-f]{40}'),)
  $(error the LuaJIT pin $(LJ_PIN_FILE) must hold one commit, 40 lowercase hex digits and a newline; read '$(LJ_COMMIT)')
endif

# The blob fingerprint must name THIS serializer, not just the LuaJIT tree;
# build-native.sh does the same. Without it this path would compile with the
# 'nohash' fallback in eris_lj.c and its blobs could not say what wrote them.
SERHASH := $(shell cat eris_lj.c eris_lj.h | sha1sum | cut -c1-8)

CC     ?= cc
CFLAGS := -std=c11 -O2 -g -Wall -Wextra -I $(LJSRC) \
          -DERIS_LJ_COMMIT='"$(LJ_COMMIT)"'
CFLAGS += -DERIS_LJ_SERHASH='"$(SERHASH)"'

BIN := erislj_test$(EXE)

.PHONY: all test negctl clean
all: $(BIN)

$(BIN): eris_lj.c eris_lj.h test_main.c $(LJLIB)
	$(CC) $(CFLAGS) eris_lj.c test_main.c $(LJLIB) $(LIBS) -o $@

$(LJLIB):
	@echo "Missing $(LJLIB) -- run native/build-native.sh first, on this platform ($(OCLJ_OS)-$(OCLJ_ARCH)), or pass OCLJ_BUILD=<the OCLJ_BUILD it used>"
	@false

test: $(BIN)
	./$(BIN) tests/m1.lua
	./$(BIN) tests/m2.lua
	./$(BIN) tests/m3.lua
	./$(BIN) tests/contract.lua
	./$(BIN) tests/stack-universe.lua
	./$(BIN) tests/fingerprint.lua
	./$(BIN) tests/strpack.lua
	./$(BIN) tests/bitop.lua
	BIN=./$(BIN) sh tests/run-forin.sh

# Proves fingerprint.lua and test_main.c's layout gate can fail
# (tests/negctl-fingerprint.sh); its copies go under $(OCLJ_BUILD).
negctl: $(LJLIB)
	LJSRC='$(LJSRC)' OCLJ_BUILD='$(OCLJ_BUILD)' CC='$(CC)' NEGCTL_LIBS='$(LIBS)' sh tests/negctl-fingerprint.sh

clean:
	rm -f $(BIN)
	rm -rf .forin
