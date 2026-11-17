# scripts/build.sh와 tests/run.sh가 함께 읽는 Rust core 빌드 설정. PROJECT_ROOT를 먼저 정해 두고 source 한다.
# 대상(arm64)과 출력 폴더를 명령줄로 못 박고, 출력 경로·대상·배포 버전을 바꾸는 사용자 환경 변수는 지운다.
# 그래야 x86_64 Rust 툴체인이나 CARGO_TARGET_DIR가 있어도 라이브러리가 늘 같은 자리에 같은 대상으로 나온다.
# MACOSX_DEPLOYMENT_TARGET을 주면 깨끗한 빌드에서 memchr-n이 proc-macro를 찾지 못해 실패한다(rustc 1.95).
CORE_TARGET="aarch64-apple-darwin"
CORE_OUT="$PROJECT_ROOT/build/core/$CORE_TARGET/release"
CORE_LIB="$CORE_OUT/libpeekdown_core.a"
# Swift는 core/include/module.modulemap으로 C 함수를 import PeekdownCore 한다
CORE_SWIFT_FLAGS=(-I "$PROJECT_ROOT/core/include" -Xlinker "$CORE_LIB" -Xlinker -liconv)

core_cargo() {  # core_cargo <cargo 하위 명령> [인자…]
    local command="$1"; shift
    env -u CARGO_TARGET_DIR -u CARGO_BUILD_TARGET_DIR -u CARGO_BUILD_TARGET -u MACOSX_DEPLOYMENT_TARGET \
        cargo "$command" --manifest-path "$PROJECT_ROOT/core/Cargo.toml" \
        --target "$CORE_TARGET" --target-dir "$PROJECT_ROOT/build/core" "$@"
}
