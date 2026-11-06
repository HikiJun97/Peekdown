// TextBundle(.textbundle 폴더)과 TextPack(.textpack ZIP) 읽기. http://textbundle.org/spec/
//   info.json   메타데이터
//   text.*      본문(확장자 자유)
//   assets/     본문이 assets/… 경로로 가리키는 첨부물
// 본문과 첨부물만 읽고, 크기는 ZIP과 같은 상한(파일당 64MB, 합계 256MB)을 넘지 않는다.

use crate::zip::{self, MAX_ENTRY_SIZE, MAX_TOTAL_SIZE};
use std::collections::HashMap;
use std::fs;
use std::path::Path;

pub struct Document {
    pub markdown: String,
    /// 키는 "assets/" 뒤의 경로
    pub assets: HashMap<String, Vec<u8>>,
}

/// 폴더면 TextBundle, 파일이면 TextPack으로 읽는다. 본문(text.*)이 없거나 읽지 못하면 None.
pub fn read(path: &Path) -> Option<Document> {
    let files = if path.is_dir() { files_in_directory(path) } else { files_in_pack(&fs::read(path).ok()?) };
    document(files)
}

fn is_text_file(relative: &str) -> bool {
    relative.starts_with("text.") && !relative.contains('/')
}

fn is_wanted(relative: &str) -> bool {
    is_text_file(relative) || relative.starts_with("assets/")
}

/// .textbundle 폴더 안의 본문과 첨부물을 번들 기준 상대 경로로 모은다. 일반 파일만 읽고 심볼릭 링크는 따라가지 않는다.
fn files_in_directory(root: &Path) -> HashMap<String, Vec<u8>> {
    let mut files = HashMap::new();
    let mut total = 0;
    let mut pending = vec![(root.to_path_buf(), String::new())];
    while let Some((dir, prefix)) = pending.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let Ok(meta) = fs::symlink_metadata(entry.path()) else { continue };
            let Some(name) = entry.file_name().to_str().map(str::to_string) else { continue };
            let relative = format!("{prefix}{name}");
            if meta.is_dir() {
                pending.push((entry.path(), format!("{relative}/")));
                continue;
            }
            let size = meta.len() as usize;
            if !meta.is_file() || !is_wanted(&relative) || size > MAX_ENTRY_SIZE || total + size > MAX_TOTAL_SIZE {
                continue;
            }
            if let Ok(data) = fs::read(entry.path()) {
                total += size;
                files.insert(relative, data);
            }
        }
    }
    files
}

/// .textpack ZIP을 번들 기준 상대 경로로 푼다. 명세가 ZIP 안 구조를 정하지 않아 "이름.textbundle/" 폴더째 든
/// 경우와 내용물이 바로 든 경우를 모두 받는다. 둘 다 있으면 Obsidian Importer처럼 폴더 쪽을 쓴다.
fn files_in_pack(data: &[u8]) -> HashMap<String, Vec<u8>> {
    // macOS가 압축할 때 끼워 넣는 리소스 포크 사본은 버린다
    let records: Vec<_> = zip::records(data)
        .into_iter()
        .filter(|r| !r.path.starts_with("__MACOSX/") && !r.path.rsplit('/').next().unwrap_or("").starts_with("._"))
        .collect();
    let prefix = records
        .iter()
        .find_map(|r| {
            let end = r.path.find(".textbundle/")? + ".textbundle/".len();
            is_text_file(&r.path[end..]).then(|| r.path[..end].to_string())
        })
        .unwrap_or_default();

    let mut files = HashMap::new();
    let mut total = 0;
    for record in records.iter().filter(|r| r.path.starts_with(&prefix)) {
        let relative = &record.path[prefix.len()..];
        // 필요한 항목만, 합계 상한 안에서만 푼다
        if !is_wanted(relative) || total + record.uncompressed_size > MAX_TOTAL_SIZE {
            continue;
        }
        let Some(content) = zip::extract(record, data) else { continue };
        total += record.uncompressed_size.max(content.len());
        files.insert(relative.to_string(), content);
    }
    files
}

fn document(mut files: HashMap<String, Vec<u8>>) -> Option<Document> {
    // 본문은 text.* 하나다. 여러 개면 마크다운 확장자를 먼저 고른다
    const PREFERRED: [&str; 5] = ["md", "markdown", "mdown", "mkd", "txt"];
    let rank = |name: &str| {
        let ext = name.rsplit_once('.').map_or("", |(_, e)| e).to_lowercase();
        PREFERRED.iter().position(|p| *p == ext).unwrap_or(PREFERRED.len())
    };
    let text_name = files.keys().filter(|k| is_text_file(k)).min_by_key(|k| (rank(k), (*k).clone()))?.clone();
    let text = files.remove(&text_name)?;
    let markdown = crate::decode_text(&text);

    let assets = files
        .into_iter()
        .filter_map(|(path, data)| path.strip_prefix("assets/").filter(|rest| !rest.is_empty()).map(|rest| (rest.to_string(), data)))
        .collect();
    Some(Document { markdown: encode_asset_spaces(&markdown), assets })
}

/// `](assets/a b.png)` 처럼 공백을 인코딩하지 않고 쓴 첨부물 경로는 CommonMark가 링크로 보지 않는다.
/// 이런 파일을 만드는 앱도 있을 수 있어 공백만 %20으로 바꿔 읽는다. 따옴표가 있으면 제목일 수 있어 둔다.
/// 정규식은 공백이 많은 줄에서 되돌아가기가 폭발해, 앞에서 한 번만 훑는다(문서 길이에 비례).
pub fn encode_asset_spaces(markdown: &str) -> String {
    let mut result = String::with_capacity(markdown.len());
    let mut cursor = 0;
    while let Some(found) = markdown[cursor..].find("](assets/") {
        let path_start = cursor + found + 2;
        let end = markdown[path_start..].find([')', '\n']).map_or(markdown.len(), |e| path_start + e);
        let path = &markdown[path_start..end];
        result.push_str(&markdown[cursor..path_start]);
        if markdown[end..].starts_with(')') && !path.contains('"') && !path.contains('\'') {
            result.push_str(&path.replace(' ', "%20"));
        } else {
            result.push_str(path);
        }
        cursor = end;
    }
    result.push_str(&markdown[cursor..]);
    result
}
