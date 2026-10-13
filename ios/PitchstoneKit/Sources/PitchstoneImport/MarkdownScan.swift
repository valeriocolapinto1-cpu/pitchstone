import Foundation

/// Applica una trasformazione solo al testo normale di un Markdown: i blocchi di codice
/// (``` e ~~~) e il codice inline restano come sono.
enum MarkdownScan {
    static func transformText(_ markdown: String, _ transform: (String) -> String) -> String {
        var output: [String] = []
        var fence: (char: Character, length: Int)?
        for line in markdown.components(separatedBy: "\n") {
            let marker = fenceMarker(line)
            if let open = fence {
                output.append(line)
                if let marker, marker.char == open.char, marker.length >= open.length, marker.rest.isEmpty { fence = nil }
                continue
            }
            if let marker {
                fence = (marker.char, marker.length)
                output.append(line)
                continue
            }
            output.append(transformLine(line, transform))
        }
        return output.joined(separator: "\n")
    }

    /// Recinzione di un blocco di codice: almeno tre ` o ~, con al massimo tre spazi prima.
    private static func fenceMarker(_ line: String) -> (char: Character, length: Int, rest: String)? {
        let indent = line.prefix { $0 == " " }
        guard indent.count <= 3 else { return nil }
        let rest = line.dropFirst(indent.count)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let run = rest.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        return (first, run.count, rest.dropFirst(run.count).trimmingCharacters(in: .whitespaces))
    }

    /// Divide la riga in testo e codice inline: una sequenza di n backtick si chiude con
    /// un'altra di n backtick; se non si chiude è testo normale.
    private static func transformLine(_ line: String, _ transform: (String) -> String) -> String {
        guard line.contains("`") else { return transform(line) }
        let chars = Array(line)
        var result = ""
        var text = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "`" else {
                text.append(chars[i])
                i += 1
                continue
            }
            var n = 0
            while i + n < chars.count, chars[i + n] == "`" { n += 1 }
            if let close = closingRun(of: n, in: chars, from: i + n) {
                result += transform(text)
                text = ""
                result += String(chars[i..<(close + n)])
                i = close + n
            } else {
                text += String(repeating: "`", count: n)
                i += n
            }
        }
        return result + transform(text)
    }

    private static func closingRun(of n: Int, in chars: [Character], from start: Int) -> Int? {
        var j = start
        while j < chars.count {
            guard chars[j] == "`" else { j += 1; continue }
            var m = 0
            while j + m < chars.count, chars[j + m] == "`" { m += 1 }
            if m == n { return j }
            j += m
        }
        return nil
    }
}
