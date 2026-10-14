import Foundation
import Testing
@testable import PitchstoneSync
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Formato di rete")
struct WireTests {
    @Test("allegati: righe del database e annotazioni di un PDF")
    func attachments() throws {
        let json = """
        {"changes":[
          {"entity":"attachment","data":{"id":"30000000-0000-4000-8000-0000000000a1","node_id":null,"kind":"pdf",
            "storage_path":"30000000-0000-4000-8000-0000000000a1","size_bytes":104857600,"page_count":null,
            "sha256":"\(String(repeating: "ab", count: 32))","file_name":"Analisi.pdf","part_count":3,"version":2,
            "created_at":"2026-10-14T09:00:00.123456+00:00","updated_at":"2026-10-14T09:00:01+00:00","deleted_at":null,
            "device_id":"ipad-a","server_seq":42}},
          {"entity":"ink_page","data":{"id":"30000000-0000-4000-8000-000000000101","node_id":"30000000-0000-4000-8000-000000000001",
            "page_no":0,"background":"blank","ink_data":"AAE=","attachment_id":"30000000-0000-4000-8000-0000000000a1","pdf_page":4,
            "version":1,"created_at":"2026-10-14T09:00:00+00:00","updated_at":"2026-10-14T09:00:00+00:00","deleted_at":null,
            "device_id":"ipad-a","server_seq":43}}
        ],"cursor":43,"has_more":false}
        """
        let response = try WireCoding.decoder().decode(PullResponse.self, from: Data(json.utf8))
        guard case .attachment(let attachment) = response.changes[0], case .inkPage(let layer) = response.changes[1] else {
            Issue.record("entità non riconosciute")
            return
        }
        #expect(attachment.sizeBytes == 104_857_600)
        #expect(attachment.partCount == 3)
        #expect(attachment.isUploaded, "una riga del server ha già le parti nel bucket")
        #expect(layer.pdfPage == 4)
        #expect(layer.attachmentID == attachment.id)

        let encoded = try JSONSerialization.jsonObject(with: try WireCoding.encoder().encode(attachment)) as? [String: Any]
        #expect(encoded?["storage_path"] as? String == "30000000-0000-4000-8000-0000000000a1")
        #expect(encoded?["is_uploaded"] == nil && encoded?["isUploaded"] == nil, "lo stato del caricamento resta locale")
    }

    @Test("date di Postgres con microsecondi e fuso orario")
    func parsesPostgresDates() throws {
        let base = try #require(WireCoding.parseDate("2026-10-13T12:00:00Z"))
        #expect(WireCoding.parseDate("2026-10-13T12:00:00+00:00") == base)
        let micro = try #require(WireCoding.parseDate("2026-10-13T12:00:00.123456+00:00"))
        #expect(abs(micro.timeIntervalSince(base) - 0.123456) < 0.000_001)
        #expect(WireCoding.parseDate("2026-10-13T14:00:00.5+02:00") == base.addingTimeInterval(0.5))
        #expect(WireCoding.parseDate("ieri") == nil)
        #expect(WireCoding.parseDate("2026-10-13T12:00:00.+00:00") == nil)
    }

