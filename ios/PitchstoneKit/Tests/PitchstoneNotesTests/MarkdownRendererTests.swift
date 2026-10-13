import Testing
@testable import PitchstoneNotes

@Suite("Rendering Markdown")
struct MarkdownRendererTests {
    @Test("titoli, paragrafi e stili inline")
    func headingsAndInline() {
        let blocks = MarkdownRenderer.render("""
        # Derivata
        Il **limite** del *rapporto* `f(x)` e ~~non~~ altro.
        """)
        #expect(blocks == [
            .heading(level: 1, [InlineRun("Derivata")]),
            .paragraph([
                InlineRun("Il "), InlineRun("limite", style: .bold), InlineRun(" del "),
                InlineRun("rapporto", style: .italic), InlineRun(" "), InlineRun("f(x)", style: .code),
                InlineRun(" e "), InlineRun("non", style: .strikethrough), InlineRun(" altro."),
            ]),
        ])
    }

    @Test("stili annidati e link")
    func nestedAndLinks() {
        let blocks = MarkdownRenderer.render("***tutto*** e [sito](https://example.org) **[forte](https://a.b)**")
        #expect(blocks == [.paragraph([
            InlineRun("tutto", style: [.bold, .italic]), InlineRun(" e "),
            InlineRun("sito", link: .url("https://example.org")), InlineRun(" "),
            InlineRun("forte", style: .bold, link: .url("https://a.b")),
        ])])
    }

    @Test("liste, checklist, citazioni, codice, tabelle, separatori")
    func blocks() {
        let blocks = MarkdownRenderer.render("""
        - uno
        - [x] fatto
        - [ ] da fare

        3. tre
        4. quattro

        > citato

        ```swift
        let x = 1
        ```

        ---

        | a | b |
        |---|---|
        | 1 | **2** |
        """)
        #expect(blocks == [
            .list(ordered: false, start: 1, items: [
                MarkdownListItem(blocks: [.paragraph([InlineRun("uno")])]),
                MarkdownListItem(checked: true, blocks: [.paragraph([InlineRun("fatto")])]),
                MarkdownListItem(checked: false, blocks: [.paragraph([InlineRun("da fare")])]),
            ]),
            .list(ordered: true, start: 3, items: [
                MarkdownListItem(blocks: [.paragraph([InlineRun("tre")])]),
                MarkdownListItem(blocks: [.paragraph([InlineRun("quattro")])]),
            ]),
            .quote([.paragraph([InlineRun("citato")])]),
            .code(language: "swift", code: "let x = 1"),
            .rule,
            .table(header: [[InlineRun("a")], [InlineRun("b")]], rows: [[[InlineRun("1")], [InlineRun("2", style: .bold)]]]),
        ])
    }

    @Test("link tra nodi stile Obsidian")
    func wikiLinks() {
        let blocks = MarkdownRenderer.render("Vedi [[Integrale]] e [[Serie di Taylor|Taylor]], non `[[codice]]`.")
        #expect(blocks == [.paragraph([
            InlineRun("Vedi "), InlineRun("Integrale", link: .wiki("Integrale")), InlineRun(" e "),
            InlineRun("Taylor", link: .wiki("Serie di Taylor")), InlineRun(", non "),
            InlineRun("[[codice]]", style: .code), InlineRun("."),
        ])])
    }

    @Test("wiki link malformati restano testo")
    func malformedWikiLinks() {
        #expect(MarkdownRenderer.render("[[]] e [[aperto") == [.paragraph([InlineRun("[[]] e [[aperto")])])
    }

    @Test("titoli collegati per il grafo, senza duplicati")
    func wikiTargets() {
        let text = """
        # [[Analisi]]
        - [[Derivata]] e [[derivata]]
        > [[Limite|il limite]]
        ```
        [[Ignorato]]
        ```
        """
        #expect(MarkdownLinks.wikiTargets(in: text) == ["Analisi", "Derivata", "Limite"])
    }

    @Test("a capo morbidi e forzati")
    func lineBreaks() {
        #expect(MarkdownRenderer.render("uno\ndue  \ntre") == [.paragraph([InlineRun("uno due\ntre")])])
    }

    @Test("testo vuoto")
    func empty() {
        #expect(MarkdownRenderer.render("").isEmpty)
    }
}
