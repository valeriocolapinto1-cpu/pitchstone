import Foundation
import Markdown

/// Applica una trasformazione solo al testo normale di un Markdown: codice (blocchi,
/// anche indentati o dentro le liste, e inline) e HTML restano come sono. Usa lo stesso
/// parser dell'app, così l'import tratta come codice esattamente ciò che l'app non collega.
enum MarkdownScan {
    static func transformText(_ markdown: String, _ transform: (String) -> String) -> String {
        var result = ""
        var cursor = markdown.startIndex
        for range in protectedRanges(markdown) where range.lowerBound >= cursor {
            result += transform(String(markdown[cursor..<range.lowerBound]))
            result += markdown[range]
            cursor = range.upperBound
        }
        return result + transform(String(markdown[cursor...]))
    }

    /// Intervalli di codice e HTML, in ordine e senza sovrapposizioni.
    static func protectedRanges(_ text: String) -> [Range<String.Index>] {
        guard text.contains("`") || text.contains("~") || text.contains("<") || text.contains("    ") || text.contains("\t") else { return [] }
        var collector = ProtectedCollector()
        collector.visit(Document(parsing: text))

        // Inizio di ogni riga, in byte UTF-8: le posizioni di swift-markdown sono riga e colonna in byte.
        var lineStarts = [0]
        for (offset, byte) in text.utf8.enumerated() where byte == UInt8(ascii: "\n") { lineStarts.append(offset + 1) }
        let count = text.utf8.count
        func index(_ location: SourceLocation) -> String.Index? {
            guard location.line >= 1, location.line <= lineStarts.count else { return nil }
            let offset = min(lineStarts[location.line - 1] + location.column - 1, count)
            return String.Index(text.utf8.index(text.utf8.startIndex, offsetBy: offset), within: text)
        }

        var ranges = collector.ranges.compactMap { range -> Range<String.Index>? in
            guard let lower = index(range.lowerBound), let upper = index(range.upperBound), lower < upper else { return nil }
            return lower..<upper
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

private struct ProtectedCollector: MarkupWalker {
    var ranges: [SourceRange] = []

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) { add(codeBlock) }
    mutating func visitInlineCode(_ inlineCode: InlineCode) { add(inlineCode) }
    mutating func visitHTMLBlock(_ html: HTMLBlock) { add(html) }
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) { add(inlineHTML) }

    private mutating func add(_ markup: Markup) {
        if let range = markup.range { ranges.append(range) }
    }
}
