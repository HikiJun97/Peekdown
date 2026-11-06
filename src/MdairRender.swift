import Foundation
import Compression
import CMarkGFM

// 앱(Peekdown.app)과 QuickLook 확장이 함께 쓰는 렌더링 코드.
// 앱은 ObjC라서 맨 아래 MdairHTML의 @objc 메서드로 부른다.

// MARK: - ZIP Parser (Pure Foundation, Sandbox-Safe)

struct ZipEntry {
    let filename: String
    let uncompressedSize: UInt32
    let data: Data
}

struct ZipReader {
    enum ZipError: Error {
        case invalidArchive
        case unsupportedCompression
        case decompressionFailed
        case pathTraversal
    }

    static func readEntries(from fileURL: URL) throws -> [ZipEntry] {
        let data = try Data(contentsOf: fileURL)
        var entries: [ZipEntry] = []
        var offset = 0

        while offset + 30 <= data.count {
            let sig = data.subdata(in: offset..<offset+4)
            // Local file header signature: 0x04034b50
            guard sig == Data([0x50, 0x4b, 0x03, 0x04]) else { break }

            let compressionMethod = data.readUInt16(at: offset + 8)
            let compressedSize = data.readUInt32(at: offset + 18)
            let uncompressedSize = data.readUInt32(at: offset + 22)
            let filenameLen = data.readUInt16(at: offset + 26)
            let extraLen = data.readUInt16(at: offset + 28)

            let filenameStart = offset + 30
            let filenameEnd = filenameStart + Int(filenameLen)
            guard filenameEnd <= data.count else { break }

            let filenameData = data.subdata(in: filenameStart..<filenameEnd)
            let filename = String(data: filenameData, encoding: .utf8) ?? ""

            let dataStart = filenameEnd + Int(extraLen)
            let dataEnd = dataStart + Int(compressedSize)
            guard dataEnd <= data.count else { break }

            // Path traversal protection
            let normalizedPath = filename.replacingOccurrences(of: "\\", with: "/")
            if normalizedPath.contains("..") {
                offset = dataEnd
                continue
            }

            // Skip directories
            if filename.hasSuffix("/") {
                offset = dataEnd
                continue
            }

            let compressedData = data.subdata(in: dataStart..<dataEnd)

            let fileData: Data
            if compressionMethod == 0 {
                // Stored (no compression)
                fileData = compressedData
            } else if compressionMethod == 8 {
                // Deflate
                guard let decompressed = Self.inflate(compressedData, uncompressedSize: Int(uncompressedSize)) else {
                    offset = dataEnd
                    continue
                }
                fileData = decompressed
            } else {
                offset = dataEnd
                continue
            }

            entries.append(ZipEntry(filename: filename, uncompressedSize: uncompressedSize, data: fileData))
            offset = dataEnd
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
    func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
    }
}

// MARK: - MdairParser

struct MdairParser {
    struct MdairDocument {
        let markdown: String
        let assets: [String: Data]  // filename -> image data
    }

