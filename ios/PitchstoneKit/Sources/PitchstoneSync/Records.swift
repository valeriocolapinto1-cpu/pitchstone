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

public enum InkBackground: String, Codable, Sendable, CaseIterable {
    case blank, lines, grid
}

/// Pagina di disegno di un nodo: tratti PencilKit serializzati (`PKDrawing.dataRepresentation()`).
public struct InkPageRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var nodeID: UUID
    public var pageNo: Int
    public var background: InkBackground
    /// In JSON viaggia in base64 (comportamento predefinito di JSONEncoder per `Data`).
    public var inkData: Data
    /// Annotazione su un PDF: l'allegato e la sua pagina (da 0). Nil per le pagine del nodo.
    public var attachmentID: UUID?
    public var pdfPage: Int?
    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var deviceID: String

    public var isPDFAnnotation: Bool { attachmentID != nil }

    public init(
        id: UUID = UUID(), nodeID: UUID, pageNo: Int, background: InkBackground = .blank, inkData: Data = Data(),
        attachmentID: UUID? = nil, pdfPage: Int? = nil,
        version: Int = 0, createdAt: Date, updatedAt: Date, deletedAt: Date? = nil, deviceID: String
    ) {
        self.id = id
        self.nodeID = nodeID
        self.pageNo = pageNo
        self.background = background
        self.inkData = inkData
        self.attachmentID = attachmentID
        self.pdfPage = pdfPage
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.deviceID = deviceID
    }

    enum CodingKeys: String, CodingKey {
        case id, background, version
        case nodeID = "node_id"
        case pageNo = "page_no"
        case inkData = "ink_data"
        case attachmentID = "attachment_id"
        case pdfPage = "pdf_page"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case deviceID = "device_id"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(nodeID, forKey: .nodeID)
        try c.encode(pageNo, forKey: .pageNo)
        try c.encode(background, forKey: .background)
        try c.encode(inkData, forKey: .inkData)
        try c.encode(attachmentID, forKey: .attachmentID)
        try c.encode(pdfPage, forKey: .pdfPage)
        try c.encode(version, forKey: .version)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(deviceID, forKey: .deviceID)
    }
}

public enum AttachmentKind: String, Codable, Sendable {
    case pdf, image, markdown
}

/// Un file allegato (PDF, immagine). I byte stanno in un file locale e, se l'allegato
/// può lasciare il dispositivo, nel bucket privato diviso in parti (ADR 0007).
public struct AttachmentRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var nodeID: UUID?
    public var kind: AttachmentKind
    public var fileName: String
    public var sizeBytes: Int
    public var pageCount: Int?
    /// SHA-256 del file intero, esadecimale.
    public var sha256: String
    public var partCount: Int
    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var deviceID: String
    /// Solo locale: tutte le parti sono nel bucket. Un allegato ricevuto dal server lo è già.
    public var isUploaded: Bool

    /// Il percorso nel bucket è l'id (vincolo del database).
    public var storagePath: String { id.uuidString.lowercased() }

    public init(
        id: UUID = UUID(), nodeID: UUID?, kind: AttachmentKind, fileName: String, sizeBytes: Int, pageCount: Int? = nil,
        sha256: String, partCount: Int, version: Int = 0, createdAt: Date, updatedAt: Date, deletedAt: Date? = nil,
        deviceID: String, isUploaded: Bool = false
    ) {
        self.id = id
        self.nodeID = nodeID
        self.kind = kind
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.pageCount = pageCount
        self.sha256 = sha256
        self.partCount = partCount
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.deviceID = deviceID
        self.isUploaded = isUploaded
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, sha256, version
        case nodeID = "node_id"
        case fileName = "file_name"
        case sizeBytes = "size_bytes"
        case pageCount = "page_count"
        case partCount = "part_count"
        case storagePath = "storage_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case deviceID = "device_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        nodeID = try c.decodeIfPresent(UUID.self, forKey: .nodeID)
        kind = try c.decode(AttachmentKind.self, forKey: .kind)
        fileName = try c.decode(String.self, forKey: .fileName)
        sizeBytes = try c.decode(Int.self, forKey: .sizeBytes)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
        sha256 = try c.decode(String.self, forKey: .sha256)
        partCount = try c.decode(Int.self, forKey: .partCount)
        version = try c.decode(Int.self, forKey: .version)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        // Arriva dal server: le parti sono già nel bucket.
        isUploaded = true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(nodeID, forKey: .nodeID)
        try c.encode(kind, forKey: .kind)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(sizeBytes, forKey: .sizeBytes)
        try c.encode(pageCount, forKey: .pageCount)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(partCount, forKey: .partCount)
        try c.encode(storagePath, forKey: .storagePath)
        try c.encode(version, forKey: .version)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(deviceID, forKey: .deviceID)
    }
}

public enum Entity: String, Codable, Sendable {
    case node, edge
    case inkPage = "ink_page"
    case attachment
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

/// Confronto tra titoli dei nodi per i link `[[...]]`: ignora spazi ai bordi, maiuscole e accenti.
public enum NodeTitle {
    public static func key(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
