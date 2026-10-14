#if canImport(SwiftData)
import Foundation
import SwiftData

/// Stato dell'analisi automatica di un nodo (fase 6). Solo locale: segnali di salute
/// già giudicati innocui, ultima versione analizzata, proposte in attesa di conferma.
public struct AnalysisRecord: Sendable, Equatable {
    public var nodeID: UUID
    /// Impronta del testo all'ultima analisi: lo stesso testo non si rianalizza.
    public var analyzedFingerprint: String?
    /// Segnali di salute che l'utente ha detto non essere dati di salute.
    public var dismissedSignals: [String]
    /// Proposte da confermare, nel formato scelto dall'app (JSON).
    public var pending: Data
    /// Proposte scartate: una nuova analisi non le ripropone.
    public var discarded: [String]

    public init(
        nodeID: UUID, analyzedFingerprint: String? = nil, dismissedSignals: [String] = [], pending: Data = Data(),
        discarded: [String] = []
    ) {
        self.nodeID = nodeID
        self.analyzedFingerprint = analyzedFingerprint
        self.dismissedSignals = dismissedSignals
        self.pending = pending
        self.discarded = discarded
    }
}

@Model
public final class AnalysisStateEntity {
    @Attribute(.unique) public var nodeID: UUID
    public var analyzedFingerprint: String?
    public var dismissedSignals: [String]
    public var pending: Data
    public var discarded: [String] = []

    init(_ r: AnalysisRecord) {
        nodeID = r.nodeID
        analyzedFingerprint = r.analyzedFingerprint
        dismissedSignals = r.dismissedSignals
        pending = r.pending
        discarded = r.discarded
    }

    var record: AnalysisRecord {
        AnalysisRecord(
            nodeID: nodeID, analyzedFingerprint: analyzedFingerprint, dismissedSignals: dismissedSignals, pending: pending,
            discarded: discarded)
    }
}

@MainActor
public final class AnalysisStore {
    private let container: ModelContainer
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.container = container
        context = container.mainContext
    }

    public func all() -> [UUID: AnalysisRecord] {
        let entities = (try? context.fetch(FetchDescriptor<AnalysisStateEntity>())) ?? []
        return Dictionary(entities.map { ($0.nodeID, $0.record) }, uniquingKeysWith: { first, _ in first })
    }

    public func record(_ nodeID: UUID) -> AnalysisRecord? {
        entity(nodeID)?.record
    }

    public func save(_ record: AnalysisRecord) {
        if let entity = entity(record.nodeID) {
            entity.analyzedFingerprint = record.analyzedFingerprint
            entity.dismissedSignals = record.dismissedSignals
            entity.pending = record.pending
            entity.discarded = record.discarded
        } else {
            context.insert(AnalysisStateEntity(record))
        }
        commit()
    }

    public func remove(_ nodeID: UUID) {
        guard let entity = entity(nodeID) else { return }
        context.delete(entity)
        commit()
    }

    private func entity(_ nodeID: UUID) -> AnalysisStateEntity? {
        var d = FetchDescriptor<AnalysisStateEntity>(predicate: #Predicate { $0.nodeID == nodeID })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    private func commit() {
        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }
}
#endif
