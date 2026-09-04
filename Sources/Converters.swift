import AppKit
import PDFKit

/// Everything SlideView can turn into a PDF that is not a slide deck.
enum Converters {

    // MARK: Images — straight to a one-page PDF, no LibreOffice needed.

    static func imagePDF(_ url: URL, to out: URL) -> Bool {
        guard let img = NSImage(contentsOf: url), img.size.width > 0 else { return false }
        let doc = PDFDocument()
        guard let page = PDFPage(image: img) else { return false }
        doc.insert(page, at: 0)
        return doc.write(to: out)
    }

    // MARK: Word / RTF / ODT / HTML — natively, no LibreOffice.

    private static let attributedTypes: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument,
        "rtf": .rtf, "rtfd": .rtfd, "html": .html, "htm": .html, "webarchive": .webArchive]

    static func handlesNatively(_ ext: String) -> Bool { attributedTypes[ext] != nil }

    /// Drawn through NSLayoutManager rather than round-tripping to HTML, so
    /// embedded images (which are NSTextAttachments) survive. Roughly 30x
    /// faster than shelling out to LibreOffice, and needs nothing installed.
    static func attributedPDF(_ url: URL, to out: URL) -> Bool {
        guard let type = attributedTypes[url.pathExtension.lowercased()],
              let text = try? NSAttributedString(url: url,
                                                 options: [.documentType: type],
                                                 documentAttributes: nil),
              text.length > 0 else { return false }

        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let inset: CGFloat = 56
        let textSize = CGSize(width: page.width - inset * 2, height: page.height - inset * 2)

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        let data = NSMutableData()
        var box = page
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return false }

        var glyph = 0, pages = 0
        while glyph < layout.numberOfGlyphs && pages < 800 {
            let container = NSTextContainer(size: textSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let range = layout.glyphRange(for: container)
            if range.length == 0 { break }

            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: inset, y: page.height - inset)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            layout.drawBackground(forGlyphRange: range, at: .zero)
            layout.drawGlyphs(forGlyphRange: range, at: .zero)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()

            glyph = NSMaxRange(range)
            pages += 1
        }
        ctx.closePDF()
        return pages > 0 && data.write(to: out, atomically: true)
    }

    // MARK: CSV / TSV — parsed here rather than handed to a spreadsheet engine.

    static func tableHTML(_ url: URL, text: String) -> String {
        let sep: Character = url.pathExtension.lowercased() == "tsv" ? "\t" : ","
        let rows = parseDelimited(text, sep: sep)
        var body = "<div class=\"fname\">\(Markdown.escape(url.lastPathComponent))</div>\n"
        guard !rows.isEmpty else { return Markdown.page(title: url.lastPathComponent, body: body + "<p>Empty file.</p>") }

        body += "<table><thead><tr>"
        body += rows[0].map { "<th>\(Markdown.escape($0))</th>" }.joined()
        body += "</tr></thead><tbody>\n"
        for r in rows.dropFirst().prefix(4000) {
            body += "<tr>" + r.map { "<td>\(Markdown.escape($0))</td>" }.joined() + "</tr>\n"
        }
        body += "</tbody></table>\n"
        if rows.count > 4001 {
            body += "<p><em>Showing the first 4000 of \(rows.count - 1) rows.</em></p>"
        }
        return Markdown.page(title: url.deletingPathExtension().lastPathComponent, body: body)
    }

    /// Minimal RFC-4180 reader: quoted fields, doubled quotes, embedded newlines.
    private static func parseDelimited(_ text: String, sep: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if quoted {
                if c == "\"" {
                    let n = text.index(after: i)
                    if n < text.endIndex, text[n] == "\"" { field.append("\""); i = n }
                    else { quoted = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": quoted = true
                case sep: row.append(field); field = ""
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                case "\r": break
                default: field.append(c)
                }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    // MARK: Plain text and source code — a numbered, wrapping listing.

    static func textHTML(_ url: URL, text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var body = "<div class=\"fname\">\(Markdown.escape(url.lastPathComponent))</div>\n<div class=\"listing\">\n"
        for (i, line) in lines.enumerated() {
            body += "<div class=\"ln\"><span class=\"n\">\(i + 1)</span>"
            body += "<span class=\"c\">\(Markdown.escape(line.isEmpty ? " " : line))</span></div>\n"
        }
        body += "</div>\n"
        return Markdown.page(title: url.lastPathComponent, body: body)
    }

    // MARK: Jupyter notebooks — markdown cells, code cells, and their outputs.

    static func notebookHTML(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cells = root["cells"] as? [[String: Any]] else { return nil }
        let dir = url.deletingLastPathComponent()
        var body = "<div class=\"fname\">\(Markdown.escape(url.lastPathComponent))</div>\n"

        for cell in cells {
            let kind = cell["cell_type"] as? String ?? ""
            let src = joined(cell["source"])
            switch kind {
            case "markdown":
                body += "<div class=\"cell\">" + Markdown.bodyHTML(src, baseDir: dir) + "</div>\n"
            case "code":
                let n = (cell["execution_count"] as? Int).map(String.init) ?? " "
                body += "<div class=\"cell\"><div class=\"prompt\">In [\(n)]</div>"
                body += "<pre><code>\(Markdown.escape(src))</code></pre>"
                for out in cell["outputs"] as? [[String: Any]] ?? [] {
                    body += output(out)
                }
                body += "</div>\n"
            case "raw":
                body += "<pre>\(Markdown.escape(src))</pre>\n"
            default: break
            }
        }
        return Markdown.page(title: url.deletingPathExtension().lastPathComponent, body: body)
    }

    private static func output(_ o: [String: Any]) -> String {
        // stream output / errors
        if let name = o["name"] as? String, o["text"] != nil {
            let cls = name == "stderr" ? "err" : "out"
            return "<pre class=\"\(cls)\">\(Markdown.escape(joined(o["text"])))</pre>"
        }
        if o["output_type"] as? String == "error" {
            let tb = (o["traceback"] as? [String] ?? []).joined(separator: "\n")
            let stripped = tb.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "",
                                                   options: .regularExpression)
            let head = [o["ename"] as? String, o["evalue"] as? String]
                .compactMap { $0 }.joined(separator: ": ")
            return "<pre class=\"err\">\(Markdown.escape(stripped.isEmpty ? head : stripped))</pre>"
        }
        guard let data = o["data"] as? [String: Any] else { return "" }
        for key in ["image/png", "image/jpeg", "image/gif"] {
            if let b64 = data[key] as? String {
                let clean = b64.components(separatedBy: .whitespacesAndNewlines).joined()
                return "<img src=\"data:\(key);base64,\(clean)\">"
            }
        }
        if let svg = data["image/svg+xml"] { return joined(svg) }
        if let html = data["text/html"] { return joined(html) }
        if data["text/plain"] != nil {
            return "<pre class=\"out\">\(Markdown.escape(joined(data["text/plain"])))</pre>"
        }
        return ""
    }

    /// Notebook fields are either a string or an array of lines.
    private static func joined(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let a = any as? [String] { return a.joined() }
        return ""
    }

    /// Notes are not always UTF-8; fall back rather than refusing to open.
    static func readText(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var enc: String.Encoding = .utf8
        if let s = try? String(contentsOf: url, usedEncoding: &enc) { return s }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }
}
