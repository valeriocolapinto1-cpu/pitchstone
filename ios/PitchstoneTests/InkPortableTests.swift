import Foundation
import PencilKit
import PitchstoneStore
import PitchstoneSync
import Testing
import UIKit
@testable import Pitchstone

// Il ponte PencilKit ↔ PSINK1. Il codec puro è testato nel pacchetto (PortableInkTests),
// sullo stesso file di esempio letto dai test della PWA.
@Suite("Disegni portabili (PSINK1) e PencilKit")
struct InkPortableTests {
    static func fixture() throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        // …/ios/PitchstoneTests/InkPortableTests.swift → radice del repository.
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent("docs/fixtures/psink1-esempio.psink"))
    }

    @Test("una pagina del PC diventa un PKDrawing scalato sulla tela")
    func fromPortable() throws {
        let loaded = try InkPortable.load(try Self.fixture(), canvasWidth: 400)
        #expect(loaded.pageWidth == 400)
        let strokes = loaded.drawing.strokes
        #expect(strokes.map(\.ink.inkType) == [.pen, .marker, .pencil])
        // La pagina è larga 800: sulla tela di 400 punti le coordinate si dimezzano.
        let first = try #require(strokes.first?.path.first)
        #expect(abs(first.location.x - 50) < 0.01 && abs(first.location.y - 60.25) < 0.01)
        #expect(abs(first.size.width - 1.25) < 0.01, "larghezza 2,5 a pressione 0,5, scalata a metà")
        #expect(strokes[0].path.count == 4)
        // Un punto solo diventa due punti uguali: PencilKit lo disegna.
        #expect(strokes[2].path.count == 2)
        #expect(InkPortable.hexColor(strokes[1].ink.color) == "#ffcc0080")
    }

    @Test("andata e ritorno: PKDrawing → PSINK1 → PKDrawing")
    func roundTrip() throws {
        let drawing = PKDrawing(strokes: [
            InkCodecTests.stroke(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 120)),
            InkCodecTests.stroke(from: CGPoint(x: 50, y: 300), to: CGPoint(x: 400, y: 310), ink: .marker),
        ])
        let data = InkPortable.data(from: drawing, pageWidth: 820)
        #expect(PortableInk.format(of: data) == .portable)
        let page = try PortableInk.decode(data)
        #expect(page.width == 820)
        #expect(page.strokes.map(\.tool) == [.pen, .marker])
        #expect(page.strokes[0].color == "#000000ff")
        #expect(page.strokes[0].points.count == 21)

        let back = try InkPortable.load(data, canvasWidth: 820).drawing
        #expect(back.strokes.map(\.ink.inkType) == [.pen, .marker])
        // I bordi includono lo spessore del tratto, arrotondato a 0,1 punti: c'è un margine.
        #expect(abs(back.bounds.minX - drawing.bounds.minX) < 2)
        #expect(abs(back.bounds.maxY - drawing.bounds.maxY) < 2)
        // Di nuovo in PSINK1: stessi byte (la codifica è stabile).
        #expect(InkPortable.data(from: back, pageWidth: 820) == data)
    }

    @Test("i tratti spostati col lazo si salvano dove si vedono")
    func transform() throws {
        var stroke = InkCodecTests.stroke(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0))
        stroke.transform = CGAffineTransform(translationX: 30, y: 40)
        let page = try PortableInk.decode(InkPortable.data(from: PKDrawing(strokes: [stroke]), pageWidth: 800))
        let first = try #require(page.strokes.first?.points.first)
        #expect(first.x == 30 && first.y == 40)
    }

    @Test("pagina vuota: zero byte; i PKDrawing di prima si leggono ancora")
    func legacy() throws {
        #expect(InkPortable.data(from: PKDrawing(), pageWidth: 800).isEmpty)
        #expect(try InkPortable.load(Data(), canvasWidth: 700).drawing.strokes.isEmpty)
        let old = InkCodec.data(from: PKDrawing(strokes: [InkCodecTests.stroke(from: .zero, to: CGPoint(x: 900, y: 100))]))
        let loaded = try InkPortable.load(old, canvasWidth: 700)
        #expect(loaded.drawing.strokes.count == 1)
        #expect(loaded.pageWidth >= 900, "un disegno più largo della tela non va tagliato sul PC")
        #expect(throws: (any Error).self) { try InkPortable.load(Data([1, 2, 3]), canvasWidth: 700) }
    }

    @Test("con la gomma pixel (tratti con maschera) la pagina resta PKDrawing")
    func maskKeepsPKDrawing() throws {
        var stroke = InkCodecTests.stroke(from: .zero, to: CGPoint(x: 100, y: 100))
        stroke.mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 50, height: 50))
        let data = InkPortable.data(from: PKDrawing(strokes: [stroke]), pageWidth: 800)
        #expect(PortableInk.format(of: data) == .other)
        #expect(try InkCodec.drawing(from: data).strokes.count == 1)
    }

    @Test("colori dinamici: si salva l'aspetto chiaro")
    func colors() {
        #expect(InkPortable.hexColor(.label) == "#000000ff")
        #expect(InkPortable.hexColor(UIColor(red: 0, green: 122 / 255, blue: 1, alpha: 1)) == "#007affff")
    }
}
