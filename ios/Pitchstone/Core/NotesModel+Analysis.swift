import Foundation
import PitchstoneAI
import PitchstoneNotes
import PitchstoneStore
import PitchstoneSync

/// Analisi automatica degli appunti (ADR 0010): rilevamento dei dati di salute,
/// estrazione di nodi e collegamenti, conferma per persone e salute.
extension NotesModel {
    struct AnalysisOutcome: Equatable {
        var created: [String]
        var linked: Int
        var pending: Int
    }

    // MARK: Salute

    /// Testo su cui decide il rilevatore: titolo, corpo e testo estratto da allegati e
    /// scrittura a mano (un diario scritto a penna o un referto in PDF contano come il corpo).
    private func healthText(_ node: NodeRecord) -> (key: String, text: String) {
        let extracted = extractedByNode[node.id] ?? ""
        let key = "\(node.updatedAt.timeIntervalSinceReferenceDate)|\(node.title.count)|\(node.bodyMD.count)|\(extracted.utf8.count)"
        return (key, node.title + "\n" + node.bodyMD + "\n" + extracted)
    }

    /// Esito del rilevatore, ricalcolato solo quando il nodo o il suo testo estratto cambiano.
    func assessHealth(_ node: NodeRecord) -> HealthAssessment {
        let (key, text) = healthText(node)
        if let cached = assessments[node.id], cached.key == key { return cached.result }
        let result = HealthDetector.assess(text)
        assessments[node.id] = (key, result)
        return result
    }

    /// Sospetto e non ancora giudicato: resta sull'iPad e fuori da ogni prompt, anche nel
    /// cestino (un nodo eliminato si sincronizza con tutto il suo testo). I segnali già
    /// giudicati innocui non contano più; uno nuovo sì.
    func isHeld(_ node: NodeRecord) -> Bool {
        guard !Privacy.isSensitive(node) else { return false }
        let assessment = assessHealth(node)
        guard assessment.suspected else { return false }
        return !assessment.signals.isSubset(of: dismissedSignals[node.id] ?? [])
    }

    func refreshAnalysisState() {
        extractedByNode = Dictionary(grouping: extractedTexts, by: \.nodeID)
            .mapValues { $0.map(\.text).joined(separator: "\n") }
        let records = analysisStore.all()
        dismissedSignals = records.compactMapValues { $0.dismissedSignals.isEmpty ? nil : Set($0.dismissedSignals) }
        healthSuspects = Set(nodes.filter(isHeld).map(\.id))
        var pending: [UUID: [PendingProposal]] = [:]
        for (id, record) in records where !record.pending.isEmpty {
            if let proposals = try? JSONDecoder().decode([PendingProposal].self, from: record.pending), !proposals.isEmpty,
               node(id)?.deletedAt == nil {
                pending[id] = proposals
            }
        }
        pendingProposals = pending
    }

    /// "Non è un dato di salute": i segnali attuali non bloccano più il nodo.
    func dismissHealth(_ id: UUID) {
        guard let node = node(id) else { return }
        var record = analysisStore.record(id) ?? AnalysisRecord(nodeID: id)
        record.dismissedSignals = Array(Set(record.dismissedSignals).union(assessHealth(node).signals)).sorted()
        analysisStore.save(record)
        dismissedSignals[id] = Set(record.dismissedSignals)
        reload()
        // Come ogni altra modifica: dopo qualche secondo di calma, non subito. Un tap per sbaglio si può ripensare.
        scheduleSync()
    }

    /// "È un dato di salute": un nodo mai sincronizzato passa all'area salute; uno già
    /// sul server non può (ADR 0001), quindi il contenuto va in un nodo di salute nuovo
    /// e l'originale, svuotato, va nel cestino. Il testo trattenuto non parte mai.
    @discardableResult
    func confirmHealth(_ id: UUID) -> UUID? {
        guard let node = node(id) else { return nil }
        // Già sul server anche se la versione locale non lo dice ancora (una modifica in attesa parte da una base).
        let onServer = node.version > 0 || store.pendingChange(.node, id)?.baseVersion != nil
        if !onServer {
            let moved = update(id) { $0.area = .salute }
            guard moved else { return nil }
            onHealthConfirmed?(id)
            return id
        }
        let copy = repository.createNode(type: node.type, title: node.title, body: node.bodyMD, area: .salute, tags: node.tags)
        // Pagine a penna e allegati mai caricati vanno con il testo: nessuno parte più.
        repository.moveLocalContent(from: id, to: copy.id)
        do {
            _ = try repository.updateNode(id) {
                $0.title = String(localized: "Nota spostata nei dati di salute")
                $0.bodyMD = ""
                $0.tags = []
            }
            try repository.trashNode(id)
        } catch {
            errorMessage = error.localizedDescription
        }
        analysisStore.remove(id)
        // I quiz nati dal testo di salute si cancellano, e la nota sparisce dal server con il suo storico.
        onHealthConfirmed?(id)
        queueRedaction(id)
        changed()
        return copy.id
    }

    // MARK: Estrazione

    /// Modelli per i quiz: gli stessi dell'analisi.
    var quizProviders: (local: ChatProvider?, online: ChatProvider?) { analysisProviders }

    private var analysisProviders: (local: ChatProvider?, online: ChatProvider?) {
        if let analysisProvidersOverride { return analysisProvidersOverride }
        let online = chatUsesGemini ? workerTransport.map(WorkerChatProvider.init(transport:)) : nil
        return (LocalModelProvider(), online)
    }

