import PitchstoneStudy
import PitchstoneSync
import SwiftUI

/// Calendario degli esami: data, giorni mancanti, stato, nodi collegati e ripassi della materia.
struct ExamCalendarView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(StudyModel.self) private var study
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSource) private var openSource

    var body: some View {
        NavigationStack {
            let entries = ExamEntry.calendar(nodes: notes.nodes, edges: notes.edges)
            List {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Nessun esame", systemImage: "graduationcap",
                        description: Text("Crea un nodo di tipo Esame e scegli la data nel nodo."))
                }
                ForEach(entries) { entry in
                    Button {
                        dismiss()
                        openSource(.init(nodeID: entry.node.id))
                    } label: {
                        ExamRow(entry: entry, due: study.activeQuizzes.filter { $0.subject == entry.node.title }.count)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Esami")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let exam = notes.createNode(type: .exam, title: String(localized: "Nuovo esame"))
                        notes.update(exam.id) { $0.tags = ExamInfo().applied(to: $0.tags) }
                        dismiss()
                        openSource(.init(nodeID: exam.id))
                    } label: {
                        Label("Nuovo esame", systemImage: "plus")
                    }
                }
            }
        }
    }
}

private struct ExamRow: View {
    let entry: ExamEntry
    let due: Int
    /// Colonna della data che cresce con la dimensione del testo.
    @ScaledMetric(relativeTo: .title2) private var dateWidth: CGFloat = 52

    var body: some View {
        HStack(spacing: 16) {
            VStack {
                if let date = entry.info.date.flatMap(Calendar.current.date(from:)) {
                    Text(date, format: .dateTime.day()).font(.title2.bold())
                    Text(date, format: .dateTime.month(.abbreviated)).font(.caption)
                } else {
                    Image(systemName: "calendar.badge.questionmark").font(.title2)
                        .accessibilityLabel(Text("Data da decidere"))
                }
            }
            .frame(width: dateWidth)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.node.title.isEmpty ? String(localized: "Senza titolo") : entry.node.title).font(.headline)
                HStack(spacing: 10) {
                    Text(entry.info.status.label)
                    if let days = entry.info.daysLeft(from: Date()), entry.info.status == .planned || entry.info.status == .studying {
                        Text(days > 0 ? "tra \(days) giorni" : days == 0 ? "oggi" : "passato")
                            .foregroundStyle(days <= 7 && days >= 0 ? .orange : .secondary)
                    }
                    Label("\(entry.linked.count)", systemImage: "point.3.connected.trianglepath.dotted")
                    Label("\(due) quiz", systemImage: "rectangle.stack")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Data e stato nel nodo di un esame.
struct ExamControls: View {
    @Environment(NotesModel.self) private var notes
    let node: NodeRecord
    /// Salva prima il testo in corso: i tag scritti a mano non si perdono.
    let beforeChange: () -> Void

    var body: some View {
        let info = ExamInfo.parse(node.tags)
        HStack(spacing: 12) {
            DatePicker(
                "Data dell'esame",
                selection: Binding(
                    get: { info.date.flatMap(Calendar.current.date(from:)) ?? Date() },
                    set: { set(date: Calendar.current.dateComponents([.year, .month, .day], from: $0), status: info.status) }),
                displayedComponents: .date)
            .fixedSize()
            Picker("Stato", selection: Binding(get: { info.status }, set: { set(date: info.date, status: $0) })) {
                ForEach(ExamInfo.Status.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .fixedSize()
        }
        .font(.callout)
    }

    private func set(date: DateComponents?, status: ExamInfo.Status) {
        beforeChange()
        notes.update(node.id) { $0.tags = ExamInfo(date: date, status: status).applied(to: $0.tags) }
    }
}

extension ExamInfo.Status {
    var label: LocalizedStringKey {
        switch self {
        case .planned: "Pianificato"
        case .studying: "In preparazione"
        case .passed: "Superato"
        case .failed: "Non superato"
        }
    }
}
