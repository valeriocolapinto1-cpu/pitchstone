# Fase 4: import, PDF e OCR

Stato: in corso, in tre parti.
1. Import di vault Obsidian ([ADR 0006](../decisioni/0006-import-obsidian.md)): in revisione.
2. Allegati e PDF: bucket privato, file divisi sotto 50 MB, lettore con annotazioni.
3. OCR di foto e scrittura a mano.

## Obiettivo

Import di vault Obsidian, PDF con annotazioni collegate al grafo, foto di appunti con OCR, scrittura a mano riconosciuta.

## Criteri di completamento

- [x] Un vault di esempio viene importato con i link (`ios/PitchstoneKit/Tests/PitchstoneImportTests/VaultDiEsempio`).
- [ ] Un PDF di 100 MB viene diviso in parti sotto 50 MB e ricomposto alla lettura.
- [ ] L'OCR dà testo ricercabile.
- [ ] Bucket `attachments` privato, senza URL pubblici, accesso con URL firmati a breve durata.

## Test

- [x] Test di import con vault di esempio: lettura, titoli doppi, link con cartelle, sezioni, alias e tabelle, codice intatto, tag, aree, salute fuori dall'outbox, reimport senza doppioni.
- [ ] Test di divisione PDF.
