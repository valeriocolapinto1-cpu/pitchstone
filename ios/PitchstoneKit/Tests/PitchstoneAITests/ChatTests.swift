import Foundation
import PitchstoneNotes
import PitchstoneSync
import Testing
@testable import PitchstoneAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let date = Date(timeIntervalSince1970: 1_800_000_000)

private func node(_ title: String, _ body: String, type: NodeType = .concept, area: Area = .studio) -> NodeRecord {
    NodeRecord(type: type, title: title, bodyMD: body, area: area, createdAt: date, updatedAt: date, deviceID: "test")
}

/// Vettori finti: una dimensione per ogni parola chiave del vocabolario.
private struct FakeEmbedder: TextEmbedder {
    let vocabulary = ["mitocondrio", "energia", "cellula", "derivata", "limite", "funzione"]
    func vector(for text: String) -> [Float]? {
        let words = TextSearch.normalize(text)
        return vocabulary.map { words.contains($0) ? 1 : 0 }
    }
}

private struct FakeProvider: ChatProvider {
    var kind: ChatProviderKind
    var budget: TokenBudget
    var available = true
    var error: Error?
    var answer = "Il mitocondrio produce energia [1]."
    let calls: Calls

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _prompts: [ChatPrompt] = []
        var prompts: [ChatPrompt] { lock.withLock { _prompts } }
        func add(_ prompt: ChatPrompt) { lock.withLock { _prompts.append(prompt) } }
    }

    init(kind: ChatProviderKind, available: Bool = true, error: Error? = nil) {
        self.kind = kind
        budget = kind == .local ? .local : .gemini
        self.available = available
        self.error = error
        calls = Calls()
    }

    func isAvailable() async -> Bool { available }

    func reply(to prompt: ChatPrompt) async throws -> String {
        calls.add(prompt)
        if let error { throw error }
        return answer
    }
}

@Suite struct ChunkerTests {
    @Test func splitsLongTextOnParagraphs() {
        let paragraph = String(repeating: "parola ", count: 60).trimmingCharacters(in: .whitespaces)
        let text = Array(repeating: paragraph, count: 6).joined(separator: "\n\n")
        let parts = Chunker.split(text)
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.count <= Chunker.targetLength * 3 / 2 })
        #expect(parts.joined(separator: " ").split(separator: " ").count == 360)
    }

    @Test func cutsEndlessParagraphs() {
        let parts = Chunker.split(String(repeating: "x", count: 5000))
        #expect(parts.count >= 4)
        #expect(parts.joined() == String(repeating: "x", count: 5000))
    }

    @Test func corpusExcludesHealthAndTrash() {
        var trashed = node("Cestinato", "mitocondrio cestinato")
        trashed.deletedAt = date
        let health = node("Pressione", "mitocondrio e terapia", type: .health)
        let area = node("Visita", "referto del mitocondrio", area: .salute)
        let normal = node("Cellula", "Il mitocondrio produce energia.")
        let extracted = [
            ExtractedText(nodeID: health.id, sourceID: UUID(), source: .image, text: "esami del sangue"),
            ExtractedText(nodeID: normal.id, sourceID: UUID(), source: .pdf, page: 2, text: "pagina sul mitocondrio"),
        ]
        let corpus = Chunker.corpus(nodes: [trashed, health, area, normal], extracted: extracted)
        #expect(Set(corpus.map(\.ref.nodeID)) == [normal.id])
        #expect(!corpus.contains { $0.text.contains("sangue") || $0.text.contains("referto") || $0.text.contains("terapia") })
        let pdf = corpus.first { $0.ref.kind == .pdf }
        #expect(pdf?.ref.page == 2)
        #expect(pdf?.title == "Cellula · p. 3")
    }

    @Test func savedChatsAreNotSources() {
        var saved = node("Chat: mitocondrio", "risposta [1]")
        saved.tags = [ChatTranscript.tag]
        #expect(Chunker.corpus(nodes: [saved], extracted: []).isEmpty)
    }

    @Test func emptyNodeCountsForItsTitle() {
        let chunks = Chunker.chunks(of: node("Derivata", ""))
        #expect(chunks.map(\.text) == ["Derivata"])
    }
}

