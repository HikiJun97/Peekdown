// 페이지 속 이미지를 data URI로 넣는다. 로컬 파일과 TextBundle 첨부물 두 경우가 있다.

use crate::base64;
use crate::zip::MAX_ENTRY_SIZE;
use regex_lite::{Captures, Regex};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

pub const IMAGE_EXTENSIONS: [&str; 8] = ["png", "jpg", "jpeg", "gif", "svg", "webp", "tiff", "tif"];

/// 페이지에 data URI로 넣는 이미지의 합계 상한. 같은 이미지를 수백 번 참조해 페이지를 부풀리지 못하게 한다.
pub const MAX_INLINE_BYTES: usize = 64 << 20;

const NOT_FOUND: &str = "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyMDAiIGhlaWdodD0iNTAiPjx0ZXh0IHg9IjEwIiB5PSIzMCIgZmlsbD0iIzk5OSI+SW1hZ2Ugbm90IGZvdW5kPC90ZXh0Pjwvc3ZnPg==";

pub fn is_image_extension(ext: &str) -> bool {
    IMAGE_EXTENSIONS.contains(&ext.to_lowercase().as_str())
}

fn extension_of(path: &Path) -> String {
    path.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase()
}

pub fn mime_type(ext: &str) -> &'static str {
    match ext.to_lowercase().as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "svg" => "image/svg+xml",
        "webp" => "image/webp",
        "tiff" | "tif" => "image/tiff",
        _ => "image/png",
    }
}

fn data_uri(data: &[u8], ext: &str) -> String {
    format!("data:{};base64,{}", mime_type(ext), base64::encode(data))
}

/// 파일 앞부분이 확장자에 맞는 실제 이미지 형식인지 본다.
pub fn is_image_data(data: &[u8], ext: &str) -> bool {
    let starts = |sig: &[u8]| data.starts_with(sig);
    match ext {
        "png" => starts(&[0x89, 0x50, 0x4E, 0x47]),
        "jpg" | "jpeg" => starts(&[0xFF, 0xD8, 0xFF]),
        "gif" => starts(b"GIF8"),
        "webp" => starts(b"RIFF") && data.get(8..12) == Some(b"WEBP"),
        "tif" | "tiff" => starts(&[0x49, 0x49, 0x2A, 0x00]) || starts(&[0x4D, 0x4D, 0x00, 0x2A]),
        "svg" => String::from_utf8_lossy(&data[..data.len().min(4096)]).to_lowercase().contains("<svg"),
        _ => false,
    }
}

/// 로컬 이미지를 읽는다. 심볼릭 링크를 따라간 실제 대상이 일반 파일이고, 이미지 확장자이고, 내용도 이미지일 때만.
/// 이미지인 척하는 링크나 이름으로 다른 파일을 페이지에 싣지 못하게 한다.
pub fn read_local_image(path: &Path) -> Option<(Vec<u8>, String)> {
    let real = fs::canonicalize(path).ok()?;
    let ext = extension_of(&real);
    let meta = fs::metadata(&real).ok()?;
    if !is_image_extension(&ext) || !meta.is_file() || meta.len() > MAX_ENTRY_SIZE as u64 {
        return None;
    }
    let data = fs::read(&real).ok()?;
    is_image_data(&data, &ext).then_some((data, ext))
}

static NUMERIC_ENTITY: LazyLock<Regex> = LazyLock::new(|| Regex::new("&#([xX][0-9a-fA-F]+|[0-9]+);").unwrap());

/// HTML 속성에 든 이미지 주소를 실제 파일 경로로 되돌린다.
/// 렌더러는 주소를 퍼센트 인코딩하고(공백 → %20, 한글 → %EC…) 일부 문자를 엔티티로 바꾼다.
/// 엔티티를 먼저 풀고(&amp; 는 마지막) 그다음 퍼센트 인코딩을 푼다.
pub fn decode_image_path(value: &str) -> String {
    let s = value.replace("&quot;", "\"").replace("&lt;", "<").replace("&gt;", ">");
    let s = NUMERIC_ENTITY.replace_all(&s, |caps: &Captures| {
        let digits = &caps[1];
        let code = match digits.strip_prefix(['x', 'X']) {
            Some(hex) => u32::from_str_radix(hex, 16).ok(),
            None => digits.parse().ok(),
        };
        code.and_then(char::from_u32).map_or_else(|| caps[0].to_string(), |c| c.to_string())
    });
    let s = s.replace("&amp;", "&");
    percent_decode(&s).unwrap_or(s)
}

