import Foundation
@testable import PitchstoneSync

/// Server in memoria con la stessa semantica di sync_push e sync_pull
/// (backend/supabase/migrations/20261013120000_sync.sql). Le funzioni SQL sono
/// testate a parte con pgTAP e nel test end-to-end del Worker.
final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var seq: Int64 = 0
    private(set) var nodes: [UUID: (NodeRecord, Int64)] = [:]
    private(set) var edges: [UUID: (EdgeRecord, Int64)] = [:]
    private var versions: [(NodeVersionRecord, Int64)] = []
    private(set) var pages: [UUID: (InkPageRecord, Int64)] = [:]
    /// Byte massimi di una risposta di pull, come sync_pull (circa 4 MB).
    var maxPullBytes = 4_000_000
    /// Push ricevuti, per verificare i lotti.
    private(set) var pushSizes: [Int] = []
    private var purged: [(Entity, UUID, Int64)] = []

    func node(_ id: UUID) -> NodeRecord? { lock.withLock { nodes[id]?.0 } }
    func inkPages(of nodeID: UUID) -> [InkPageRecord] {
        lock.withLock { pages.values.map(\.0).filter { $0.nodeID == nodeID }.sorted { $0.pageNo < $1.pageNo } }
    }
    func history(_ id: UUID) -> [NodeVersionRecord] { lock.withLock { versions.map(\.0).filter { $0.nodeID == id } } }
    var nodeCount: Int { lock.withLock { nodes.count } }

    private func next() -> Int64 {
        seq += 1
        return seq
    }

    func push(_ request: PushRequest) -> PushResponse {
        lock.withLock {
            pushSizes.append(request.changes.count)
            return PushResponse(results: request.changes.map { change in
                switch change.payload {
                case .node(let n): applyNode(n, base: change.baseVersion, device: request.deviceID)
                case .edge(let e): applyEdge(e, base: change.baseVersion)
                case .inkPage(let p): applyInk(p, base: change.baseVersion, device: request.deviceID)
                }
            })
        }
    }

    private func applyNode(_ n: NodeRecord, base: Int?, device: String) -> PushResult {
        if n.type == .health || n.area == .salute {
            return PushResult(entity: .node, id: n.id, status: .rejected, error: "23514")
        }
        var result = n
        result.deviceID = device
        result.updatedAt = Date()
        let status: PushResult.Status
        let old = nodes[n.id]?.0
        if let cur = old {
            if base == cur.version {
                status = .updated
            } else {
                status = .merged
                let baseBody = versions.first { $0.0.nodeID == n.id && $0.0.version == base }?.0.bodyMD
                if cur.bodyMD == n.bodyMD || n.bodyMD == baseBody || n.bodyMD.isEmpty {
                    result.bodyMD = cur.bodyMD
                } else if cur.bodyMD == baseBody || cur.bodyMD.isEmpty {
                    result.bodyMD = n.bodyMD
                } else {
                    result.bodyMD = "\(cur.bodyMD)\n\n---\n\n<!-- conflitto: versione da \(device) -->\n\n\(n.bodyMD)"
                }
                result.tags = Array(Set(cur.tags + n.tags)).sorted()
                result.deletedAt = (cur.deletedAt != nil && n.deletedAt != nil) ? max(cur.deletedAt!, n.deletedAt!) : nil
            }
            result.version = cur.version + 1
        } else {
            status = .created
            result.version = 1
        }
        nodes[n.id] = (result, next())
        if old == nil || old!.bodyMD != result.bodyMD {
            let v = NodeVersionRecord(id: UUID(), nodeID: n.id, version: result.version, bodyMD: result.bodyMD,
                                      createdAt: Date(), deviceID: device)
            versions.append((v, next()))
        }
        purged.removeAll { $0.0 == .node && $0.1 == n.id }
        return PushResult(entity: .node, id: n.id, status: status, node: result)
    }

    private func applyEdge(_ e: EdgeRecord, base: Int?) -> PushResult {
        guard nodes[e.sourceID] != nil, nodes[e.targetID] != nil else {
            return PushResult(entity: .edge, id: e.id, status: .rejected, error: "23503")
        }
        var result = e
        let status: PushResult.Status
        if let cur = edges[e.id]?.0 {
            status = base == cur.version ? .updated : .merged
            if status == .merged {
                result.deletedAt = (cur.deletedAt != nil && e.deletedAt != nil) ? e.deletedAt : nil
            }
            result.version = cur.version + 1
        } else {
            status = .created
            result.version = 1
        }
        edges[e.id] = (result, next())
        return PushResult(entity: .edge, id: e.id, status: status, edge: result)
    }

    /// Come sync_apply_ink: in un conflitto la pagina del server resta e il disegno
    /// del client diventa una nuova pagina dello stesso nodo.
    private func applyInk(_ p: InkPageRecord, base: Int?, device: String) -> PushResult {
        guard nodes[p.nodeID] != nil else {
            return PushResult(entity: .inkPage, id: p.id, status: .rejected, error: "23503")
        }
        var result = p
        result.deviceID = device
        let status: PushResult.Status
        if let cur = pages[p.id]?.0 {
            if base == cur.version {
                status = .updated
                result.version = cur.version + 1
            } else if cur.inkData == p.inkData {
                status = .merged
                result = cur
                result.version = cur.version + 1
            } else if cur.deletedAt != nil, p.deletedAt == nil {
                status = .merged
                result.version = cur.version + 1
            } else {
                status = .merged
                result = cur
                if p.deletedAt == nil, !p.inkData.isEmpty {
                    let nextPage = (pages.values.filter { $0.0.nodeID == p.nodeID }.map(\.0.pageNo).max() ?? -1) + 1
                    let copy = InkPageRecord(nodeID: p.nodeID, pageNo: nextPage, background: p.background, inkData: p.inkData,
                                             version: 1, createdAt: Date(), updatedAt: Date(), deviceID: device)
                    pages[copy.id] = (copy, next())
                }
                return PushResult(entity: .inkPage, id: p.id, status: status, inkPage: result)
            }
        } else {
            status = .created
            result.version = 1
        }
        pages[p.id] = (result, next())
        return PushResult(entity: .inkPage, id: p.id, status: status, inkPage: result)
    }

    func pull(_ request: PullRequest) -> PullResponse {
        lock.withLock {
            var all: [(Int64, IncomingChange)] = []
            all += nodes.values.map { ($0.1, .node($0.0)) }
            all += edges.values.map { ($0.1, .edge($0.0)) }
            all += versions.map { ($0.1, .nodeVersion($0.0)) }
            all += pages.values.map { ($0.1, .inkPage($0.0)) }
            all += purged.map { ($0.2, .purged($0.0, $0.1)) }
            let newer = all.filter { $0.0 > request.cursor }.sorted { $0.0 < $1.0 }
            var page: [(Int64, IncomingChange)] = []
            var bytes = 0
            for item in newer.prefix(request.limit) {
                if case .inkPage(let p) = item.1 { bytes += p.inkData.count * 4 / 3 } else { bytes += 300 }
                if bytes > maxPullBytes, !page.isEmpty { break }
                page.append(item)
            }
            return PullResponse(changes: page.map(\.1), cursor: page.last?.0 ?? request.cursor,
                                hasMore: newer.count > page.count)
        }
    }

    /// Come purge_trash: rimuove nodi e archi nel cestino da più di `age`.
    func purge(olderThan cutoff: Date) {
        lock.withLock {
            let expired = nodes.values.filter { ($0.0.deletedAt ?? .distantFuture) < cutoff }.map(\.0.id)
            for (id, (e, _)) in edges where expired.contains(e.sourceID) || expired.contains(e.targetID)
                || (e.deletedAt ?? .distantFuture) < cutoff {
                edges[id] = nil
                purged.append((.edge, id, next()))
            }
            for (id, (p, _)) in pages where expired.contains(p.nodeID) || (p.deletedAt ?? .distantFuture) < cutoff {
                pages[id] = nil
                purged.append((.inkPage, id, next()))
            }
            for id in expired {
                nodes[id] = nil
                versions.removeAll { $0.0.nodeID == id }
                purged.append((.node, id, next()))
            }
        }
    }
}

