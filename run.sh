#!/bin/bash
set -e

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
TICKETS_DB=${TICKETS_DB:-.lunet/tickets.db}

export PORT HOST MCP_TRACE TICKETS_DB

echo "Starting codex-ticketing MCP server..."
echo "Port: $PORT  Store: $TICKETS_DB  Trace: $MCP_TRACE"

LUNET_BIN=".lunet/${LUNET_VERSION}/lunet-run"
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
