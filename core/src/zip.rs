// TextPack에 쓰는 최소한의 ZIP 읽기·쓰기. ZIP64와 암호화는 지원하지 않는다.

use std::collections::HashSet;
use std::ops::Range;

/// 항목 하나·전체 합계의 상한. 문서와 이미지에는 넉넉하고, 헤더 크기를 부풀린 ZIP으로 메모리를 다 쓰지 못하게 한다.
pub const MAX_ENTRY_SIZE: usize = 64 << 20;
pub const MAX_TOTAL_SIZE: usize = 256 << 20;

/// central directory 항목 하나. 데이터는 [`extract`]로 필요할 때만 푼다.
#[derive(Debug, Clone)]
pub struct ZipRecord {
    pub path: String,
    pub method: u16,
    pub uncompressed_size: usize,
    pub data_range: Range<usize>,
}

// 정렬되지 않은 위치도 읽을 수 있게 바이트를 직접 조합한다(little-endian). 범위를 벗어나면 0.
fn u16_at(data: &[u8], offset: usize) -> usize {
    data.get(offset..offset + 2).map_or(0, |b| u16::from_le_bytes([b[0], b[1]]) as usize)
}

fn u32_at(data: &[u8], offset: usize) -> usize {
    data.get(offset..offset + 4).map_or(0, |b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize)
}

/// 파일 끝의 central directory를 읽어 항목 목록을 만든다. 로컬 헤더에 크기를 0으로 적고 뒤에 데이터
/// 디스크립터를 두는 ZIP(Finder 압축, 스트리밍으로 만든 zip)도 읽는다.
pub fn records(data: &[u8]) -> Vec<ZipRecord> {
    // End of central directory: 시그니처 0x06054b50, 최소 22바이트, 그 뒤 주석이 최대 65535바이트
    if data.len() < 22 {
        return Vec::new();
    }
    let lowest = data.len().saturating_sub(22 + 0xFFFF);
    let Some(eocd) = (lowest..=data.len() - 22).rev().find(|&i| u32_at(data, i) == 0x06054b50) else {
        return Vec::new();
    };

    let count = u16_at(data, eocd + 10);
    let mut offset = u32_at(data, eocd + 16);
    let mut records = Vec::new();
    let mut seen_local_headers = HashSet::new();
    for _ in 0..count {
        if offset + 46 > data.len() || u32_at(data, offset) != 0x02014b50 {
            break;
        }
        let method = u16_at(data, offset + 10) as u16;
        let compressed_size = u32_at(data, offset + 20);
        let uncompressed_size = u32_at(data, offset + 24);
        let name_length = u16_at(data, offset + 28);
        let extra_length = u16_at(data, offset + 30);
        let comment_length = u16_at(data, offset + 32);
        let local_offset = u32_at(data, offset + 42);
        let name_end = offset + 46 + name_length;
        if name_end > data.len() {
            break;
        }
        let name = &data[offset + 46..name_end];
        // 이름은 UTF-8, 아니면 옛 ZIP처럼 Latin-1로 읽는다
        let path = match std::str::from_utf8(name) {
            Ok(s) => s.to_string(),
            Err(_) => name.iter().map(|&b| b as char).collect(),
        };
        offset = name_end + extra_length + comment_length;

        // 폴더 항목과 경로 조작(../)은 건너뛴다
        if path.ends_with('/') || path.replace('\\', "/").split('/').any(|c| c == "..") {
            continue;
        }
        // 여러 항목이 같은 로컬 데이터를 가리키게 해 같은 데이터를 거듭 풀게 하는 ZIP은 받지 않는다
        if !seen_local_headers.insert(local_offset) {
            continue;
        }
        if uncompressed_size > MAX_ENTRY_SIZE || !(method == 0 || method == 8) {
            continue;
        }

        // 로컬 헤더의 이름·extra 길이는 central directory와 다를 수 있어 따로 읽는다
        if local_offset + 30 > data.len() || u32_at(data, local_offset) != 0x04034b50 {
            continue;
        }
        let data_start = local_offset + 30 + u16_at(data, local_offset + 26) + u16_at(data, local_offset + 28);
        let data_end = data_start + compressed_size;
        if data_end > data.len() {
            continue;
        }
        records.push(ZipRecord { path, method, uncompressed_size, data_range: data_start..data_end });
    }
    records
}

