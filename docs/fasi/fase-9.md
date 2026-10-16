# Fase 9: rifinitura

Stato: completata ([ADR 0014](../decisioni/0014-rifinitura.md)).

## Obiettivo

Tema scuro definitivo, strumenti Pencil completi, prestazioni del grafo, accessibilità, onboarding in tre schermate, scorciatoie da tastiera, icona.

## Criteri di completamento

- [x] Accessibilità con dimensione testo e contrasto elevato (stili di testo dinamici, colonne delle icone con `@ScaledMetric`, etichette sui pulsanti a icona, grafo con elenco accessibile e colori risolti per tema e contrasto).
- [x] Scorciatoie funzionanti con tastiera esterna (⌘N, ⌘F, ⌘G, ⌘/, ⌘R, ⌘, nei comandi della scena, elencate nelle Impostazioni).
- [x] Onboarding al primo avvio (tre schermate, saltabile, rivedibile dalle Impostazioni).

Inoltre: icona dell'app (`Assets.xcassets/AppIcon`), Annulla e Ripristina sulle pagine a penna.

## Test

- [x] Test di accessibilità di base (`AccessibilityTests`: presentazione, scorciatoie, tema della scena del grafo; `GraphFilterTests.neighbors` per l'elenco accessibile).

## Verifica su dispositivo

- [ ] VoiceOver sull'elenco del grafo e sulla presentazione.
- [ ] Scorciatoie con la tastiera esterna (anche tenendo premuto ⌘).
- [ ] Doppio tocco della Pencil sulla pagina a penna.
