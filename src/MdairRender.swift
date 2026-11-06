import Foundation
import Compression
import WebKit
import CMarkGFM

// 앱(Peekdown.app)과 QuickLook 확장이 함께 쓰는 렌더링 코드.
// 앱은 ObjC라서 맨 아래 MdairHTML의 @objc 메서드로 부른다.

// MARK: - ZIP Reader (Pure Foundation, Sandbox-Safe)

/// ZIP의 central directory 항목 하나. 데이터는 extract로 필요할 때만 푼다.
struct ZipRecord {
    let path: String
    let method: UInt16
    let uncompressedSize: Int
    let dataRange: Range<Int>
}

enum ZipReader {
    /// 항목 하나·전체 합계의 상한. 문서와 이미지에는 넉넉하고, 헤더 크기를 부풀린 ZIP으로 메모리를 다 쓰지 못하게 한다.
    static let maxEntrySize = 64 << 20
    static let maxTotalSize = 256 << 20

    /// 파일 끝의 central directory를 읽어 항목 목록을 만든다. 로컬 헤더에 크기를 0으로 적고 뒤에 데이터
    /// 디스크립터를 두는 ZIP(Finder 압축, 스트리밍으로 만든 zip)도 읽는다. ZIP64와 암호화는 지원하지 않는다.
    static func records(in data: Data) -> [ZipRecord] {
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
        var records: [ZipRecord] = []
        var seenLocalHeaders: Set<Int> = []
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
            // 여러 항목이 같은 로컬 데이터를 가리키게 해 같은 데이터를 거듭 풀게 하는 ZIP은 받지 않는다
            guard seenLocalHeaders.insert(localOffset).inserted else { continue }
            guard uncompressedSize <= maxEntrySize, method == 0 || method == 8 else { continue }

            // 로컬 헤더의 이름·extra 길이는 central directory와 다를 수 있어 따로 읽는다
            guard localOffset + 30 <= data.count, data.readUInt32(at: localOffset) == 0x04034b50 else { continue }
            let dataStart = localOffset + 30 + Int(data.readUInt16(at: localOffset + 26)) + Int(data.readUInt16(at: localOffset + 28))
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= data.count else { continue }
            records.append(ZipRecord(path: path, method: method, uncompressedSize: uncompressedSize, dataRange: dataStart..<dataEnd))
        }
        return records
    }

    /// 항목 하나를 푼다. 실제로 풀리는 양도 선언 크기(이미 상한 이하)를 넘지 못한다.
    static func extract(_ record: ZipRecord, from data: Data) -> Data? {
        let raw = data.subdata(in: record.dataRange)
        switch record.method {
        case 0: return raw.count <= maxEntrySize ? raw : nil
        case 8: return inflate(raw, uncompressedSize: record.uncompressedSize)
        default: return nil
        }
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
/// 본문과 첨부물만 읽고, 크기는 ZipReader와 같은 상한(파일당 64MB, 합계 256MB)을 넘지 않는다.
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

    private func isWanted(_ relative: String) -> Bool {
        isTextFile(relative) || relative.hasPrefix("assets/")
    }

    /// .textbundle 폴더 안의 본문과 첨부물을 번들 기준 상대 경로로 모은다. 일반 파일만 읽고 심볼릭 링크는 따라가지 않는다.
    private func filesInDirectory(_ dir: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        var total = 0
        let root = dir.standardizedFileURL.path + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return files }
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(root) else { continue }
            let relative = String(path.dropFirst(root.count))
            let size = values.fileSize ?? 0
            guard isWanted(relative), size <= ZipReader.maxEntrySize, total + size <= ZipReader.maxTotalSize else { continue }
            files[relative] = try Data(contentsOf: file)
            total += size
        }
        return files
    }

    /// .textpack ZIP을 번들 기준 상대 경로로 푼다. 명세가 ZIP 안 구조를 정하지 않아 "이름.textbundle/" 폴더째 든
    /// 경우와 내용물이 바로 든 경우를 모두 받는다. 둘 다 있으면 Obsidian Importer처럼 폴더 쪽을 쓴다.
    private func filesInPack(_ data: Data) -> [String: Data] {
        let records = ZipReader.records(in: data).filter {
            // macOS가 압축할 때 끼워 넣는 리소스 포크 사본은 버린다
            !$0.path.hasPrefix("__MACOSX/") && !($0.path.split(separator: "/").last?.hasPrefix("._") ?? false)
        }
        var prefix = ""
        if let nested = records.first(where: {
            guard let range = $0.path.range(of: ".textbundle/") else { return false }
            return isTextFile(String($0.path[range.upperBound...]))
        }), let range = nested.path.range(of: ".textbundle/") {
            prefix = String(nested.path[..<range.upperBound])
        }
        var files: [String: Data] = [:]
        var total = 0
        for record in records where record.path.hasPrefix(prefix) {
            let relative = String(record.path.dropFirst(prefix.count))
            // 필요한 항목만, 합계 상한 안에서만 푼다
            guard isWanted(relative), total + record.uncompressedSize <= ZipReader.maxTotalSize,
                  let content = ZipReader.extract(record, from: data) else { continue }
            files[relative] = content
            total += max(record.uncompressedSize, content.count)
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

    /// ](assets/a b.png) 처럼 공백을 인코딩하지 않고 쓴 첨부물 경로는 CommonMark가 링크로 보지 않는다.
    /// 이런 파일을 만드는 앱도 있을 수 있어 공백만 %20으로 바꿔 읽는다. 따옴표가 있으면 제목일 수 있어 둔다.
    /// 정규식은 공백이 많은 줄에서 되돌아가기가 폭발해, 앞에서 한 번만 훑는다(문서 길이에 비례).
    static func encodeAssetSpaces(_ markdown: String) -> String {
        var result = ""
        var cursor = markdown.startIndex
        while let open = markdown.range(of: "](assets/", range: cursor..<markdown.endIndex) {
            let pathStart = markdown.index(open.lowerBound, offsetBy: 2)
            let end = markdown[pathStart...].firstIndex(where: { $0 == ")" || $0 == "\n" }) ?? markdown.endIndex
            let path = markdown[pathStart..<end]
            result += markdown[cursor..<pathStart]
            if end < markdown.endIndex, markdown[end] == ")", !path.contains("\""), !path.contains("'") {
                result += path.replacingOccurrences(of: " ", with: "%20")
            } else {
                result += path
            }
            cursor = end
        }
        result += markdown[cursor...]
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
    /// 원격 리소스는 이미지만 허용한다. 원격 스타일시트는 CSS 선택자로 페이지 내용을 밖으로 빼낼 수 있어 막는다.
    static func page(body: String, notice: String = "") -> String {
        let nonce = UUID().uuidString
        var mermaid = ""
        if body.contains("class=\"mermaid\""), let script = mermaidScript {
            mermaid = "<script nonce='\(nonce)'>\(script)</script>"
                + "<script nonce='\(nonce)'>mermaid.initialize({startOnLoad:true,theme:'default'});</script>"
        }
        return """
        <!DOCTYPE html><html><head><meta charset='utf-8'>\
        <meta http-equiv='Content-Security-Policy' content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; img-src data: file: http: https:; font-src data:; object-src 'none'; base-uri 'none'; form-action 'none'">\
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

    /// 페이지에 data URI로 넣는 이미지의 합계 상한. 같은 이미지를 수백 번 참조해 페이지를 부풀리지 못하게 한다.
    static let maxInlineBytes = 64 << 20

    /// 파일 앞부분이 확장자에 맞는 실제 이미지 형식인지 본다. TextBundleConverter.swift의 같은 검사와 맞춘다.
    static func isImageData(_ data: Data, ext: String) -> Bool {
        let b = [UInt8](data.prefix(12))
        func starts(_ sig: [UInt8]) -> Bool { b.count >= sig.count && Array(b.prefix(sig.count)) == sig }
        switch ext {
        case "png": return starts([0x89, 0x50, 0x4E, 0x47])
        case "jpg", "jpeg": return starts([0xFF, 0xD8, 0xFF])
        case "gif": return starts(Array("GIF8".utf8))
        case "webp": return starts(Array("RIFF".utf8)) && b.count >= 12 && Array(b[8..<12]) == Array("WEBP".utf8)
        case "tif", "tiff": return starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A])
        case "svg": return String(decoding: data.prefix(4096), as: UTF8.self).lowercased().contains("<svg")
        default: return false
        }
    }

    /// 로컬 이미지를 읽는다. 심볼릭 링크를 따라간 실제 대상이 일반 파일이고, 이미지 확장자이고, 내용도 이미지일 때만.
    /// 이미지인 척하는 링크나 이름으로 다른 파일을 페이지에 싣지 못하게 한다.
    static func readLocalImage(_ url: URL) -> (data: Data, ext: String)? {
        let real = url.resolvingSymlinksInPath()
        let ext = real.pathExtension.lowercased()
        guard imageExtensions.contains(ext),
              let values = try? real.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= ZipReader.maxEntrySize,
              let data = try? Data(contentsOf: real), isImageData(data, ext: ext) else { return nil }
        return (data, ext)
    }

    /// <img src="로컬경로">를 baseDir 기준으로 읽어 data URI로 바꾼다. 못 읽은 개수도 돌려준다.
    /// 실제 이미지 파일만 읽고(readLocalImage), 같은 파일은 한 번만 인코딩하며, 합계는 maxInlineBytes까지만 넣는다.
    static func inlineLocalImages(_ html: String, baseDir: URL) -> (html: String, missingCount: Int) {
        guard let regex = try? NSRegularExpression(
            pattern: #"(<img\b[^>]*?\ssrc=\")([^\"]+)\""#, options: [.caseInsensitive]
        ) else { return (html, 0) }
        var result = html
        var missingCount = 0
        var cache: [String: String] = [:]
        var budget = maxInlineBytes
        let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
        for match in matches.reversed() {
            guard let attrRange = Range(match.range(at: 1), in: html),
                  let pathRange = Range(match.range(at: 2), in: html) else { continue }
            let attr = String(html[attrRange])
            let path = decodeImagePath(String(html[pathRange]))
            if path.hasPrefix("http://") || path.hasPrefix("https://") || path.hasPrefix("data:") { continue }
            let fileURL = path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseDir.appendingPathComponent(path)
            guard imageExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            let dataURI: String
            if let cached = cache[fileURL.path] {
                dataURI = cached
            } else {
                guard let image = readLocalImage(fileURL) else {
                    missingCount += 1
                    continue
                }
                dataURI = "data:\(mimeType(forExtension: image.ext));base64,\(image.data.base64EncodedString())"
                cache[fileURL.path] = dataURI
            }
            guard dataURI.utf8.count <= budget else {
                missingCount += 1
                continue
            }
            budget -= dataURI.utf8.count
            guard let swiftRange = Range(match.range(at: 0), in: result) else { continue }
            result.replaceSubrange(swiftRange, with: "\(attr)\(dataURI)\"")
        }
        return (result, missingCount)
    }

    /// TextBundle 안의 assets/ 이미지를 data URI로 바꾼다. 없는 이미지는 "Image not found" 그림으로 채운다.
    /// 같은 첨부물은 한 번만 인코딩하고, 합계는 maxInlineBytes까지만 넣는다.
    static func inlineAssets(_ html: String, assets: [String: Data]) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(src|srcset)=\"assets/([^\"]+)\""#, options: []
        ) else { return html }
        let notFound = "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyMDAiIGhlaWdodD0iNTAiPjx0ZXh0IHg9IjEwIiB5PSIzMCIgZmlsbD0iIzk5OSI+SW1hZ2Ugbm90IGZvdW5kPC90ZXh0Pjwvc3ZnPg=="
        var result = html
        var cache: [String: String] = [:]
        var budget = maxInlineBytes
        let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))
        for match in matches.reversed() {
            guard let attrRange = Range(match.range(at: 1), in: result),
                  let filenameRange = Range(match.range(at: 2), in: result),
                  let swiftRange = Range(match.range(at: 0), in: result) else { continue }
            let attr = String(result[attrRange])
            let encoded = String(result[filenameRange])
            let filename = decodeImagePath(encoded)

            var dataURI = notFound
            if let cached = cache[filename] {
                dataURI = cached
            } else if let imgData = assets[filename] ?? assets[encoded] {
                dataURI = "data:\(mimeType(forExtension: (filename as NSString).pathExtension));base64,\(imgData.base64EncodedString())"
                cache[filename] = dataURI
            }
            if dataURI.utf8.count > budget { dataURI = notFound }
            budget -= min(budget, dataURI.utf8.count)
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
