//! Peekdown 핵심 로직. 앱, QuickLook 확장, 변환기(peekdown-convert)가 함께 쓴다.
//!
//! - [`render`]: 마크다운 → HTML 본문 (comrak, CommonMark + GFM)
//! - [`page`]: 본문을 CSP가 걸린 완성 페이지로 감싸고, 로컬 이미지·TextBundle 첨부물을 data URI로 넣는다
//! - [`textbundle`]: TextBundle(.textbundle 폴더)과 TextPack(.textpack ZIP) 읽기
//! - [`convert`]: 마크다운과 로컬 이미지를 TextBundle/TextPack으로 내보내기

mod base64;
pub mod convert;
pub mod images;
pub mod page;
pub mod render;
pub mod textbundle;
pub mod zip;

pub use page::{is_same_document_link, page, page_for_markdown, page_for_textbundle};
pub use render::render;
