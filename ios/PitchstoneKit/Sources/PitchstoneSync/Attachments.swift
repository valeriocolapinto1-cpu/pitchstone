import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Divisione di un file in parti sotto il limite di Supabase (50 MB per file).
public enum AttachmentParts {
    /// 45 MiB: margine sotto i 50 MB del piano gratuito.
    public static let partSize = 45 * 1024 * 1024
    /// Limite del database: 100 parti, cioè circa 4,4 GB.
    public static let maxParts = 100

    public static func count(forSize size: Int, partSize: Int = partSize) -> Int {
        max(1, (size + partSize - 1) / partSize)
    }

    /// Parti di un file in ordine. Le sottosequenze di un `Data` mappato in memoria non copiano i byte.
    public static func split(_ data: Data, partSize: Int = partSize) -> [Data] {
        guard !data.isEmpty else { return [] }
        return stride(from: 0, to: data.count, by: partSize).map { start in
            data.subdata(in: (data.startIndex + start)..<(data.startIndex + min(start + partSize, data.count)))
        }
    }

    /// Percorso di una parte nel bucket: `<id>/part-007`.
    public static func path(of attachment: AttachmentRecord, part: Int) -> String {
        "\(attachment.storagePath)/part-\(String(format: "%03d", part))"
    }
}

/// File degli allegati sul dispositivo. Un file per allegato, intero.
public protocol AttachmentFileStore: Sendable {
    func url(for id: UUID) -> URL
    func exists(_ id: UUID) -> Bool
    func read(_ id: UUID) throws -> Data
    func write(_ data: Data, for id: UUID) throws
    func remove(_ id: UUID)
}

/// File in una cartella (Application Support sull'iPad).
public struct DirectoryAttachmentFiles: AttachmentFileStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func url(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased()) }
    public func exists(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: url(for: id).path) }
    public func read(_ id: UUID) throws -> Data { try Data(contentsOf: url(for: id), options: .alwaysMapped) }
    public func write(_ data: Data, for id: UUID) throws { try data.write(to: url(for: id), options: .atomic) }
    public func remove(_ id: UUID) { try? FileManager.default.removeItem(at: url(for: id)) }
}

/// Canale per i file nel bucket: il Worker firma, il trasferimento va diretto a Supabase.
public protocol StorageTransport: Sendable {
    func signedURL(upload: Bool, path: String) async throws -> URL
    func put(_ data: Data, to url: URL) async throws
    func get(_ url: URL) async throws -> Data
}

public enum AttachmentError: Error, Equatable {
    case missingLocalFile
    case corrupted
    case tooLarge
}

/// Caricamento e scaricamento delle parti.
public struct AttachmentTransfer: Sendable {
    public let transport: StorageTransport
    public let files: AttachmentFileStore

    public init(transport: StorageTransport, files: AttachmentFileStore) {
        self.transport = transport
        self.files = files
    }

    /// Carica tutte le parti del file locale. Ripetibile: le parti già presenti si sovrascrivono.
    public func upload(_ attachment: AttachmentRecord) async throws {
        guard files.exists(attachment.id) else { throw AttachmentError.missingLocalFile }
        let parts = AttachmentParts.split(try files.read(attachment.id))
        guard parts.count == attachment.partCount else { throw AttachmentError.corrupted }
        for (index, part) in parts.enumerated() {
            let url = try await transport.signedURL(upload: true, path: AttachmentParts.path(of: attachment, part: index))
            try await transport.put(part, to: url)
        }
    }

    /// Il file locale, scaricandolo e ricomponendolo se manca. Un file che non torna
    /// identico (SHA-256) non viene salvato.
    @discardableResult
    public func ensureLocal(_ attachment: AttachmentRecord) async throws -> URL {
        if files.exists(attachment.id) { return files.url(for: attachment.id) }
        var data = Data(capacity: attachment.sizeBytes)
        for index in 0..<attachment.partCount {
            let url = try await transport.signedURL(upload: false, path: AttachmentParts.path(of: attachment, part: index))
            data.append(try await transport.get(url))
        }
        guard data.count == attachment.sizeBytes, SHA256Digest.hex(data) == attachment.sha256 else {
            throw AttachmentError.corrupted
        }
        try files.write(data, for: attachment.id)
        return files.url(for: attachment.id)
    }
}

extension HTTPSyncTransport: StorageTransport {
    struct SignRequest: Encodable {
        var action: String
        var path: String
    }

    struct SignResponse: Decodable {
        var url: URL
    }

    public func signedURL(upload: Bool, path: String) async throws -> URL {
        let request = try makeRequest(path: "storage/sign", body: SignRequest(action: upload ? "upload" : "download", path: path))
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw HTTPError(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(SignResponse.self, from: data).url
    }

    /// Verso l'URL firmato di Supabase: niente credenziali di Access.
    public func put(_ data: Data, to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 600
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPError(status: status) }
    }

    public func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HTTPError(status: status) }
        return data
    }
}
