# codex-ticketing Makefile
#
# Consumes the official Lunet runtime as a pinned binary release, per the
# upstream lunet-mcp pattern (vendored fetcher -> .lunet/$(LUNET_VERSION)/).

LUNET_VERSION ?= v0.19.0
FETCHER := ./scripts/lunet_fetch_release_$(LUNET_VERSION).lua

LUA_CMD := $(shell command -v lua 2>/dev/null || command -v luajit 2>/dev/null || echo "")

ifeq ($(OS),Windows_NT)
  LUNET_BIN := .lunet/$(LUNET_VERSION)/lunet-run.exe
else
  LUNET_BIN := .lunet/$(LUNET_VERSION)/lunet-run
endif

.PHONY: all build run run-trace test test-mcp embed clean clean-all

all: help

# Fetch the pinned Lunet runtime release and sync types.
build:
	@if [ -z "$(LUA_CMD)" ]; then \
		echo "ERROR: lua or luajit interpreter not found on PATH" >&2; \
		exit 1; \
	fi
	@"$(LUA_CMD)" "$(FETCHER)" >/dev/null
	@rm -rf types && cp -r .lunet/$(LUNET_VERSION)/types types
	@echo "Build complete. Lunet runner: $(LUNET_BIN)"

run: build
	@"$(LUNET_BIN)" app/main.lua

run-trace: build
	@MCP_TRACE=trace "$(LUNET_BIN)" app/main.lua

test: build
	@PORT=8099 TICKETS_DB=.tmp/tickets_test.db "$(LUNET_BIN)" app/main.lua &

# Full MCP flow test against a running server.
test-mcp:
	@./test/test_mcp_flow.sh

# Build the single-file embedded executable (macOS arm64; see
# scripts/build_embed_macos.sh for prereqs and the runtime-loader caveat).
embed:
	@./scripts/build_embed_macos.sh

clean:
	@rm -rf .tmp/*.log

clean-all: clean
	@rm -rf .lunet types

help:
	@echo "codex-ticketing"
	@echo "  make build        - fetch pinned Lunet runtime ($(LUNET_VERSION))"
	@echo "  make run          - start MCP server (port 8080)"
	@echo "  make run-trace    - start with full tracing"
	@echo "  make test-mcp     - run MCP flow test (server must be running)"
	@echo "  make clean-all    - remove fetched runtime and types"
	@echo "Env: PORT, HOST, TICKETS_DB, MCP_TRACE"
	@echo "DB:  TICKETS_DB env > --repo-local flag > ~/.codex/ticketing/tickets.db (shared default)"
