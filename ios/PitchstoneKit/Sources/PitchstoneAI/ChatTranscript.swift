import Foundation

/// Una conversazione salvata come nodo: domande e risposte in Markdown, citazioni
/// cliccabili e, in fondo, i nodi citati come `[[link]]`, che diventano archi del grafo.
public enum ChatTranscript {
    public static func title(for messages: [ChatMessage]) -> String {
        let question = messages.first { $0.role == .user }?.text ?? ""
        let line = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Chat" }
        return "Chat: " + (trimmed.count > 60 ? String(trimmed.prefix(59)) + "…" : trimmed)
    }

    /// `titles` dà il titolo attuale di un nodo citato; i nodi spariti non compaiono tra i link.
    public static func markdown(_ messages: [ChatMessage], titles: (UUID) -> String?) -> String {
        var parts: [String] = []
        var cited: [UUID] = []
        for message in messages {
            switch message.role {
            case .user:
                parts.append("## Domanda\n\n" + message.text)
            case .assistant:
                let source = message.provider == .gemini ? "Gemini" : "modello sul dispositivo"
                parts.append("### Risposta (\(source))\n\n" + Citations.linked(message.text, citations: message.citations))
                for citation in message.citations where !cited.contains(citation.ref.nodeID) {
                    cited.append(citation.ref.nodeID)
                }
            }
        }
        let links = cited.compactMap(titles).filter { !$0.isEmpty && !$0.contains("]]") && !$0.contains("|") }
        if !links.isEmpty {
            parts.append("## Fonti\n\n" + links.map { "- [[\($0)]]" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}
