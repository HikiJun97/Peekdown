import Cocoa
import WebKit

// Peekdown 테스트 하네스. src/MdairRender.swift와 함께 컴파일한다(tests/run.sh 참고).
//   harness unit                          렌더러·리더 단위 테스트
//   harness webkit                        WKWebView에 띄워 보는 보안·동작 테스트
//   harness spec <cases.json> <out.json>  스펙 예제를 렌더링해 저장(비교는 tests/spec/spec.py)
//   harness bundle <path>                 TextBundle/TextPack을 열어 제목과 이미지 인라인 결과를 출력

var failures: [String] = []
var passes = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        passes += 1
    } else {
        failures.append(name)
        print("  ✗ \(name)\(detail().isEmpty ? "" : " — \(detail())")")
    }
}

func finish() -> Never {
    print("  \(passes)개 통과, \(failures.count)개 실패")
    exit(failures.isEmpty ? 0 : 1)
}

func render(_ markdown: String) -> String { MarkdownRenderer().render(markdown) }

func elapsed(_ work: () -> Void) -> Double {
    let start = Date()
    work()
    return Date().timeIntervalSince(start)
}

/// 테스트용 PNG(2x2). 저장소에 이미지 파일을 넣지 않으려고 실행 중에 만든다.
func pngData() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

func makeTempDir() -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("peekdown-tests-\(UUID().uuidString)").path
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    // 앱처럼 폴더 주소(끝에 /)로 둔다. 그래야 문서 속 상대 경로가 이 폴더 기준으로 풀린다
    let dir = URL(fileURLWithPath: path, isDirectory: true)
    return dir
}

// MARK: - ZIP 만들기 (stored 방식, 선언 크기·참조를 마음대로 정할 수 있게)

struct ZipItem {
    let name: String
    let data: [UInt8]
    var declaredSize: UInt32? = nil
}

/// items를 담은 ZIP을 만든다. extraRefs만큼 central directory 항목을 더 만들어 첫 항목의 로컬 데이터를 다시 가리키게 한다.
func makeZip(_ items: [ZipItem], extraRefs: Int = 0) -> Data {
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
    var out: [UInt8] = []
    var central: [UInt8] = []
    var count = 0
    var firstOffset = 0
    for (index, item) in items.enumerated() {
        let name = Array(item.name.utf8)
        let offset = out.count
        if index == 0 { firstOffset = offset }
        let size = item.declaredSize ?? UInt32(item.data.count)
        out += le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            + le32(UInt32(item.data.count)) + le32(size) + le16(name.count) + le16(0) + name + item.data
        let refs = index == 0 ? 1 + extraRefs : 1
        for r in 0..<refs {
            let n = r == 0 ? name : Array("\(item.name)-\(r)".utf8)
            central += le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
                + le32(UInt32(item.data.count)) + le32(size) + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0)
                + le32(0) + le32(UInt32(index == 0 ? firstOffset : offset)) + n
            count += 1
        }
    }
    let cdStart = out.count
    out += central
    out += le32(0x06054b50) + le16(0) + le16(0) + le16(count) + le16(count) + le32(UInt32(central.count)) + le32(UInt32(cdStart)) + le16(0)
    return Data(out)
}

// MARK: - unit

