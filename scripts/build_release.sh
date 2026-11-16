#!/bin/bash
# build_release.sh — stage and archive a codex-ticketing release bundle for one
# platform, following the lua-lunet/lunet-mcp release pattern (4-platform
# archives, sha256 digest per asset).
#
# Usage: build_release.sh <platform>
#   platform: macos | linux-amd64 | linux-arm64 | windows-amd64
#
# Bundle layout (same for every platform):
#   app/                       our Lua server (main, store, trace, ui)
#   lunet-run[.exe] + lunet/   upstream lua-lunet/lunet v0.19.0 runtime tree
#                              (incl. the sqlite3 driver cdylib)
#   run.sh / run.cmd           launcher
#   plugin.json, mcp.json,     codex plugin packaging (local marketplace)
#   skills/, .agents/
#   README.md, README-CN.md
#
# The runtime archive is fetched from the pinned upstream release and its
# SHA-256 is verified against the digest GitHub publishes per asset
# (fail-closed, same as the official lunet_fetch_release script).
#
# Output: .tmp/dist/codex-ticketing-<platform>/ containing
#   codex-ticketing-<platform>.tar.gz  (.zip for windows)
#   codex-ticketing-<platform>.sha256
set -euo pipefail

LUNET_VERSION=${LUNET_VERSION:-v0.19.0}
LUNET_REPO="lua-lunet/lunet"
PLATFORM=${1:?usage: build_release.sh <macos|linux-amd64|linux-arm64|windows-amd64>}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/.tmp/dist"
WORK="$DIST/stage-$PLATFORM"

case "$PLATFORM" in
  macos)        ASSET="lunet-macos.tar.gz" ;;
  linux-amd64)  ASSET="lunet-linux-amd64.tar.gz" ;;
  linux-arm64)  ASSET="lunet-linux-arm64.tar.gz" ;;
  windows-amd64) ASSET="lunet-windows-amd64.zip" ;;
  *) echo "unknown platform: $PLATFORM" >&2; exit 1 ;;
esac

# ── 1. Fetch + verify the pinned runtime archive ────────────────────────────
mkdir -p "$DIST"
ARCHIVE="$DIST/$ASSET"
if [ ! -f "$ARCHIVE" ]; then
  echo "[release] fetching $ASSET"
  curl -fsSL --connect-timeout 15 --max-time 600 -o "$ARCHIVE" \
    "https://github.com/${LUNET_REPO}/releases/download/${LUNET_VERSION}/${ASSET}"
fi
echo "[release] verifying digest for $ASSET"
EXPECTED=$(curl -fsSL --max-time 30 \
  "https://api.github.com/repos/${LUNET_REPO}/releases/tags/${LUNET_VERSION}" \
  | python3 -c "
import json, sys
for a in json.load(sys.stdin)['assets']:
    if a['name'] == '${ASSET}':
        d = a.get('digest') or ''
        assert d.startswith('sha256:'), 'no sha256 digest published for ${ASSET}'
        print(d[7:])
        break
else:
    raise SystemExit('asset ${ASSET} not in release ${LUNET_VERSION}')
")
ACTUAL=$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)
if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "SHA-256 mismatch for $ASSET" >&2
  echo "  expected: $EXPECTED" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi
echo "[release] digest verified"

# ── 2. Stage the bundle ──────────────────────────────────────────────────────
rm -rf "$WORK"
mkdir -p "$WORK"
if [ "$PLATFORM" = "windows-amd64" ]; then
  unzip -q "$ARCHIVE" -d "$WORK"
else
  tar -xzf "$ARCHIVE" -C "$WORK"
fi
# Keep the runtime tree's docs/types out of the bundle: our README ships, and
# types/ is a development aid only (not needed at runtime).
find "$WORK" -maxdepth 1 \( -name '*.md' -o -name 'types' \) ! -name 'README.md' ! -name 'README-CN.md' -exec rm -rf {} +

cp -R "$ROOT/app" "$WORK/app"
cp "$ROOT/plugin.json" "$ROOT/mcp.json" "$ROOT/run.sh" \
   "$ROOT/README.md" "$ROOT/README-CN.md" "$WORK/"
cp -R "$ROOT/skills" "$WORK/skills"
mkdir -p "$WORK/.agents/plugins"
cp "$ROOT/.agents/plugins/marketplace.json" "$WORK/.agents/plugins/marketplace.json"
cp "$ROOT/test/test_mcp_flow.sh" "$WORK/test_mcp_flow.sh" 2>/dev/null || true

if [ "$PLATFORM" = "windows-amd64" ]; then
  cat > "$WORK/run.cmd" <<'CMD'
@echo off
cd /d "%~dp0"
if not defined PORT set PORT=8080
if not defined HOST set HOST=127.0.0.1
if not defined TICKETS_DB set TICKETS_DB=.lunet\tickets.db
lunet-run.exe app\main.lua %*
CMD
fi
find "$WORK" -name '*.lua' -exec sh -c 'chmod 644 "$1"' _ {} \;
chmod +x "$WORK"/run.sh "$WORK"/test_mcp_flow.sh 2>/dev/null || true

# ── 3. Archive + digest ──────────────────────────────────────────────────────
OUT="$DIST/codex-ticketing-$PLATFORM"
rm -f "$OUT".tar.gz "$OUT".zip "$OUT".sha256
cd "$WORK"
if [ "$PLATFORM" = "windows-amd64" ]; then
  zip -q -r "$OUT.zip" .
  ( cd "$DIST" && shasum -a 256 "codex-ticketing-$PLATFORM.zip" \
      > "codex-ticketing-$PLATFORM.sha256" )
  echo "[release] built $OUT.zip"
else
  tar -czf "$OUT.tar.gz" .
  ( cd "$DIST" && shasum -a 256 "codex-ticketing-$PLATFORM.tar.gz" \
      > "codex-ticketing-$PLATFORM.sha256" )
  echo "[release] built $OUT.tar.gz"
fi
