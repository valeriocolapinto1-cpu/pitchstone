import Foundation
import Markdown

// Rendering Markdown in un modello a blocchi indipendente dalla UI: SwiftUI lo
// disegna sull'iPad, i test lo verificano anche su Linux.

public struct InlineStyle: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = InlineStyle(rawValue: 1 << 0)
    public static let italic = InlineStyle(rawValue: 1 << 1)
    public static let code = InlineStyle(rawValue: 1 << 2)
    public static let strikethrough = InlineStyle(rawValue: 1 << 3)
}

public enum InlineLink: Hashable, Sendable {
    case url(String)
    /// Link a un altro nodo, `[[Titolo]]` o `[[Titolo|testo]]` come in Obsidian.
    case wiki(String)
}

public struct InlineRun: Hashable, Sendable {
    public var text: String
    public var style: InlineStyle
    public var link: InlineLink?

    public init(_ text: String, style: InlineStyle = [], link: InlineLink? = nil) {
        self.text = text
        self.style = style
        self.link = link
    }
}

public struct MarkdownListItem: Hashable, Sendable {
    /// nil se non è una checklist, altrimenti lo stato della casella.
    public var checked: Bool?
    public var blocks: [MarkdownBlock]

    public init(checked: Bool? = nil, blocks: [MarkdownBlock]) {
        self.checked = checked
        self.blocks = blocks
    }
}

public indirect enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, [InlineRun])
    case paragraph([InlineRun])
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case quote([MarkdownBlock])
    case code(language: String?, code: String)
    case table(header: [[InlineRun]], rows: [[[InlineRun]]])
    case rule
}

public enum MarkdownRenderer {
    public static func render(_ text: String) -> [MarkdownBlock] {
        blocks(Document(parsing: text).children)
    }

    private static func blocks(_ children: MarkupChildren) -> [MarkdownBlock] {
        children.compactMap(block)
    }

    private static func block(_ markup: Markup) -> MarkdownBlock? {
        switch markup {
        case let h as Heading:
            return .heading(level: h.level, inlines(h.children))
        case let p as Paragraph:
            return .paragraph(inlines(p.children))
        case let list as UnorderedList:
            return .list(ordered: false, start: 1, items: items(list.listItems))
        case let list as OrderedList:
            return .list(ordered: true, start: Int(list.startIndex), items: items(list.listItems))
        case let quote as BlockQuote:
            return .quote(blocks(quote.children))
        case let code as CodeBlock:
            let body = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
            return .code(language: code.language.flatMap { $0.isEmpty ? nil : $0 }, code: body)
        case is ThematicBreak:
            return .rule
        case let table as Table:
            let header: [[InlineRun]] = table.head.cells.map { inlines($0.children) }
            let rows: [[[InlineRun]]] = table.body.rows.map { row in row.cells.map { inlines($0.children) } }
            return .table(header: header, rows: rows)
        case let html as HTMLBlock:
            // Niente HTML grezzo nell'anteprima: si mostra come codice.
            return .code(language: "html", code: html.rawHTML.trimmingCharacters(in: .newlines))
        default:
            return nil
        }
    }

    private static func items(_ items: some Sequence<ListItem>) -> [MarkdownListItem] {
        items.map { item in
            let checked: Bool? = switch item.checkbox {
            case .checked: true
            case .unchecked: false
            case nil: nil
            }
            return MarkdownListItem(checked: checked, blocks: blocks(item.children))
        }
    }

    // MARK: Inline

    private static func inlines(_ children: MarkupChildren) -> [InlineRun] {
        var runs: [InlineRun] = []
        for child in children { collect(child, style: [], link: nil, into: &runs) }
        return merge(runs.flatMap(splitWikiLinks))
    }

    private static func collect(_ markup: Markup, style: InlineStyle, link: InlineLink?, into runs: inout [InlineRun]) {
        switch markup {
        case let text as Markdown.Text:
            runs.append(InlineRun(text.string, style: style, link: link))
        case let code as InlineCode:
            runs.append(InlineRun(code.code, style: style.union(.code), link: link))
        case is SoftBreak:
            runs.append(InlineRun(" ", style: style, link: link))
        case is LineBreak:
            runs.append(InlineRun("\n", style: style, link: link))
        case let html as InlineHTML:
            runs.append(InlineRun(html.rawHTML, style: style.union(.code), link: link))
        case let image as Image:
            // Le immagini arrivano con gli allegati (fase 4): per ora il testo alternativo.
            let alt = image.plainText
            runs.append(InlineRun(alt.isEmpty ? (image.source ?? "") : alt, style: style.union(.italic), link: image.source.map(InlineLink.url)))
        default:
            var style = style
            var link = link
            if markup is Strong { style.insert(.bold) }
            if markup is Emphasis { style.insert(.italic) }
            if markup is Strikethrough { style.insert(.strikethrough) }
            if let l = markup as? Markdown.Link, let destination = l.destination { link = .url(destination) }
            for child in markup.children { collect(child, style: style, link: link, into: &runs) }
        }
    }

    /// `[[Titolo]]` e `[[Titolo|testo]]` dentro il testo normale (non nel codice, non nei link).
    private static func splitWikiLinks(_ run: InlineRun) -> [InlineRun] {
        guard run.link == nil, !run.style.contains(.code), run.text.contains("[[") else { return [run] }
        var result: [InlineRun] = []
        var rest = Substring(run.text)
        while let open = rest.range(of: "[["), let close = rest[open.upperBound...].range(of: "]]") {
            let inner = rest[open.upperBound..<close.lowerBound]
            let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = parts[0].trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, !inner.contains("[") else {
                result.append(InlineRun(String(rest[..<close.upperBound]), style: run.style))
                rest = rest[close.upperBound...]
                continue
            }
            if open.lowerBound > rest.startIndex {
                result.append(InlineRun(String(rest[..<open.lowerBound]), style: run.style))
            }
            let label = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : target
            result.append(InlineRun(label.isEmpty ? target : label, style: run.style, link: .wiki(target)))
            rest = rest[close.upperBound...]
        }
        if !rest.isEmpty { result.append(InlineRun(String(rest), style: run.style)) }
        return result
    }

    /// Unisce i frammenti consecutivi con lo stesso stile e lo stesso link.
    private static func merge(_ runs: [InlineRun]) -> [InlineRun] {
        var merged: [InlineRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = merged.last, last.style == run.style, last.link == run.link {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }
        return merged
    }
}

public enum MarkdownLinks {
    /// Titoli dei nodi collegati con `[[...]]`, in ordine e senza duplicati.
    /// Servono a creare gli archi di tipo `link` del grafo.
    public static func wikiTargets(in text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func visit(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case .heading(_, let runs), .paragraph(let runs): add(runs)
                case .list(_, _, let items): items.forEach { visit($0.blocks) }
                case .quote(let inner): visit(inner)
                case .table(let header, let rows):
                    header.forEach(add)
                    rows.forEach { $0.forEach(add) }
                case .code, .rule: break
                }
            }
        }
        func add(_ runs: [InlineRun]) {
            for run in runs {
                if case .wiki(let target)? = run.link, seen.insert(target.lowercased()).inserted {
                    result.append(target)
                }
            }
        }
        visit(MarkdownRenderer.render(text))
        return result
    }
}
