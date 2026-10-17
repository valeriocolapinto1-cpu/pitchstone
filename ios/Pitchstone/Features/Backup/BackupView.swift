import PitchstoneImport
import PitchstoneSync
import SwiftUI
import UniformTypeIdentifiers

/// Esportazione degli appunti in Markdown e backup cifrato dei dati di salute.
struct BackupView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(\.dismiss) private var dismiss
    @State private var includeHealth = false
    @State private var exportingMarkdown = false
    @State private var password = ""
    @State private var confirm = ""
    @State private var backupFile: DataFile?
    /// Allegati rimasti fuori dal backup, detti quando il file è salvato.
    @State private var missingFiles = 0
    @State private var restoring = false
    @State private var restorePassword = ""
    @State private var message: String?
    @State private var confirmingHealthExport = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Includi i dati di salute", isOn: $includeHealth)
                    Button("Esporta in una cartella Markdown") {
                        // I file Markdown non sono cifrati: i dati di salute escono dalla protezione dell'app.
                        if includeHealth { confirmingHealthExport = true } else { exportingMarkdown = true }
                    }
                } header: {
                    Text("Esportazione")
                } footer: {
                    if includeHealth {
                        Text("Attenzione: i file Markdown non sono cifrati. Con i dati di salute dentro, chi apre la cartella (o il servizio dove la salvi) li legge. Per i dati di salute usa il backup cifrato qui sotto.")
                    } else {
                        Text("Un file .md per nodo con tipo, area e tag nel frontmatter: si apre con Obsidian. Il PDF di un singolo nodo si esporta dal nodo.")
                    }
                }
                Section {
                    SecureField("Password (almeno 8 caratteri)", text: $password)
                    SecureField("Ripeti la password", text: $confirm)
                    Button("Crea il backup cifrato") {
                        do {
                            let archive = notes.healthArchive()
                            backupFile = DataFile(data: try HealthBackup.seal(archive, password: password))
                            missingFiles = archive.missingFiles.count
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                    .disabled(password.count < 8 || password != confirm)
                } header: {
                    Text("Backup dei dati di salute")
                } footer: {
                    Text("I dati di salute non vanno mai sul server: questo file cifrato è il loro unico backup. Salvalo dove vuoi (File, una chiavetta); senza la password non si apre e non si recupera.")
                }
                Section {
                    SecureField("Password del backup", text: $restorePassword)
                    Button("Ripristina da un file") { restoring = true }
                        .disabled(restorePassword.isEmpty)
                } header: {
                    Text("Ripristino")
                } footer: {
                    Text("Aggiunge i nodi che mancano su questo iPad, senza sovrascrivere quelli presenti.")
                }
            }
            .navigationTitle("Backup ed esportazione")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .confirmationDialog(
                "Esportare anche i dati di salute in chiaro?", isPresented: $confirmingHealthExport, titleVisibility: .visible
            ) {
                Button("Esporta con i dati di salute", role: .destructive) { exportingMarkdown = true }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("I file Markdown non sono cifrati. Il backup cifrato è la via giusta per i dati di salute.")
            }
            .fileExporter(
                isPresented: $exportingMarkdown,
                document: MarkdownFolder(files: VaultExport.files(notes.nodes, includeSensitive: includeHealth)),
                contentType: .folder, defaultFilename: "Pitchstone"
            ) { result in
                if case .failure(let error) = result { message = error.localizedDescription }
            }
            .fileExporter(
                isPresented: Binding(get: { backupFile != nil }, set: { if !$0 { backupFile = nil } }),
                document: backupFile, contentType: .data,
                defaultFilename: "Pitchstone-salute-\(Date().formatted(.iso8601.year().month().day())).psbackup"
            ) { result in
                switch result {
                case .success:
                    password = ""
                    confirm = ""
                    message = missingFiles == 0
                        ? String(localized: "Backup salvato.")
                        : String(localized: "Backup salvato, ma \(missingFiles) allegati non si leggono e mancano.")
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
            .fileImporter(isPresented: $restoring, allowedContentTypes: [.data]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let archive = try HealthBackup.open(try Data(contentsOf: url), password: restorePassword)
                    let added = try notes.restoreHealth(archive)
                    restorePassword = ""
                    message = String(localized: "Ripristinati \(added) nodi.")
                } catch {
                    message = error.localizedDescription
                }
            }
            .alert("Backup", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }
}