/// Trasporto che collega un dispositivo al server finto, con la rete simulabile.
final class FakeTransport: SyncTransport, @unchecked Sendable {
    let server: FakeServer
    private let lock = NSLock()
    private var _online = true
    var online: Bool {
        get { lock.withLock { _online } }
        set { lock.withLock { _online = newValue } }
    }
    /// Eseguito dopo che il server ha applicato il push, prima che la risposta arrivi.
    var afterPush: (@Sendable () async -> Void)?
    /// Eseguito prima che il server riceva il push (richiesta già partita).
    var beforePush: (@Sendable () async -> Void)?

    init(server: FakeServer) {
        self.server = server
    }

    func push(_ request: PushRequest) async throws -> PushResponse {
        guard online else { throw URLError(.notConnectedToInternet) }
        // La richiesta deve essere codificabile come in produzione.
        _ = try WireCoding.encoder().encode(request)
        if let beforePush { await beforePush() }
        let response = server.push(request)
        if let afterPush { await afterPush() }
        return response
    }

    func pull(_ request: PullRequest) async throws -> PullResponse {
        guard online else { throw URLError(.notConnectedToInternet) }
        return server.pull(request)
    }
}

/// Un dispositivo: archivio locale, repository e motore di sync.
final class Clock: @unchecked Sendable {
    var now = Date()
}

@MainActor
final class Device {
    let store = InMemoryStore()
    let repository: Repository
    let engine: SyncEngine
    let transport: FakeTransport
    let clock = Clock()

    init(_ name: String, server: FakeServer) {
        transport = FakeTransport(server: server)
        let clock = clock
        repository = Repository(store: store, deviceID: name, now: { clock.now })
        engine = SyncEngine(store: store, transport: transport, deviceID: name)
    }
}
