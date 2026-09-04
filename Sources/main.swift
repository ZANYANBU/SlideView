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
                "notes": lib.noteCount(d.id),
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

    case "/api/notes":
        guard let id = req.query["id"], lib.doc(id) != nil else { return .json([:], status: 404) }
        if req.method == "POST" {
            guard let pageStr = req.query["page"], let page = Int(pageStr) else {
                return .json(["ok": false], status: 400)
            }
            lib.setNote(id, page: page, text: req.bodyText)
            return .json(["ok": true, "count": lib.noteCount(id)])
        }
        return .json(lib.notes(id))

    case "/api/thumb":
        guard let id = req.query["id"], let d = lib.doc(id) else { return .text("no such document", status: 404) }
        guard let png = lib.thumbnail(d) else { return .text("no thumb", status: 404) }
        return HTTPResponse(status: 200,
                            headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                            body: png)

    default:
        // Static assets under Resources/web
        let rel = String(req.path.dropFirst())
        guard !rel.contains(".."), !rel.isEmpty else { return .text("not found", status: 404) }
        let url = webRoot.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: url.path) else { return .text("not found", status: 404) }
        return HTTPResponse.file(url, type: mimeType(url.pathExtension.lowercased()))
    }
}

/// Tabs now occupy the titlebar strip, so the web view swallows the drags that
/// used to move the window. This transparent view sits above the web view in
/// the empty area to the right of the tabs and gives that back — the same place
/// Chrome lets you grab its window.
final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only claim the point for dragging; never steal clicks meant for the page.
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
}

