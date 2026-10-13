import PitchstoneNotes
import SwiftUI

/// Editor visuale: testo Markdown con barra di formattazione e scorciatoie.
struct MarkdownEditor: View {
    @Binding var text: String
    @State private var selection: TextSelection?

    var body: some View {
        VStack(spacing: 0) {
            FormatBar { apply($0) }
            Divider()
            TextEditor(text: $text, selection: $selection)
                .font(.system(.body, design: .default))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .accessibilityLabel(Text("Testo della nota"))
        }
    }

    private func apply(_ format: MarkdownFormat) {
        let range = characterRange()
        let edit = MarkdownFormatting.apply(format, to: text, selection: range)
        text = edit.text
        let lower = text.index(text.startIndex, offsetBy: edit.selection.lowerBound, limitedBy: text.endIndex) ?? text.endIndex
        let upper = text.index(text.startIndex, offsetBy: edit.selection.upperBound, limitedBy: text.endIndex) ?? text.endIndex
        selection = lower == upper ? TextSelection(insertionPoint: lower) : TextSelection(range: lower..<upper)
    }

    /// Selezione corrente in caratteri; senza selezione, la fine del testo.
    private func characterRange() -> Range<Int> {
        let end = text.count
        guard let selection, case .selection(let range) = selection.indices,
              range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex else {
            return end..<end
        }
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.distance(from: text.startIndex, to: range.upperBound)
        return lower..<upper
    }
}

private struct FormatBar: View {
    let apply: (MarkdownFormat) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Menu {
                    ForEach(1...4, id: \.self) { level in
                        Button("Titolo \(level)") { apply(.heading(level)) }
                    }
                } label: {
                    Image(systemName: "textformat.size")
                        .frame(minWidth: 36, minHeight: 36)
                }
                .accessibilityLabel(Text("Titolo"))

                button("bold", "Grassetto", .bold).keyboardShortcut("b", modifiers: .command)
                button("italic", "Corsivo", .italic).keyboardShortcut("i", modifiers: .command)
                button("strikethrough", "Barrato", .strikethrough)
                button("chevron.left.forwardslash.chevron.right", "Codice", .code)
                Divider().frame(height: 24)
                button("list.bullet", "Elenco puntato", .bulletList)
                button("list.number", "Elenco numerato", .numberedList)
                button("checklist", "Lista di controllo", .checklist)
                button("text.quote", "Citazione", .quote)
                button("link", "Link", .link).keyboardShortcut("k", modifiers: .command)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private func button(_ symbol: String, _ label: LocalizedStringKey, _ format: MarkdownFormat) -> some View {
        Button { apply(format) } label: {
            Image(systemName: symbol)
                .frame(minWidth: 36, minHeight: 36)
        }
        .accessibilityLabel(Text(label))
        .help(Text(label))
    }
}
