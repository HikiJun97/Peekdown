import Cocoa
import Quartz
import WebKit

// MARK: - QLPreviewingController

class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {
    var webView: WKWebView!
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private let navigationGuard = NavigationGuard()

    override func loadView() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.allowsMagnification = true
        webView.navigationDelegate = self
        self.view = webView
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    // 링크를 눌러도 미리보기 안에서 페이지를 옮기지 않는다. 확장은 네트워크가 막혀 빈 화면만 남고 돌아올 방법도 없다.
    // 브라우저로 여는 것도 안 된다: macOS가 QuickLook 확장의 앱 실행을 막는다
    // (com.apple.private.launchservices.allowedtolaunchinothersessions 권한 필요).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 문서가 <meta refresh>나 폼 제출로 미리보기를 다른 페이지로 옮기지 못하게 한다
        if navigationGuard.shouldBlock(navigationAction, in: webView) {
            decisionHandler(.cancel)
            return
        }
        // 각주(#fn-1)처럼 같은 문서 안에서 옮겨 가는 링크는 허용한다
        let leavesDocument = navigationAction.navigationType == .linkActivated
            && !MdairHTML.isSameDocumentLink(navigationAction.request.url, currentURL: webView.url)
        decisionHandler(leavesDocument ? .cancel : .allow)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        if ["textbundle", "textpack"].contains(url.pathExtension.lowercased()) {
            try await prepareTextBundlePreview(at: url)
        } else {
            try await prepareMarkdownPreview(at: url)
        }
    }

    private func prepareMarkdownPreview(at url: URL) async throws {
        let data = try Data(contentsOf: url)
        let markdown = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let baseDir = url.deletingLastPathComponent()
        let (body, missing) = MdairHTML.body(forMarkdown: markdown, baseDir: baseDir.path)
        let notice = missing > 0 ? """
        <div class="mdair-notice"><strong>로컬 이미지를 표시할 수 없습니다.</strong><br>macOS QuickLook 미리보기는 보안 정책상 미리보기 파일 외 다른 파일에 접근할 수 없습니다. 이미지를 보려면 파일을 더블클릭하여 <strong>Peekdown</strong> 앱으로 열거나, <code>peekdown-convert</code>로 이미지를 함께 담은 <code>.textpack</code>으로 변환하세요.</div>
        """ : ""
        let html = MdairHTML.page(body: body, notice: notice)
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.loadContinuation = continuation
                self.navigationGuard.prepareForLoad(in: self.webView)
                self.webView.loadHTMLString(html, baseURL: baseDir)
            }
        }
    }

    private func prepareTextBundlePreview(at url: URL) async throws {
        guard let html = MdairHTML.page(forTextBundle: url.path) else { throw CocoaError(.fileReadCorruptFile) }
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.loadContinuation = continuation
                self.navigationGuard.prepareForLoad(in: self.webView)
                self.webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }
}
