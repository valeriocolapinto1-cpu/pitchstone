import PitchstoneStudy
import SwiftUI

/// Ripasso: streak, obiettivo della settimana, poi un quiz per schermata con risposta immediata.
struct QuizView: View {
    @Environment(StudyModel.self) private var study
    @Environment(\.dismiss) private var dismiss
    @State private var session: [QuizRecord] = []
    @State private var index = 0
    @State private var started = false
    @State private var editingGoal = false

    var body: some View {
        NavigationStack {
            Group {
                if started, index < session.count {
                    QuizCard(quiz: session[index], position: index + 1, total: session.count) {
                        index += 1
                        // I "di nuovo" tornano dopo 10 minuti: alla fine si riprende la coda aggiornata.
                        if index == session.count, !study.queue.isEmpty {
                            session = study.queue
                            index = 0
                        }
                    }
                    .id(session[index].id)
                } else {
                    summary
                }
            }
            .navigationTitle("Ripasso")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .sheet(isPresented: $editingGoal) {
                GoalEditor()
            }
            .task { await study.requestNotificationPermission() }
        }
    }

    private var summary: some View {
        let week = study.week
        return List {
            Section {
                HStack(spacing: 24) {
                    stat("\(study.streak)", "giorni di fila", "flame.fill", .orange)
                    stat("\(study.queue.count)", "da fare ora", "rectangle.stack", .accentColor)
                    stat("\(week.quizzes)/\(week.targetQuizzes)", "quiz della settimana", "target", .green)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                ProgressView(value: week.fraction) {
                    Text("Obiettivo settimanale: \(week.minutes) di \(week.targetMinutes) minuti")
                        .font(.callout)
                }
                Button("Cambia obiettivo") { editingGoal = true }
            }
            Section {
                if started, study.queue.isEmpty {
                    Label("Sessione finita: a domani!", systemImage: "checkmark.seal")
                }
                if !study.queue.isEmpty {
                    Button {
                        session = study.queue
                        index = 0
                        started = true
                    } label: {
                        Label("Inizia il ripasso", systemImage: "play.fill").font(.headline)
                    }
                    .keyboardShortcut(.defaultAction)
                } else if !study.practice.isEmpty {
                    // Niente in scadenza: allenamento in anticipo, che tiene lo streak.
                    Button {
                        session = study.practice
                        index = 0
                        started = true
                    } label: {
                        Label("Allenamento: anticipa i prossimi ripassi", systemImage: "figure.run").font(.headline)
                    }
                } else {
                    Label("Niente da ripassare adesso", systemImage: "play.slash")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Al massimo \(StudyPlan.dailyLimit) quiz al giorno. Crea quiz da un nodo con il pulsante \"Quiz\".")
            }
            if !study.subjects.isEmpty {
                Section("Livello per materia") {
                    ForEach(study.subjects, id: \.self) { subject in
                        Stepper(value: Binding(get: { study.level(for: subject) }, set: { study.setLevel($0, for: subject) }), in: 1...5) {
                            LabeledContent(subject, value: "\(study.level(for: subject))/5")
                        }
                    }
                }
            }
        }
    }

    private func stat(_ value: String, _ label: LocalizedStringKey, _ symbol: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title2)
                .accessibilityHidden(true)
            Text(value).font(.title.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        // Letto come "12, quiz da ripassare" invece di tre elementi separati.
        .accessibilityElement(children: .combine)
    }
}

/// Un quiz: risposta, correzione immediata, spiegazione, poi il successivo.
private struct QuizCard: View {
    @Environment(StudyModel.self) private var study
    let quiz: QuizRecord
    let position: Int
    let total: Int
    let next: () -> Void

