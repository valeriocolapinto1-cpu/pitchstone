#if canImport(PencilKit)
import Foundation
import PencilKit

/// Serializzazione del disegno: i byte salvati in `InkPageRecord.inkData` sono
/// `PKDrawing.dataRepresentation()`. Una pagina vuota ha zero byte.
public enum InkCodec {
    public static func data(from drawing: PKDrawing) -> Data {
        drawing.strokes.isEmpty ? Data() : drawing.dataRepresentation()
    }

    public static func drawing(from data: Data) throws -> PKDrawing {
        data.isEmpty ? PKDrawing() : try PKDrawing(data: data)
    }
}
#endif
