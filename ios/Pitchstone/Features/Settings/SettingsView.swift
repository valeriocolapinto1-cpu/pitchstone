import PitchstoneSync
import SwiftUI

/// Collegamento al Worker: indirizzo e service token di Cloudflare Access.
/// Il token resta nel Keychain di questo iPad.
struct SettingsView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(\.dismiss) private var dismiss
    @State private var workerURL = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var chatUsesGemini = true
    /// "Rivedi la presentazione": RootView la apre quando questo foglio è chiuso.
    var onReplayOnboarding: () -> Void = {}

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://ai-proxy.esempio.workers.dev", text: $workerURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Indirizzo del Worker")
                }
                Section {
                    TextField("Client ID", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Client Secret", text: $clientSecret)
                } header: {
                    Text("Service token di Cloudflare Access")
                } footer: {
                    if notes.hasCredentials {
                        Text("Un token è già salvato nel Keychain. Lascia vuoto per mantenerlo.")
                    } else {
                        Text("Il token si salva solo nel Keychain di questo iPad.")
                    }
                }
                Section {
                    LabeledContent("Dispositivo", value: notes.deviceID)
                    LabeledContent("Stato", value: statusText)
                    if !notes.rejections.isEmpty {
                        ForEach(notes.rejections, id: \.id) { rejection in
                            LabeledContent("Rifiutata", value: rejection.reason)
                        }
                    }
                } header: {
                    Text("Sincronizzazione")
                } footer: {
                    Text("I nodi di salute non lasciano mai questo iPad.")
                }
                Section {
                    Toggle("Usa Gemini quando sei online", isOn: $chatUsesGemini)
                } header: {
                    Text("Chat")
                } footer: {
                    Text("Gemini passa dal Worker e riceve solo i frammenti degli appunti pertinenti, mai i dati di salute. Offline, o se Gemini non risponde, la chat usa il modello sul dispositivo.")
                }
                Section {
                    ForEach(AppShortcut.allCases) { shortcut in
                        LabeledContent {
                            Text(shortcut.display)
                                .monospaced()
                        } label: {
                            Label(shortcut.title, systemImage: shortcut.symbol)
                        }
                    }
                } header: {
                    Text("Scorciatoie da tastiera")
                } footer: {
                    Text("Con una tastiera esterna, tieni premuto ⌘ per vederle tutte.")
                }
                Section {
                    Button("Rivedi la presentazione") {
                        onReplayOnboarding()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Impostazioni")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        notes.chatUsesGemini = chatUsesGemini
                        notes.saveSyncSettings(workerURL: workerURL, clientID: clientID, clientSecret: clientSecret)
                        dismiss()
                    }
                    .disabled(!workerURL.isEmpty && !workerURL.hasPrefix("https://"))
                }
            }
            .onAppear {
                workerURL = notes.workerURL
                chatUsesGemini = notes.chatUsesGemini
            }
        }
    }

    private var statusText: String {
        switch notes.syncStatus {
        case .notConfigured: String(localized: "Non configurata")
        case .idle(nil): String(localized: "Pronta")
        case .idle(let date?): String(localized: "Ultima: \(date.formatted(date: .omitted, time: .shortened))")
        case .syncing: String(localized: "In corso")
        case .failed(let message): String(localized: "Errore: \(message)")
        }
    }
}
