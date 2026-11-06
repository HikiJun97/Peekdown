import Foundation
import WebKit
import PeekdownCore

// 앱(Peekdown.app)과 QuickLook 확장이 함께 쓰는 연결 코드. 렌더링·TextBundle 읽기는 Rust(core/)가 하고,
// 여기서는 C 함수(core/include/peekdown.h)를 감싸며 WebView에 붙는 NavigationGuard만 직접 구현한다.
// 앱은 ObjC라서 @objc 이름(MdairHTML, MdairNavigationGuard)으로 부른다.

/// Rust가 돌려준 문자열을 Swift 문자열로 옮기고 해제한다.
private func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { peekdown_free(pointer) }
    return String(cString: pointer)
}

private func withBytes<T>(_ text: String, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
    var text = text
    return text.withUTF8 { body($0.baseAddress, $0.count) }
}

@objc(MdairHTML)
public final class MdairHTML: NSObject {
    /// .md 문서 전체 페이지. baseDir가 있으면 그 폴더 기준으로 마크다운 이미지를 인라인한다.
    @objc(pageForMarkdown:baseDir:)
    public static func page(forMarkdown markdown: String, baseDir: String?) -> String {
        withBytes(markdown) { bytes, count in take(peekdown_page_for_markdown(bytes, count, baseDir)) } ?? ""
    }

    /// TextBundle(.textbundle 폴더)이나 TextPack(.textpack) 전체 페이지. 읽지 못하면 nil.
    @objc(pageForTextBundle:)
    public static func page(forTextBundle path: String) -> String? {
        take(peekdown_page_for_textbundle(path))
    }

    /// 마크다운 본문과 읽지 못한 로컬 이미지 수. QuickLook이 안내 문구를 붙일 때 page(body:notice:)와 함께 쓴다.
    static func body(forMarkdown markdown: String, baseDir: String?) -> (html: String, missingImages: Int) {
        var missing = 0
        let html = withBytes(markdown) { bytes, count in take(peekdown_markdown_body(bytes, count, baseDir, &missing)) } ?? ""
        return (html, missing)
    }

    static func page(body: String, notice: String = "") -> String {
        take(peekdown_page(body, notice)) ?? ""
    }

    /// 각주(#fn-1)처럼 지금 문서 안의 다른 위치로 옮겨 가는 링크인지 판단한다. 이런 이동은 막지 않는다.
    @objc(isSameDocumentLink:currentURL:)
    public static func isSameDocumentLink(_ url: URL?, currentURL: URL?) -> Bool {
        guard let target = url?.absoluteString, let current = currentURL?.absoluteString else { return false }
        return peekdown_is_same_document_link(target, current)
    }
}

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
