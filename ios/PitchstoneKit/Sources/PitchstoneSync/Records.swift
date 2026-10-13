import Foundation

// Record condivisi tra archivio locale e server (ARCHITETTURA.md, sezione 5).
// `version` è sempre l'ultima versione nota del server: 0 se il record non è
// mai stato sincronizzato. Le modifiche locali non la cambiano.

public enum NodeType: String, Codable, Sendable, CaseIterable {
    case concept, idea, project, exam, person
    /// Solo locale: mai inviato al server.
    case health
}

public enum Area: String, Codable, Sendable, CaseIterable {
    case studio, progetti, lavoro, persone, interessi
    /// Solo locale: mai inviata al server.
    case salute
}

public enum EdgeKind: String, Codable, Sendable {
    case link, ai, manual
}

public struct NodeRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var type: NodeType
    public var title: String
    public var bodyMD: String
    public var area: Area
    public var tags: [String]
    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var deviceID: String

    public init(
        id: UUID = UUID(), type: NodeType, title: String, bodyMD: String = "", area: Area,
        tags: [String] = [], version: Int = 0, createdAt: Date, updatedAt: Date,
        deletedAt: Date? = nil, deviceID: String
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.bodyMD = bodyMD
        self.area = area
        self.tags = tags
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.deviceID = deviceID
    }

    enum CodingKeys: String, CodingKey {
        case id, type, title, area, tags, version
        case bodyMD = "body_md"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case deviceID = "device_id"
    }

    // deleted_at va inviato anche quando è nil: un ripristino dal cestino
    // deve arrivare al server.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(title, forKey: .title)
        try c.encode(bodyMD, forKey: .bodyMD)
        try c.encode(area, forKey: .area)
        try c.encode(tags, forKey: .tags)
        try c.encode(version, forKey: .version)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(deviceID, forKey: .deviceID)
    }
}

public struct EdgeRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var sourceID: UUID
    public var targetID: UUID
    public var kind: EdgeKind
    public var label: String?
    public var version: Int
    public var createdAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(), sourceID: UUID, targetID: UUID, kind: EdgeKind, label: String? = nil,
        version: Int = 0, createdAt: Date, deletedAt: Date? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.targetID = targetID
        self.kind = kind
        self.label = label
        self.version = version
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, label, version
        case sourceID = "source_id"
        case targetID = "target_id"
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceID, forKey: .sourceID)
        try c.encode(targetID, forKey: .targetID)
        try c.encode(kind, forKey: .kind)
        try c.encode(label, forKey: .label)
        try c.encode(version, forKey: .version)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(deletedAt, forKey: .deletedAt)
    }
}

/// Storico di un nodo. Le versioni sono create dal server a ogni modifica accettata.
public struct NodeVersionRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var nodeID: UUID
    public var version: Int
    public var bodyMD: String
    public var createdAt: Date
    public var deviceID: String

    public init(id: UUID, nodeID: UUID, version: Int, bodyMD: String, createdAt: Date, deviceID: String) {
        self.id = id
        self.nodeID = nodeID
        self.version = version
        self.bodyMD = bodyMD
        self.createdAt = createdAt
        self.deviceID = deviceID
    }

    enum CodingKeys: String, CodingKey {
        case id, version
        case nodeID = "node_id"
        case bodyMD = "body_md"
        case createdAt = "created_at"
        case deviceID = "device_id"
    }
}

public enum Entity: String, Codable, Sendable {
    case node, edge
}

/// Voce dell'outbox: una sola per record, le modifiche successive si fondono.
public struct PendingChange: Equatable, Sendable {
    public var entity: Entity
    public var id: UUID
    /// Versione del server da cui è partita la modifica locale; nil se il record non è mai arrivato al server.
    public var baseVersion: Int?
    /// Cresce a ogni modifica locale: serve a capire se il record è cambiato durante un push.
    public var revision: Int
    /// Motivo del rifiuto del server. Una voce rifiutata resta in outbox ma non
    /// viene reinviata finché il record non cambia (o, per un arco, finché un suo
    /// estremo non arriva sul server).
    public var rejection: String?

    public init(entity: Entity, id: UUID, baseVersion: Int?, revision: Int, rejection: String? = nil) {
        self.entity = entity
        self.id = id
        self.baseVersion = baseVersion
        self.revision = revision
        self.rejection = rejection
    }
}
