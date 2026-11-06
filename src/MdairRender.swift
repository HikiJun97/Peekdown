import Foundation
import Compression
import WebKit
import CMarkGFM

// 앱(Peekdown.app)과 QuickLook 확장이 함께 쓰는 렌더링 코드.
// 앱은 ObjC라서 맨 아래 MdairHTML의 @objc 메서드로 부른다.

// MARK: - ZIP Reader (Pure Foundation, Sandbox-Safe)

struct ZipEntry {
    let path: String
    let data: Data
}

enum ZipReader {
    /// 파일 끝의 central directory를 읽어 항목을 푼다. 로컬 헤더에 크기를 0으로 적고 뒤에 데이터 디스크립터를
    /// 두는 ZIP(Finder 압축, 스트리밍으로 만든 zip)도 읽을 수 있다. ZIP64와 암호화는 지원하지 않는다.
    static func readEntries(from data: Data) -> [ZipEntry] {
        // End of central directory: 시그니처 0x06054b50, 최소 22바이트, 그 뒤 주석이 최대 65535바이트
        guard data.count >= 22 else { return [] }
        var eocd = -1
        var i = data.count - 22
        let lowest = max(0, data.count - 22 - 0xFFFF)
        while i >= lowest {
            if data.readUInt32(at: i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return [] }

        let count = Int(data.readUInt16(at: eocd + 10))
        var offset = Int(data.readUInt32(at: eocd + 16))
        var entries: [ZipEntry] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.readUInt32(at: offset) == 0x02014b50 else { break }
            let method = data.readUInt16(at: offset + 10)
            let compressedSize = Int(data.readUInt32(at: offset + 20))
            let uncompressedSize = Int(data.readUInt32(at: offset + 24))
            let nameLength = Int(data.readUInt16(at: offset + 28))
            let extraLength = Int(data.readUInt16(at: offset + 30))
            let commentLength = Int(data.readUInt16(at: offset + 32))
            let localOffset = Int(data.readUInt32(at: offset + 42))
            let nameEnd = offset + 46 + nameLength
            guard nameEnd <= data.count else { break }
            let nameData = data.subdata(in: offset + 46 ..< nameEnd)
            let path = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            offset = nameEnd + extraLength + commentLength

            // 폴더 항목과 경로 조작(../)은 건너뛴다
            let components = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            if path.hasSuffix("/") || components.contains("..") { continue }

            // 로컬 헤더의 이름·extra 길이는 central directory와 다를 수 있어 따로 읽는다
            guard localOffset + 30 <= data.count, data.readUInt32(at: localOffset) == 0x04034b50 else { continue }
            let dataStart = localOffset + 30 + Int(data.readUInt16(at: localOffset + 26)) + Int(data.readUInt16(at: localOffset + 28))
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= data.count else { continue }
            let raw = data.subdata(in: dataStart..<dataEnd)

            switch method {
            case 0:  // stored
                entries.append(ZipEntry(path: path, data: raw))
            case 8:  // deflate
                if let inflated = inflate(raw, uncompressedSize: uncompressedSize) {
                    entries.append(ZipEntry(path: path, data: inflated))
                }
            default:
                continue
            }
        }
        return entries
    }

    private static func inflate(_ data: Data, uncompressedSize: Int) -> Data? {
        guard uncompressedSize > 0 else { return Data() }
        let destSize = max(uncompressedSize, 256)
        var destBuffer = [UInt8](repeating: 0, count: destSize)

        let result = data.withUnsafeBytes { srcPtr -> Int in
            guard let srcBase = srcPtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                &destBuffer, destSize,
                srcBase.assumingMemoryBound(to: UInt8.self), data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard result > 0 else { return nil }
        return Data(destBuffer.prefix(result))
    }
}

private extension Data {
    // 정렬되지 않은 위치도 읽을 수 있게 바이트를 직접 조합한다(little-endian)
    func readUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}

// MARK: - TextBundle Reader

/// TextBundle(.textbundle 폴더)과 TextPack(.textpack ZIP)을 읽는다. http://textbundle.org/spec/
///   info.json   메타데이터
///   text.*      본문(확장자 자유)
///   assets/     본문이 assets/… 경로로 가리키는 첨부물
struct TextBundleReader {
    struct Document {
        let markdown: String
        let assets: [String: Data]  // 키는 "assets/" 뒤의 경로
    }

