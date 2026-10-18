# ADR 0012: esami, backup ed esportazione

Stato: accettata, 2026-10-14. Riferimento: ARCHITETTURA.md, sezioni 6.6, 7 e 9 (fase 8).

## Decisioni

- Esami: sono nodi di tipo `exam`; data e stato stanno nei tag del nodo (`data:2027-01-20`, `stato:studio`), così si sincronizzano senza una tabella nuova e restano leggibili in un export Markdown. La tabella `exams` dell'architettura non si usa. Il calendario mostra data, giorni mancanti, stato, nodi collegati nel grafo e quiz della materia; nel grafo l'esame porta la data nell'etichetta.
- Backup giornaliero sul server: il piano gratuito di Supabase non ha backup scaricabili. Il Worker, dopo la pulizia del cestino (cron delle 04:30 UTC), chiama `backup_snapshot()` (solo service_role) e salva un JSON di nodi, archi, pagine a penna e metadati degli allegati nel bucket privato `backups`, tenuto 14 giorni. Il database non può contenere dati di salute (vincoli su `nodes`); la funzione e il Worker li filtrano comunque, e un'istantanea con dati di salute non viene salvata. I file degli allegati sono già nel loro bucket.
- Backup locale della salute: un file cifrato con AES-GCM e una chiave PBKDF2-SHA256 (310.000 iterazioni, sale casuale) dalla password dell'utente, con nodi di salute, archi, pagine a penna e allegati con i file. Il ripristino aggiunge ciò che manca e rifiuta un archivio con dati non di salute, così niente finisce in sync per errore.
- Esportazione: cartella Markdown compatibile con Obsidian (un file per nodo, frontmatter con tipo, area, tag e date; salute esclusa salvo scelta esplicita) e PDF di un nodo dal suo Markdown (HTML stampato in A4).

## Conseguenze

- Il backup sul server copre i dati sincronizzati, non i quiz e le statistiche (solo locali, ADR 0011).
- La password del backup di salute non si recupera.

## Aggiornamento (Fase 8)
Il backup cifrato dei dati di salute passa al formato `PSB2`: PBKDF2-SHA256 con 600 000 iterazioni scritte nell'intestazione, e intestazione, iterazioni e sale come dati autenticati di AES-GCM. L'esito di `CCKeyDerivationPBKDF` e quello della generazione del sale vengono controllati; un file con iterazioni fuori scala (oltre 10 milioni) o oltre 600 MB si rifiuta prima di derivare la chiave. I file `PSB1` si aprono ancora.
