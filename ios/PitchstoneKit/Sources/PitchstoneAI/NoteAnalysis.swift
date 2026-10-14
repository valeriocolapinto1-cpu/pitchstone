import Foundation
import PitchstoneNotes
import PitchstoneSync

/// Nodo proposto dall'analisi di un appunto.
public struct ProposedNode: Sendable, Equatable, Codable, Hashable {
    public var title: String
    public var type: NodeType
    public var summary: String

    public init(title: String, type: NodeType, summary: String) {
        self.title = title
        self.type = type
        self.summary = summary
    }
}

public struct ProposedLink: Sendable, Equatable, Codable, Hashable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public struct ProposedGraph: Sendable, Equatable, Codable {
    public var nodes: [ProposedNode]
    public var links: [ProposedLink]

    public init(nodes: [ProposedNode], links: [ProposedLink]) {
        self.nodes = nodes
        self.links = links
    }
}

/// Proposta che aspetta l'utente: persone e possibili dati di salute.
public struct PendingProposal: Sendable, Equatable, Codable, Hashable, Identifiable {
    public enum Reason: String, Sendable, Codable {
        case person, health
    }

    public var node: ProposedNode
    public var reason: Reason
    public var id: String { NodeTitle.key(node.title) }

    public init(node: ProposedNode, reason: Reason) {
        self.node = node
        self.reason = reason
    }
}

/// Cosa fare con una proposta: nodi da creare subito, nodi da confermare,
/// archi tra titoli (il nodo analizzato compreso).
public struct AnalysisPlan: Sendable, Equatable {
    public var create: [ProposedNode]
    public var confirm: [PendingProposal]
    /// Coppie di titoli; si risolvono dopo la creazione dei nodi.
    public var links: [ProposedLink]
}

public enum NoteAnalysis {
    public static let maxNodes = 8
    /// Testo analizzato al massimo: un appunto lungo si legge dall'inizio.
    public static let maxInput = 6000

    public static let instructions = """
    Analizzi un appunto di studio e ne estrai i concetti principali per un grafo di conoscenza. \
    Rispondi SOLO con un oggetto JSON, senza altro testo, in questa forma: \
    {"nodes":[{"title":"...","type":"concept","summary":"..."}],"links":[{"from":"...","to":"..."}]}. \
    "type" è uno tra concept, idea, project, exam, person. Al massimo \(maxNodes) nodi, titoli brevi \
    (1-5 parole) nella lingua dell'appunto, riassunti di una frase. Preferisci i titoli già esistenti \
    quando parlano della stessa cosa. "links" collega titoli tra loro o con il titolo dell'appunto. \
    Non inventare concetti che non sono nell'appunto.
    """

    /// Il prompt per un appunto. Mai per un nodo sensibile o sospetto: lo decide chi chiama.
    public static func prompt(for node: NodeRecord, existingTitles: [String]) -> ChatPrompt {
        let titles = existingTitles.prefix(150).joined(separator: "; ")
        let question = """
        TITOLO: \(node.title)
        TITOLI GIÀ ESISTENTI: \(titles.isEmpty ? "nessuno" : titles)
        APPUNTO:
        \(String(node.bodyMD.prefix(maxInput)))
        """
        return ChatPrompt(instructions: instructions, sources: [], history: [], question: question, localOnly: false,
                          includesSources: false)
    }