    enum ReadError: Error { case noTextFile }

    func read(url: URL) throws -> Document {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return try document(from: try filesInDirectory(url))
        }
        return try document(from: filesInPack(try Data(contentsOf: url)))
    }

    /// .textbundle 폴더 안의 파일을 번들 기준 상대 경로로 모은다
    private func filesInDirectory(_ dir: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let root = dir.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return files }
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(root) else { continue }
            let relative = String(path.dropFirst(root.count))
            // 본문과 첨부물만 읽는다
            guard relative.hasPrefix("text.") || relative.hasPrefix("assets/") else { continue }
            files[relative] = try Data(contentsOf: file)
        }
        return files
    }

    /// .textpack ZIP을 번들 기준 상대 경로로 푼다. 명세가 ZIP 안 구조를 정하지 않아
    /// 내용물이 바로 들어 있는 경우와 "이름.textbundle/" 폴더째 들어 있는 경우를 모두 받는다.
    private func filesInPack(_ data: Data) -> [String: Data] {
        let entries = ZipReader.readEntries(from: data).filter {
            // macOS가 압축할 때 끼워 넣는 리소스 포크 사본은 버린다
            !$0.path.hasPrefix("__MACOSX/") && !($0.path.split(separator: "/").last?.hasPrefix("._") ?? false)
        }
        var prefix = ""
        if !entries.contains(where: { isTextFile($0.path) }),
           let nested = entries.first(where: { $0.path.contains(".textbundle/") && isTextFile(String($0.path.split(separator: "/").last ?? "")) }),
           let range = nested.path.range(of: ".textbundle/") {
            prefix = String(nested.path[..<range.upperBound])
        }
        var files: [String: Data] = [:]
        for entry in entries where entry.path.hasPrefix(prefix) {
            files[String(entry.path.dropFirst(prefix.count))] = entry.data
        }
        return files
    }

    private func isTextFile(_ path: String) -> Bool {
        path.hasPrefix("text.") && !path.contains("/")
    }

    private func document(from files: [String: Data]) throws -> Document {
        // 본문은 text.* 하나다. 여러 개면 마크다운 확장자를 먼저 고른다
        let preferred = ["md", "markdown", "mdown", "mkd", "txt"]
        let textNames = files.keys.filter(isTextFile).sorted {
            (preferred.firstIndex(of: ($0 as NSString).pathExtension.lowercased()) ?? preferred.count)
                < (preferred.firstIndex(of: ($1 as NSString).pathExtension.lowercased()) ?? preferred.count)
        }
        guard let textName = textNames.first, let textData = files[textName] else { throw ReadError.noTextFile }
        var markdown = String(data: textData, encoding: .utf8) ?? String(data: textData, encoding: .isoLatin1) ?? ""
        markdown = Self.encodeAssetSpaces(markdown)

        var assets: [String: Data] = [:]
        for (path, data) in files where path.hasPrefix("assets/") && path.count > 7 {
            assets[String(path.dropFirst(7))] = data
        }
        return Document(markdown: markdown, assets: assets)
    }

    // 따옴표가 있으면 ![a](assets/x.png "제목") 같은 제목일 수 있어 건드리지 않는다
    private static let unencodedAssetLink = try! NSRegularExpression(pattern: #"(!\[[^\]\n]*\]\()(assets/[^)\n"']* [^)\n"']*)\)"#)

    /// ![a](assets/a b.png)처럼 공백을 인코딩하지 않고 쓴 첨부물 경로는 CommonMark가 이미지로 보지 않는다.
    /// 이런 파일을 만드는 앱도 있을 수 있어 공백만 %20으로 바꿔 읽는다.
    static func encodeAssetSpaces(_ markdown: String) -> String {
        var result = markdown
        for match in unencodedAssetLink.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).reversed() {
            guard let whole = Range(match.range, in: result),
                  let head = Range(match.range(at: 1), in: result),
                  let path = Range(match.range(at: 2), in: result) else { continue }
            let fixed = result[head] + result[path].replacingOccurrences(of: " ", with: "%20") + ")"
            result.replaceSubrange(whole, with: fixed)
        }
        return result
    }
}

