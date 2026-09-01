# Makefile — M0 frame-walk validation spike.
# Reuses the LuaJIT tree already cloned/built by ../watchdog (pinned 1ee778a4).
# framewalk uses PRIVATE headers (lj_obj.h, lj_frame.h, lj_vm.h), so it must be
# compiled against the same source tree and linked to that static lib.

LJDIR := ../watchdog/luajit
LJSRC := $(LJDIR)/src
LJLIB := ../watchdog/libluajit_stock.a

CC     ?= cc
CFLAGS := -std=c11 -O2 -g -Wall -Wextra -I $(LJSRC)

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

BIN := framewalk$(EXE)

.PHONY: all run clean
all: $(BIN)

$(BIN): framewalk.c $(LJLIB)
	$(CC) $(CFLAGS) framewalk.c $(LJLIB) $(LIBS) -o $@

$(LJLIB):
	@echo "Missing $(LJLIB) — build it first: (cd ../watchdog && make all)"
	@false

run: $(BIN)
	./$(BIN)

clean:
	rm -f $(BIN)
