# M3 restore-path probes. Reuse the LuaJIT tree built by ../watchdog.
LJSRC := ../watchdog/luajit/src
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
PROBES := coclone$(EXE) coclone2$(EXE) probe3$(EXE)
.PHONY: all run clean
all: $(PROBES)
%$(EXE): %.c $(LJLIB)
	$(CC) $(CFLAGS) $< $(LJLIB) $(LIBS) -o $@
run: all
	@for p in $(PROBES); do echo "==== $$p ===="; ./$$p; echo; done
clean:
	rm -f $(PROBES)
