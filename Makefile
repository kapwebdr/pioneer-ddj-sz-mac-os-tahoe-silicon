# Native macOS build. No Rosetta, no Pioneer private framework.
CC      ?= clang
ARCH    ?= $(shell uname -m)
PREFIX  ?= /usr/local

CFLAGS  ?= -std=c11 -Wall -Wextra -O2 -fobjc-arc -arch $(ARCH)
LDFLAGS ?= -framework Foundation -framework IOKit -framework IOUSBHost -framework CoreFoundation

SRC := src/ddj_sz_routing.m
BIN := ddj-sz-routing

.PHONY: all clean install

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRC)

install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/$(BIN)

clean:
	rm -f $(BIN)
