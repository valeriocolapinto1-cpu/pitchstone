#if canImport(SwiftData)
import Foundation
import PitchstoneNotes
import SwiftData

/// Testo estratto da allegati e pagine a penna. Dato derivato e solo locale: ogni
/// dispositivo lo ricalcola dai file e dai disegni (ADR 0008).
@Model
public final class ExtractedTextEntity {
    @Attribute(.unique) public var entryKey: String
    public var nodeID: UUID
    public var sourceID: UUID
    public var sourceRaw: String
    public var page: Int?
    public var text: String
    /// Impronta del contenuto da cui viene il testo: se non cambia non si ricalcola.
    public var fingerprint: String

    init(_ t: ExtractedText, fingerprint: String) {
        entryKey = Self.key(t.sourceID, t.page)
        nodeID = t.nodeID
        sourceID = t.sourceID
        sourceRaw = t.source.rawValue
        page = t.page
        text = t.text
        self.fingerprint = fingerprint
    }

    static func key(_ sourceID: UUID, _ page: Int?) -> String { "\(sourceID.uuidString):\(page ?? -1)" }

    var record: ExtractedText? {
        guard let source = ExtractedText.Source(rawValue: sourceRaw) else { return nil }
        return ExtractedText(nodeID: nodeID, sourceID: sourceID, source: source, page: page, text: text)
    }
}

@MainActor
public final class TextIndexStore {
    // Il contesto non tiene in vita il container: va trattenuto qui.
    private let container: ModelContainer
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.container = container
        context = container.mainContext
    }

    /// Un salvataggio fallito non deve lasciare il contesto condiviso con la sync in uno stato sporco.
    private func save() {
        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }

    /// Impronte di tutte le fonti indicizzate, con una sola lettura.
    public func fingerprints() -> [UUID: String] {
        let d = FetchDescriptor<ExtractedTextEntity>()
        var result: [UUID: String] = [:]
        for entity in (try? context.fetch(d)) ?? [] { result[entity.sourceID] = entity.fingerprint }
        return result
    }

    private func entities(of sourceID: UUID) -> [ExtractedTextEntity] {
        let d = FetchDescriptor<ExtractedTextEntity>(predicate: #Predicate { $0.sourceID == sourceID })
        return (try? context.fetch(d)) ?? []
    }

    /// Impronta con cui è stata indicizzata la fonte, o nil se non lo è.
    public func fingerprint(of sourceID: UUID) -> String? {
        var d = FetchDescriptor<ExtractedTextEntity>(predicate: #Predicate { $0.sourceID == sourceID })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.fingerprint
    }

    /// Sostituisce il testo di una fonte. Una fonte senza testo tiene una voce vuota,
    /// così non si ricalcola a ogni avvio.
    public func replace(sourceID: UUID, fingerprint: String, with texts: [ExtractedText], placeholder: ExtractedText) {
        for entity in entities(of: sourceID) { context.delete(entity) }
        for text in texts.isEmpty ? [placeholder] : texts {
            context.insert(ExtractedTextEntity(text, fingerprint: fingerprint))
        }
        save()
    }

    public func remove(sourceID: UUID) {
        for entity in entities(of: sourceID) { context.delete(entity) }
        save()
    }

    public func all() -> [ExtractedText] {
        let d = FetchDescriptor<ExtractedTextEntity>(sortBy: [SortDescriptor(\.sourceID), SortDescriptor(\.page)])
        return ((try? context.fetch(d)) ?? []).compactMap(\.record).filter { !$0.text.isEmpty }
    }

    public func sourceIDs() -> Set<UUID> {
        let d = FetchDescriptor<ExtractedTextEntity>()
        return Set(((try? context.fetch(d)) ?? []).map(\.sourceID))
    }
}
#endif
