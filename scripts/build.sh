#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/Peekdown.app"
EXT_BUNDLE="$APP_BUNDLE/Contents/PlugIns/QLMarkdownPreview.appex"

echo "=== Peekdown Build ==="

rm -rf "$APP_BUNDLE"

# Apple silicon(arm64) 전용으로 빌드한다. Intel Mac은 지원하지 않는다.
OBJ_DIR="$BUILD_DIR/obj"
mkdir -p "$OBJ_DIR"
TARGET="arm64-apple-macosx13.0"

# --- 0. Rust core ---
# 렌더링·TextBundle·내보내기는 core/(Rust)에 있다. 앱과 확장은 정적 라이브러리로 링크하고,
# 변환기 peekdown-convert는 실행 파일로 앱 안에 넣는다. 설정은 .cargo/config.toml(출력 폴더 build/core).
echo "[0/5] Building core (Rust)..."
cd "$PROJECT_ROOT"
cargo build --release --manifest-path core/Cargo.toml --lib --bin peekdown-convert
CORE_OUT="$BUILD_DIR/core/release"
CORE_LIB="$CORE_OUT/libpeekdown_core.a"
# Swift는 core/include/module.modulemap으로 C 함수를 import PeekdownCore 한다
CORE_SWIFT_FLAGS=(-I "$PROJECT_ROOT/core/include" -Xlinker "$CORE_LIB" -Xlinker -liconv)
echo "  ✓ core"

copy_resources() {  # copy_resources <Resources 폴더>
    cp "$PROJECT_ROOT/resources/mermaid-LICENSE.txt" "$PROJECT_ROOT/resources/THIRD-PARTY-NOTICES.txt" "$1/"
}

# --- 1. Build App ---
echo "[1/5] Building Peekdown.app..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$PROJECT_ROOT/AppInfo.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_ROOT/resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
copy_resources "$APP_BUNDLE/Contents/Resources"
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# 연결 코드(Swift)를 ObjC 앱에서 부를 수 있게 헤더를 만든다
swiftc \
    -target "$TARGET" \
    -module-name MdairShared \
    -parse-as-library \
    -typecheck \
    -emit-objc-header-path "$OBJ_DIR/MdairShared-Swift.h" \
    -I "$PROJECT_ROOT/core/include" \
    "$PROJECT_ROOT/src/CoreBridge.swift"

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
    "${CORE_SWIFT_FLAGS[@]}" \
    "$PROJECT_ROOT/src/CoreBridge.swift" \
    "$OBJ_DIR/AppMain.o"

echo "  ✓ Peekdown.app"

# --- 2. Build QuickLook Preview Extension ---
echo "[2/5] Building QLMarkdownPreview.appex..."
mkdir -p "$EXT_BUNDLE/Contents/MacOS"
mkdir -p "$EXT_BUNDLE/Contents/Resources"
copy_resources "$EXT_BUNDLE/Contents/Resources"

cp "$PROJECT_ROOT/ExtInfo.plist" "$EXT_BUNDLE/Contents/Info.plist"

# Compile Swift extension as appex executable with NSExtensionMain entry point
swiftc \
    -target "$TARGET" \
    -module-name QLMarkdownPreview \
    -o "$EXT_BUNDLE/Contents/MacOS/QLMarkdownPreview" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -Xlinker -rpath -Xlinker @executable_path/../../../../Frameworks \
    -Xlinker -e -Xlinker _NSExtensionMain \
    "${CORE_SWIFT_FLAGS[@]}" \
    "$PROJECT_ROOT/src/CoreBridge.swift" \
    "$PROJECT_ROOT/src/PreviewExtension.swift" \
    2>&1

echo "  ✓ QLMarkdownPreview.appex"

# --- 2b. TextBundle converter CLI tool ---
echo "[2b/5] Adding peekdown-convert..."
cp "$CORE_OUT/peekdown-convert" "$APP_BUNDLE/Contents/MacOS/peekdown-convert"
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
