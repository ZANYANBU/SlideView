import Foundation

/// What makes Ask an assistant and not only a search: it keeps your chats, keeps
/// the things you ask it to remember, works out what kind of request it was given,
/// and carries its own instructions, which you can edit.
///
/// Everything is plain files under Application Support/SlideView/assistant.

struct SourceRef: Codable, Equatable {
    var n: Int
    var id: String
    var name: String
    var page: Int
    var text: String

    var json: [String: Any] { ["n": n, "id": id, "name": name, "page": page, "text": text] }
}

struct Turn: Codable, Equatable {
    var question: String
    var answer: String
    var kind: String            // "answer", "guide", "note" or "chat"
    var grounded: Bool
    var seconds: Int
    var sources: [SourceRef]
    var at: Double
    /// Decks the map links to the ones this answer drew on.
    var linked: [Linked]? = nil

    var json: [String: Any] {
        ["question": question, "answer": answer, "kind": kind, "grounded": grounded,
         "seconds": seconds, "sources": sources.map(\.json), "at": at,
         "linked": (linked ?? []).map { ["id": $0.id, "name": $0.name] }]
    }
}

struct Linked: Codable, Equatable {
    var id: String
    var name: String
}

struct Conversation: Codable, Equatable {
    var id: String
    var title: String
    var updated: Double
    var turns: [Turn]
}

struct Note: Codable, Equatable {
    var id: String
    var text: String
    var created: Double
}

// MARK: - What was asked for

enum Intent {
    /// A request for an overview of a subject or deck, not for one fact.
    static func isGuide(_ question: String) -> Bool {
        let q = " " + question.lowercased() + " "
        return ["study guide", "summary", "summarise", "summarize", "overview", "key points", "main points",
                "revision", "revise", "cheat sheet", "cheatsheet", "important topics", "notes on", "notes for",
                "what is covered", "what's covered", "outline"].contains { q.contains($0) }
    }

    /// The thing to remember, when the message asks for something to be remembered.
    static func remember(_ question: String) -> String? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for lead in ["remember that ", "remember: ", "remember this: ", "please remember that ", "please remember ",
                     "note that ", "don't forget that ", "dont forget that ", "don't forget ", "remember "] {
            if lower.hasPrefix(lead) {
                let rest = trimmed.dropFirst(lead.count).trimmingCharacters(in: CharacterSet(charactersIn: " .:").union(.whitespaces))
                // "remember what I asked" is a question about the past, not a note.
                let asksBack = ["what", "when", "how", "why", "which", "who", "if ", "the last", "our "].contains { rest.lowercased().hasPrefix($0) }
                return rest.count >= 3 && !asksBack ? rest : nil
            }
        }
        return nil
    }

    /// A question about earlier chats, which needs them looked up.
    static func recalls(_ question: String) -> Bool {
        let q = " " + question.lowercased() + " "
        return [" did i ask", " i asked", " we talked", " we discussed", " last time", " earlier ", " previously",
                " before ", " yesterday", " you said", " you told", " remember what", " remember when",
                " our last", " our previous"].contains { q.contains($0) }
    }
}

