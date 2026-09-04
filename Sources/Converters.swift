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