func unitTests() {
    print("[unit] 렌더러")
    let common = render("""
    - parent
      - child

    Title
    ---

    _italic_ and __bold__ and \\*not italic\\*

    See <https://example.com> and [docs][ref].

    [ref]: https://example.com/docs

    | l | c |
    |:--|:-:|
    | a | b |

    3. three
    """)
    check(common.contains("<li>parent\n<ul>"), "중첩 목록")
    check(common.contains("<h2>Title</h2>"), "밑줄 제목(setext)")
    check(common.contains("<em>italic</em>") && common.contains("<strong>bold</strong>"), "_기울임_ __굵게__")
    check(common.contains("*not italic*"), "백슬래시 이스케이프")
    check(common.contains("<a href=\"https://example.com\">"), "자동 링크 <https://…>")
    check(common.contains("<a href=\"https://example.com/docs\">docs</a>"), "참조 링크")
    check(common.contains("align=\"center\""), "표 열 정렬")
    check(common.contains("<ol start=\"3\">"), "목록 시작 번호")
    check(render("a\nb\n") == "<p>a\nb</p>\n", "이어진 줄은 한 문단", render("a\nb\n"))
    check(render("<script>alert(1)</script>\n").contains("&lt;script"), "tagfilter가 <script>를 무력화")
    let mermaid = render("```mermaid\ngraph TD\n  A-->B\n```\n")
    check(mermaid.contains("<pre class=\"mermaid\">") && mermaid.contains("A--&gt;B"), "mermaid 블록 변환", mermaid)

    print("[unit] 각주")
    let footnote = render("Claim.[^1] Regex [^a-z] and `[^1]`.\n\n[^1]: Note.\n")
    check(footnote.contains("class=\"footnote-ref\"") && footnote.contains("<section class=\"footnotes\""), "각주 렌더링")
    check(footnote.contains("[^a-z]") && footnote.contains("<code>[^1]</code>"), "정의 없는 [^…]와 코드는 그대로")

    print("[unit] 이미지 경로 디코딩")
    for (input, expected) in [("it&#x27;s.png", "it's.png"), ("it&#39;s.png", "it's.png"), ("a%20b.png", "a b.png"),
                              ("a&amp;b.png", "a&b.png"), ("%EC%8A%A4.png", "스.png"), ("100%.png", "100%.png"),
                              ("&amp;#39;.png", "&#39;.png")] {
        check(MdairHTML.decodeImagePath(input) == expected, "decodeImagePath(\(input))", MdairHTML.decodeImagePath(input))
    }

    print("[unit] 같은 문서 링크 판정")
    let dir = URL(string: "file:///tmp/doc/")!
    check(MdairHTML.isSameDocumentLink(URL(string: "file:///tmp/doc/#fn-1"), currentURL: dir), "file 기준 #fn-1")
    check(MdairHTML.isSameDocumentLink(URL(string: "about:blank#fn-1"), currentURL: URL(string: "about:blank")), "about:blank 기준 #fn-1")
    check(!MdairHTML.isSameDocumentLink(URL(string: "file:///tmp/doc/other.md#x"), currentURL: dir), "다른 문서는 아님")
    check(!MdairHTML.isSameDocumentLink(URL(string: "https://example.com/"), currentURL: dir), "외부 주소는 아님")

    print("[unit] TextBundle 첨부물 공백 보정")
    check(TextBundleReader.encodeAssetSpaces("![a](assets/a b.png)") == "![a](assets/a%20b.png)", "공백을 %20으로")
    check(TextBundleReader.encodeAssetSpaces("![a](assets/a b.png \"t\")") == "![a](assets/a b.png \"t\")", "제목이 있으면 그대로")
    let hostile = String(repeating: "![](assets/ ", count: 6000)  // 약 72KB 한 줄, 예전 정규식은 수십 분
    let t = elapsed { _ = TextBundleReader.encodeAssetSpaces(hostile) }
    check(t < 0.5, "공백이 많은 긴 줄도 빠르게(선형)", String(format: "%.2fs", t))

    print("[unit] ZIP 자원 제한")
    let tiny = Array("# t".utf8)
    let inflated = makeZip([ZipItem(name: "text.md", data: tiny), ZipItem(name: "assets/big.png", data: tiny, declaredSize: 4_000_000_000)])
    let records = ZipReader.records(in: inflated)
    check(records.map(\.path) == ["text.md"], "선언 크기가 상한을 넘는 항목은 버림", "\(records.map(\.path))")
    check(records.first.flatMap { ZipReader.extract($0, from: inflated) } == Data(tiny), "정상 항목은 풀림")
    let overlapping = makeZip([ZipItem(name: "text.md", data: tiny)], extraRefs: 200)
    check(ZipReader.records(in: overlapping).count == 1, "같은 로컬 항목을 다시 가리키는 항목은 버림")
    let traversal = makeZip([ZipItem(name: "x.textbundle/text.md", data: tiny), ZipItem(name: "../escape.md", data: tiny),
                             ZipItem(name: "x.textbundle/assets/../../text.md", data: Array("# hijack".utf8))])
    check(ZipReader.records(in: traversal).map(\.path) == ["x.textbundle/text.md"], "../ 항목은 버림")
    check(ZipReader.records(in: Data([0x50, 0x4b, 0x05, 0x06])).isEmpty, "잘린 ZIP은 빈 결과")
}

