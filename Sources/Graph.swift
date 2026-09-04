import Foundation
import PDFKit

/// Builds a map of the library: which documents are linked, and which cover the
/// same ground.
///
/// Two kinds of edge:
///   • `link`    — an explicit `[[wikilink]]` or `](file)` in a notes file.
///   • `similar` — significant vocabulary shared between two documents, scored
///                 with TF-IDF so common words ("network", "the") do not tie
///                 everything to everything.
///
/// Written from scratch. Obsidian is closed source, and Logseq is AGPL-3.0, so
/// neither could contribute code to an MIT project.
final class GraphBuilder {
    static let shared = GraphBuilder()

    private let lock = NSLock()
    private var built: [String: Any]?
    private var building = false
    private var done = 0, total = 0
    private let queue = DispatchQueue(label: "slideview.graph")

    private let sigDir: URL
    private init() {
        sigDir = Library.shared.support.appendingPathComponent("signatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: sigDir, withIntermediateDirectories: true)
    }

    private static let stop: Set<String> = [
        "the","and","for","that","with","this","from","are","was","were","have","has","had",
        "not","but","you","your","can","will","would","should","could","which","when","what",
        "there","their","they","them","then","than","also","into","using","used","use","such",
        "each","other","more","most","some","any","all","one","two","three","its","been","being","between","because","about","over","under","only",
        "these","those","where","while","after","before","both","same","very","much","many",
        "shall","must","may","per","via","etc","fig","figure","table","page","slide","chapter",
        "unit","example","examples","given","above","below","following","note","notes"]

    func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        if let built { return built }
        return ["ready": false, "progress": done, "total": total]
    }

    func build(force: Bool) {
        lock.lock()
        if building || (built != nil && !force) { lock.unlock(); return }
        building = true
        if force { built = nil }
        done = 0
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let graph = self.compute()
            self.lock.lock()
            self.built = graph
            self.building = false
            self.lock.unlock()
        }
    }

    // MARK: - Building

    private func compute() -> [String: Any] {
        let lib = Library.shared
        let docs = lib.scan().filter { lib.state($0) == .ready }
        lock.lock(); total = docs.count; done = 0; lock.unlock()

        var sigs: [String: [String: Double]] = [:]        // docId -> term: tf
        var df: [String: Int] = [:]

        for d in docs {
            let tf = signature(d)
            sigs[d.id] = tf
            for term in tf.keys { df[term, default: 0] += 1 }
            lock.lock(); done += 1; lock.unlock()
        }

        let n = max(1, docs.count)
        func idf(_ t: String) -> Double { log(Double(n) / Double(1 + (df[t] ?? 0))) + 1 }

        // top terms per document, weighted
        var top: [String: [String: Double]] = [:]
        for (id, tf) in sigs {
            let scored = tf.map { ($0.key, $0.value * idf($0.key)) }
                           .sorted { $0.1 > $1.1 }
                           .prefix(28)
            top[id] = Dictionary(uniqueKeysWithValues: scored.map { ($0.0, $0.1) })
        }

        // similarity edges, capped per node so the map stays readable
        var scored: [(String, String, Double)] = []
        let ids = docs.map(\.id)
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                guard let a = top[ids[i]], let b = top[ids[j]] else { continue }
                var w = 0.0
                for (t, wa) in a { if let wb = b[t] { w += min(wa, wb) } }
                if w > 0 { scored.append((ids[i], ids[j], w)) }
            }
        }
        let maxW = scored.map(\.2).max() ?? 1
        var kept: [String: Int] = [:]
        var edges: [[String: Any]] = []
        for e in scored.sorted(by: { $0.2 > $1.2 }) {
            let norm = e.2 / maxW
            guard norm > 0.16 else { break }
            if kept[e.0, default: 0] >= 4 || kept[e.1, default: 0] >= 4 { continue }
            kept[e.0, default: 0] += 1
            kept[e.1, default: 0] += 1
            edges.append(["a": e.0, "b": e.1, "w": norm, "kind": "similar"])
        }

        // explicit links written in notes files
        let byName = Dictionary(docs.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
        for d in docs where Library.kind(d.ext) == .markdown || Library.kind(d.ext) == .text {
            guard let raw = Converters.readText(d.url) else { continue }
            for target in Self.references(in: raw) {
                guard let tid = byName[target.lowercased()], tid != d.id else { continue }
                edges.append(["a": d.id, "b": tid, "w": 1.0, "kind": "link"])
            }
        }

        let nodes: [[String: Any]] = docs.map { d in
            ["id": d.id, "name": d.name, "subject": d.subject, "ext": d.ext,
             "pages": lib.pageCount(d), "notes": lib.noteCount(d.id),
             "terms": (top[d.id] ?? [:]).sorted { $0.value > $1.value }.prefix(6).map(\.key)]
        }
        return ["ready": true, "nodes": nodes, "edges": edges]
    }

    /// `[[wikilink]]` and `](target)` references.
    private static func references(in text: String) -> [String] {
        var out: [String] = []
        for pattern in [#"\[\[([^\]|#]+)"#, #"\]\(([^)\s#]+)\)"#] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var t = ns.substring(with: m.range(at: 1))
                if t.hasPrefix("http") || t.hasPrefix("#") { continue }
                t = (t as NSString).lastPathComponent
                if let dot = t.lastIndex(of: "."), t.distance(from: dot, to: t.endIndex) <= 6 {
                    t = String(t[t.startIndex..<dot])
                }
                let clean = t.trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty { out.append(clean) }
            }
        }
        return out
    }

    // MARK: - Per-document vocabulary

    private func signature(_ doc: Doc) -> [String: Double] {
        let key = Library.shared.pdfPath(doc).lastPathComponent + ".json"
        let cache = sigDir.appendingPathComponent(key)
        if let d = try? Data(contentsOf: cache),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Double] { return o }

        var text = ""
        if let pdf = PDFDocument(url: Library.shared.pdfPath(doc)) {
            text = String((pdf.string ?? "").prefix(400_000))
        }
        var counts: [String: Int] = [:]
        var totalTerms = 0
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            let w = String(raw)
            guard w.count >= 4, w.count <= 24, !Self.stop.contains(w) else { continue }
            counts[w, default: 0] += 1
            totalTerms += 1
        }
        guard totalTerms > 0 else { return [:] }
        let tf = counts.filter { $0.value >= 2 }
            .mapValues { Double($0) / Double(totalTerms) }
        let trimmed = Dictionary(uniqueKeysWithValues:
            tf.sorted { $0.value > $1.value }.prefix(160).map { ($0.key, $0.value) })
        if let d = try? JSONSerialization.data(withJSONObject: trimmed) { try? d.write(to: cache) }
        return trimmed
    }
}
