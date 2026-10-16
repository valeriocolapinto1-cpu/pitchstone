import SwiftUI

/// Quando mostrare la presentazione: al primo avvio, finché non la si completa o salta.
enum OnboardingPolicy {
    static let storageKey = "onboardingCompleted"

    static func shouldShow(completed: Bool, arguments: [String]) -> Bool {
        if arguments.contains("-onboarding") { return true }
        // Test e screenshot automatici partono senza presentazione.
        if arguments.contains("-inMemoryStore") { return false }
        return !completed
    }
}

/// Le tre schermate della presentazione.
enum OnboardingPage: Int, CaseIterable, Identifiable {
    case notes
    case ai
    case study

    var id: Int { rawValue }

    var next: OnboardingPage? { OnboardingPage(rawValue: rawValue + 1) }

    var symbol: String {
        switch self {
        case .notes: "circle.hexagongrid"
        case .ai: "lock.shield"
        case .study: "rectangle.stack.badge.play"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .notes: "Note collegate in un grafo"
        case .ai: "Un'AI che rispetta la privacy"
        case .study: "Studia e ripassa"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .notes: "Scrivi in Markdown o a penna e collega le idee: ogni nodo trova il suo posto nel grafo."
        case .ai: "La chat risponde dalle tue fonti, con citazioni che aprono la nota o la pagina del PDF."
        case .study: "Dai tuoi appunti nascono quiz che tornano nel momento giusto per ricordarli."
        }
    }

    /// Punti in breve, con il simbolo di ciascuno.
    var points: [(symbol: String, text: LocalizedStringKey)] {
        switch self {
        case .notes: [
            ("link", "Scrivi [[titolo]] per collegare due nodi, o traccia una linea con la Pencil nel grafo."),
            ("pencil.and.scribble", "Pagine a penna, PDF e foto diventano ricercabili."),
        ]
        case .ai: [
            ("heart.text.square", "I dati di salute restano solo su questo iPad: non vanno al server né all'AI online."),
            ("ipad", "Offline la chat usa il modello sul dispositivo."),
        ]
        case .study: [
            ("checkmark.bubble", "Risposta multipla, domande aperte ed esercizi, una domanda per schermata."),
            ("calendar", "Ripasso ogni giorno ed esami nel calendario, collegati al grafo."),
        ]
        }
    }
}

/// Presentazione al primo avvio: tre schermate, saltabile in ogni momento.
struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = OnboardingPage.notes
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Salta", action: onFinish)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint(Text("Chiude la presentazione"))
            }
            .padding()
            TabView(selection: $page) {
                ForEach(OnboardingPage.allCases) { item in
                    content(item)
                        .tag(item)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            Button {
                if let next = page.next {
                    withAnimation { page = next }
                } else {
                    onFinish()
                }
            } label: {
                Text(page.next == nil ? "Inizia" : "Avanti")
                    .frame(maxWidth: 360)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding()
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func content(_ item: OnboardingPage) -> some View {
        // Con il testo molto grande la schermata scorre invece di tagliare.
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: item.symbol)
                    .font(.system(size: symbolSize))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(item.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(item.points.indices, id: \.self) { i in
                        Label {
                            Text(item.points[i].text)
                        } icon: {
                            Image(systemName: item.points[i].symbol)
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                        .font(.body)
                    }
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 32)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Schermata \(item.rawValue + 1) di \(OnboardingPage.allCases.count)"))
    }
}
