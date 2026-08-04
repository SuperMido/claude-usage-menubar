.PHONY: build test install uninstall run start stop restart status clean

BIN   := build/ClaudeUsage
SRC   := menubar/ClaudeUsage.swift
LABEL := com.claude-code.usage-menubar
PLIST := $(HOME)/Library/LaunchAgents/$(LABEL).plist
GUI    = gui/$(shell id -u)

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

## run this checkout in the foreground (Ctrl-C to stop)
run: build
	@pgrep -qf '$(HOME)/.claude/menubar/ClaudeUsage' \
		&& echo "note: the installed copy is running too, so you'll see two items — 'make stop' hides it" || true
	$(BIN)

## start the installed app (also restarts it if already running)
start:
	@launchctl kickstart -k $(GUI)/$(LABEL) 2>/dev/null \
		|| launchctl bootstrap $(GUI) $(PLIST)
	@echo "started"

## stop the installed app until the next login
stop:
	@launchctl bootout $(GUI)/$(LABEL) 2>/dev/null || true
	@echo "stopped"

restart: start

## is it running?
status:
	@launchctl print $(GUI)/$(LABEL) 2>/dev/null | grep -E '^[[:space:]]+(state|pid|runs) ' \
		|| echo "not loaded — 'make start' to load it, or './install.sh' if never installed"

clean:
	rm -rf build
