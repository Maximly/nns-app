CC ?= clang
CFLAGS = -O2 -Wall -Wextra -Werror -std=c11
BIN = bin
# Informational; C tools do not embed a version string today. build.sh reads
# the same repo-root VERSION when packaging installers.
VERSION := $(shell tr -d '[:space:]\r' < ../VERSION)

.PHONY: all clean test
all: $(BIN)/nns-run $(BIN)/libnnsbind.dylib
	@printf 'macos binaries ready (nns-app %s)\n' '$(VERSION)'
$(BIN):
	mkdir -p $@
$(BIN)/nns-run: src/nns-run.c src/nns_net.h | $(BIN)
	$(CC) $(CFLAGS) -o $@ $<
$(BIN)/libnnsbind.dylib: src/libnnsbind.c src/nns_net.h | $(BIN)
	$(CC) $(CFLAGS) -dynamiclib -o $@ $<
clean:
	rm -rf $(BIN)
test:
	bash -n nns-app-darwin.sh install.sh
	./tests/test-static.sh
