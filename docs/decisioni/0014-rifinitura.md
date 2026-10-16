# ADR 0014: rifinitura (accessibilità, scorciatoie, onboarding)

Stato: accettata, 2026-10-16. Riferimento: ARCHITETTURA.md, sezioni 2 e 9 (fase 9).

## Decisioni

- Scorciatoie globali nei comandi della scena (`AppShortcuts.swift`), non in pulsanti nascosti: tenendo premuto ⌘ compaiono con il loro nome, e su iPadOS 26 stanno nella barra dei menu. Un solo elenco (`AppShortcut`) alimenta comandi, Impostazioni e test. La ricerca è ⌘F e non ⌘K come nell'architettura: ⌘K è già il link nell'editor (ADR 0003). Con un foglio aperto le scorciatoie globali non fanno nulla, perché un foglio non ne presenta un altro.
- Grafo accessibile: la tela SpriteKit è un solo elemento con il numero di nodi e un'azione che apre l'elenco dei nodi, raggruppati per area, con tipo, collegamenti e vicini; da lì si apre il nodo o lo si centra nel grafo. Niente elementi per ogni nodo nella tela: con migliaia di nodi VoiceOver diventerebbe inutilizzabile.
- Tema scuro e contrasto: SpriteKit non segue i colori dinamici di UIKit, quindi la scena li risolve con tema, contrasto e dimensione del testo della vista e li riapplica a ogni cambio. Con il contrasto elevato archi, bolle delle aree e filtri hanno tratti più marcati. Il resto dell'app usa colori di sistema e stili di testo dinamici.
- Onboarding: tre schermate (note e grafo, AI e privacy della salute, studio) al primo avvio, saltabili, rivedibili dalle Impostazioni. Lo stato è un flag in `UserDefaults`; i test automatici partono senza.
- Penna: la palette di sistema copre già penna, evidenziatore, gomma, lazo, righello, forme e il doppio tocco o la pressione della Pencil; si aggiungono solo Annulla e Ripristina visibili sopra la pagina.
- Prestazioni del grafo: il layout è già O(n log n), in background, ricalcolato solo quando cambia la struttura, e il disegno ha un solo draw call per i nodi ed etichette riciclate per i soli nodi visibili. Un arresto anticipato del layout, misurato, non scattava mai (il raffreddamento domina): nessuna modifica.

## Conseguenze

- L'app non compila su Linux: le viste nuove si verificano con la CI su macOS e sul dispositivo (VoiceOver, tastiera esterna, contrasto elevato).
