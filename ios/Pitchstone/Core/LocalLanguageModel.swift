import Foundation
import NaturalLanguage
import PitchstoneAI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Modello sul dispositivo (Apple Foundation Models, iOS 26 con Apple Intelligence).
/// Offline e gratuito; 4.096 token in tutto, quindi poche fonti e risposte brevi.
struct LocalModelProvider: ChatProvider {
    let kind = ChatProviderKind.local
    let budget = TokenBudget.local

    func isAvailable() async -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    func reply(to prompt: ChatPrompt) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            var prompt = prompt
            // La stima dei token è approssimata: se il contesto non basta si riprova con metà fonti.
            for _ in 0..<3 {
                let session = LanguageModelSession(instructions: prompt.system)
                do {
                    let response = try await session.respond(
                        to: prompt.transcript, options: GenerationOptions(maximumResponseTokens: budget.answer))
                    return response.content
                } catch LanguageModelSession.GenerationError.exceededContextWindowSize(_) {
                    guard !prompt.sources.isEmpty || !prompt.history.isEmpty else { throw ChatError.contextTooLarge }
                    prompt.sources = Array(prompt.sources.prefix(prompt.sources.count / 2))
                    prompt.history = Array(prompt.history.suffix(prompt.history.count / 2))
                } catch LanguageModelSession.GenerationError.guardrailViolation(_) {
                    throw ChatError.refused
                }
            }
            throw ChatError.contextTooLarge
        }
        #endif
        throw ChatError.noProvider
    }
}

/// Vettori di frase di NaturalLanguage, in italiano: ricerca semantica offline.
/// Se il modello della lingua non è sul dispositivo, la ricerca usa solo le parole.
final class NLTextEmbedder: TextEmbedder, @unchecked Sendable {
    private let embedding: NLEmbedding?
    private let lock = NSLock()

    init(language: NLLanguage = .italian) {
        embedding = NLEmbedding.sentenceEmbedding(for: language)
    }

    var isAvailable: Bool { embedding != nil }

    func vector(for text: String) -> [Float]? {
        // NLEmbedding non è sicuro tra thread: una richiesta alla volta.
        lock.withLock { embedding?.vector(for: String(text.prefix(2000))) }?.map(Float.init)
    }
}
