import Foundation
import PitchstoneSync
import Testing

@Suite("Formato portabile dei disegni (PSINK1)")
struct PortableInkTests {
    /// Lo stesso file lo leggono i test della PWA (web/test/ink.test.ts): i due codec devono coincidere.
    static func fixture() throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent("docs/fixtures/psink1-esempio.psink"))
    }

    @Test("legge il file di esempio condiviso con la PWA")
    func readsFixture() throws {
        let page = try PortableInk.decode(try Self.fixture())
        #expect(page.width == 800)
        #expect(page.height == 1131.2)
        #expect(page.strokes.map(\.tool) == [.pen, .marker, .pencil])
        #expect(page.strokes[0] == PortableInk.Stroke(tool: .pen, color: "#1d1d1fff", width: 2.5, points: [
            .init(x: 100, y: 120.5, pressure: 0.5, time: 0), .init(x: 110.2, y: 125, pressure: 0.62, time: 0.016),
            .init(x: 130, y: 131.7, pressure: 0.8, time: 0.033), .init(x: 150.5, y: 140, pressure: 0.4, time: 0.05),
        ]))
        #expect(page.strokes[1].color == "#ffcc0080")
        #expect(page.strokes[2].points == [.init(x: 200, y: 500, pressure: 1, time: 0)])
    }

    @Test("scrive esattamente gli stessi byte del file di esempio (codifica canonica)")
    func canonicalEncoding() throws {
        let data = try Self.fixture()
        let encoded = try PortableInk.decode(data).encoded()
        #expect(String(decoding: encoded, as: UTF8.self) == String(decoding: data, as: UTF8.self))
        #expect(encoded == data)
    }

    @Test("arrotonda coordinate, pressione e tempo, e tiene i valori nei limiti")
    func rounding() throws {
        let stroke = try #require(PortableInk.normalized(PortableInk.Stroke(
            tool: .pen, color: "#FF0000", width: 2.345,
            points: [.init(x: 10.04, y: 20.06, pressure: 0.123, time: 0.0004), .init(x: -3.25, y: 5.55, pressure: 1.7, time: -1)])))
        #expect(stroke.color == "#ff0000ff")
        #expect(stroke.width == 2.3)
        #expect(stroke.points == [.init(x: 10, y: 20.1, pressure: 0.12, time: 0), .init(x: -3.3, y: 5.6, pressure: 1, time: 0)])
        let back = try PortableInk.decode(PortableInk(width: 800, height: 1131.2, strokes: [stroke]).encoded())
        #expect(back.strokes == [stroke])
    }

    @Test("valori sconosciuti diventano predefiniti, tratti senza punti spariscono")
    func lenient() throws {
        let text = #"PSINK1\#n{"v":1,"width":600,"strokes":[{"tool":"brush","color":"rosso","points":[[1,2,0.3,0],["x",1]],"extra":true},{"tool":"pen","points":[]},7],"futuro":1}"#
        let page = try PortableInk.decode(Data(text.utf8))
        #expect(page.width == 600)
        #expect(abs(page.height - 600 * 1.414) < 0.1)
        #expect(page.strokes == [PortableInk.Stroke(tool: .pen, color: "#000000ff", width: 2,
                                                    points: [.init(x: 1, y: 2, pressure: 0.3, time: 0)])])
    }

    @Test("pagina vuota: zero byte; un PKDrawing non è PSINK1")
    func formats() throws {
        #expect(PortableInk(width: 800, height: 1131.2, strokes: []).encoded().isEmpty)
        #expect(try PortableInk.decode(Data()).strokes.isEmpty)
        #expect(PortableInk.format(of: Data()) == .empty)
        #expect(PortableInk.format(of: try Self.fixture()) == .portable)
        let pkdrawing = Data([0x77, 0x72, 0x64, 0xF0, 0x00, 0x01, 0x02])
        #expect(PortableInk.format(of: pkdrawing) == .other)
        #expect(throws: PortableInk.DecodingError.notPortable) { try PortableInk.decode(pkdrawing) }
        #expect(throws: PortableInk.DecodingError.unsupportedVersion) {
            try PortableInk.decode(Data("PSINK1\n{\"v\":2,\"strokes\":[]}".utf8))
        }
        #expect(throws: PortableInk.DecodingError.invalidJSON) { try PortableInk.decode(Data("PSINK1\n{rotto".utf8)) }
    }

    @Test("pressione e larghezza: andata e ritorno; l'evidenziatore è uniforme")
    func pressureAndWidth() {
        let pen = PortableInk.Stroke(tool: .pen, color: "#000000ff", width: 3, points: [])
        #expect(abs(PortableInk.width(of: pen, atPressure: 0.5) - 3) < 1e-9)
        #expect(abs(PortableInk.width(of: pen, atPressure: 1) - 4.8) < 1e-9)
        for pressure in [0.0, 0.25, 0.5, 0.9, 1] {
            let size = PortableInk.width(of: pen, atPressure: pressure)
            #expect(abs(PortableInk.pressure(forSize: size, nominalWidth: 3) - pressure) < 1e-9)
        }
        #expect(PortableInk.pressure(forSize: 100, nominalWidth: 3) == 1)
        let marker = PortableInk.Stroke(tool: .marker, color: "#ffcc00ff", width: 16, points: [])
        #expect(PortableInk.width(of: marker, atPressure: 0.1) == 16)
    }

    @Test("colori: esadecimale e componenti")
    func colors() {
        #expect(PortableInk.hexColor(red: 0, green: 122 / 255, blue: 1, alpha: 1) == "#007affff")
        #expect(PortableInk.hexColor(red: -1, green: 2, blue: .nan, alpha: 0.5) == "#00ff0080")
        let c = PortableInk.components(ofColor: "#ffcc0080")
        #expect(c.red == 1 && abs(c.green - 0.8) < 1e-9 && c.blue == 0 && abs(c.alpha - 128.0 / 255) < 1e-9)
        #expect(PortableInk.components(ofColor: "blu").alpha == 1)
    }

    @Test("altezza: A4 o i tratti più 200")
    func height() {
        let stroke = PortableInk.Stroke(tool: .pen, color: "#000000ff", width: 2, points: [.init(x: 0, y: 2000)])
        #expect(PortableInk.pageHeight(width: 800, strokes: []) == 1131.2)
        #expect(PortableInk.pageHeight(width: 800, strokes: [stroke]) == 2200)
    }
}
