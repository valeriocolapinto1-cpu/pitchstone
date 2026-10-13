import Foundation

/// Formattazione dell'editor visuale: i pulsanti della barra applicano la sintassi
/// Markdown al testo selezionato. Le posizioni sono in caratteri (Character),
/// così l'app converte facilmente da e verso la selezione di SwiftUI.
public enum MarkdownFormat: Hashable, Sendable {
    case bold, italic, strikethrough, code
    case heading(Int)
    case bulletList, numberedList, checklist, quote
    case link
}

public struct TextEdit: Equatable, Sendable {
    public var text: String
    /// Nuova selezione in caratteri.
    public var selection: Range<Int>

    public init(text: String, selection: Range<Int>) {
        self.text = text
        self.selection = selection
    }
}

public enum MarkdownFormatting {
    public static func apply(_ format: MarkdownFormat, to text: String, selection: Range<Int>) -> TextEdit {
        let chars = Array(text)
        let lower = max(0, min(selection.lowerBound, chars.count))
        let upper = max(lower, min(selection.upperBound, chars.count))
        let range = lower..<upper
        switch format {
        case .bold: return toggleInline("**", chars, range)
        case .italic: return toggleInline("*", chars, range)
        case .strikethrough: return toggleInline("~~", chars, range)
        case .code: return toggleInline("`", chars, range)
        case .heading(let level): return toggleLines(chars, range) { lines in
            let prefix = String(repeating: "#", count: min(max(level, 1), 6)) + " "
            let allHave = lines.allSatisfy { $0.hasPrefix(prefix) }
            return lines.map { line in
                let stripped = stripHeading(line)
                return allHave ? stripped : prefix + stripped
            }
        }
        case .bulletList: return toggleLinePrefix("- ", chars, range)
        case .checklist: return toggleLinePrefix("- [ ] ", chars, range)
        case .quote: return toggleLinePrefix("> ", chars, range)
        case .numberedList: return toggleLines(chars, range) { lines in
            let allHave = lines.allSatisfy { numberedPrefix($0) != nil }
            return lines.enumerated().map { index, line in
                let stripped = numberedPrefix(line).map { String(line.dropFirst($0)) } ?? line
                return allHave ? stripped : "\(index + 1). " + stripped
            }
        }
        case .link: return insertLink(chars, range)
        }
    }

    // MARK: Inline

    private static func toggleInline(_ marker: String, _ chars: [Character], _ range: Range<Int>) -> TextEdit {
        let m = Array(marker)
        let n = m.count
        // Già formattato: i marcatori stanno appena fuori dalla selezione.
        if range.lowerBound >= n, range.upperBound + n <= chars.count,
           Array(chars[(range.lowerBound - n)..<range.lowerBound]) == m,
           Array(chars[range.upperBound..<(range.upperBound + n)]) == m,
           !(marker == "*" && isBoldBoundary(chars, range)) {
            var out = chars
            out.removeSubrange(range.upperBound..<(range.upperBound + n))
            out.removeSubrange((range.lowerBound - n)..<range.lowerBound)
            return TextEdit(text: String(out), selection: (range.lowerBound - n)..<(range.upperBound - n))
        }
        // Oppure dentro la selezione.
        let selected = Array(chars[range])
        if selected.count >= 2 * n, Array(selected.prefix(n)) == m, Array(selected.suffix(n)) == m {
            var out = chars
            out.replaceSubrange(range, with: selected.dropFirst(n).dropLast(n))
            return TextEdit(text: String(out), selection: range.lowerBound..<(range.upperBound - 2 * n))
        }
        var out = chars
        out.replaceSubrange(range, with: m + selected + m)
        return TextEdit(text: String(out), selection: (range.lowerBound + n)..<(range.upperBound + n))
    }

    /// `**testo**` non va confuso con un corsivo: un solo `*` di qua e di là fa parte del grassetto.
    private static func isBoldBoundary(_ chars: [Character], _ range: Range<Int>) -> Bool {
        range.lowerBound >= 2 && chars[range.lowerBound - 2] == "*"
            && range.upperBound + 1 < chars.count && chars[range.upperBound + 1] == "*"
    }

    private static func insertLink(_ chars: [Character], _ range: Range<Int>) -> TextEdit {
        let label = Array(chars[range])
        let placeholder = Array("https://")
        var out = chars
        out.replaceSubrange(range, with: Array("[") + label + Array("](") + placeholder + Array(")"))
        if label.isEmpty {
            // Nessun testo selezionato: il cursore va nel testo del link.
            return TextEdit(text: String(out), selection: (range.lowerBound + 1)..<(range.lowerBound + 1))
        }
        let urlStart = range.lowerBound + label.count + 3
        return TextEdit(text: String(out), selection: urlStart..<(urlStart + placeholder.count))
    }

    // MARK: Righe

    private static func toggleLinePrefix(_ prefix: String, _ chars: [Character], _ range: Range<Int>) -> TextEdit {
        toggleLines(chars, range) { lines in
            let allHave = lines.allSatisfy { $0.hasPrefix(prefix) }
            return lines.map { allHave ? String($0.dropFirst(prefix.count)) : prefix + $0 }
        }
    }

    /// Applica `transform` alle righe toccate dalla selezione; la selezione copre le righe risultanti.
    private static func toggleLines(_ chars: [Character], _ range: Range<Int>, _ transform: ([String]) -> [String]) -> TextEdit {
        var start = range.lowerBound
        while start > 0, chars[start - 1] != "\n" { start -= 1 }
        var end = range.upperBound
        // Una selezione che finisce a inizio riga non tocca quella riga.
        if end > start, end > range.lowerBound, chars[end - 1] == "\n" { end -= 1 }
        while end < chars.count, chars[end] != "\n" { end += 1 }
        let block = String(chars[start..<end])
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let replaced = Array(transform(lines).joined(separator: "\n"))
        var out = chars
        out.replaceSubrange(start..<end, with: replaced)
        if range.isEmpty, lines.count == 1 {
            // Cursore senza selezione: resta alla fine della riga modificata.
            let caret = start + replaced.count
            return TextEdit(text: String(out), selection: caret..<caret)
        }
        return TextEdit(text: String(out), selection: start..<(start + replaced.count))
    }

    private static func stripHeading(_ line: String) -> String {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return line }
        return String(line.dropFirst(hashes + 1))
    }

    /// Lunghezza del prefisso `12. ` se la riga è un elemento numerato.
    private static func numberedPrefix(_ line: String) -> Int? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }.count
        guard digits > 0, line.dropFirst(digits).hasPrefix(". ") else { return nil }
        return digits + 2
    }
}