// MARK: - Markdown Renderer

/// CommonMark + GitHub Flavored Markdown 렌더러 (cmark-gfm).
struct MarkdownRenderer {
    private static let extensions = ["table", "strikethrough", "autolink", "tagfilter", "tasklist"]
    // HTML은 지금처럼 통과시킨다. 문서 속 스크립트는 페이지의 CSP가 막고,
    // <script>·<style>·<iframe> 같은 위험한 태그는 tagfilter 확장이 무력화한다.
    // 각주([^1])는 GitHub처럼 지원한다. 정의가 있는 [^이름]만 각주가 되므로 [^a-z] 같은 일반 글은 그대로다.
    private static let options = CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES
    private static let registered: Void = cmark_gfm_core_extensions_ensure_registered()

    func render(_ markdown: String) -> String {
        _ = Self.registered
        guard let parser = cmark_parser_new(Self.options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in Self.extensions {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }
        var source = markdown
        source.withUTF8 { cmark_parser_feed(parser, $0.baseAddress, $0.count) }
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        guard let rendered = cmark_render_html(document, Self.options, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(rendered) }
        return Self.mermaidBlocks(String(cString: rendered))
    }

    // ```mermaid 블록을 mermaid.js가 찾는 <pre class="mermaid">로 바꾼다.
    // 내용은 이스케이프된 채로 두며, mermaid가 엔티티를 풀어서 읽는다.
    private static let mermaidPattern = try! NSRegularExpression(
        pattern: #"<pre><code class="language-mermaid">([\s\S]*?)</code></pre>"#)

    private static func mermaidBlocks(_ html: String) -> String {
        mermaidPattern.stringByReplacingMatches(
            in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "<pre class=\"mermaid\">$1</pre>")
    }
}

// MARK: - Navigation Guard

/// 문서가 스스로 창을 다른 페이지로 옮기지 못하게 막는다(<meta http-equiv="refresh">, 폼 제출 등).
/// 옮겨 간 페이지에는 우리 CSP가 없어 그 페이지의 스크립트가 그대로 돈다.
/// 처음 문서를 불러오는 이동만 허용하고, 그 뒤 메인 프레임 이동은 사용자의 링크 클릭과 같은 문서 안 이동만 둔다.
/// "로드가 끝났는지"가 아니라 "첫 이동인지"로 판단한다. 지연 0초 refresh는 로드가 끝나기 전에 일어날 수 있다.
@objc(MdairNavigationGuard)
public final class NavigationGuard: NSObject {
    private let navigated = NSHashTable<WKWebView>.weakObjects()

    /// 같은 WebView에 새 문서를 불러오기 직전에 부른다.
    @objc(prepareForLoadInWebView:)
    public func prepareForLoad(in webView: WKWebView) {
        navigated.remove(webView)
    }

    @objc(shouldBlock:inWebView:)
    public func shouldBlock(_ action: WKNavigationAction, in webView: WKWebView) -> Bool {
        guard action.targetFrame?.isMainFrame == true,
              action.navigationType != .linkActivated,
              !MdairHTML.isSameDocumentLink(action.request.url, currentURL: webView.url) else { return false }
        if navigated.contains(webView) { return true }
        navigated.add(webView)
        return false
    }
}

// MARK: - Page & Image Inlining

@objc(MdairHTML)
public final class MdairHTML: NSObject {
    static let css = """
    * { margin: 0; padding: 0; box-sizing: border-box; }
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
    }
    """

    /// 번들에 넣은 mermaid.min.js. QuickLook 확장은 macOS가 외부 네트워크를 막아 CDN에서 받을 수 없다.
    /// 3MB가 넘으므로 다이어그램이 있는 문서에만 넣는다.
    static let mermaidScript: String? = Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// 문서 본문은 HTML을 그대로 통과시키므로, CSP로 우리가 넣은 스크립트(nonce가 맞는 것)만 실행한다.
    /// 본문에 끼워 넣은 <script>, onerror= 같은 인라인 핸들러, javascript: URL은 막힌다.
    static func page(body: String, notice: String = "") -> String {
        let nonce = UUID().uuidString
        var mermaid = ""
        if body.contains("class=\"mermaid\""), let script = mermaidScript {
            mermaid = "<script nonce='\(nonce)'>\(script)</script>"
                + "<script nonce='\(nonce)'>mermaid.initialize({startOnLoad:true,theme:'default'});</script>"
        }
        return """
        <!DOCTYPE html><html><head><meta charset='utf-8'>\
        <meta http-equiv='Content-Security-Policy' content="script-src 'nonce-\(nonce)'; object-src 'none'; base-uri 'none'; form-action 'none'">\
        <style>\(css)</style></head>\
        <body>\(notice)\(body)\
        \(mermaid)\
        <script nonce='\(nonce)'>(function(){var t=null,m=null;function s(){if(!t){t=document.createElement('div');t.id='mdair-toast';t.textContent='복사됨';document.body.appendChild(t);}t.classList.add('show');clearTimeout(m);m=setTimeout(function(){t.classList.remove('show');},1200);}document.addEventListener('copy',s);})();</script>\
        </body></html>
        """
    }

    /// 각주(#fn-1)처럼 지금 문서 안의 다른 위치로 옮겨 가는 링크인지 판단한다. 이런 이동은 막지 않는다.
    @objc(isSameDocumentLink:currentURL:)
    public static func isSameDocumentLink(_ url: URL?, currentURL: URL?) -> Bool {
        // WebKit이 주는 about:blank#fn-1 은 URL.fragment가 nil이라 문자열로 # 앞부분을 비교한다(TextBundle은 about:blank에서 열린다)
        guard let target = url?.absoluteString, let current = currentURL?.absoluteString,
              let hash = target.firstIndex(of: "#") else { return false }
        let currentBase = current.firstIndex(of: "#").map { String(current[..<$0]) } ?? current
        return String(target[..<hash]) == currentBase
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "tiff", "tif": return "image/tiff"
        default: return "image/png"
        }
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "tiff", "tif"]

    private static let numericEntity = try! NSRegularExpression(pattern: "&#([xX][0-9a-fA-F]+|[0-9]+);")

    /// HTML 속성에 든 이미지 주소를 실제 파일 경로로 되돌린다.
    /// cmark는 주소를 퍼센트 인코딩하고(공백 → %20, 한글 → %EC…) ' 와 & 를 &#x27; &amp; 로 바꾼다.
    /// 엔티티를 먼저 풀고(&amp; 는 마지막) 그다음 퍼센트 인코딩을 푼다.
    static func decodeImagePath(_ value: String) -> String {
        var s = value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        for match in numericEntity.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(match.range, in: s), let digits = Range(match.range(at: 1), in: s) else { continue }
            let text = s[digits]
            let code = text.hasPrefix("x") || text.hasPrefix("X") ? UInt32(text.dropFirst(), radix: 16) : UInt32(text)
            if let code, let scalar = Unicode.Scalar(code) {
                s.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        return s.removingPercentEncoding ?? s
    }

    /// <img src="로컬경로">를 baseDir 기준으로 읽어 data URI로 바꾼다. 못 읽은 개수도 돌려준다.
    /// 문서가 아무 파일이나 페이지에 싣지 못하도록 <img>의 이미지 확장자 파일만 읽는다.
    static func inlineLocalImages(_ html: String, baseDir: URL) -> (html: String, missingCount: Int) {
        guard let regex = try? NSRegularExpression(
            pattern: #"(<img\b[^>]*?\ssrc=\")([^\"]+)\""#, options: [.caseInsensitive]
        ) else { return (html, 0) }
        var result = html
        var missingCount = 0
        let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
        for match in matches.reversed() {
            guard let attrRange = Range(match.range(at: 1), in: html),
                  let pathRange = Range(match.range(at: 2), in: html) else { continue }
            let attr = String(html[attrRange])
            let path = decodeImagePath(String(html[pathRange]))
            if path.hasPrefix("http://") || path.hasPrefix("https://") || path.hasPrefix("data:") { continue }
            let fileURL = path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseDir.appendingPathComponent(path)
            guard imageExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            guard let imgData = try? Data(contentsOf: fileURL) else {
                missingCount += 1
                continue
            }
            let dataURI = "data:\(mimeType(forExtension: fileURL.pathExtension));base64,\(imgData.base64EncodedString())"
            guard let swiftRange = Range(match.range(at: 0), in: result) else { continue }
            result.replaceSubrange(swiftRange, with: "\(attr)\(dataURI)\"")
        }
        return (result, missingCount)
    }

    /// TextBundle 안의 assets/ 이미지를 data URI로 바꾼다. 없는 이미지는 "Image not found" 그림으로 채운다.
    static func inlineAssets(_ html: String, assets: [String: Data]) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(src|srcset)=\"assets/([^\"]+)\""#, options: []
        ) else { return html }
        var result = html
        let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
        for match in matches.reversed() {
            guard let attrRange = Range(match.range(at: 1), in: result),
                  let filenameRange = Range(match.range(at: 2), in: result),
                  let swiftRange = Range(match.range(at: 0), in: result) else { continue }
            let attr = String(result[attrRange])
            let encoded = String(result[filenameRange])
            let filename = decodeImagePath(encoded)

            guard let imgData = assets[filename] ?? assets[encoded] else {
                result.replaceSubrange(swiftRange, with: "\(attr)=\"data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyMDAiIGhlaWdodD0iNTAiPjx0ZXh0IHg9IjEwIiB5PSIzMCIgZmlsbD0iIzk5OSI+SW1hZ2Ugbm90IGZvdW5kPC90ZXh0Pjwvc3ZnPg==\"")
                continue
            }
            let dataURI = "data:\(mimeType(forExtension: (filename as NSString).pathExtension));base64,\(imgData.base64EncodedString())"
            result.replaceSubrange(swiftRange, with: "\(attr)=\"\(dataURI)\"")
        }
        return result
    }

    // MARK: ObjC 진입점 (Peekdown.app)

    /// .md 문서 전체 페이지. baseDir가 있으면 로컬 이미지를 인라인한다.
    @objc(pageForMarkdown:baseDir:)
    public static func page(forMarkdown markdown: String, baseDir: String?) -> String {
        var body = MarkdownRenderer().render(markdown)
        if let baseDir = baseDir {
            body = inlineLocalImages(body, baseDir: URL(fileURLWithPath: baseDir)).html
        }
        return page(body: body)
    }

    /// TextBundle(.textbundle 폴더)이나 TextPack(.textpack) 전체 페이지. 읽지 못하면 nil.
    @objc(pageForTextBundle:)
    public static func page(forTextBundle path: String) -> String? {
        guard let doc = try? TextBundleReader().read(url: URL(fileURLWithPath: path)) else { return nil }
        return page(body: inlineAssets(MarkdownRenderer().render(doc.markdown), assets: doc.assets))
    }
}
