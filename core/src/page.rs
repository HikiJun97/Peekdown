// 본문 HTML을 완성 페이지로 감싼다. 앱과 QuickLook이 같은 페이지를 띄운다.

use crate::images::{BundleAssets, LocalImages};
use crate::render::{render, render_with_images};
use crate::textbundle;
use std::path::Path;

const CSS: &str = r#"* { margin: 0; padding: 0; box-sizing: border-box; }
:root { color-scheme: light dark; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif;
  max-width: 820px; margin: 0 auto; padding: 24px 40px; line-height: 1.7; font-size: 15px;
}
h1 { font-size: 2em; margin: 0.8em 0 0.4em; padding-bottom: 0.3em; border-bottom: 1px solid; }
h2 { font-size: 1.5em; margin: 0.8em 0 0.4em; padding-bottom: 0.2em; border-bottom: 1px solid; }
h3 { font-size: 1.25em; margin: 0.8em 0 0.4em; }
h4 { font-size: 1.1em; margin: 0.6em 0 0.3em; }
h5, h6 { font-size: 1em; margin: 0.6em 0 0.3em; }
p { margin: 0.6em 0; }
pre { padding: 16px; border-radius: 8px; overflow-x: auto; font-size: 13px; margin: 1em 0; }
code { font-family: 'SF Mono', Menlo, monospace; font-size: 0.9em; padding: 2px 6px; border-radius: 4px; }
pre code { padding: 0; font-size: inherit; background: transparent; }
blockquote { padding: 8px 16px; margin: 1em 0; border-left: 4px solid; border-radius: 2px; }
ul, ol { padding-left: 2em; margin: 0.5em 0; }
li { margin: 0.25em 0; }
table { border-collapse: collapse; margin: 1em 0; width: 100%; }
th, td { padding: 8px 12px; border: 1px solid; text-align: left; }
th { font-weight: 600; }
hr { border: none; height: 1px; margin: 2em 0; }
img { max-width: 100%; border-radius: 4px; margin: 0.5em 0; }
a { text-decoration: none; }
a:hover { text-decoration: underline; }
input[type=checkbox] { margin-right: 6px; }
.mdair-notice {
  padding: 12px 16px; margin-bottom: 20px; border-radius: 8px;
  border-left: 4px solid #f0a020; font-size: 13px; line-height: 1.5;
}
.mdair-notice code { padding: 1px 6px; border-radius: 3px; font-size: 12px; }
#mdair-toast {
  position: fixed; top: 16px; right: 16px;
  padding: 6px 14px; border-radius: 6px;
  font-size: 13px; font-weight: 500;
  background: rgba(40,40,40,0.92); color: #fff;
  opacity: 0; pointer-events: none;
  transform: translateY(-8px);
  transition: opacity 0.18s ease, transform 0.18s ease;
  z-index: 99999;
}
#mdair-toast.show { opacity: 1; transform: translateY(0); }
sup.footnote-ref { font-size: 0.75em; }
.footnotes { margin-top: 2em; padding-top: 1em; border-top: 1px solid; font-size: 0.85em; }
.footnotes ol { padding-left: 1.5em; }
.footnotes p { margin: 0.3em 0; }
@media (prefers-color-scheme: light) {
  body { color: #24292f; background: #fff; }
  h1, h2 { border-bottom-color: #d1d9e0; }
  code { background: #eff1f3; } pre { background: #f6f8fa; }
  blockquote { border-left-color: #d1d9e0; color: #59636e; background: #f6f8fa; }
  th { background: #f6f8fa; } th, td { border-color: #d1d9e0; }
  hr { background: #d1d9e0; } a { color: #0969da; }
  .mdair-notice { background: #fff8e1; color: #6b4f00; }
  .mdair-notice code { background: rgba(0,0,0,0.06); }
  .footnotes { border-top-color: #d1d9e0; color: #59636e; }
}
@media (prefers-color-scheme: dark) {
  body { color: #e6edf3; background: #0d1117; }
  h1, h2 { border-bottom-color: #30363d; }
  code { background: #262c36; } pre { background: #161b22; }
  blockquote { border-left-color: #30363d; color: #8b949e; background: #161b22; }
  th { background: #161b22; } th, td { border-color: #30363d; }
  hr { background: #30363d; } a { color: #58a6ff; }
  .mdair-notice { background: #2a2410; color: #e0c97a; }
  .mdair-notice code { background: rgba(255,255,255,0.08); }
  .footnotes { border-top-color: #30363d; color: #8b949e; }
}
/* Print / PDF export — A4 paper with proper margins, readable colors, no awkward breaks */
@page { size: A4; margin: 18mm 16mm; }
@media print {
  :root { color-scheme: light; }
  html, body {
    color: #24292f !important; background: #fff !important;
    max-width: none !important;
    margin: 0 !important;
    padding: 0 !important;
    font-size: 11pt;
    line-height: 1.55;
    -webkit-print-color-adjust: exact;
    print-color-adjust: exact;
  }
  h1, h2, h3, h4, h5, h6 { page-break-after: avoid; break-after: avoid; }
  h1 { border-bottom-color: #d1d9e0 !important; }
  h2 { border-bottom-color: #d1d9e0 !important; }
  p, li, blockquote { orphans: 3; widows: 3; }
  pre, blockquote, table, figure, img {
    page-break-inside: avoid; break-inside: avoid;
  }
  pre { background: #f6f8fa !important; border: 1px solid #e5e7eb; }
  code { background: #eff1f3 !important; }
  pre code { background: transparent !important; }
  blockquote { background: #f6f8fa !important; border-left-color: #d1d9e0 !important; color: #59636e !important; }
  th { background: #f6f8fa !important; }
  th, td { border-color: #d1d9e0 !important; }
  hr { background: #d1d9e0 !important; }
  a { color: #0969da !important; text-decoration: none; }
  img { max-width: 100% !important; height: auto; }
  #mdair-toast { display: none !important; }
}"#;

/// mermaid.min.js를 실행 파일에 넣어 둔다. QuickLook 확장은 macOS가 외부 네트워크를 막아 CDN에서 받을 수 없다.
/// 3MB가 넘으므로 다이어그램이 있는 문서의 페이지에만 넣는다.
const MERMAID_JS: &str = include_str!("../../resources/mermaid.min.js");

const COPY_TOAST_JS: &str = "(function(){var t=null,m=null;function s(){if(!t){t=document.createElement('div');t.id='mdair-toast';t.textContent='복사됨';document.body.appendChild(t);}t.classList.add('show');clearTimeout(m);m=setTimeout(function(){t.classList.remove('show');},1200);}document.addEventListener('copy',s);})();";

/// 문서 본문은 HTML을 그대로 통과시키므로, CSP로 우리가 넣은 스크립트(nonce가 맞는 것)만 실행한다.
/// 본문에 끼워 넣은 `<script>`, onerror= 같은 인라인 핸들러, javascript: URL은 막힌다.
/// 원격 리소스는 이미지만 허용한다. 원격 스타일시트는 CSS 선택자로 페이지 내용을 밖으로 빼낼 수 있어 막는다.
pub fn page(body: &str, notice: &str) -> String {
    let nonce = new_nonce();
    let mermaid = if body.contains("class=\"mermaid\"") {
        format!(
            "<script nonce='{nonce}'>{MERMAID_JS}</script><script nonce='{nonce}'>mermaid.initialize({{startOnLoad:true,theme:'default'}});</script>"
        )
    } else {
        String::new()
    };
    format!(
        "<!DOCTYPE html><html><head><meta charset='utf-8'>\
         <meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'nonce-{nonce}'; style-src 'unsafe-inline'; img-src data: file: http: https:; font-src data:; object-src 'none'; base-uri 'none'; form-action 'none'\">\
         <style>{CSS}</style></head>\
         <body>{notice}{body}{mermaid}<script nonce='{nonce}'>{COPY_TOAST_JS}</script></body></html>"
    )
}

/// 페이지마다 새로 만드는 CSP nonce(128비트, 16진수). 문서를 쓴 사람이 미리 알 수 없어야 한다.
fn new_nonce() -> String {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).expect("OS 난수를 읽을 수 없다");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// .md 문서 전체 페이지. base_dir가 있으면 그 폴더 기준으로 마크다운 이미지(`![](…)`)를 인라인한다.
/// raw HTML `<img>`는 인라인하지 않는다.
pub fn page_for_markdown(markdown: &str, base_dir: Option<&Path>) -> String {
    page(&markdown_body(markdown, base_dir).0, "")
}

/// [`page_for_markdown`]의 본문과, 읽지 못하거나 넣지 않은 로컬 이미지 수.
/// QuickLook은 샌드박스라 로컬 이미지를 못 읽어서, 이 수로 안내 문구를 붙인다.
pub fn markdown_body(markdown: &str, base_dir: Option<&Path>) -> (String, usize) {
    match base_dir {
        Some(dir) => {
            let mut images = LocalImages::new(dir);
            let body = render_with_images(markdown, |url| images.resolve(url));
            (body, images.missing)
        }
        None => (render(markdown), 0),
    }
}

/// TextBundle(.textbundle 폴더)이나 TextPack(.textpack) 전체 페이지. 읽지 못하면 None.
pub fn page_for_textbundle(path: &Path) -> Option<String> {
    let doc = textbundle::read(path)?;
    let mut assets = BundleAssets::new(&doc.assets);
    Some(page(&render_with_images(&doc.markdown, |url| assets.resolve(url)), ""))
}

/// 각주(#fn-1)처럼 지금 문서 안의 다른 위치로 옮겨 가는 링크인지 판단한다. 이런 이동은 막지 않는다.
/// WebKit이 주는 about:blank#fn-1 같은 주소도 다루도록 # 앞부분을 문자열로 비교한다.
pub fn is_same_document_link(target: &str, current: &str) -> bool {
    let Some((target_base, _)) = target.split_once('#') else { return false };
    target_base == current.split_once('#').map_or(current, |(base, _)| base)
}
