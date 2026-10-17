import Foundation

/// Formato portabile dei disegni (ADR 0015): `ink_data` = "PSINK1\n" + JSON con i tratti
/// in coordinate di pagina, leggibile e modificabile anche dalla PWA del PC.
/// Foundation pura: il ponte con PencilKit sta nell'app (`InkPortable`).
/// La codifica è canonica (ordine delle chiavi e arrotondamenti fissi): la PWA
/// (`web/src/ink.ts`) scrive gli stessi byte.
public struct PortableInk: Equatable, Sendable {
    public static let prefix = Data("PSINK1\n".utf8)
    /// Larghezza delle pagine nuove del PC; l'altezza parte da A4.
    public static let defaultPageWidth = 800.0
    public static let a4Ratio = 1.414

    public enum Tool: String, Sendable, CaseIterable {
        case pen, marker, pencil
    }

    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        /// 0...1; 0,5 dà la larghezza nominale del tratto.
        public var pressure: Double
        /// Secondi dall'inizio del tratto.
        public var time: Double

        public init(x: Double, y: Double, pressure: Double = 0.5, time: Double = 0) {
            self.x = x
            self.y = y
            self.pressure = pressure
            self.time = time
        }
    }

    public struct Stroke: Equatable, Sendable {
        public var tool: Tool
        /// "#rrggbbaa" nell'aspetto chiaro.
        public var color: String
        /// Larghezza a pressione 0,5, in unità di pagina.
        public var width: Double
        public var points: [Point]

        public init(tool: Tool, color: String, width: Double, points: [Point]) {
            self.tool = tool
            self.color = color
            self.width = width
            self.points = points
        }
    }

    /// Larghezza della pagina: definisce lo spazio delle coordinate.
    public var width: Double
    public var height: Double
    public var strokes: [Stroke]

    public init(width: Double, height: Double, strokes: [Stroke]) {
        self.width = width
        self.height = height
        self.strokes = strokes
    }

    public enum Format: Sendable, Equatable {
        /// Zero byte: pagina vuota.
        case empty
        /// PSINK1.
        case portable
        /// Altro, cioè un PKDrawing.
        case other
    }

    public enum DecodingError: Error, Equatable {
        case notPortable
        case invalidJSON
        case unsupportedVersion
    }

    public static func format(of data: Data) -> Format {
        if data.isEmpty { return .empty }
        return data.starts(with: prefix) ? .portable : .other
    }

    // MARK: Lettura

    /// Legge una pagina PSINK1 o vuota. Valori fuori posto diventano predefiniti, come nella PWA.
    public static func decode(_ data: Data) throws -> PortableInk {
        switch format(of: data) {
        case .empty:
            return PortableInk(width: defaultPageWidth, height: defaultPageWidth * a4Ratio, strokes: [])
        case .other:
            throw DecodingError.notPortable
        case .portable:
            break
        }
        let raw: RawPage
        do {
            raw = try JSONDecoder().decode(RawPage.self, from: data.dropFirst(prefix.count))
        } catch {
            throw DecodingError.invalidJSON
        }
        guard raw.v == 1 else { throw DecodingError.unsupportedVersion }
        let width = raw.width.flatMap { $0 > 0 ? $0 : nil } ?? defaultPageWidth
        let strokes = (raw.strokes ?? []).compactMap { $0.value.flatMap(normalized) }
        let height = raw.height.flatMap { $0 > 0 ? $0 : nil } ?? pageHeight(width: width, strokes: strokes)
        return PortableInk(width: width, height: height, strokes: strokes)
    }

    /// Tratto con valori arrotondati e nei limiti; nil senza punti.
    public static func normalized(_ stroke: Stroke) -> Stroke? {
        let points = stroke.points.compactMap { p -> Point? in
            guard p.x.isFinite, p.y.isFinite else { return nil }
            return Point(
                x: round(p.x, 1), y: round(p.y, 1),
                pressure: round(min(1, max(0, p.pressure.isFinite ? p.pressure : 0.5)), 2),
                time: round(max(0, p.time.isFinite ? p.time : 0), 3))
        }
        guard !points.isEmpty else { return nil }
        let width = stroke.width.isFinite && stroke.width > 0 ? stroke.width : 2
        return Stroke(tool: stroke.tool, color: normalizedColor(stroke.color), width: round(min(200, max(0.1, width)), 1),
                      points: points)
    }

    private static func normalized(_ raw: RawStroke) -> Stroke? {
        let points = (raw.points ?? []).compactMap { entry -> Point? in
            guard let values = entry.value, values.count >= 2, let x = values[0], let y = values[1] else { return nil }
            return Point(x: x, y: y, pressure: values.count > 2 ? values[2] ?? 0.5 : 0.5, time: values.count > 3 ? values[3] ?? 0 : 0)
        }
        return normalized(Stroke(tool: raw.tool.flatMap(Tool.init(rawValue:)) ?? .pen, color: raw.color ?? "",
                                 width: raw.width ?? 2, points: points))
    }

    // MARK: Scrittura

    /// Byte per `ink_data`. Una pagina senza tratti ha zero byte.
    public func encoded() -> Data {
        let strokes = self.strokes.compactMap(Self.normalized)
        guard !strokes.isEmpty else { return Data() }
        let width = Self.round(width > 0 ? width : Self.defaultPageWidth, 1)
        let height = Self.round(max(height, 0), 1)
        var json = "{\"v\":1,\"width\":\(Self.number(width)),\"height\":\(Self.number(height)),\"strokes\":["
        for (index, stroke) in strokes.enumerated() {
            if index > 0 { json += "," }
            json += "{\"tool\":\"\(stroke.tool.rawValue)\",\"color\":\"\(stroke.color)\",\"width\":\(Self.number(stroke.width)),\"points\":["
            json += stroke.points.map { p in
                "[\(Self.number(p.x)),\(Self.number(p.y)),\(Self.number(p.pressure)),\(Self.number(p.time))]"
            }.joined(separator: ",")
            json += "]}"
        }
        json += "]}"
        return Self.prefix + Data(json.utf8)
    }

    // MARK: Geometria e colori

    /// Altezza della pagina: A4, o i tratti più 200 (come la tela dell'iPad).
    public static func pageHeight(width: Double, strokes: [Stroke], minimum: Double = 0) -> Double {
        let bottom = strokes.flatMap(\.points).map(\.y).max()
        return round(max(width * a4Ratio, minimum, bottom.map { $0 + 200 } ?? 0), 1)
    }

    /// Larghezza disegnata a una pressione: 0,5 dà la larghezza nominale. L'evidenziatore è uniforme.
    public static func width(of stroke: Stroke, atPressure pressure: Double) -> Double {
        stroke.tool == .marker ? stroke.width : stroke.width * (0.4 + 1.2 * min(1, max(0, pressure)))
    }

    /// Inverso di `width(of:atPressure:)`: la pressione che dà la larghezza `size`.
    public static func pressure(forSize size: Double, nominalWidth: Double) -> Double {
        guard nominalWidth > 0, size.isFinite else { return 0.5 }
        return min(1, max(0, (size / nominalWidth - 0.4) / 1.2))
    }

    /// "#rrggbbaa" da componenti 0...1.
    public static func hexColor(red: Double, green: Double, blue: Double, alpha: Double) -> String {
        let byte = { (v: Double) -> String in
            let value = Int((min(1, max(0, v.isFinite ? v : 0)) * 255).rounded())
            let hex = String(value, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }
        return "#" + byte(red) + byte(green) + byte(blue) + byte(alpha)
    }

    /// Componenti 0...1 di "#rrggbbaa" (o "#rrggbb").
    public static func components(ofColor color: String) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        let hex = Array(normalizedColor(color).dropFirst())
        let value = { (i: Int) -> Double in Double(Int(String(hex[i..<i + 2]), radix: 16) ?? 0) / 255 }
        return (value(0), value(2), value(4), value(6))
    }

    static func normalizedColor(_ color: String) -> String {
        let hex = color.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = hex.dropFirst()
        guard hex.hasPrefix("#"), digits.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return "#000000ff" }
        if digits.count == 8 { return hex }
        if digits.count == 6 { return hex + "ff" }
        return "#000000ff"
    }

    /// Arrotonda a `digits` decimali, simmetrico rispetto allo zero (come la PWA).
    static func round(_ value: Double, _ digits: Int) -> Double {
        guard value.isFinite else { return 0 }
        let k = [1.0, 10, 100, 1000][digits]
        let r = (abs(value) * k).rounded() / k
        return r == 0 ? 0 : (value < 0 ? -r : r)
    }

    /// Come `JSON.stringify` per i numeri arrotondati: interi senza decimali, gli altri nella forma più corta.
    static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }
}

// MARK: JSON tollerante

/// Un elemento che non si decodifica diventa nil invece di far fallire tutto.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

private struct RawPage: Decodable {
    let v: Int?
    let width: Double?
    let height: Double?
    let strokes: [Lenient<RawStroke>]?

    enum CodingKeys: String, CodingKey { case v, width, height, strokes }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try? c.decodeIfPresent(Int.self, forKey: .v)
        width = try? c.decodeIfPresent(Double.self, forKey: .width)
        height = try? c.decodeIfPresent(Double.self, forKey: .height)
        strokes = try? c.decodeIfPresent([Lenient<RawStroke>].self, forKey: .strokes)
    }
}

private struct RawStroke: Decodable {
    let tool: String?
    let color: String?
    let width: Double?
    let points: [Lenient<[Double?]>]?

    enum CodingKeys: String, CodingKey { case tool, color, width, points }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try? c.decodeIfPresent(String.self, forKey: .tool)
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        width = try? c.decodeIfPresent(Double.self, forKey: .width)
        points = try? c.decodeIfPresent([Lenient<[Double?]>].self, forKey: .points)
    }
}