@Suite struct RetrievalTests {
    let cell = node("Cellula", "Il mitocondrio produce energia per la cellula.")
    let calculus = node("Analisi", "La derivata è il limite del rapporto incrementale di una funzione.")

    @Test func ranksBySemanticAndWords() {
        let index = SemanticIndex(chunks: Chunker.corpus(nodes: [calculus, cell], extracted: []), embedder: FakeEmbedder())
        let hits = index.search("Come fa il mitocondrio a dare energia?", embedder: FakeEmbedder())
        #expect(hits.first?.ref.nodeID == cell.id)
        #expect(!hits.contains { $0.ref.nodeID == calculus.id })
    }

    @Test func worksWithoutEmbeddings() {
        let index = SemanticIndex(chunks: Chunker.corpus(nodes: [calculus, cell], extracted: []), embedder: nil)
        #expect(index.search("derivata di una funzione", embedder: nil).first?.ref.nodeID == calculus.id)
    }

    @Test func focusComesFirst() {
        let index = SemanticIndex(chunks: Chunker.corpus(nodes: [calculus, cell], extracted: []), embedder: FakeEmbedder())
        let hits = index.search("riassumi", embedder: FakeEmbedder(), focus: calculus.id)
        #expect(hits.first?.ref.nodeID == calculus.id)
    }

    @Test func reusesVectorsOfUnchangedText() {
        final class Counting: TextEmbedder, @unchecked Sendable {
            var count = 0
            func vector(for text: String) -> [Float]? { count += 1; return [1, 0] }
        }
        let embedder = Counting()
        let chunks = Chunker.corpus(nodes: [calculus, cell], extracted: [])
        let first = SemanticIndex(chunks: chunks, embedder: embedder)
        #expect(embedder.count == 2)
        _ = SemanticIndex(chunks: chunks, embedder: embedder, previous: first)
        #expect(embedder.count == 2)
    }
}

@Suite struct PromptTests {
    @Test func respectsTheLocalBudget() {
        let nodes = (0..<60).map { node("Nodo \($0)", String(repeating: "mitocondrio energia ", count: 30)) }
        let candidates = Chunker.corpus(nodes: nodes, extracted: [])
        let history = (0..<30).map { ChatMessage(role: $0 % 2 == 0 ? .user : .assistant, text: String(repeating: "storia ", count: 80)) }
        let prompt = PromptBuilder.build(
            question: "Cos'è il mitocondrio?", history: history, candidates: candidates, budget: .local, localOnly: false)
        let used = TokenBudget.estimate(prompt.system) + TokenBudget.estimate(prompt.transcript)
        #expect(used <= TokenBudget.local.total - TokenBudget.local.answer)
        #expect(!prompt.sources.isEmpty)
        #expect(prompt.sources.count < candidates.count)
        // Si tiene la parte più recente della conversazione.
        #expect(prompt.history.last == history.last)
    }

    @Test func capsHistoryAndQuestionLikeTheWorker() {
        let history = (0..<100).map { ChatMessage(role: $0 % 2 == 0 ? .user : .assistant, text: "ok") }
        let prompt = PromptBuilder.build(
            question: String(repeating: "a", count: 30_000), history: history, candidates: [], budget: .gemini, localOnly: false)
        #expect(prompt.history.count <= PromptBuilder.maxHistory)
        #expect(prompt.question.count == PromptBuilder.maxQuestionLength)
    }

    @Test func numbersSources() {
        let a = node("A", "testo a")
        let b = node("B", "testo b")
        let prompt = PromptBuilder.build(
            question: "?", history: [], candidates: Chunker.corpus(nodes: [a, b], extracted: []), budget: .gemini, localOnly: false)
        #expect(prompt.system.contains("[1] A\ntesto a"))
        #expect(prompt.system.contains("[2] B\ntesto b"))
    }
}

@Suite struct CitationTests {
    let pdfNode = UUID()
    let attachment = UUID()
    var sources: [Chunk] {
        [
            Chunk(id: "a", ref: SourceRef(nodeID: UUID()), title: "Cellula", text: "..."),
            Chunk(id: "b", ref: SourceRef(nodeID: pdfNode, kind: .pdf, sourceID: attachment, page: 4), title: "Libro · p. 5", text: "..."),
        ]
    }

