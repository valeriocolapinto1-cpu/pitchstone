import Foundation
import PencilKit
import PitchstoneStore
import PitchstoneSync
import Testing
import UIKit
@testable import Pitchstone

@MainActor
@Suite("Allegati nell'app", .serialized)
struct AppAttachmentTests {
    let model: NotesModel
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("allegati-\(UUID().uuidString)")

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "attachments-\(UUID().uuidString)"))
        model = NotesModel(container: try PitchstoneSchema.container(inMemory: true), defaults: defaults,
                           startSync: false, attachmentsDirectory: directory)
    }

    func samplePDF(pages: Int = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Prova \(UUID().uuidString.prefix(4)).pdf")
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
            for i in 0..<pages {
                context.beginPage()
                "Pagina \(i + 1): teorema di Lagrange".draw(at: CGPoint(x: 20, y: 40), withAttributes: nil)
            }
        }
        try data.write(to: url)
        return url
    }

    @Test("un PDF importato diventa un nodo con l'allegato; il file resta nell'app")
    func importPDF() throws {
        let id = try model.importDocument(at: try samplePDF(pages: 3), area: .studio)
        let attachment = try #require(model.attachments(of: id).first)
        #expect(attachment.kind == .pdf)
        #expect(attachment.pageCount == 3)
        #expect(attachment.partCount == 1)
        #expect(model.files.exists(attachment.id))
        #expect(model.node(id)?.title.hasPrefix("Prova") == true)
        #expect(model.store.pendingChanges().contains { $0.entity == .attachment && $0.id == attachment.id })
    }

    @Test("un file che non è un PDF né un'immagine non si allega")
    func rejectsOtherFiles() throws {
        let node = model.createNode(title: "Appunti")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("note.txt")
        try "testo".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: AttachmentImportError.self) { try model.attach(fileAt: url, to: node.id) }
        #expect(model.attachments(of: node.id).isEmpty)
    }

    @Test("annotazioni: salvate per pagina, due strati si uniscono senza perdere tratti")
    func annotations() throws {
        let id = try model.importDocument(at: try samplePDF(), area: .studio)
        let attachment = try #require(model.attachments(of: id).first)
        func stroke(_ x: Double) -> PKStroke {
            PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: [
                PKStrokePoint(location: CGPoint(x: x, y: 10), timeOffset: 0, size: CGSize(width: 2, height: 2),
                              opacity: 1, force: 1, azimuth: 0, altitude: 1),
                PKStrokePoint(location: CGPoint(x: x + 50, y: 10), timeOffset: 0.1, size: CGSize(width: 2, height: 2),
                              opacity: 1, force: 1, azimuth: 0, altitude: 1),
            ], creationDate: Date()))
        }
        let first = InkCodec.data(from: PKDrawing(strokes: [stroke(10)]))
        let layer = try #require(model.savePDFAnnotation(first, attachment: attachment, page: 1, layer: nil, loadedFrom: Data()))
        #expect(model.pdfAnnotationLayers(attachment.id, page: 1).map(\.id) == [layer])
        #expect(model.pdfAnnotationLayers(attachment.id, page: 0).isEmpty)
        #expect(model.inkPages(of: id).isEmpty, "le annotazioni non sono pagine a penna del nodo")

        // Un secondo strato (come dopo un conflitto) si unisce nel primo.
        let second = InkCodec.data(from: PKDrawing(strokes: [stroke(100)]))
        let other = try #require(model.savePDFAnnotation(second, attachment: attachment, page: 1, layer: nil, loadedFrom: Data()))
        #expect(other != layer)
        let layers = model.pdfAnnotationLayers(attachment.id, page: 1)
        var merged = PKDrawing()
        for l in layers { merged.append(try InkCodec.drawing(from: l.inkData)) }
        _ = model.mergePDFLayers(layers, into: InkCodec.data(from: merged))
        let remaining = model.pdfAnnotationLayers(attachment.id, page: 1)
        #expect(remaining.count == 1)
        #expect(try InkCodec.drawing(from: remaining[0].inkData).strokes.count == 2)
    }

    @Test("un nodo dal testo selezionato è collegato al nodo del PDF")
    func nodeFromSelection() throws {
        let id = try model.importDocument(at: try samplePDF(), area: .progetti)
        let attachment = try #require(model.attachments(of: id).first)
        let created = model.createNode(fromQuote: "Teorema di Lagrange\nesiste c in (a, b)", attachment: attachment, page: 1)
        let node = try #require(model.node(created))
        #expect(node.title == "Teorema di Lagrange")
        #expect(node.area == .progetti)
        #expect(node.bodyMD.contains("> esiste c in (a, b)"))
        #expect(node.bodyMD.contains("pagina 2"))
        #expect(model.edges.contains { $0.sourceID == created && $0.targetID == id && $0.deletedAt == nil })
    }
}
