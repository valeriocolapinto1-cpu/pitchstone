import Foundation
import PDFKit
import PencilKit
import PitchstoneNotes
import UIKit
import Vision

/// Estrazione del testo, sul dispositivo e fuori dal thread principale:
/// testo dei PDF (PDFKit), OCR di foto e pagine scansionate e riconoscimento della
/// scrittura a mano (Vision), in italiano e in inglese.
enum TextExtractor {
    /// Le pagine di un PDF oltre questa soglia si leggono solo dal testo incorporato.
    static let maxOCRPages = 40
    static let languages = ["it-IT", "en-US"]

    /// Testo di ogni pagina; le pagine senza testo (scansioni) passano dall'OCR.
    static func pdfPages(at url: URL) -> [(page: Int, text: String)] {
        guard let document = PDFDocument(url: url) else { return [] }
        var result: [(Int, String)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count < 20, index < maxOCRPages {
                let size = page.bounds(for: .mediaBox).size
                let scale = 1600 / max(size.width, size.height, 1)
                let thumbnail = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
                if let image = thumbnail.cgImage { text = recognize(image) }
            }
            if !text.isEmpty { result.append((index, text)) }
        }
        return result
    }

    static func image(at url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return "" }
        return recognize(image)
    }

    /// Scrittura a mano: il disegno si rende in nero su bianco e passa dall'OCR.
    static func handwriting(_ data: Data) -> String {
        guard let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else { return "" }
        let bounds = drawing.bounds.insetBy(dx: -24, dy: -24)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return "" }
        // Tema chiaro: l'inchiostro "colore etichetta" diventa nero.
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: bounds, scale: 2)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: ink.size.applying(.init(scaleX: ink.scale, y: ink.scale)), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: context.format.bounds.size))
            ink.draw(in: CGRect(origin: .zero, size: context.format.bounds.size))
        }
        return image.cgImage.map(recognize) ?? ""
    }

    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
