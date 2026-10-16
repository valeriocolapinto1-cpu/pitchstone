# Fase 10: versione PC

Stato: completata ([ADR 0013](../decisioni/0013-pwa.md)).

## Criteri di completamento

- [x] Il PC vede gli stessi dati dell'iPad (`web/test/e2e.test.ts`: nodo e arco dall'iPad, modifica dal PC che torna all'iPad, contro il database locale).
- [x] Il modello locale del PC funziona quando è acceso (`web/test/chat.test.ts`: risponde Ollama su `localhost` quando è acceso; spento, senza modello o in errore passa a Gemini via `/ai/chat`; con "Solo locale" si ferma senza uscire dal PC).

## Test

- [x] Test end-to-end della sincronizzazione tra iPad e PWA.
- [x] Test del motore di sync della PWA (outbox, offline, conflitti, rifiuti, link).
- [x] Test del Tutor della PWA: ricerca, spazio del prompt, citazioni, scelta del modello, esclusione dei nodi di salute (`web/test/chat.test.ts`).
