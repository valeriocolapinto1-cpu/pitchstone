import Foundation
import PitchstoneSync
import Testing
@testable import PitchstoneAI

private let date = Date(timeIntervalSince1970: 1_800_000_000)

private func note(_ title: String, _ body: String, area: Area = .studio) -> NodeRecord {
    NodeRecord(type: .concept, title: title, bodyMD: body, area: area, createdAt: date, updatedAt: date, deviceID: "t")
}

private struct Scripted: ChatProvider {
    var kind: ChatProviderKind
    var budget: TokenBudget { kind == .local ? .local : .gemini }
    var available = true
    var answer: String

    func isAvailable() async -> Bool { available }
    func reply(to prompt: ChatPrompt) async throws -> String { answer }
}

@Suite struct NoteAnalysisTests {
    static let sample = note("Derivata", """
    La derivata è il limite del rapporto incrementale. Si usa per studiare la monotonia
    di una funzione e trovare massimi e minimi. Il teorema di Lagrange la collega
    all'incremento della funzione. Ne ha parlato la prof.ssa Bianchi a lezione.
    """)

    static let answer = """
    Ecco il risultato:
    ```json
    {"nodes":[
      {"title":"Rapporto incrementale","type":"concept","summary":"Quoziente della variazione."},
      {"title":"Teorema di Lagrange","type":"concept","summary":"Teorema del valor medio."},
      {"title":"Limiti","type":"concept","summary":"Già nel grafo."},
      {"title":"Prof.ssa Bianchi","type":"person","summary":"Docente di Analisi."},
      {"title":"Derivata","type":"concept","summary":"Se stesso."},
      {"title":"Terapia","type":"health","summary":"Tipo non ammesso."}
    ],"links":[
      {"from":"Teorema di Lagrange","to":"Rapporto incrementale"},
      {"from":"Rapporto incrementale","to":"Limiti"},
      {"from":"Prof.ssa Bianchi","to":"Derivata"},
      {"from":"Inventato","to":"Limiti"},
      {"from":"Limiti","to":"Limiti"}
    ]}
    ```
    """

    @Test func sampleNoteProducesNodesAndLinks() throws {
        let graph = try #require(NoteAnalysis.parse(Self.answer))
        #expect(graph.nodes.first { $0.title == "Terapia" }?.type == .concept)
        let plan = NoteAnalysis.plan(graph, source: Self.sample, existingTitles: ["Limiti", "Derivata"])
        #expect(plan.create.map(\.title) == ["Rapporto incrementale", "Teorema di Lagrange"])
        // La persona e il possibile dato di salute aspettano la conferma.
        #expect(plan.confirm.map(\.node.title) == ["Prof.ssa Bianchi", "Terapia"])
        #expect(plan.confirm.map(\.reason) == [.person, .health])
        let pairs = Set(plan.links.map { Set([$0.from, $0.to]) })
        #expect(pairs == [
            ["Derivata", "Rapporto incrementale"], ["Derivata", "Teorema di Lagrange"], ["Derivata", "Limiti"],
            ["Teorema di Lagrange", "Rapporto incrementale"], ["Rapporto incrementale", "Limiti"],
        ])
    }

    @Test func rejectsGarbage() {
        #expect(NoteAnalysis.parse("non so") == nil)
        #expect(NoteAnalysis.parse("{ rotto") == nil)
        #expect(NoteAnalysis.parse(#"{"nodes":[{"title":""}]}"#)?.nodes.isEmpty == true)
    }

    @Test func capsTheNumberOfNodes() throws {
        let nodes = (0..<20).map { #"{"title":"Concetto \#($0)","type":"concept","summary":""}"# }.joined(separator: ",")
        let graph = try #require(NoteAnalysis.parse(#"{"nodes":[\#(nodes)],"links":[]}"#))
        #expect(NoteAnalysis.plan(graph, source: Self.sample, existingTitles: []).create.count == NoteAnalysis.maxNodes)
    }

    @Test func usesTheLocalModelFirstAndGeminiOnlyOnRequest() async throws {
        let local = Scripted(kind: .local, answer: "nessun json")
        let online = Scripted(kind: .gemini, answer: Self.answer)
        await #expect(throws: ChatError.invalidAnswer) {
            try await NoteAnalysis.run(Self.sample, existingTitles: [], local: local, online: online, allowOnline: false)
        }
        let plan = try await NoteAnalysis.run(Self.sample, existingTitles: [], local: local, online: online, allowOnline: true)
        #expect(!plan.create.isEmpty)
        await #expect(throws: ChatError.noProvider) {
            try await NoteAnalysis.run(Self.sample, existingTitles: [], local: nil, online: online, allowOnline: false)
        }
    }

    @Test func neverAnalyzesHealthData() async {
        let online = Scripted(kind: .gemini, answer: Self.answer)
        let diary = note("Oggi", "Mi hanno diagnosticato l'emicrania, devo prendere 5 mg di triptano.")
        await #expect(throws: ChatError.sensitiveContent) {
            try await NoteAnalysis.run(diary, existingTitles: [], local: online, online: online, allowOnline: true)
        }
        await #expect(throws: ChatError.sensitiveContent) {
            try await NoteAnalysis.run(note("Visita", "testo", area: .salute), existingTitles: [], local: online, online: online, allowOnline: true)
        }
    }

    @Test func dismissedSignalsAllowAnalysis() async throws {
        let online = Scripted(kind: .gemini, answer: Self.answer)
        let text = note("Oggi", "Mi hanno diagnosticato l'emicrania, devo prendere 5 mg di triptano.")
        let signals = HealthDetector.assess(text.title + "\n" + text.bodyMD).signals
        let plan = try await NoteAnalysis.run(
            text, existingTitles: [], local: online, online: nil, allowOnline: false, dismissedSignals: signals)
        #expect(!plan.create.isEmpty)
    }

    @Test func longNotesFitTheLocalModel() {
        let long = note("Lungo", String(repeating: "parola ", count: 3000))
        let titles = (0..<150).map { "Un titolo esistente piuttosto lungo \($0)" }
        let prompt = NoteAnalysis.prompt(for: long, existingTitles: titles, budget: .local)
        let used = TokenBudget.estimate(prompt.system) + TokenBudget.estimate(prompt.transcript)
        #expect(used <= TokenBudget.local.total - TokenBudget.local.answer)
        #expect(prompt.question.contains("Un titolo esistente piuttosto lungo 0"))
    }

    @Test func promptHasNoSourcesSection() {
        let prompt = NoteAnalysis.prompt(for: Self.sample, existingTitles: ["Limiti"])
        #expect(!prompt.system.contains("FONTI"))
        #expect(prompt.question.contains("TITOLI GIÀ ESISTENTI: Limiti"))
    }

    @Test func corpusSkipsSuspects() {
        let a = note("A", "testo a")
        let b = note("B", "testo b")
        #expect(Chunker.corpus(nodes: [a, b], extracted: [], excluding: [b.id]).map(\.ref.nodeID) == [a.id])
    }
}
