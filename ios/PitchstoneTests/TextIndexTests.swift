import Foundation
import PencilKit
import PitchstoneNotes
import PitchstoneStore
import PitchstoneSync
import Testing
import UIKit
@testable import Pitchstone

@MainActor
@Suite("Testo ricercabile", .serialized)
struct TextIndexTests {
    let model: NotesModel

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "text-\(UUID().uuidString)"))
        model = NotesModel(container: try PitchstoneSchema.container(inMemory: true), defaults: defaults, startSync: false,
                           attachmentsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    func file(_ name: String, _ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString.prefix(6)) \(name)")
        try data.write(to: url)
        return url
    }

    @Test("il testo di un PDF è ricercabile, con la pagina")
    func pdfText() async throws {
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 500)).pdfData { context in
            context.beginPage()
            "Introduzione al corso".draw(at: CGPoint(x: 20, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            context.beginPage()
            "Il teorema di Lagrange per funzioni derivabili".draw(at: CGPoint(x: 20, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        let node = try model.importDocument(at: try file("Dispensa.pdf", pdf), area: .studio)
        await model.reindexText()
        let hit = try #require(model.textMatches("lagrange")[node])
        #expect(hit.page == 1)
        #expect(hit.source == .pdf)
        #expect(model.textMatches("inesistente").isEmpty)
    }

    @Test("OCR: il testo di una foto di appunti diventa ricercabile")
    func imageOCR() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 400)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
            "Teorema di Lagrange".draw(at: CGPoint(x: 60, y: 140),
                                       withAttributes: [.font: UIFont.boldSystemFont(ofSize: 72), .foregroundColor: UIColor.black])
        }
        let node = try model.importDocument(at: try file("Lavagna.png", try #require(image.pngData())), area: .studio)
        await model.reindexText()
        let hit = try #require(model.textMatches("lagrange")[node], "OCR: \(model.extractedTexts.map(\.text))")
        #expect(hit.source == .image)
    }

    @Test("una fonte eliminata esce dall'indice; una invariata non si ricalcola")
    func removal() async throws {
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 300)).pdfData { context in
            context.beginPage()
            "Integrali impropri e convergenza".draw(at: CGPoint(x: 20, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
        }
        let node = try model.importDocument(at: try file("Integrali.pdf", pdf), area: .studio)
        await model.reindexText()
        #expect(model.textMatches("convergenza")[node] != nil)
        let attachment = try #require(model.attachments(of: node).first)
        #expect(model.textIndex.fingerprint(of: attachment.id) == attachment.sha256)
        model.trashAttachment(attachment.id)
        await model.reindexText()
        #expect(model.textMatches("convergenza").isEmpty)
    }
}
