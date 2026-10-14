import Foundation

public enum ChatProviderKind: String, Sendable, Codable {
    /// Modello sul dispositivo (Apple Foundation Models).
    case local
    /// Gemini attraverso il Worker.
    case gemini
}

public struct ChatMessage: Sendable, Equatable, Codable, Identifiable {
    public enum Role: String, Sendable, Codable {
        case user, assistant
    }

    public var id: UUID
    public var role: Role
    public var text: String
    public var citations: [Citation]
    public var provider: ChatProviderKind?

    public init(id: UUID = UUID(), role: Role, text: String, citations: [Citation] = [], provider: ChatProviderKind? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.citations = citations
        self.provider = provider
    }
}

/// Spazio del prompt, in token stimati. Il modello locale ha 4.096 token in
/// tutto, risposta compresa; Gemini molti di più, ma oltre una certa quantità
/// di fonti le risposte non migliorano e il piano gratuito si consuma prima.
public struct TokenBudget: Sendable, Equatable {
    public var total: Int
    public var answer: Int

    public init(total: Int, answer: Int) {
        self.total = total
        self.answer = answer
    }

    public static let local = TokenBudget(total: 4096, answer: 1000)
    public static let gemini = TokenBudget(total: 24_000, answer: 4000)

    /// Stima prudente: in italiano un token vale circa 3-4 caratteri.
    public static func estimate(_ text: String) -> Int {
        (text.count + 2) / 3
    }
}

/// Tutto quello che un modello riceve: istruzioni, fonti numerate, conversazione.
public struct ChatPrompt: Sendable, Equatable {
    public var instructions: String
    public var sources: [Chunk]
    public var history: [ChatMessage]
    public var question: String
    /// Conversazione su un dato di salute: resta sul dispositivo.
    public var localOnly: Bool

    public init(instructions: String, sources: [Chunk], history: [ChatMessage], question: String, localOnly: Bool) {
        self.instructions = instructions
        self.sources = sources
        self.history = history
        self.question = question
        self.localOnly = localOnly
    }

    /// Fonti numerate da 1, come le citazioni nella risposta.
    public var sourcesText: String {
        guard !sources.isEmpty else { return "Nessuna fonte trovata negli appunti." }
        return sources.enumerated().map { index, chunk in
            "[\(index + 1)] \(chunk.title)\n\(chunk.text)"
        }.joined(separator: "\n\n")
    }

    /// Istruzioni con le fonti: il "system prompt".
    public var system: String {
        instructions + "\n\nFONTI\n" + sourcesText
    }

    /// Tutto in un testo, per il modello locale.
    public var transcript: String {
        var lines: [String] = []
        for message in history {
            lines.append((message.role == .user ? "Domanda: " : "Risposta: ") + message.text)
        }
        lines.append("Domanda: " + question)
        return lines.joined(separator: "\n\n")
    }
}

public enum PromptBuilder {
    public static let instructions = """
    Sei il tutor di studio di Pitchstone. Rispondi in italiano, in modo didattico e preciso: \
    prima la risposta in breve, poi la spiegazione passo per passo, con esempi quando aiutano. \
    Usa le FONTI, che sono gli appunti dell'utente. Dopo ogni affermazione presa da una fonte \
    scrivi il suo numero tra parentesi quadre, per esempio [2]. Non inventare numeri di fonti. \
    Se le fonti non bastano, dillo e rispondi con le tue conoscenze, senza citazioni. \
    Per le formule usa la notazione LaTeX tra $.
    """

    public static let maxQuestionLength = 8000
    public static let maxHistory = 38

    /// Mette nel prompt le fonti più pertinenti finché c'è spazio, poi la
    /// conversazione più recente. La domanda e le istruzioni entrano sempre.
    public static func build(
        question: String, history: [ChatMessage], candidates: [Chunk], budget: TokenBudget, localOnly: Bool
    ) -> ChatPrompt {
        // Gli stessi limiti del Worker: al più 40 messaggi, domanda sotto i 20.000 caratteri.
        let question = String(question.prefix(maxQuestionLength))
        let history = Array(history.suffix(maxHistory))
        let fixed = TokenBudget.estimate(instructions) + TokenBudget.estimate(question) + 20
        var available = budget.total - budget.answer - fixed

        // La conversazione recente vale fino a un quarto dello spazio.
        var kept: [ChatMessage] = []
        var historyBudget = max(0, available / 4)
        for message in history.reversed() {
            let cost = TokenBudget.estimate(message.text) + 4
            guard cost <= historyBudget else { break }
            kept.insert(message, at: 0)
            historyBudget -= cost
            available -= cost
        }

        var sources: [Chunk] = []
        for chunk in candidates {
            let cost = TokenBudget.estimate(chunk.title + chunk.text) + 6
            // Un frammento troppo grande si salta: uno più piccolo può ancora entrare.
            guard cost <= available else { continue }
            sources.append(chunk)
            available -= cost
        }
        return ChatPrompt(instructions: instructions, sources: sources, history: kept, question: question, localOnly: localOnly)
    }
}
