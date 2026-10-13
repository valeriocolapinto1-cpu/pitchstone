# ADR 0003: progetto iOS ed editor

Stato: accettata, 2026-10-13. Riferimento: ARCHITETTURA.md, sezioni 2, 4 e 9 (fase 2).

## Contesto

Lo sviluppo avviene senza un Mac sempre disponibile: il codice iOS si compila solo in CI su macOS, che costa 10 volte i minuti Linux. Serve un progetto Xcode leggibile e rigenerabile, e la maggior parte della logica testabile su Linux.

## Decisioni

**Progetto**
- `ios/Pitchstone.xcodeproj` è generato con XcodeGen 2.46.0 da `ios/project.yml` e versionato, così si apre direttamente in Xcode. Dopo una modifica a `project.yml`: `xcodegen generate` in `ios/`.
- App solo iPad (`TARGETED_DEVICE_FAMILY = 2`), iOS 18, Swift 6. Bundle id `app.pitchstone.ipad`.
- L'app dipende dal package locale `PitchstoneKit`. Nuovo target `PitchstoneNotes` (Foundation + `swift-markdown` 0.8.0 di Apple): rendering Markdown, formattazione, differenze tra versioni. Si testa su Linux.

**Editor**
- Testo in Markdown, che resta il formato di `nodes.body_md` (esportabile, compatibile con Obsidian).
- "Editor visuale": barra di formattazione e scorciatoie (⌘B, ⌘I, ⌘K) che applicano la sintassi alla selezione, più l'anteprima nativa SwiftUI affiancata. Niente editor WYSIWYG ad attributi: il Markdown resta la fonte di verità e il rendering è lo stesso dell'anteprima.
- Link tra nodi `[[Titolo]]` e `[[Titolo|testo]]` come in Obsidian. Il titolo si confronta senza maiuscole e accenti; un link a un nodo inesistente lo crea. `MarkdownLinks.wikiTargets` prepara gli archi di tipo `link` per la fase 3.
- Salvataggio automatico dopo 0,8 s senza modifiche e quando si lascia il nodo; si salva solo se qualcosa è cambiato, perché ogni salvataggio è una modifica da sincronizzare.

**Storico**
- Lo storico mostra le versioni accettate dal server, con le differenze riga per riga rispetto alla precedente. Il ripristino è una modifica normale: crea una nuova versione e non cancella nulla.

**CI**
- `ci-ios` usa un solo job macOS: test del package, `xcodebuild test` sul simulatore iPad più recente, e su `main` un IPA non firmato come artefatto per Sideloadly (14 giorni).
- I test dell'app girano dentro l'app con `-inMemoryStore`: archivio in memoria, nessuna sync.

## Conseguenze

- Il disegno a penna (PencilKit, sfondi) arriva nella seconda parte della fase 2, con la propria sincronizzazione.
- Ogni modifica a `project.yml` va accompagnata dal progetto rigenerato.
