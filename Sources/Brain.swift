import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Ask a question, get an answer from your own material.
///
/// Three parts, kept apart so each can be tested:
///   • `BrainText` and `PassageIndex` — cut every page into passages and rank them
///     against a question with BM25. Plain keyword scoring: no model, no network.
///   • `BrainPrompt` — turns the best passages into numbered notes for the model.
///   • `OnDeviceModel` — Apple's built-in language model, which runs on this Mac.
///     Where it is missing the passages are still returned, so the panel works as
///     a search of the whole library.
///
/// Nothing here talks to anything but this machine.

struct Passage: Codable, Equatable {
    var doc: String       // document id
    var page: Int
    var text: String
}

// MARK: - Text

enum BrainText {
    private static let stop: Set<String> = [
        "the","and","for","that","with","this","from","are","was","were","have","has","had",
        "not","but","you","your","can","will","would","should","could","which","when","what",
        "there","their","they","them","then","than","also","into","such","each","other","more",
        "most","some","any","all","its","been","being","between","because","about","only",
        "these","those","where","while","does","did","how","why","who","is","it","in","on",
        "of","to","as","at","by","an","or","be","do","if","so","we","me","my","a","i"]

    /// Lower-cased words of a text, without common words, each cut to a rough stem
    /// so "transitions" in a question matches "transition" on a slide.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var word = ""
        func flush() {
            if word.count >= 2, !stop.contains(word) { out.append(stem(word)) }
            word = ""
        }
        for ch in s.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) { word.unicodeScalars.append(ch) } else { flush() }
        }
        flush()
        return out
    }

    static func stem(_ w: String) -> String {
        guard w.count > 4, w.allSatisfy({ $0.isLetter }) else { return w }
        for (suffix, keep) in [("ies", "y"), ("sses", "ss"), ("ing", ""), ("ed", ""), ("es", ""), ("s", "")] {
            if w.hasSuffix(suffix), w.count - suffix.count + keep.count >= 3, !(suffix == "s" && w.hasSuffix("ss")) {
                return String(w.dropLast(suffix.count)) + keep
            }
        }
        return w
    }

    /// Cut a page into passages of about `limit` characters, breaking at blank
    /// lines, then line ends, then sentence ends, so a passage reads as a unit.
    static func split(_ text: String, limit: Int = 900) -> [String] {
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean.isEmpty ? [] : [clean] }

        var pieces: [String] = []
        var current = ""
        func push() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { pieces.append(t) }
            current = ""
        }
        for paragraph in clean.components(separatedBy: "\n\n") {
            for unit in units(of: paragraph, limit: limit) {
                if !current.isEmpty, current.count + unit.count + 1 > limit { push() }
                current += (current.isEmpty ? "" : "\n") + unit
            }
            if current.count > limit / 2 { push() }
        }
        push()
        return pieces
    }

    /// A paragraph as lines; any line still too long as sentences; any sentence
    /// still too long as hard slices.
    private static func units(of paragraph: String, limit: Int) -> [String] {
        var out: [String] = []
        for line in paragraph.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if line.count <= limit { out.append(line); continue }
            var sentence = ""
            for ch in line {
                sentence.append(ch)
                if ".!?".contains(ch), sentence.count > 40 { out.append(contentsOf: slices(sentence, limit)); sentence = "" }
            }
            out.append(contentsOf: slices(sentence, limit))
        }
        return out
    }

    private static func slices(_ s: String, _ limit: Int) -> [String] {
        var out: [String] = []
        var rest = Substring(s.trimmingCharacters(in: .whitespaces))
        while !rest.isEmpty {
            out.append(String(rest.prefix(limit)))
            rest = rest.dropFirst(limit)
        }
        return out
    }
}

// MARK: - Ranking

/// BM25 over a fixed set of passages.
struct PassageIndex {
    let passages: [Passage]
    private var postings: [String: [(index: Int, count: Double)]] = [:]
    private var lengths: [Double] = []
    private var averageLength: Double = 1

