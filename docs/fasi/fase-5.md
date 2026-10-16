# Fase 5: chat AI

Stato: completata ([ADR 0009](../decisioni/0009-chat.md)).

## Obiettivo

Chat generale e per nodo, modello locale su iPad, Worker per Gemini, ricerca semantica, citazioni cliccabili, storico salvato come nodi.

## Criteri di completamento

- [x] La chat risponde online con Gemini e offline con il modello locale (`ChatRouter`, test di fallback).
- [x] Le citazioni aprono il nodo o la pagina (link `pitchstone-source://`, lettore PDF alla pagina citata).
- [x] I nodi di salute non compaiono nei prompt (corpus senza nodi sensibili, chat di salute solo locale).
- [x] La chat viene salvata come nodo (`idea`, collegato al nodo di origine e ai nodi citati).

## Test

- [x] Test che verificano l'esclusione dei nodi di salute (`PitchstoneAITests`, `ChatModelTests`).
- [x] Test di citazioni (numeri validi, link, ritorno alla fonte, nessun falso `[[link]]`).
- [x] Test di fallback offline (Gemini irraggiungibile, non configurato, nessun modello).
- [x] Worker: autenticazione, validazione, chiamata a Gemini, limite 429, errori nascosti.

## Verifica su dispositivo

- [ ] Qualità dell'italiano e gestione dei 4.096 token sul tuo iPad.
- [ ] Chat online con la chiave Gemini reale (`wrangler secret put GEMINI_API_KEY`).
