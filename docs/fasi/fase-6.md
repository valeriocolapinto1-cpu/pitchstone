# Fase 6: analisi automatica

Stato: completata ([ADR 0010](../decisioni/0010-analisi.md)).

## Obiettivo

Estrazione di nodi e collegamenti dagli appunti, conferma per i dati sensibili, rilevamento della salute con tag manuale.

## Criteri di completamento

- [x] Un appunto di esempio produce nodi e collegamenti corretti (`NoteAnalysisTests`, `AnalysisTests`).
- [x] I dati sensibili richiedono conferma: persone e salute proposte dall'analisi, appunti sospetti trattenuti finché l'utente non sceglie.
- [x] Il rilevamento della salute supera il set di test (`HealthDetectorTests`: 12 testi personali, 16 appunti e altro).

## Test

- [x] Set di esempi per il rilevamento della salute.
- [x] Test di conferma: proposte, "È salute" su nodi locali e sincronizzati, "Non lo è" con segnali nuovi.
- [x] Sync: un nodo trattenuto e i suoi archi restano in outbox (`HoldTests`).

## Verifica su dispositivo

- [ ] Qualità dell'estrazione con il modello locale in italiano.
- [ ] Rilevamento della salute sui tuoi appunti reali.