    init(_ passages: [Passage]) {
        self.passages = passages
        lengths.reserveCapacity(passages.count)
        var total = 0.0
        for (i, p) in passages.enumerated() {
            let words = BrainText.tokens(p.text)
            var counts: [String: Double] = [:]
            for w in words { counts[w, default: 0] += 1 }
            for (w, c) in counts { postings[w, default: []].append((i, c)) }
            lengths.append(Double(words.count))
            total += Double(words.count)
        }
        averageLength = passages.isEmpty ? 1 : max(1, total / Double(passages.count))
    }

    /// The passages that best match `query`, best first, at most one per page so
    /// a single wordy page cannot fill the whole answer.
    func search(_ query: String, limit: Int = 5) -> [(passage: Passage, score: Double)] {
        let k1 = 1.5, b = 0.75
        let n = Double(passages.count)
        var scores: [Int: Double] = [:]
        for term in Set(BrainText.tokens(query)) {
            guard let hits = postings[term] else { continue }
            let idf = log(1 + (n - Double(hits.count) + 0.5) / (Double(hits.count) + 0.5))
            for h in hits {
                let norm = h.count + k1 * (1 - b + b * lengths[h.index] / averageLength)
                scores[h.index, default: 0] += idf * h.count * (k1 + 1) / norm
            }
        }
        var seen = Set<String>()
        var out: [(Passage, Double)] = []
        for (i, s) in scores.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
            let p = passages[i]
            if seen.insert("\(p.doc)#\(p.page)").inserted { out.append((p, s)) }
            if out.count == limit { break }
        }
        return out
    }
}

// MARK: - Prompt

enum BrainPrompt {
    static let instructions = """
        You help a student revise from their own study material. Answer the question using \
        only the numbered notes you are given. After each fact, cite the note it came from \
        like [1]. If the notes do not contain the answer, say you could not find it in their \
        material and do not guess. Keep the answer short and plain.
        """

    /// The notes and the question as one prompt. `budget` caps the characters of
    /// notes so the whole thing fits a small model's context.
    static func build(question: String, notes: [(title: String, page: Int, text: String)], budget: Int = 4800) -> String {
        var out = "Notes:\n"
        var used = 0
        for (i, n) in notes.enumerated() {
            let room = budget - used
            if room < 200 { break }
            let text = String(n.text.prefix(room))
            out += "\n[\(i + 1)] \(n.title), page \(n.page)\n\(text)\n"
            used += text.count
        }
        return out + "\nQuestion: \(question.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

// MARK: - Model

/// Apple's on-device language model. It needs macOS 26, Apple silicon and Apple
/// Intelligence switched on; `state` says which of those is missing.
enum OnDeviceModel {
    struct State { var ready: Bool; var reason: String }

    static var state: State {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return State(ready: true, reason: "")
            case .unavailable(.appleIntelligenceNotEnabled):
                return State(ready: false, reason: "Turn on Apple Intelligence in System Settings to get written answers.")
            case .unavailable(.modelNotReady):
                return State(ready: false, reason: "Apple's on-device model is not ready yet. Turn on Apple Intelligence in System Settings and let it finish downloading.")
            case .unavailable(.deviceNotEligible):
                return State(ready: false, reason: "This Mac cannot run Apple's on-device model.")
            case .unavailable:
                return State(ready: false, reason: "Apple's on-device model is unavailable.")
            }
        }
        #endif
        return State(ready: false, reason: "Written answers need macOS 26 or later.")
    }

    /// Blocks until the model has answered. Call off the main thread.
    static func answer(instructions: String, prompt: String) throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            final class Box: @unchecked Sendable { var result: Result<String, Error>? }
            let box = Box()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    box.result = .success(try await session.respond(to: prompt).content)
                } catch {
                    box.result = .failure(error)
                }
                done.signal()
            }
            done.wait()
            return try box.result!.get()
        }
        #endif
        throw NSError(domain: "SlideView", code: 2, userInfo: [NSLocalizedDescriptionKey: state.reason])
    }
}

