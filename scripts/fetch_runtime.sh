#!/bin/bash
# fetch_runtime.sh — fetch, digest-verify and extract the pinned upstream
# lua-lunet/lunet runtime release (the shell twin of the official
# lunet_fetch_release lua script, for CI runners without a lua interpreter).
#
# Usage: fetch_runtime.sh [platform] [dest_dir]
#   platform:  macos | linux-amd64 | linux-arm64 | windows-amd64
#              (default: detect the host)
#   dest_dir:  extraction target (default: .lunet/<LUNET_VERSION>/)
#
# The archive's SHA-256 is verified against the digest GitHub publishes per
# asset on the release API (fail-closed: no digest -> abort).
set -euo pipefail

LUNET_VERSION=${LUNET_VERSION:-v0.19.0}
LUNET_REPO="lua-lunet/lunet"

PLATFORM=${1:-}
if [ -z "$PLATFORM" ]; then
  case "$(uname -s)/$(uname -m)" in
    Darwin/arm64|Darwin/x86_64) PLATFORM=macos ;;
    Linux/x86_64)               PLATFORM=linux-amd64 ;;
    Linux/aarch64|Linux/arm64)  PLATFORM=linux-arm64 ;;
    MINGW*|MSYS*|Windows*)      PLATFORM=windows-amd64 ;;
    *) echo "unsupported host: $(uname -s)/$(uname -m); pass a platform" >&2; exit 1 ;;
  esac
fi

case "$PLATFORM" in
  macos)         ASSET="lunet-macos.tar.gz" ;;
  linux-amd64)   ASSET="lunet-linux-amd64.tar.gz" ;;
  linux-arm64)   ASSET="lunet-linux-arm64.tar.gz" ;;
  windows-amd64) ASSET="lunet-windows-amd64.zip" ;;
  *) echo "unknown platform: $PLATFORM" >&2; exit 1 ;;
esac

DEST=${2:-".lunet/${LUNET_VERSION}"}

EXPECTED=$(curl -fsSL --connect-timeout 15 --max-time 30 \
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

TMPDIR_FETCH="${TMPDIR:-/tmp}"
mkdir -p "$TMPDIR_FETCH" "$DEST"
ARCHIVE="$TMPDIR_FETCH/$ASSET"
URL="https://github.com/${LUNET_REPO}/releases/download/${LUNET_VERSION}/${ASSET}"
if [ -f "$ARCHIVE" ]; then
  ACTUAL=$(shasum -a 256 "$ARCHIVE" 2>/dev/null | cut -d' ' -f1 \
    || sha256sum "$ARCHIVE" | cut -d' ' -f1)
else
  ACTUAL=""
fi
if [ "$ACTUAL" != "$EXPECTED" ]; then
  curl -fsSL --connect-timeout 15 --max-time 600 -o "$ARCHIVE" "$URL"
  ACTUAL=$(shasum -a 256 "$ARCHIVE" 2>/dev/null | cut -d' ' -f1 \
    || sha256sum "$ARCHIVE" | cut -d' ' -f1)
fi
if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "SHA-256 mismatch for $ASSET" >&2
  echo "  expected: $EXPECTED" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi
echo "[fetch] digest verified: $ASSET"

if [ "$PLATFORM" = "windows-amd64" ]; then
  unzip -q -o "$ARCHIVE" -d "$DEST" 2>/dev/null \
    || 7z x -y -o"$DEST" "$ARCHIVE" >/dev/null \
    || tar -xf "$ARCHIVE" -C "$DEST"
else
  tar -xzf "$ARCHIVE" -C "$DEST"
fi
echo "[fetch] installed ${LUNET_VERSION} ($PLATFORM) -> $DEST"