enum Scope {
    /// The decks a question is about, when it names a subject folder or a deck.
    /// Returns nil when it names neither, which means "the whole library".
    ///
    /// - Parameters:
    ///   - subjects: subject name to the ids of its documents.
    ///   - names: document id to file name.
    static func match(_ question: String, subjects: [String: Set<String>], names: [String: String]) -> (label: String, docs: Set<String>)? {
        let asked = Set(BrainText.tokens(question))
        guard !asked.isEmpty else { return nil }

        // A deck named in full wins over its subject.
        var best: (label: String, docs: Set<String>, size: Int)?
        for (id, name) in names {
            let title = Set(BrainText.tokens((name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")))
            guard title.count >= 2, title.isSubset(of: asked), title.count > (best?.size ?? 0) else { continue }
            best = ((name as NSString).deletingPathExtension, [id], title.count)
        }
        if let best { return (best.label, best.docs) }

        for (subject, docs) in subjects.sorted(by: { $0.key < $1.key }) {
            let words = Set(BrainText.tokens(subject.replacingOccurrences(of: "/", with: " ")))
            guard !words.isEmpty, words.isSubset(of: asked) else { continue }
            if words.count > (best?.size ?? 0) { best = (subject, docs, words.count) }
        }
        return best.map { ($0.label, $0.docs) }
    }
}

extension Scope {
    /// The decks of a folder that belong together, going by the map. A subject
    /// folder often holds a stray report or two; a guide to the subject should be
    /// about the largest group of decks the map ties to one another.
    ///
    /// - Parameters:
    ///   - sizes: how much each deck has to say, used to pick the main group.
    ///   - links: for a deck, the decks the map links it to.
    static func core(_ docs: Set<String>, sizes: [String: Int], links: (String) -> [String]) -> Set<String> {
        var left = docs
        var best: Set<String> = []
        var bestSize = -1
        while let start = left.sorted().first {
            var group: Set<String> = [start]
            var queue = [start]
            left.remove(start)
            while let next = queue.popLast() {
                for other in links(next) where left.contains(other) {
                    left.remove(other); group.insert(other); queue.append(other)
                }
            }
            let size = group.reduce(0) { $0 + (sizes[$1] ?? 0) }
            if size > bestSize { best = group; bestSize = size }
        }
        // A lone deck means the map found no ties at all, which says nothing.
        return best.count >= 2 ? best : docs
    }
}

// MARK: - Instructions

enum AssistantPrompt {
    /// The assistant's standing instructions. A copy is written to
    /// `instructions.md` on first run; edit that file to change how it behaves.
    static let standard = """
        You are the study assistant built into SlideView on the student's own Mac. Talk to them \
        directly as "you", the way a capable personal assistant would: warm, brief and exact.

        How to answer:
        - Use only the numbered notes you are given. They come from the student's own decks and PDFs.
        - Start with the answer in one sentence. Then, if it helps, add three to six short bullet points.
        - After each fact, cite the note it came from, like [2]. The only valid citations are the \
        note numbers shown in square brackets at the start of each note. Numbers inside a note's \
        text are part of the slide, not citations.
        - Some notes are labels lifted off a diagram in no particular order. Never guess which \
        label goes with which; say the slide is a diagram and name the page instead.
        - If the notes do not clearly hold the answer, reply only: "I could not find that in your material."
        - Use the earlier turns and what you remember about the student to work out what "it", \
        "that" or "the second point" refers to.
        - Never invent facts, formulas or page numbers, and never answer from outside knowledge.
        """

    /// For one deck of a study guide.
    static let guide = """
        You are helping a student revise. The numbered notes below are from one of their lecture \
        decks. Write the five most important things they must know from this deck for an exam. \
        Put each on its own line, as one clear sentence in your own words, and end the line with \
        the note it came from, like [3]. Use only the notes. Skip tables, examples of single \
        problems and anything you cannot state clearly. Write nothing before or after the five lines.
        """

    /// The notes, what is remembered and the recent turns as one prompt.
    static func build(question: String,
                      notes: [(title: String, page: Int, text: String)],
                      known: [String] = [],
                      earlier: [(question: String, answer: String)] = [],
                      recalled: [(question: String, answer: String)] = [],
                      budget: Int = 4200) -> String {
        var out = ""
        if !known.isEmpty {
            out += "What you remember about the student:\n" + known.prefix(10).map { "- " + String($0.prefix(160)) }.joined(separator: "\n") + "\n\n"
        }
        if !recalled.isEmpty {
            out += "From earlier chats:\n" + recalled.prefix(3).map {
                "- They asked: \(String($0.question.prefix(120)))\n  You answered: \(String($0.answer.prefix(260)))"
            }.joined(separator: "\n") + "\n\n"
        }
        if !earlier.isEmpty {
            out += "Earlier in this chat:\n" + earlier.suffix(2).map {
                "- They asked: \(String($0.question.prefix(120)))\n  You answered: \(String($0.answer.prefix(280)))"
            }.joined(separator: "\n") + "\n\n"
        }
        out += "Notes:\n"
        var used = 0
        let room = max(1200, budget - out.count)
        for (i, n) in notes.enumerated() {
            let left = room - used
            if left < 200 { break }
            let text = String(n.text.prefix(left))
            out += "\n[\(i + 1)] \(n.title), page \(n.page)\n\(text)\n"
            used += text.count
        }
        return out + "\nQuestion: \(question.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// The model's guide lines for one deck as clean points, each with the local
    /// note numbers it cited. Lines without a valid citation are dropped: a point
    /// that cannot be traced to a page has no place in a study guide.
    static func points(_ reply: String, notes: Int) -> [(text: String, cites: [Int])] {
        var out: [(String, [Int])] = []
        for raw in reply.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "-*•0123456789.) ".contains(first) { line.removeFirst() }
            var cites: [Int] = []
            var text = ""
            var rest = Substring(line)
            while let open = rest.firstIndex(of: "[") {
                text += rest[..<open]
                let after = rest[rest.index(after: open)...]
                guard let close = after.firstIndex(of: "]") else { text += "["; rest = after; continue }
                let inside = after[..<close]
                let numbers = inside.split(whereSeparator: { ", ".contains($0) }).compactMap { Int($0) }
                if !numbers.isEmpty, numbers.count == inside.split(whereSeparator: { ", ".contains($0) }).count {
                    cites += numbers.filter { $0 >= 1 && $0 <= notes }
                } else {
                    text += "[" + inside + "]"
                }
                rest = after[after.index(after: close)...]
            }
            text += rest
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:")) + "."
            let unique = cites.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
            if text.count >= 24, !unique.isEmpty { out.append((text, unique)) }
        }
        return out
    }
}

// MARK: - Storage

final class AssistantStore {
    static let shared = AssistantStore(Library.shared.support.appendingPathComponent("assistant", isDirectory: true))

    private let dir: URL
    private let chats: URL
    private let lock = NSLock()

    init(_ dir: URL) {
        self.dir = dir
        chats = dir.appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("instructions.md")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? Data(AssistantPrompt.standard.utf8).write(to: file, options: .atomic)
        }
    }

    /// The instructions in force: the file if it has any text, otherwise the built-in ones.
    var instructions: String {
        let text = (try? String(contentsOf: dir.appendingPathComponent("instructions.md"), encoding: .utf8)) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AssistantPrompt.standard : text
    }

    // MARK: Chats

    private func file(_ id: String) -> URL { chats.appendingPathComponent("\(id).json") }
    private static func safe(_ id: String) -> Bool { !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }

    func conversation(_ id: String) -> Conversation? {
        guard Self.safe(id), let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder().decode(Conversation.self, from: data)
    }

    /// Every chat, newest first.
    func conversations() -> [Conversation] {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Conversation.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    /// Adds a turn to a chat, starting a new one when `id` is nil or unknown.
    @discardableResult
    func append(_ turn: Turn, to id: String?) -> Conversation {
        lock.lock(); defer { lock.unlock() }
        var chat = id.flatMap { conversation($0) }
            ?? Conversation(id: UUID().uuidString, title: Self.title(turn.question), updated: turn.at, turns: [])
        chat.turns.append(turn)
        chat.updated = turn.at
        if let data = try? JSONEncoder().encode(chat) { try? data.write(to: file(chat.id), options: .atomic) }
        return chat
    }

    func deleteConversation(_ id: String) {
        guard Self.safe(id) else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: file(id))
    }

    static func title(_ question: String) -> String {
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return clean.count > 60 ? String(clean.prefix(57)) + "…" : clean
    }

    // MARK: Notes

    private var notesFile: URL { dir.appendingPathComponent("notes.json") }

    func notes() -> [Note] {
        guard let data = try? Data(contentsOf: notesFile) else { return [] }
        return (try? JSONDecoder().decode([Note].self, from: data)) ?? []
    }

    @discardableResult
    func remember(_ text: String) -> Note {
        lock.lock(); defer { lock.unlock() }
        let note = Note(id: UUID().uuidString, text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)),
                        created: Date().timeIntervalSince1970)
        var all = notes()
        all.removeAll { $0.text.lowercased() == note.text.lowercased() }
        all.insert(note, at: 0)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: notesFile, options: .atomic) }
        return note
    }

    func forget(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        let all = notes().filter { $0.id != id }
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: notesFile, options: .atomic) }
    }
}
