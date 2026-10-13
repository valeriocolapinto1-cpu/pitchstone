#if canImport(SwiftData)
import Foundation
import PitchstoneSync
import SwiftData

// Modello dati locale in SwiftData. I nodi di salute vivono solo qui.
// I tipi sono salvati come stringhe grezze per tollerare valori futuri.

@Model
public final class NodeEntity {
    @Attribute(.unique) public var id: UUID
    public var type: String
    public var title: String
    public var bodyMD: String
    public var area: String
    public var tags: [String]
    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var deviceID: String

    public init(_ r: NodeRecord) {
        id = r.id
        type = r.type.rawValue
        title = r.title
        bodyMD = r.bodyMD
        area = r.area.rawValue
        tags = r.tags
        version = r.version
        createdAt = r.createdAt
        updatedAt = r.updatedAt
        deletedAt = r.deletedAt
        deviceID = r.deviceID
    }

    func update(from r: NodeRecord) {
        type = r.type.rawValue
        title = r.title
        bodyMD = r.bodyMD
        area = r.area.rawValue
        tags = r.tags
        version = r.version
        createdAt = r.createdAt
        updatedAt = r.updatedAt
        deletedAt = r.deletedAt
        deviceID = r.deviceID
    }

    /// nil se il tipo o l'area non sono noti a questa versione dell'app.
    public var record: NodeRecord? {
        guard let type = NodeType(rawValue: type), let area = Area(rawValue: area) else { return nil }
        return NodeRecord(
            id: id, type: type, title: title, bodyMD: bodyMD, area: area, tags: tags, version: version,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt, deviceID: deviceID)
    }
}

@Model
public final class EdgeEntity {
    @Attribute(.unique) public var id: UUID
    public var sourceID: UUID
    public var targetID: UUID
    public var kind: String
    public var label: String?
    public var version: Int
    public var createdAt: Date
    public var deletedAt: Date?

    public init(_ r: EdgeRecord) {
        id = r.id
        sourceID = r.sourceID
        targetID = r.targetID
        kind = r.kind.rawValue
        label = r.label
        version = r.version
        createdAt = r.createdAt
        deletedAt = r.deletedAt
    }

    func update(from r: EdgeRecord) {
        sourceID = r.sourceID
        targetID = r.targetID
        kind = r.kind.rawValue
        label = r.label
        version = r.version
        createdAt = r.createdAt
        deletedAt = r.deletedAt
    }

    public var record: EdgeRecord? {
        guard let kind = EdgeKind(rawValue: kind) else { return nil }
        return EdgeRecord(
            id: id, sourceID: sourceID, targetID: targetID, kind: kind, label: label, version: version,
            createdAt: createdAt, deletedAt: deletedAt)
    }
}

@Model
public final class NodeVersionEntity {
    @Attribute(.unique) public var id: UUID
    public var nodeID: UUID
    public var version: Int
    public var bodyMD: String
    public var createdAt: Date
    public var deviceID: String

    public init(_ r: NodeVersionRecord) {
        id = r.id
        nodeID = r.nodeID
        version = r.version
        bodyMD = r.bodyMD
        createdAt = r.createdAt
        deviceID = r.deviceID
    }

    public var record: NodeVersionRecord {
        NodeVersionRecord(id: id, nodeID: nodeID, version: version, bodyMD: bodyMD, createdAt: createdAt, deviceID: deviceID)
    }
}

/// Pagina di disegno. I byte del PKDrawing stanno fuori dal database (externalStorage).
@Model
public final class InkPageEntity {
    @Attribute(.unique) public var id: UUID
    public var nodeID: UUID
    public var pageNo: Int
    public var background: String
    @Attribute(.externalStorage) public var inkData: Data
    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var deviceID: String

    public init(_ r: InkPageRecord) {
        id = r.id
        nodeID = r.nodeID
        pageNo = r.pageNo
        background = r.background.rawValue
        inkData = r.inkData
        version = r.version
        createdAt = r.createdAt
        updatedAt = r.updatedAt
        deletedAt = r.deletedAt
        deviceID = r.deviceID
    }

    func update(from r: InkPageRecord) {
        nodeID = r.nodeID
        pageNo = r.pageNo
        background = r.background.rawValue
        if inkData != r.inkData { inkData = r.inkData }
        version = r.version
        createdAt = r.createdAt
        updatedAt = r.updatedAt
        deletedAt = r.deletedAt
        deviceID = r.deviceID
    }

    public var record: InkPageRecord {
        InkPageRecord(
            id: id, nodeID: nodeID, pageNo: pageNo, background: InkBackground(rawValue: background) ?? .blank,
            inkData: inkData, version: version, createdAt: createdAt, updatedAt: updatedAt,
            deletedAt: deletedAt, deviceID: deviceID)
    }
}

/// Outbox: una voce per record, ordinata per `sequence`.
@Model
public final class OutboxEntity {
    // Nomi lontani da quelli di NSManagedObject/KVC (key, entity, entityName).
    @Attribute(.unique) public var outboxKey: String
    public var kindRaw: String
    public var recordID: UUID
    public var baseVersion: Int?
    public var revision: Int
    public var rejection: String?
    public var sequence: Int

    init(_ c: PendingChange, sequence: Int) {
        outboxKey = OutboxEntity.key(c.entity, c.id)
        kindRaw = c.entity.rawValue
        recordID = c.id
        baseVersion = c.baseVersion
        revision = c.revision
        rejection = c.rejection
        self.sequence = sequence
    }

    static func key(_ entity: Entity, _ id: UUID) -> String { "\(entity.rawValue):\(id.uuidString)" }

    var change: PendingChange? {
        guard let entity = Entity(rawValue: kindRaw) else { return nil }
        return PendingChange(entity: entity, id: recordID, baseVersion: baseVersion, revision: revision, rejection: rejection)
    }
}

@Model
public final class SyncStateEntity {
    @Attribute(.unique) public var stateName: String
    public var cursor: Int64

    init(cursor: Int64) {
        stateName = "default"
        self.cursor = cursor
    }
}

public enum PitchstoneSchema {
    public static func container(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        let schema = Schema([
            NodeEntity.self, EdgeEntity.self, NodeVersionEntity.self, InkPageEntity.self, OutboxEntity.self,
            SyncStateEntity.self,
        ])
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
#endif
