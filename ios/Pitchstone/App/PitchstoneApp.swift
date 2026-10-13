import PitchstoneStore
import SwiftData
import SwiftUI

@main
struct PitchstoneApp: App {
    @State private var notes: NotesModel

    init() {
        // I test girano dentro l'app: archivio in memoria e nessuna sync.
        let testing = ProcessInfo.processInfo.arguments.contains("-inMemoryStore")
        let container: ModelContainer
        do {
            container = try PitchstoneSchema.container(inMemory: testing)
        } catch {
            fatalError("Archivio locale non disponibile: \(error)")
        }
        let model = NotesModel(container: container, startSync: !testing)
        // Screenshot automatici in CI: archivio in memoria con dati dimostrativi.
        if testing && ProcessInfo.processInfo.arguments.contains("-demoData") { model.loadDemoData() }
        _notes = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(notes)
        }
    }
}
