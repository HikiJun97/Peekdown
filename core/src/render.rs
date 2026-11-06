// CommonMark + GitHub Flavored Markdown 렌더러 (comrak).

use comrak::adapters::CodefenceRendererAdapter;
use comrak::nodes::{Node, NodeValue, Sourcepos};
use comrak::options::Plugins;
use comrak::{Arena, Options, format_html_with_plugins, parse_document};
use std::fmt;

/// 마크다운을 HTML 본문으로 바꾼다.
///
/// HTML은 그대로 통과시킨다. 문서 속 스크립트는 페이지의 CSP가 막고, `<script>`·`<style>`·`<iframe>` 같은
/// 위험한 태그는 GFM tagfilter 규칙으로 무력화한다(comrak은 0.56에서 이 확장을 없애 여기서 직접 한다).
/// 각주(`[^1]`)는 GitHub처럼 지원한다. 정의가 있는 `[^이름]`만 각주가 되므로 `[^a-z]` 같은 일반 글은 그대로다.
pub fn render(markdown: &str) -> String {
    render_with_images(markdown, |_| None)
}

/// [`render`]와 같고, 마크다운 이미지(`![](주소)`)의 주소를 image가 돌려준 값으로 바꾼다(None이면 그대로).
/// 이미지를 data URI로 넣을 때 쓴다. 렌더링된 HTML을 정규식으로 고치면 문서가 속성값 안에 숨겨 둔
/// `<img src=…>`까지 바꿔 버려(예: 원격 주소의 쿼리) 로컬 이미지 내용이 밖으로 새므로, 실제 이미지 노드만 바꾼다.
/// raw HTML `<img>`는 건드리지 않는다.
pub fn render_with_images(markdown: &str, mut image: impl FnMut(&str) -> Option<String>) -> String {
    let options = options();
    let arena = Arena::new();
    let root = parse_document(&arena, markdown, &options);
    filter_raw_html(root);
    for node in root.descendants() {
        if let NodeValue::Image(link) = &mut node.data_mut().value {
            if let Some(url) = image(&link.url) {
                link.url = url;
            }
        }
    }

    let mut plugins = Plugins::default();
    plugins.render.codefence_renderers.insert("mermaid".to_string(), &MERMAID);
    let mut html = String::new();
    format_html_with_plugins(root, &options, &mut html, &plugins).expect("String에 쓰기는 실패하지 않는다");
    html
}

/// 렌더링과 내보내기가 같은 문법으로 문서를 읽도록 파서 옵션을 한곳에 둔다.
pub(crate) fn options() -> Options<'static> {
    let mut options = Options::default();
    options.extension.table = true;
    options.extension.strikethrough = true;
    options.extension.autolink = true;
    options.extension.tasklist = true;
    options.extension.footnotes = true;
    options.render.r#unsafe = true;
    options
}

/// ```mermaid 블록을 mermaid.js가 찾는 `<pre class="mermaid">`로 낸다.
/// 내용은 이스케이프된 채로 두며, mermaid가 엔티티를 풀어서 읽는다.
struct Mermaid;
static MERMAID: Mermaid = Mermaid;

impl CodefenceRendererAdapter for Mermaid {
    fn write(&self, output: &mut dyn fmt::Write, _lang: &str, _meta: &str, code: &str, _sourcepos: Option<Sourcepos>) -> fmt::Result {
        output.write_str("<pre class=\"mermaid\">")?;
        for c in code.chars() {
            match c {
                '&' => output.write_str("&amp;")?,
                '<' => output.write_str("&lt;")?,
                '>' => output.write_str("&gt;")?,
                '"' => output.write_str("&quot;")?,
                _ => output.write_char(c)?,
            }
        }
        output.write_str("</pre>\n")
    }
}

// MARK: tagfilter (GFM 스펙의 Disallowed Raw HTML. cmark-gfm extensions/tagfilter.c를 바탕으로, 브라우저가
// 태그로 읽는 두 경우를 더 막는다)

const FILTERED_TAGS: [&str; 9] = ["title", "textarea", "style", "xmp", "iframe", "noembed", "noframes", "script", "plaintext"];

/// HTML 블록과 인라인 HTML 모두 안의 모든 `<`를 검사한다. cmark-gfm은 인라인 HTML의 맨 앞 `<`만 보는데,
/// 그러면 `x <!-- --!><style>…` 처럼 주석 노드 안에 넣은 태그가 브라우저에서 살아난다.
fn filter_raw_html<'a>(root: Node<'a>) {
    for node in root.descendants() {
        let mut data = node.data_mut();
        match &mut data.value {
            NodeValue::HtmlBlock(block) => block.literal = filter_tags(&block.literal),
            NodeValue::HtmlInline(html) => *html = filter_tags(html),
            _ => {}
        }
    }
}

fn filter_tags(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut last = 0;
    for (i, _) in html.match_indices('<') {
        if is_filtered_tag(&html.as_bytes()[i..]) {
            out.push_str(&html[last..i]);
            out.push_str("&lt;");
            last = i + 1;
        }
    }
    out.push_str(&html[last..]);
    out
}

fn is_filtered_tag(data: &[u8]) -> bool {
    FILTERED_TAGS.iter().any(|name| is_tag(data, name))
}

/// data가 `<name` 또는 `</name` 다음에 공백, `>`, `/`가 오는 태그로 시작하는지 본다(대소문자 무시).
/// cmark-gfm은 `/` 뒤에 `>`가 와야만 태그로 보지만, 브라우저는 `<style/x>`도 style 태그로 읽는다.
fn is_tag(data: &[u8], name: &str) -> bool {
    if data.len() < 3 || data[0] != b'<' {
        return false;
    }
    let mut i = 1;
    if data[i] == b'/' {
        i += 1;
    }
    for &c in name.as_bytes() {
        if i >= data.len() || data[i].to_ascii_lowercase() != c {
            return false;
        }
        i += 1;
    }
    if i == data.len() {
        return false;
    }
    matches!(data[i], b' ' | b'\t'..=b'\r' | b'>' | b'/')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tagfilter_rules() {
        assert_eq!(filter_tags("<script>x</script>"), "&lt;script>x&lt;/script>");
        assert_eq!(filter_tags("<STYLE >"), "&lt;STYLE >");
        assert_eq!(filter_tags("<title/>"), "&lt;title/>");
        assert_eq!(filter_tags("<style/x>"), "&lt;style/x>");
        assert_eq!(filter_tags("<scripts>"), "<scripts>");
        assert_eq!(filter_tags("<script"), "<script");
        assert_eq!(filter_tags("<!-- --!><style>"), "<!-- --!>&lt;style>");
    }
}
