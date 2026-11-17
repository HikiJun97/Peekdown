// TextBundle(.textbundle 폴더)과 TextPack(.textpack ZIP) 읽기. http://textbundle.org/spec/
//   info.json   메타데이터
//   text.*      본문(확장자 자유)
//   assets/     본문이 assets/… 경로로 가리키는 첨부물
// 본문과 첨부물만 읽고, 크기는 ZIP과 같은 상한(파일당 64MB, 합계 256MB)을 넘지 않는다.

use crate::zip::{self, MAX_ENTRY_SIZE, MAX_TOTAL_SIZE};
use std::collections::HashMap;
use std::fs;
use std::ops::Range;
use std::path::Path;
use crate::render::options;
use comrak::nodes::NodeValue;
use comrak::{Arena, parse_document};

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
                // 본문은 루트에, 첨부물은 assets/ 아래에만 있다. 다른 폴더(.git 등)는 훑지 않는다
                if relative == "assets" || relative.starts_with("assets/") {
                    pending.push((entry.path(), format!("{relative}/")));
                }
                continue;
            }
            let size = meta.len() as usize;
            if !meta.is_file() || !is_wanted(&relative) || size > MAX_ENTRY_SIZE || total + size > MAX_TOTAL_SIZE {
                continue;
            }
            // 크기를 본 뒤 파일이 커졌을 수 있어 읽은 크기로 다시 따진다
            if let Some(data) = fs::read(entry.path()).ok().filter(|d| d.len() <= MAX_ENTRY_SIZE && total + d.len() <= MAX_TOTAL_SIZE) {
                total += data.len();
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
/// 경로 끝은 짝이 맞지 않는 첫 `)`다(`a (1) b.png`). 코드 블록과 코드 스팬 안은 글자 그대로 보여야 해서 고치지 않는다.
/// 정규식은 공백이 많은 줄에서 되돌아가기가 폭발해, 앞에서 한 번만 훑는다(문서 길이에 비례).
pub fn encode_asset_spaces(markdown: &str) -> String {
    let code = code_ranges(markdown);
    let mut code = code.iter().peekable();
    let mut result = String::with_capacity(markdown.len());
    let mut cursor = 0;
    while let Some(found) = markdown[cursor..].find("](assets/") {
        let at = cursor + found;
        while code.peek().is_some_and(|r| r.end <= at) {
            code.next();
        }
        if let Some(r) = code.peek().filter(|r| r.start <= at) {
            result.push_str(&markdown[cursor..r.end]);
            cursor = r.end;
            continue;
        }
        let path_start = at + 2;
        let mut end = markdown.len();
        let mut parens = 0;
        for (i, c) in markdown[path_start..].char_indices() {
            match c {
                '\n' | '\r' => {
                    end = path_start + i;
                    break;
                }
                '(' => parens += 1,
                ')' if parens == 0 => {
                    end = path_start + i;
                    break;
                }
                ')' => parens -= 1,
                _ => {}
            }
        }
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

/// 코드 블록(들여쓰기·펜스)과 코드 스팬이 원문에서 차지하는 바이트 범위를 앞에서부터 순서대로.
/// 블록은 파서가 읽은 줄 범위를 쓰고, 스팬은 블록 밖에서 같은 길이의 백틱 묶음끼리 짝짓는다.
fn code_ranges(markdown: &str) -> Vec<Range<usize>> {
    let arena = Arena::new();
    let root = parse_document(&arena, markdown, &options());
    let bytes = markdown.as_bytes();
    let mut line_starts = vec![0];
    for (i, &b) in bytes.iter().enumerate() {
        if b == b'\n' || (b == b'\r' && bytes.get(i + 1) != Some(&b'\n')) {
            line_starts.push(i + 1);
        }
    }
    let line = |n: usize| line_starts.get(n).copied().unwrap_or(markdown.len());
    let mut blocks: Vec<Range<usize>> = root
        .descendants()
        .filter(|n| matches!(n.data().value, NodeValue::CodeBlock(_)))
        .map(|n| {
            let pos = n.data().sourcepos;
            line(pos.start.line.saturating_sub(1))..line(pos.end.line)
        })
        .collect();
    blocks.sort_by_key(|r| r.start);

    let mut ranges = Vec::new();
    let mut i = 0;
    let mut open: Option<(usize, usize)> = None; // (여는 백틱 묶음 위치, 길이)
    let mut blocks = blocks.into_iter().peekable();
    while i < bytes.len() {
        if let Some(block) = blocks.peek().filter(|b| b.start <= i).cloned() {
            blocks.next();
            open = None; // 코드 스팬은 블록을 넘지 못한다
            i = i.max(block.end);
            ranges.push(block);
            continue;
        }
        match bytes[i] {
            b'\\' if open.is_none() => i += 2,
            b'`' => {
                let run = bytes[i..].iter().take_while(|&&b| b == b'`').count();
                match open {
                    Some((start, len)) if len == run => {
                        ranges.push(start..i + run);
                        open = None;
                    }
                    None => open = Some((i, run)),
                    _ => {}
                }
                i += run;
            }
            _ => i += 1,
        }
    }
    ranges.sort_by_key(|r| r.start);
    ranges
}