/// 항목 하나를 푼다. 실제로 풀리는 양도 선언 크기(이미 상한 이하)를 넘지 못한다.
pub fn extract(record: &ZipRecord, data: &[u8]) -> Option<Vec<u8>> {
    let raw = data.get(record.data_range.clone())?;
    match record.method {
        0 => (raw.len() <= MAX_ENTRY_SIZE).then(|| raw.to_vec()),
        8 if record.uncompressed_size == 0 => Some(Vec::new()),
        8 => miniz_oxide::inflate::decompress_to_vec_with_limit(raw, record.uncompressed_size).ok(),
        _ => None,
    }
}

/// 항목들을 압축하지 않고(stored) ZIP으로 묶는다. 이름은 UTF-8 플래그를 붙여 한글 파일 이름도 그대로 둔다.
/// 항목이나 전체가 4GB를 넘으면 None(ZIP64는 쓰지 않는다).
pub fn write_stored(entries: &[(String, Vec<u8>)]) -> Option<Vec<u8>> {
    const UTF8_NAMES: u16 = 1 << 11;
    const DOS_DATE_1980_01_01: u16 = (1 << 5) | 1;
    fn le16(out: &mut Vec<u8>, v: u16) {
        out.extend_from_slice(&v.to_le_bytes());
    }
    fn le32(out: &mut Vec<u8>, v: u32) {
        out.extend_from_slice(&v.to_le_bytes());
    }

    let mut out = Vec::new();
    let mut central = Vec::new();
    for (name, data) in entries {
        let size = u32::try_from(data.len()).ok()?;
        let offset = u32::try_from(out.len()).ok()?;
        let name_len = u16::try_from(name.len()).ok()?;
        let crc = crc32(data);

        le32(&mut out, 0x04034b50);
        for v in [20, UTF8_NAMES, 0, 0, DOS_DATE_1980_01_01] {
            le16(&mut out, v);
        }
        for v in [crc, size, size] {
            le32(&mut out, v);
        }
        le16(&mut out, name_len);
        le16(&mut out, 0);
        out.extend_from_slice(name.as_bytes());
        out.extend_from_slice(data);

        le32(&mut central, 0x02014b50);
        // 만든 곳: Unix(3), 버전 2.0
        for v in [(3 << 8) | 20, 20, UTF8_NAMES, 0, 0, DOS_DATE_1980_01_01] {
            le16(&mut central, v);
        }
        for v in [crc, size, size] {
            le32(&mut central, v);
        }
        for v in [name_len, 0, 0, 0, 0] {
            le16(&mut central, v);
        }
        le32(&mut central, 0o100644 << 16); // 일반 파일, rw-r--r--
        le32(&mut central, offset);
        central.extend_from_slice(name.as_bytes());
    }
    let count = u16::try_from(entries.len()).ok()?;
    let central_start = u32::try_from(out.len()).ok()?;
    let central_size = u32::try_from(central.len()).ok()?;
    out.extend_from_slice(&central);
    le32(&mut out, 0x06054b50);
    for v in [0, 0, count, count] {
        le16(&mut out, v);
    }
    le32(&mut out, central_size);
    le32(&mut out, central_start);
    le16(&mut out, 0);
    Some(out)
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0xEDB88320 } else { crc >> 1 };
        }
    }
    !crc
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc32_known_value() {
        assert_eq!(crc32(b"123456789"), 0xCBF43926);
    }

    #[test]
    fn written_zip_reads_back() {
        let entries = vec![("a.textbundle/text.md".to_string(), b"# hi".to_vec()), ("a.textbundle/assets/스.png".to_string(), vec![1, 2, 3])];
        let zip = write_stored(&entries).unwrap();
        let recs = records(&zip);
        assert_eq!(recs.iter().map(|r| r.path.as_str()).collect::<Vec<_>>(), ["a.textbundle/text.md", "a.textbundle/assets/스.png"]);
        assert_eq!(extract(&recs[1], &zip).unwrap(), vec![1, 2, 3]);
    }
}