    @Test("decodifica la risposta reale di sync_pull")
    func decodesPull() throws {
        let json = """
        {"changes":[
          {"entity":"node","data":{"id":"10000000-0000-4000-8000-000000000001","type":"concept","title":"Limite","body_md":"v1",
            "area":"studio","tags":["analisi"],"version":1,"created_at":"2026-10-13T12:39:16.123456+00:00",
            "updated_at":"2026-10-13T12:39:16.123456+00:00","deleted_at":null,"device_id":"ipad-a","server_seq":7}},
          {"entity":"edge","data":{"id":"10000000-0000-4000-8000-000000000101","source_id":"10000000-0000-4000-8000-000000000001",
            "target_id":"10000000-0000-4000-8000-000000000001","kind":"manual","label":null,"created_at":"2026-10-13T12:39:16+00:00",
            "deleted_at":null,"version":1,"server_seq":8}},
          {"entity":"node_version","data":{"id":"10000000-0000-4000-8000-000000000201","node_id":"10000000-0000-4000-8000-000000000001",
            "version":1,"body_md":"v1","created_at":"2026-10-13T12:39:16.1+00:00","device_id":"ipad-a","server_seq":9}},
          {"entity":"purged","data":{"entity":"node","id":"10000000-0000-4000-8000-000000000004","purged_at":"2026-10-13T12:39:16+00:00","server_seq":10}},
          {"entity":"quiz","data":{}}
        ],"cursor":10,"has_more":false}
        """
        let response = try WireCoding.decoder().decode(PullResponse.self, from: Data(json.utf8))
        #expect(response.cursor == 10)
        #expect(response.hasMore == false)
        #expect(response.changes.count == 5)
        guard case .node(let node) = response.changes[0] else { Issue.record("atteso un nodo"); return }
        #expect(node.title == "Limite")
        #expect(node.tags == ["analisi"])
        #expect(node.deletedAt == nil)
        guard case .purged(.node, let id) = response.changes[3] else { Issue.record("atteso purged"); return }
        #expect(id.uuidString.lowercased() == "10000000-0000-4000-8000-000000000004")
        guard case .unknown = response.changes[4] else { Issue.record("entità sconosciuta ignorata"); return }
    }

    @Test("decodifica la risposta di sync_push, rifiuti compresi")
    func decodesPush() throws {
        let json = """
        {"results":[
          {"entity":"node","id":"10000000-0000-4000-8000-000000000001","status":"merged","record":{"id":"10000000-0000-4000-8000-000000000001",
            "type":"concept","title":"x","body_md":"a\\n\\n---\\n\\nb","area":"studio","tags":[],"version":4,
            "created_at":"2026-10-13T12:39:16+00:00","updated_at":"2026-10-13T12:39:16+00:00","deleted_at":null,"device_id":"b","server_seq":3}},
          {"entity":"node","id":"10000000-0000-4000-8000-000000000002","status":"rejected","error":"23514","message":"violates check constraint"}
        ]}
        """
        let response = try WireCoding.decoder().decode(PushResponse.self, from: Data(json.utf8))
        #expect(response.results[0].status == .merged)
        #expect(response.results[0].node?.version == 4)
        #expect(response.results[1].status == .rejected)
        #expect(response.results[1].node == nil)
    }

    @Test("il push invia deleted_at anche quando è null")
    func encodesRestore() throws {
        let node = NodeRecord(type: .concept, title: "x", area: .studio, createdAt: Date(timeIntervalSince1970: 0),
                              updatedAt: Date(timeIntervalSince1970: 0), deviceID: "a")
        let request = PushRequest(deviceID: "a", changes: [OutgoingChange(baseVersion: nil, payload: .node(node))])
        let json = try #require(String(data: try WireCoding.encoder().encode(request), encoding: .utf8))
        #expect(json.contains("\"deleted_at\":null"))
        #expect(json.contains("\"base_version\":null"))
        #expect(json.contains("\"device_id\":\"a\""))
        #expect(json.contains("\"created_at\":\"1970-01-01T00:00:00.000Z\""))
    }

    @Test("le richieste HTTP portano il service token di Access")
    func requestHasAccessHeaders() throws {
        let transport = HTTPSyncTransport(
            baseURL: try #require(URL(string: "https://ai.pitchstone.example")),
            credentials: AccessCredentials(clientID: "id.access", clientSecret: "segreto"))
        let request = try transport.makeRequest(path: "sync/pull", body: PullRequest(cursor: 5, limit: 100))
        #expect(request.url?.absoluteString == "https://ai.pitchstone.example/sync/pull")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "id.access")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "segreto")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Int]
        #expect(body == ["cursor": 5, "limit": 100])
    }
}
