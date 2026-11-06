// 마크다운과 그 문서가 참조하는 로컬 이미지를 TextBundle 하나로 묶는다. http://textbundle.org/spec/
//   이름.textbundle/
//     text.md      이미지 경로를 assets/… 로 바꾼 본문
//     info.json    {"version": 2, "type": "net.daringfireball.markdown", …}
//     assets/      이미지 파일
// .textpack은 이 폴더를 통째로 ZIP으로 묶은 것이다(Obsidian Importer 등은 ZIP 안의 .textbundle 폴더를 찾는다).
//
// 문서는 신뢰할 수 없는 입력이다. 내보낸 파일은 남에게 공유되므로 다음을 지킨다.
// - 원격 이미지(http, https)는 내려받지 않고 링크로 남긴다
// - 로컬 이미지는 심볼릭 링크를 따라간 실제 대상이 일반 파일이고, 이미지 확장자이고, 내용도 이미지일 때만 담는다
// - 담는 파일 이름은 경로 문자를 걸러 assets/ 밖으로 나가지 못하게 한다

use crate::images::{is_image_data, is_image_extension, percent_decode};
use crate::{base64, zip};
use regex_lite::Regex;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::LazyLock;

pub struct Report {
    pub output: PathBuf,
    /// 읽을 수 있는 로컬 이미지가 아니어서 담지 않은 이미지 주소
    pub skipped: Vec<String>,
}

const INFO_JSON: &str = r#"{
  "creatorIdentifier" : "io.github.hikijun97.peekdown",
  "transient" : false,
  "type" : "net.daringfireball.markdown",
  "version" : 2
}"#;

static IMAGE_REF: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"!\[([^\]]*)\]\(([^)]+)\)").unwrap());

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

    // 같은 원본은 한 번만 담는다. 이름은 앞에서부터 정하고, 치환은 일치한 위치에만 한다
    let mut used_names = HashSet::new();
    let mut assigned: HashMap<String, String> = HashMap::new(); // 원본 경로 → assets 안 파일 이름
    let mut assets: Vec<(String, Vec<u8>)> = Vec::new();
    let mut skipped = Vec::new();
    let mut text = String::with_capacity(markdown.len());
    let mut last = 0;
    for caps in IMAGE_REF.captures_iter(&markdown) {
        let whole = caps.get(0).unwrap();
        let original = local_path(&caps[2]);
        if is_remote(&original) {
            continue; // 원격 이미지는 링크로 남긴다
        }
        let name = match assigned.get(&original) {
            Some(name) => name.clone(),
            None => {
                let Some((data, ext)) = load_image(&original, &base_dir) else {
                    skipped.push(original);
                    continue;
                };
                let name = unique_filename(&safe_base_name(&original), &ext, &mut used_names);
                // 걸러낸 이름이라도 마지막으로 assets/ 바로 아래 파일 하나인지 확인한다
                let mut parts = Path::new(&name).components();
                if !matches!((parts.next(), parts.next()), (Some(Component::Normal(_)), None)) {
                    continue;
                }
                assets.push((name.clone(), data));
                assigned.insert(original, name.clone());
                name
            }
        };
        // TextBundle 명세: 본문은 이미지를 assets/ 로 시작하는 상대 경로로 가리켜야 한다
        text.push_str(&markdown[last..whole.start()]);
        text.push_str(&format!("![{}](assets/{})", &caps[1], encode_destination(&name)));
        last = whole.end();
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

/// 마크다운 주소를 실제 경로로 바꾼다: `<a b.png>` 꺾쇠를 벗기고, `a%20b.png` 같은 퍼센트 인코딩을 푼다.
pub fn local_path(destination: &str) -> String {
    let mut path = destination.trim_matches([' ', '\t']);
    if path.len() >= 2 && path.starts_with('<') && path.ends_with('>') {
        path = &path[1..path.len() - 1];
    }
    if path.starts_with("data:") || is_remote(path) {
        return path.to_string();
    }
    percent_decode(path).unwrap_or_else(|| path.to_string())
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

/// 이미지 데이터와 확장자를 읽는다. data URI이거나, 실제 대상이 이미지 내용을 가진 일반 파일일 때만.
fn load_image(path: &str, base_dir: &Path) -> Option<(Vec<u8>, String)> {
    if path.starts_with("data:") {
        let (header, payload) = path.split_once(',')?;
        if !header.ends_with(";base64") {
            return None;
        }
        let data = base64::decode(payload)?;
        let header = header.to_lowercase();
        let ext = [("image/png", "png"), ("image/jpeg", "jpg"), ("image/gif", "gif"), ("image/svg", "svg"), ("image/webp", "webp")]
            .iter()
            .find(|(mime, _)| header.contains(mime))
            .map_or("png", |(_, ext)| ext);
        return is_image_data(&data, ext).then(|| (data, ext.to_string()));
    }
    let file = if path.starts_with('/') { PathBuf::from(path) } else { base_dir.join(path) };
    let real = fs::canonicalize(file).ok()?;
    let ext = real.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    if !is_image_extension(&ext) || !fs::metadata(&real).ok()?.is_file() {
        return None;
    }
    let data = fs::read(&real).ok()?;
    is_image_data(&data, &ext).then_some((data, ext))
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

/// 이미 쓴 이름(새로 만든 a_1 같은 이름 포함)과 대소문자 구분 없이 겹치지 않는 이름을 고른다
pub fn unique_filename(base_name: &str, ext: &str, used: &mut HashSet<String>) -> String {
    let mut candidate = format!("{base_name}.{ext}");
    let mut n = 0;
    while used.contains(&candidate.to_lowercase()) {
        n += 1;
        candidate = format!("{base_name}_{n}.{ext}");
    }
    used.insert(candidate.to_lowercase());
    candidate
}
