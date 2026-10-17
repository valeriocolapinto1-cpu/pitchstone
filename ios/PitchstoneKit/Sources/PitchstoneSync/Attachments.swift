import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Divisione di un file in parti sotto il limite di Supabase (50 MB per file).
public enum AttachmentParts {
    /// 45 MiB: margine sotto i 50 MB del piano gratuito.
    public static let partSize = 45 * 1024 * 1024
    /// Limite del database: 100 parti.
    public static let maxParts = 100
    /// Un allegato più grande non ha senso con 1 GB di spazio (stesso limite nel database).
    public static let maxBytes = 500_000_000

    public static func count(forSize size: Int, partSize: Int = partSize) -> Int {
        max(1, (size + partSize - 1) / partSize)
    }

    /// Intervalli delle parti di un file di `size` byte, in ordine.
    public static func ranges(forSize size: Int, partSize: Int = partSize) -> [Range<Int>] {
        stride(from: 0, to: size, by: partSize).map { $0..<min($0 + partSize, size) }
    }

    /// Parti di un file in ordine (copie: per i file grandi meglio `ranges` e una parte alla volta).
    public static func split(_ data: Data, partSize: Int = partSize) -> [Data] {
        ranges(forSize: data.count, partSize: partSize).map { data.subdata(in: (data.startIndex + $0.lowerBound)..<(data.startIndex + $0.upperBound)) }
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
    /// Parti già caricate nel bucket per questo contenuto: un caricamento interrotto riprende da dove era arrivato
    /// invece di rimandare tutto. Un archivio che non le ricorda le rimanda (si può: l'upload sovrascrive).
    func uploadedParts(of id: UUID, sha256: String) -> Set<Int>
    func markUploaded(part: Int, of id: UUID, sha256: String)
    func clearUploaded(of id: UUID)
}

extension AttachmentFileStore {
    public func uploadedParts(of id: UUID, sha256: String) -> Set<Int> { [] }
    public func markUploaded(part: Int, of id: UUID, sha256: String) {}
    public func clearUploaded(of id: UUID) {}
}

/// File in una cartella (Application Support sull'iPad).
public struct DirectoryAttachmentFiles: AttachmentFileStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Darwin)
        // Gli allegati possono contenere referti: niente copie su iCloud o iTunes (si riscaricano dal server).
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        #endif
    }

    public func url(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased()) }
    public func exists(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: url(for: id).path) }
    public func read(_ id: UUID) throws -> Data { try Data(contentsOf: url(for: id), options: .alwaysMapped) }
    public func write(_ data: Data, for id: UUID) throws {
        #if os(iOS)
        // Illeggibile a dispositivo bloccato.
        try data.write(to: url(for: id), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url(for: id), options: .atomic)
        #endif
    }
    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
        clearUploaded(of: id)
    }

    // Le parti già caricate stanno in un file accanto: "<sha256> <indici separati da virgole>".
    private func markerURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased() + ".parts") }

    public func uploadedParts(of id: UUID, sha256: String) -> Set<Int> {
        guard let text = try? String(contentsOf: markerURL(id), encoding: .utf8) else { return [] }
        let fields = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard fields.count == 2, fields[0] == sha256 else { return [] }
        return Set(fields[1].split(separator: ",").compactMap { Int($0) })
    }

    public func markUploaded(part: Int, of id: UUID, sha256: String) {
        let parts = uploadedParts(of: id, sha256: sha256).union([part]).sorted()
        try? "\(sha256) \(parts.map(String.init).joined(separator: ","))".write(to: markerURL(id), atomically: true, encoding: .utf8)
    }

    public func clearUploaded(of id: UUID) { try? FileManager.default.removeItem(at: markerURL(id)) }
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

    /// Carica le parti del file locale. Ripetibile: le parti già caricate in un tentativo interrotto si saltano.
    public func upload(_ attachment: AttachmentRecord) async throws {
        guard files.exists(attachment.id) else { throw AttachmentError.missingLocalFile }
        // Il file è mappato in memoria: si copia una parte alla volta, non tutto il file.
        let data = try files.read(attachment.id)
        let ranges = AttachmentParts.ranges(forSize: data.count)
        guard !ranges.isEmpty, ranges.count == attachment.partCount, data.count == attachment.sizeBytes else {
            throw AttachmentError.corrupted
        }
        let done = files.uploadedParts(of: attachment.id, sha256: attachment.sha256)
        for (index, range) in ranges.enumerated() where !done.contains(index) {
            let url = try await transport.signedURL(upload: true, path: AttachmentParts.path(of: attachment, part: index))
            let part = data.subdata(in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound))
            try await transport.put(part, to: url)
            files.markUploaded(part: index, of: attachment.id, sha256: attachment.sha256)
        }
        files.clearUploaded(of: attachment.id)
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
        let url = try JSONDecoder().decode(SignResponse.self, from: data).url
        // Il Worker firma solo per lo storage di Supabase: un URL altrove non si segue.
        try validateStorageURL(url)
        return url
    }

    /// Verso l'URL firmato di Supabase: niente credenziali di Access.
    public func put(_ data: Data, to url: URL) async throws {
        try validateStorageURL(url)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 600
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPError(status: status) }
    }

    public func get(_ url: URL) async throws -> Data {
        try validateStorageURL(url)
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HTTPError(status: status) }
        return data
    }
}
