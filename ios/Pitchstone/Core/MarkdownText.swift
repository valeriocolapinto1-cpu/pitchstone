import Foundation
import PitchstoneNotes

/// Ponte tra i frammenti inline di PitchstoneNotes e `AttributedString`.
/// I link tra nodi usano lo schema `pitchstone-node:`, intercettato dall'anteprima.
enum MarkdownText {
    static let nodeScheme = "pitchstone-node"

    static func attributed(_ runs: [InlineRun]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.style.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if run.style.contains(.italic) { intent.insert(.emphasized) }
            if run.style.contains(.code) { intent.insert(.code) }
            if run.style.contains(.strikethrough) { intent.insert(.strikethrough) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            switch run.link {
            case .url(let destination):
                piece.link = URL(string: destination)
            case .wiki(let title):
                piece.link = nodeURL(title)
            case nil:
                break
            }
            result += piece
        }
        return result
    }

    static func nodeURL(_ title: String) -> URL? {
        var components = URLComponents()
        components.scheme = nodeScheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "title", value: title)]
        return components.url
    }

    /// Titolo del nodo se l'URL è un link `[[...]]`, altrimenti nil.
    static func nodeTitle(from url: URL) -> String? {
        guard url.scheme == nodeScheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return items.first { $0.name == "title" }?.value
    }
}
