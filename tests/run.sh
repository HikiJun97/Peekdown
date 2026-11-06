#!/bin/bash
# Peekdown 테스트를 모두 돌린다. 하나라도 실패하면 종료 코드 1.
#   tests/run.sh            전체
#   tests/run.sh unit spec  고른 묶음만 (unit, spec, webkit, converter)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SUITES=("$@")
[ ${#SUITES[@]} -eq 0 ] && SUITES=(unit spec webkit converter)
OUT="$ROOT/build/tests"
mkdir -p "$OUT"

echo "== 빌드"
if ! ./scripts/build.sh > "$OUT/build.log" 2>&1; then
    tail -20 "$OUT/build.log"; echo "빌드 실패"; exit 1
fi
WARNINGS=$(grep -c "warning:" "$OUT/build.log" || true)
echo "  빌드 성공, 경고 ${WARNINGS}개"
swiftc -O -o "$OUT/harness" \
    -I vendor/cmark-gfm -Xcc -Ivendor/cmark-gfm/src -Xcc -Ivendor/cmark-gfm/extensions -Xcc -DCMARK_GFM_STATIC_DEFINE \
    src/MdairRender.swift tests/harness/main.swift build/obj/libcmark-gfm.a || { echo "하네스 빌드 실패"; exit 1; }
# 하네스도 앱처럼 실행 파일 옆의 mermaid.min.js를 읽는다
cp resources/mermaid.min.js "$OUT/"

FAILED=()
run() {  # run <묶음 이름> <명령…>
    echo "== $1"
    "${@:2}" || FAILED+=("$1")
}
spec_suite() {  # 예제 모으기 → 렌더링 → 비교. 어느 단계든 실패하면 묶음 실패
    python3 tests/spec/spec.py cases "$OUT/spec-cases.json" &&
        "$OUT/harness" spec "$OUT/spec-cases.json" "$OUT/spec-rendered.json" &&
        python3 tests/spec/spec.py compare "$OUT/spec-cases.json" "$OUT/spec-rendered.json"
}
for suite in "${SUITES[@]}"; do
    case "$suite" in
        unit) run unit "$OUT/harness" unit ;;
        webkit) run webkit "$OUT/harness" webkit ;;
        spec) run spec spec_suite ;;
        converter) run converter tests/converter.sh "$ROOT/build/Peekdown.app/Contents/MacOS/peekdown-convert" "$OUT/harness" ;;
        *) echo "알 수 없는 묶음: $suite"; FAILED+=("$suite") ;;
    esac
done
[ "$WARNINGS" -eq 0 ] || FAILED+=("빌드 경고")

echo
if [ ${#FAILED[@]} -eq 0 ]; then
    echo "모든 테스트 통과"
else
    echo "실패: ${FAILED[*]}"
    exit 1
fi
