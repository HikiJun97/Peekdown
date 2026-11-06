// 렌더러·리더 단위 테스트. tests/harness/main.swift의 unit 묶음과 같은 내용을 Rust 구현에 돌린다.

use peekdown_core::images::decode_image_path;
use peekdown_core::textbundle::encode_asset_spaces;
use peekdown_core::{is_same_document_link, render, zip};
use std::time::Instant;

#[test]
fn common_syntax() {
    let html = render(
        "- parent\n  - child\n\nTitle\n---\n\n_italic_ and __bold__ and \\*not italic\\*\n\n\
         See <https://example.com> and [docs][ref].\n\n[ref]: https://example.com/docs\n\n\
         | l | c |\n|:--|:-:|\n| a | b |\n\n3. three\n",
    );
    assert!(html.contains("<li>parent\n<ul>"), "중첩 목록\n{html}");
    assert!(html.contains("<h2>Title</h2>"), "밑줄 제목(setext)");
    assert!(html.contains("<em>italic</em>") && html.contains("<strong>bold</strong>"), "_기울임_ __굵게__");
    assert!(html.contains("*not italic*"), "백슬래시 이스케이프");
    assert!(html.contains("<a href=\"https://example.com\">"), "자동 링크 <https://…>");
    assert!(html.contains("<a href=\"https://example.com/docs\">docs</a>"), "참조 링크");
    assert!(html.contains("align=\"center\""), "표 열 정렬\n{html}");
    assert!(html.contains("<ol start=\"3\">"), "목록 시작 번호");
    assert_eq!(render("a\nb\n"), "<p>a\nb</p>\n", "이어진 줄은 한 문단");
}

#[test]
fn raw_html_and_mermaid() {
    assert!(render("<script>alert(1)</script>\n").contains("&lt;script"), "tagfilter가 <script>를 무력화");
    assert!(render("x <style>a{}</style>\n").contains("&lt;style>"), "인라인 <style>도 무력화");
    assert!(render("<div>ok</div>\n").contains("<div>ok</div>"), "다른 HTML은 그대로");
    let mermaid = render("```mermaid\ngraph TD\n  A-->B\n```\n");
    assert!(mermaid.contains("<pre class=\"mermaid\">") && mermaid.contains("A--&gt;B"), "mermaid 블록 변환\n{mermaid}");
    assert!(render("```rust\nfn x() {}\n```\n").contains("<code class=\"language-rust\">"), "다른 코드 블록은 그대로");
}

#[test]
fn footnotes() {
    let html = render("Claim.[^1] Regex [^a-z] and `[^1]`.\n\n[^1]: Note.\n");
    assert!(html.contains("class=\"footnote-ref\"") && html.contains("<section class=\"footnotes\""), "각주 렌더링\n{html}");
    assert!(html.contains("[^a-z]") && html.contains("<code>[^1]</code>"), "정의 없는 [^…]와 코드는 그대로");
}

#[test]
fn image_path_decoding() {
    for (input, expected) in [
        ("it&#x27;s.png", "it's.png"),
        ("it&#39;s.png", "it's.png"),
        ("a%20b.png", "a b.png"),
        ("a&amp;b.png", "a&b.png"),
        ("%EC%8A%A4.png", "스.png"),
        ("100%.png", "100%.png"),
        ("&amp;#39;.png", "&#39;.png"),
    ] {
        assert_eq!(decode_image_path(input), expected, "decode_image_path({input})");
    }
}

#[test]
fn same_document_links() {
    let dir = "file:///tmp/doc/";
    assert!(is_same_document_link("file:///tmp/doc/#fn-1", dir), "file 기준 #fn-1");
    assert!(is_same_document_link("about:blank#fn-1", "about:blank"), "about:blank 기준 #fn-1");
    assert!(!is_same_document_link("file:///tmp/doc/other.md#x", dir), "다른 문서는 아님");
    assert!(!is_same_document_link("https://example.com/", dir), "외부 주소는 아님");
}