    func parse(fileURL: URL) throws -> MdairDocument {
        let entries = try ZipReader.readEntries(from: fileURL)

        // Find content.md
        var markdownData: Data?
        if let contentEntry = entries.first(where: { $0.filename == "content.md" }) {
            markdownData = contentEntry.data
        } else if let firstMd = entries.first(where: { $0.filename.hasSuffix(".md") && !$0.filename.contains("/") }) {
            markdownData = firstMd.data
        }

        let markdown: String
        if let md = markdownData {
            markdown = String(data: md, encoding: .utf8) ?? String(data: md, encoding: .isoLatin1) ?? ""
        } else {
            markdown = ""
        }

        // Collect assets
        var assets: [String: Data] = [:]
        for entry in entries {
            if entry.filename.hasPrefix("assets/") && entry.filename.count > 7 {
                let assetName = String(entry.filename.dropFirst(7)) // drop "assets/"
                assets[assetName] = entry.data
            }
        }

        return MdairDocument(markdown: markdown, assets: assets)
    }
}

// MARK: - Markdown Renderer

/// CommonMark + GitHub Flavored Markdown 렌더러 (cmark-gfm).
struct MarkdownRenderer {
    private static let extensions = ["table", "strikethrough", "autolink", "tagfilter", "tasklist"]
    // HTML은 지금처럼 통과시킨다. 문서 속 스크립트는 페이지의 CSP가 막고,
    // <script>·<style>·<iframe> 같은 위험한 태그는 tagfilter 확장이 무력화한다.
    private static let options = CMARK_OPT_UNSAFE
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
    pre code { padding: 0; font-size: inherit; }
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
    @media (prefers-color-scheme: light) {
      body { color: #24292f; background: #fff; }
      h1, h2 { border-bottom-color: #d1d9e0; }
      code { background: #eff1f3; } pre { background: #f6f8fa; }
      blockquote { border-left-color: #d1d9e0; color: #59636e; background: #f6f8fa; }
      th { background: #f6f8fa; } th, td { border-color: #d1d9e0; }
      hr { background: #d1d9e0; } a { color: #0969da; }
      .mdair-notice { background: #fff8e1; color: #6b4f00; }
      .mdair-notice code { background: rgba(0,0,0,0.06); }
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
        <meta http-equiv='Content-Security-Policy' content="script-src 'nonce-\(nonce)'; object-src 'none'; base-uri 'none'">\
        <style>\(css)</style></head>\
        <body>\(notice)\(body)\
        \(mermaid)\
        <script nonce='\(nonce)'>(function(){var t=null,m=null;function s(){if(!t){t=document.createElement('div');t.id='mdair-toast';t.textContent='복사됨';document.body.appendChild(t);}t.classList.add('show');clearTimeout(m);m=setTimeout(function(){t.classList.remove('show');},1200);}document.addEventListener('copy',s);})();</script>\
        </body></html>
        """
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
            let rawPath = String(html[pathRange])
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
            // cmark는 주소를 퍼센트 인코딩한다(공백 → %20, 한글 → %EC…). 실제 파일 이름으로 되돌린다.
            let path = rawPath.removingPercentEncoding ?? rawPath
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

    /// .mdair 안의 assets/ 이미지를 data URI로 바꾼다. 없는 이미지는 "Image not found" 그림으로 채운다.
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
            let filename = encoded.removingPercentEncoding ?? encoded  // cmark의 퍼센트 인코딩을 푼다

            guard let imgData = assets[filename] ?? assets[encoded] else {
                result.replaceSubrange(swiftRange, with: "\(attr)=\"data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyMDAiIGhlaWdodD0iNTAiPjx0ZXh0IHg9IjEwIiB5PSIzMCIgZmlsbD0iIzk5OSI+SW1hZ2Ugbm90IGZvdW5kPC90ZXh0Pjwvc3ZnPg==\"")
                continue
            }
            let dataURI = "data:\(mimeType(forExtension: (filename as NSString).pathExtension));base64,\(imgData.base64EncodedString())"
            result.replaceSubrange(swiftRange, with: "\(attr)=\"\(dataURI)\"")
        }
        return result
    }

    // MARK: ObjC 진입점 (mdair.app)

    /// .md 문서 전체 페이지. baseDir가 있으면 로컬 이미지를 인라인한다.
    @objc(pageForMarkdown:baseDir:)
    public static func page(forMarkdown markdown: String, baseDir: String?) -> String {
        var body = MarkdownRenderer().render(markdown)
        if let baseDir = baseDir {
            body = inlineLocalImages(body, baseDir: URL(fileURLWithPath: baseDir)).html
        }
        return page(body: body)
    }

    /// .mdair 파일 전체 페이지. 읽지 못하면 nil.
    @objc(pageForMdairFile:)
    public static func page(forMdairFile path: String) -> String? {
        guard let doc = try? MdairParser().parse(fileURL: URL(fileURLWithPath: path)) else { return nil }
        return page(body: inlineAssets(MarkdownRenderer().render(doc.markdown), assets: doc.assets))
    }
}
