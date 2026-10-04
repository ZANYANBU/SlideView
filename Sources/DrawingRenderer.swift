import AppKit
import WebKit

/// Renders an Excalidraw scene to a PNG without showing anything.
///
/// Excalidraw's own exporter is the only renderer that draws a scene exactly as
/// the editor does (rough.js strokes, its fonts, bound text), so rather than
/// approximate it natively this loads the app's draw page in an offscreen web
/// view in "render" mode. The page exports the scene and posts the PNG back.
/// Same shape as HTMLToPDF: hop to the main thread for WebKit, block the
/// conversion queue until the result arrives or the timeout passes.
final class DrawingRenderer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    /// Port of the app's local server, set once it is listening.
    static var port: UInt16 = 0
    private static var live: [DrawingRenderer] = []

    private var web: WKWebView?
    private var host: NSWindow?
    private var finish: ((Data?, CGFloat) -> Void)?
    private var settled = false

    static func render(id: String, timeout: TimeInterval = 45) -> (png: Data, scale: CGFloat)? {
        guard port != 0 else { return nil }
        var result: (Data, CGFloat)?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let r = DrawingRenderer()
            live.append(r)
            r.start(id: id) { data, scale in
                if let data { result = (data, scale) }
                live.removeAll { $0 === r }
                sem.signal()
            }
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            DispatchQueue.main.async { live.forEach { $0.complete(nil, 1) } }
            return nil
        }
        return result.map { (png: $0.0, scale: $0.1) }
    }

    private func start(id: String, done: @escaping (Data?, CGFloat) -> Void) {
        finish = done
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "drawing")
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let w = WKWebView(frame: frame, configuration: cfg)
        w.navigationDelegate = self
        web = w

        let win = NSWindow(contentRect: frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.alphaValue = 0
        win.ignoresMouseEvents = true
        win.contentView = w
        win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        win.orderFrontRegardless()
        host = win

        guard let url = URL(string: "http://127.0.0.1:\(Self.port)/draw.html?id=\(id)&render=1") else {
            return complete(nil, 1)
        }
        w.load(URLRequest(url: url))
    }

    func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard let body = msg.body as? [String: Any],
              let b64 = body["png"] as? String,
              let data = Data(base64Encoded: b64) else { return complete(nil, 1) }
        complete(data, CGFloat((body["scale"] as? Double) ?? 1))
    }

    func webView(_ w: WKWebView, didFail nav: WKNavigation!, withError e: Error) { complete(nil, 1) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError e: Error) { complete(nil, 1) }

    private func complete(_ data: Data?, _ scale: CGFloat) {
        guard !settled else { return }
        settled = true
        // The content controller holds its handler strongly; drop it or this leaks.
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "drawing")
        web?.navigationDelegate = nil
        web = nil
        host?.orderOut(nil)
        host?.contentView = nil
        host = nil
        finish?(data, scale)
        finish = nil
    }
}
