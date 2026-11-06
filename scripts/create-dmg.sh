#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/dist"
DMG_NAME="Peekdown.dmg"

echo "=== Peekdown DMG Creation ==="

# Check pkg exists
if [ ! -f "$DIST_DIR/Peekdown.pkg" ]; then
    echo "Error: Peekdown.pkg not found. Run create-pkg.sh first."
    exit 1
fi

rm -f "$DIST_DIR/$DMG_NAME"

# DMG contains just the .pkg installer
TEMP_DIR=$(mktemp -d)
cp "$DIST_DIR/Peekdown.pkg" "$TEMP_DIR/"

hdiutil create \
    -volname "Peekdown Installer" \
    -srcfolder "$TEMP_DIR" \
    -ov \
    -format UDZO \
    "$DIST_DIR/$DMG_NAME"

rm -rf "$TEMP_DIR"

echo "=== DMG created: $DIST_DIR/$DMG_NAME ==="
echo "사용자: DMG 열기 → Peekdown.pkg 더블클릭 → 설치 완료"
