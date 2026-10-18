# 0021 — PWA, sicurezza del frontend, accessibilità

## Fatto
- PWA: `manifest` con `id`, `scope` e icone (anche maskable), `apple-touch-icon`; service worker con precache dei file con hash (elenco scritto dalla build), `skipWaiting` + `clients.claim`, percorsi API esclusi per prefisso esatto, nessuna cache di redirect o errori.
- Header (`web/public/_headers`): CSP (`script-src 'self'`, `img-src 'self' data:`, `connect-src` solo origine propria e Ollama locale, `frame-ancestors 'none'`), `nosniff`, `Referrer-Policy: no-referrer`, COOP.
- DOMPurify: niente `img`, `style`, `form`, attributo `style`; `rel="noopener noreferrer"` sui link; `data-title` ammesso solo su `.wiki`.
- Id: la pull scarta record con id `__proto__`/`constructor`/`prototype`; `nodeFromLink` non lancia più su `%` isolati. I `[[wikilink]]` dell'anteprima non vengono più segnati dentro codice in linea e blocchi.
- Accessibilità web: righe dell'elenco e wikilink raggiungibili da tastiera, chat come dialogo (Esc, focus intrappolato, `aria-live`), focus visibile, bersagli da 24 px, `prefers-reduced-motion`.
- iPad: Reduce Motion rispettato in chat e presentazione; annuncio VoiceOver dell'esito del quiz.
- `lib` senza `WebWorker`.

## Non fatto (scelta)
`noUncheckedIndexedAccess` (62 errori, la maggior parte in `ink*.ts`: i `!` meccanici non migliorano la sicurezza), spezzare `main.ts` e `createApp()`, eslint/prettier sul web (Fase 8), `Localizable.xcstrings`, plurali, token di design condivisi, "Collega a…" per il grafo, pan/zoom da tastiera, Dynamic Type nel grafo, tasti numerici del quiz, un solo `enum Sheet`, menu della sidebar: modifiche ampie a SwiftUI e ai testi che qui non si possono compilare né provare con VoiceOver.
