#!/bin/bash
# Peekdown 테스트를 모두 돌린다. 하나라도 실패하면 종료 코드 1.
#   tests/run.sh            전체
#   tests/run.sh unit spec  고른 묶음만
# 묶음: unit, spec, webkit, converter        지금 앱이 쓰는 Swift 렌더러(src/MdairRender.swift)
#       core, core-spec, core-webkit, core-converter   Rust 핵심 로직(core/). 앱이 core로 옮겨 가면 Swift 쪽은 지운다
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SUITES=("$@")
[ ${#SUITES[@]} -eq 0 ] && SUITES=(unit spec webkit converter core core-spec core-webkit core-converter)
OUT="$ROOT/build/tests"
CORE="$ROOT/build/core/release"
mkdir -p "$OUT"

echo "== 빌드"
if ! ./scripts/build.sh > "$OUT/build.log" 2>&1; then
    tail -20 "$OUT/build.log"; echo "빌드 실패"; exit 1
fi
if ! cargo build --release --manifest-path core/Cargo.toml --target-dir build/core --bins --examples > "$OUT/core-build.log" 2>&1; then
    tail -20 "$OUT/core-build.log"; echo "core 빌드 실패"; exit 1
fi
WARNINGS=$(cat "$OUT/build.log" "$OUT/core-build.log" | grep -c "warning:" || true)
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
spec_suite() {  # spec_suite <렌더러 하네스> <결과 파일 이름> <알려진 실패 목록>. 어느 단계든 실패하면 묶음 실패
    python3 tests/spec/spec.py cases "$OUT/spec-cases.json" &&
        "$1" spec "$OUT/spec-cases.json" "$OUT/$2" &&
        python3 tests/spec/spec.py compare "$OUT/spec-cases.json" "$OUT/$2" --known "tests/spec/$3"
}
for suite in "${SUITES[@]}"; do
    case "$suite" in
        unit) run unit "$OUT/harness" unit ;;
        webkit) run webkit "$OUT/harness" webkit ;;
        spec) run spec spec_suite "$OUT/harness" spec-rendered.json known-failures.txt ;;
        converter) run converter tests/converter.sh "$ROOT/build/Peekdown.app/Contents/MacOS/peekdown-convert" "$OUT/harness" ;;
        core) run core cargo test --quiet --manifest-path core/Cargo.toml --target-dir build/core ;;
        core-webkit) run core-webkit "$OUT/harness" webkit --core "$CORE/examples/harness" ;;
        core-spec) run core-spec spec_suite "$CORE/examples/harness" core-spec-rendered.json known-failures-core.txt ;;
        core-converter) run core-converter tests/converter.sh "$CORE/peekdown-convert" "$CORE/examples/harness" --core ;;
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
