import XCTest
@testable import SlideViewCore

final class AssistantTests: XCTestCase {
    // MARK: Vectors

    func testCentreIsTheAverageOfTheVectorsThatExist() {
        XCTAssertEqual(VectorMath.centre([[1, 3], [], [3, 5]]), [2, 4])
        XCTAssertEqual(VectorMath.centre([[], []]), [])
    }

    func testUnitRemovesTheCentreAndScalesToLengthOne() {
        let v = VectorMath.unit([4, 4], minus: [1, 0])
        XCTAssertEqual(v[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(v[1], 0.8, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.unit([1, 1], minus: [1, 1]), [], "nothing is left once the centre is taken away")
        XCTAssertEqual(VectorMath.unit([], minus: [1, 1]), [])
    }

    func testFusionRewardsBeingHighInBothLists() {
        let fused = VectorMath.fuse([[10, 20, 30], [30, 10, 40]]).map(\.index)
        XCTAssertEqual(fused.first, 10, "first and second beats third and first")
        XCTAssertEqual(Set(fused), [10, 20, 30, 40])
        XCTAssertEqual(fused.last, 40)
        XCTAssertTrue(VectorMath.fuse([[], []]).isEmpty)
    }

    func testNearestFindsTheClosestAndHonoursTheFloorAndFilter() {
        // Three directions around a common centre; the fourth passage has no vector.
        let index = VectorIndex(raw: [[1, 0, 0], [0, 1, 0], [0, 0, 1], []])
        XCTAssertEqual(index.count, 3)
        let hits = index.nearest([0.9, 0.1, 0], limit: 3, floor: 0)
        XCTAssertEqual(hits.first?.index, 0)
        XCTAssertFalse(hits.contains { $0.index == 3 })
        XCTAssertEqual(index.nearest([0.9, 0.1, 0], limit: 3, floor: -1) { $0 != 0 }.first?.index, 1)
        XCTAssertTrue(index.nearest([0.9, 0.1, 0], limit: 3, floor: 0.999).isEmpty)
        XCTAssertTrue(index.nearest([], limit: 3).isEmpty)
    }

    func testVectorsSurviveBeingWrittenAndRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sv-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: url) }
        VectorIndex.write([[1, 2, 3], [], [4, 5, 6]], to: url, dimension: 3)
        XCTAssertEqual(VectorIndex.read(url, count: 3, dimension: 3), [[1, 2, 3], [0, 0, 0], [4, 5, 6]])
        XCTAssertNil(VectorIndex.read(url, count: 4, dimension: 3), "a file of the wrong size is not trusted")
    }

    // MARK: Intent and scope

    func testGuideRequestsAreRecognised() {
        XCTAssertTrue(Intent.isGuide("my FLA study guide"))
        XCTAssertTrue(Intent.isGuide("Give me a summary of unit 2"))
        XCTAssertTrue(Intent.isGuide("key points of flight controls"))
        XCTAssertFalse(Intent.isGuide("what does the rudder control"))
    }

    func testRememberRequestsGiveTheFactToKeep() {
        XCTAssertEqual(Intent.remember("Remember that my FLA exam is on 20 October."), "my FLA exam is on 20 October")
        XCTAssertEqual(Intent.remember("note that I prefer short answers"), "I prefer short answers")
        XCTAssertNil(Intent.remember("remember what I asked about automata?"), "a question about the past is not a note")
        XCTAssertNil(Intent.remember("what is a DFA"))
        XCTAssertNil(Intent.remember("remember "))
    }

    func testQuestionsAboutEarlierChatsAreRecognised() {
        XCTAssertTrue(Intent.recalls("what did I ask you last time?"))
        XCTAssertTrue(Intent.recalls("explain what we discussed about lift"))
        XCTAssertFalse(Intent.recalls("what is lift"))
    }

    private let subjects: [String: Set<String>] = ["FLA": ["f1", "f2"], "Aero": ["a1", "a2"], "all": ["x"], "5th sem": ["s"]]
    private let names = ["f1": "Unit 1_Minu.pdf", "f2": "FLAUNIT-I.pptx", "a1": "4_Flight Controls.pdf",
                         "a2": "3_Parts of an Airplane.pdf", "x": "misc.pdf", "s": "plan.md"]

    func testASubjectNamedInTheQuestionLimitsTheSearchToIt() {
        let scope = Scope.match("my FLA study guide", subjects: subjects, names: names)
        XCTAssertEqual(scope?.label, "FLA")
        XCTAssertEqual(scope?.docs, ["f1", "f2"])
        XCTAssertEqual(Scope.match("summarise aero for me", subjects: subjects, names: names)?.docs, ["a1", "a2"])
    }

    func testADeckNamedInFullWinsOverItsSubject() {
        let scope = Scope.match("key points of flight controls", subjects: subjects, names: names)
        XCTAssertEqual(scope?.docs, ["a1"])
        XCTAssertEqual(scope?.label, "4_Flight Controls")
    }

    func testCommonWordsNeverCountAsASubject() {
        XCTAssertNil(Scope.match("what are all the axes", subjects: subjects, names: names), "a folder called 'all' is not a topic")
        XCTAssertNil(Scope.match("what is a wing", subjects: subjects, names: names))
        XCTAssertNil(Scope.match("the and of", subjects: subjects, names: names))
    }

    // MARK: Prompt

    func testPromptCarriesMemoryThenEarlierTurnsThenNotesThenTheQuestion() {
        let prompt = AssistantPrompt.build(
            question: "and the second?",
            notes: [(title: "Automata", page: 3, text: "A DFA has one move per symbol.")],
            known: ["My exam is on 20 October"],
            earlier: [(question: "What is a DFA?", answer: "A machine with one move per symbol [1].")],
            recalled: [(question: "What is lift?", answer: "An upward force.")])
        let order = ["What you remember about the student", "My exam is on 20 October", "From earlier chats", "What is lift?",
                     "Earlier in this chat", "What is a DFA?", "Notes:", "[1] Automata, page 3", "Question: and the second?"]
        var from = prompt.startIndex
        for piece in order {
            guard let found = prompt.range(of: piece, range: from..<prompt.endIndex) else { return XCTFail("missing or out of order: \(piece)") }
            from = found.upperBound
        }
        XCTAssertTrue(prompt.hasSuffix("Question: and the second?"))
    }

    func testPromptLeavesOutEmptySectionsAndKeepsToItsBudget() {
        let plain = AssistantPrompt.build(question: "q", notes: [(title: "D", page: 1, text: "text")])
        XCTAssertFalse(plain.contains("remember about"))
        XCTAssertFalse(plain.contains("Earlier in this chat"))
        let long = String(repeating: "word ", count: 600)
        let big = AssistantPrompt.build(question: "q", notes: (1...5).map { (title: "D", page: $0, text: long) }, budget: 3000)
        XCTAssertLessThan(big.count, 3400)
    }

    func testGuidePointsKeepOnlyLinesThatCiteARealNote() {
        let reply = """
            1. A DFA has exactly one move for each input symbol [2].
            - An NFA may have several moves or none [2, 3]
            * This line cites a note that does not exist at all [9].
            This line makes a claim but gives no source for it.
            short [1]
            The array a[i] holds the states of the machine being built [1].
            """
        let points = AssistantPrompt.points(reply, notes: 3)
        XCTAssertEqual(points.map(\.text), [
            "A DFA has exactly one move for each input symbol.",
            "An NFA may have several moves or none.",
            "The array a[i] holds the states of the machine being built.",
        ])
        XCTAssertEqual(points.map(\.cites), [[2], [2, 3], [1]])
    }

    func testTheStandardInstructionsSayTheThingsThatMatter() {
        let text = AssistantPrompt.standard
        for must in ["only the numbered notes", "I could not find that in your material.", "diagram", "outside knowledge"] {
            XCTAssertTrue(text.contains(must), "instructions lost: \(must)")
        }
    }

    // MARK: Storage

    private func store() -> (AssistantStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sv-assistant-\(UUID().uuidString)")
        return (AssistantStore(dir), dir)
    }

    private func turn(_ q: String, _ a: String, at: Double = 1) -> Turn {
        Turn(question: q, answer: a, kind: "answer", grounded: true, seconds: 3,
             sources: [SourceRef(n: 1, id: "d", name: "Deck.pdf", page: 4, text: "passage")], at: at)
    }

    func testChatsAreSavedReopenedListedNewestFirstAndDeleted() {
        let (store, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = store.append(turn("What is a DFA?", "One move per symbol.", at: 10), to: nil)
        XCTAssertEqual(first.title, "What is a DFA?")
        let same = store.append(turn("And an NFA?", "Several moves.", at: 20), to: first.id)
        XCTAssertEqual(same.id, first.id)
        XCTAssertEqual(store.conversation(first.id)?.turns.map(\.question), ["What is a DFA?", "And an NFA?"])
        XCTAssertEqual(store.conversation(first.id)?.turns.first?.sources.first?.page, 4)

        let second = store.append(turn("What is lift?", "An upward force.", at: 30), to: nil)
        XCTAssertEqual(store.conversations().map(\.id), [second.id, first.id])
        XCTAssertNotEqual(store.append(turn("x", "y"), to: "no-such-chat").id, "no-such-chat", "an unknown chat starts a new one")

        store.deleteConversation(first.id)
        XCTAssertNil(store.conversation(first.id))
        XCTAssertNil(store.conversation("../../etc/passwd"), "an id is never used as a path")
    }

    func testLongQuestionsMakeShortTitles() {
        XCTAssertEqual(AssistantStore.title("  What is\na DFA?  "), "What is a DFA?")
        XCTAssertEqual(AssistantStore.title(String(repeating: "x", count: 200)).count, 58)
    }

    func testNotesAreKeptNewestFirstWithoutRepeatsAndCanBeForgotten() {
        let (store, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(store.notes().isEmpty)
        store.remember("My exam is on 20 October")
        let keep = store.remember("I prefer short answers")
        store.remember("my exam is on 20 october")
        XCTAssertEqual(store.notes().map(\.text), ["my exam is on 20 october", "I prefer short answers"])
        store.forget(store.notes()[0].id)
        XCTAssertEqual(store.notes().map(\.id), [keep.id])
    }

    func testInstructionsComeFromTheFileAndFallBackWhenItIsEmpty() throws {
        let (store, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(store.instructions, AssistantPrompt.standard, "the file is created with the standard text")
        let file = dir.appendingPathComponent("instructions.md")
        try "Answer in rhyme.".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.instructions, "Answer in rhyme.")
        try "  \n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.instructions, AssistantPrompt.standard)
    }

    // MARK: Guide

    func testSpreadCoversTheWholeDeckAndPrefersPagesThatExplain() {
        let prose = "This page explains one idea in plain sentences. It has enough words to count as prose here."
        var passages = (1...40).map { Passage(doc: "d", page: $0, text: "\(prose) Page \($0).") }
        passages[5] = Passage(doc: "d", page: 6, text: "p q r s 0 1 {q,s} {q} {r} {q,r} {s} {p} E C H F G H 0 1 0 1 1 0 0 1 0 1 1 0 1 0 0 1 1 0")
        let index = PassageIndex(passages)
        let picked = Brain.spread(Array(0..<40), index: index, budget: 2600, each: 520)
        XCTAssertEqual(picked.count, 5)
        XCTAssertEqual(picked, picked.sorted(), "pages stay in order")
        XCTAssertLessThan(picked.first!, 8)
        XCTAssertGreaterThan(picked.last!, 31)
        XCTAssertFalse(picked.contains(5), "the table page is passed over")
        XCTAssertEqual(Brain.spread([0, 1], index: index, budget: 2600), [0, 1], "a short deck is used whole")
        XCTAssertTrue(Brain.spread([], index: index, budget: 2600).isEmpty)
    }

    func testTheMapsNeighboursComeStrongestFirstAndIgnoreWeakLinks() {
        let edges: [[String: Any]] = [
            ["a": "x", "b": "y", "w": 0.9, "kind": "similar"], ["a": "z", "b": "x", "w": 0.5, "kind": "similar"],
            ["a": "x", "b": "q", "w": 0.1, "kind": "similar"], ["a": "y", "b": "z", "w": 1.0, "kind": "link"],
            ["a": "x", "b": "y", "w": 0.3, "kind": "link"],
        ]
        let near = GraphBuilder.neighbours(of: "x", in: edges)
        XCTAssertEqual(near.map(\.id), ["y", "z"], "the weak link to q is left out")
        XCTAssertEqual(near.first?.weight, 0.9, "the stronger of two links between the same pair counts")
        XCTAssertEqual(GraphBuilder.neighbours(of: "x", in: edges, limit: 1).count, 1)
        XCTAssertTrue(GraphBuilder.neighbours(of: "nobody", in: edges).isEmpty)
    }

    func testAFoldersMainGroupLeavesOutTheStraysTheMapDoesNotTie() {
        let links: [String: [String]] = ["u1": ["u2"], "u2": ["u1", "u3"], "u3": ["u2"], "report": ["cover"], "cover": ["report"], "alone": []]
        let sizes = ["u1": 90, "u2": 60, "u3": 40, "report": 30, "cover": 2, "alone": 10]
        let core = Scope.core(["u1", "u2", "u3", "report", "cover", "alone"], sizes: sizes) { links[$0] ?? [] }
        XCTAssertEqual(core, ["u1", "u2", "u3"])
        XCTAssertEqual(Scope.core(["a", "b"], sizes: ["a": 1, "b": 1]) { _ in [] }, ["a", "b"], "no ties at all says nothing")
        XCTAssertEqual(Scope.core([], sizes: [:]) { _ in [] }, [])
    }

    // MARK: Engine

    func testAutomaticPrefersApplesModelAndFallsBackToOllama() {
        XCTAssertEqual(Engine.resolve("auto", appleReady: true, ollama: ["qwen2.5:7b"]), "apple")
        XCTAssertEqual(Engine.resolve("auto", appleReady: false, ollama: ["qwen2.5:7b"]), "ollama:qwen2.5:7b")
        XCTAssertEqual(Engine.resolve("auto", appleReady: false, ollama: []), "apple", "nothing to fall back to")
    }

    func testAChosenOllamaModelIsUsedOnlyWhileItExists() {
        XCTAssertEqual(Engine.resolve("ollama:phi4-mini", appleReady: true, ollama: ["phi4-mini", "qwen2.5:7b"]), "ollama:phi4-mini")
        XCTAssertEqual(Engine.resolve("ollama:gone", appleReady: true, ollama: ["qwen2.5:7b"]), "apple")
        XCTAssertEqual(Engine.resolve("ollama:gone", appleReady: false, ollama: ["qwen2.5:7b"]), "ollama:qwen2.5:7b")
        XCTAssertEqual(Engine.resolve("apple", appleReady: false, ollama: ["qwen2.5:7b"]), "apple", "an explicit choice is kept")
    }

    func testOllamasModelListLeavesOutVectorOnlyModels() {
        let tags = Data(#"{"models":[{"name":"qwen2.5:7b"},{"name":"nomic-embed-text:latest"},{"name":"gemma3:4b"}]}"#.utf8)
        XCTAssertEqual(Ollama.names(inTags: tags), ["gemma3:4b", "qwen2.5:7b"])
        XCTAssertEqual(Ollama.names(inTags: Data("not json".utf8)), [])
    }

    func testOllamasReplyDropsThinkingAloud() {
        let plain = Data(#"{"message":{"role":"assistant","content":"  A DFA has one move per symbol [1].  "}}"#.utf8)
        XCTAssertEqual(Ollama.reply(in: plain), "A DFA has one move per symbol [1].")
        let thinking = Data(#"{"message":{"content":"<think>let me see</think>\nThe rudder controls yaw [2]."}}"#.utf8)
        XCTAssertEqual(Ollama.reply(in: thinking), "The rudder controls yaw [2].")
        XCTAssertNil(Ollama.reply(in: Data("{}".utf8)))
    }

    func testSearchCanBeLimitedToSomeDocuments() {
        let index = PassageIndex([
            Passage(doc: "ml", page: 1, text: "The model looks at many examples and tries to discover a pattern in the data."),
            Passage(doc: "fla", page: 1, text: "A finite automaton is a model of computation with a fixed number of states."),
        ])
        XCTAssertEqual(index.search("model").count, 2)
        XCTAssertEqual(index.search("model", allowed: ["fla"]).map(\.passage.doc), ["fla"])
        XCTAssertTrue(index.search("model", allowed: []).isEmpty)
    }
}
