# ADR 0017: privacy dei dati di salute e controllo sul cloud

Stato: accettata, 2026-10-17. Integra l'ADR 0001 (stack e privacy) e l'ADR 0010 (analisi).

## Decisioni

- **Rilevatore a chiusura**: oltre all'italiano e all'inglese riconosce francese, spagnolo e tedesco. Un testo in un'altra scrittura (cirillico, arabo, CJK…) o in una lingua latina sconosciuta non si può giudicare: ha il segnale «lingua non verificabile», è sospetto e resta trattenuto finché l'utente non lo dichiara innocuo. Contano solo le parole di almeno 3 lettere e servono 15 parole per giudicare la lingua, così formule e codice non fanno scattare l'allarme. L'iPad (`HealthDetector.swift`) e il PC (`web/src/health.ts`) hanno gli stessi elenchi e gli stessi esempi nei test.
- **PC**: gli appunti sospetti, o tenuti solo qui con il tag `solo-locale`, non vanno al server (le loro modifiche, i loro archi e le loro pagine restano in outbox), non entrano nei frammenti del tutor e non finiscono in nessun prompt. «Tieni solo qui» su un nodo già sul server lo toglie dal server (`/sync/redact`) e lo tiene sul PC come record mai sincronizzato. La chat parte «solo locale» per impostazione predefinita; per usare Gemini bisogna disattivarlo e confermare a ogni invio. Una domanda che sembra di salute non va mai a Gemini.
- **iPad**: stesse guardie nei quiz (`QuizGenerator.checkedPrompt`) e nella correzione delle domande aperte (la risposta scritta dall'utente non va online se sembra di salute); una chat con una domanda sospetta si salva come dato di salute, solo locale; confermare un dato di salute cancella i quiz derivati e, per una nota già sul server, la toglie dal server (coda `redactQueue`, si riprova finché ci riesce); «Non è un dato di salute» non fa partire subito la sync ma segue il ritardo normale.
- **Allegati**: un allegato parte solo dopo che il suo testo è stato estratto e valutato insieme al corpo del nodo; uno senza nodo resta sull'iPad. I file degli allegati sono esclusi dai backup di iCloud e protetti a dispositivo bloccato; il database locale è escluso dai backup e protetto fino al primo sblocco (non la protezione completa: la sync in background parte a dispositivo bloccato).
- **Rete (iPad)**: sessione effimera senza cache né cookie, redirect rifiutati, URL firmati accettati solo se `https`, senza credenziali nell'URL, sulla porta 443 e con un host di Supabase (`*.supabase.co`).
- **Controllo sul cloud**: interruttore globale «Sincronizzazione attiva» (iPad e PC) che spegne ogni invio, Gemini compreso; «Esporta tutto (JSON)» sul PC (`/account/export`, a pagine: cestino, storico e disegni compresi) e «Cancella tutto dal server» su entrambi (`/account/erase`: database, file degli allegati e backup, con parola d'ordine; nuova epoca di sincronizzazione). Sul PC «Cancella dati locali» e «Esci» tolgono archivio, preferenze, cache e service worker. L'archivio del PC chiede la persistenza al browser e, se IndexedDB non è disponibile, lo dice invece di perdere i dati in silenzio.

## Conseguenze

- Un testo in una lingua sconosciuta si sblocca con un tocco, ma ogni nota in una lingua non supportata passa da una scelta dell'utente.
- I backup già scritti (14 giorni) possono ancora contenere una nota poi tolta dal server con `/sync/redact`.
- Dopo «Cancella tutto dal server» i dispositivi tengono i loro dati: le modifiche future ricreano singole note sul server; la gestione dell'epoca di sincronizzazione sui client è nella Fase 4.
