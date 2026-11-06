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
SCRIPTS_DIR=$(mktemp -d)
cat > "$SCRIPTS_DIR/postinstall" << 'POSTINSTALL'
#!/bin/bash
# Register app so it appears in "Open With" and QL extension is activated
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Peekdown.app 2>/dev/null || true
/usr/bin/qlmanage -r 2>/dev/null || true
/usr/bin/qlmanage -r cache 2>/dev/null || true
# Open the app briefly to register the extension, then quit
open -a /Applications/Peekdown.app 2>/dev/null || true
sleep 2
osascript -e 'tell application "Peekdown" to quit' 2>/dev/null || true
exit 0
POSTINSTALL
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
