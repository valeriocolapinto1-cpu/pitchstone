import Foundation

// Formato scambiato con il Worker (/sync/push, /sync/pull), identico a quello
// delle funzioni sync_push e sync_pull del database.

public struct OutgoingChange: Encodable, Sendable {
    public enum Payload: Sendable {
        case node(NodeRecord)
        case edge(EdgeRecord)
    }

    public var baseVersion: Int?
    public var payload: Payload

    public init(baseVersion: Int?, payload: Payload) {
        self.baseVersion = baseVersion
        self.payload = payload
    }

    public var entity: Entity {
        switch payload {
        case .node: .node
        case .edge: .edge
        }
    }

    public var id: UUID {
        switch payload {
        case .node(let n): n.id
        case .edge(let e): e.id
        }
    }

    enum CodingKeys: String, CodingKey {
        case entity, data
        case baseVersion = "base_version"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entity, forKey: .entity)
        try c.encode(baseVersion, forKey: .baseVersion)
        switch payload {
        case .node(let n): try c.encode(n, forKey: .data)
        case .edge(let e): try c.encode(e, forKey: .data)
        }
    }
}

public struct PushRequest: Encodable, Sendable {
    public var deviceID: String
    public var changes: [OutgoingChange]

    enum CodingKeys: String, CodingKey {
        case changes
        case deviceID = "device_id"
    }
}

public struct PushResult: Decodable, Sendable {
    public enum Status: String, Decodable, Sendable {
        case created, updated, merged, rejected
    }

    public var entity: Entity?
    public var id: UUID?
    public var status: Status
    public var node: NodeRecord?
    public var edge: EdgeRecord?
    public var error: String?
    public var message: String?

    public init(entity: Entity?, id: UUID?, status: Status, node: NodeRecord? = nil, edge: EdgeRecord? = nil,
                error: String? = nil, message: String? = nil) {
        self.entity = entity
        self.id = id
        self.status = status
        self.node = node
        self.edge = edge
        self.error = error
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case entity, id, status, record, error, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entity = try? c.decodeIfPresent(Entity.self, forKey: .entity)
        id = try? c.decodeIfPresent(UUID.self, forKey: .id)
        status = try c.decode(Status.self, forKey: .status)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        if status != .rejected {
            switch entity {
            case .node: node = try c.decode(NodeRecord.self, forKey: .record)
            case .edge: edge = try c.decode(EdgeRecord.self, forKey: .record)
            case nil: break
            }
        }
    }
}

public struct PushResponse: Decodable, Sendable {
    public var results: [PushResult]

    public init(results: [PushResult]) {
        self.results = results
    }
}

public struct PullRequest: Encodable, Sendable {
    public var cursor: Int64
    public var limit: Int
}

public enum IncomingChange: Decodable, Sendable {
    case node(NodeRecord)
    case edge(EdgeRecord)
    case nodeVersion(NodeVersionRecord)
    case purged(Entity, UUID)
    /// Entità introdotte da fasi successive: ignorate dai client più vecchi.
    case unknown

    enum CodingKeys: String, CodingKey {
        case entity, data
    }

    struct Purged: Decodable {
        var entity: Entity
        var id: UUID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .entity) {
        case "node": self = .node(try c.decode(NodeRecord.self, forKey: .data))
        case "edge": self = .edge(try c.decode(EdgeRecord.self, forKey: .data))
        case "node_version": self = .nodeVersion(try c.decode(NodeVersionRecord.self, forKey: .data))
        case "purged":
            let p = try c.decode(Purged.self, forKey: .data)
            self = .purged(p.entity, p.id)
        default: self = .unknown
        }
    }
}

public struct PullResponse: Decodable, Sendable {
    public var changes: [IncomingChange]
    public var cursor: Int64
    public var hasMore: Bool

    public init(changes: [IncomingChange], cursor: Int64, hasMore: Bool) {
        self.changes = changes
        self.cursor = cursor
        self.hasMore = hasMore
    }

    enum CodingKeys: String, CodingKey {
        case changes, cursor
        case hasMore = "has_more"
    }
}

/// JSON del server: date ISO 8601 con frazioni fino ai microsecondi (Postgres).
public enum WireCoding {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "data non valida: \(text)")
            }
            return date
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatDate(date))
        }
        return encoder
    }

    /// Accetta `2026-10-13T12:00:00Z`, `…:00.5+00:00`, `…:00.123456+02:00`.
    public static func parseDate(_ text: String) -> Date? {
        var base = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let digitsEnd = text[dot...].dropFirst().firstIndex { !$0.isNumber } ?? text.endIndex
            let digits = text[text.index(after: dot)..<digitsEnd]
            guard !digits.isEmpty, let value = Double("0." + digits) else { return nil }
            fraction = value
            base = String(text[..<dot] + text[digitsEnd...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: base) else { return nil }
        return date.addingTimeInterval(fraction)
    }

    public static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
