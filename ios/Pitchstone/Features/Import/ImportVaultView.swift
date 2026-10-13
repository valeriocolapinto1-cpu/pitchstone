import PitchstoneImport
import PitchstoneSync
import SwiftUI
import UniformTypeIdentifiers

/// Import di un vault Obsidian: si sceglie la cartella, si guarda cosa verrà creato,
/// poi si conferma. Le note di salute restano su questo iPad come quelle scritte qui.
struct ImportVaultView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var phase: Phase = .start
    @State private var folderName = ""
    @State private var contents: VaultContents?
    @State private var plan: VaultImportPlan?
    @State private var area: Area = .studio

    enum Phase: Equatable {
        case start, reading, ready, done(notes: Int, links: Int), failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .start:
                    Section {
                        Text("Scegli la cartella del vault. Ogni file .md diventa un nodo; i link [[...]], i tag e gli alias restano.")
                        Button("Scegli la cartella del vault") { choosing = true }
                    } footer: {
                        Text("Le cartelle nascoste (.obsidian, .trash) non vengono lette. PDF e immagini arriveranno con gli allegati.")
                    }
                case .reading:
                    Section { ProgressView("Lettura del vault…") }
                case .ready:
                    if let plan { preview(plan) }
                case .done(let count, let links):
                    Section {
                        Label("Importate \(count) note e \(links) collegamenti.", systemImage: "checkmark.circle")
                    }
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                        Button("Scegli un'altra cartella") { choosing = true }
                    }
                }
            }
            .navigationTitle("Importa da Obsidian")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isDone ? "Fine" : "Annulla") { dismiss() }
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): read(url)
                case .failure(let error): phase = .failed(error.localizedDescription)
                }
            }
            .onChange(of: area) { replan() }
        }
    }

    private var isDone: Bool {
        if case .done = phase { return true }
        return false
    }

    @ViewBuilder
    private func preview(_ plan: VaultImportPlan) -> some View {
        Section {
            Picker("Area delle note senza area", selection: $area) {
                ForEach(Area.allCases, id: \.self) { Text($0.graphName).tag($0) }
            }
        } header: {
            Text(folderName)
        } footer: {
            Text("L'area si prende dalla proprietà area, poi dalla prima cartella (Studio, Progetti…). Per le altre note vale questa.")
        }
        Section {
            LabeledContent("Note da creare", value: "\(plan.notes.count)")
            LabeledContent("Collegamenti", value: "\(plan.linkCount)")
            let health = plan.notes.filter { $0.area == .salute || $0.type == .health }.count
            if health > 0 {
                LabeledContent("Di salute, solo su questo iPad", value: "\(health)")
            }
            let existing = plan.skipped.filter { if case .alreadyExists = $0.reason { true } else { false } }
            if !existing.isEmpty {
                DisclosureGroup("Già presenti, non duplicate: \(existing.count)") {
                    ForEach(existing, id: \.path) { Text($0.path).font(.caption) }
                }
            }
            let unreadable = plan.skipped.filter { $0.reason == .tooLarge || $0.reason == .notText }
            if !unreadable.isEmpty {
                DisclosureGroup("Non lette (troppo grandi o non testo): \(unreadable.count)") {
                    ForEach(unreadable, id: \.path) { Text($0.path).font(.caption) }
                }
            }
            if !plan.unresolvedLinks.isEmpty {
                DisclosureGroup("Link a note che non esistono: \(plan.unresolvedLinks.count)") {
                    ForEach(plan.unresolvedLinks, id: \.self) { Text($0).font(.caption) }
                }
            }
            if !plan.otherFiles.isEmpty {
                DisclosureGroup("Altri file, per ora non importati: \(plan.otherFiles.count)") {
                    ForEach(plan.otherFiles, id: \.self) { Text($0).font(.caption) }
                }
            }
        }
        Section {
            Button("Importa \(plan.notes.count) note") {
                let result = notes.importVault(plan)
                phase = .done(notes: result.created.count, links: result.links)
            }
            .disabled(plan.notes.isEmpty)
        }
    }

    private func read(_ url: URL) {
        phase = .reading
        folderName = url.lastPathComponent
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let read = try await Task.detached(priority: .userInitiated) { try VaultReader.read(at: url) }.value
                contents = read
                replan()
                phase = .ready
            } catch {
                phase = .failed(String(localized: "Impossibile leggere la cartella: \(error.localizedDescription)"))
            }
        }
    }

    private func replan() {
        guard let contents else { return }
        plan = notes.importPlan(contents, area: area)
    }
}
