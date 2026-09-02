import Foundation
import PDFKit
import AppKit
import CryptoKit

struct Doc {
    var id: String
    var url: URL
    var name: String
    var subject: String
    var ext: String
    var size: Int
    var modified: Double
    var needsConversion: Bool
}

enum ConvState: String { case ready, converting, error, pending }

final class Library {
    static let shared = Library()

    private(set) var roots: [URL] = []
    var root: URL { roots.first ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0] }
    private var docs: [String: Doc] = [:]
    private var states: [String: ConvState] = [:]
    private var errors: [String: String] = [:]
    private var pageCounts: [String: Int] = [:]   // keyed by cache filename (mtime+size aware)
    private var notesCache: [String: [String: String]] = [:]
    private let lock = NSLock()
    private let convQueue = OperationQueue()

    let support: URL
    let cacheDir: URL
    let thumbDir: URL
    let profileDir: URL
    let notesDir: URL

    private static let convertible: Set<String> = ["pptx", "ppt", "odp", "key", "docx", "doc", "odt"]
    private static let native: Set<String> = ["pdf"]

    private init() {
        let fm = FileManager.default
        support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SlideView", isDirectory: true)
        cacheDir = support.appendingPathComponent("pdf", isDirectory: true)
        thumbDir = support.appendingPathComponent("thumbs", isDirectory: true)
        notesDir = support.appendingPathComponent("notes", isDirectory: true)
        // LibreOffice takes its profile as a file:// URL; keep it away from
        // paths like "Application Support" whose space trips up the parser.
        profileDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.raja.slideview/lo-profile", isDirectory: true)
        for d in [support, cacheDir, thumbDir, profileDir, notesDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        convQueue.maxConcurrentOperationCount = 1   // one soffice instance per profile

        var list = UserDefaults.standard.stringArray(forKey: "libraryRoots") ?? []
        if list.isEmpty, let legacy = UserDefaults.standard.string(forKey: "libraryRoot") { list = [legacy] }
        if list.isEmpty {
            let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            let guess = desktop.appendingPathComponent("5th sem")
            list = [fm.fileExists(atPath: guess.path) ? guess.path : desktop.path]
        }
        roots = list.filter { fm.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    func addRoots(_ urls: [URL]) {
        lock.lock()
        for u in urls where !roots.contains(where: { $0.standardizedFileURL == u.standardizedFileURL }) {
            roots.append(u)
        }
        let snapshot = roots
        lock.unlock()
        UserDefaults.standard.set(snapshot.map(\.path), forKey: "libraryRoots")
    }

    func removeRoot(_ path: String) {
        lock.lock()
        roots.removeAll { $0.path == path }
        let snapshot = roots
        lock.unlock()
        UserDefaults.standard.set(snapshot.map(\.path), forKey: "libraryRoots")
    }

    // MARK: - Scanning

    @discardableResult
    func scan() -> [Doc] {
        var found: [Doc] = []
        var seen = Set<String>()
        for r in roots {
            for d in scanOne(r) where !seen.contains(d.id) { seen.insert(d.id); found.append(d) }
        }
        found.sort {
            if $0.subject != $1.subject { return $0.subject.localizedStandardCompare($1.subject) == .orderedAscending }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        lock.lock()
        docs = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        lock.unlock()
        return found
    }

    private func scanOne(_ root: URL) -> [Doc] {
        let fm = FileManager.default
        var found: [Doc] = []
        let rootPath = root.standardizedFileURL.path

        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in en {
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if vals?.isDirectory == true {
                let n = url.lastPathComponent
                if n == "SlideView" || n == "node_modules" || n.hasPrefix(".") { en.skipDescendants() }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard Self.convertible.contains(ext) || Self.native.contains(ext) else { continue }
            if url.lastPathComponent.hasPrefix("~$") || url.lastPathComponent.hasPrefix(".") { continue }

            let rel = url.deletingLastPathComponent().standardizedFileURL.path
            var subject = root.lastPathComponent
            if rel != rootPath, rel.hasPrefix(rootPath) {
                let r = String(rel.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !r.isEmpty { subject = r }
            }

            let doc = Doc(id: Self.hash(url.path),
                          url: url,
                          name: url.deletingPathExtension().lastPathComponent,
                          subject: subject,
                          ext: ext,
                          size: vals?.fileSize ?? 0,
                          modified: vals?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                          needsConversion: !Self.native.contains(ext))
            found.append(doc)
        }
        return found
    }

    func doc(_ id: String) -> Doc? { lock.lock(); defer { lock.unlock() }; return docs[id] }

    static func hash(_ s: String) -> String {
        let d = SHA256.hash(data: Data(s.utf8))
        return d.map { String(format: "%02x", $0) }.prefix(16).joined()
    }

    // MARK: - PDF resolution

    /// Path where the converted PDF for `doc` lives (keyed on mtime+size so edits invalidate).
    func pdfPath(_ doc: Doc) -> URL {
        if !doc.needsConversion { return doc.url }
        let key = "\(doc.id)-\(Int(doc.modified))-\(doc.size)"
        return cacheDir.appendingPathComponent("\(key).pdf")
    }

    func state(_ doc: Doc) -> ConvState {
        if FileManager.default.fileExists(atPath: pdfPath(doc).path) { return .ready }
        lock.lock(); defer { lock.unlock() }
        return states[doc.id] ?? .pending
    }

    func error(_ id: String) -> String? { lock.lock(); defer { lock.unlock() }; return errors[id] }

    func convert(_ doc: Doc) {
        if state(doc) == .ready || state(doc) == .converting { return }
        lock.lock(); states[doc.id] = .converting; errors[doc.id] = nil; lock.unlock()

        convQueue.addOperation { [weak self] in
            guard let self else { return }
            let out = self.pdfPath(doc)
            let tmp = self.cacheDir.appendingPathComponent("tmp-\(doc.id)-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let soffice = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
            guard FileManager.default.fileExists(atPath: soffice) else {
                self.fail(doc, "LibreOffice not found at /Applications/LibreOffice.app")
                return
            }

            let profileURL = "file://" + (self.profileDir.path
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self.profileDir.path)

            let p = Process()
            p.executableURL = URL(fileURLWithPath: soffice)
            p.arguments = [
                "-env:UserInstallation=\(profileURL)",
                "--headless", "--norestore", "--nolockcheck",
                "--convert-to", "pdf", "--outdir", tmp.path, doc.url.path
            ]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe

            do {
                try p.run()
                let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                let produced = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil))?
                    .first { $0.pathExtension.lowercased() == "pdf" }
                guard let produced else {
                    self.fail(doc, "Conversion produced no PDF.\n\(log.suffix(400))")
                    return
                }
                try? FileManager.default.removeItem(at: out)
                try FileManager.default.moveItem(at: produced, to: out)
                self.pruneOldCache(for: doc)
                self.lock.lock(); self.states[doc.id] = .ready; self.lock.unlock()
            } catch {
                self.fail(doc, error.localizedDescription)
            }
        }
    }

    private func fail(_ doc: Doc, _ msg: String) {
        lock.lock(); states[doc.id] = .error; errors[doc.id] = msg; lock.unlock()
    }

    /// Drop stale converted copies of the same source file (older mtime/size keys).
    private func pruneOldCache(for doc: Doc) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
        else { return }
        let keep = pdfPath(doc).lastPathComponent
        for f in items where f.lastPathComponent.hasPrefix(doc.id + "-") && f.lastPathComponent != keep {
            try? FileManager.default.removeItem(at: f)
        }
        for f in items where f.lastPathComponent.hasPrefix("thumb-\(doc.id)") {
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: - Per-slide notes

    /// Notes live in their own JSON file per deck, keyed by page number, and the
    /// file records the deck's name and path so it still makes sense on its own.
    /// They are deliberately NOT keyed by mtime — re-converting a deck after an
    /// edit must not throw away what you wrote.
    private func notesURL(_ id: String) -> URL { notesDir.appendingPathComponent("\(id).json") }

    func notes(_ id: String) -> [String: String] {
        lock.lock()
        if let hit = notesCache[id] { lock.unlock(); return hit }
        lock.unlock()

        var out: [String: String] = [:]
        if let d = try? Data(contentsOf: notesURL(id)),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let n = obj["notes"] as? [String: String] { out = n }
        lock.lock(); notesCache[id] = out; lock.unlock()
        return out
    }

    func setNote(_ id: String, page: Int, text: String) {
        var n = notes(id)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            n.removeValue(forKey: String(page))
        } else {
            n[String(page)] = text
        }
        lock.lock(); notesCache[id] = n; lock.unlock()

        let d = doc(id)
        let payload: [String: Any] = [
            "name": d?.name ?? "", "path": d?.url.path ?? "",
            "updated": ISO8601DateFormatter().string(from: Date()), "notes": n
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: notesURL(id), options: .atomic)
        }
    }

    func noteCount(_ id: String) -> Int { notes(id).count }

    // MARK: - Metadata + thumbnails

    /// Opening a PDFDocument per deck on every library poll is far too slow once
    /// the library grows, and the answer cannot change without the cache key
    /// (which folds in mtime and size) changing too — so memoise it.
    func pageCount(_ doc: Doc) -> Int {
        let p = pdfPath(doc)
        let key = p.lastPathComponent
        lock.lock()
        if let hit = pageCounts[key] { lock.unlock(); return hit }
        lock.unlock()

        guard FileManager.default.fileExists(atPath: p.path), let pdf = PDFDocument(url: p) else { return 0 }
        let n = pdf.pageCount
        lock.lock(); pageCounts[key] = n; lock.unlock()
        return n
    }

    /// Render any page of the converted PDF as an image (used by the
    /// right-click actions: clipboard, Google Lens, …).
    func pageImage(_ doc: Doc, page: Int, width: CGFloat = 2000) -> NSImage? {
        let p = pdfPath(doc)
        guard let pdf = PDFDocument(url: p), page >= 1, page <= pdf.pageCount,
              let pg = pdf.page(at: page - 1) else { return nil }
        let box = pg.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = width / box.width
        let size = NSSize(width: width, height: (box.height * scale).rounded())
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
            pg.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        img.unlockFocus()
        return img
    }

    func pageText(_ doc: Doc, page: Int) -> String {
        let p = pdfPath(doc)
        guard let pdf = PDFDocument(url: p), page >= 1, page <= pdf.pageCount,
              let pg = pdf.page(at: page - 1) else { return "" }
        return (pg.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func thumbnail(_ doc: Doc, width: CGFloat = 640) -> Data? {
        let key = "\(doc.id)-\(Int(doc.modified))-\(doc.size)-\(Int(width)).png"
        let cached = thumbDir.appendingPathComponent(key)
        if let d = try? Data(contentsOf: cached) { return d }

        let p = pdfPath(doc)
        guard FileManager.default.fileExists(atPath: p.path),
              let pdf = PDFDocument(url: p), let page = pdf.page(at: 0) else { return nil }

        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = width / box.width
        let size = NSSize(width: width, height: (box.height * scale).rounded())

        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        img.unlockFocus()

        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: cached)
        return png
    }
}
