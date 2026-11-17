#!/usr/bin/env python3
"""앱에 들어가는 Rust 의존성의 라이선스 전문을 resources/THIRD-PARTY-NOTICES.txt로 모은다.

core/Cargo.toml의 의존성이 바뀌면 다시 실행해 결과를 커밋한다.
    python3 scripts/third-party-notices.py
지금 빌드하는 macOS(호스트) 대상의 일반 의존성만 모은다. 테스트 전용(dev) 의존성은 앱에 들어가지 않아 뺀다.
정적 라이브러리와 변환기에는 Rust 표준 라이브러리도 들어가서, 툴체인에 든 라이선스 원문으로 그 고지도 붙인다.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "core", "Cargo.toml")
OUT = os.path.join(ROOT, "resources", "THIRD-PARTY-NOTICES.txt")
LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE)", re.IGNORECASE)


def cargo(*args):
    return subprocess.run(["cargo", *args, "--manifest-path", MANIFEST], check=True,
                          capture_output=True, text=True, cwd=ROOT).stdout


def rust_std_section():
    """Rust 표준 라이브러리(std, core, alloc) 고지. Apache-2.0 OR MIT 중 MIT로 싣고,
    표준 라이브러리 안의 유니코드 표(core/src/unicode/unicode_data.rs)는 Unicode-3.0이라 함께 싣는다."""
    sysroot = subprocess.run(["rustc", "--print", "sysroot"], check=True, capture_output=True, text=True).stdout.strip()
    version = subprocess.run(["rustc", "--version"], check=True, capture_output=True, text=True).stdout.strip()
    licenses = os.path.join(sysroot, "share", "doc", "rust", "licenses")
    read = lambda name: open(os.path.join(licenses, name), encoding="utf-8").read().strip()
    mit = read("MIT.txt").replace("Copyright (c) <year> <copyright holders>", "Copyright (c) The Rust Project Developers")
    header = (f"Rust standard library ({version}) — Apache-2.0 OR MIT\nhttps://github.com/rust-lang/rust\n"
              "Full notices: COPYRIGHT-library.html in the Rust toolchain")
    return header + "\n\n" + mit + "\n\n---\n\n" + read("Unicode-3.0.txt")


def main():
    tree = cargo("tree", "-e", "normal", "--prefix", "none", "-f", "{p}")
    wanted = set()
    for line in tree.splitlines():
        m = re.match(r"^(\S+) v(\S+)", line)
        if m and m.group(1) != "peekdown-core":
            wanted.add((m.group(1), m.group(2)))

    packages = json.loads(cargo("metadata", "--format-version", "1"))["packages"]
    sections = []
    for pkg in sorted(packages, key=lambda p: p["name"]):
        if (pkg["name"], pkg["version"]) not in wanted:
            continue
        folder = os.path.dirname(pkg["manifest_path"])
        files = sorted(f for f in os.listdir(folder) if LICENSE_FILE.match(f) and os.path.isfile(os.path.join(folder, f)))
        if not files:
            sys.exit(f"{pkg['name']} {pkg['version']}: 라이선스 파일이 없다. 직접 확인해서 넣어야 한다")
        texts = [open(os.path.join(folder, f), encoding="utf-8", errors="replace").read().strip() for f in files]
        header = f"{pkg['name']} {pkg['version']} — {pkg.get('license') or '라이선스 표기 없음'}\n{pkg.get('repository') or ''}".strip()
        sections.append(header + "\n\n" + "\n\n---\n\n".join(texts))
    sections.append(rust_std_section())

    with open(OUT, "w", encoding="utf-8") as f:
        f.write("Peekdown includes the following third-party Rust crates and the Rust standard library.\n")
        f.write("Mermaid's license is in mermaid-LICENSE.txt.\n\n")
        f.write(("\n\n" + "=" * 72 + "\n\n").join(sections) + "\n")
    print(f"{len(sections) - 1}개 크레이트와 Rust 표준 라이브러리 → {os.path.relpath(OUT, ROOT)}")


if __name__ == "__main__":
    main()
