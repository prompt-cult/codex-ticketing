#!/bin/bash
set -e

CALLER_DIR="$PWD"

cd "$(dirname "$0")"

if [ -f ".env" ]; then
	set -a
	source .env
	set +a
fi

PORT=${PORT:-8080}
HOST=${HOST:-127.0.0.1}
MCP_TRACE=${MCP_TRACE:-off}
LUNET_VERSION=${LUNET_VERSION:-v0.19.0}

# DB location is resolved by app/main.lua:
#   TICKETS_DB env   -> exact path as given (wins over everything)
#   --repo-local     -> <git repo root>/.ticketing/tickets.db
#   default          -> ~/.codex/ticketing/tickets.db (shared, created at startup)
# For --repo-local the invoking caller's repo root is discovered here, before
# the cd above; with TICKETS_DB already set the env path wins and the flag is
# a no-op. main.lua also ensures the parent directory exists.
if [ -n "${TICKETS_DB:-}" ]; then
	export TICKETS_DB
elif [ "$1" = "--repo-local" ] || printf '%s\n' "$@" | grep -q -x -- --repo-local; then
	REPO_ROOT=$(cd "$CALLER_DIR" && git rev-parse --show-toplevel 2>/dev/null || echo "$CALLER_DIR")
	export TICKETS_DB="$REPO_ROOT/.ticketing/tickets.db"
fi

export PORT HOST MCP_TRACE

echo "Starting codex-ticketing MCP server..."
echo "Port: $PORT  DB: caller-set TICKETS_DB or main.lua default  Trace: $MCP_TRACE"

LUNET_BIN=".lunet/${LUNET_VERSION}/lunet-run"
if [ ! -f "$LUNET_BIN" ] && [ -f "./lunet-run" ]; then
	# Release bundle layout: the runtime sits at the bundle root.
	LUNET_BIN="./lunet-run"
fi
if [ ! -f "$LUNET_BIN" ] && [ -f "./bin/lunet" ]; then
	LUNET_BIN="./bin/lunet"
fi

if [ ! -f "$LUNET_BIN" ]; then
	echo "Lunet binary not found at $LUNET_BIN. Running make build..."
	make build
fi

if [ -f "$LUNET_BIN" ]; then
	exec "$LUNET_BIN" app/main.lua "$@"
else
	echo "ERROR: lunet binary not found at $LUNET_BIN"
	exit 1
fi
