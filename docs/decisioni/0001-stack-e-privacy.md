# ADR 0001: stack e privacy

Stato: accettata, 2026-10-13.

## Contesto

App personale per iPad, budget zero, uso offline, dati di salute da proteggere. Riferimento: ARCHITETTURA.md, sezioni 3, 4, 5 e 7.

## Decisioni

**Stack**
- Client iPad nativo: SwiftUI, SwiftData, PencilKit, SpriteKit con Metal, Vision, NaturalLanguage, Apple Foundation Models.
- Backend: Supabase Free in regione Europa (Postgres, pgvector, Storage privato).
- AI online: Gemini, piano gratuito, chiamato solo dal Worker Cloudflare `ai-proxy`. La chiave è un secret del Worker e non entra mai nell'app.
- Protezione di rete: Cloudflare Access, login Google per il web e service token per l'iPad. I service token sono disponibili nel piano Free di Zero Trust ([documentazione Cloudflare](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/mutual-tls-authentication/): "Free customers can use service tokens"; mTLS invece non è incluso).
- CI su GitHub Actions: Linux a ogni PR, macOS solo su `main` o manualmente.

**Database**
- RLS attiva su tutte le tabelle, nessuna policy per `anon`. In più `anon` non ha privilegi sulle tabelle utente, anche per le tabelle create in futuro dal ruolo `postgres`.
- L'estensione `vector` sta nello schema `extensions`, come raccomandato da Supabase.
- Unica tabella extra: `keepalive`, una sola riga. `anon` ha solo `SELECT`; per RLS la risposta è un array vuoto. Il keep-alive considera valida una risposta 200 con array JSON: basta a generare attività senza esporre righe e senza introdurre policy per `anon`. Una tabella mancante o una chiave errata producono un errore esplicito.

**Privacy**
- I nodi di tipo `health`, e tutto ciò che vi è collegato, restano solo su iPad. Non vanno a Supabase, al Worker o ai prompt.
- Il server rifiuta comunque il tipo `health` e l'area `salute` sui nodi tramite i check di `nodes`.
- Nessun segreto nel repository: GitHub Secrets, secret del Worker, Keychain. I nomi sono in `.env.example`.

## Conseguenze

- Le operazioni di sync richiederanno in fase 1 un percorso autorizzato (Worker o policy dedicata), da definire senza aprire accessi ad `anon`.
- Il keep-alive non verifica il contenuto della riga, solo che l'API risponda correttamente.
