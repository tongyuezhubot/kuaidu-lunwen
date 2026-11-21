import SwiftUI
import WebKit

enum MathMarkup {
    // In prose a single dollar sign next to a price is common. A math closing
    // delimiter must follow a non-space and cannot be followed by another digit.
    static let tokens = try! NSRegularExpression(pattern: #"(?s)(?<!\\)\$\$(.+?)\$\$|(?<!\\)\\\[(.+?)\\\]|(?<!\\)\\\((.+?)\\\)|(?<![\\$])\$(?![\s$])((?:\\.|[^\\$\r\n])*?(?<!\s))\$(?![\d$])"#)
    static func parts(in text: String) -> [[String: String]] {
        let source = text as NSString
        var parts: [[String: String]] = []
        var end = 0
        for token in tokens.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let group = (1...4).first(where: { token.range(at: $0).location != NSNotFound }),
                  token.range(at: group).length > 0 else { continue }
            if token.range.location > end {
                parts.append(["text": source.substring(with: NSRange(location: end, length: token.range.location-end))])
            }
            parts.append(["math": source.substring(with: token.range(at: group)), "raw": source.substring(with: token.range),
                          "style": group <= 2 ? "block" : "inline"])
            end = NSMaxRange(token.range)
        }
        guard !parts.isEmpty else { return [] }
        if end < source.length { parts.append(["text": source.substring(from: end)]) }
        return parts
    }
}

struct MathPassage: View {
    let text: String
    var size: CGFloat = 13
    var quote = false
    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat = 24
    var body: some View {
        let parts = MathMarkup.parts(in: text)
        if parts.isEmpty {
            Text(text).font(quote ? .custom("Charter", size: size) : .system(size: size)).lineSpacing(4).textSelection(.enabled)
        } else {
            FormulaWeb(parts: parts, size: size, quote: quote, dark: scheme == .dark, height: $height)
                .frame(maxWidth: .infinity).frame(height: height)
        }
    }
}

private struct FormulaWeb: NSViewRepresentable {
    let parts: [[String: String]], size: CGFloat, quote: Bool, dark: Bool
    @Binding var height: CGFloat

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var current: FormulaWeb
        var ready = false
        init(_ current: FormulaWeb) { self.current = current }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            render(webView)
        }
        func render(_ web: WKWebView) {
            guard ready else { return }
            web.callAsyncJavaScript("draw(parts, size, quote, dark)", arguments: [
                "parts": current.parts, "size": Double(current.size), "quote": current.quote, "dark": current.dark
            ], in: nil, in: .page, completionHandler: nil)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let n = message.body as? NSNumber else { return }
            let value = max(18, ceil(n.doubleValue))
            if abs(current.height-value) >= 1 { current.height = value }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "height")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        if let file = Bundle.main.url(forResource: "reader", withExtension: "html", subdirectory: "Math") {
            web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        }
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        let old = context.coordinator.current
        context.coordinator.current = self
        if old.parts != parts || old.dark != dark || old.quote != quote || old.size != size { context.coordinator.render(web) }
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "height")
    }
}
