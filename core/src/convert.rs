// 마크다운과 그 문서가 참조하는 로컬 이미지를 TextBundle 하나로 묶는다. http://textbundle.org/spec/
//   이름.textbundle/
//     text.md      이미지 경로를 assets/… 로 바꾼 본문
//     info.json    {"version": 2, "type": "net.daringfireball.markdown", …}
//     assets/      이미지 파일
// .textpack은 이 폴더를 통째로 ZIP으로 묶은 것이다(Obsidian Importer 등은 ZIP 안의 .textbundle 폴더를 찾는다).
//
// 문서는 신뢰할 수 없는 입력이다. 내보낸 파일은 남에게 공유되므로 다음을 지킨다.
// - 담는 이미지는 화면에 보이는 마크다운 이미지뿐이다. 파서가 이미지로 읽은 노드만 쓰므로, HTML 주석이나
//   코드 안에 숨긴 참조는 담지 않는다
// - 원격 이미지(http, https)는 내려받지 않고 링크로 남긴다
// - 로컬 이미지는 심볼릭 링크를 따라간 실제 대상이 일반 파일이고, 이미지 확장자이고, 내용도 이미지일 때만 담는다
// - 파일당 64MB, 합계 256MB까지만 담는다(TextPack을 읽을 때의 상한과 같다)
// - 담는 파일 이름은 경로 문자를 걸러 assets/ 밖으로 나가지 못하게 한다

use crate::images::{decode_image_path, is_image_data, read_local_image};
use crate::render::options;
use crate::zip::{self, MAX_ENTRY_SIZE, MAX_TOTAL_SIZE};
use crate::base64;
use comrak::nodes::NodeValue;
use comrak::{Arena, parse_document};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::ops::Range;
use std::path::{Component, Path, PathBuf};
use unicode_normalization::UnicodeNormalization;

pub struct Report {
    pub output: PathBuf,
    /// 담지 않은 로컬 이미지 주소: 읽을 수 있는 이미지 파일이 아니거나 크기 상한을 넘은 것
    pub skipped: Vec<String>,
}

const INFO_JSON: &str = r#"{
  "creatorIdentifier" : "io.github.hikijun97.peekdown",
  "transient" : false,
  "type" : "net.daringfireball.markdown",
  "version" : 2
}"#;

/// 문서 속 마크다운 이미지 하나. range는 원문에서 `![…](…)`(또는 `![…][참조]`) 전체가 차지하는 바이트 범위.
struct ImageRef {
    range: Range<usize>,
    alt: String,
    title: String,
    url: String,
}

/// input을 output(.textpack 파일 또는 .textbundle 폴더)으로 내보낸다. output이 없으면 input 옆에 "이름.textpack".
/// 결과물은 임시 이름으로 다 만든 다음 한 번에 바꿔 넣는다(실패해도 기존 파일이 남는다).
pub fn convert(input: &Path, output: Option<&Path>) -> Result<Report, String> {
    let input = std::path::absolute(input).map_err(|e| e.to_string())?;
    if !input.exists() {
        return Err(format!("File not found: {}", input.display()));
    }
    let bytes = fs::read(&input).map_err(|e| format!("{}: {e}", input.display()))?;
    let markdown = String::from_utf8(bytes).unwrap_or_else(|e| e.into_bytes().iter().map(|&b| b as char).collect());
    let base_dir = input.parent().unwrap_or(Path::new("/")).to_path_buf();

    let output = match output {
        Some(path) => std::path::absolute(path).map_err(|e| e.to_string())?,
        None => base_dir.join(format!("{}.textpack", file_stem(&input))),
    };
    let ext = output.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    if ext != "textpack" && ext != "textbundle" {
        return Err(format!("output must end in .textpack or .textbundle: {}", output.display()));
    }
    let as_folder = ext == "textbundle";
    if let Ok(meta) = fs::metadata(&output) {
        if meta.is_dir() != as_folder {
            let kind = if meta.is_dir() { "folder" } else { "file" };
            return Err(format!("output exists and is a {kind}: {}", output.display()));
        }
    }
    let bundle_name = format!("{}.textbundle", file_stem(&output));

    // 같은 이미지(실제 파일 기준)는 한 번만 담는다. 이름은 앞에서부터 정하고, 치환은 이미지 노드 자리에만 한다
    let mut used_names = HashSet::new();
    let mut assigned: HashMap<String, String> = HashMap::new(); // 실제 경로(또는 data URI) → assets 안 파일 이름
    let mut assets: Vec<(String, Vec<u8>)> = Vec::new();
    let mut total = 0;
    let mut skipped = Vec::new();
    let mut text = String::with_capacity(markdown.len());
    let mut last = 0;
    for image in image_refs(&markdown) {
        if image.range.start < last {
            continue; // 다른 이미지의 대체 텍스트 안에 든 이미지
        }
        if is_remote(&image.url) {
            continue; // 원격 이미지는 링크로 남긴다
        }
        let loaded = load_image(&image.url, &base_dir);
        let name = match loaded.as_ref().and_then(|(key, _, _)| assigned.get(key)) {
            Some(name) => name.clone(),
            None => {
                let Some((key, data, ext)) = loaded.filter(|(_, data, _)| total + data.len() <= MAX_TOTAL_SIZE) else {
                    skipped.push(image.url);
                    continue;
                };
                let name = unique_filename(&safe_base_name(&decode_image_path(&image.url)), &ext, &mut used_names);
                // 걸러낸 이름이라도 마지막으로 assets/ 바로 아래 파일 하나인지 확인한다
                let mut parts = Path::new(&name).components();
                if !matches!((parts.next(), parts.next()), (Some(Component::Normal(_)), None)) {
                    continue;
                }
                total += data.len();
                assets.push((name.clone(), data));
                assigned.insert(key, name.clone());
                name
            }
        };
        // TextBundle 명세: 본문은 이미지를 assets/ 로 시작하는 상대 경로로 가리켜야 한다
        text.push_str(&markdown[last..image.range.start]);
        text.push_str(&format!("![{}](assets/{}{})", escape_alt(&image.alt), encode_destination(&name), title_suffix(&image.title)));
        last = image.range.end;
    }
    text.push_str(&markdown[last..]);

    let mut files = vec![("text.md".to_string(), text.into_bytes()), ("info.json".to_string(), INFO_JSON.as_bytes().to_vec())];
    files.extend(assets.into_iter().map(|(name, data)| (format!("assets/{name}"), data)));
    if as_folder {
        write_folder(&output, &files)?;
    } else {
        let entries: Vec<_> = files.into_iter().map(|(path, data)| (format!("{bundle_name}/{path}"), data)).collect();
        let zip = zip::write_stored(&entries).ok_or("Failed to create ZIP archive: too large")?;
        let temp = temp_sibling(&output);
        fs::write(&temp, zip).and_then(|_| fs::rename(&temp, &output)).map_err(|e| {
            let _ = fs::remove_file(&temp);
            format!("{}: {e}", output.display())
        })?;
    }
    Ok(Report { output, skipped })
}

