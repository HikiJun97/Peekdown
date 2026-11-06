// macOS 앱(ObjC)과 QuickLook 확장(Swift)이 부르는 C 함수. 선언은 core/include/peekdown.h.
// 돌려주는 문자열은 모두 Rust가 할당하므로 peekdown_free로만 해제한다.
// 패닉이 C 쪽으로 넘어가지 않게 모든 함수를 catch_unwind로 감싸고, 실패하면 NULL(또는 false)을 돌려준다.

use crate::page::{markdown_body, page, page_for_markdown, page_for_textbundle};
use crate::{decode_text, is_same_document_link};
use std::ffi::{CStr, CString, c_char};
use std::panic::{UnwindSafe, catch_unwind};
use std::path::Path;
use std::ptr;

fn guard<T>(fallback: T, work: impl FnOnce() -> T + UnwindSafe) -> T {
    catch_unwind(work).unwrap_or(fallback)
}

/// NULL이거나 UTF-8이 아니면 None
unsafe fn str_arg<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok()
}

unsafe fn text_arg(bytes: *const u8, len: usize) -> String {
    if bytes.is_null() || len == 0 {
        return String::new();
    }
    decode_text(unsafe { std::slice::from_raw_parts(bytes, len) })
}

fn out(s: String) -> *mut c_char {
    // 페이지에는 NUL이 들어갈 일이 없지만, 들어가면 잘리지 않게 바꿔 둔다
    CString::new(s).unwrap_or_else(|e| CString::new(e.into_vec().into_iter().filter(|&b| b != 0).collect::<Vec<_>>()).unwrap()).into_raw()
}

/// 마크다운(UTF-8, 아니면 Latin-1 바이트)으로 완성 페이지를 만든다. base_dir가 NULL이 아니면 그 폴더 기준으로
/// 마크다운 이미지를 인라인한다.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn peekdown_page_for_markdown(markdown: *const u8, len: usize, base_dir: *const c_char) -> *mut c_char {
    let markdown = unsafe { text_arg(markdown, len) };
    let base_dir = unsafe { str_arg(base_dir) };
    guard(ptr::null_mut(), || out(page_for_markdown(&markdown, base_dir.map(Path::new))))
}

/// peekdown_page_for_markdown의 본문만. missing_images가 NULL이 아니면 읽지 못한 로컬 이미지 수를 적는다.
/// QuickLook이 안내 문구를 붙이려고 peekdown_page와 나눠 부른다.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn peekdown_markdown_body(markdown: *const u8, len: usize, base_dir: *const c_char, missing_images: *mut usize) -> *mut c_char {
    let markdown = unsafe { text_arg(markdown, len) };
    let base_dir = unsafe { str_arg(base_dir) };
    let (body, missing) = guard((String::new(), 0), || markdown_body(&markdown, base_dir.map(Path::new)));
    if !missing_images.is_null() {
        unsafe { *missing_images = missing };
    }
    out(body)
}

/// 본문 HTML과 안내 HTML(NULL 가능)을 CSP가 걸린 완성 페이지로 감싼다.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn peekdown_page(body: *const c_char, notice: *const c_char) -> *mut c_char {
    let body = unsafe { str_arg(body) }.unwrap_or("");
    let notice = unsafe { str_arg(notice) }.unwrap_or("");
    guard(ptr::null_mut(), || out(page(body, notice)))
}

/// .textbundle 폴더나 .textpack 파일의 완성 페이지. 읽지 못하면 NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn peekdown_page_for_textbundle(path: *const c_char) -> *mut c_char {
    let Some(path) = (unsafe { str_arg(path) }) else { return ptr::null_mut() };
    guard(ptr::null_mut(), || page_for_textbundle(Path::new(path)).map_or(ptr::null_mut(), out))
}

/// target이 current 문서 안의 다른 위치(#fn-1 등)로 옮겨 가는 링크인지. 둘 중 하나라도 NULL이면 false.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn peekdown_is_same_document_link(target: *const c_char, current: *const c_char) -> bool {
    match unsafe { (str_arg(target), str_arg(current)) } {
        (Some(target), Some(current)) => is_same_document_link(target, current),
        _ => false,
    }
}

/// 이 라이브러리가 돌려준 문자열을 해제한다. NULL은 무시한다.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn peekdown_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}
