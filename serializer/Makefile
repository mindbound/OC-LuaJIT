# Makefile — eris-lj serializer (Track P).
# Links against the pinned LuaJIT already built by ../prototype/watchdog.

LJDIR := ../prototype/watchdog/luajit
LJSRC := $(LJDIR)/src
LJLIB := ../prototype/watchdog/libluajit_stock.a
LJ_COMMIT := 1ee778a4e37122d8ca7d5733c590a47dafd6b15c

CC     ?= cc
CFLAGS := -std=c11 -O2 -g -Wall -Wextra -I $(LJSRC) \
          -DERIS_LJ_COMMIT='"$(LJ_COMMIT)"'

UNAME_S := $(shell uname -s)
ifneq (,$(findstring MINGW,$(UNAME_S)))
  EXE := .exe
  LIBS := -lm
else ifneq (,$(findstring MSYS,$(UNAME_S)))
  EXE := .exe
  LIBS := -lm
else
  EXE :=
  LIBS := -lpthread -lm -ldl
endif

BIN := erislj_test$(EXE)

.PHONY: all test clean
all: $(BIN)

$(BIN): eris_lj.c eris_lj.h test_main.c $(LJLIB)
	$(CC) $(CFLAGS) eris_lj.c test_main.c $(LJLIB) $(LIBS) -o $@

$(LJLIB):
	@echo "Missing $(LJLIB) — build it first: (cd ../prototype/watchdog && make all)"
	@false

test: $(BIN)
	./$(BIN) tests/m1.lua

clean:
	rm -f $(BIN)
