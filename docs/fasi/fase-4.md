# Fase 4: import, PDF e OCR

Stato: in corso, in tre parti.
1. Import di vault Obsidian ([ADR 0006](../decisioni/0006-import-obsidian.md)): completata con #7.
2. Allegati e PDF ([ADR 0007](../decisioni/0007-allegati.md)): bucket privato, file divisi sotto 50 MB, lettore con annotazioni. In revisione.
3. OCR di foto e scrittura a mano.

Screenshot automatici: a ogni esecuzione di ci-ios i test di interfaccia (`ios/PitchstoneUITests`) aprono l'app con dati dimostrativi e fotografano le schermate principali; le immagini vanno in `refs/screenshots/latest` (`git fetch origin refs/screenshots/latest`).

## Obiettivo

Import di vault Obsidian, PDF con annotazioni collegate al grafo, foto di appunti con OCR, scrittura a mano riconosciuta.

## Criteri di completamento

- [x] Un vault di esempio viene importato con i link (`ios/PitchstoneKit/Tests/PitchstoneImportTests/VaultDiEsempio`).
- [x] Un PDF di 100 MB viene diviso in parti sotto 50 MB e ricomposto alla lettura (test di sync con 100 MB: tre parti da 45 MiB al massimo, file identico sull'altro dispositivo).
- [ ] L'OCR dà testo ricercabile.
- [x] Bucket `attachments` privato, senza URL pubblici, accesso con URL firmati a breve durata (test end-to-end con lo storage locale).

## Test

- [x] Test di import con vault di esempio: lettura, titoli doppi, link con cartelle, sezioni, alias e tabelle, codice intatto, tag, aree, salute fuori dall'outbox, reimport senza doppioni.
- [x] Test di divisione PDF: parti, SHA-256, ricomposizione, file manomesso rifiutato, upload prima della riga, allegati di salute locali, annotazioni in conflitto, pulizia del bucket.
