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

    /// How much of a passage reads as sentences, from 0 (a table, a formula, loose
    /// diagram labels) to 1 (plain prose). A question is better answered by the page
    /// that explains than by the page that tabulates.
    static func prose(_ text: String) -> Double {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 4 else { return 0.3 }
        let plain = words.filter { w in
            let letters = w.filter { $0.isLetter }.count
            return letters >= 2 && letters * 10 >= w.count * 8
        }.count
        let share = Double(plain) / Double(words.count)
        let sentences = text.filter { ".?!".contains($0) }.count
        let flow = min(1, Double(sentences) * 12 / Double(words.count))   // about one stop per dozen words
        return max(0, min(1, share * (0.6 + 0.4 * flow)))
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
    private var prose: [Double] = []
    private var averageLength: Double = 1

    /// `titles` maps a document id to its name, so a question that names a deck finds it.
    init(_ passages: [Passage], titles: [String: String] = [:]) {
        self.passages = passages
        lengths.reserveCapacity(passages.count)
        var total = 0.0
        for (i, p) in passages.enumerated() {
            let words = BrainText.tokens(p.text) + BrainText.tokens(titles[p.doc] ?? "")
            var counts: [String: Double] = [:]
            for w in words { counts[w, default: 0] += 1 }
            for (w, c) in counts { postings[w, default: []].append((i, c)) }
            lengths.append(Double(words.count))
            prose.append(BrainText.prose(p.text))
            total += Double(words.count)
        }
        averageLength = passages.isEmpty ? 1 : max(1, total / Double(passages.count))
    }

    /// Every passage that shares a word with `query`, best first. `related` are
    /// other words for the same idea and count for half. Pages that read as prose
    /// are preferred over tables and loose labels. `allowed` limits the search to
    /// some documents.
    func rank(_ query: String, related: [String] = [], allowed: Set<String>? = nil) -> [(index: Int, score: Double)] {
        let k1 = 1.5, b = 0.75
        let n = Double(passages.count)
        var weights: [String: Double] = [:]
        for term in BrainText.tokens(related.joined(separator: " ")) { weights[term] = 0.5 }
        for term in BrainText.tokens(query) { weights[term] = 1 }
        var scores: [Int: Double] = [:]
        for (term, weight) in weights {
            guard let hits = postings[term] else { continue }
            let idf = log(1 + (n - Double(hits.count) + 0.5) / (Double(hits.count) + 0.5))
            for h in hits {
                if let allowed, !allowed.contains(passages[h.index].doc) { continue }
                let norm = h.count + k1 * (1 - b + b * lengths[h.index] / averageLength)
                scores[h.index, default: 0] += weight * idf * h.count * (k1 + 1) / norm
            }
        }
        return scores.map { (index: $0.key, score: $0.value * (0.2 + 0.8 * prose[$0.key])) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
    }

    func proseScore(_ index: Int) -> Double { prose[index] }

    /// The best `limit` passages for `query`, at most one per page so a single
    /// wordy page cannot fill the whole answer.
    func search(_ query: String, related: [String] = [], allowed: Set<String>? = nil, limit: Int = 5) -> [(passage: Passage, score: Double)] {
        var seen = Set<String>()
        var out: [(Passage, Double)] = []
        for hit in rank(query, related: related, allowed: allowed) {
            let p = passages[hit.index]
            if seen.insert("\(p.doc)#\(p.page)").inserted { out.append((p, hit.score)) }
            if out.count == limit { break }
        }
        return out
    }
}

// MARK: - Prompt

enum BrainPrompt {
    static let instructions = """
        You help a student revise from their own study material. Speak to them as "you". \
        Answer the question using only the numbered notes you are given, in a few plain \
        sentences. After each fact, cite the note it came from, like [1]. The only valid \
        citations are the note numbers shown in square brackets at the start of each note; \
        numbers inside a note's text are part of the slide, not citations. Some notes are \
        labels lifted off a diagram in no particular order: do not guess which label goes \
        with which. If the notes do not clearly state the answer, reply only: "I could not \
        find that in your material." Do not guess and do not use outside knowledge.
        """

    /// Removes citation markers that point at no note, which a small model sometimes
    /// copies from list numbers inside a slide.
    static func tidy(_ answer: String, notes: Int) -> String {
        var out = ""
        var rest = Substring(answer)
        while let open = rest.firstIndex(of: "[") {
            out += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "]"), let n = Int(after[..<close]) {
                if n >= 1 && n <= notes { out += "[\(n)]" } else if out.hasSuffix(" ") { out.removeLast() }
                rest = after[after.index(after: close)...]
            } else {
                out += "["
                rest = after
            }
        }
        var text = out + rest
        for (left, right) in [(",.", "."), (", ,", ","), (",,", ","), (" .", "."), (":.", ".")] {
            text = text.replacingOccurrences(of: left, with: right)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Not found" needs no citation after it.
        if text.count < 80, text.lowercased().contains(notFound.lowercased().dropLast()) { return notFound }
        return text
    }

    static let notFound = "I could not find that in your material."

    /// Asks the model for other words a slide might use for the same idea, so a
    /// question about "DFA" also finds the page that says "deterministic automaton".
    static let related = """
        A student is searching their lecture slides. For the question you are given, list up \
        to eight other words or short phrases a slide about it would likely contain: full \
        forms of abbreviations, synonyms and closely related technical terms. Reply with the \
        list only, separated by commas, with no explanation.
        """

    /// The model's comma-separated reply as clean terms, capped so a rambling reply
    /// cannot swamp the question's own words.
    static func terms(_ reply: String, limit: Int = 8) -> [String] {
        reply.split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { $0.count >= 2 && $0.count <= 40 }
            .prefix(limit).map { $0 }
    }

    /// Used when no page matches at all, for a greeting or a general question.
    static let smallTalk = """
        You are the study assistant inside SlideView, a Mac app that holds a student's lecture \
        files. Nothing in their files matched what they just typed. If it is a greeting or small \
        talk, reply warmly in one sentence and invite a question about their material. If it is \
        a real question, answer briefly from general knowledge in at most three sentences.
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
/// cached on disk against its size and date and reread only when it changes. Once
/// the passages are in, their vectors are worked out in the background.
final class Brain {
    static let shared = Brain()

    private let lock = NSLock()
    private var index: PassageIndex?
    private var vectors: VectorIndex?
    private var names: [String: String] = [:]
    private var subjects: [String: Set<String>] = [:]
    private var suggestions: [String] = []
    private var building = false
    private var done = 0, total = 0
    private var embedded = 0
    private var stage = ""
    private var generation = 0
    private let queue = DispatchQueue(label: "slideview.brain")
    private let vectorQueue = DispatchQueue(label: "slideview.brain.vectors", qos: .utility)
    private let cacheDir: URL

    private init() {
        cacheDir = Library.shared.support.appendingPathComponent("passages", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Forget the index: the set of documents just changed underneath it.
    func invalidate() {
        lock.lock(); index = nil; vectors = nil; generation += 1; lock.unlock()
    }

    func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let model = Engine.state
        var out: [String: Any] = ["ready": index != nil, "progress": done, "total": total,
                                  "model": model.ready, "modelNote": model.reason, "engine": model.label, "stage": stage]
        if let index {
            out["passages"] = index.passages.count
            out["documents"] = names.count
            out["suggestions"] = suggestions
            out["subjects"] = subjects.keys.sorted()
            out["meaning"] = vectors != nil ? index.passages.count : embedded
        }
        return out
    }

    private func set(stage text: String) { lock.lock(); stage = text; lock.unlock() }

    func build() {
        lock.lock()
        if building || index != nil { lock.unlock(); return }
        building = true; done = 0
        let mine = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let read = self.read()
            self.lock.lock()
            self.index = read.index; self.names = read.names; self.subjects = read.subjects
            self.suggestions = Brain.suggest(read.index.passages, read.names)
            self.building = false; self.embedded = 0
            self.lock.unlock()
            self.vectorQueue.async { self.embed(read.index.passages, files: read.files, generation: mine) }
        }
    }

    private struct Read {
        var index: PassageIndex
        var names: [String: String]
        var subjects: [String: Set<String>]
        var files: [(doc: String, count: Int, url: URL)]
    }

    private func read() -> Read {
        let lib = Library.shared
        let docs = lib.scan().filter { !Library.isSensitive($0.url) && lib.state($0) == .ready }
        lock.lock(); total = docs.count; done = 0; lock.unlock()

        var all: [Passage] = []
        var names: [String: String] = [:]
        var subjects: [String: Set<String>] = [:]
        var files: [(String, Int, URL)] = []
        for d in docs {
            let stem = "\(d.id)-\(Int(d.modified))-\(d.size)"
            let file = cacheDir.appendingPathComponent("\(stem).json")
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
            if !passages.isEmpty {
                names[d.id] = d.name
                subjects[d.subject, default: []].insert(d.id)
                files.append((d.id, passages.count, cacheDir.appendingPathComponent("\(stem).f32")))
            }
            all.append(contentsOf: passages)
            lock.lock(); done += 1; lock.unlock()
        }
        return Read(index: PassageIndex(all, titles: names), names: names, subjects: subjects, files: files)
    }

    /// Works out a vector for every passage, a document at a time, reusing the
    /// ones already on disk. Stops quietly if the library changes meanwhile.
    private func embed(_ passages: [Passage], files: [(doc: String, count: Int, url: URL)], generation mine: Int) {
        let size = Embedder.dimension
        guard size > 0 else { return }
        var raw: [[Float]] = []
        raw.reserveCapacity(passages.count)
        var offset = 0
        for file in files {
            lock.lock(); let current = generation; lock.unlock()
            if current != mine { return }
            let slice = passages[offset..<(offset + file.count)]
            if let cached = VectorIndex.read(file.url, count: file.count, dimension: size) {
                raw.append(contentsOf: cached)
            } else {
                let made = slice.map { Embedder.vector($0.text) }
                VectorIndex.write(made, to: file.url, dimension: size)
                raw.append(contentsOf: made)
            }
            offset += file.count
            lock.lock(); embedded = offset; lock.unlock()
        }
        let built = VectorIndex(raw: raw)
        lock.lock()
        if generation == mine { vectors = built }
        lock.unlock()
    }

    /// A few decks to offer as starting questions: the ones with the most to say.
    static func suggest(_ passages: [Passage], _ names: [String: String], count: Int = 4) -> [String] {
        var size: [String: Int] = [:]
        for p in passages { size[p.doc, default: 0] += 1 }
        return size.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .compactMap { names[$0.key] }
            .map { ($0 as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ") }
            .prefix(count).map { $0 }
    }

    private func dropStale(_ id: String) {
        let old = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
        for f in old where f.hasPrefix("\(id)-") { try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(f)) }
    }

    // MARK: Retrieval

    /// The best passages for a question: the keyword ranking and the meaning
    /// ranking fused, one per page.
    private func retrieve(_ question: String, related: [String], allowed: Set<String>?, cluster: Set<String>? = nil,
                          index: PassageIndex, vectors: VectorIndex?, limit: Int) -> [Passage] {
        let words = index.rank(question, related: related, allowed: allowed).prefix(40).map(\.index)
        var lists = [Array(words)]
        // Decks the map ties together get a second say, so the answer can draw on
        // the neighbouring deck and not only the one with the most matching words.
        if let cluster, !cluster.isEmpty {
            lists.append(index.rank(question, related: related, allowed: cluster).prefix(20).map(\.index))
        }
        if let vectors, BrainText.tokens(question).count >= 2 {
            let query = Embedder.vector(question)
            let near = vectors.nearest(query, limit: 40, floor: 0.34) { i in
                (allowed?.contains(index.passages[i].doc) ?? true) && index.proseScore(i) >= 0.25
            }
            lists.append(near.map(\.index))
        }
        var seen = Set<String>()
        var out: [Passage] = []
        for hit in VectorMath.fuse(lists) {
            let p = index.passages[hit.index]
            if seen.insert("\(p.doc)#\(p.page)").inserted { out.append(p) }
            if out.count == limit { break }
        }
        return out
    }

    // MARK: Asking

    /// Answers `question` inside the chat `conversation` (a new one when nil) and
    /// saves the turn. While the index is still being read this returns its
    /// progress instead.
    func ask(_ question: String, conversation: String? = nil) -> [String: Any] {
        lock.lock()
        let index = self.index, vectors = self.vectors, names = self.names, subjects = self.subjects
        lock.unlock()
        guard let index else {
            build()
            var s = status(); s["answer"] = NSNull(); s["sources"] = [Any]()
            return s
        }
        defer { set(stage: "") }
        let started = Date()
        let store = AssistantStore.shared
        let model = Engine.state
        let chat = conversation.flatMap { store.conversation($0) }
        let earlier = (chat?.turns ?? []).filter { $0.kind != "note" }.map { (question: $0.question, answer: $0.answer) }

        var kind = "answer", answer = "", grounded = true, note = model.reason
        var sources: [SourceRef] = []
        var linked: [Linked] = []

        if let fact = Intent.remember(question) {
            store.remember(fact)
            kind = "note"; grounded = false
            answer = "I'll remember that: \(fact)"
        } else if Intent.isGuide(question) {
            let scope = Scope.match(question, subjects: subjects, names: names)
            let made = guide(question, scope: scope, index: index, vectors: vectors, names: names, model: model.ready)
            kind = "guide"; answer = made.text; sources = made.sources
            if answer.isEmpty { kind = "answer" }
        }

        if answer.isEmpty {
            let scope = Scope.match(question, subjects: subjects, names: names)
            set(stage: "Looking through your material")
            var related: [String] = []
            if model.ready, BrainText.tokens(question).count >= 2,
               let reply = try? Engine.answer(instructions: BrainPrompt.related, prompt: question) {
                related = BrainPrompt.terms(reply)
            }
            // A short follow-up ("why?", "and the second one?") leans on the last question.
            if BrainText.tokens(question).count <= 3, let last = earlier.last { related.append(last.question) }
            var hits = retrieve(question, related: related, allowed: scope?.docs, index: index, vectors: vectors, limit: 5)
            // Follow the map: the decks linked to the best matches join the search.
            var top: [String] = []
            for p in hits where !top.contains(p.doc) { top.append(p.doc) }
            let near = top.prefix(2).flatMap { GraphBuilder.shared.neighbours(of: $0) }
                .filter { names[$0.id] != nil && (scope?.docs.contains($0.id) ?? true) }
            if !near.isEmpty {
                let cluster = Set(top.prefix(2)).union(near.map(\.id))
                hits = retrieve(question, related: related, allowed: scope?.docs, cluster: cluster, index: index, vectors: vectors, limit: 5)
            }
            let used = Set(hits.map(\.doc))
            linked = top.first.map { GraphBuilder.shared.neighbours(of: $0, limit: 6) }?
                .filter { !used.contains($0.id) }.compactMap { n in names[n.id].map { Linked(id: n.id, name: $0) } }
                .prefix(3).map { $0 } ?? []
            sources = hits.enumerated().map { i, p in
                SourceRef(n: i + 1, id: p.doc, name: names[p.doc] ?? "Document", page: p.page, text: p.text)
            }
            grounded = !hits.isEmpty
            if model.ready {
                set(stage: "Writing an answer on this Mac")
                if hits.isEmpty && !Intent.recalls(question) {
                    kind = "chat"
                    answer = ((try? Engine.answer(instructions: BrainPrompt.smallTalk, prompt: question)) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    let recalled = Intent.recalls(question) ? recall(question, store: store, except: chat?.id) : []
                    let prompt = AssistantPrompt.build(
                        question: question,
                        notes: sources.map { (title: $0.name, page: $0.page, text: $0.text) },
                        known: store.notes().map(\.text), earlier: earlier, recalled: recalled, budget: Engine.budget)
                    do {
                        let raw = try Engine.answer(instructions: store.instructions, prompt: prompt)
                        answer = BrainPrompt.tidy(raw, notes: sources.count)
                    } catch {
                        note = "The model could not answer: \(error.localizedDescription)"
                    }
                }
            }
        }

        let seconds = max(1, Int(Date().timeIntervalSince(started).rounded()))
        var out: [String: Any] = ["ready": true, "kind": kind, "grounded": grounded, "seconds": seconds,
                                  "sources": sources.map(\.json), "model": model.ready, "modelNote": note,
                                  "answer": answer.isEmpty ? NSNull() : answer as Any,
                                  "linked": linked.map { ["id": $0.id, "name": $0.name] }]
        let turn = Turn(question: question, answer: answer, kind: kind, grounded: grounded, seconds: seconds,
                        sources: sources, at: Date().timeIntervalSince1970, linked: linked.isEmpty ? nil : linked)
        out["conversation"] = store.append(turn, to: chat?.id).id
        return out
    }

    /// Past turns from other chats that match a question about "last time".
    private func recall(_ question: String, store: AssistantStore, except: String?) -> [(question: String, answer: String)] {
        let turns = store.conversations().filter { $0.id != except }.flatMap(\.turns).filter { !$0.answer.isEmpty && $0.kind != "note" }
        guard !turns.isEmpty else { return [] }
        let past = PassageIndex(turns.enumerated().map { Passage(doc: "t\($0.offset)", page: 1, text: $0.element.question + ". " + $0.element.answer) })
        let hits = past.rank(question).prefix(3).map { turns[$0.index] }
        let chosen = hits.isEmpty ? Array(turns.sorted { $0.at > $1.at }.prefix(2)) : Array(hits)
        return chosen.map { (question: $0.question, answer: $0.answer) }
    }

    /// A study guide: for each deck in scope, the model picks the points that
    /// matter from a spread of that deck's pages, and every point keeps its page.
    private func guide(_ question: String, scope: (label: String, docs: Set<String>)?, index: PassageIndex,
                       vectors: VectorIndex?, names: [String: String], model: Bool) -> (text: String, sources: [SourceRef]) {
        guard model else { return ("", []) }
        var docs: [String]
        var label: String
        var strays: [String] = []
        if let scope {
            var size: [String: Int] = [:]
            for p in index.passages where scope.docs.contains(p.doc) { size[p.doc, default: 0] += 1 }
            let core = scope.docs.count > 2
                ? Scope.core(scope.docs, sizes: size) { GraphBuilder.shared.neighbours(of: $0, limit: 8).map(\.id) }
                : scope.docs
            strays = scope.docs.subtracting(core).compactMap { names[$0] }.map { ($0 as NSString).deletingPathExtension }.sorted()
            docs = Array(core); label = scope.label
        } else {
            // No subject or deck named: use the decks the question's words point at.
            let hits = retrieve(question, related: [], allowed: nil, index: index, vectors: vectors, limit: 12)
            var order: [String] = []
            for p in hits where !order.contains(p.doc) { order.append(p.doc) }
            docs = Array(order.prefix(3)); label = ""
        }
        guard !docs.isEmpty else { return ("", []) }
        docs.sort { (names[$0] ?? "").localizedStandardCompare(names[$1] ?? "") == .orderedAscending }
        let limit = 6
        let skipped = max(0, docs.count - limit)
        docs = Array(docs.prefix(limit))

        var byDoc: [String: [Int]] = [:]
        for (i, p) in index.passages.enumerated() where docs.contains(p.doc) { byDoc[p.doc, default: []].append(i) }

        var sections: [String] = []
        var sources: [SourceRef] = []
        for (n, doc) in docs.enumerated() {
            let title = ((names[doc] ?? "Document") as NSString).deletingPathExtension
            set(stage: "Reading \(title) (\(n + 1) of \(docs.count))")
            let picked = Brain.spread(byDoc[doc] ?? [], index: index, budget: 3400)
            guard !picked.isEmpty else { continue }
            let notes = picked.map { (title: title, page: index.passages[$0].page, text: String(index.passages[$0].text.prefix(520))) }
            let prompt = AssistantPrompt.build(question: "List the five most important points.", notes: notes, budget: 3800)
            guard let reply = try? Engine.answer(instructions: AssistantPrompt.guide, prompt: prompt) else { continue }
            var lines: [String] = []
            for point in AssistantPrompt.points(reply, notes: picked.count).prefix(6) {
                var marks: [String] = []
                for local in point.cites.prefix(2) {
                    let passage = index.passages[picked[local - 1]]
                    let existing = sources.first { $0.id == passage.doc && $0.page == passage.page && $0.text == passage.text }
                    let number = existing?.n ?? sources.count + 1
                    if existing == nil {
                        sources.append(SourceRef(n: number, id: passage.doc, name: names[passage.doc] ?? "Document",
                                                 page: passage.page, text: passage.text))
                    }
                    marks.append("[\(number)]")
                }
                lines.append("- \(point.text) \(marks.joined(separator: " "))")
            }
            if !lines.isEmpty { sections.append("## \(title)\n" + lines.joined(separator: "\n")) }
        }
        guard !sections.isEmpty else { return ("", []) }
        var head = label.isEmpty ? "Here is a study guide from the decks closest to that."
                                 : "Here is your \(label) study guide, from \(sections.count) deck\(sections.count == 1 ? "" : "s")."
        if !strays.isEmpty {
            head += " I left out \(strays.joined(separator: ", ")), which the map shows \(strays.count == 1 ? "is" : "are") about something else."
        }
        if skipped > 0 { head += " \(skipped) more deck\(skipped == 1 ? " was" : "s were") left out to keep it short; ask for one by name." }
        return (head + "\n\n" + sections.joined(separator: "\n\n"), sources)
    }

    /// Passages spread evenly through a deck, preferring pages that explain, up
    /// to `budget` characters, so the guide covers the deck and not only its start.
    static func spread(_ candidates: [Int], index: PassageIndex, budget: Int, each: Int = 520) -> [Int] {
        let prose = candidates.filter { index.proseScore($0) >= 0.4 && index.passages[$0].text.count >= 80 }
        let pool = prose.count >= 4 ? prose : candidates.filter { index.passages[$0].text.count >= 40 }
        guard !pool.isEmpty else { return [] }
        let want = max(1, budget / each)
        if pool.count <= want { return pool }
        return (0..<want).map { pool[Int((Double($0) + 0.5) * Double(pool.count) / Double(want))] }
    }
}
