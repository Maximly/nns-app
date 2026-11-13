CC ?= clang
CFLAGS = -O2 -Wall -Wextra -Werror -std=c11
BIN = bin

.PHONY: all clean test
all: $(BIN)/nns-run $(BIN)/libnnsbind.dylib
$(BIN):
	mkdir -p $@
$(BIN)/nns-run: src/nns-run.c | $(BIN)
	$(CC) $(CFLAGS) -o $@ $<
$(BIN)/libnnsbind.dylib: src/libnnsbind.c | $(BIN)
	$(CC) $(CFLAGS) -dynamiclib -o $@ $<
clean:
	rm -rf $(BIN)
test:
	bash -n nns-app-darwin.sh install.sh
	./tests/test-static.sh
