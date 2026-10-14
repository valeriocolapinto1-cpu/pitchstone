import PitchstoneStore
import SwiftData
import SwiftUI

@main
struct PitchstoneApp: App {
    @State private var notes: NotesModel
    @State private var study: StudyModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // I test girano dentro l'app: archivio in memoria e nessuna sync.
        let testing = ProcessInfo.processInfo.arguments.contains("-inMemoryStore")
        let container: ModelContainer
        do {
            container = try PitchstoneSchema.container(inMemory: testing)
        } catch {
            fatalError("Archivio locale non disponibile: \(error)")
        }
        let model = NotesModel(container: container, startSync: !testing, autoIndex: true)
        // Screenshot automatici in CI: archivio in memoria con dati dimostrativi.
        if testing && ProcessInfo.processInfo.arguments.contains("-demoData") { model.loadDemoData() }
        _notes = State(initialValue: model)
        let study = StudyModel(container: container, notes: model)
        study.notificationsEnabled = !testing
        if testing && ProcessInfo.processInfo.arguments.contains("-demoData") { study.loadDemoQuizzes() }
        _study = State(initialValue: study)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(notes)
                .environment(study)
                .task { await study.retryQueued() }
                .onChange(of: scenePhase) { _, phase in
                    // Promemoria aggiornati quando si esce: contano i ripassi fatti oggi.
                    if phase == .background { study.scheduleReminders() }
                }
        }
    }
}
