#!/bin/bash
# build/Peekdown.app을 /Applications에 설치한다(make install). 먼저 scripts/build.sh로 빌드해 둔다.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET=/Applications/Peekdown.app

# pkg로 설치한 앱은 root 소유라 지우다 중간에 멈춘다. 지우기 전에 확인한다
if [ -e "$TARGET" ] && [ -n "$(find "$TARGET" ! -user "$(id -u)" -print -quit 2>/dev/null)" ]; then
    echo "$TARGET 안에 다른 사용자(보통 pkg 설치로 root) 소유 파일이 있어 덮어쓸 수 없습니다." >&2
    echo "  sudo rm -rf $TARGET  로 지운 뒤 다시 make install 하세요." >&2
    exit 1
fi
rm -rf "$TARGET"
cp -R "$PROJECT_ROOT/build/Peekdown.app" /Applications/
"$PROJECT_ROOT/scripts/postinstall.sh"
# Finder가 QuickLook 확장을 새로 읽게 한다
killall Finder 2>/dev/null || true
echo "Installed: $TARGET"