    @State private var shownAt = Date()
    @State private var grade: QuizGrade?
    @State private var chosen: String?
    @State private var text = ""
    @State private var grading = false
    /// Domanda aperta senza modelli: l'utente si valuta da solo.
    @State private var selfAssessing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("\(position) di \(total)").foregroundStyle(.secondary)
                    Spacer()
                    Text(quiz.subject).font(.caption).padding(6).background(.quaternary, in: Capsule())
                }
                MarkdownBlocks(text: quiz.question)
                    .font(.title3)
                switch quiz.kind {
                case .mcq: choices
                case .calc: numberInput
                case .open: openInput
                }
                if let grade { feedback(grade) }
                if selfAssessing { selfAssessment }
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private var choices: some View {
        VStack(spacing: 10) {
            ForEach(Array(quiz.options.enumerated()), id: \.offset) { offset, option in
                Button {
                    guard grade == nil else { return }
                    chosen = option
                    finish(QuizGrader.gradeChoice(quiz, choice: option, seconds: Date().timeIntervalSince(shownAt)))
                } label: {
                    HStack {
                        Text(option).multilineTextAlignment(.leading)
                        Spacer()
                        if grade != nil, optionKey(option) == optionKey(quiz.answer) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityLabel(Text("Risposta giusta"))
                        } else if grade != nil, option == chosen {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                                .accessibilityLabel(Text("La tua risposta, sbagliata"))
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(offset + 1))), modifiers: [])
            }
        }
    }

    private var numberInput: some View {
        HStack {
            TextField("Risultato", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .onSubmit(checkNumber)
                .disabled(grade != nil)
            Button("Controlla", action: checkNumber)
                .buttonStyle(.borderedProminent)
                .disabled(text.isEmpty || grade != nil)
        }
    }

    private func checkNumber() {
        guard grade == nil, !text.isEmpty else { return }
        finish(QuizGrader.gradeNumber(quiz, input: text))
    }

    private var openInput: some View {
        VStack(alignment: .leading) {
            TextEditor(text: $text)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .disabled(grade != nil || grading || selfAssessing)
            Button {
                grading = true
                Task {
                    defer { grading = false }
                    if let result = await study.gradeOpen(quiz, answer: text) {
                        finish(result)
                    } else {
                        selfAssessing = true
                    }
                }
            } label: {
                Label(grading ? "Correggo…" : "Correggi", systemImage: "checkmark.bubble")
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || grade != nil || grading || selfAssessing)
        }
    }

    private var selfAssessment: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nessun modello disponibile: confronta con la risposta modello e valutati.").font(.callout)
            Text(quiz.answer).padding().background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                ForEach(Rating.allCases, id: \.self) { rating in
                    Button(rating.label) {
                        selfAssessing = false
                        finish(QuizGrade(correct: rating >= .good, rating: rating, feedback: ""))
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func feedback(_ grade: QuizGrade) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(grade.correct ? "Giusto" : "Non proprio", systemImage: grade.correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.headline)
                .foregroundStyle(grade.correct ? .green : .red)
            if !grade.feedback.isEmpty { Text(grade.feedback) }
            if quiz.kind == .open { Text("Risposta modello: \(quiz.answer)").foregroundStyle(.secondary) }
            if !quiz.explanation.isEmpty { MarkdownBlocks(text: quiz.explanation).foregroundStyle(.secondary) }
            Button("Avanti", action: next)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding()
        .background((grade.correct ? Color.green : Color.red).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        // VoiceOver: l'esito si annuncia da solo, senza dover cercare l'etichetta.
        .accessibilityElement(children: .contain)
        .onAppear {
            AccessibilityNotification.Announcement(grade.correct ? "Giusto" : "Non proprio").post()
        }
    }

    private func finish(_ result: QuizGrade) {
        grade = result
        study.answer(quiz, rating: result.rating, duration: Date().timeIntervalSince(shownAt))
    }
}

/// Confronto delle opzioni senza maiuscole né accenti, come la correzione.
private func optionKey(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
}

private struct GoalEditor: View {
    @Environment(StudyModel.self) private var study
    @Environment(\.dismiss) private var dismiss
    @State private var quizzes = 100
    @State private var minutes = 120

    var body: some View {
        NavigationStack {
            Form {
                Stepper("Quiz a settimana: \(quizzes)", value: $quizzes, in: 10...700, step: 10)
                Stepper("Minuti a settimana: \(minutes)", value: $minutes, in: 15...1200, step: 15)
            }
            .navigationTitle("Obiettivo settimanale")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        study.goal = StudyGoal(targetQuizzes: quizzes, targetMinutes: minutes)
                        dismiss()
                    }
                }
            }
            .onAppear {
                quizzes = study.goal.targetQuizzes
                minutes = study.goal.targetMinutes
            }
        }
    }
}

extension Rating {
    var label: LocalizedStringKey {
        switch self {
        case .again: "Di nuovo"
        case .hard: "Difficile"
        case .good: "Bene"
        case .easy: "Facile"
        }
    }
}