/// 렌더러와 같은 옵션으로 문서를 읽어 마크다운 이미지 노드를 원문 순서대로 모은다.
/// 소스 위치(1부터 세는 줄·바이트 열)를 원문 바이트 범위로 바꾸고, 범위가 `![`로 시작하지 않으면 버린다.
fn image_refs(markdown: &str) -> Vec<ImageRef> {
    let arena = Arena::new();
    let root = parse_document(&arena, markdown, &options());
    let line_starts: Vec<usize> = std::iter::once(0).chain(markdown.match_indices('\n').map(|(i, _)| i + 1)).collect();
    let offset = |line: usize, column: usize| Some(line_starts.get(line.checked_sub(1)?)? + column.checked_sub(1)?);

    let mut refs = Vec::new();
    for node in root.descendants() {
        let data = node.data();
        let NodeValue::Image(link) = &data.value else { continue };
        let pos = data.sourcepos;
        let (Some(start), Some(last)) = (offset(pos.start.line, pos.start.column), offset(pos.end.line, pos.end.column)) else {
            continue;
        };
        let end = last + 1;
        if end > markdown.len() || !markdown.is_char_boundary(start) || !markdown.is_char_boundary(end) || !markdown[start..end].starts_with("![") {
            continue;
        }
        refs.push(ImageRef { range: start..end, alt: node.collect_text(), title: link.title.clone(), url: link.url.clone() });
    }
    // 각주 정의처럼 파서가 자리를 옮기는 노드가 있어 원문 순서로 다시 놓는다
    refs.sort_by_key(|r| r.range.start);
    refs
}

fn escape_alt(alt: &str) -> String {
    let mut out = String::with_capacity(alt.len());
    for c in alt.chars() {
        match c {
            '\\' | '[' | ']' => {
                out.push('\\');
                out.push(c);
            }
            '\n' | '\r' => out.push(' '),
            _ => out.push(c),
        }
    }
    out
}

fn title_suffix(title: &str) -> String {
    if title.is_empty() {
        return String::new();
    }
    format!(" \"{}\"", title.replace('\\', "\\\\").replace('"', "\\\"").replace(['\n', '\r'], " "))
}

