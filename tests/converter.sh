#!/bin/bash
# peekdown-convert(내보내기)와 TextBundle/TextPack 읽기를 실제 파일로 검사한다.
# 사용법: tests/converter.sh <peekdown-convert 경로> <harness 경로>   (보통 tests/run.sh가 부른다)
set -u
CONV="$1"
HARNESS="$2"
W=$(mktemp -d "${TMPDIR:-/tmp}/peekdown-conv.XXXXXX")
trap 'rm -rf "$W"' EXIT
FAIL=0
PASS=0

expect() {  # expect <이름> <명령…>: 명령이 성공하면 통과
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  ✗ $name"; fi
}
contains() { grep -qF -- "$2" <<<"$1"; }
png() { echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==" | base64 -d > "$1"; }

echo "[converter] 정상 문서 내보내기"
mkdir -p "$W/doc/imgs"
for n in "a b.png" "it's.png" "a&b.png" "plain.png"; do png "$W/doc/imgs/$n"; done
cat > "$W/doc/doc.md" <<'EOF'
# Paths

![space](imgs/a%20b.png)

![angle](<imgs/a b.png>)

![quote](imgs/it's.png)

![amp](imgs/a&b.png)

![plain](imgs/plain.png)

![remote](https://example.com/remote.png)
EOF
"$CONV" "$W/doc/doc.md" -o "$W/doc.textpack" >/dev/null 2>&1
expect "TextPack이 만들어짐" test -f "$W/doc.textpack"
LIST=$(unzip -Z1 "$W/doc.textpack" 2>/dev/null)
expect "ZIP 안에 .textbundle 폴더째 들어감" contains "$LIST" "doc.textbundle/text.md"
expect "info.json이 있음" contains "$LIST" "doc.textbundle/info.json"
expect "같은 이미지는 한 파일로 합침(4개)" test "$(grep -c '^doc.textbundle/assets/.' <<<"$LIST")" -eq 4
TEXT=$(unzip -p "$W/doc.textpack" doc.textbundle/text.md 2>/dev/null)
expect "원격 이미지는 링크로 남김" contains "$TEXT" "](https://example.com/remote.png)"
expect "공백 경로는 %20으로 씀" contains "$TEXT" "](assets/a%20b.png)"
expect "열면 이미지 5장이 모두 인라인됨" contains "$("$HARNESS" bundle "$W/doc.textpack")" \
    "title=Paths images=space=OK,angle=OK,quote=OK,amp=OK,plain=OK"

"$CONV" "$W/doc/doc.md" -o "$W/folder.textbundle" >/dev/null 2>&1
expect ".textbundle 폴더로 저장" test -f "$W/folder.textbundle/text.md"
expect "폴더 번들도 열림" contains "$("$HARNESS" bundle "$W/folder.textbundle")" "images=space=OK,angle=OK,quote=OK,amp=OK,plain=OK"
(cd "$W" && "$CONV" doc/doc.md -o rel.textpack >/dev/null 2>&1)
expect "상대 경로 -o 도 파일을 만듦" test -f "$W/rel.textpack"

echo "[converter] 여러 방식으로 만든 TextPack 읽기"
(cd "$W/folder.textbundle" && zip -r -q ../root.textpack .)
(cd "$W" && zip -r -q - folder.textbundle | cat > stream.textpack)
expect "스트리밍 ZIP에 데이터 디스크립터가 있음" test "$(zipinfo -v "$W/stream.textpack" | grep -c 'extended local header: *yes')" -gt 0
(cd "$W" && ditto -c -k --sequesterRsrc --keepParent folder.textbundle finder.textpack)
for f in root stream finder; do
    expect "$f.textpack 열림" contains "$("$HARNESS" bundle "$W/$f.textpack")" "images=space=OK,angle=OK,quote=OK,amp=OK,plain=OK"
done
python3 -I - "$W" <<'EOF'
import sys, zipfile
w = sys.argv[1]
with zipfile.ZipFile(w + "/evil.textpack", "w") as z:
    z.writestr("evil.textbundle/text.md", "# Evil\n\n![plain](assets/plain.png)\n")
    z.write(w + "/doc/imgs/plain.png", "evil.textbundle/assets/plain.png")
    z.writestr("../escape.md", "ignored")
    z.writestr("evil.textbundle/assets/../../text.md", "# Hijacked")
with zipfile.ZipFile(w + "/both.textpack", "w") as z:
    z.writestr("text.md", "# Root")
    z.writestr("x.textbundle/text.md", "# Nested")
EOF
expect "../ 항목으로 본문을 바꿔치지 못함" contains "$("$HARNESS" bundle "$W/evil.textpack")" "title=Evil images=plain=OK"
expect "맨 위와 폴더가 함께 있으면 폴더 쪽(Obsidian과 같게)" contains "$("$HARNESS" bundle "$W/both.textpack")" "title=Nested"

echo "[converter] 공격 문서 내보내기"
mkdir -p "$W/victim/.fakessh" "$W/repo/docs" "$W/target"
echo "DUMMY-PRIVATE-KEY" > "$W/victim/.fakessh/id_rsa"
echo "DUMMY-TOKEN" > "$W/victim/secret.env"
echo "ORIGINAL" > "$W/target/victim.txt"
ln -s "$W/victim/secret.env" "$W/repo/docs/logo.png"
DOTS=$(printf '..%%2F%.0s' $(seq 1 25))
TGT=$(echo "$W/target/victim.txt" | sed 's#^/##; s#/#%2F#g')
cat > "$W/repo/docs/README.md" <<EOF
# Hello
<!-- ![](../../victim/secret.env) -->
<!-- ![k]($W/victim/.fakessh) -->
\`\`\`
![x](../../victim/.fakessh/id_rsa)
\`\`\`
![logo](logo.png)
![x](http://127.0.0.1:9/${DOTS}${TGT})
EOF
"$CONV" "$W/repo/docs/README.md" -o "$W/attack.textpack" >/dev/null 2>&1
expect "공격 문서도 내보내기는 끝남" test -f "$W/attack.textpack"
expect "비밀 파일·폴더·심볼릭 링크는 담지 않음" test -z "$(unzip -Z1 "$W/attack.textpack" | grep '^attack.textbundle/assets/.')"
expect "원격 주소 %2F로 다른 파일을 덮어쓰지 않음" test "$(cat "$W/target/victim.txt")" = "ORIGINAL"

mkdir -p "$W/Important/sub" && echo keep > "$W/Important/sub/file.txt"
"$CONV" "$W/doc/doc.md" -o "$W/Important" >/dev/null 2>&1
expect "확장자 없는 출력(기존 폴더)은 거부" test "$?" -ne 0
expect "기존 폴더 내용은 그대로" test "$(cat "$W/Important/sub/file.txt")" = "keep"
mkdir -p "$W/dir.textpack"
"$CONV" "$W/doc/doc.md" -o "$W/dir.textpack" >/dev/null 2>&1
expect "폴더인 .textpack 출력은 거부" test "$?" -ne 0

echo "  ${PASS}개 통과, ${FAIL}개 실패"
[ "$FAIL" -eq 0 ]
