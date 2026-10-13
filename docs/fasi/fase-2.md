# Fase 2: editor e penna

Stato: in corso. Parte 1 (progetto, editor Markdown, storico) in revisione; parte 2 (penna) da iniziare.

## Obiettivo

Editor Markdown con anteprima, editor visuale, PencilKit con gli strumenti concordati, sfondi a righe e quadretti. Decisioni in [ADR 0003](../decisioni/0003-app-ed-editor.md).

## Criteri di completamento

- [ ] Scrittura fluida con Pencil. (parte 2)
- [ ] Il disegno si salva in `pdf_pages` o in un nodo di appunti. (parte 2)
- [x] Lo storico versioni è accessibile: vista Storico con differenze e ripristino.
- [x] `ci-ios.yml` esegue `xcodebuild test` su un simulatore iPad, non solo la build.

## Test

- [ ] Test di serializzazione PKDrawing. (parte 2)
- [x] Test di rendering Markdown (`PitchstoneNotesTests`, su Linux e macOS).
- [x] Test della barra di formattazione e delle differenze tra versioni.
- [x] Test dell'app su simulatore (`PitchstoneTests`): modello, link tra nodi, cestino, ripristino.

## Parte 1

- `ios/project.yml` e `ios/Pitchstone.xcodeproj` (XcodeGen).
- App: elenco dei nodi per area con ricerca, nodo con titolo, tipo, area, tag, editor e anteprima (Scrivi, Affiancato, Anteprima), storico, cestino, impostazioni della sync.
- `PitchstoneNotes`: `MarkdownRenderer`, `MarkdownFormatting`, `MarkdownLinks`, `LineDiff`.
- IPA non firmato su `main` come artefatto di `ci-ios`.

## Verifiche su dispositivo

- [ ] Scrittura e anteprima sul tuo iPad (IPA da Sideloadly o build da Xcode).
