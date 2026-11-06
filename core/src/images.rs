// 마크다운 이미지를 data URI로 넣는다. 로컬 파일과 TextBundle 첨부물 두 경우가 있다.
// 바꾸는 대상은 렌더러가 넘겨주는 실제 이미지 노드의 주소뿐이다(render::render_with_images 참고).

use crate::base64;
use crate::zip::MAX_ENTRY_SIZE;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

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

/// base64로 바꾼 data URI의 길이(머리말 여유 포함). 파일을 읽기 전에 예산을 따질 때 쓴다.
fn data_uri_len(size: u64) -> usize {
    (size as usize).div_ceil(3) * 4 + 32
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

/// 로컬 이미지를 읽는다. 심볼릭 링크를 따라간 실제 대상이 일반 파일이고, 이미지 확장자이고, 크기가 max 이하이고,
/// 내용도 이미지일 때만. 이미지인 척하는 링크나 이름으로 다른 파일을 싣지 못하게 한다.
/// 실제 경로도 함께 돌려준다(같은 파일을 다른 경로로 가리켜도 한 번만 다루려고).
pub fn read_local_image(path: &Path, max: u64) -> Option<LocalImage> {
    let real = fs::canonicalize(path).ok()?;
    let ext = extension_of(&real);
    let meta = fs::metadata(&real).ok()?;
    if !is_image_extension(&ext) || !meta.is_file() || meta.len() > max {
        return None;
    }
    let data = fs::read(&real).ok()?;
    is_image_data(&data, &ext).then_some(LocalImage { real, data, ext })
}

pub struct LocalImage {
    pub real: PathBuf,
    pub data: Vec<u8>,
    pub ext: String,
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

/// 이미지 주소를 파일 경로로 되돌린다. 엔티티와 백슬래시 이스케이프는 파서가 이미 풀었고, 퍼센트 인코딩만 남아 있다.
pub fn decode_image_path(url: &str) -> String {
    percent_decode(url).unwrap_or_else(|| url.to_string())
}

/// .md 문서의 로컬 이미지를 base_dir 기준으로 읽어 data URI로 바꾼다.
/// 같은 파일(실제 경로 기준)은 한 번만 읽고, 합계는 [`MAX_INLINE_BYTES`]까지만 넣으며, 넘칠 파일은 읽지도 않는다.
pub struct LocalImages<'a> {
    base_dir: &'a Path,
    cache: HashMap<PathBuf, String>,
    budget: usize,
    /// 찾지 못했거나 넣지 않은 로컬 이미지 수
    pub missing: usize,
}

impl<'a> LocalImages<'a> {
    pub fn new(base_dir: &'a Path) -> Self {
        LocalImages { base_dir, cache: HashMap::new(), budget: MAX_INLINE_BYTES, missing: 0 }
    }

    /// 이미지 주소 하나를 data URI로 바꾼다. 원격·data 주소나 이미지 확장자가 아닌 주소는 None(그대로 둔다).
    pub fn resolve(&mut self, url: &str) -> Option<String> {
        let path = decode_image_path(url);
        if path.starts_with("http://") || path.starts_with("https://") || path.starts_with("data:") {
            return None;
        }
        let file = if path.starts_with('/') { PathBuf::from(&path) } else { self.base_dir.join(&path) };
        if !is_image_extension(&extension_of(&file)) {
            return None;
        }
        let uri = self.load(&file);
        match uri {
            Some(uri) if uri.len() <= self.budget => {
                self.budget -= uri.len();
                Some(uri)
            }
            _ => {
                self.missing += 1;
                None
            }
        }
    }

    fn load(&mut self, file: &Path) -> Option<String> {
        let real = fs::canonicalize(file).ok()?;
        if let Some(uri) = self.cache.get(&real) {
            return Some(uri.clone());
        }
        // 예산을 넘길 파일은 읽지 않는다
        let size = fs::metadata(&real).ok()?.len();
        if data_uri_len(size) > self.budget {
            return None;
        }
        let image = read_local_image(&real, MAX_ENTRY_SIZE as u64)?;
        let uri = data_uri(&image.data, &image.ext);
        self.cache.insert(image.real, uri.clone());
        Some(uri)
    }
}

/// TextBundle 안의 assets/ 이미지를 data URI로 바꾼다. 없는 이미지는 "Image not found" 그림으로 채운다.
/// 같은 첨부물은 한 번만 인코딩하고, 합계는 [`MAX_INLINE_BYTES`]까지만 넣는다.
pub struct BundleAssets<'a> {
    assets: &'a HashMap<String, Vec<u8>>,
    cache: HashMap<String, String>,
    budget: usize,
}

impl<'a> BundleAssets<'a> {
    pub fn new(assets: &'a HashMap<String, Vec<u8>>) -> Self {
        BundleAssets { assets, cache: HashMap::new(), budget: MAX_INLINE_BYTES }
    }

    /// assets/ 로 시작하는 주소만 바꾼다.
    pub fn resolve(&mut self, url: &str) -> Option<String> {
        let encoded = url.strip_prefix("assets/")?;
        let filename = decode_image_path(encoded);
        let mut uri = match self.cache.get(&filename) {
            Some(uri) => uri.clone(),
            None => match self.assets.get(&filename).or_else(|| self.assets.get(encoded)) {
                Some(data) => {
                    let uri = data_uri(data, filename.rsplit_once('.').map_or("", |(_, e)| e));
                    self.cache.insert(filename, uri.clone());
                    uri
                }
                None => NOT_FOUND.to_string(),
            },
        };
        if uri.len() > self.budget {
            uri = NOT_FOUND.to_string();
        }
        self.budget -= self.budget.min(uri.len());
        Some(uri)
    }
}
