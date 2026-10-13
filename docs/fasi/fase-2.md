# Fase 2: editor e penna

Stato: completata con #5.

## Obiettivo

Editor Markdown con anteprima, editor visuale, PencilKit con gli strumenti concordati, sfondi a righe e quadretti. Decisioni in [ADR 0003](../decisioni/0003-app-ed-editor.md) e [ADR 0004](../decisioni/0004-disegno.md).

## Criteri di completamento

- [ ] Scrittura fluida con Pencil: tela PencilKit nativa; da verificare sul dispositivo.
- [x] Il disegno si salva in un nodo di appunti: pagine `ink_pages` del nodo, sincronizzate.
- [x] Lo storico versioni è accessibile: vista Storico con differenze e ripristino.
- [x] `ci-ios.yml` esegue `xcodebuild test` su un simulatore iPad, non solo la build.

## Test

- [x] Test di serializzazione PKDrawing (`InkCodecTests`, su macOS, e test dell'app sul simulatore).
- [x] Test di rendering Markdown (`PitchstoneNotesTests`).
- [x] Test della barra di formattazione e delle differenze tra versioni.
- [x] Test della sync del disegno: due dispositivi, conflitto con pagina copiata, salute, lotti limitati in byte, cestino (Swift, pgTAP, end-to-end).
- [x] Test dell'app su simulatore (`PitchstoneTests`).

## Strumenti

- Penna, evidenziatore, gomma, lazo, righello: palette di sistema di PencilKit.
- Carta bianca, a righe, a quadretti: per pagina.
- Forme: riconoscimento di PencilKit, da verificare sul dispositivo.

## Verifiche su dispositivo

- [ ] Scrittura e anteprima Markdown sul tuo iPad.
- [ ] Pencil: latenza, palette, sfondi, forme.
