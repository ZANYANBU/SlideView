import XCTest
@testable import SlideViewCore

final class BrainTests: XCTestCase {
    func testTokensDropCommonWordsAndStem() {
        XCTAssertEqual(BrainText.tokens("What are the transitions of a DFA?"), ["transition", "dfa"])
        XCTAssertEqual(BrainText.tokens("Sorting, sorted and sorts"), ["sort", "sort", "sort"])
        XCTAssertEqual(BrainText.tokens("class glass"), ["class", "glass"], "a double s is not a plural")
        XCTAssertEqual(BrainText.tokens("C++ and x86"), ["x86"], "single letters are dropped, numbers kept")
    }

    func testShortPageIsOnePassage() {
        XCTAssertEqual(BrainText.split("  A short slide.  "), ["A short slide."])
        XCTAssertEqual(BrainText.split("   \n "), [])
    }

    func testLongPageIsCutAtParagraphsWithinTheLimit() {
        let paragraph = String(repeating: "Automata theory studies abstract machines. ", count: 12)
        let page = [paragraph, paragraph, paragraph].joined(separator: "\n\n")
        let pieces = BrainText.split(page, limit: 600)
        XCTAssertGreaterThan(pieces.count, 2)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 600 }, "no passage is longer than the limit")
        XCTAssertEqual(pieces.joined().filter { !$0.isWhitespace }.count, page.filter { !$0.isWhitespace }.count,
                       "nothing is lost in the cutting")
    }

    func testAnUnbrokenRunIsStillCut() {
        let pieces = BrainText.split(String(repeating: "x", count: 2500), limit: 900)
        XCTAssertEqual(pieces.map(\.count), [900, 900, 700])
    }

    private let library = [
        Passage(doc: "automata", page: 3, text: "A DFA has exactly one transition for each symbol from every state."),
        Passage(doc: "automata", page: 4, text: "An NFA may have several transitions for a symbol, or none. Epsilon moves need no input."),
        Passage(doc: "networks", page: 9, text: "TCP gives a reliable ordered byte stream. It uses a three-way handshake to open a connection."),
        Passage(doc: "networks", page: 9, text: "The handshake is SYN, SYN-ACK, ACK."),
        Passage(doc: "os", page: 2, text: "A process is a program in execution. The scheduler decides which process runs next."),
    ]

    func testSearchRanksTheMatchingPageFirst() {
        let index = PassageIndex(library)
        XCTAssertEqual(index.search("how does TCP open a connection").first?.passage.doc, "networks")
        XCTAssertEqual(index.search("what does the scheduler do").first?.passage.doc, "os")
        let dfa = index.search("transitions in a DFA")
        XCTAssertEqual(dfa.first?.passage.page, 3)
        XCTAssertEqual(dfa.map(\.passage.doc), ["automata", "automata"], "the NFA page also mentions transitions")
    }

    func testSearchGivesOnePassagePerPage() {
        let hits = PassageIndex(library).search("handshake")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.passage.page, 9)
    }

    func testSearchWithNoMatchIsEmpty() {
        XCTAssertTrue(PassageIndex(library).search("photosynthesis").isEmpty)
        XCTAssertTrue(PassageIndex(library).search("the and of").isEmpty)
        XCTAssertTrue(PassageIndex([]).search("anything").isEmpty)
    }

    func testSearchRespectsTheLimit() {
        let many = (1...20).map { Passage(doc: "d\($0)", page: 1, text: "kernel memory paging \($0)") }
        XCTAssertEqual(PassageIndex(many).search("kernel paging", limit: 5).count, 5)
    }

    func testPromptNumbersTheNotesAndEndsWithTheQuestion() {
        let prompt = BrainPrompt.build(question: "  What is a DFA?  ", notes: [
            (title: "Automata", page: 3, text: "A DFA has one transition per symbol."),
            (title: "Automata", page: 4, text: "An NFA may have several."),
        ])
        XCTAssertTrue(prompt.contains("[1] Automata, page 3\nA DFA has one transition per symbol."))
        XCTAssertTrue(prompt.contains("[2] Automata, page 4"))
        XCTAssertTrue(prompt.hasSuffix("Question: What is a DFA?"))
    }

    func testPromptStaysWithinItsBudget() {
        let long = String(repeating: "word ", count: 400)
        let notes = (1...5).map { (title: "Deck", page: $0, text: long) }
        let prompt = BrainPrompt.build(question: "q", notes: notes, budget: 3000)
        XCTAssertLessThan(prompt.count, 3400)
        XCTAssertTrue(prompt.contains("[1] Deck, page 1"))
        XCTAssertFalse(prompt.contains("[3] Deck"), "notes past the budget are left out")
    }

    func testTidyDropsCitationsThatPointAtNoNote() {
        XCTAssertEqual(BrainPrompt.tidy("A DFA is deterministic [1]. NFAs differ [9].", notes: 5),
                       "A DFA is deterministic [1]. NFAs differ.")
        XCTAssertEqual(BrainPrompt.tidy("Both hold [2], [10].", notes: 3), "Both hold [2].")
        XCTAssertEqual(BrainPrompt.tidy("An array a[i] and a set [x, y] stay [3]", notes: 3),
                       "An array a[i] and a set [x, y] stay [3]")
        XCTAssertEqual(BrainPrompt.tidy("  no citations here  ", notes: 2), "no citations here")
        XCTAssertEqual(BrainPrompt.tidy("unclosed [ bracket [1]", notes: 1), "unclosed [ bracket [1]")
        XCTAssertEqual(BrainPrompt.tidy("I could not find that in your material. [1]", notes: 5), BrainPrompt.notFound)
    }

    func testADeckIsFoundByItsName() {
        let passages = [Passage(doc: "a", page: 1, text: "Lift and drag on a wing."),
                        Passage(doc: "b", page: 1, text: "Sorting and searching.")]
        let index = PassageIndex(passages, titles: ["a": "Flight Controls.pdf", "b": "Algorithms.pdf"])
        XCTAssertEqual(index.search("flight controls").first?.passage.doc, "a")
        XCTAssertTrue(PassageIndex(passages).search("flight controls").isEmpty)
    }

    func testSuggestionsAreTheBiggestDecksWithTidyNames() {
        let passages = [Passage(doc: "a", page: 1, text: "x"), Passage(doc: "b", page: 1, text: "x"),
                        Passage(doc: "b", page: 2, text: "x"), Passage(doc: "c", page: 1, text: "x")]
        let names = ["a": "Unit_1 Automata.pdf", "b": "4_Flight Controls.pptx", "c": "Notes.md"]
        XCTAssertEqual(Brain.suggest(passages, names, count: 2), ["4 Flight Controls", "Unit 1 Automata"])
    }

    func testProseScoresSentencesAboveTablesAndLabels() {
        let explain = BrainText.prose("A DFA has exactly one transition for each symbol. An NFA may have several, or none at all.")
        let table = BrainText.prose("state 0 1 p {q,s} {q} q {r} {q,r} r {s} {p} *s {p} E C H F G H")
        let labels = BrainText.prose("AXES OF AN AEROPLANE Lateral axis y Pitch Roll Yaw x Longitudinal axis z Vertical axis")
        XCTAssertGreaterThan(explain, 0.75)
        XCTAssertLessThan(table, 0.3)
        XCTAssertGreaterThan(explain, labels + 0.2, "labels off a diagram have no sentences")
        XCTAssertEqual(BrainText.prose("too short"), 0.3)
    }

    func testThePageThatExplainsBeatsThePageThatTabulates() {
        let index = PassageIndex([
            Passage(doc: "t", page: 1, text: "NFA DFA NFA to DFA state 0 1 p {q,s} {q} q {r} {q,r} r {s} {p} DFA NFA"),
            Passage(doc: "e", page: 1, text: "A DFA has exactly one transition for each symbol. An NFA may have several, or none at all."),
        ])
        XCTAssertEqual(index.search("difference between DFA and NFA").first?.passage.doc, "e")
    }

    func testRelatedWordsFindAPageTheQuestionsWordsMiss() {
        let index = PassageIndex([
            Passage(doc: "a", page: 1, text: "A deterministic finite automaton reads one symbol at a time and never has a choice of move."),
            Passage(doc: "b", page: 1, text: "The rudder controls yaw about the vertical axis of the aircraft in flight."),
        ])
        XCTAssertTrue(index.search("what is a DFA").isEmpty, "the slide never says DFA")
        XCTAssertEqual(index.search("what is a DFA", related: ["deterministic finite automaton"]).first?.passage.doc, "a")
    }

    func testTheQuestionsOwnWordsOutweighRelatedOnes() {
        let index = PassageIndex([
            Passage(doc: "own", page: 1, text: "The handshake opens every connection before any data is sent between hosts."),
            Passage(doc: "rel", page: 1, text: "A greeting is polite before any conversation is started between people."),
        ])
        XCTAssertEqual(index.search("handshake", related: ["greeting"]).first?.passage.doc, "own")
    }

    func testTermsCleansTheModelsList() {
        XCTAssertEqual(BrainPrompt.terms("deterministic finite automaton, NFA; state machine\n- transition function."),
                       ["deterministic finite automaton", "NFA", "state machine", "transition function"])
        XCTAssertEqual(BrainPrompt.terms("a, , ok").count, 1, "one-letter and empty items are dropped")
        XCTAssertEqual(BrainPrompt.terms((1...20).map { "term\($0)" }.joined(separator: ",")).count, 8)
    }

    func testModelStateAlwaysExplainsItself() {
        let state = OnDeviceModel.state
        XCTAssertEqual(state.ready, state.reason.isEmpty, "a reason is given exactly when the model is not ready")
    }
}
