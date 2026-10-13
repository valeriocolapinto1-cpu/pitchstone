import Foundation
import Testing
@testable import PitchstoneImport
@testable import PitchstoneSync

/// Il vault di esempio del repository, copiato in una cartella temporanea con in più
/// una cartella `.trash` che non deve essere importata.
func sampleVault() throws -> URL {
    let source = try #require(Bundle.module.url(forResource: "VaultDiEsempio", withExtension: nil))
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: source, to: copy)
    let trash = copy.appendingPathComponent(".trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    try "Nota cancellata [[Limiti]]".write(to: trash.appendingPathComponent("Vecchia.md"), atomically: true, encoding: .utf8)
    return copy
}

func plan(_ files: [String: String], area: Area = .studio, existing: [String] = []) -> VaultImportPlan {
    ObsidianImport.plan(
        VaultContents(notes: files.map { VaultFile(path: $0.key, text: $0.value) }),
        defaultArea: area, existingTitles: existing)
}

extension VaultImportPlan {
    func note(_ title: String) -> Note? { notes.first { $0.title == title } }
}

@Suite("Import del vault di esempio")
struct SampleVaultTests {
    @Test("lettura: note, allegati elencati, cartelle nascoste escluse")
    func read() throws {
        let contents = try VaultReader.read(at: try sampleVault())
        #expect(contents.notes.map(\.path) == [
            "Archivio/Limiti.md", "Idee sparse.md", "Progetti/Pitchstone.md", "Salute/Visita.md",
            "Studio/Analisi 1.md", "Studio/Analisi/Derivate.md", "Studio/Analisi/Limiti.md",
        ])
        #expect(contents.otherFiles == ["allegati/dispensa.pdf"])
        #expect(contents.skipped.isEmpty)
    }

    @Test("piano: titoli, link riscritti, tag, aree e tipi")
    func planSample() throws {
        let result = ObsidianImport.plan(try VaultReader.read(at: try sampleVault()), defaultArea: .interessi, existingTitles: [])
        #expect(result.notes.map(\.title) == [
            "Idee sparse", "Limiti", "Pitchstone", "Visita", "Analisi 1", "Derivate", "Limiti (Analisi)",
        ])

        let limiti = try #require(result.note("Limiti (Analisi)"))
        #expect(limiti.body.hasPrefix("# Limiti\n"))
        #expect(limiti.body.contains("Vedi [[Derivate]] e [[Analisi 1|il programma]]."))
        #expect(limiti.body.contains("x = \"[[Derivate]]\"  # non è un link"), "il codice resta com'è")
        #expect(limiti.body.hasSuffix("```yaml\ncreated: 2024-03-01\n```\n"), "le proprietà non usate restano nella nota")
        #expect(!limiti.body.contains("aliases"))
        #expect(limiti.tags == ["analisi", "esame", "teorema"])
        #expect(limiti.area == .studio)
        #expect(limiti.links == ["Derivate", "Analisi 1"])

        let derivate = try #require(result.note("Derivate"))
        #expect(derivate.body.contains("dal [[Limiti (Analisi)|limite]] del rapporto"), "alias della nota")
        #expect(derivate.body.contains("a [[Limiti (Analisi)|Limiti]] e a [[Integrali]]"), "percorso completo")
        #expect(derivate.body.contains("Inline `[[Limiti]]` resta codice."))
        #expect(derivate.links == ["Limiti (Analisi)"])

        let analisi = try #require(result.note("Analisi 1"))
        #expect(analisi.type == .exam)
        #expect(analisi.body.contains("- [[Limiti]]\n- [[Derivate|derivate e applicazioni]]"))
        #expect(analisi.body.contains("| Limiti | [[Limiti\\|vedi]] |"), "il separatore nelle tabelle resta \\|")
        #expect(analisi.links == ["Limiti", "Derivate"])

        let pitchstone = try #require(result.note("Pitchstone"))
        #expect(pitchstone.area == .progetti)
        #expect(pitchstone.type == .project)
        #expect(pitchstone.tags == ["app"])
        #expect(pitchstone.body.contains("![[schema.png]]"), "gli allegati restano finché non si importano")
        #expect(pitchstone.body.contains("\n[[Limiti]]"), "l'embed di una nota diventa un link")

        #expect(result.note("Visita")?.area == .salute, "cartella Salute")
        #expect(result.note("Idee sparse")?.area == .salute, "tag #salute: resta sul dispositivo")
        #expect(result.unresolvedLinks == ["Integrali", "Obsidian"])
        #expect(result.otherFiles == ["allegati/dispensa.pdf"])
    }

    @MainActor
    @Test("applicazione: nodi, archi, e niente salute nell'outbox")
    func apply() throws {
        let store = InMemoryStore()
        let repository = Repository(store: store, deviceID: "ipad")
        let plan = ObsidianImport.plan(try VaultReader.read(at: try sampleVault()), defaultArea: .studio, existingTitles: [])
        let result = VaultImporter.apply(plan, to: repository, store: store)

        #expect(result.created.count == 7)
        #expect(store.allNodes().count == 7)
        let byTitle = Dictionary(uniqueKeysWithValues: store.allNodes().map { ($0.title, $0.id) })
        func linked(_ a: String, _ b: String) -> Bool {
            store.allEdges().contains { $0.sourceID == byTitle[a] && $0.targetID == byTitle[b] && $0.kind == .link && $0.deletedAt == nil }
        }
        #expect(linked("Derivate", "Limiti (Analisi)"))
        #expect(linked("Limiti (Analisi)", "Derivate"))
        #expect(linked("Analisi 1", "Limiti"))
        #expect(linked("Pitchstone", "Analisi 1"))
        #expect(linked("Visita", "Pitchstone"))
        #expect(store.allEdges().count == 8)
        #expect(result.links == 8)

        let pending = Set(store.pendingChanges().map(\.id))
        #expect(!pending.contains(try #require(byTitle["Visita"])))
        #expect(!pending.contains(try #require(byTitle["Idee sparse"])))
        #expect(pending.contains(try #require(byTitle["Pitchstone"])))
        let healthEdge = try #require(store.allEdges().first { $0.sourceID == byTitle["Visita"] })
        #expect(!pending.contains(healthEdge.id), "l'arco verso la salute resta locale")
    }

    @MainActor
    @Test("reimportare lo stesso vault non duplica nulla")
    func reimport() throws {
        let store = InMemoryStore()
        let repository = Repository(store: store, deviceID: "ipad")
        let contents = try VaultReader.read(at: try sampleVault())
        _ = VaultImporter.apply(ObsidianImport.plan(contents, defaultArea: .studio, existingTitles: []), to: repository, store: store)

        let again = ObsidianImport.plan(contents, defaultArea: .studio, existingTitles: store.allNodes().map(\.title))
        #expect(again.notes.isEmpty)
        #expect(again.skipped.count == 7)
        _ = VaultImporter.apply(again, to: repository, store: store)
        #expect(store.allNodes().count == 7)
    }
}

