import Foundation
import PencilKit
import PitchstoneStore
import PitchstoneSync
import Testing

// Qui e non nel pacchetto: PencilKit salva il proprio stato nelle preferenze
// dell'app, e nel runner di `swift test` su macOS (senza bundle id) va in crash.
@Suite("Serializzazione del disegno")
struct InkCodecTests {
    /// Un tratto a penna con punti, pressione e inclinazione, come quelli della Pencil.
    static func stroke(from start: CGPoint, to end: CGPoint, ink: PKInk.InkType = .pen) -> PKStroke {
        let points = (0...20).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 20
            return PKStrokePoint(
                location: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                timeOffset: TimeInterval(i) * 0.01, size: CGSize(width: 3, height: 3),
                opacity: 1, force: 0.5 + 0.02 * CGFloat(i), azimuth: 0.3, altitude: 1.1)
        }
        return PKStroke(ink: PKInk(ink, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    @Test("andata e ritorno di un PKDrawing")
    func roundTrip() throws {
        let drawing = PKDrawing(strokes: [
            Self.stroke(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 120)),
            Self.stroke(from: CGPoint(x: 50, y: 300), to: CGPoint(x: 400, y: 310), ink: .marker),
        ])
        let data = InkCodec.data(from: drawing)
        #expect(!data.isEmpty)
        let decoded = try InkCodec.drawing(from: data)
        #expect(decoded.strokes.count == 2)
        #expect(decoded.strokes.map(\.ink.inkType) == [.pen, .marker])
        #expect(abs(decoded.bounds.minX - drawing.bounds.minX) < 0.5)
        #expect(abs(decoded.bounds.maxY - drawing.bounds.maxY) < 0.5)
        #expect(decoded.strokes[0].path.count == drawing.strokes[0].path.count)
    }

    @Test("pagina vuota: zero byte, e zero byte è una pagina vuota")
    func empty() throws {
        #expect(InkCodec.data(from: PKDrawing()).isEmpty)
        #expect(try InkCodec.drawing(from: Data()).strokes.isEmpty)
    }

    @Test("byte non validi: errore, non crash")
    func invalid() {
        #expect(throws: (any Error).self) { try InkCodec.drawing(from: Data([1, 2, 3])) }
    }

    @MainActor
    @Test("il disegno passa per SwiftData e per il JSON della sync senza cambiare")
    func throughStoreAndWire() throws {
        let store = SwiftDataSyncStore(container: try PitchstoneSchema.container(inMemory: true))
        let repository = Repository(store: store, deviceID: "a")
        let node = repository.createNode(type: .concept, title: "Appunti", area: .studio)
        let page = try repository.createInkPage(in: node.id, background: .lines)
        let data = InkCodec.data(from: PKDrawing(strokes: [Self.stroke(from: .zero, to: CGPoint(x: 100, y: 100))]))
        try repository.updateInkPage(page.id) { $0.inkData = data }

        let stored = try #require(store.inkPage(page.id))
        #expect(stored.inkData == data)
        #expect(stored.background == .lines)
        let json = try WireCoding.encoder().encode(stored)
        let back = try WireCoding.decoder().decode(InkPageRecord.self, from: json)
        #expect(try InkCodec.drawing(from: back.inkData).strokes.count == 1)

        store.deleteNode(node.id)
        #expect(store.inkPage(page.id) == nil)
    }
}
