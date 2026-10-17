# Prestazioni del database

Script per misurare `sync_pull` su un archivio grande, da lanciare su un database di prova (mai in produzione).

```
psql "$DATABASE_URL" -f backend/supabase/bench/seed.sql
psql "$DATABASE_URL" -f backend/supabase/bench/explain.sql
```

Misure della Fase 5 (600 000 righe sintetiche, Postgres locale): la selezione dei candidati usa solo scansioni
d'indice (0,2 ms); la funzione intera costa circa 60 ms a regime e circa 650 ms alla prima pagina. Accettabile
per un archivio personale; si riguarda se `explain.sql` mostra una scansione sequenziale.
