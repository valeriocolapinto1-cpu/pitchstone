import Foundation
import PitchstoneSync
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Corpo di `POST /ai/chat`: il Worker aggiunge la chiave e chiama Gemini.
public struct WorkerChatRequest: Codable, Equatable, Sendable {
    public struct Message: Codable, Equatable, Sendable {
        public var role: String
        public var text: String
    }

    public var system: String
    public var messages: [Message]
    public var maxOutputTokens: Int

    /// Il prompt in forma di richiesta. Un prompt riservato al dispositivo non
    /// diventa mai una richiesta: è l'ultimo controllo prima della rete.
    public init(prompt: ChatPrompt, maxOutputTokens: Int) throws {
        guard !prompt.localOnly else { throw ChatError.sensitiveContent }
        system = prompt.system
        messages = prompt.history.map { Message(role: $0.role.rawValue, text: $0.text) }
            + [Message(role: "user", text: prompt.question)]
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct WorkerChatResponse: Codable, Equatable, Sendable {
    public var text: String
}

/// Gemini attraverso il Worker `ai-proxy`: la chiave non è mai sull'iPad.
public struct WorkerChatProvider: ChatProvider {
    public let kind = ChatProviderKind.gemini
    public let budget = TokenBudget.gemini
    let transport: HTTPSyncTransport

    public init(transport: HTTPSyncTransport) {
        self.transport = transport
    }

    public func isAvailable() async -> Bool { true }

    public func reply(to prompt: ChatPrompt) async throws -> String {
        try await transport.send(makeRequest(prompt) as URLRequest, as: WorkerChatResponse.self).text
    }

    public func makeRequest(_ prompt: ChatPrompt) throws -> URLRequest {
        var request = try transport.makeRequest(
            path: "ai/chat", body: WorkerChatRequest(prompt: prompt, maxOutputTokens: budget.answer))
        // Una risposta lunga di Gemini può richiedere più dei 30 s della sync.
        request.timeoutInterval = 90
        return request
    }
}

extension HTTPSyncTransport {
    func send<Response: Decodable>(_ request: URLRequest, as type: Response.Type) async throws -> Response {
        try await send(request)
    }
}
