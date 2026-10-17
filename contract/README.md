# Contratto della sincronizzazione

Lo stesso formato è parlato da quattro parti: l'app iPad (Swift, `ios/PitchstoneKit/Sources/PitchstoneSync/Wire.swift`),
la PWA (`web/src/sync.ts`), il Worker (`backend/worker-ai/src/sync.ts`) e il database (`sync_push` e `sync_pull`
in `backend/supabase/migrations`). Qui sta ciò che le accomuna.

- `schema/` JSON Schema delle richieste e delle risposte di `/sync/push` e `/sync/pull`.
- `fixtures/` esempi reali, usati dai test di tutte le parti: se un esempio non passa più in una di loro, il contratto si è rotto.

I test che li usano: `ios/PitchstoneKit/Tests/PitchstoneSyncTests/ContractTests.swift`, `web/test/contract.test.ts`,
`backend/worker-ai/test/contract.test.ts`.

## Versione

Ogni richiesta porta `X-Pitchstone-Api: <n>`; ogni risposta dichiara la versione del server nella stessa intestazione.
Il Worker risponde `426` a un client con una versione sotto il minimo (`MIN_API_VERSION`): l'app mostra «Aggiorna l'app».
Una richiesta senza l'intestazione (client precedenti) passa. Si alza la versione solo per un cambio incompatibile.
`GET /sync/config` restituisce i limiti in vigore (modifiche per push, byte, pagina del pull, lunghezze).

## Regole

- Date ISO 8601 con frazioni fino ai microsecondi (Postgres).
- Un rifiuto in `/sync/push` ha `status: "rejected"`, `error` (SQLSTATE) e `message` (un codice fisso: `invalid`, `missing_parent`, `too_large`, `forbidden_type`, `conflict`; mai il testo dell'errore del database).
- `/sync/pull` restituisce `epoch`: un client che vede un'epoca diversa dalla sua riparte dal cursore 0 (un ripristino dal backup la cambia).
- Un'entità o uno stato sconosciuti si ignorano senza rompere il resto (i client vecchi convivono con un server nuovo).