/// Container that accepts files and folders dropped anywhere on the window.
final class RootView: NSView {
    var onDrop: (([URL]) -> Void)?
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: nil) as? [URL],
              !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, NSWindowDelegate, NSMenuDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var dragView: WindowDragView!
    let recentMenu = NSMenu(title: "Open Recent")
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
        let container = RootView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        container.registerForDraggedTypes([.fileURL])
        container.onDrop = { [weak self] urls in self?.handleOpen(urls) }
        web.unregisterDraggedTypes()
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)

        dragView = WindowDragView(frame: .zero)
        dragView.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(dragView)

        window.contentView = container
        window.setFrameAutosaveName("SlideViewMain")
        window.center()
        window.makeKeyAndOrderFront(nil)

        buildMenu()
        NSApp.activate(ignoringOtherApps: true)

        // The server lives on a fixed port, so WKWebView would happily keep
        // serving a previous build's app.js from its HTTP cache. Drop the
        // response caches on every launch — but NOT localStorage, which holds
        // reading position, starred slides and appearance.
        let caches: Set<String> = [WKWebsiteDataTypeDiskCache,
                                   WKWebsiteDataTypeMemoryCache,
                                   WKWebsiteDataTypeOfflineWebApplicationCache]
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        WKWebsiteDataStore.default().removeData(ofTypes: caches, modifiedSince: .distantPast) { [weak self] in
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            self?.web.load(req)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // MARK: Opening documents

    private var webReady = false
    private var pendingOpens: [URL] = []

    func application(_ app: NSApplication, open urls: [URL]) { handleOpen(urls) }

    func handleOpen(_ urls: [URL]) {
        var folders: [URL] = []
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { folders.append(u) } else { files.append(u) }
        }
        if !folders.isEmpty {
            Library.shared.addRoots(folders)
            web?.evaluateJavaScript("window.sv && window.sv.rootChanged && window.sv.rootChanged()")
        }
        guard !files.isEmpty else { return }
        guard webReady else { pendingOpens.append(contentsOf: files); return }

        var ids: [String] = []
        var rejected: [String] = []
        for f in files {
            if let d = Library.shared.adopt(f) { ids.append(d.id) }
            else { rejected.append(f.lastPathComponent) }
        }
        if let first = ids.first {
            let list = ids.map { "'\($0)'" }.joined(separator: ",")
            web.evaluateJavaScript("window.sv && window.sv.openPaths && window.sv.openPaths([\(list)])")
            _ = first
        }
        if !rejected.isEmpty {
            let a = NSAlert()
            a.messageText = rejected.count == 1 ? "Can't open \(rejected[0])"
                                                : "Can't open \(rejected.count) of those files"
            a.informativeText = "SlideView opens documents, slides, spreadsheets, images, notebooks, Markdown and text files."
            a.runModal()
        }
    }

    private func flushPendingOpens() {
        guard webReady, !pendingOpens.isEmpty else { return }
        let urls = pendingOpens
        pendingOpens.removeAll()
        handleOpen(urls)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = Array(Library.openable)
        panel.message = "Choose a document, deck, notebook, image or notes file"
        panel.begin { [weak self] r in
            guard r == .OK else { return }
            self?.handleOpen(panel.urls)
        }
    }

    // MARK: JS bridge

    func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard let body = msg.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "ready":
            webReady = true
            flushPendingOpens()
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
        case "copyText":
            if let t = body["text"] as? String, !t.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
            }
        case "dragZone":
            // The page tells us where the tabs end; everything right of that
            // (across the tab strip's height) becomes window-drag territory.
            if let x = body["x"] as? Double, let h = body["h"] as? Double,
               let host = web.superview {
                let w = max(0, host.bounds.width - x)
                dragView.frame = NSRect(x: x, y: host.bounds.height - h, width: w, height: h)
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

    private func mi(_ title: String, _ key: String = "",
                    _ mods: NSEvent.ModifierFlags = [.command], cmd: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: #selector(runCmd(_:)), keyEquivalent: key)
        if !key.isEmpty { it.keyEquivalentModifierMask = mods }
        it.target = self
        it.representedObject = cmd
        return it
    }

    @objc private func runCmd(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? String else { return }
        web.evaluateJavaScript("window.sv && window.sv.cmd && window.sv.cmd('\(cmd)')")
    }

    private func buildMenu() {
        let main = NSMenu()

        // ── SlideView ────────────────────────────────────────────────
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About SlideView",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let addFolder = NSMenuItem(title: "Add Folder to Library…",
                                   action: #selector(menuChooseRoot), keyEquivalent: "o")
        addFolder.keyEquivalentModifierMask = [.command, .shift]
        addFolder.target = self
        appMenu.addItem(addFolder)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide SlideView", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit SlideView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // ── File ─────────────────────────────────────────────────────
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        let open = NSMenuItem(title: "Open…", action: #selector(menuOpen), keyEquivalent: "o")
        open.target = self
        file.addItem(open)
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        file.addItem(recentItem)
        file.addItem(.separator())
        file.addItem(mi("Close Tab", "w", cmd: "closeTab"))
        file.addItem(.separator())
        file.addItem(mi("Export Deck Notes as Markdown…", "e", [.command, .option], cmd: "exportNotes"))
        let reveal = NSMenuItem(title: "Reveal Original in Finder", action: #selector(menuReveal), keyEquivalent: "r")
        reveal.keyEquivalentModifierMask = [.command, .shift]
        reveal.target = self
        file.addItem(reveal)
        file.addItem(mi("Rescan Library", "r", cmd: "rescan"))
        fileItem.submenu = file
        main.addItem(fileItem)

        // ── Edit ─────────────────────────────────────────────────────
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(mi("Find in Deck…", "f", cmd: "search"))
        editItem.submenu = edit
        main.addItem(editItem)

        // ── View ─────────────────────────────────────────────────────
        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        let appearance = NSMenu(title: "Appearance")
        appearance.addItem(mi("Smart Invert", "1", [.command, .option], cmd: "theme:smart"))
        appearance.addItem(mi("Invert Everything", "2", [.command, .option], cmd: "theme:invert"))
        appearance.addItem(mi("Dim", "3", [.command, .option], cmd: "theme:dim"))
        appearance.addItem(mi("Original Colours", "4", [.command, .option], cmd: "theme:light"))
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearance
        view.addItem(appearanceItem)
        view.addItem(.separator())
        view.addItem(mi("Hide All but the Slide", "h", [.command, .control], cmd: "zen"))
        view.addItem(mi("Thumbnail Rail", "t", [.command, .option], cmd: "strip"))
        view.addItem(mi("Notes", "n", [.command, .option], cmd: "notes"))
        view.addItem(.separator())
        view.addItem(mi("Zoom In", "+", cmd: "zoomIn"))
        view.addItem(mi("Zoom Out", "-", cmd: "zoomOut"))
        view.addItem(mi("Fit to Window", "0", cmd: "fit"))
        view.addItem(mi("Fit to Width", "0", [.command, .option], cmd: "fitWidth"))
        view.addItem(.separator())
        let fs = NSMenuItem(title: "Enter Full Screen",
                            action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        view.addItem(fs)
        let reload = NSMenuItem(title: "Reload", action: #selector(menuReload), keyEquivalent: "r")
        reload.keyEquivalentModifierMask = [.command, .option]
        reload.target = self
        view.addItem(reload)
        viewItem.submenu = view
        main.addItem(viewItem)

        // ── Go ───────────────────────────────────────────────────────
        let goItem = NSMenuItem()
        let go = NSMenu(title: "Go")
        go.addItem(mi("Next Slide", cmd: "next"))
        go.addItem(mi("Previous Slide", cmd: "prev"))
        go.addItem(mi("First Slide", cmd: "first"))
        go.addItem(mi("Last Slide", cmd: "last"))
        go.addItem(.separator())
        go.addItem(mi("Go to Slide…", "g", cmd: "goto"))
        go.addItem(.separator())
        go.addItem(mi("Star This Slide", "d", cmd: "star"))
        go.addItem(mi("Next Starred", "]", [.command, .option], cmd: "nextStar"))
        go.addItem(mi("Previous Starred", "[", [.command, .option], cmd: "prevStar"))
        go.addItem(mi("Starred Slides", "s", [.command, .option], cmd: "starList"))
        go.addItem(.separator())
        go.addItem(mi("Library", "l", cmd: "library"))
        goItem.submenu = go
        main.addItem(goItem)

        // ── Window ───────────────────────────────────────────────────
        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(mi("New Tab", "t", cmd: "newTab"))
        win.addItem(mi("Next Tab", "}", [.command, .shift], cmd: "nextTab"))
        win.addItem(mi("Previous Tab", "{", [.command, .shift], cmd: "prevTab"))
        win.addItem(.separator())
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let closeWin = NSMenuItem(title: "Close Window",
                                  action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWin.keyEquivalentModifierMask = [.command, .shift]
        win.addItem(closeWin)
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.windowsMenu = win

        // ── Help ─────────────────────────────────────────────────────
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(mi("Keyboard Shortcuts", "/", cmd: "help"))
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    @objc private func menuOpen() { openPanel() }
    @objc private func menuReveal() {
        web.evaluateJavaScript("window.sv && window.sv.cmd && window.sv.cmd('reveal')")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls.isEmpty {
            let none = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for u in urls.prefix(12) {
            let it = NSMenuItem(title: u.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = u
            it.toolTip = u.path
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecents), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }
    @objc private func openRecent(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { handleOpen([u]) }
    }
    @objc private func clearRecents() { NSDocumentController.shared.clearRecentDocuments(nil) }

    @objc private func menuChooseRoot() { chooseRoot() }
    @objc private func menuReload() { web.reload() }
    @objc private func menuNewTab() { web.evaluateJavaScript("window.sv && window.sv.newTab && window.sv.newTab()") }
    @objc private func menuCloseTab() { web.evaluateJavaScript("window.sv && window.sv.closeTab && window.sv.closeTab()") }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
