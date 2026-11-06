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
CORE="$ROOT/build/core/release"   # .cargo/config.toml의 출력 폴더
mkdir -p "$OUT"

echo "== 빌드"
if ! ./scripts/build.sh > "$OUT/build.log" 2>&1; then
    tail -20 "$OUT/build.log"; echo "빌드 실패"; exit 1
fi
if ! cargo build --release --manifest-path core/Cargo.toml --examples > "$OUT/core-build.log" 2>&1; then
    tail -20 "$OUT/core-build.log"; echo "테스트 하네스(core/examples) 빌드 실패"; exit 1
fi
# WebKit 하네스는 앱과 같은 CoreBridge.swift로 Rust core를 C 함수로 부른다
if ! swiftc -O -o "$OUT/harness" -I core/include -Xlinker "$CORE/libpeekdown_core.a" -Xlinker -liconv \
        src/CoreBridge.swift tests/harness/main.swift > "$OUT/harness-build.log" 2>&1; then
    cat "$OUT/harness-build.log"; echo "WebKit 하네스 빌드 실패"; exit 1
fi
WARNINGS=$(cat "$OUT/build.log" "$OUT/core-build.log" "$OUT/harness-build.log" | grep -c "warning:" || true)
echo "  빌드 성공, 경고 ${WARNINGS}개"

FAILED=()
run() {  # run <묶음 이름> <명령…>
    echo "== $1"
    "${@:2}" || FAILED+=("$1")
}
spec_suite() {  # 예제 모으기 → 렌더링 → 비교. 어느 단계든 실패하면 묶음 실패
    python3 tests/spec/spec.py cases "$OUT/spec-cases.json" &&
        "$CORE/examples/harness" spec "$OUT/spec-cases.json" "$OUT/spec-rendered.json" &&
        python3 tests/spec/spec.py compare "$OUT/spec-cases.json" "$OUT/spec-rendered.json"
}
for suite in "${SUITES[@]}"; do
    case "$suite" in
        unit) run unit cargo test --quiet --manifest-path core/Cargo.toml ;;
        spec) run spec spec_suite ;;
        webkit) run webkit "$OUT/harness" webkit ;;
        converter) run converter tests/converter.sh "$ROOT/build/Peekdown.app/Contents/MacOS/peekdown-convert" "$CORE/examples/harness" ;;
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
