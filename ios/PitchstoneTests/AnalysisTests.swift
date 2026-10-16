import Foundation
import PitchstoneAI
import PitchstoneStore
import PitchstoneSync
import Testing
@testable import Pitchstone

private struct Scripted: ChatProvider {
    let kind: ChatProviderKind
    var budget: TokenBudget { kind == .local ? .local : .gemini }
    let answer: String
    func isAvailable() async -> Bool { true }
    func reply(to prompt: ChatPrompt) async throws -> String { answer }
}

@MainActor
@Suite("Analisi automatica", .serialized)
struct AnalysisTests {
    let model: NotesModel

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "analysis-\(UUID().uuidString)"))
        model = NotesModel(container: try PitchstoneSchema.container(inMemory: true), defaults: defaults, startSync: false,
                           attachmentsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    static let answer = """
    {"nodes":[{"title":"Teorema di Lagrange","type":"concept","summary":"Valor medio."},
    {"title":"Limiti","type":"concept","summary":""},
    {"title":"Prof.ssa Bianchi","type":"person","summary":"Docente."}],
    "links":[{"from":"Teorema di Lagrange","to":"Limiti"}]}
    """

    @Test("un appunto produce nodi e collegamenti; la persona aspetta la conferma")
    func analyzeCreatesNodesAndAsksForPeople() async throws {
        let limits = model.createNode(title: "Limiti", body: "Base dell'analisi.")
        let derivative = model.createNode(title: "Derivata", body: "La derivata e il teorema di Lagrange, spiegati dalla prof.ssa Bianchi.")
        model.analysisProvidersOverride = (Scripted(kind: .local, answer: Self.answer), nil)

        let outcome = try await model.analyze(derivative.id, allowOnline: false)
        #expect(outcome.created == ["Teorema di Lagrange"])
        #expect(outcome.pending == 1)
        let lagrange = try #require(model.node(titled: "Teorema di Lagrange"))
        #expect(lagrange.area == .studio)
        func linked(_ a: UUID, _ b: UUID) -> Bool {
            model.edges.contains { $0.kind == .ai && Set([$0.sourceID, $0.targetID]) == Set([a, b]) }
        }
        #expect(linked(derivative.id, lagrange.id))
        #expect(linked(derivative.id, limits.id))
        #expect(linked(lagrange.id, limits.id))
        #expect(model.node(titled: "Prof.ssa Bianchi") == nil)

        let proposal = try #require(model.pendingProposals[derivative.id]?.first)
        let person = model.confirmProposal(proposal, from: derivative.id)
        #expect(model.node(person)?.type == .person)
        #expect(model.node(person)?.area == .persone)
        #expect(model.pendingProposals[derivative.id] == nil)

        // Rianalizzare non crea doppioni.
        _ = try await model.analyze(derivative.id, allowOnline: false)
        #expect(model.activeNodes.filter { $0.title == "Teorema di Lagrange" }.count == 1)
        #expect(model.pendingProposals[derivative.id] == nil)
    }

    @Test("un appunto che sembra di salute resta fuori da sync, chat e analisi finché l'utente non sceglie")
    func suspectedHealthNeedsConfirmation() async throws {
        let diary = model.createNode(title: "Oggi", body: "Visita dal cardiologo: pressione 150/95, devo prendere ramipril 5 mg.")
        #expect(model.healthSuspects.contains(diary.id))
        #expect(model.isHeld(try #require(model.node(diary.id))))
        #expect(model.isSensitive(diary.id))
        let index = await model.currentChatIndex()
        #expect(!index.chunks.contains { $0.ref.nodeID == diary.id })
        model.analysisProvidersOverride = (Scripted(kind: .local, answer: Self.answer), nil)
        await #expect(throws: ChatError.sensitiveContent) { try await model.analyze(diary.id, allowOnline: false) }

        // "Non lo è": libero, finché non compare un segnale nuovo.
        model.dismissHealth(diary.id)
        #expect(!model.healthSuspects.contains(diary.id))
        model.update(diary.id) { $0.bodyMD += "\nMi hanno diagnosticato l'ipertensione." }
        #expect(model.healthSuspects.contains(diary.id))
    }

    @Test("un appunto sospetto resta trattenuto anche nel cestino")
    func trashedSuspectStaysHeld() throws {
        let diary = model.createNode(title: "Oggi", body: "Mi hanno diagnosticato l'emicrania.")
        model.trash(diary.id)
        #expect(model.isHeld(try #require(model.node(diary.id))))
    }

    @Test("una scelta \"Non lo è\" permette l'analisi")
    func dismissedNodesCanBeAnalyzed() async throws {
        let diary = model.createNode(title: "Lezione", body: "Il mio medico di base, il prof. Rossi, insegna farmacologia: oggi 5 mg di esempi.")
        #expect(model.healthSuspects.contains(diary.id))
        model.dismissHealth(diary.id)
        model.analysisProvidersOverride = (Scripted(kind: .local, answer: Self.answer), nil)
        let outcome = try await model.analyze(diary.id, allowOnline: false)
        #expect(!outcome.created.isEmpty)
    }

    @Test("confermare la salute: un nodo mai sincronizzato cambia area")
    func confirmHealthLocalNode() throws {
        let diary = model.createNode(title: "Oggi", body: "Ho la febbre, 38,5°, e mal di gola.")
        #expect(model.healthSuspects.contains(diary.id))
        #expect(model.confirmHealth(diary.id) == diary.id)
        let node = try #require(model.node(diary.id))
        #expect(Privacy.isSensitive(node))
        #expect(!model.healthSuspects.contains(diary.id))
    }

    @Test("confermare la salute: un nodo già sincronizzato viene copiato e svuotato")
    func confirmHealthSyncedNode() throws {
        let note = model.createNode(title: "Appunti", body: "Lezione di oggi.")
        var synced = try #require(model.store.node(note.id))
        synced.version = 1
        model.store.saveNode(synced)
        model.update(note.id) { $0.bodyMD = "Mi hanno diagnosticato l'emicrania, devo prendere 5 mg di triptano." }
        #expect(model.healthSuspects.contains(note.id))

        let page = try #require(model.createInkPage(in: note.id, background: .blank))
        let copy = try #require(model.confirmHealth(note.id))
        #expect(model.store.inkPage(page.id)?.nodeID == copy)
        #expect(copy != note.id)
        let moved = try #require(model.node(copy))
        #expect(Privacy.isSensitive(moved))
        #expect(moved.bodyMD.contains("emicrania"))
        let original = try #require(model.node(note.id))
        #expect(original.deletedAt != nil)
        #expect(!original.bodyMD.contains("emicrania"))
        #expect(!original.title.contains("Appunti") || original.bodyMD.isEmpty)
    }
}
