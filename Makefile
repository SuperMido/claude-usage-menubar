.PHONY: build test install uninstall clean

BIN := build/ClaudeUsage
SRC := menubar/ClaudeUsage.swift

build: $(BIN)

$(BIN): $(SRC)
	@mkdir -p build
	swiftc -O $(SRC) -o $(BIN) -framework AppKit

test: build
	./tests/run.sh

install:
	./install.sh

uninstall:
	./uninstall.sh

clean:
	rm -rf build
