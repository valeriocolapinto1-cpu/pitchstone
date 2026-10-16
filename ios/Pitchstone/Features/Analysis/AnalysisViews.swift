import PitchstoneAI
import PitchstoneSync
import SwiftUI

/// Avvisi sotto l'intestazione del nodo: possibile dato di salute, proposte da confermare.
struct AnalysisBanners: View {
    @Environment(NotesModel.self) private var notes
    let nodeID: UUID
    /// Salva il testo in corso prima di cambiare il nodo.
    let beforeAction: () -> Void
    /// Il nodo di salute creato al posto di uno già sincronizzato.
    let openMoved: (UUID) -> Void
    @State private var showingProposals = false

    var body: some View {
        VStack(spacing: 0) {
            if notes.healthSuspects.contains(nodeID) {
                banner(tint: .pink) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sembra un dato di salute").bold()
                            Text("Finché non scegli resta solo su questo iPad, fuori dalla sync e dalla chat.")
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "heart.text.square")
                    }
                    Spacer()
                    Button("È salute") {
                        beforeAction()
                        if let moved = notes.confirmHealth(nodeID), moved != nodeID { openMoved(moved) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                    Button("Non lo è") {
                        beforeAction()
                        notes.dismissHealth(nodeID)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let pending = notes.pendingProposals[nodeID], !pending.isEmpty {
                banner(tint: .accentColor) {
                    Label("\(pending.count) proposte dall'analisi da confermare", systemImage: "sparkles")
                    Spacer()
                    Button("Rivedi") { showingProposals = true }
                        .buttonStyle(.bordered)
                }
            }
        }
        .sheet(isPresented: $showingProposals) {
            AnalysisSheet(nodeID: nodeID, outcome: nil)
        }
    }

    private func banner(tint: Color, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) { content() }
            .font(.callout)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(tint.opacity(0.1))
    }
}

/// Risultato di un'analisi e proposte in attesa: persone e possibili dati di salute.
struct AnalysisSheet: View {
    @Environment(NotesModel.self) private var notes
    @Environment(\.dismiss) private var dismiss
    let nodeID: UUID
    let outcome: NotesModel.AnalysisOutcome?

    var body: some View {
        NavigationStack {
            List {
                if let outcome {
                    Section("Fatto") {
                        if outcome.created.isEmpty && outcome.linked == 0 {
                            Text("Nessun nodo nuovo: l'appunto è già collegato.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(outcome.created, id: \.self) { title in
                            Label(title, systemImage: "plus.circle")
                        }
                        if outcome.linked > 0 {
                            Label("\(outcome.linked) collegamenti nel grafo", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                }
                let pending = notes.pendingProposals[nodeID] ?? []
                if !pending.isEmpty {
                    Section {
                        ForEach(pending) { proposal in
                            VStack(alignment: .leading, spacing: 6) {
                                Label(proposal.node.title, systemImage: proposal.reason == .person ? "person" : "heart.text.square")
                                    .font(.headline)
                                if !proposal.node.summary.isEmpty {
                                    Text(proposal.node.summary).font(.callout).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button(proposal.reason == .person ? "Crea persona" : "Crea nodo di salute") {
                                        notes.confirmProposal(proposal, from: nodeID)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    Button("Scarta", role: .destructive) {
                                        notes.discardProposal(proposal, from: nodeID)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("Da confermare")
                    } footer: {
                        Text("Persone e dati di salute non si creano da soli. I nodi di salute restano solo su questo iPad.")
                    }
                }
            }
            .navigationTitle("Analisi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }
}