/// %XX를 푼다. %뒤가 16진수 두 자리가 아니거나 결과가 UTF-8이 아니면 None(Foundation의 removingPercentEncoding과 같다).
pub fn percent_decode(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = bytes.get(i + 1..i + 3).filter(|h| h.iter().all(u8::is_ascii_hexdigit))?;
            out.push(u8::from_str_radix(std::str::from_utf8(hex).ok()?, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

static IMG_SRC: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"(?i)(<img\b[^>]*?\ssrc=")([^"]+)""#).unwrap());
static ASSET_SRC: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"(src|srcset)="assets/([^"]+)""#).unwrap());

/// `<img src="로컬경로">`를 base_dir 기준으로 읽어 data URI로 바꾼다. 못 읽은 개수도 돌려준다.
/// 실제 이미지 파일만 읽고([`read_local_image`]), 같은 파일은 한 번만 인코딩하며, 합계는 [`MAX_INLINE_BYTES`]까지만 넣는다.
pub fn inline_local_images(html: &str, base_dir: &Path) -> (String, usize) {
    let mut missing = 0;
    let mut cache: HashMap<PathBuf, String> = HashMap::new();
    let mut budget = MAX_INLINE_BYTES;
    let result = IMG_SRC.replace_all(html, |caps: &Captures| {
        let original = caps[0].to_string();
        let path = decode_image_path(&caps[2]);
        if path.starts_with("http://") || path.starts_with("https://") || path.starts_with("data:") {
            return original;
        }
        let file = if path.starts_with('/') { PathBuf::from(&path) } else { base_dir.join(&path) };
        if !is_image_extension(&extension_of(&file)) {
            return original;
        }
        let uri = match cache.get(&file) {
            Some(uri) => uri.clone(),
            None => {
                let Some((data, ext)) = read_local_image(&file) else {
                    missing += 1;
                    return original;
                };
                let uri = data_uri(&data, &ext);
                cache.insert(file, uri.clone());
                uri
            }
        };
        if uri.len() > budget {
            missing += 1;
            return original;
        }
        budget -= uri.len();
        format!("{}{}\"", &caps[1], uri)
    });
    (result.into_owned(), missing)
}

/// TextBundle 안의 assets/ 이미지를 data URI로 바꾼다. 없는 이미지는 "Image not found" 그림으로 채운다.
/// 같은 첨부물은 한 번만 인코딩하고, 합계는 [`MAX_INLINE_BYTES`]까지만 넣는다.
pub fn inline_assets(html: &str, assets: &HashMap<String, Vec<u8>>) -> String {
    let mut cache: HashMap<String, String> = HashMap::new();
    let mut budget = MAX_INLINE_BYTES;
    ASSET_SRC
        .replace_all(html, |caps: &Captures| {
            let encoded = &caps[2];
            let filename = decode_image_path(encoded);
            let mut uri = match cache.get(&filename) {
                Some(uri) => uri.clone(),
                None => match assets.get(&filename).or_else(|| assets.get(encoded)) {
                    Some(data) => {
                        let ext = filename.rsplit_once('.').map_or("", |(_, e)| e);
                        let uri = data_uri(data, ext);
                        cache.insert(filename.clone(), uri.clone());
                        uri
                    }
                    None => NOT_FOUND.to_string(),
                },
            };
            if uri.len() > budget {
                uri = NOT_FOUND.to_string();
            }
            budget -= budget.min(uri.len());
            format!("{}=\"{}\"", &caps[1], uri)
        })
        .into_owned()
}