    @Test func extractsValidNumbersInOrder() {
        let citations = Citations.extract(from: "Vero [2]. Anche [1, 2] e [7]. Formula [x] e [1][2].", sources: sources)
        #expect(citations.map(\.number) == [2, 1])
        #expect(citations.first?.ref.page == 4)
        #expect(Citations.extract(from: "[1]", sources: []).isEmpty)
    }

    @Test func linksOpenTheSource() throws {
        let citations = Citations.extract(from: "x [2]", sources: sources)
        let linked = Citations.linked("Vedi [2] e [9].", citations: citations)
        #expect(linked.hasPrefix("Vedi [\\[2\\]](pitchstone-source://pdf?"))
        #expect(linked.hasSuffix(" e [9]."))
        #expect(!linked.contains("[["))
        let url = try #require(URL(string: String(linked.split(separator: "(")[1].split(separator: ")")[0])))
        #expect(Citations.ref(from: url) == SourceRef(nodeID: pdfNode, kind: .pdf, sourceID: attachment, page: 4))
    }

    @Test func linkedTextRendersAsMarkdownLink() {
        let citations = Citations.extract(from: "[1]", sources: sources)
        let runs = MarkdownRenderer.render(Citations.linked("Vero [1].", citations: citations))
        guard case .paragraph(let inline)? = runs.first else {
            Issue.record("niente paragrafo")
            return
        }
        #expect(inline.contains { $0.text == "[1]" && $0.link != nil })
        #expect(MarkdownLinks.wikiTargets(in: Citations.linked("Vero [1].", citations: citations)).isEmpty)
    }
}

@Suite struct RouterTests {
    let cell = node("Cellula", "Il mitocondrio produce energia.")
    let health = node("Diario", "mitocondrio e farmaci per la pressione", type: .health)

    var index: SemanticIndex {
        SemanticIndex(chunks: Chunker.corpus(nodes: [cell, health], extracted: []), embedder: FakeEmbedder())
    }

    @Test func usesGeminiWhenOnline() async throws {
        let online = FakeProvider(kind: .gemini)
        let local = FakeProvider(kind: .local)
        let reply = try await ChatRouter(online: online, local: local)
            .answer("mitocondrio?", history: [], index: index, embedder: FakeEmbedder())
        #expect(reply.message.provider == .gemini)
        #expect(reply.message.citations.first?.ref.nodeID == cell.id)
        #expect(local.calls.prompts.isEmpty)
        #expect(reply.fallbackReason == nil)
    }

    @Test func fallsBackToLocalWhenOffline() async throws {
        let online = FakeProvider(kind: .gemini, error: URLError(.notConnectedToInternet))
        let local = FakeProvider(kind: .local)
        let reply = try await ChatRouter(online: online, local: local)
            .answer("mitocondrio?", history: [], index: index, embedder: FakeEmbedder())
        #expect(reply.message.provider == .local)
        #expect(reply.fallbackReason != nil)
        #expect(local.calls.prompts.count == 1)
        // Il prompt locale rispetta i 4.096 token.
        #expect(reply.prompt == local.calls.prompts[0])
    }

    @Test func fallsBackWhenNotConfigured() async throws {
        let reply = try await ChatRouter(online: nil, local: FakeProvider(kind: .local))
            .answer("mitocondrio?", history: [], index: index, embedder: nil)
        #expect(reply.message.provider == .local)
    }