// MARK: - The library's index

/// Reads every ready document page by page and keeps the passages, so a question
/// can be answered without opening a single file. Each document's passages are
/// cached on disk against its size and date and reread only when it changes.
final class Brain {
    static let shared = Brain()

    private let lock = NSLock()
    private var index: PassageIndex?
    private var names: [String: String] = [:]
    private var building = false
    private var done = 0, total = 0
    private let queue = DispatchQueue(label: "slideview.brain")
    private let cacheDir: URL

    private init() {
        cacheDir = Library.shared.support.appendingPathComponent("passages", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Forget the index: the set of documents just changed underneath it.
    func invalidate() {
        lock.lock(); index = nil; lock.unlock()
    }

    func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let model = OnDeviceModel.state
        var out: [String: Any] = ["ready": index != nil, "progress": done, "total": total,
                                  "model": model.ready, "modelNote": model.reason]
        if let index { out["passages"] = index.passages.count; out["documents"] = names.count }
        return out
    }

    func build() {
        lock.lock()
        if building || index != nil { lock.unlock(); return }
        building = true; done = 0
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let (built, names) = self.read()
            self.lock.lock()
            self.index = built; self.names = names; self.building = false
            self.lock.unlock()
        }
    }

    private func read() -> (PassageIndex, [String: String]) {
        let lib = Library.shared
        let docs = lib.scan().filter { !Library.isSensitive($0.url) && lib.state($0) == .ready }
        lock.lock(); total = docs.count; done = 0; lock.unlock()

        var all: [Passage] = []
        var names: [String: String] = [:]
        for d in docs {
            let file = cacheDir.appendingPathComponent("\(d.id)-\(Int(d.modified))-\(d.size).json")
            var passages: [Passage] = []
            if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode([Passage].self, from: data) {
                passages = cached
            } else {
                let pages = lib.pageCount(d)
                if pages > 0 {
                    for page in 1...pages {
                        for piece in BrainText.split(lib.pageText(d, page: page)) {
                            passages.append(Passage(doc: d.id, page: page, text: piece))
                        }
                    }
                }
                dropStale(d.id)
                if let data = try? JSONEncoder().encode(passages) { try? data.write(to: file, options: .atomic) }
            }
            if !passages.isEmpty { names[d.id] = d.name }
            all.append(contentsOf: passages)
            lock.lock(); done += 1; lock.unlock()
        }
        return (PassageIndex(all), names)
    }

    private func dropStale(_ id: String) {
        let old = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
        for f in old where f.hasPrefix("\(id)-") { try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(f)) }
    }

    /// The answer to `question` with the passages it was drawn from. While the
    /// index is still being read this returns its progress instead.
    func ask(_ question: String) -> [String: Any] {
        lock.lock()
        let index = self.index, names = self.names
        lock.unlock()
        guard let index else {
            build()
            var s = status(); s["answer"] = NSNull(); s["sources"] = [Any]()
            return s
        }

        let hits = index.search(question, limit: 5)
        let sources: [[String: Any]] = hits.enumerated().map { i, h in
            ["n": i + 1, "id": h.passage.doc, "name": names[h.passage.doc] ?? "Document",
             "page": h.passage.page, "text": h.passage.text]
        }
        var out: [String: Any] = ["ready": true, "sources": sources, "answer": NSNull()]
        let model = OnDeviceModel.state
        out["model"] = model.ready
        out["modelNote"] = model.reason
        guard model.ready, !hits.isEmpty else { return out }

        let notes = hits.map { (title: names[$0.passage.doc] ?? "Document", page: $0.passage.page, text: $0.passage.text) }
        do {
            out["answer"] = try OnDeviceModel.answer(instructions: BrainPrompt.instructions,
                                                     prompt: BrainPrompt.build(question: question, notes: notes))
        } catch {
            out["modelNote"] = "The model could not answer: \(error.localizedDescription)"
        }
        return out
    }
}
