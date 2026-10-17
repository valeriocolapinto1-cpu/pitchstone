import Foundation
import Testing
@testable import PitchstoneSync

/// Il contratto condiviso con il Worker e la PWA (../../../../contract): gli stessi esempi, lo stesso formato.
@Suite("Contratto con il server")
struct ContractTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.root.appendingPathComponent("contract/fixtures/\(name).json"))
    }

    func json(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
    }

    @Test("la risposta di pull di esempio: entità note lette, sconosciute ignorate")
    func decodesThePullFixture() throws {
        let response = try WireCoding.decoder().decode(PullResponse.self, from: fixture("pull-response"))
        #expect(response.cursor == 56)
        #expect(response.hasMore == false)
        #expect(response.epoch == 1)
        var counts: [String: Int] = [:]
        for change in response.changes {
            switch change {
            case .node(let n):
                #expect(n.title == "Derivata" && n.version == 3 && n.tags == ["analisi"])
                counts["node", default: 0] += 1
            case .nodeVersion(let v): #expect(v.version == 3); counts["version", default: 0] += 1
            case .edge(let e): #expect(e.kind == .link && e.label == nil); counts["edge", default: 0] += 1
            case .inkPage(let p): #expect(p.background == .blank && p.inkData == Data([0x41, 0x42, 0x43, 0x44])); counts["ink", default: 0] += 1
            case .attachment(let a): #expect(a.fileName == "Analisi.pdf" && a.partCount == 3 && a.isUploaded); counts["attachment", default: 0] += 1
            case .purged(let entity, _): #expect(entity == .node); counts["purged", default: 0] += 1
            case .unknown: counts["unknown", default: 0] += 1
            }
        }
        #expect(counts == ["node": 1, "version": 1, "edge": 1, "ink": 1, "attachment": 1, "purged": 1, "unknown": 2])
    }

    @Test("la risposta di push di esempio: stati, record e codici di rifiuto")
    func decodesThePushFixture() throws {
        let response = try WireCoding.decoder().decode(PushResponse.self, from: fixture("push-response"))
        #expect(response.results.map(\.status) == [.created, .merged, .rejected, .updated, .rejected])
        #expect(response.results[0].node?.version == 1)
        #expect(response.results[1].node?.bodyMD == "A\n\n---\n\nB")
        #expect(response.results[2].message == "missing_parent")
        #expect(response.results[2].error == "23503")
        #expect(response.results[3].inkPage?.version == 2)
        #expect(response.results[4].message == "invalid")
    }

    @Test("uno stato che non esiste ancora diventa .unknown, non un errore")
    func unknownStatusDecodes() throws {
        let data = Data(#"{"results":[{"entity":"node","id":"10000000-0000-4000-8000-000000000001","status":"teleported"}]}"#.utf8)
        let response = try WireCoding.decoder().decode(PushResponse.self, from: data)
        #expect(response.results[0].status == .unknown)
        #expect(response.results[0].node == nil)
    }

    @Test("un pull senza epoca (server precedente) si legge ancora")
    func pullWithoutEpoch() throws {
        let response = try WireCoding.decoder().decode(PullResponse.self, from: Data(#"{"changes":[],"cursor":3,"has_more":false}"#.utf8))
        #expect(response.epoch == nil)
    }

    @Test("ciò che l'iPad manda ha almeno le chiavi dell'esempio di push")
    func encodedRecordsHaveTheContractKeys() throws {
        let pulled = try WireCoding.decoder().decode(PullResponse.self, from: fixture("pull-response"))
        let request = try json("push-request")
        let changes = try #require(request["changes"] as? [[String: Any]])
        func keys(_ entity: String) throws -> Set<String> {
            let change = try #require(changes.first { $0["entity"] as? String == entity })
            return Set(try #require(change["data"] as? [String: Any]).keys)
        }
        func encodedKeys<T: Encodable>(_ value: T) throws -> Set<String> {
            let object = try JSONSerialization.jsonObject(with: WireCoding.encoder().encode(value)) as? [String: Any]
            return Set(try #require(object).keys)
        }
        for change in pulled.changes {
            switch change {
            case .node(let n): #expect(try keys("node").isSubset(of: encodedKeys(n)))
            case .edge(let e): #expect(try keys("edge").isSubset(of: encodedKeys(e)))
            case .inkPage(let p): #expect(try keys("ink_page").isSubset(of: encodedKeys(p)))
            case .attachment(let a): #expect(try keys("attachment").isSubset(of: encodedKeys(a)))
            default: break
            }
        }
    }

    @Test("la richiesta di push dell'iPad ha la forma dello schema")
    func pushRequestShape() throws {
        let pulled = try WireCoding.decoder().decode(PullResponse.self, from: fixture("pull-response"))
        let node = try #require(pulled.changes.compactMap { change -> NodeRecord? in
            if case .node(let n) = change { return n }
            return nil
        }.first)
        let request = PushRequest(deviceID: "ipad-1a2b3c4d", changes: [OutgoingChange(baseVersion: 3, payload: .node(node))])
        let object = try #require(try JSONSerialization.jsonObject(with: WireCoding.encoder().encode(request)) as? [String: Any])
        #expect(object["device_id"] as? String == "ipad-1a2b3c4d")
        let change = try #require((object["changes"] as? [[String: Any]])?.first)
        #expect(change["entity"] as? String == "node")
        #expect(change["base_version"] as? Int == 3)
        #expect(change["data"] is [String: Any])
    }

    @Test("ogni richiesta porta la versione dell'API")
    func requestsCarryTheAPIVersion() throws {
        let transport = HTTPSyncTransport(
            baseURL: try #require(URL(string: "https://ai.pitchstone.example")),
            credentials: AccessCredentials(clientID: "id", clientSecret: "s"))
        let request = try transport.makeRequest(path: "sync/pull", body: PullRequest(cursor: 0, limit: 10))
        #expect(request.value(forHTTPHeaderField: "X-Pitchstone-Api") == String(apiVersion))
        #expect(apiVersion == 1)
    }
}
