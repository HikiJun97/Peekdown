#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
DIST_DIR="$PROJECT_ROOT/dist"
PKG_ID="io.github.hikijun97.peekdown"
VERSION="0.1.0"

echo "=== Peekdown PKG Installer Creation ==="

if [ ! -d "$BUILD_DIR/Peekdown.app" ]; then
    echo "Error: Peekdown.app not found. Run build.sh first."
    exit 1
fi

mkdir -p "$DIST_DIR"

# Payload: install app to /Applications
PAYLOAD_DIR=$(mktemp -d)
mkdir -p "$PAYLOAD_DIR/Applications"
cp -R "$BUILD_DIR/Peekdown.app" "$PAYLOAD_DIR/Applications/"

# Postinstall: register app with Launch Services + reset QuickLook
# make install(scripts/install.sh)과 같은 스크립트를 쓴다
SCRIPTS_DIR=$(mktemp -d)
cp "$PROJECT_ROOT/scripts/postinstall.sh" "$SCRIPTS_DIR/postinstall"
chmod +x "$SCRIPTS_DIR/postinstall"

pkgbuild \
    --root "$PAYLOAD_DIR" \
    --scripts "$SCRIPTS_DIR" \
    --identifier "$PKG_ID" \
    --version "$VERSION" \
    --install-location "/" \
    "$DIST_DIR/Peekdown.pkg"

rm -rf "$PAYLOAD_DIR" "$SCRIPTS_DIR"

echo "=== PKG created: $DIST_DIR/Peekdown.pkg ==="
