# Peekdown 개발용 명령. `make help`로 목록을 본다.
# 실제 작업은 scripts/와 tests/의 스크립트가 하고, 여기서는 이름만 붙인다.

APP := build/Peekdown.app
# make test SUITES="unit spec" 처럼 고른 묶음만 돌린다(unit, spec, webkit, converter)
SUITES ?=

.DEFAULT_GOAL := build
.PHONY: help build test install run pkg dmg notices spec-update clean

help: ## 명령 목록
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  make %-12s %s\n", $$1, $$2}'

build: ## 앱 빌드 (build/Peekdown.app)
	./scripts/build.sh

test: ## 빌드하고 전체 테스트. 묶음 고르기: make test SUITES="unit spec"
	./tests/run.sh $(SUITES)

install: build ## 빌드해서 /Applications에 설치하고, Finder를 다시 띄워 QuickLook 확장을 새로 읽힌다
	rm -rf /Applications/Peekdown.app
	cp -R $(APP) /Applications/
	-killall Finder

run: build ## 빌드한 앱 실행
	open $(APP)

pkg: build ## 설치 파일 dist/Peekdown.pkg
	./scripts/create-pkg.sh

dmg: pkg ## 디스크 이미지 dist/Peekdown.dmg
	./scripts/create-dmg.sh

notices: ## Rust 의존성 라이선스 고지(resources/THIRD-PARTY-NOTICES.txt) 다시 만들기
	python3 scripts/third-party-notices.py

spec-update: ## 렌더러를 일부러 바꿔 스펙 결과가 달라졌을 때 known-failures.txt 갱신
	-./tests/run.sh spec
	python3 tests/spec/spec.py compare build/tests/spec-cases.json build/tests/spec-rendered.json --update

clean: ## 빌드 결과물 삭제 (build/, dist/)
	rm -rf build dist
