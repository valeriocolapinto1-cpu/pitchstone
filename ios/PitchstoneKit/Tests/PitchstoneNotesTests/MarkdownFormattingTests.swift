import Testing
@testable import PitchstoneNotes

@Suite("Barra di formattazione")
struct MarkdownFormattingTests {
    func apply(_ format: MarkdownFormat, _ text: String, _ range: Range<Int>) -> TextEdit {
        MarkdownFormatting.apply(format, to: text, selection: range)
    }

    @Test("grassetto: aggiunge e toglie")
    func bold() {
        let on = apply(.bold, "il limite qui", 3..<9)
        #expect(on == TextEdit(text: "il **limite** qui", selection: 5..<11))
        let off = apply(.bold, on.text, on.selection)
        #expect(off == TextEdit(text: "il limite qui", selection: 3..<9))
        // Anche con i marcatori dentro la selezione.
        #expect(apply(.bold, "il **limite** qui", 3..<13) == TextEdit(text: "il limite qui", selection: 3..<9))
    }

    @Test("corsivo dentro un grassetto non rompe il grassetto")
    func italicInsideBold() {
        let edit = apply(.italic, "**forte**", 2..<7)
        #expect(edit.text == "***forte***")
        #expect(MarkdownRenderer.render(edit.text) == [.paragraph([InlineRun("forte", style: [.bold, .italic])])])
    }

    @Test("selezione vuota: marcatori con il cursore in mezzo")
    func emptySelection() {
        #expect(apply(.code, "ab", 1..<1) == TextEdit(text: "a``b", selection: 2..<2))
    }

    @Test("titolo: aggiunge, cambia livello, toglie")
    func heading() {
        let h2 = apply(.heading(2), "Titolo\naltro", 2..<2)
        #expect(h2 == TextEdit(text: "## Titolo\naltro", selection: 9..<9))
        #expect(apply(.heading(1), h2.text, 3..<3).text == "# Titolo\naltro")
        #expect(apply(.heading(2), h2.text, 3..<3).text == "Titolo\naltro")
    }

    @Test("liste su più righe")
    func lists() {
        let text = "uno\ndue\ntre"
        let bullets = apply(.bulletList, text, 0..<7)
        #expect(bullets == TextEdit(text: "- uno\n- due\ntre", selection: 0..<11))
        #expect(apply(.bulletList, bullets.text, bullets.selection).text == text)
        #expect(apply(.numberedList, text, 0..<11).text == "1. uno\n2. due\n3. tre")
        #expect(apply(.numberedList, "1. uno\n2. due", 0..<13).text == "uno\ndue")
        #expect(apply(.checklist, "spesa", 0..<0).text == "- [ ] spesa")
        #expect(apply(.quote, "frase", 2..<2).text == "> frase")
    }

    @Test("una selezione che finisce a inizio riga non tocca quella riga")
    func selectionEndingAtLineStart() {
        #expect(apply(.bulletList, "uno\ndue", 0..<4).text == "- uno\ndue")
    }

    @Test("link: il testo selezionato diventa l'etichetta, l'URL resta selezionato")
    func link() {
        let edit = apply(.link, "vedi sito", 5..<9)
        #expect(edit.text == "vedi [sito](https://)")
        let url = Array(edit.text)[edit.selection].map(String.init).joined()
        #expect(url == "https://")
        #expect(apply(.link, "x", 1..<1) == TextEdit(text: "x[](https://)", selection: 2..<2))
    }

    @Test("caratteri composti ed emoji contano come un carattere")
    func graphemes() {
        #expect(apply(.bold, "café 👩‍🔬 ok", 5..<6).text == "café **👩‍🔬** ok")
    }

    @Test("selezione fuori dal testo viene limitata")
    func clamped() {
        #expect(apply(.bold, "ab", 1..<99).text == "a**b**")
    }
}
