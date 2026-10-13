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
    // Nota di iCloud non ancora scaricata: un segnaposto nascosto.
    try Data().write(to: copy.appendingPathComponent("Progetti/.Bozza.md.icloud"))
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
        #expect(contents.skipped == [.init(path: "Progetti/Bozza.md", reason: .notDownloaded)])
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
        #expect(limiti.body.hasSuffix("```yaml\naliases: [Lim, limite]\ncreated: 2024-03-01\n```\n"), "alias e date restano nella nota")
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
        #expect(!pitchstone.body.contains("```yaml"), "area, tipo e tag sono diventati proprietà del nodo")

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
        #expect(again.skipped.filter { if case .alreadyExists = $0.reason { true } else { false } }.count == 7)
        _ = VaultImporter.apply(again, to: repository, store: store)
        #expect(store.allNodes().count == 7)
    }
}

@Suite("Import di un vault grande")
struct LargeVaultTests {
    @MainActor
    @Test("2000 note con 5 link ciascuna: piano e applicazione in pochi secondi")
    func largeVault() {
        let files = (0..<2000).map { i in
            VaultFile(path: "Cartella \(i % 20)/Nota \(i).md",
                      text: "Testo della nota \(i) #tag\(i % 7)\n" + (1...5).map { "[[Nota \((i * 7 + $0 * 13) % 2000)]]" }.joined(separator: " "))
        }
        let start = Date()
        let plan = ObsidianImport.plan(VaultContents(notes: files), defaultArea: .studio, existingTitles: [])
        let store = InMemoryStore()
        let result = VaultImporter.apply(plan, to: Repository(store: store, deviceID: "ipad"), store: store)
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.created.count == 2000)
        #expect(result.links == store.allEdges().count)
        #expect(result.links > 9000)
        #expect(elapsed < 10, "piano e applicazione: \(elapsed) s")
    }
}

@Suite("Traduzione delle note Obsidian")
struct ConversionTests {
    @Test("frontmatter: liste in linea e a righe, virgolette, nessun frontmatter")
    func frontmatter() {
        let (front, body) = Frontmatter.split("---\ntags:\n  - uno\n  - \"due\"\naliases: ['A', \"Rossi, Mario\"]\nfonte: libro\n---\n\nTesto")
        #expect(front.strings("tags") == ["uno", "due"])
        #expect(front.strings("aliases") == ["A", "Rossi, Mario"], "la virgola tra virgolette non separa")
        #expect(front.lines(excluding: ["tags"]) == ["aliases: ['A', \"Rossi, Mario\"]", "fonte: libro"])
        #expect(body == "Testo")

        let plain = Frontmatter.split("Testo\n---\naltro")
        #expect(plain.0 == Frontmatter())
        #expect(plain.body == "Testo\n---\naltro")

        let unclosed = Frontmatter.split("---\ntitolo: x\nmai chiuso")
        #expect(unclosed.body == "---\ntitolo: x\nmai chiuso", "senza chiusura non è frontmatter")

        let rule = Frontmatter.split("---\nUna riga di testo\nAltra riga\n---\nCorpo")
        #expect(rule.body == "---\nUna riga di testo\nAltra riga\n---\nCorpo", "righe orizzontali, non proprietà: niente si perde")
    }

    @Test("tag: in testo, non nel codice, non i titoli, non le ancore e non i numeri")
    func tags() {
        let tags = ObsidianImport.inlineTags("# Titolo\n#uno e [link](#ancora) e x#tre e #4 e #v2 e `#codice`\n```\n#blocco\n```\n#materia/sotto")
        #expect(tags == ["uno", "v2", "materia/sotto"])
    }

    @Test("codice dentro una lista e codice indentato restano intatti")
    func codeInLists() throws {
        let result = plan([
            "A.md": "- voce\n\n    ```\n    [[Sub/B]] #codetag\n    ```\n\nTesto\n\n    [[Sub/B]] indentato\n\n<!-- [[Sub/B]] -->",
            "Sub/B.md": "",
        ])
        let note = try #require(result.note("A"))
        #expect(note.body.contains("    [[Sub/B]] #codetag"))
        #expect(note.body.contains("    [[Sub/B]] indentato"))
        #expect(note.body.contains("<!-- [[Sub/B]] -->"))
        #expect(note.tags.isEmpty)
        #expect(note.links.isEmpty, "l'app non crea archi dal codice: neanche l'import")
    }

    @Test("salute: tag annidati, cartelle a ogni livello, vince sull'area dichiarata")
    func healthDetection() {
        let result = plan([
            "Personale/Salute/Visita.md": "Pressione ok.",
            "Diario/Oggi.md": "Visita #salute/visite fatta.",
            "Note/Analisi.md": "---\narea: studio\ntags: [health/esami]\n---\nValori del sangue.",
            "Note/Cura.md": "---\ntype: salute\n---\n",
            "Note/Normale.md": "#salutare non è salute",
        ])
        #expect(result.note("Visita")?.area == .salute)
        #expect(result.note("Oggi")?.area == .salute)
        #expect(result.note("Analisi")?.area == .salute)
        #expect(result.note("Cura")?.area == .salute)
        #expect(result.note("Normale")?.area == .studio)
    }

    @Test("proprietà non riconosciute restano; il recinto resiste ai backtick")
    func unknownProperties() throws {
        let result = plan(["N.md": "---\narea: università\ntype: lezione\nnota: usa ``` qui\n---\nTesto"])
        let note = try #require(result.note("N"))
        #expect(note.area == .studio)
        #expect(note.type == .concept)
        #expect(note.body == "Testo\n\n````yaml\narea: università\ntype: lezione\nnota: usa ``` qui\n````\n")
    }

    @Test("embed di una nota con il punto nel nome e titoli con #")
    func dottedAndHashTitles() throws {
        let result = plan([
            "Lezione 3.2.md": "", "C#.md": "",
            "Indice.md": "![[Lezione 3.2]] e [[C#]] e [[C#|linguaggio]] e ![[foto.jpeg]]",
        ])
        let note = try #require(result.note("Indice"))
        #expect(note.body == "[[Lezione 3.2]] e [[C#]] e [[C#|linguaggio]] e ![[foto.jpeg]]")
        #expect(note.links == ["Lezione 3.2", "C#"])
        #expect(result.unresolvedLinks.isEmpty)
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
