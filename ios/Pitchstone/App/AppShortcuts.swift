import Observation
import SwiftUI

/// Scorciatoie globali con la tastiera esterna. Stanno nei comandi della scena: tenendo
/// premuto ⌘ (o nella barra dei menu di iPadOS 26) compaiono con il loro nome.
/// Quelle locali (⌘B e ⌘I nell'editor, ⌘↩ nella chat, 1–4 nei quiz) restano sulle viste.
enum AppShortcut: String, CaseIterable, Identifiable {
    case newNode
    case search
    case toggleGraph
    case chat
    case review
    case settings

    var id: String { rawValue }

    /// Tutte con ⌘. ⌘K resta all'editor per i link, quindi la ricerca è ⌘F.
    var key: Character {
        switch self {
        case .newNode: "n"
        case .search: "f"
        case .toggleGraph: "g"
        case .chat: "/"
        case .review: "r"
        case .settings: ","
        }
    }

    var title: String {
        switch self {
        case .newNode: String(localized: "Nuovo nodo")
        case .search: String(localized: "Cerca")
        case .toggleGraph: String(localized: "Elenco o grafo")
        case .chat: String(localized: "Mostra o nascondi la chat")
        case .review: String(localized: "Ripasso")
        case .settings: String(localized: "Impostazioni")
        }
    }

    var symbol: String {
        switch self {
        case .newNode: "plus"
        case .search: "magnifyingglass"
        case .toggleGraph: "circle.hexagongrid"
        case .chat: "bubble.left.and.text.bubble.right"
        case .review: "rectangle.stack.badge.play"
        case .settings: "gearshape"
        }
    }

    /// Come appare nell'elenco delle Impostazioni, per esempio "⌘N".
    var display: String { "⌘" + String(key).uppercased() }

    var keyEquivalent: KeyEquivalent { KeyEquivalent(key) }
}

/// Ponte tra i comandi della scena e la finestra: il comando registra una richiesta,
/// RootView la esegue con il suo stato.
@MainActor
@Observable
final class CommandCenter {
    struct Request: Equatable {
        let shortcut: AppShortcut
        /// Due richieste uguali di fila sono comunque due cambiamenti.
        let id = UUID()
    }

    private(set) var request: Request?

    func perform(_ shortcut: AppShortcut) {
        request = Request(shortcut: shortcut)
    }
}

struct AppCommands: Commands {
    let center: CommandCenter

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            item(.newNode)
        }
        CommandGroup(replacing: .appSettings) {
            item(.settings)
        }
        CommandMenu("Vai") {
            item(.search)
            item(.toggleGraph)
            item(.chat)
            item(.review)
        }
    }

    private func item(_ shortcut: AppShortcut) -> some View {
        Button {
            center.perform(shortcut)
        } label: {
            Label(shortcut.title, systemImage: shortcut.symbol)
        }
        .keyboardShortcut(shortcut.keyEquivalent, modifiers: .command)
    }
}