    /// Analizza un nodo e applica la proposta: crea i nodi sicuri e gli archi, mette in
    /// attesa persone e possibili dati di salute. `allowOnline`: solo su richiesta.
    func analyze(_ id: UUID, allowOnline: Bool) async throws -> AnalysisOutcome {
        guard let source = node(id), !isSensitive(id) else { throw ChatError.sensitiveContent }
        let titles = activeNodes.filter { !Privacy.isSensitive($0) && !healthSuspects.contains($0.id) && $0.id != id }.map(\.title)
        let providers = analysisProviders
        let plan = try await NoteAnalysis.run(
            source, existingTitles: titles, local: providers.local, online: providers.online, allowOnline: allowOnline,
            dismissedSignals: dismissedSignals[id] ?? [])
        return apply(plan, to: source)
    }

    private func apply(_ plan: AnalysisPlan, to source: NodeRecord) -> AnalysisOutcome {
        // Il nodo può essere cambiato mentre il modello rispondeva.
        guard let current = node(source.id), current.deletedAt == nil, !isSensitive(source.id) else {
            return AnalysisOutcome(created: [], linked: 0, pending: 0)
        }
        var created: [String] = []
        for proposal in plan.create where node(titled: proposal.title) == nil {
            createNode(type: proposal.type, title: proposal.title, area: current.area, body: proposal.summary)
            created.append(proposal.title)
        }
        var linked = 0
        for link in plan.links {
            guard let a = node(titled: link.from)?.id, let b = node(titled: link.to)?.id, a != b,
                  !isSensitive(a), !isSensitive(b), !connected(a, b) else { continue }
            perform { try repository.createEdge(from: a, to: b, kind: .ai) }
            linked += 1
        }
        var record = analysisStore.record(source.id) ?? AnalysisRecord(nodeID: source.id)
        var pending = (try? JSONDecoder().decode([PendingProposal].self, from: record.pending)) ?? []
        var added = 0
        for proposal in plan.confirm
        where !pending.contains(where: { $0.id == proposal.id }) && !record.discarded.contains(proposal.id)
            && node(titled: proposal.node.title) == nil {
            pending.append(proposal)
            added += 1
        }
        record.pending = pending.isEmpty ? Data() : ((try? JSONEncoder().encode(pending)) ?? Data())
        // Il testo che il modello ha letto, non quello di adesso: una modifica nel frattempo si rianalizza.
        record.analyzedFingerprint = analysisFingerprint(source)
        analysisStore.save(record)
        reload()
        return AnalysisOutcome(created: created, linked: linked, pending: added)
    }

    private func connected(_ a: UUID, _ b: UUID) -> Bool {
        edges.contains { $0.deletedAt == nil && Set([$0.sourceID, $0.targetID]) == Set([a, b]) }
    }

    func analysisFingerprint(_ node: NodeRecord) -> String {
        TextSearch.fingerprint(Data((node.title + "\n" + node.bodyMD).utf8))
    }

    /// Conferma una proposta: le persone vanno nell'area persone, la salute in un nodo
    /// di salute (solo locale). Il nodo nuovo si collega a quello analizzato.
    @discardableResult
    func confirmProposal(_ proposal: PendingProposal, from sourceID: UUID) -> UUID {
        removeProposal(proposal, from: sourceID)
        let created: NodeRecord = switch proposal.reason {
        case .person: createNode(type: .person, title: proposal.node.title, area: .persone, body: proposal.node.summary)
        case .health: createNode(type: .health, title: proposal.node.title, area: .salute, body: proposal.node.summary)
        }
        if node(sourceID)?.deletedAt == nil {
            perform { try repository.createEdge(from: sourceID, to: created.id, kind: .ai) }
        }
        return created.id
    }

    func discardProposal(_ proposal: PendingProposal, from sourceID: UUID) {
        removeProposal(proposal, from: sourceID)
        if var record = analysisStore.record(sourceID), !record.discarded.contains(proposal.id) {
            record.discarded.append(proposal.id)
            analysisStore.save(record)
        }
        reload()
    }

    private func removeProposal(_ proposal: PendingProposal, from sourceID: UUID) {
        guard var record = analysisStore.record(sourceID) else { return }
        var pending = (try? JSONDecoder().decode([PendingProposal].self, from: record.pending)) ?? []
        pending.removeAll { $0.id == proposal.id }
        record.pending = pending.isEmpty ? Data() : ((try? JSONEncoder().encode(pending)) ?? Data())
        analysisStore.save(record)
    }

    // MARK: In automatico

    /// Dopo le modifiche, con il modello locale e solo per i nodi toccati in questa
    /// sessione: gratis, offline, senza consumare la quota di Gemini.
    func scheduleAnalysis() {
        // Un'analisi in corso non si interrompe: crea nodi, e ogni nodo nuovo la riprogrammerebbe.
        guard !analysisRunning else {
            analyzeAgain = true
            return
        }
        analyzing?.cancel()
        analyzing = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
            guard let self else { return }
            analysisRunning = true
            await analyzeRecentEdits()
            analysisRunning = false
            if analyzeAgain {
                analyzeAgain = false
                scheduleAnalysis()
            }
        }
    }

    func analyzeRecentEdits() async {
        guard let local = analysisProviders.local, await local.isAvailable() else { return }
        for id in recentlyEdited {
            guard let node = node(id), node.deletedAt == nil, !isSensitive(id), !node.tags.contains(ChatTranscript.tag),
                  node.bodyMD.count >= 200 else {
                recentlyEdited.remove(id)
                continue
            }
            guard analysisStore.record(id)?.analyzedFingerprint != analysisFingerprint(node) else {
                recentlyEdited.remove(id)
                continue
            }
            // Esce dalla coda solo se l'analisi è riuscita.
            if (try? await analyze(id, allowOnline: false)) != nil { recentlyEdited.remove(id) }
        }
    }
}
