# ===========================================================================
#  Makefile -- LuaJIT watchdog prototype (Linux + mingw-w64/MSYS2).
#  Requires GNU make and git. Builds a STATIC LuaJIT v2.1 at a pinned commit
#  in TWO variants and links the harness against each:
#     harness_checkhook   <- LUAJIT_ENABLE_CHECKHOOK (the design)
#     harness_stock       <- no CHECKHOOK (the evasion baseline)
#  GC64 stays ON (x64 default -- required by the counting allocator); we do
#  NOT pass -DLUAJIT_DISABLE_GC64.
# ===========================================================================

LJ_COMMIT := 1ee778a4e37122d8ca7d5733c590a47dafd6b15c
LJ_REPO   := https://github.com/LuaJIT/LuaJIT.git

CC        ?= cc
CFLAGS    := -std=c11 -O2 -Wall -Wextra -I luajit/src
XCFLAGS_CH := -DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_CHECKHOOK
XCFLAGS_ST := -DLUAJIT_ENABLE_LUA52COMPAT

# --- platform detection ---
UNAME_S := $(shell uname -s)
ifneq (,$(findstring MINGW,$(UNAME_S)))
  EXE  := .exe
  # harness takes the _WIN32 branch (Win32 threads); no pthread/dl needed.
  LIBS := -lm
else ifneq (,$(findstring MSYS,$(UNAME_S)))
  EXE  := .exe
  LIBS := -lm
else
  EXE  :=
  LIBS := -lpthread -lm -ldl
endif

CHECKHOOK_BIN := harness_checkhook$(EXE)
STOCK_BIN     := harness_stock$(EXE)

.PHONY: all clean distclean test bench luajit-src
all: $(CHECKHOOK_BIN) $(STOCK_BIN)

# --- 1. fetch LuaJIT at the pinned commit ---
luajit/.stamp:
	@if [ ! -d luajit ]; then echo "[*] cloning LuaJIT ..."; git clone $(LJ_REPO) luajit; fi
	cd luajit && git fetch --all --tags && git checkout $(LJ_COMMIT)
	@touch luajit/.stamp
luajit-src: luajit/.stamp

# --- 2. two static libs. Each recipe cleans, builds with its XCFLAGS, and
#        copies the archive out before the next variant clobbers it. ---
libluajit_checkhook.a: luajit/.stamp
	@echo "[*] building LuaJIT static lib WITH CHECKHOOK ..."
	$(MAKE) -C luajit clean
	$(MAKE) -C luajit BUILDMODE=static XCFLAGS='$(XCFLAGS_CH)'
	cp luajit/src/libluajit.a $@

libluajit_stock.a: luajit/.stamp
	@echo "[*] building LuaJIT static lib WITHOUT CHECKHOOK ..."
	$(MAKE) -C luajit clean
	$(MAKE) -C luajit BUILDMODE=static XCFLAGS='$(XCFLAGS_ST)'
	cp luajit/src/libluajit.a $@

# The two lib recipes both write luajit/src/libluajit.a, so force them to
# run in series (never in parallel) to avoid a race.
libluajit_stock.a: libluajit_checkhook.a

# --- 3. harness against each ---
$(CHECKHOOK_BIN): harness.c libluajit_checkhook.a
	$(CC) $(CFLAGS) harness.c libluajit_checkhook.a $(LIBS) -o $@

$(STOCK_BIN): harness.c libluajit_stock.a
	$(CC) $(CFLAGS) harness.c libluajit_stock.a $(LIBS) -o $@

# --- convenience ---
# The canonical A/B: same script, both builds.
test: all
	@echo "=== CHECKHOOK build: tight loop should be INTERRUPTED ==="
	./$(CHECKHOOK_BIN) --soft-ms 200 --hard-ms 800 --expect interrupt scripts/attack_tight_loop.lua
	@echo
	@echo "=== STOCK build: tight loop is expected to EVADE (hard abort) ==="
	./$(STOCK_BIN)     --soft-ms 200 --hard-ms 800 --expect hard-abort-needed scripts/attack_tight_loop.lua
	@echo
	@echo "=== other attacks (CHECKHOOK build) ==="
	./$(CHECKHOOK_BIN) --expect interrupt scripts/attack_nested_coro.lua
	./$(CHECKHOOK_BIN) --expect interrupt scripts/attack_pcall_swallow.lua
	./$(CHECKHOOK_BIN) --mem-mb 32 --expect memcap scripts/attack_alloc_bomb.lua
	# Measured 2026-09-01: the rep bomb IS interruptible (~6 ms) — the hook lands
	# between C calls, and the memory cap bounds any single call. A truly
	# hard-abort-only case needs one enormous uninterruptible C call.
	./$(CHECKHOOK_BIN) --mem-mb 4096 --soft-ms 50 --hard-ms 300 --expect interrupt scripts/attack_string_bomb.lua

bench: all
	@echo "=== mandelbrot: JIT on (CHECKHOOK) ==="
	./$(CHECKHOOK_BIN) --soft-ms 600000 --expect complete scripts/bench_mandelbrot.lua
	@echo "=== mandelbrot: JIT on (stock) ==="
	./$(STOCK_BIN)     --soft-ms 600000 --expect complete scripts/bench_mandelbrot.lua
	@echo "=== mandelbrot: JIT OFF (interpreter floor) ==="
	./$(STOCK_BIN)     --jitoff --soft-ms 600000 --expect complete scripts/bench_mandelbrot.lua
	@echo "=== numeric/bit loop: JIT on (CHECKHOOK) vs (stock) vs off ==="
	./$(CHECKHOOK_BIN) --soft-ms 600000 --expect complete scripts/bench_numeric.lua
	./$(STOCK_BIN)     --soft-ms 600000 --expect complete scripts/bench_numeric.lua
	./$(STOCK_BIN)     --jitoff --soft-ms 600000 --expect complete scripts/bench_numeric.lua

clean:
	rm -f $(CHECKHOOK_BIN) $(STOCK_BIN) libluajit_checkhook.a libluajit_stock.a *.o

distclean: clean
	rm -rf luajit