#[test]
fn asset_space_fixing() {
    assert_eq!(encode_asset_spaces("![a](assets/a b.png)"), "![a](assets/a%20b.png)", "공백을 %20으로");
    assert_eq!(encode_asset_spaces("![a](assets/a b.png \"t\")"), "![a](assets/a b.png \"t\")", "제목이 있으면 그대로");
    let hostile = "![](assets/ ".repeat(6000); // 약 72KB 한 줄
    let start = Instant::now();
    encode_asset_spaces(&hostile);
    assert!(start.elapsed().as_secs_f64() < 0.5, "공백이 많은 긴 줄도 빠르게(선형): {:?}", start.elapsed());
}

// MARK: ZIP 자원 제한

struct Item<'a> {
    name: &'a str,
    data: &'a [u8],
    declared_size: Option<u32>,
}

fn item<'a>(name: &'a str, data: &'a [u8]) -> Item<'a> {
    Item { name, data, declared_size: None }
}

/// stored 방식 ZIP. extra_refs만큼 central directory 항목을 더 만들어 첫 항목의 로컬 데이터를 다시 가리키게 한다.
fn make_zip(items: &[Item], extra_refs: usize) -> Vec<u8> {
    fn le16(v: usize) -> [u8; 2] {
        (v as u16).to_le_bytes()
    }
    fn le32(v: u32) -> [u8; 4] {
        v.to_le_bytes()
    }
    let mut out = Vec::new();
    let mut central = Vec::new();
    let mut count = 0;
    let mut first_offset = 0;
    for (index, item) in items.iter().enumerate() {
        let offset = out.len();
        if index == 0 {
            first_offset = offset;
        }
        let size = item.declared_size.unwrap_or(item.data.len() as u32);
        out.extend(le32(0x04034b50));
        for v in [20, 0, 0, 0, 0] {
            out.extend(le16(v));
        }
        out.extend(le32(0));
        out.extend(le32(item.data.len() as u32));
        out.extend(le32(size));
        out.extend(le16(item.name.len()));
        out.extend(le16(0));
        out.extend(item.name.as_bytes());
        out.extend(item.data);
        let refs = if index == 0 { 1 + extra_refs } else { 1 };
        for r in 0..refs {
            let name = if r == 0 { item.name.to_string() } else { format!("{}-{r}", item.name) };
            central.extend(le32(0x02014b50));
            for v in [20, 20, 0, 0, 0, 0] {
                central.extend(le16(v));
            }
            central.extend(le32(0));
            central.extend(le32(item.data.len() as u32));
            central.extend(le32(size));
            central.extend(le16(name.len()));
            for v in [0, 0, 0, 0] {
                central.extend(le16(v));
            }
            central.extend(le32(0));
            central.extend(le32(if index == 0 { first_offset } else { offset } as u32));
            central.extend(name.as_bytes());
            count += 1;
        }
    }
    let cd_start = out.len();
    out.extend(&central);
    out.extend(le32(0x06054b50));
    for v in [0, 0, count, count] {
        out.extend(le16(v));
    }
    out.extend(le32(central.len() as u32));
    out.extend(le32(cd_start as u32));
    out.extend(le16(0));
    out
}

fn paths(data: &[u8]) -> Vec<String> {
    zip::records(data).into_iter().map(|r| r.path).collect()
}

#[test]
fn zip_limits() {
    let tiny = b"# t";
    let inflated = make_zip(&[item("text.md", tiny), Item { name: "assets/big.png", data: tiny, declared_size: Some(4_000_000_000) }], 0);
    assert_eq!(paths(&inflated), ["text.md"], "선언 크기가 상한을 넘는 항목은 버림");
    let records = zip::records(&inflated);
    assert_eq!(zip::extract(&records[0], &inflated).as_deref(), Some(&tiny[..]), "정상 항목은 풀림");

    let overlapping = make_zip(&[item("text.md", tiny)], 200);
    assert_eq!(zip::records(&overlapping).len(), 1, "같은 로컬 항목을 다시 가리키는 항목은 버림");

    let traversal = make_zip(
        &[item("x.textbundle/text.md", tiny), item("../escape.md", tiny), item("x.textbundle/assets/../../text.md", b"# hijack")],
        0,
    );
    assert_eq!(paths(&traversal), ["x.textbundle/text.md"], "../ 항목은 버림");
    assert!(zip::records(&[0x50, 0x4b, 0x05, 0x06]).is_empty(), "잘린 ZIP은 빈 결과");
}
