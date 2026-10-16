import Foundation
import Testing
import UIKit
@testable import Pitchstone

@Suite("Presentazione al primo avvio")
struct OnboardingTests {
    @Test("si mostra finché non è completata, mai nei test automatici")
    func policy() {
        #expect(OnboardingPolicy.shouldShow(completed: false, arguments: []))
        #expect(!OnboardingPolicy.shouldShow(completed: true, arguments: []))
        #expect(!OnboardingPolicy.shouldShow(completed: false, arguments: ["-inMemoryStore"]))
        #expect(OnboardingPolicy.shouldShow(completed: true, arguments: ["-inMemoryStore", "-onboarding"]))
    }

    @Test("tre schermate in ordine, l'ultima chiude")
    func pages() {
        #expect(OnboardingPage.allCases.count == 3)
        #expect(OnboardingPage.notes.next == .ai)
        #expect(OnboardingPage.ai.next == .study)
        #expect(OnboardingPage.study.next == nil)
        for page in OnboardingPage.allCases {
            #expect(!page.points.isEmpty)
            #expect(UIImage(systemName: page.symbol) != nil, "simbolo \(page.symbol)")
        }
    }
}

@MainActor
@Suite("Scorciatoie da tastiera")
struct ShortcutTests {
    @Test("tasti distinti, nomi e simboli presenti")
    func registry() {
        let keys = AppShortcut.allCases.map(\.key)
        #expect(Set(keys).count == keys.count, "due scorciatoie sullo stesso tasto")
        // ⌘K è dell'editor (link), ⌘B e ⌘I della formattazione.
        #expect(keys.allSatisfy { !"kbi".contains($0) })
        for shortcut in AppShortcut.allCases {
            #expect(!shortcut.title.isEmpty)
            #expect(UIImage(systemName: shortcut.symbol) != nil, "simbolo \(shortcut.symbol)")
        }
        #expect(AppShortcut.newNode.display == "⌘N")
        #expect(AppShortcut.settings.display == "⌘,")
    }

    @Test("la stessa scorciatoia due volte di fila arriva due volte")
    func repeatedRequests() {
        let center = CommandCenter()
        center.perform(.chat)
        let first = center.request
        center.perform(.chat)
        #expect(center.request?.shortcut == .chat)
        #expect(center.request != first)
    }
}

@MainActor
@Suite("Grafo accessibile")
struct GraphAccessibilityTests {
    @Test("tema scuro e contrasto elevato si applicano alla scena")
    func appearance() {
        let scene = GraphScene(size: CGSize(width: 800, height: 600))
        let dark = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .dark),
            UITraitCollection(accessibilityContrast: .high),
        ])
        scene.applyAppearance(dark)
        #expect(brightness(scene.backgroundColor) < 0.2, "fondo scuro")
        scene.applyAppearance(UITraitCollection(userInterfaceStyle: .light))
        #expect(brightness(scene.backgroundColor) > 0.8, "fondo chiaro")
    }

    private func brightness(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red + green + blue) / 3
    }
}
