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

/// Chiama il Worker `ai-proxy` attraverso Cloudflare Access.
public struct HTTPSyncTransport: SyncTransport {
    public var baseURL: URL
    public var credentials: AccessCredentials
    let session: URLSession

    public init(baseURL: URL, credentials: AccessCredentials, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
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
