import Foundation

/// Un modello che risponde a un prompt.
public protocol ChatProvider: Sendable {
    var kind: ChatProviderKind { get }
    var budget: TokenBudget { get }
    /// Pronto a rispondere: modello scaricato, Worker configurato.
    func isAvailable() async -> Bool
    func reply(to prompt: ChatPrompt) async throws -> String
}

public enum ChatError: Error, Equatable, Sendable {
    /// Né Gemini né il modello locale possono rispondere.
    case noProvider
    /// Un prompt con dati di salute stava per uscire dal dispositivo.
    case sensitiveContent
    case emptyAnswer
}

public struct ChatReply: Sendable, Equatable {
    public var message: ChatMessage
    public var prompt: ChatPrompt
    /// Perché ha risposto il modello locale invece di Gemini, se è successo.
    public var fallbackReason: String?
}

/// Sceglie chi risponde: Gemini se si è online, altrimenti il modello locale.
/// Le conversazioni su dati di salute restano sempre sul dispositivo.
public struct ChatRouter: Sendable {
    public var online: ChatProvider?
    public var local: ChatProvider?

    public init(online: ChatProvider?, local: ChatProvider?) {
        self.online = online
        self.local = local
    }

    public func answer(
        _ question: String, history: [ChatMessage], index: SemanticIndex, embedder: TextEmbedder?,
        focus: UUID? = nil, localOnly: Bool = false
    ) async throws -> ChatReply {
        let candidates = index.search(question, embedder: embedder, limit: 40, focus: focus)
        var fallbackReason: String?
        var onlineError: Error?
        if !localOnly, let online {
            if await online.isAvailable() {
                let prompt = PromptBuilder.build(
                    question: question, history: history, candidates: candidates, budget: online.budget, localOnly: false)
                do {
                    let text = try await online.reply(to: prompt)
                    return try Self.reply(text, kind: online.kind, prompt: prompt, fallbackReason: nil)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    onlineError = error
                    // Offline, limite del piano gratuito, Worker irraggiungibile: risponde il modello locale.
                    fallbackReason = String(describing: error)
                }
            } else {
                fallbackReason = "Gemini non disponibile"
            }
        }
        guard let local, await local.isAvailable() else {
            // Senza modello locale l'errore utile è quello di Gemini.
            throw onlineError ?? ChatError.noProvider
        }
        let prompt = PromptBuilder.build(
            question: question, history: history, candidates: candidates, budget: local.budget, localOnly: localOnly)
        let text = try await local.reply(to: prompt)
        return try Self.reply(text, kind: local.kind, prompt: prompt, fallbackReason: fallbackReason)
    }

    static func reply(_ text: String, kind: ChatProviderKind, prompt: ChatPrompt, fallbackReason: String?) throws -> ChatReply {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw ChatError.emptyAnswer }
        let citations = Citations.extract(from: answer, sources: prompt.sources)
        let message = ChatMessage(role: .assistant, text: answer, citations: citations, provider: kind)
        return ChatReply(message: message, prompt: prompt, fallbackReason: fallbackReason)
    }
}
