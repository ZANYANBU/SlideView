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

    func testModelStateAlwaysExplainsItself() {
        let state = OnDeviceModel.state
        XCTAssertEqual(state.ready, state.reason.isEmpty, "a reason is given exactly when the model is not ready")
    }
}