    /// Il JSON della risposta, anche se il modello lo racchiude in un blocco di codice o
    /// aggiunge frasi prima e dopo. Tipi sconosciuti diventano `concept`; `health` non è ammesso.
    public static func parse(_ answer: String) -> ProposedGraph? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let data = String(answer[start...end]).data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let nodes = (raw["nodes"] as? [[String: Any]] ?? []).compactMap { item -> ProposedNode? in
            guard let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, title.count <= 80 else { return nil }
            var type = (item["type"] as? String).flatMap(NodeType.init(rawValue:)) ?? .concept
            if type == .health { type = .concept }
            let summary = (item["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ProposedNode(title: title, type: type, summary: String(summary.prefix(400)))
        }
        let links = (raw["links"] as? [[String: Any]] ?? []).compactMap { item -> ProposedLink? in
            guard let from = item["from"] as? String, let to = item["to"] as? String else { return nil }
            return ProposedLink(from: from, to: to)
        }
        return ProposedGraph(nodes: nodes, links: links)
    }

    /// Divide la proposta: titoli già esistenti diventano solo archi, le persone e i
    /// possibili dati di salute vanno in conferma, il resto si crea. Archi verso titoli
    /// sconosciuti o verso se stessi si scartano.
    public static func plan(_ graph: ProposedGraph, source: NodeRecord, existingTitles: [String]) -> AnalysisPlan {
        let sourceKey = NodeTitle.key(source.title)
        let existing = Set(existingTitles.map(NodeTitle.key))
        var seen: Set<String> = [sourceKey]
        var create: [ProposedNode] = []
        var confirm: [PendingProposal] = []
        var known = existing.union([sourceKey])
        // Nodi già nel grafo: nessun nodo nuovo, ma l'arco dal nodo analizzato sì.
        var links: [ProposedLink] = []
        for node in graph.nodes {
            let key = NodeTitle.key(node.title)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            if existing.contains(key) {
                links.append(ProposedLink(from: source.title, to: node.title))
                continue
            }
            guard create.count + confirm.count < maxNodes else { continue }
            if HealthDetector.assess(node.title + "\n" + node.summary).suspected || isHealthTitle(node.title) {
                confirm.append(PendingProposal(node: node, reason: .health))
            } else if node.type == .person {
                confirm.append(PendingProposal(node: node, reason: .person))
            } else {
                create.append(node)
                known.insert(key)
                links.append(ProposedLink(from: source.title, to: node.title))
            }
        }
        var pairs = Set(links.map { [NodeTitle.key($0.from), NodeTitle.key($0.to)].sorted() })
        for link in graph.links {
            let a = NodeTitle.key(link.from), b = NodeTitle.key(link.to)
            guard a != b, known.contains(a), known.contains(b) else { continue }
            guard pairs.insert([a, b].sorted()).inserted else { continue }
            links.append(link)
        }
        return AnalysisPlan(create: create, confirm: confirm, links: links)
    }

    /// Un titolo come "Terapia" o "Ansia" da solo non ha indizi personali, ma
    /// creato in automatico sarebbe comunque un nodo sulla salute: meglio chiedere.
    static func isHealthTitle(_ title: String) -> Bool {
        let words = " " + TextSearch.normalize(title) + " "
        return HealthDetector.terms.contains { words.contains(" " + $0) }
    }
}

extension NoteAnalysis {
    /// Analizza con il modello locale; con Gemini solo se `allowOnline` (analisi chiesta
    /// dall'utente) e se il locale manca o risponde male.
    public static func run(
        _ node: NodeRecord, existingTitles: [String], local: ChatProvider?, online: ChatProvider?, allowOnline: Bool
    ) async throws -> AnalysisPlan {
        guard !Privacy.isSensitive(node), !HealthDetector.assess(node.title + "\n" + node.bodyMD).suspected else {
            throw ChatError.sensitiveContent
        }
        let prompt = Self.prompt(for: node, existingTitles: existingTitles)
        var providers: [ChatProvider] = []
        if let local, await local.isAvailable() { providers.append(local) }
        if allowOnline, let online, await online.isAvailable() { providers.append(online) }
        guard !providers.isEmpty else { throw ChatError.noProvider }
        var lastError: Error = ChatError.invalidAnswer
        for provider in providers {
            do {
                let answer = try await provider.reply(to: prompt)
                if let graph = parse(answer) {
                    return plan(graph, source: node, existingTitles: existingTitles)
                }
                lastError = ChatError.invalidAnswer
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }
}
