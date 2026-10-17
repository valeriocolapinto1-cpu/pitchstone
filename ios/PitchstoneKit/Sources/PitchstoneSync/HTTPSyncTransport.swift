import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Service token di Cloudflare Access. Sull'iPad sta nel Keychain.
public struct AccessCredentials: Sendable, Equatable {
    public var clientID: String
    public var clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public struct HTTPError: Error, Equatable {
    public var status: Int
}

/// Un URL firmato che non punta dove deve: schema o host non ammessi.
public struct UntrustedURLError: Error, Equatable {
    public var host: String
}

/// Rifiuta ogni redirect: né Access né Supabase ne mandano a un client con un token valido, e uno
/// che arriva porterebbe le intestazioni (o il testo delle note) in un altro posto.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Chiama il Worker `ai-proxy` attraverso Cloudflare Access.
public struct HTTPSyncTransport: SyncTransport {
    public var baseURL: URL
    public var credentials: AccessCredentials
    /// Host (o suffissi, con il punto davanti) a cui possono puntare gli URL firmati dello storage.
    public var storageHosts: [String]
    let session: URLSession

    public static let defaultStorageHosts = [".supabase.co"]

    public init(
        baseURL: URL, credentials: AccessCredentials, session: URLSession = HTTPSyncTransport.makeSession(),
        storageHosts: [String] = HTTPSyncTransport.defaultStorageHosts
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
        self.storageHosts = storageHosts
    }

    /// Sessione effimera: niente cache su disco (le risposte contengono il testo delle note), niente
    /// cookie, niente redirect.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// Solo https, un host ammesso, niente credenziali nell'URL né porte diverse dalla 443.
    public func validateStorageURL(_ url: URL) throws {
        let host = (url.host ?? "").lowercased()
        let allowed = storageHosts.contains { entry in
            let entry = entry.lowercased()
            return entry.hasPrefix(".") ? host.hasSuffix(entry) && host.count > entry.count : host == entry
        }
        guard url.scheme == "https", allowed, url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            throw UntrustedURLError(host: host)
        }
    }

    /// Toglie una nota dal server con storico, archi, pagine e allegati: era sincronizzata e non deve più esserlo.
    public func redact(_ id: UUID) async throws {
        struct Body: Encodable { var id: String }
        let request = try makeRequest(path: "sync/redact", body: Body(id: id.uuidString.lowercased()))
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HTTPError(status: status) }
    }

    public struct EraseResult: Decodable, Equatable, Sendable {
        public var database: Bool
        public var storage: Bool
    }

    /// "Cancella tutto dal server": database, file degli allegati e backup.
    public func eraseServer() async throws -> EraseResult {
        struct Body: Encodable { var confirm = "cancella-tutto" }
        return try await send(makeRequest(path: "account/erase", body: Body()))
    }

    public func push(_ request: PushRequest) async throws -> PushResponse {
        try await send(makeRequest(path: "sync/push", body: request))
    }

    public func pull(_ request: PullRequest) async throws -> PullResponse {
        try await send(makeRequest(path: "sync/pull", body: request))
    }

    public func makeRequest<Body: Encodable>(path: String, body: Body) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue(credentials.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        request.httpBody = try WireCoding.encoder().encode(body)
        return request
    }

    public func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Access risponde con un redirect alla pagina di login se il token non è valido.
        guard status == 200 else { throw HTTPError(status: status) }
        return try WireCoding.decoder().decode(Response.self, from: data)
    }
}
