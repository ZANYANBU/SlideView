import XCTest
@testable import SlideViewCore

/// The map's blue "written link" edges come from these references.
final class GraphTests: XCTestCase {
    func testWikilinksAreFound() {
        XCTAssertEqual(GraphBuilder.references(in: "See [[Unit 1]] and [[ Quantum Gates ]]."),
                       ["Unit 1", "Quantum Gates"])
    }

    func testAliasesAndHeadingAnchorsAreDropped() {
        XCTAssertEqual(GraphBuilder.references(in: "[[Unit 2|the second unit]] then [[Deck#Slide 3]]"),
                       ["Unit 2", "Deck"])
    }

    func testFoldersAndExtensionsAreStripped() {
        XCTAssertEqual(GraphBuilder.references(in: "[[CN/Unit 3.pptx]] and [revision](../Maths/Revision.md)"),
                       ["Unit 3", "Revision"])
    }

    func testWebLinksAndInPageAnchorsAreNotReferences() {
        XCTAssertEqual(GraphBuilder.references(in: "[site](https://example.com/a.pdf) [top](#top) [[https://x.y]]"),
                       [])
    }

    func testTextWithoutLinksHasNoReferences() {
        XCTAssertEqual(GraphBuilder.references(in: "plain notes with [brackets] and (parens)"), [])
    }
}