    @Test func reportsGeminiErrorWithoutLocalModel() async {
        let online = FakeProvider(kind: .gemini, error: URLError(.timedOut))
        let local = FakeProvider(kind: .local, available: false)
        await #expect(throws: URLError.self) {
            try await ChatRouter(online: online, local: local).answer("x", history: [], index: index, embedder: nil)
        }
        await #expect(throws: ChatError.noProvider) {
            try await ChatRouter(online: nil, local: local).answer("x", history: [], index: index, embedder: nil)
        }
    }

    @Test func cancelledRequestsDoNotFallBack() async {
        let online = FakeProvider(kind: .gemini, error: URLError(.cancelled))
        let local = FakeProvider(kind: .local)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ChatRouter(online: online, local: local)
                .answer("mitocondrio?", history: [], index: index, embedder: nil)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(local.calls.prompts.isEmpty)
    }

    @Test func healthChatStaysOnDevice() async throws {
        let online = FakeProvider(kind: .gemini)
        let local = FakeProvider(kind: .local)
        let reply = try await ChatRouter(online: online, local: local)
            .answer("mitocondrio?", history: [], index: index, embedder: FakeEmbedder(), focus: health.id, localOnly: true)
        #expect(online.calls.prompts.isEmpty)
        #expect(reply.message.provider == .local)
    }

    @Test func healthNodesNeverReachAnyPrompt() async throws {
        let online = FakeProvider(kind: .gemini)
        let local = FakeProvider(kind: .local)
        let router = ChatRouter(online: online, local: local)
        _ = try await router.answer("farmaci pressione mitocondrio", history: [], index: index, embedder: FakeEmbedder())
        _ = try await router.answer("pressione", history: [], index: index, embedder: FakeEmbedder(), focus: health.id, localOnly: true)
        let prompts = online.calls.prompts + local.calls.prompts
        #expect(prompts.count == 2)
        for prompt in prompts {
            #expect(!prompt.system.contains("farmaci"))
            #expect(!prompt.sources.contains { $0.ref.nodeID == health.id })
        }
    }

    @Test func workerRequestRefusesLocalOnlyPrompts() throws {
        var prompt = PromptBuilder.build(question: "q", history: [], candidates: [], budget: .gemini, localOnly: true)
        #expect(throws: ChatError.sensitiveContent) { try WorkerChatRequest(prompt: prompt, maxOutputTokens: 100) }
        prompt.localOnly = false
        prompt.history = [ChatMessage(role: .user, text: "prima"), ChatMessage(role: .assistant, text: "risposta")]
        let request = try WorkerChatRequest(prompt: prompt, maxOutputTokens: 100)
        #expect(request.messages.map(\.role) == ["user", "assistant", "user"])
        #expect(request.messages.last?.text == "q")
    }

    @Test func workerProviderBuildsAuthenticatedRequest() throws {
        let transport = HTTPSyncTransport(
            baseURL: URL(string: "https://ai.example.com")!, credentials: AccessCredentials(clientID: "id", clientSecret: "s"))
        let provider = WorkerChatProvider(transport: transport)
        let prompt = PromptBuilder.build(question: "q", history: [], candidates: [], budget: .gemini, localOnly: false)
        let request = try provider.makeRequest(prompt)
        #expect(request.url?.path == "/ai/chat")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "id")
        let body = try JSONDecoder().decode(WorkerChatRequest.self, from: try #require(request.httpBody))
        #expect(body.maxOutputTokens == TokenBudget.gemini.answer)
    }
}

@Suite struct TranscriptTests {
    @Test func savesQuestionsAnswersAndSourceLinks() {
        let cellID = UUID()
        let citation = Citation(number: 1, ref: SourceRef(nodeID: cellID), title: "Cellula")
        let messages = [
            ChatMessage(role: .user, text: "Cos'è il mitocondrio?\nSpiega bene"),
            ChatMessage(role: .assistant, text: "La centrale della cellula [1].", citations: [citation], provider: .gemini),
        ]
        #expect(ChatTranscript.title(for: messages) == "Chat: Cos'è il mitocondrio?")
        let body = ChatTranscript.markdown(messages) { $0 == cellID ? "Cellula" : nil }
        #expect(body.contains("## Domanda\n\nCos'è il mitocondrio?"))
        #expect(body.contains("### Risposta (Gemini)"))
        #expect(body.contains("pitchstone-source://node?node=\(cellID.uuidString)"))
        #expect(MarkdownLinks.wikiTargets(in: body) == ["Cellula"])
    }

    @Test func longTitlesAreShortened() {
        let title = ChatTranscript.title(for: [ChatMessage(role: .user, text: String(repeating: "a", count: 100))])
        #expect(title.count == "Chat: ".count + 60)
    }
}
