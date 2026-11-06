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
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# 렌더러(Swift)를 ObjC 앱에서 부를 수 있게 헤더를 만든 뒤, 아키텍처별로 빌드해 합친다
OBJ_DIR="$BUILD_DIR/obj"
mkdir -p "$OBJ_DIR"

# 마크다운 파서 cmark-gfm(C)을 아키텍처별 정적 라이브러리로 빌드한다
CMARK_DIR="$PROJECT_ROOT/vendor/cmark-gfm"
CMARK_SWIFT_FLAGS=(-I "$CMARK_DIR" -Xcc "-I$CMARK_DIR/src" -Xcc "-I$CMARK_DIR/extensions" -Xcc -DCMARK_GFM_STATIC_DEFINE)
for ARCH in arm64 x86_64; do
    mkdir -p "$OBJ_DIR/cmark-$ARCH"
    for SRC in "$CMARK_DIR"/src/*.c "$CMARK_DIR"/extensions/*.c; do
        clang -arch "$ARCH" -mmacosx-version-min=13.0 -O2 -w -DCMARK_GFM_STATIC_DEFINE \
            -I "$CMARK_DIR/src" -I "$CMARK_DIR/extensions" \
            -c -o "$OBJ_DIR/cmark-$ARCH/$(basename "$SRC" .c).o" "$SRC" &
    done
    wait
    libtool -static -no_warning_for_no_symbols -o "$OBJ_DIR/libcmark-gfm-$ARCH.a" "$OBJ_DIR/cmark-$ARCH"/*.o
done
swiftc \
    -target arm64-apple-macosx13.0 \
    -module-name MdairShared \
    -parse-as-library \
    -typecheck \
    -emit-objc-header-path "$OBJ_DIR/MdairShared-Swift.h" \
    "${CMARK_SWIFT_FLAGS[@]}" \
    "$PROJECT_ROOT/src/MdairRender.swift"

for ARCH in arm64 x86_64; do
    clang \
        -arch "$ARCH" \
        -mmacosx-version-min=13.0 \
        -fobjc-arc \
        -fmodules \
        -w \
        -I "$OBJ_DIR" \
        -c -o "$OBJ_DIR/AppMain-$ARCH.o" \
        "$PROJECT_ROOT/src/AppMain.m"
    swiftc \
        -target "$ARCH-apple-macosx13.0" \
        -module-name MdairShared \
        -parse-as-library \
        -framework Cocoa \
        -framework WebKit \
        -o "$OBJ_DIR/Peekdown-$ARCH" \
        "${CMARK_SWIFT_FLAGS[@]}" \
        "$PROJECT_ROOT/src/MdairRender.swift" \
        "$OBJ_DIR/AppMain-$ARCH.o" \
        "$OBJ_DIR/libcmark-gfm-$ARCH.a"
done
lipo -create -output "$APP_BUNDLE/Contents/MacOS/Peekdown" "$OBJ_DIR/Peekdown-arm64" "$OBJ_DIR/Peekdown-x86_64"

echo "  ✓ Peekdown.app"

# --- 2. Build QuickLook Preview Extension ---
echo "[2/5] Building QLMarkdownPreview.appex..."
mkdir -p "$EXT_BUNDLE/Contents/MacOS"
mkdir -p "$EXT_BUNDLE/Contents/Resources"
# 확장은 샌드박스라 앱 번들을 읽는다고 장담할 수 없어 mermaid를 따로 넣는다
cp "$PROJECT_ROOT/resources/mermaid.min.js" "$PROJECT_ROOT/resources/mermaid-LICENSE.txt" "$EXT_BUNDLE/Contents/Resources/"

cp "$PROJECT_ROOT/ExtInfo.plist" "$EXT_BUNDLE/Contents/Info.plist"

# Compile Swift extension as appex executable with NSExtensionMain entry point
swiftc \
    -target arm64-apple-macosx13.0 \
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
    "$OBJ_DIR/libcmark-gfm-arm64.a" \
    2>&1

echo "  ✓ QLMarkdownPreview.appex"

# --- 2b. Build MdairConverter CLI tool ---
echo "[2b/5] Building peekdown-convert..."
swiftc \
    -target arm64-apple-macosx13.0 \
    -module-name MdairConverter \
    -o "$APP_BUNDLE/Contents/MacOS/peekdown-convert" \
    -import-objc-header /dev/null \
    "$PROJECT_ROOT/src/MdairConverter.swift" \
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
