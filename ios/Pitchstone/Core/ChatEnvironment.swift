import PitchstoneAI
import SwiftUI

/// Apre il punto citato da una risposta: un nodo o la pagina di un PDF.
struct OpenSourceAction {
    let handler: @MainActor (SourceRef) -> Void

    @MainActor func callAsFunction(_ ref: SourceRef) { handler(ref) }
}

/// Apre la chat: generale (nil) o dedicata a un nodo.
struct OpenChatAction {
    let handler: @MainActor (UUID?) -> Void

    @MainActor func callAsFunction(_ nodeID: UUID?) { handler(nodeID) }
}

extension EnvironmentValues {
    @Entry var openSource = OpenSourceAction { _ in }
    @Entry var openChat = OpenChatAction { _ in }
}
