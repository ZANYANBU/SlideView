import AppKit
import WebKit

// MARK: - Routing

func mimeType(_ ext: String) -> String {
    switch ext {
    case "html": return "text/html; charset=utf-8"
    case "css":  return "text/css; charset=utf-8"
    case "js", "mjs": return "text/javascript; charset=utf-8"
    case "json": return "application/json; charset=utf-8"
    case "png":  return "image/png"
    case "svg":  return "image/svg+xml"
    case "woff2": return "font/woff2"
    case "pdf":  return "application/pdf"
    default: return "application/octet-stream"
    }
}

func route(_ req: HTTPRequest) -> HTTPResponse {
    let lib = Library.shared
    let webRoot = (Bundle.main.resourceURL ?? URL(fileURLWithPath: "."))
        .appendingPathComponent("web", isDirectory: true)

    switch req.path {

    case "/", "/index.html":
        return .file(webRoot.appendingPathComponent("index.html"), type: "text/html; charset=utf-8")

    case "/api/library":
        let docs = lib.scan()
        var subjects: [String: [[String: Any]]] = [:]
        for d in docs {
            let ready = lib.state(d) == .ready
            subjects[d.subject, default: []].append([
                "id": d.id, "name": d.name, "ext": d.ext, "subject": d.subject,
                "size": d.size, "modified": d.modified,
                "state": lib.state(d).rawValue,
                "pages": ready ? lib.pageCount(d) : 0,
                "path": d.url.path
            ])
        }
        let payload: [String: Any] = [
            "root": lib.root.path,
            "rootName": lib.root.lastPathComponent,
            "roots": lib.roots.map { ["path": $0.path, "name": $0.lastPathComponent] },
            "subjects": subjects.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { ["name": $0, "docs": subjects[$0]!] }
        ]
        return .json(payload)

    case "/api/state":
        guard let id = req.query["id"], let d = lib.doc(id) else { return .json(["state": "missing"], status: 404) }
        let st = lib.state(d)
        var out: [String: Any] = ["state": st.rawValue, "id": id]
        if st == .ready { out["pages"] = lib.pageCount(d) }
        if st == .error { out["message"] = lib.error(id) ?? "Conversion failed" }
        return .json(out)

    case "/api/convert":
        guard let id = req.query["id"], let d = lib.doc(id) else { return .json(["state": "missing"], status: 404) }
        lib.convert(d)
        return .json(["state": lib.state(d).rawValue])

    case "/api/pdf":
        guard let id = req.query["id"], let d = lib.doc(id) else { return .text("no such document", status: 404) }
        let p = lib.pdfPath(d)
        guard FileManager.default.fileExists(atPath: p.path) else {
            lib.convert(d)
            return .text("not ready", status: 404)
        }
        return .file(p, type: "application/pdf")

    case "/api/thumb":
        guard let id = req.query["id"], let d = lib.doc(id) else { return .text("no such document", status: 404) }
        guard let png = lib.thumbnail(d) else { return .text("no thumb", status: 404) }
        return HTTPResponse(status: 200,
                            headers: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"],
                            body: png)

    default:
        // Static assets under Resources/web
        let rel = String(req.path.dropFirst())
        guard !rel.contains(".."), !rel.isEmpty else { return .text("not found", status: 404) }
        let url = webRoot.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: url.path) else { return .text("not found", status: 404) }
        var res = HTTPResponse.file(url, type: mimeType(url.pathExtension.lowercased()))
        res.headers["Cache-Control"] = "max-age=3600"
        return res
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, NSWindowDelegate {
    var window: NSWindow!
    var web: WKWebView!
    let server = HTTPServer()

    func applicationDidFinishLaunching(_ note: Notification) {
        server.handler = route
        var port: UInt16 = 0
        do { port = try server.start() } catch {
            let a = NSAlert()
            a.messageText = "SlideView could not start"
            a.informativeText = error.localizedDescription
            a.runModal()
            NSApp.terminate(nil)
            return
        }

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "app")
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")

        web = WKWebView(frame: .zero, configuration: cfg)
        web.underPageBackgroundColor = NSColor(calibratedRed: 0.078, green: 0.078, blue: 0.086, alpha: 1)
        web.setValue(false, forKey: "drawsBackground")
        web.allowsMagnification = false

        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: style, backing: .buffered, defer: false)
        window.title = "SlideView"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.078, green: 0.078, blue: 0.086, alpha: 1)
        window.minSize = NSSize(width: 720, height: 520)
        window.delegate = self
        window.contentView = web
        window.setFrameAutosaveName("SlideViewMain")
        window.center()
        window.makeKeyAndOrderFront(nil)

        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
        web.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // MARK: JS bridge

    func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard let body = msg.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "toggleFullScreen":
            window.toggleFullScreen(nil)
        case "title":
            window.title = (body["text"] as? String) ?? "SlideView"
        case "reveal":
            if let id = body["id"] as? String, let d = Library.shared.doc(id) {
                NSWorkspace.shared.activateFileViewerSelecting([d.url])
            }
        case "openExternal":
            if let id = body["id"] as? String, let d = Library.shared.doc(id) {
                NSWorkspace.shared.open(d.url)
            }
        case "exportPDF":
            if let id = body["id"] as? String, let d = Library.shared.doc(id) { savePDF(d) }
        case "contextMenu":
            if let id = body["id"] as? String, let page = body["page"] as? Int {
                let x = (body["x"] as? Double) ?? 0, y = (body["y"] as? Double) ?? 0
                showSlideMenu(id: id, page: page, at: NSPoint(x: x, y: web.bounds.height - y))
            }
        case "chooseRoot":
            chooseRoot()
        case "removeRoot":
            if let p = body["path"] as? String {
                Library.shared.removeRoot(p)
                web.evaluateJavaScript("window.sv && window.sv.rootChanged && window.sv.rootChanged()")
            }
        default: break
        }
    }

    private var ctxDoc: Doc?
    private var ctxPage: Int = 1

    private func showSlideMenu(id: String, page: Int, at pt: NSPoint) {
        guard let d = Library.shared.doc(id) else { return }
        ctxDoc = d; ctxPage = page

        let m = NSMenu()
        m.addItem(withTitle: "Slide \(page) of \(d.name)", action: nil, keyEquivalent: "")
        m.items.first?.isEnabled = false
        m.addItem(.separator())
        func add(_ title: String, _ sel: Selector) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            m.addItem(it)
        }
        add("Copy Slide as Image", #selector(ctxCopyImage))
        add("Copy Slide Text", #selector(ctxCopyText))
        m.addItem(.separator())
        add("Search this Slide with Google Lens", #selector(ctxLens))
        add("Ask Gemini about this Slide", #selector(ctxGemini))
        add("Search Slide Text on Google", #selector(ctxGoogle))
        m.addItem(.separator())
        add("Open PDF in Chrome", #selector(ctxChromePDF))
        add("Open Original in Default App", #selector(ctxOpenOriginal))
        add("Reveal Original in Finder", #selector(ctxReveal))
        m.popUp(positioning: nil, at: pt, in: web)
    }

    private func toast(_ s: String) {
        let esc = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        web.evaluateJavaScript("window.sv && window.sv.toast && window.sv.toast('\(esc)')")
    }

    private func copySlideImage() -> Bool {
        guard let d = ctxDoc, let img = Library.shared.pageImage(d, page: ctxPage),
              let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        pb.setData(tiff, forType: .tiff)
        return true
    }

    private func openInChrome(_ url: URL) {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        if FileManager.default.fileExists(atPath: chrome.path) {
            NSWorkspace.shared.open([url], withApplicationAt: chrome,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func ctxCopyImage() {
        toast(copySlideImage() ? "Slide copied as image" : "Could not copy this slide")
    }
    @objc private func ctxCopyText() {
        guard let d = ctxDoc else { return }
        let t = Library.shared.pageText(d, page: ctxPage)
        guard !t.isEmpty else { return toast("No text on this slide") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        toast("Slide text copied")
    }
    @objc private func ctxLens() {
        // Lens cannot reach a 127.0.0.1 URL, so hand it the image via the clipboard.
        guard copySlideImage() else { return toast("Could not copy this slide") }
        openInChrome(URL(string: "https://lens.google.com/")!)
        toast("Slide copied — press ⌘V in Chrome to search it")
    }
    @objc private func ctxGemini() {
        guard let d = ctxDoc else { return }
        let t = Library.shared.pageText(d, page: ctxPage)
        if t.isEmpty { _ = copySlideImage() } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("Explain this slide from my Computer Networks notes:\n\n" + t,
                                           forType: .string)
        }
        openInChrome(URL(string: "https://gemini.google.com/app")!)
        toast("Copied — press ⌘V in Gemini")
    }
    @objc private func ctxGoogle() {
        guard let d = ctxDoc else { return }
        let t = Library.shared.pageText(d, page: ctxPage)
        guard !t.isEmpty else { return toast("No text on this slide") }
        let q = String(t.prefix(220)).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        openInChrome(URL(string: "https://www.google.com/search?q=\(q)")!)
    }
    @objc private func ctxChromePDF() {
        guard let d = ctxDoc else { return }
        let pdf = Library.shared.pdfPath(d)
        guard FileManager.default.fileExists(atPath: pdf.path) else { return }
        openInChrome(URL(fileURLWithPath: pdf.path))
    }
    @objc private func ctxOpenOriginal() { if let d = ctxDoc { NSWorkspace.shared.open(d.url) } }
    @objc private func ctxReveal() { if let d = ctxDoc { NSWorkspace.shared.activateFileViewerSelecting([d.url]) } }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        panel.message = "Choose one or more folders holding your subject material"
        panel.directoryURL = Library.shared.root
        panel.begin { [weak self] resp in
            guard resp == .OK, !panel.urls.isEmpty else { return }
            Library.shared.addRoots(panel.urls)
            self?.web.evaluateJavaScript("window.sv && window.sv.rootChanged && window.sv.rootChanged()")
        }
    }

    private func savePDF(_ d: Doc) {
        let src = Library.shared.pdfPath(d)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = d.name + ".pdf"
        panel.begin { resp in
            guard resp == .OK, let dst = panel.url else { return }
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
    }

    // MARK: Full-screen notifications to JS

    func windowDidEnterFullScreen(_ n: Notification) { notifyFS(true) }
    func windowDidExitFullScreen(_ n: Notification)  { notifyFS(false) }
    private func notifyFS(_ on: Bool) {
        web.evaluateJavaScript("window.sv && window.sv.fullScreen && window.sv.fullScreen(\(on))")
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About SlideView", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let openFolder = NSMenuItem(title: "Add Folder to Library…", action: #selector(menuChooseRoot), keyEquivalent: "o")
        openFolder.target = self
        appMenu.addItem(openFolder)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide SlideView", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit SlideView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        let fs = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        view.addItem(fs)
        let reload = NSMenuItem(title: "Reload", action: #selector(menuReload), keyEquivalent: "r")
        reload.target = self
        view.addItem(reload)
        viewItem.submenu = view
        main.addItem(viewItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    @objc private func menuChooseRoot() { chooseRoot() }
    @objc private func menuReload() { web.reload() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
