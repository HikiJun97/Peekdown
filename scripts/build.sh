#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/Peekdown.app"
EXT_BUNDLE="$APP_BUNDLE/Contents/PlugIns/QLMarkdownPreview.appex"

echo "=== Peekdown Build ==="

rm -rf "$APP_BUNDLE"

# --- 1. Build App ---
echo "[1/5] Building Peekdown.app..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$PROJECT_ROOT/AppInfo.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_ROOT/resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$PROJECT_ROOT/resources/mermaid.min.js" "$PROJECT_ROOT/resources/mermaid-LICENSE.txt" "$APP_BUNDLE/Contents/Resources/"
cp "$PROJECT_ROOT/vendor/cmark-gfm/COPYING" "$APP_BUNDLE/Contents/Resources/cmark-gfm-LICENSE.txt"
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Apple silicon(arm64) 전용으로 빌드한다. Intel Mac은 지원하지 않는다.
OBJ_DIR="$BUILD_DIR/obj"
mkdir -p "$OBJ_DIR"
TARGET="arm64-apple-macosx13.0"

# 마크다운 파서 cmark-gfm(C)을 정적 라이브러리로 빌드한다
CMARK_DIR="$PROJECT_ROOT/vendor/cmark-gfm"
CMARK_LIB="$OBJ_DIR/libcmark-gfm.a"
CMARK_SWIFT_FLAGS=(-I "$CMARK_DIR" -Xcc "-I$CMARK_DIR/src" -Xcc "-I$CMARK_DIR/extensions" -Xcc -DCMARK_GFM_STATIC_DEFINE)
# 이전 빌드의 .o가 섞여 들어가지 않게 매번 비운다
rm -rf "$OBJ_DIR/cmark"
mkdir -p "$OBJ_DIR/cmark"
PIDS=()
for SRC in "$CMARK_DIR"/src/*.c "$CMARK_DIR"/extensions/*.c; do
    # -w: 외부 코드(cmark-gfm)의 경고는 우리가 고칠 대상이 아니라 끈다
    clang -target "$TARGET" -O2 -w -DNDEBUG -DCMARK_GFM_STATIC_DEFINE \
        -I "$CMARK_DIR/src" -I "$CMARK_DIR/extensions" \
        -c -o "$OBJ_DIR/cmark/$(basename "$SRC" .c).o" "$SRC" &
    PIDS+=($!)
done
# 인자 없는 wait는 실패를 놓치므로 하나씩 기다린다. 하나라도 실패하면 set -e로 멈춘다
for PID in "${PIDS[@]}"; do wait "$PID"; done
libtool -static -no_warning_for_no_symbols -o "$CMARK_LIB" "$OBJ_DIR/cmark"/*.o

# 렌더러(Swift)를 ObjC 앱에서 부를 수 있게 헤더를 만든다
swiftc \
    -target "$TARGET" \
    -module-name MdairShared \
    -parse-as-library \
    -typecheck \
    -emit-objc-header-path "$OBJ_DIR/MdairShared-Swift.h" \
    "${CMARK_SWIFT_FLAGS[@]}" \
    "$PROJECT_ROOT/src/MdairRender.swift"

clang \
    -target "$TARGET" \
    -fobjc-arc \
    -fmodules \
    -I "$OBJ_DIR" \
    -c -o "$OBJ_DIR/AppMain.o" \
    "$PROJECT_ROOT/src/AppMain.m"
swiftc \
    -target "$TARGET" \
    -module-name MdairShared \
    -parse-as-library \
    -framework Cocoa \
    -framework WebKit \
    -o "$APP_BUNDLE/Contents/MacOS/Peekdown" \
    "${CMARK_SWIFT_FLAGS[@]}" \
    "$PROJECT_ROOT/src/MdairRender.swift" \
    "$OBJ_DIR/AppMain.o" \
    "$CMARK_LIB"

echo "  ✓ Peekdown.app"

# --- 2. Build QuickLook Preview Extension ---
echo "[2/5] Building QLMarkdownPreview.appex..."
mkdir -p "$EXT_BUNDLE/Contents/MacOS"
mkdir -p "$EXT_BUNDLE/Contents/Resources"
# 확장은 샌드박스라 앱 번들을 읽는다고 장담할 수 없어 mermaid를 따로 넣는다
cp "$PROJECT_ROOT/resources/mermaid.min.js" "$PROJECT_ROOT/resources/mermaid-LICENSE.txt" "$EXT_BUNDLE/Contents/Resources/"
cp "$PROJECT_ROOT/vendor/cmark-gfm/COPYING" "$EXT_BUNDLE/Contents/Resources/cmark-gfm-LICENSE.txt"

cp "$PROJECT_ROOT/ExtInfo.plist" "$EXT_BUNDLE/Contents/Info.plist"

# Compile Swift extension as appex executable with NSExtensionMain entry point
swiftc \
    -target "$TARGET" \
    -module-name QLMarkdownPreview \
    -o "$EXT_BUNDLE/Contents/MacOS/QLMarkdownPreview" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -Xlinker -rpath -Xlinker @executable_path/../../../../Frameworks \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -import-objc-header /dev/null \
    -disable-bridging-pch \
    "${CMARK_SWIFT_FLAGS[@]}" \
    "$PROJECT_ROOT/src/MdairRender.swift" \
    "$PROJECT_ROOT/src/PreviewExtension.swift" \
    "$CMARK_LIB" \
    2>&1

echo "  ✓ QLMarkdownPreview.appex"

# --- 2b. Build TextBundle converter CLI tool ---
echo "[2b/5] Building peekdown-convert..."
swiftc \
    -target "$TARGET" \
    -module-name TextBundleConverter \
    -o "$APP_BUNDLE/Contents/MacOS/peekdown-convert" \
    -import-objc-header /dev/null \
    "$PROJECT_ROOT/src/TextBundleConverter.swift" \
    2>&1

echo "  ✓ peekdown-convert"

# --- 3. Code Sign ---
echo "[3/5] Code signing..."
codesign --force --sign - --entitlements "$PROJECT_ROOT/ExtEntitlements.plist" "$EXT_BUNDLE" 2>&1
codesign --force --sign - "$APP_BUNDLE" 2>&1
echo "  ✓ Signed (ad-hoc)"

# --- 4. Verify ---
echo "[4/5] Verifying..."
FAIL=0
[ -f "$APP_BUNDLE/Contents/MacOS/Peekdown" ] || { echo "  ✗ App binary missing"; FAIL=1; }
[ -f "$EXT_BUNDLE/Contents/MacOS/QLMarkdownPreview" ] || { echo "  ✗ Extension binary missing"; FAIL=1; }
[ -f "$EXT_BUNDLE/Contents/Info.plist" ] || { echo "  ✗ Extension Info.plist missing"; FAIL=1; }
[ -f "$APP_BUNDLE/Contents/MacOS/peekdown-convert" ] || { echo "  ✗ peekdown-convert binary missing"; FAIL=1; }

if [ "$FAIL" -eq 0 ]; then
    echo "  ✓ All verified"
else
    echo "  ✗ Verification failed!"
    exit 1
fi

echo ""
echo "=== Build complete ==="
echo "  $APP_BUNDLE"
echo "  ├── Contents/MacOS/peekdown-convert"
echo "  └── Contents/PlugIns/QLMarkdownPreview.appex"