@Suite("Traduzione delle note Obsidian")
struct ConversionTests {
    @Test("frontmatter: liste in linea e a righe, virgolette, nessun frontmatter")
    func frontmatter() {
        let (front, body) = Frontmatter.split("---\ntags:\n  - uno\n  - \"due\"\naliases: ['A', B]\nfonte: libro\n---\n\nTesto")
        #expect(front.values["tags"] == ["uno", "due"])
        #expect(front.values["aliases"] == ["A", "B"])
        #expect(front.otherLines == ["fonte: libro"])
        #expect(body == "Testo")

        let plain = Frontmatter.split("Testo\n---\naltro")
        #expect(plain.0 == Frontmatter())
        #expect(plain.body == "Testo\n---\naltro")

        let unclosed = Frontmatter.split("---\ntitolo: x\nmai chiuso")
        #expect(unclosed.body == "---\ntitolo: x\nmai chiuso", "senza chiusura non è frontmatter")
    }

    @Test("tag: in testo, non nel codice, non i titoli, non le ancore e non i numeri")
    func tags() {
        let tags = ObsidianImport.inlineTags("# Titolo\n#uno e (#due) e x#tre e #4 e #v2 e `#codice`\n```\n#blocco\n```\n#materia/sotto")
        #expect(tags == ["uno", "due", "v2", "materia/sotto"])
    }

    @Test("titoli doppi: la cartella tra parentesi; nodi esistenti non duplicati")
    func duplicates() throws {
        let result = plan([
            "a/Nota.md": "x", "b/Nota.md": "y", "c/Nota.md": "z", "Esistente.md": "[[Nota]] [[esistente]]",
        ], existing: ["Esistènte"])
        #expect(Set(result.notes.map(\.title)) == ["Nota", "Nota (b)", "Nota (c)"])
        #expect(result.skipped == [.init(path: "Esistente.md", reason: .alreadyExists(title: "Esistènte"))])
    }

    @Test("link a nodi già nell'app e link irrisolti")
    func existingLinks() throws {
        let result = plan(["Nuova.md": "Vedi [[Derivate]], [[Mai scritta|qui]] e [[#Sezione]]."], existing: ["Derivate"])
        let note = try #require(result.note("Nuova"))
        #expect(note.body == "Vedi [[Derivate]], [[Mai scritta|qui]] e Sezione.")
        #expect(note.links == ["Derivate"])
        #expect(result.unresolvedLinks == ["Mai scritta"])
    }

    @Test("area: frontmatter, poi cartella, poi quella scelta; tipo in italiano o inglese")
    func areaAndType() {
        let result = plan([
            "Lavoro/A.md": "---\narea: Interessi\ntype: persona\n---\n",
            "Lavoro/B.md": "---\ntipo: idea\n---\n",
            "Varie/C.md": "",
            "People/D.md": "---\ntags: [health]\n---\n",
        ], area: .progetti)
        #expect(result.note("A")?.area == .interessi)
        #expect(result.note("A")?.type == .person)
        #expect(result.note("B")?.area == .lavoro)
        #expect(result.note("B")?.type == .idea)
        #expect(result.note("C")?.area == .progetti)
        #expect(result.note("C")?.type == .concept)
        #expect(result.note("D")?.area == .salute, "il tag salute vince sulla cartella")
    }

    @Test("a capo di Windows e BOM")
    func lineEndings() {
        let result = plan(["N.md": "\u{FEFF}---\r\ntags: x\r\n---\r\nRiga [[Altra]]\r\n", "Altra.md": ""])
        #expect(result.note("N")?.tags == ["x"])
        #expect(result.note("N")?.body == "Riga [[Altra]]\n")
    }
}
