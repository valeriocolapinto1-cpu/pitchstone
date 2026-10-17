import Foundation
import Testing
@testable import PitchstoneSync
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Sicurezza del trasporto")
struct TransportSecurityTests {
    func makeTransport(storageHosts: [String] = HTTPSyncTransport.defaultStorageHosts) throws -> HTTPSyncTransport {
        HTTPSyncTransport(
            baseURL: try #require(URL(string: "https://ai.pitchstone.example")),
            credentials: AccessCredentials(clientID: "id.access", clientSecret: "segreto"),
            storageHosts: storageHosts)
    }

    @Test("gli URL firmati: solo https, solo host ammessi")
    func validatesSignedURLs() throws {
        let transport = try makeTransport()
        for good in [
            "https://abcd.supabase.co/storage/v1/object/sign/attachments/x?token=t",
            "https://ABCD.Supabase.co/storage/v1/object/upload/sign/attachments/x?token=t",
            "https://abcd.supabase.co:443/storage/v1/object/sign/x",
        ] {
            try transport.validateStorageURL(try #require(URL(string: good)))
        }
        for bad in [
            "http://abcd.supabase.co/storage/v1/object/sign/x",
            "https://evil.example/storage/v1/object/sign/x",
            "https://supabase.co/storage/v1/object/sign/x",
            "https://abcd.supabase.co.evil.example/x",
            "https://evilsupabase.co/x",
            "https://user:pw@abcd.supabase.co/x",
            "https://abcd.supabase.co:8443/x",
            "file:///etc/passwd",
            "https://127.0.0.1/x",
        ] {
            let url = try #require(URL(string: bad))
            #expect(throws: UntrustedURLError.self) { try transport.validateStorageURL(url) }
        }
    }

    @Test("un host esatto si può ammettere, e solo quello")
    func exactHost() throws {
        let transport = try makeTransport(storageHosts: ["storage.example.com"])
        try transport.validateStorageURL(try #require(URL(string: "https://storage.example.com/x")))
        let other = try #require(URL(string: "https://other.example.com/x"))
        let sub = try #require(URL(string: "https://a.storage.example.com/x"))
        #expect(throws: UntrustedURLError.self) { try transport.validateStorageURL(other) }
        #expect(throws: UntrustedURLError.self) { try transport.validateStorageURL(sub) }
    }

    @Test("il trasferimento rifiuta un URL non ammesso prima di mandare qualsiasi cosa")
    func transferRejectsUntrustedURLs() async throws {
        let transport = try makeTransport()
        let evil = try #require(URL(string: "https://evil.example/x"))
        await #expect(throws: UntrustedURLError.self) { try await transport.put(Data("segreto".utf8), to: evil) }
        await #expect(throws: UntrustedURLError.self) { _ = try await transport.get(evil) }
    }

    @Test("la sessione è effimera: niente cache, niente cookie")
    func sessionIsEphemeral() {
        let configuration = HTTPSyncTransport.makeSession().configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("un redirect non si segue")
    func redirectsAreRefused() async throws {
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        let url = try #require(URL(string: "https://example.com/a"))
        let task = session.dataTask(with: url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://evil.example"]))
        let followed = await withCheckedContinuation { continuation in
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)) {
                continuation.resume(returning: $0)
            }
        }
        #expect(followed == nil)
        session.invalidateAndCancel()
    }

    @Test("redact e cancellazione usano le rotte del Worker con il service token")
    func accountRequests() throws {
        let transport = try makeTransport()
        struct Body: Encodable { var id: String }
        let request = try transport.makeRequest(path: "sync/redact", body: Body(id: "abc"))
        #expect(request.url?.path == "/sync/redact")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "id.access")
    }
}