// MARK: - webkit

final class Recorder: NSObject, WKNavigationDelegate {
    let guardian = NavigationGuard()
    var loaded = false
    var blocked: [String] = []
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if guardian.shouldBlock(action, in: webView) {
            blocked.append(action.request.url?.absoluteString ?? "nil")
            decisionHandler(.cancel)
            return
        }
        // 링크 클릭은 앱처럼 문서 밖으로 나가지 않게 막는다(앱은 이 경우 브라우저로 넘긴다)
        let leaves = action.navigationType == .linkActivated
            && !MdairHTML.isSameDocumentLink(action.request.url, currentURL: webView.url)
        decisionHandler(leaves ? .cancel : .allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
}

func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

/// 페이지를 띄우고 JS 식의 결과(JSON 문자열)를 돌려준다. before가 있으면 먼저 실행하고 잠시 기다린다.
func runPage(_ html: String, baseURL: URL?, before: String? = nil, settle: Double = 1.5, _ expression: String) -> (String, Recorder, WKWebView) {
    let recorder = Recorder()
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    webView.navigationDelegate = recorder
    recorder.guardian.prepareForLoad(in: webView)
    webView.loadHTMLString(html, baseURL: baseURL)
    let deadline = Date().addingTimeInterval(10)
    while !recorder.loaded && Date() < deadline { wait(0.05) }
    wait(settle)
    if let before {
        var done = false
        webView.evaluateJavaScript(before) { _, _ in done = true }
        while !done { wait(0.05) }
        wait(1.0)
    }
    var result = ""
    var done = false
    webView.evaluateJavaScript(expression) { value, error in
        result = (value as? String) ?? "error: \(String(describing: error))"
        done = true
    }
    while !done { wait(0.05) }
    return (result, recorder, webView)
}

func json(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}

func webkitTests() {
    _ = NSApplication.shared
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let png = pngData()
    for name in ["pic.png", "스크린 샷.png"] { try! png.write(to: dir.appendingPathComponent(name)) }
    try! "DUMMY-SECRET".write(to: dir.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
    try! FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("logo.png"), withDestinationURL: dir.appendingPathComponent("secret.txt"))
    check(MdairHTML.mermaidScript != nil, "mermaid.min.js가 실행 파일 옆에 있음(tests/run.sh가 복사)")

    print("[webkit] 스크립트·파일 인라인·Mermaid")
    let attack = """
    # Evil

    <script>window.pwned = (window.pwned || '') + 'script;'</script>
    <img src="x" onerror="window.pwned = (window.pwned || '') + 'onerror;'">
    ![a](x" onerror="window.pwned = (window.pwned || '') + 'attr;')
    <img id="secret" src="secret.txt">
    <img id="hosts" src="/etc/hosts">
    <img id="link" src="logo.png">
    <img id="pic" src="pic.png">
    <link rel="stylesheet" href="data:text/css,body%7Bcolor:rgb(1,2,3)!important%7D">

    ![한글 이름](스크린%20샷.png)

    ```mermaid
    graph TD
      A-->B
    ```
    """
    let (page, _, _) = runPage(MdairHTML.page(forMarkdown: attack, baseDir: dir.path), baseURL: dir, """
    JSON.stringify({
      pwned: window.pwned || null,
      mermaid: document.querySelectorAll('.mermaid svg').length,
      secret: document.getElementById('secret').getAttribute('src'),
      hosts: document.getElementById('hosts').getAttribute('src'),
      link: document.getElementById('link').getAttribute('src').slice(0, 5),
      pic: document.getElementById('pic').getAttribute('src').slice(0, 14),
      korean: [...document.images].filter(i => i.alt === '한글 이름').map(i => i.getAttribute('src').slice(0, 14))[0] || null,
      color: getComputedStyle(document.body).color
    })
    """)
    let r = json(page)
    check(r["pwned"] is NSNull, "주입한 스크립트·onerror·속성 탈출이 실행되지 않음", "\(r["pwned"] ?? "nil")")
    check((r["mermaid"] as? Int) == 1, "Mermaid가 그려짐", page)
    check((r["secret"] as? String) == "secret.txt" && (r["hosts"] as? String) == "/etc/hosts", "이미지가 아닌 파일은 인라인하지 않음")
    check((r["link"] as? String) == "logo.", "비밀 파일을 가리키는 이미지 이름의 심볼릭 링크는 인라인하지 않음", "\(r["link"] ?? "nil")")
    check((r["pic"] as? String) == "data:image/png", "정상 이미지는 인라인")
    check((r["korean"] as? String) == "data:image/png", "한글·공백 파일 이름 이미지 인라인")
    check((r["color"] as? String) != "rgb(1, 2, 3)", "문서 속 외부 스타일시트는 CSP로 막힘", "\(r["color"] ?? "nil")")

    print("[webkit] 문서가 창을 다른 페이지로 옮기지 못함")
    for (label, body) in [("meta refresh 0초", "<meta http-equiv=\"refresh\" content=\"0;url=https://example.com/phish\">"),
                          ("meta refresh 1초", "<meta http-equiv=\"refresh\" content=\"1;url=https://example.com/phish\">"),
                          ("meta refresh data:", "<meta http-equiv=\"refresh\" content=\"0;url=data:text/html,x\">")] {
        let (_, recorder, webView) = runPage(MdairHTML.page(body: render("# Doc\n\n\(body)\n")), baseURL: dir, settle: 2.0, "'ok'")
        check(webView.url?.scheme == "file", "\(label): 원래 문서에 머묾", "\(webView.url?.absoluteString ?? "nil")")
        check(!recorder.blocked.isEmpty, "\(label): 이동을 막은 기록이 있음")
    }
    let (_, formRecorder, formView) = runPage(MdairHTML.page(body: render("<form action=\"https://example.com/post\"><button id=\"b\">go</button></form>\n")),
                                              baseURL: dir, before: "document.getElementById('b').click(); 1", "'ok'")
    check(formView.url?.scheme == "file", "폼 제출로 이동하지 않음", "\(formView.url?.absoluteString ?? "nil") \(formRecorder.blocked)")

    print("[webkit] 각주 링크는 문서 안에서 이동")
    let filler = (1...60).map { "Line \($0)." }.joined(separator: "\n\n")
    let notes = MdairHTML.page(body: render("Claim.[^1]\n\n\(filler)\n\n[^1]: Note.\n"))
    for (label, base) in [("파일 기준 주소", dir as URL?), ("about:blank", nil)] {
        let (state, _, _) = runPage(notes, baseURL: base, before: "document.querySelector('a[data-footnote-ref]').click(); 1",
                                    "JSON.stringify({hash: location.hash, y: scrollY})")
        let s = json(state)
        check((s["hash"] as? String) == "#fn-1" && ((s["y"] as? Int) ?? 0) > 0, "\(label): #fn-1로 스크롤", state)
    }
}

// MARK: - spec, bundle

func specRender(_ casesPath: String, _ outPath: String) {
    let data = try! Data(contentsOf: URL(fileURLWithPath: casesPath))
    let cases = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    let out = cases.map { render($0["markdown"] as! String) }
    try! JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: outPath))
}

func bundleSummary(_ path: String) {
    guard let html = MdairHTML.page(forTextBundle: path) else { print("nil"); return }
    let ns = NSRange(html.startIndex..., in: html)
    let title = try! NSRegularExpression(pattern: "<h1>([^<]*)</h1>").firstMatch(in: html, range: ns)
        .map { String(html[Range($0.range(at: 1), in: html)!]) } ?? "-"
    let images = try! NSRegularExpression(pattern: #"<img src="([^"]{0,20})[^"]*" alt="([^"]*)""#).matches(in: html, range: ns).map { m in
        "\(html[Range(m.range(at: 2), in: html)!])=\(html[Range(m.range(at: 1), in: html)!].hasPrefix("data:image/png") ? "OK" : "FAIL")"
    }
    print("title=\(title) images=\(images.joined(separator: ","))")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "unit": unitTests(); finish()
case "webkit": webkitTests(); finish()
case "spec": specRender(args[2], args[3])
case "bundle": bundleSummary(args[2])
default:
    print("usage: harness unit | webkit | spec <cases.json> <out.json> | bundle <path>")
    exit(2)
}
