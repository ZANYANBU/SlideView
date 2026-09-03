import AppKit
import WebKit
import PDFKit

/// Renders HTML to a paginated PDF.
///
/// AppKit's NSPrintOperation was tried first and is not usable here: with no
/// window it spins forever inside -[NSView canDraw], and with one it paginates
/// into hundreds of thousands of pages. Both failures block the main thread,
/// which freezes the whole app.
///
/// So pagination is done in the page itself — a script inserts spacers so every
/// block starts inside a page's usable band — and each page is then captured
/// with `createPDF`, which is asynchronous and cannot stall the UI. The slices
/// are stitched back together with PDFKit.
final class HTMLToPDF: NSObject, WKNavigationDelegate {

    static let pageW: CGFloat = 595, pageH: CGFloat = 842, pad: CGFloat = 54
    private static let maxPages = 400

    private var web: WKWebView?
    private var host: NSWindow?
    private var out: URL!
    private var finish: ((Bool) -> Void)?
    private var settled = false
    private static var live: [HTMLToPDF] = []

    static func render(html: String, to url: URL, timeout: TimeInterval = 60) -> Bool {
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let r = HTMLToPDF()
            live.append(r)
            r.start(html: html, to: url) { good in
                ok = good
                live.removeAll { $0 === r }
                sem.signal()
            }
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            DispatchQueue.main.async { live.forEach { $0.complete(false) } }
            return false
        }
        return ok
    }

    private func start(html: String, to url: URL, done: @escaping (Bool) -> Void) {
        out = url
        finish = done
        let frame = NSRect(x: 0, y: 0, width: Self.pageW, height: Self.pageH)
        let w = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        w.navigationDelegate = self
        web = w

        // An offscreen host window: WebKit needs to be in a window hierarchy to
        // lay out and paint reliably.
        let win = NSWindow(contentRect: frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.alphaValue = 0
        win.ignoresMouseEvents = true
        win.contentView = w
        win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        win.orderFrontRegardless()
        host = win

        w.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.paginate() }
    }
    func webView(_ w: WKWebView, didFail nav: WKNavigation!, withError e: Error) { complete(false) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError e: Error) { complete(false) }

    /// Push any block that would straddle a page boundary onto the next page,
    /// then report how many pages the document needs.
    private func paginate() {
        guard let w = web else { return complete(false) }
        let js = """
        (function(){
          var PAGE = \(Int(Self.pageH)), PAD = \(Int(Self.pad));
          var usable = PAGE - 2*PAD;
          var head = document.createElement('div');
          head.style.height = PAD + 'px';
          document.body.insertBefore(head, document.body.firstChild);
          var kids = Array.prototype.slice.call(document.body.children);
          for (var i = 1; i < kids.length; i++) {
            var el = kids[i];
            var top = el.offsetTop, h = el.offsetHeight;
            if (h <= 0 || h > usable) continue;              // oversized blocks just flow
            var p = Math.floor((top - PAD) / PAGE);
            if (p < 0) p = 0;
            var limit = p * PAGE + PAGE - PAD;
            if (top + h > limit) {
              var sp = document.createElement('div');
              sp.style.height = ((p + 1) * PAGE + PAD - top) + 'px';
              document.body.insertBefore(sp, el);
            }
          }
          return Math.max(1, Math.ceil(document.body.scrollHeight / PAGE));
        })();
        """
        w.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            let pages = min((result as? Int) ?? (result as? NSNumber)?.intValue ?? 0, Self.maxPages)
            guard pages > 0 else { return self.complete(false) }
            // Lay the whole document out so every slice is inside view coordinates.
            self.host?.setContentSize(NSSize(width: Self.pageW, height: Self.pageH * CGFloat(pages)))
            self.web?.frame = NSRect(x: 0, y: 0, width: Self.pageW, height: Self.pageH * CGFloat(pages))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.capture(page: 0, of: pages, into: PDFDocument())
            }
        }
    }

    private func capture(page: Int, of total: Int, into pdf: PDFDocument) {
        guard let w = web else { return complete(false) }
        if page >= total {
            let ok = pdf.pageCount > 0 && pdf.write(to: out)
            return complete(ok)
        }
        let cfg = WKPDFConfiguration()
        cfg.rect = CGRect(x: 0, y: CGFloat(page) * Self.pageH, width: Self.pageW, height: Self.pageH)
        w.createPDF(configuration: cfg) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                if let slice = PDFDocument(data: data), let p = slice.page(at: 0) {
                    pdf.insert(p, at: pdf.pageCount)
                }
                self.capture(page: page + 1, of: total, into: pdf)
            case .failure:
                self.complete(pdf.pageCount > 0 && pdf.write(to: self.out))
            }
        }
    }

    private func complete(_ ok: Bool) {
        guard !settled else { return }
        settled = true
        web?.navigationDelegate = nil
        web = nil
        host?.orderOut(nil)
        host?.contentView = nil
        host = nil
        finish?(ok)
        finish = nil
    }
}
