import Cocoa
import Quartz
import WebKit

// MARK: - QLPreviewingController

class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {
    var webView: WKWebView!
    private var loadContinuation: CheckedContinuation<Void, Never>?

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

    // 링크는 미리보기 안에서 이동하지 않고 브라우저로 연다. 파일 링크로 앱을 실행하지 못하게 웹 주소만 허용한다.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        if url.pathExtension.lowercased() == "mdair" {
            try await prepareMdairPreview(at: url)
        } else {
            try await prepareMarkdownPreview(at: url)
        }
    }

    private func prepareMarkdownPreview(at url: URL) async throws {
        let data = try Data(contentsOf: url)
        let markdown = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let rendered = MarkdownRenderer().render(markdown)
        let baseDir = url.deletingLastPathComponent()
        let (body, missing) = MdairHTML.inlineLocalImages(rendered, baseDir: baseDir)
        let notice = missing > 0 ? """
        <div class="mdair-notice"><strong>로컬 이미지를 표시할 수 없습니다.</strong><br>macOS QuickLook 미리보기는 보안 정책상 미리보기 파일 외 다른 파일에 접근할 수 없습니다. 이미지를 보려면 파일을 더블클릭하여 <strong>mdair</strong> 앱으로 열거나, <code>mdair-convert</code>로 <code>.mdair</code> 형식으로 변환하세요.</div>
        """ : ""
        let html = MdairHTML.page(body: body, notice: notice)
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.loadContinuation = continuation
                self.webView.loadHTMLString(html, baseURL: baseDir)
            }
        }
    }

    private func prepareMdairPreview(at url: URL) async throws {
        let doc = try MdairParser().parse(fileURL: url)
        let body = MdairHTML.inlineAssets(MarkdownRenderer().render(doc.markdown), assets: doc.assets)
        let html = MdairHTML.page(body: body)
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.loadContinuation = continuation
                self.webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }
}
