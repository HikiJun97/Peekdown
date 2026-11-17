#!/bin/bash
# /Applications/Peekdown.app을 설치한 뒤 시스템에 알린다. pkg 설치 파일(create-pkg.sh)과 make install이 함께 쓴다.
# "다음으로 열기" 목록에 나오도록 Launch Services에 등록하고, QuickLook이 새 확장을 쓰도록 캐시를 비운다.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Peekdown.app 2>/dev/null || true
/usr/bin/qlmanage -r 2>/dev/null || true
/usr/bin/qlmanage -r cache 2>/dev/null || true
# Open the app briefly to register the extension, then quit
open -a /Applications/Peekdown.app 2>/dev/null || true
sleep 2
osascript -e 'tell application "Peekdown" to quit' 2>/dev/null || true
exit 0
