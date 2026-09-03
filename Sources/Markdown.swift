import Foundation

/// A small, dependency-free Markdown → HTML converter.
/// Deliberately renders a *light* document: SlideView's smart invert turns it
/// dark the same way it does any PDF, so notes and slides look consistent.
enum Markdown {

    static func html(_ source: String, title: String, baseDir: URL) -> String {
        let body = blocks(source, baseDir: baseDir)
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
          @page { margin: 0; }
          /* padding-top rather than margin-top: collapsing margins would make
             offsetTop disagree with where the block actually paints, and the
             paginator reads offsetTop. */
          body{ margin:0; padding:0 54px; width:487px; overflow:hidden;
                font:15px/1.62 -apple-system,"SF Pro Text","Helvetica Neue",sans-serif;
                color:#16161a; background:#fff; }
          h1,h2,h3,h4,h5,h6{ line-height:1.25; margin:0 0 .55em; padding-top:1.5em;
                             font-weight:640; }
          h1{ font-size:26px; padding-top:0; border-bottom:1px solid #e3e3e8; padding-bottom:.3em; }
          h2{ font-size:21px; border-bottom:1px solid #ececf1; padding-bottom:.25em; }
          h3{ font-size:17px } h4,h5,h6{ font-size:15px }
          p,ul,ol,blockquote,table,pre{ margin:0 0 .85em; }
          hr{ margin:1.6em 0 }
          ul,ol{ padding-left:1.5em } li{ margin:.22em 0 }
          li>ul,li>ol{ margin:.22em 0 }
          code{ font:13px/1.5 ui-monospace,"SF Mono",Menlo,monospace;
                background:#f2f2f6; padding:.12em .38em; border-radius:4px; }
          pre{ background:#f6f6f9; border:1px solid #e6e6ee; border-radius:8px;
               padding:11px 13px; overflow:hidden; white-space:pre-wrap; word-wrap:break-word; }
          pre code{ background:none; padding:0; font-size:12.5px; }
          blockquote{ border-left:3px solid #d4d4de; padding-left:14px; color:#54545e; }
          table{ border-collapse:collapse; width:100%; font-size:14px; }
          th,td{ border:1px solid #e0e0e8; padding:6px 9px; text-align:left; vertical-align:top; }
          th{ background:#f5f5f9; font-weight:600 }
          hr{ border:0; border-top:1px solid #e3e3e8; margin:1.6em 0 }
          img{ max-width:100%; height:auto }
          a{ color:#0a58c8; text-decoration:none }
          .task{ list-style:none; margin-left:-1.2em }
        </style></head><body>
        \(body)
        </body></html>
        """
    }

    // MARK: - Block level

    private static func blocks(_ src: String, baseDir: URL) -> String {
        var out = ""
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0

        func flushParagraph(_ buf: inout [String]) {
            guard !buf.isEmpty else { return }
            out += "<p>" + inline(buf.joined(separator: " "), baseDir: baseDir) + "</p>\n"
            buf.removeAll()
        }

        var para: [String] = []
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // fenced code
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushParagraph(&para)
                let fence = String(line.prefix(3))
                i += 1
                var code: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1
                out += "<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>\n"
                continue
            }

            if line.isEmpty { flushParagraph(&para); i += 1; continue }

            // horizontal rule
            if line.count >= 3, let f = line.first, "-*_".contains(f), line.allSatisfy({ $0 == f }) {
                flushParagraph(&para); out += "<hr>\n"; i += 1; continue
            }

            // heading
            if line.hasPrefix("#") {
                let hashes = line.prefix(while: { $0 == "#" }).count
                if hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") {
                    flushParagraph(&para)
                    let text = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                    out += "<h\(hashes)>" + inline(text, baseDir: baseDir) + "</h\(hashes)>\n"
                    i += 1; continue
                }
            }

            // blockquote
            if line.hasPrefix(">") {
                flushParagraph(&para)
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var t = lines[i].trimmingCharacters(in: .whitespaces)
                    t.removeFirst()
                    quoted.append(t.hasPrefix(" ") ? String(t.dropFirst()) : t)
                    i += 1
                }
                out += "<blockquote>\n" + blocks(quoted.joined(separator: "\n"), baseDir: baseDir) + "</blockquote>\n"
                continue
            }

            // table
            if line.contains("|"), i + 1 < lines.count,
               isTableRule(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph(&para)
                let head = cells(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || !t.contains("|") { break }
                    rows.append(cells(t)); i += 1
                }
                out += "<table><thead><tr>"
                out += head.map { "<th>" + inline($0, baseDir: baseDir) + "</th>" }.joined()
                out += "</tr></thead><tbody>\n"
                for r in rows {
                    out += "<tr>" + r.map { "<td>" + inline($0, baseDir: baseDir) + "</td>" }.joined() + "</tr>\n"
                }
                out += "</tbody></table>\n"
                continue
            }

            // lists
            if let _ = bullet(line) {
                flushParagraph(&para)
                var items: [String] = []
                let ordered = orderedMarker(line)
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let content = bullet(t), orderedMarker(t) == ordered else { break }
                    items.append(content); i += 1
                }
                let tag = ordered ? "ol" : "ul"
                out += "<\(tag)>\n"
                for it in items {
                    if it.hasPrefix("[ ] ") || it.hasPrefix("[x] ") || it.hasPrefix("[X] ") {
                        let done = !it.hasPrefix("[ ] ")
                        let text = String(it.dropFirst(4))
                        out += "<li class=\"task\">\(done ? "☑" : "☐") " + inline(text, baseDir: baseDir) + "</li>\n"
                    } else {
                        out += "<li>" + inline(it, baseDir: baseDir) + "</li>\n"
                    }
                }
                out += "</\(tag)>\n"
                continue
            }

            para.append(line)
            i += 1
        }
        flushParagraph(&para)
        return out
    }

    private static func bullet(_ line: String) -> String? {
        for m in ["- ", "* ", "+ "] where line.hasPrefix(m) { return String(line.dropFirst(2)) }
        // 1. / 12)
        let digits = line.prefix(while: { $0.isNumber })
        if !digits.isEmpty {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return String(rest.dropFirst(2)) }
        }
        return nil
    }
    private static func orderedMarker(_ line: String) -> Bool {
        !line.prefix(while: { $0.isNumber }).isEmpty
    }
    private static func isTableRule(_ s: String) -> Bool {
        guard s.contains("|"), s.contains("-") else { return false }
        return s.allSatisfy { "|-: ".contains($0) }
    }
    private static func cells(_ row: String) -> [String] {
        var t = row.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Inline

    private static func inline(_ s: String, baseDir: URL) -> String {
        var t = escape(s)
        // code spans first so their contents are not further formatted
        var spans: [String] = []
        t = replace(t, #"`([^`]+)`"#) { m in
            spans.append(m[1]); return "\u{0}CODE\(spans.count - 1)\u{0}"
        }
        t = replace(t, #"!\[([^\]]*)\]\(([^)\s]+)\)"#) { m in
            "<img alt=\"\(m[1])\" src=\"\(dataURI(m[2], baseDir: baseDir))\">"
        }
        t = replace(t, #"\[([^\]]+)\]\(([^)\s]+)\)"#) { m in "<a href=\"\(m[2])\">\(m[1])</a>" }
        t = replace(t, #"\*\*([^*]+)\*\*"#) { m in "<strong>\(m[1])</strong>" }
        t = replace(t, #"__([^_]+)__"#) { m in "<strong>\(m[1])</strong>" }
        t = replace(t, #"(?<![*\w])\*([^*]+)\*(?!\w)"#) { m in "<em>\(m[1])</em>" }
        t = replace(t, #"~~([^~]+)~~"#) { m in "<s>\(m[1])</s>" }
        for (n, c) in spans.enumerated() {
            t = t.replacingOccurrences(of: "\u{0}CODE\(n)\u{0}", with: "<code>\(c)</code>")
        }
        return t
    }

    /// Inline local images so the print pass needs no file access at all.
    private static func dataURI(_ src: String, baseDir: URL) -> String {
        if src.hasPrefix("http://") || src.hasPrefix("https://") || src.hasPrefix("data:") { return src }
        let url = src.hasPrefix("/") ? URL(fileURLWithPath: src)
                                     : baseDir.appendingPathComponent(src)
        guard let d = try? Data(contentsOf: url), d.count < 8 * 1024 * 1024 else { return src }
        let type: String
        switch url.pathExtension.lowercased() {
        case "png": type = "image/png"
        case "gif": type = "image/gif"
        case "svg": type = "image/svg+xml"
        case "webp": type = "image/webp"
        default: type = "image/jpeg"
        }
        return "data:\(type);base64," + d.base64EncodedString()
    }

    private static func replace(_ s: String, _ pattern: String,
                                _ body: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for g in 0..<m.numberOfRanges {
                let r = m.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += body(groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
