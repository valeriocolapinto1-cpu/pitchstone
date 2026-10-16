# Fase 8: esami, backup ed esportazione

Stato: completata ([ADR 0012](../decisioni/0012-esami-backup.md)).

## Obiettivo

Calendario esami collegato al grafo, backup giornaliero su Supabase senza salute, backup locale della salute, esportazione Markdown e PDF.

## Criteri di completamento

- [x] Un esame compare nel calendario e nel grafo (`ExamTests`, etichetta con la data nel grafo).
- [x] Il backup giornaliero non contiene nodi di salute (`backup.test.sql`, `backup.test.ts`, end-to-end con lo storage locale).
- [x] L'esportazione produce file leggibili (Markdown con frontmatter, PDF, backup cifrato apribile solo con la password).

## Test

- [x] Test del filtro di backup.
- [x] Test di esportazione.

## Verifica su dispositivo

- [ ] Primo backup giornaliero nel bucket `backups` dopo il deploy del Worker.
- [ ] Esportazione e ripristino del backup di salute da File.
