// Peekdown 핵심 로직(core/, Rust)의 C 인터페이스. 구현은 core/src/ffi.rs.
// 돌려주는 문자열은 모두 peekdown_free로 해제한다.
#ifndef PEEKDOWN_H
#define PEEKDOWN_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 마크다운(UTF-8, 아니면 Latin-1 바이트)으로 완성 페이지를 만든다. base_dir가 NULL이 아니면
// 그 폴더 기준으로 마크다운 이미지를 인라인한다.
char *peekdown_page_for_markdown(const uint8_t *markdown, size_t len, const char *base_dir);

// peekdown_page_for_markdown의 본문만. missing_images가 NULL이 아니면 읽지 못한 로컬 이미지 수를 적는다.
char *peekdown_markdown_body(const uint8_t *markdown, size_t len, const char *base_dir, size_t *missing_images);

// 본문 HTML과 안내 HTML(NULL 가능)을 CSP가 걸린 완성 페이지로 감싼다.
char *peekdown_page(const char *body, const char *notice);

// .textbundle 폴더나 .textpack 파일의 완성 페이지. 읽지 못하면 NULL.
char *peekdown_page_for_textbundle(const char *path);

// target이 current 문서 안의 다른 위치(#fn-1 등)로 옮겨 가는 링크인지. 둘 중 하나라도 NULL이면 false.
bool peekdown_is_same_document_link(const char *target, const char *current);

void peekdown_free(char *s);

#ifdef __cplusplus
}
#endif

#endif
