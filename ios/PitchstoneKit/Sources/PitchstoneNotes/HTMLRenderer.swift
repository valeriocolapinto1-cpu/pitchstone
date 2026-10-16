import Foundation

/// HTML semplice dai blocchi Markdown, per l'esportazione in PDF. I `[[link]]`
/// diventano testo sottolineato: in un PDF non portano da nessuna parte.
public enum HTMLRenderer {
    public static func document(title: String, markdown: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        body{font-family:-apple-system,Helvetica,sans-serif;font-size:12pt;line-height:1.45;color:#111;margin:0}
        h1{font-size:22pt}h2{font-size:17pt}h3{font-size:14pt}
        pre{background:#f3f3f3;padding:8px;border-radius:6px;white-space:pre-wrap;font-size:10pt}
        code{font-family:Menlo,monospace}blockquote{border-left:3px solid #999;margin-left:0;padding-left:10px;color:#444}
        table{border-collapse:collapse}td,th{border:1px solid #bbb;padding:4px 8px}.wiki{text-decoration:underline}
        </style></head><body><h1>\(escape(title))</h1>
        \(body(markdown))
        </body></html>
        """
    }

    public static func body(_ markdown: String) -> String {
        MarkdownRenderer.render(markdown).map(block).joined(separator: "\n")
    }

    static func block(_ block: MarkdownBlock) -> String {
        switch block {
        case .heading(let level, let runs):
            let h = min(6, level + 1)
            return "<h\(h)>\(inline(runs))</h\(h)>"
        case .paragraph(let runs):
            return "<p>\(inline(runs))</p>"
        case .list(let ordered, let start, let items):
            let tag = ordered ? "ol" : "ul"
            let open = ordered && start != 1 ? "<ol start=\"\(start)\">" : "<\(tag)>"
            let lis = items.map { item -> String in
                let box = item.checked.map { $0 ? "☑ " : "☐ " } ?? ""
                return "<li>\(box)\(item.blocks.map(Self.block).joined())</li>"
            }.joined()
            return open + lis + "</\(tag)>"
        case .quote(let inner):
            return "<blockquote>\(inner.map(Self.block).joined())</blockquote>"
        case .code(_, let code):
            return "<pre><code>\(escape(code))</code></pre>"
        case .table(let header, let rows):
            let head = "<tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr>"
            let body = rows.map { "<tr>" + $0.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }.joined()
            return "<table>\(head)\(body)</table>"
        case .rule:
            return "<hr>"
        }
    }

    static func inline(_ runs: [InlineRun]) -> String {
        runs.map { run in
            var text = escape(run.text).replacingOccurrences(of: "\n", with: "<br>")
            if run.style.contains(.code) { text = "<code>\(text)</code>" }
            if run.style.contains(.bold) { text = "<strong>\(text)</strong>" }
            if run.style.contains(.italic) { text = "<em>\(text)</em>" }
            if run.style.contains(.strikethrough) { text = "<s>\(text)</s>" }
            switch run.link {
            case .url(let url) where url.hasPrefix("http://") || url.hasPrefix("https://"):
                text = "<a href=\"\(escape(url))\">\(text)</a>"
            case .wiki:
                text = "<span class=\"wiki\">\(text)</span>"
            default:
                break
            }
            return text
        }.joined()
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
