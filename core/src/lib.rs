//! Peekdown 핵심 로직. 앱, QuickLook 확장, 변환기(peekdown-convert)가 함께 쓴다.
//!
//! - [`render`]: 마크다운 → HTML 본문 (comrak, CommonMark + GFM)
//! - [`page`]: 본문을 CSP가 걸린 완성 페이지로 감싸고, 로컬 이미지·TextBundle 첨부물을 data URI로 넣는다
//! - [`textbundle`]: TextBundle(.textbundle 폴더)과 TextPack(.textpack ZIP) 읽기
//! - [`convert`]: 마크다운과 로컬 이미지를 TextBundle/TextPack으로 내보내기
//! - `ffi`: macOS 앱과 QuickLook 확장이 부르는 C 함수(core/include/peekdown.h)

mod base64;
pub mod convert;
mod ffi;
pub mod images;
pub mod page;
pub mod render;
pub mod textbundle;
pub mod zip;

pub use page::{is_same_document_link, markdown_body, page, page_for_markdown, page_for_textbundle};
pub use render::render;

/// 문서 바이트를 글자로 읽는다. UTF-8이 아니면 옛 문서처럼 Latin-1로 읽는다.
pub fn decode_text(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(s) => s.to_string(),
        Err(_) => bytes.iter().map(|&b| b as char).collect(),
    }
}
