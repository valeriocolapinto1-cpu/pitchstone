# Fase 10: versione PC

Stato: in corso ([ADR 0013](../decisioni/0013-pwa.md)).

## Criteri di completamento

- [x] Il PC vede gli stessi dati dell'iPad (`web/test/e2e.test.ts`: nodo e arco dall'iPad, modifica dal PC che torna all'iPad, contro il database locale).
- [ ] Il modello locale del PC funziona quando è acceso.

## Test

- [x] Test end-to-end della sincronizzazione tra iPad e PWA.
- [x] Test del motore di sync della PWA (outbox, offline, conflitti, rifiuti, link).
