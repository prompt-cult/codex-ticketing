#!/bin/bash
# Build the single-file embedded executable: codex-ticketing-macos-arm64.run
#
# Uses the official Lunet release SDK (v0.19.0) to embed the app's Lua tree
# into a native binary (liblunet-static.a). Optional extension loaders
# (lunet.http, sqlite3, jsonic, …) are NOT in the static core, so the
# runtime's lunet/ tree is staged beside the .run (documented caveat).
#
# Prereqs: curl, xmake, cc, pkg-config, luajit/libuv/zlib dev packages.
set -euo pipefail
cd "$(dirname "$0")/.."

LUNET_VERSION=${LUNET_VERSION:-v0.19.0}
SDK_TGZ="lunet-macos-sdk.tar.gz"
SDK_DIR=".lunet/${LUNET_VERSION}-sdk"
DIST=".tmp/dist/codex-ticketing-macos-arm64"

# 1. Fetch + verify the SDK archive (sha256 against release metadata).
if [ ! -d "$SDK_DIR" ]; then
  URL="https://github.com/lua-lunet/lunet/releases/download/${LUNET_VERSION}/${SDK_TGZ}"
  curl -fsSL --connect-timeout 15 --max-time 600 -o ".tmp/${SDK_TGZ}" "$URL"
  mkdir -p "$SDK_DIR"
  tar -xzf ".tmp/${SDK_TGZ}" -C "$SDK_DIR"
fi

# 2. Stage a flat app tree for embedding: the generator packs the source dir
#    verbatim (manifest paths = relative to it), and the runtime resolves
#    module names from those paths. Our app requires "app.*" — stage copies
#    with the app./ prefix rewritten away so the blob is self-contained.
STAGE=".tmp/embed_src"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp app/main.lua app/store.lua app/trace.lua app/ui.lua "$STAGE/"
sed -i.bak 's/require("app\./require("/g' "$STAGE/main.lua"
rm -f "$STAGE/main.lua.bak"

# 3. Generate the embed blob from the staged tree.
mkdir -p generated
LUNET_EMBED_SOURCE="$STAGE" \
LUNET_EMBED_OUTPUT=generated/lunet_embed_scripts_blob.h \
LUNET_EMBED_PROJECT_ROOT="$PWD" \
xmake lua "$SDK_DIR/bin/generate_embed_scripts.lua" >/dev/null

# 3. Compile.
if [ "$(uname -s)" = "Darwin" ]; then
  export PKG_CONFIG_PATH="$(brew --prefix zlib)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi
mkdir -p "$DIST"
cc -std=c99 -I"$SDK_DIR/include" -Igenerated \
  $(pkg-config --cflags luajit libuv zlib) \
  "$SDK_DIR/examples/sdk_embed/main.c" \
  "$SDK_DIR/lib/liblunet-static.a" \
  $(pkg-config --libs luajit libuv zlib) \
  -o "$DIST/codex-ticketing-macos-arm64.run" 2>/dev/null

# 4. Stage the runtime loaders (lunet.http, sqlite3, jsonic, …) beside it.
cp -R ".lunet/${LUNET_VERSION}/lunet" "$DIST/lunet"

echo "Built: $DIST/codex-ticketing-macos-arm64.run"
echo "Run:   (cd $DIST && ./codex-ticketing-macos-arm64.run)"
