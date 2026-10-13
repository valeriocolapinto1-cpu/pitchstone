import PitchstoneNotes
import SwiftUI

/// Anteprima del Markdown: blocchi nativi SwiftUI, link tra nodi cliccabili.
struct MarkdownPreview: View {
    let text: String
    var onOpenNode: (String) -> Void = { _ in }

    var body: some View {
        let blocks = MarkdownRenderer.render(text)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if blocks.isEmpty {
                    Text("Niente da mostrare")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    BlockView(block: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .environment(\.openURL, OpenURLAction { url in
            if let title = MarkdownText.nodeTitle(from: url) {
                onOpenNode(title)
                return .handled
            }
            return .systemAction
        })
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let runs):
            Text(MarkdownText.attributed(runs))
                .font(Self.headingFont(level))
                .padding(.top, level <= 2 ? 8 : 4)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let runs):
            Text(MarkdownText.attributed(runs))
                .textSelection(.enabled)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(ordered: ordered, number: start + index, checked: item.checked)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, inner in
                                BlockView(block: inner)
                            }
                        }
                    }
                }
            }
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.tint)
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(inner.enumerated()), id: \.offset) { _, block in
                        BlockView(block: block)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownText.attributed(cell)).bold()
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(MarkdownText.attributed(cell))
                            }
                        }
                    }
                }
            }
        case .rule:
            Divider()
        }
    }

    @ViewBuilder
    private func marker(ordered: Bool, number: Int, checked: Bool?) -> some View {
        if let checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityLabel(checked ? Text("Fatto") : Text("Da fare"))
        } else if ordered {
            Text("\(number).")
                .monospacedDigit()
        } else {
            Text("•")
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .largeTitle.bold()
        case 2: .title.bold()
        case 3: .title2.bold()
        case 4: .title3.bold()
        default: .headline
        }
    }
}
