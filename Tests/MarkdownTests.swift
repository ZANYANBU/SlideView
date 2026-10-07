import XCTest
@testable import SlideViewCore

final class MarkdownTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory

    private func render(_ source: String) -> String {
        Markdown.bodyHTML(source, baseDir: dir)
    }

    // MARK: Blocks

    func testHeadings() {
        XCTAssertEqual(render("# Title"), "<h1>Title</h1>\n")
        XCTAssertEqual(render("### Deep *one*"), "<h3>Deep <em>one</em></h3>\n")
    }

    func testAHashWithoutASpaceIsNotAHeading() {
        XCTAssertEqual(render("#hashtag"), "<p>#hashtag</p>\n")
        XCTAssertEqual(render("####### seven"), "<p>####### seven</p>\n")
    }

    func testLinesOfAParagraphAreJoined() {
        XCTAssertEqual(render("Hello\nworld\n\nNext"), "<p>Hello world</p>\n<p>Next</p>\n")
    }

    func testWindowsLineEndings() {
        XCTAssertEqual(render("# A\r\ntext"), "<h1>A</h1>\n<p>text</p>\n")
    }

    func testFencedCodeIsEscapedAndNotFormatted() {
        XCTAssertEqual(render("```swift\nlet a = 1 < 2\n**not bold**\n```"),
                       "<pre><code>let a = 1 &lt; 2\n**not bold**</code></pre>\n")
        XCTAssertEqual(render("~~~\nx\n~~~"), "<pre><code>x</code></pre>\n")
    }

    func testAnUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(render("```\nstill code"), "<pre><code>still code</code></pre>\n")
    }

    func testHorizontalRule() {
        XCTAssertEqual(render("above\n\n---\n\nbelow"), "<p>above</p>\n<hr>\n<p>below</p>\n")
        XCTAssertEqual(render("***"), "<hr>\n")
    }

    func testUnorderedAndOrderedLists() {
        XCTAssertEqual(render("- one\n* two\n+ three"),
                       "<ul>\n<li>one</li>\n<li>two</li>\n<li>three</li>\n</ul>\n")
        XCTAssertEqual(render("1. first\n2) second"), "<ol>\n<li>first</li>\n<li>second</li>\n</ol>\n")
    }

    func testAListChangesKindWhenTheMarkerDoes() {
        XCTAssertEqual(render("- a\n1. b"), "<ul>\n<li>a</li>\n</ul>\n<ol>\n<li>b</li>\n</ol>\n")
    }

    func testTaskLists() {
        XCTAssertEqual(render("- [ ] todo\n- [x] done\n- [X] also done"),
                       "<ul>\n<li class=\"task\">☐ todo</li>\n<li class=\"task\">☑ done</li>\n"
                       + "<li class=\"task\">☑ also done</li>\n</ul>\n")
    }

    func testTable() {
        XCTAssertEqual(render("| Gate | Effect |\n|---|:--:|\n| X | flip |\n| H | **mix** |"),
                       "<table><thead><tr><th>Gate</th><th>Effect</th></tr></thead><tbody>\n"
                       + "<tr><td>X</td><td>flip</td></tr>\n"
                       + "<tr><td>H</td><td><strong>mix</strong></td></tr>\n"
                       + "</tbody></table>\n")
    }

    func testAPipeWithoutARuleLineIsJustText() {
        XCTAssertEqual(render("a | b"), "<p>a | b</p>\n")
    }

    func testBlockquoteIsRenderedAsItsOwnDocument() {
        XCTAssertEqual(render("> quoted\n> more\n\nafter"),
                       "<blockquote>\n<p>quoted more</p>\n</blockquote>\n<p>after</p>\n")
        XCTAssertEqual(render("> # Heading\n> - item"),
                       "<blockquote>\n<h1>Heading</h1>\n<ul>\n<li>item</li>\n</ul>\n</blockquote>\n")
    }

    // MARK: Inline

    func testEmphasis() {
        XCTAssertEqual(render("**bold** __also__ *it* ~~gone~~"),
                       "<p><strong>bold</strong> <strong>also</strong> <em>it</em> <s>gone</s></p>\n")
    }

    func testAsterisksInsideWordsAreLeftAlone() {
        XCTAssertEqual(render("2*3*4 and a*b"), "<p>2*3*4 and a*b</p>\n")
    }

    func testCodeSpansAreNotFormatted() {
        XCTAssertEqual(render("use `**x**` and `a < b`"),
                       "<p>use <code>**x**</code> and <code>a &lt; b</code></p>\n")
    }

    func testLinks() {
        XCTAssertEqual(render("[site](https://example.com/a?b=1)"),
                       "<p><a href=\"https://example.com/a?b=1\">site</a></p>\n")
    }

    func testHTMLInTheSourceIsEscaped() {
        XCTAssertEqual(render("<script>alert(\"x\")</script> & more"),
                       "<p>&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; more</p>\n")
        XCTAssertEqual(Markdown.escape("<a href=\"x\">&</a>"), "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;")
    }

    // MARK: Images

    func testRemoteImagesKeepTheirAddress() {
        XCTAssertEqual(render("![logo](https://example.com/a.png)"),
                       "<p><img alt=\"logo\" src=\"https://example.com/a.png\"></p>\n")
    }

    func testLocalImagesAreInlinedSoThePrintPassNeedsNoFileAccess() throws {
        let folder = dir.appendingPathComponent("slideview-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        try bytes.write(to: folder.appendingPathComponent("pic.png"))

        XCTAssertEqual(Markdown.bodyHTML("![p](pic.png)", baseDir: folder),
                       "<p><img alt=\"p\" src=\"data:image/png;base64,\(bytes.base64EncodedString())\"></p>\n")
        XCTAssertEqual(Markdown.bodyHTML("![p](missing.png)", baseDir: folder),
                       "<p><img alt=\"p\" src=\"missing.png\"></p>\n")
    }

    // MARK: Whole page

    func testPageWrapsTheBodyAndEscapesTheTitle() {
        let page = Markdown.html("# Hi", title: "Notes & <drafts>", baseDir: dir)
        XCTAssertTrue(page.hasPrefix("<!doctype html>"))
        XCTAssertTrue(page.contains("<title>Notes &amp; &lt;drafts&gt;</title>"))
        XCTAssertTrue(page.contains("<h1>Hi</h1>"))
        XCTAssertTrue(page.hasSuffix("</body></html>"))
    }
}
