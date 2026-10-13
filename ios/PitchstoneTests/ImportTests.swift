import Foundation
import PitchstoneImport
import PitchstoneStore
import PitchstoneSync
import Testing
@testable import Pitchstone

@MainActor
@Suite("Import nell'app", .serialized)
struct AppImportTests {
    let model: NotesModel

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "import-\(UUID().uuidString)"))
        model = NotesModel(container: try PitchstoneSchema.container(inMemory: true), defaults: defaults, startSync: false)
    }

    @Test("le note importate entrano nel grafo, anche dai link scritti prima nell'app")
    func importIntoModel() throws {
        let existing = model.createNode(title: "Appunti di analisi")
        model.update(existing.id) { $0.bodyMD = "Da importare: [[Limiti]]." }
        #expect(model.edges.isEmpty)

        let contents = VaultContents(notes: [
            VaultFile(path: "Studio/Limiti.md", text: "---\ntags: [analisi]\n---\nVedi [[Derivate]] e [[Appunti di analisi]]."),
            VaultFile(path: "Studio/Derivate.md", text: "Nascono dai [[Limiti]]."),
        ])
        let plan = model.importPlan(contents, area: .interessi)
        #expect(plan.notes.map(\.title) == ["Derivate", "Limiti"])
        let result = model.importVault(plan)
        #expect(result.created.count == 2)

        let limiti = try #require(model.node(titled: "Limiti"))
        let derivate = try #require(model.node(titled: "Derivate"))
        #expect(limiti.tags == ["analisi"])
        #expect(limiti.area == .studio)
        func linked(_ a: UUID, _ b: UUID) -> Bool {
            model.edges.contains { $0.sourceID == a && $0.targetID == b && $0.kind == .link && $0.deletedAt == nil }
        }
        #expect(linked(limiti.id, derivate.id))
        #expect(linked(derivate.id, limiti.id))
        #expect(linked(limiti.id, existing.id), "link verso una nota già nell'app")
        #expect(linked(existing.id, limiti.id), "la nota già nell'app riceve l'arco verso quella importata")

        // Una seconda volta non crea nulla.
        #expect(model.importPlan(contents, area: .interessi).notes.isEmpty)
    }
}