fn file_stem(path: &Path) -> String {
    path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

/// 같은 폴더 안의 임시 이름. 같은 볼륨이어야 rename으로 한 번에 바꿔 넣을 수 있다.
fn temp_sibling(path: &Path) -> PathBuf {
    let mut random = [0u8; 8];
    let _ = getrandom::fill(&mut random);
    let tag: String = random.iter().map(|b| format!("{b:02x}")).collect();
    path.with_file_name(format!(".{}.peekdown-{tag}", path.file_name().unwrap_or_default().to_string_lossy()))
}

/// .textbundle 폴더를 임시 이름으로 다 만든 뒤 기존 폴더와 바꾼다. 실패하면 기존 폴더를 되돌린다.
fn write_folder(output: &Path, files: &[(String, Vec<u8>)]) -> Result<(), String> {
    let temp = temp_sibling(output);
    let build = || -> std::io::Result<()> {
        fs::create_dir_all(temp.join("assets"))?;
        for (path, data) in files {
            fs::write(temp.join(path), data)?;
        }
        Ok(())
    };
    let fail = |e: std::io::Error| format!("{}: {e}", output.display());
    if let Err(e) = build() {
        let _ = fs::remove_dir_all(&temp);
        return Err(fail(e));
    }
    let backup = temp_sibling(output);
    let had_old = output.exists();
    if had_old {
        fs::rename(output, &backup).map_err(|e| {
            let _ = fs::remove_dir_all(&temp);
            fail(e)
        })?;
    }
    if let Err(e) = fs::rename(&temp, output) {
        if had_old {
            let _ = fs::rename(&backup, output);
        }
        let _ = fs::remove_dir_all(&temp);
        return Err(fail(e));
    }
    if had_old {
        let _ = fs::remove_dir_all(&backup);
    }
    Ok(())
}

pub fn is_remote(path: &str) -> bool {
    let lower = path.to_lowercase();
    lower.starts_with("http://") || lower.starts_with("https://") || lower.starts_with("//")
}

/// 파일 이름을 마크다운 주소로 쓸 수 있게 공백·괄호·꺾쇠·%·\ 를 퍼센트 인코딩한다.
/// CommonMark는 공백이 든 주소를 이미지로 보지 않는다.
pub fn encode_destination(filename: &str) -> String {
    let mut out = String::with_capacity(filename.len());
    for c in filename.chars() {
        if " \t()<>%\\".contains(c) || c.is_control() {
            let mut buf = [0u8; 4];
            for b in c.encode_utf8(&mut buf).bytes() {
                out.push_str(&format!("%{b:02X}"));
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// 이미지 주소에서 (같은 이미지인지 가릴 키, 데이터, 확장자)를 읽는다.
/// data URI이거나, 실제 대상이 이미지 내용을 가진 일반 파일이고 64MB 이하일 때만.
fn load_image(url: &str, base_dir: &Path) -> Option<(String, Vec<u8>, String)> {
    if url.starts_with("data:") {
        let (header, payload) = url.split_once(',')?;
        if !header.ends_with(";base64") {
            return None;
        }
        let data = base64::decode(payload).filter(|d| d.len() <= MAX_ENTRY_SIZE)?;
        let header = header.to_lowercase();
        let ext = [("image/png", "png"), ("image/jpeg", "jpg"), ("image/gif", "gif"), ("image/svg", "svg"), ("image/webp", "webp")]
            .iter()
            .find(|(mime, _)| header.contains(mime))
            .map_or("png", |(_, ext)| ext);
        return is_image_data(&data, ext).then(|| (url.to_string(), data, ext.to_string()));
    }
    let path = decode_image_path(url);
    let file = if path.starts_with('/') { PathBuf::from(&path) } else { base_dir.join(&path) };
    let image = read_local_image(&file, MAX_ENTRY_SIZE as u64)?;
    Some((image.real.to_string_lossy().into_owned(), image.data, image.ext))
}

/// assets 안 파일 이름의 기본 부분. 경로 구분자·제어 문자를 걸러 폴더 밖을 가리키지 못하게 한다.
pub fn safe_base_name(path: &str) -> String {
    if path.starts_with("data:") {
        return "inline".to_string();
    }
    let last = path.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    let base = match last.rsplit_once('.') {
        Some((stem, _)) if !stem.is_empty() => stem,
        _ => last,
    };
    let cleaned: String = base.chars().map(|c| if "/\\:".contains(c) || c.is_control() { '_' } else { c }).collect();
    let cleaned = cleaned.trim_start_matches('.');
    if cleaned.is_empty() { "image".to_string() } else { cleaned.chars().take(100).collect() }
}

/// 이미 쓴 이름(새로 만든 a_1 같은 이름 포함)과 겹치지 않는 이름을 고른다. macOS 파일 시스템처럼 대소문자와
/// 유니코드 정규화(é 한 글자와 e + 결합 부호)를 구분하지 않고 비교한다.
pub fn unique_filename(base_name: &str, ext: &str, used: &mut HashSet<String>) -> String {
    let key = |name: &str| name.nfc().collect::<String>().to_lowercase();
    let mut candidate = format!("{base_name}.{ext}");
    let mut n = 0;
    while used.contains(&key(&candidate)) {
        n += 1;
        candidate = format!("{base_name}_{n}.{ext}");
    }
    used.insert(key(&candidate));
    candidate
}
