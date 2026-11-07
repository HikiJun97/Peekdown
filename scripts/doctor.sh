#!/bin/bash
# 이 Mac에 Peekdown을 빌드·테스트할 도구가 있는지 점검한다. 빠진 것이 있으면 종료 코드 1.
#   make doctor   (또는 scripts/doctor.sh)
set -u
FAIL=0
ok()   { echo "  ✓ $1"; }
bad()  { echo "  ✗ $1"; FAIL=1; }
warn() { echo "  ! $1"; }

# version_at_least <실제> <최소>: 점으로 나눈 숫자를 앞에서부터 비교한다
version_at_least() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, x, "."); m = split(b, y, ".")
        for (i = 1; i <= (n > m ? n : m); i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
        exit 0 }'
}

echo "[macOS]"
MACOS=$(sw_vers -productVersion)
version_at_least "$MACOS" 13.0 && ok "macOS $MACOS" || bad "macOS $MACOS: 13.0 이상이 필요합니다"
ARCH=$(uname -m)
[ "$ARCH" = "arm64" ] && ok "Apple silicon ($ARCH)" || bad "$ARCH: Apple silicon(arm64)만 지원합니다"

echo "[Xcode Command Line Tools]"
if xcode-select -p > /dev/null 2>&1; then
    ok "$(xcode-select -p)"
    for tool in clang swiftc codesign; do
        command -v "$tool" > /dev/null && ok "$tool" || bad "$tool 없음"
    done
    ok "$(swiftc --version 2>&1 | head -1)"
else
    bad "설치되지 않음: xcode-select --install"
fi

echo "[Rust]"
if command -v cargo > /dev/null && command -v rustc > /dev/null; then
    RUSTC=$(rustc -V | awk '{print $2}')
    version_at_least "$RUSTC" 1.89 && ok "rustc $RUSTC ($(command -v rustc))" || bad "rustc $RUSTC: 1.89 이상이 필요합니다(rustup update)"
    ok "cargo $(cargo -V | awk '{print $2}') ($(command -v cargo))"
    HOST=$(rustc -vV | awk '/^host:/ {print $2}')
    [ "$HOST" = "aarch64-apple-darwin" ] && ok "host $HOST" || bad "host $HOST: aarch64-apple-darwin이어야 합니다"
    if command -v rustup > /dev/null; then
        ok "rustup: $(rustup show active-toolchain 2>/dev/null | head -1)"
    else
        warn "rustup 없음(Homebrew rust 등). 버전만 맞으면 되지만 rustup을 권합니다: https://rustup.rs"
    fi
else
    bad "cargo/rustc 없음: https://rustup.rs 에서 설치"
fi

echo "[빌드에 영향을 주는 설정]"
SEEN=0
for var in MACOSX_DEPLOYMENT_TARGET RUSTFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_BUILD_TARGET CARGO_TARGET_DIR CARGO_BUILD_TARGET_DIR RUSTC_WRAPPER CARGO_BUILD_RUSTC_WRAPPER; do
    if [ -n "${!var:-}" ]; then
        SEEN=1
        if [ "$var" = "MACOSX_DEPLOYMENT_TARGET" ]; then
            bad "$var=${!var}: 이 값이 있으면 core 빌드가 실패합니다(fearless_simd_macros E0463). unset 후 make clean"
        else
            warn "$var=${!var}: 빌드 결과가 달라질 수 있습니다"
        fi
    fi
done
for config in "$HOME/.cargo/config.toml" "$HOME/.cargo/config"; do
    if [ -f "$config" ]; then
        SEEN=1
        warn "$config 이 있습니다. build·target·env 설정이 있으면 빌드에 영향을 줍니다:"
        grep -nE '^\s*(\[|target|rustflags|rustc-wrapper|MACOSX)' "$config" | sed 's/^/      /'
    fi
done
[ "$SEEN" -eq 0 ] && ok "특별한 환경 변수나 사용자 cargo 설정 없음"

echo "[테스트 도구]"
for tool in make python3 zip unzip zipinfo ditto; do
    command -v "$tool" > /dev/null && ok "$tool" || bad "$tool 없음"
done

echo
if [ "$FAIL" -eq 0 ]; then
    echo "빌드 준비 완료. 이전 빌드가 이상하게 실패한다면 make clean 후 다시 빌드하세요"
else
    echo "위의 ✗ 항목을 먼저 해결하세요"
    exit 1
fi
