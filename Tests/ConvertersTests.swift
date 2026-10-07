import XCTest
@testable import SlideViewCore

final class ConvertersTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slideview-conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: CSV / TSV

    func testCSVBecomesATableWithAHeaderRow() {
        let html = Converters.tableHTML(URL(fileURLWithPath: "/x/grades.csv"), text: "name,score\nAsha,91\nRavi,78\n")
        XCTAssertTrue(html.contains("<title>grades</title>"))
        XCTAssertTrue(html.contains("<div class=\"fname\">grades.csv</div>"))
        XCTAssertTrue(html.contains("<thead><tr><th>name</th><th>score</th></tr></thead>"))
        XCTAssertTrue(html.contains("<tr><td>Asha</td><td>91</td></tr>\n<tr><td>Ravi</td><td>78</td></tr>"))
    }

    func testQuotedFieldsKeepCommasQuotesAndNewlines() {
        let csv = "who,said\n\"Rao, A\",\"He said \"\"hi\"\"\"\n\"two\nlines\",x\n"
        let html = Converters.tableHTML(URL(fileURLWithPath: "/x/q.csv"), text: csv)
        XCTAssertTrue(html.contains("<tr><td>Rao, A</td><td>He said &quot;hi&quot;</td></tr>"))
        XCTAssertTrue(html.contains("<tr><td>two\nlines</td><td>x</td></tr>"))
    }

    func testWindowsLineEndingsAndBlankLines() {
        // Regression: "\r\n" is a single Character in Swift, so a CSV saved by
        // Excel on Windows used to come out as one enormous row.
        let html = Converters.tableHTML(URL(fileURLWithPath: "/x/w.csv"), text: "a,b\r\n\r\n1,2\r\n3,4\r\n")
        XCTAssertTrue(html.contains("<th>a</th><th>b</th>"))
        XCTAssertEqual(count("<tr><td>", in: html), 2)
        XCTAssertTrue(html.contains("<tr><td>1</td><td>2</td></tr>\n<tr><td>3</td><td>4</td></tr>"))
    }

    func testALineBreakInsideQuotesStaysInTheCell() {
        let html = Converters.tableHTML(URL(fileURLWithPath: "/x/w.csv"), text: "a,b\r\n\"x\r\ny\",2\r\n")
        XCTAssertEqual(count("<tr><td>", in: html), 1)
        XCTAssertTrue(html.contains("<td>x\r\ny</td><td>2</td>"))
    }

    func testTSVSplitsOnTabsNotCommas() {
        let html = Converters.tableHTML(URL(fileURLWithPath: "/x/t.TSV"), text: "city\tnote\nChennai\thot, humid\n")
        XCTAssertTrue(html.contains("<th>city</th><th>note</th>"))
        XCTAssertTrue(html.contains("<tr><td>Chennai</td><td>hot, humid</td></tr>"))
    }

    func testCellsAreEscaped() {
        let html = Converters.tableHTML(URL(fileURLWithPath: "/x/e.csv"), text: "h\n<b>&</b>\n")
        XCTAssertTrue(html.contains("<td>&lt;b&gt;&amp;&lt;/b&gt;</td>"))
    }

    func testAnEmptyFileSaysSo() {
        let html = Converters.tableHTML(URL(fileURLWithPath: "/x/empty.csv"), text: "")
        XCTAssertTrue(html.contains("<p>Empty file.</p>"))
        XCTAssertFalse(html.contains("<table>"))
    }

    func testLongTablesAreCutAt4000Rows() {
        let csv = "n\n" + (1...4002).map(String.init).joined(separator: "\n")
        let html = Converters.tableHTML(URL(fileURLWithPath: "/x/long.csv"), text: csv)
        XCTAssertEqual(count("<tr><td>", in: html), 4000)
        XCTAssertTrue(html.contains("Showing the first 4000 of 4002 rows."))
        XCTAssertFalse(html.contains("<td>4001</td>"))
    }

    // MARK: Plain text and code

    func testTextBecomesANumberedEscapedListing() {
        let html = Converters.textHTML(URL(fileURLWithPath: "/x/a.swift"), text: "let a = 1\r\n\r\nif a < 2 {}")
        XCTAssertTrue(html.contains("<title>a.swift</title>"))
        XCTAssertTrue(html.contains("<span class=\"n\">1</span><span class=\"c\">let a = 1</span>"))
        XCTAssertTrue(html.contains("<span class=\"n\">2</span><span class=\"c\"> </span>"))
        XCTAssertTrue(html.contains("<span class=\"n\">3</span><span class=\"c\">if a &lt; 2 {}</span>"))
        XCTAssertEqual(count("<div class=\"ln\">", in: html), 3)
    }

    func testReadTextReadsUTF8AndDoesNotRefuseOtherEncodings() throws {
        let utf8 = try write("u.txt", "naïve café ✓")
        XCTAssertEqual(Converters.readText(utf8), "naïve café ✓")

        let latin1 = folder.appendingPathComponent("l.txt")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: latin1)      // "café" in Latin-1, not valid UTF-8
        let text = try XCTUnwrap(Converters.readText(latin1))
        XCTAssertTrue(text.hasPrefix("caf"))

        XCTAssertNil(Converters.readText(folder.appendingPathComponent("missing.txt")))
    }

    // MARK: Jupyter notebooks

    func testNotebookKeepsItsStructure() throws {
        let notebook = try write("Lab 1.ipynb", """
        {"cells": [
          {"cell_type": "markdown", "source": ["# Title\\n", "some *text*"]},
          {"cell_type": "code", "execution_count": 3, "source": "print(1 < 2)",
           "outputs": [
             {"output_type": "stream", "name": "stdout", "text": ["True\\n"]},
             {"output_type": "stream", "name": "stderr", "text": "careful"},
             {"output_type": "display_data", "data": {"image/png": "AAAA\\nBBBB", "text/plain": "<Figure>"}},
             {"output_type": "execute_result", "data": {"text/plain": ["<result>"]}}
           ]},
          {"cell_type": "code", "execution_count": null, "source": ["x = 1"], "outputs": []},
          {"cell_type": "raw", "source": "raw <text>"}
        ]}
        """)
        let html = try XCTUnwrap(Converters.notebookHTML(notebook))

        XCTAssertTrue(html.contains("<title>Lab 1</title>"))
        XCTAssertTrue(html.contains("<div class=\"cell\"><h1>Title</h1>\n<p>some <em>text</em></p>\n</div>"))
        XCTAssertTrue(html.contains("<div class=\"prompt\">In [3]</div><pre><code>print(1 &lt; 2)</code></pre>"))
        XCTAssertTrue(html.contains("<pre class=\"out\">True\n</pre>"))
        XCTAssertTrue(html.contains("<pre class=\"err\">careful</pre>"))
        XCTAssertTrue(html.contains("<img src=\"data:image/png;base64,AAAABBBB\">"))
        XCTAssertTrue(html.contains("<pre class=\"out\">&lt;result&gt;</pre>"))
        XCTAssertTrue(html.contains("<div class=\"prompt\">In [ ]</div><pre><code>x = 1</code></pre>"))
        XCTAssertTrue(html.contains("<pre>raw &lt;text&gt;</pre>"))
    }

    func testNotebookErrorsLoseTheirTerminalColours() throws {
        let notebook = try write("err.ipynb", """
        {"cells": [{"cell_type": "code", "execution_count": 1, "source": "1/0", "outputs": [
          {"output_type": "error", "ename": "ZeroDivisionError", "evalue": "division by zero",
           "traceback": ["\\u001b[0;31mZeroDivisionError\\u001b[0m: division by zero"]}]},
          {"cell_type": "code", "execution_count": 2, "source": "boom()", "outputs": [
          {"output_type": "error", "ename": "NameError", "evalue": "boom", "traceback": []}]}]}
        """)
        let html = try XCTUnwrap(Converters.notebookHTML(notebook))
        XCTAssertTrue(html.contains("<pre class=\"err\">ZeroDivisionError: division by zero</pre>"))
        XCTAssertTrue(html.contains("<pre class=\"err\">NameError: boom</pre>"))
        XCTAssertFalse(html.contains("\u{1B}"))
    }

    func testSomethingThatIsNotANotebookIsRefused() throws {
        XCTAssertNil(Converters.notebookHTML(try write("bad.ipynb", "not json")))
        XCTAssertNil(Converters.notebookHTML(try write("nocells.ipynb", "{\"metadata\": {}}")))
        XCTAssertNil(Converters.notebookHTML(folder.appendingPathComponent("missing.ipynb")))
    }

    // MARK: Drawings

    func testDrawingTextIsTheLabelsStillOnTheCanvas() throws {
        let scene = try write("idea.excalidraw", """
        {"type": "excalidraw", "elements": [
          {"type": "rectangle", "id": "a"},
          {"type": "text", "text": "Welcome", "isDeleted": false},
          {"type": "text", "text": "Erased", "isDeleted": true},
          {"type": "arrow"},
          {"type": "text", "text": "Put a star"}
        ]}
        """)
        XCTAssertEqual(Converters.drawingText(scene), "Welcome\nPut a star")
    }

    func testABrokenDrawingHasNoTextRatherThanCrashing() throws {
        XCTAssertEqual(Converters.drawingText(try write("bad.excalidraw", "{")), "")
        XCTAssertEqual(Converters.drawingText(folder.appendingPathComponent("missing.excalidraw")), "")
    }

    // MARK: Which converter handles what

    func testWordAndRichTextAreHandledWithoutLibreOffice() {
        for ext in ["docx", "doc", "odt", "rtf", "html"] {
            XCTAssertTrue(Converters.handlesNatively(ext), ext)
        }
        for ext in ["pptx", "xlsx", "pdf", "md"] {
            XCTAssertFalse(Converters.handlesNatively(ext), ext)
        }
    }
}
