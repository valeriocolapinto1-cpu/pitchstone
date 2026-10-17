# Pitchstone: documento di architettura

Secondo cervello personale per studio e progetti. Grafo di note in stile Obsidian, appunti a penna su iPad, chat AI sulle proprie fonti, quiz con ripetizione spaziata FSRS.

Stato: versione 1.0, da approvare prima della fase 0. Le voci marcate **[DA VERIFICARE]** dipendono da informazioni esterne o da test su dispositivo.

---

## 1. Visione e ambito

- Uso personale, senza condivisione. Nessun account multiutente nella prima versione.
- Un solo grafo globale con cluster per area di vita: studio, progetti, lavoro e clienti, persone, salute e allenamento, interessi e informazioni.
- Piattaforma primaria: app nativa iPad (SwiftUI). iPhone dopo. PC come PWA nella fase 10.
- Budget: zero. Tutti i servizi su piano gratuito.
- Lingue: italiano e inglese, interfaccia e AI. Quiz nella lingua degli appunti.

Fuori ambito nella prima versione: audio e trascrizione, condivisione, multiutente, versione iPhone, versione PC.

---

## 2. Requisiti chiave

| Area | Requisito |
|---|---|
| Grafo | Pinch per zoom, trascinamento per pan, tap per aprire nodo, doppio tap per modificare, Pencil per collegare due nodi. Cluster per area, ricerca testo più semantica, zoom semantico, etichette solo a zoom alto. |
| Appunti | Markdown con anteprima, editor visuale, scrittura a penna con PencilKit. Strumenti: penna, evidenziatore, gomma, forme, carta a quadretti o righe, lasso. Sul PC si scrive a mano con la tavoletta grafica sulle stesse pagine (formato portabile PSINK1, ADR 0015). |
| PDF e OCR | Annotazioni collegate al grafo. Foto di appunti e scrittura a mano con riconoscimento. PDF divisi automaticamente in parti. |
| Import | Vault Obsidian (file .md con link), PDF e appunti manoscritti. |
| Analisi | Subito dopo il salvataggio, l'AI estrae nodi e collegamenti. Conferma richiesta solo per dati sensibili. |
| Chat | Chat generale sul lato, chat dedicata quando si apre un nodo. Risposte didattiche e precise con citazioni cliccabili verso nodo o pagina PDF. Storico salvato come nodi. Quiz generabili da chat su richiesta. |
| Quiz | Risposta multipla, domande aperte corrette dall'AI, esercizi di calcolo. Difficoltà adattiva, livello scelto per materia. Una domanda per schermata. Massimo 200 per materia. Ripasso FSRS, massimo circa 20 al giorno. |
| Motivazione | Streak giornaliera e obiettivi settimanali in una scheda separata. |
| Promemoria | Ogni mattina alle 8 se ci sono ripassi. Avviso immediato al primo giorno saltato. |
| Calendario | Esami collegati al grafo con data e stato. |
| Eliminazioni | Cestino per 30 giorni. |
| Esportazione | Markdown e PDF in qualsiasi momento. |
| Offline | Lettura e scrittura complete. Sync automatico in background quando torna la connessione. |
| Accessibilità | Dimensione testo, contrasto elevato. Feedback aptico leggero, nessun suono. Tema scuro. |
| Scorciatoie | Cmd+F cerca (Cmd+K resta ai link dell'editor, ADR 0014), Cmd+N nuovo nodo, Cmd+R ripasso, Cmd+/ chat. |

---

## 3. Architettura generale

```
 iPad (SwiftUI, SwiftData, PencilKit, SpriteKit + Metal)
   |  ├─ Modello locale on-device (Apple Foundation Models): chat offline, risposte brevi
   |  ├─ NaturalLanguage: embedding per ricerca semantica offline
   |  ├─ Vision: OCR di foto e scrittura a mano
   |  └─ Sync engine (outbox + pull incrementale)
   |
   |  HTTPS + Cloudflare Access service token (Keychain)
   v
 Cloudflare (piano gratuito)
   |  ├─ Access: protegge tutte le route, login Google per il web, service token per l'iPad
   |  └─ Worker "ai-proxy": chiama Gemini, tiene la chiave API fuori dal dispositivo
   |
   v
 Supabase (piano gratuito, regione Europa)
   ├─ Postgres: nodi, collegamenti, versioni, quiz, ripasso, chat, obiettivi, esami
   ├─ pgvector: embedding per la ricerca semantica lato server (solo dati non sensibili)
   ├─ Storage: bucket privato per PDF e immagini, file divisi sotto 50 MB
   └─ RLS attiva, nessun accesso anonimo diretto

 PC (quando acceso): modello locale più grande, collegato al backend come nodo opzionale
 GitHub (repository privato): codice, CI, keep-alive Supabase
```

### Decisioni di design

- **Offline-first**: il dispositivo è la fonte di verità per la lettura. Il server è il punto di sincronizzazione.
- **Chiavi**: la chiave Gemini non entra mai nell'app. La chiave pubblica Supabase è nell'app, le operazioni sensibili passano dal Worker.
- **Dati di salute**: restano solo su iPad (SwiftData). Non vengono mai inviati a Supabase, al Worker o ai prompt. Vedi sezione 7.
- **Un solo client alla volta**: la sync usa versioni per ogni nodo e risolve i conflitti con lo storico, non con la sovrascrittura.

### Flusso di Access e autenticazione **[DA VERIFICARE]**

Hai chiesto nessun login nell'app e protezione di rete. Un'app nativa non può passare il login Google del browser. Per questo:
- Il web (PWA futura) usa il login Google di Cloudflare Access.
- L'iPad usa un **service token** di Cloudflare Access, salvato nel Keychain.

Va verificato in fase 0 che il piano gratuito di Cloudflare Access supporti i service token. Se non li supporta, la protezione dell'iPad va ripensata, e ne parlo con te prima di procedere.

---

## 4. Stack

| Strato | Scelta | Motivo |
|---|---|---|
| Client iPad | SwiftUI, iOS ultima versione | Nativo, integrazione con penna e Apple Intelligence |
| Penna | PencilKit | Tratto vettoriale, latenza bassa, gratuito |
| Grafo | SpriteKit con shader Metal | Gratuito, nativo, effetti personalizzati |
| Markdown | swift-markdown | Parser standard, rendering nativo |
| DB locale | SwiftData | Integrato con SwiftUI |
| OCR | Vision (RecognizeDocumentRequest) | Gratuito, sul dispositivo, supporta l'italiano |
| LLM locale | Apple Foundation Models | Gratuito, offline, italiano, 4.096 token **[DA VERIFICARE su iPad]** |
| Embedding offline | NaturalLanguage | Gratuito, incluso in iOS |
| LLM online | Gemini, piano gratuito | Matematica migliore, dati usati da Google (accettato) |
| Backend | Supabase Free, regione EU | Postgres, storage, pgvector, gratuito |
| Edge/proxy AI | Cloudflare Worker, piano gratuito | Chiave Gemini fuori dal client |
| Protezione | Cloudflare Access, Google + service token | Accesso limitato, gratuito |
| CI | GitHub Actions, repo privato | Lint e test su Linux, build iOS su macOS con quota **[DA VERIFICARE]** |
| Keep-alive | GitHub Actions cron, Linux | Evita la pausa del progetto Supabase gratuito |

### Limiti dei piani gratuiti da rispettare

- Supabase Free: 500 MB database, 1 GB storage, 50 MB per file, pausa per inattività **[DA VERIFICARE nella dashboard]**.
- GitHub Free, repo privato: 2.000 minuti al mese, macOS consuma 10 volte. Circa 200 minuti macOS reali al mese.
- Gemini Free: dati usati da Google per migliorare i prodotti. Limiti di richiesta giornalieri **[DA VERIFICARE]**.

---

## 5. Schema del database (Postgres, Supabase)

Convenzioni: `id` uuid, `created_at`/`updated_at` timestamptz, `deleted_at` per il cestino, `version` integer per la sync.

```sql
-- Nodi del grafo (solo non sensibili: i nodi di salute non vengono mai inviati)
create table nodes (
  id uuid primary key,
  type text not null check (type in ('concept','idea','project','exam','person')),
  title text not null,
  body_md text not null default '',
  area text not null check (area in ('studio','progetti','lavoro','persone','interessi')),
  tags text[] not null default '{}',
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  device_id text not null
);

-- Collegamenti tra nodi
create table edges (
  id uuid primary key,
  source_id uuid not null references nodes(id) on delete cascade,
  target_id uuid not null references nodes(id) on delete cascade,
  kind text not null check (kind in ('link','ai','manual')),
  label text,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  version integer not null default 1
);

-- Storico versioni di ogni nodo (ripristino)
create table node_versions (
  id uuid primary key,
  node_id uuid not null references nodes(id) on delete cascade,
  version integer not null,
  body_md text not null,
  created_at timestamptz not null default now(),
  device_id text not null,
  unique (node_id, version)
);

-- File caricati (PDF, immagini)
create table attachments (
  id uuid primary key,
  node_id uuid references nodes(id) on delete set null,
  kind text not null check (kind in ('pdf','image','markdown')),
  storage_path text not null,
  size_bytes bigint not null,
  page_count integer,
  sha256 text not null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

-- Pagine di PDF e testo estratto
create table pdf_pages (
  id uuid primary key,
  attachment_id uuid not null references attachments(id) on delete cascade,
  page_no integer not null,
  text_content text,
  ink_data bytea,            -- PKDrawing serializzato (scrittura a penna)
  unique (attachment_id, page_no)
);

-- Frammenti per chat e ricerca (embedding per la ricerca semantica)
create table chunks (
  id uuid primary key,
  node_id uuid references nodes(id) on delete cascade,
  attachment_id uuid references attachments(id) on delete cascade,
  page_no integer,
  content text not null,
  embedding vector(384),      -- dimensione da confermare col modello scelto
  created_at timestamptz not null default now()
);
create index on chunks using hnsw (embedding vector_cosine_ops);

-- Chat
create table chats (
  id uuid primary key,
  node_id uuid references nodes(id) on delete set null,
  title text,
  created_at timestamptz not null default now()
);

create table messages (
  id uuid primary key,
  chat_id uuid not null references chats(id) on delete cascade,
  role text not null check (role in ('user','assistant','system')),
  content text not null,
  citations jsonb not null default '[]',
  provider text check (provider in ('local','gemini')),
  created_at timestamptz not null default now()
);

-- Quiz
create table quizzes (
  id uuid primary key,
  node_id uuid references nodes(id) on delete cascade,
  area text not null,
  kind text not null check (kind in ('mcq','open','calc')),
  question text not null,
  options jsonb,
  answer text not null,
  explanation text,
  difficulty integer not null check (difficulty between 1 and 5),
  language text not null,
  created_at timestamptz not null default now()
);

-- Stato di ripasso FSRS per quiz
create table reviews (
  quiz_id uuid primary key references quizzes(id) on delete cascade,
  due_at timestamptz not null,
  stability real not null default 0,
  difficulty real not null default 0,
  reps integer not null default 0,
  lapses integer not null default 0,
  state text not null default 'new' check (state in ('new','learning','review','relearning')),
  last_review_at timestamptz
);

-- Registro delle risposte (statistiche)
create table review_logs (
  id uuid primary key,
  quiz_id uuid not null references quizzes(id) on delete cascade,
  rating smallint not null check (rating between 1 and 4),
  answered_at timestamptz not null default now(),
  duration_ms integer
);

-- Obiettivi settimanali
create table goals (
  id uuid primary key,
  week_start date not null unique,
  target_quizzes integer not null,
  target_minutes integer not null
);

-- Esami
create table exams (
  id uuid primary key,
  node_id uuid not null references nodes(id) on delete cascade,
  exam_date date,
  status text not null check (status in ('planned','studying','passed','failed'))
);

-- Outbox di sincronizzazione (lato client, opzionale lato server)
create table sync_changes (
  id bigserial primary key,
  entity text not null,
  entity_id uuid not null,
  op text not null check (op in ('upsert','delete')),
  payload jsonb,
  changed_at timestamptz not null default now(),
  device_id text not null
);
```

### Regole di sicurezza

- RLS attiva su tutte le tabelle. Nessuna policy per il ruolo `anon`. L'accesso avviene solo con il service token di Access, che passa dal Worker o da una policy dedicata.
- Vincolo applicativo: nessun nodo di tipo `health` e nessuna riga collegata a un nodo di salute viene scritta sul server. Il client filtra prima dell'invio. Il server rifiuta comunque il tipo `health` perché non è nel check.
- Bucket `attachments`: privato, nessun URL pubblico. Accesso con URL firmati a breve durata.

---

## 6. Flusso dei dati

### 6.1 Salvataggio di un appunto

1. L'utente scrive o disegna. Il client salva in SwiftData e crea una riga in `node_versions` se è passato del tempo dall'ultima versione.
2. Il client mette una voce in `sync_changes`, se il nodo non è sensibile.
3. Quando c'è connessione, il sync invia le modifiche in ordine e riceve le versioni più recenti.
4. Dopo il salvataggio parte l'analisi in background: estrazione di nodi e collegamenti.

### 6.2 Analisi automatica

1. Il client divide il testo in frammenti.
2. Il modello locale (o Gemini, se il locale non basta) propone nodi e collegamenti in forma strutturata.
3. Se un nodo è sensibile (salute, persone), va in conferma. Gli altri vengono creati.
4. Il nodo di salute, se confermato dal tag, resta solo locale. Fino alla conferma è escluso da ogni prompt.

### 6.3 Chat

1. L'utente scrive una domanda. Il client seleziona i frammenti più rilevanti con la ricerca semantica (embedding locali).
2. Esclude i nodi di salute.
3. Se l'utente è online, il Worker chiama Gemini con i frammenti e le istruzioni didattiche. Se è offline, usa il modello locale con un contesto ridotto a 4.096 token.
4. La risposta include citazioni: ogni citazione apre il nodo o la pagina del PDF.
5. La conversazione viene salvata come nodo di tipo `idea` o `concept`, collegato al nodo di origine.

### 6.4 Quiz e ripasso

1. Su richiesta o in automatico dopo l'analisi, il sistema genera quiz dagli appunti, nella lingua degli appunti.
2. Le domande di calcolo e quelle aperte vanno a Gemini online. Offline restano in coda.
3. Ogni risposta crea una riga in `review_logs` e aggiorna `reviews` con FSRS.
4. Il promemoria delle 8 mostra i ripassi in scadenza. Se un giorno viene saltato, l'avviso arriva subito.

### 6.5 Sync

- Pull incrementale: il client chiede le righe modificate dopo l'ultima sincronizzazione.
- Push: invia le modifiche dalla `sync_changes` in ordine di tempo.
- Conflitti: se la stessa versione è stata modificata su due dispositivi, il sistema crea una nuova versione con entrambe le modifiche e tiene lo storico. Nessuna perdita di dati.

### 6.6 Backup

- Backup giornaliero del database su Supabase, senza nodi di salute, come da decisione.
- Backup locale dei nodi di salute su iPad, esportabile in file cifrato dall'app.

---

## 7. Privacy e dati sensibili

| Tipo di dato | Dove resta | Va all'AI esterna | Nel backup server |
|---|---|---|---|
| Appunti normali | iPad e Supabase | Sì (piano gratuito Gemini, accettato) | Sì |
| Nodi di salute | Solo iPad | No | No |
| Chat su nodi di salute | Solo iPad | No | No |
| Statistiche di studio | Solo iPad | No | No |
| PDF e immagini | Supabase Storage, privato | Solo frammenti testuali selezionati | Sì, sotto 50 MB per file |

Regole operative:
- Un nodo è sensibile se ha il tipo `health`, oppure se è stato rilevato come tale e non confermato. In entrambi i casi è escluso dai prompt.
- Il rilevamento automatico della salute va testato su un set di esempi prima di essere attivato. Il set lo costruiamo in fase 6, con esempi che confermi tu.
- Gemini: piano gratuito, dati usati da Google. Va verificato sul sito ufficiale che la regola per utenti in Europa sia compatibile. **[DA VERIFICARE]**

---

## 8. Struttura del repository

```
pitchstone/
├── README.md
├── ARCHITETTURA.md                 # questo documento
├── docs/
│   ├── decisioni/                  # ADR, una decisione per file
│   └── fasi/                       # stato e criteri di ogni fase
├── ios/
│   ├── Pitchstone.xcodeproj        # creato in fase 0 o 2
│   ├── Pitchstone/
│   │   ├── App/
│   │   ├── Features/               # Grafo, Editor, Chat, Quiz, Calendario, Impostazioni
│   │   ├── Core/                   # modelli, sync, privacy, AI locale
│   │   ├── Graph/                  # SpriteKit + shader Metal
│   │   └── Resources/
│   └── PitchstoneTests/
├── backend/
│   ├── supabase/
│   │   ├── migrations/             # schema SQL versionato
│   │   ├── seed/
│   │   └── config.toml
│   └── worker-ai/                  # Cloudflare Worker per Gemini
├── tools/
│   └── keepalive/                  # script del keep-alive, se serve
└── .github/
    └── workflows/
        ├── ci-linux.yml            # lint e test del backend, ogni PR
        ├── ci-ios.yml              # build e test iOS su macOS, solo su main o su richiesta
        └── keepalive.yml           # ping Supabase ogni 3 giorni
```

Regole del repository:
- Nessun segreto nel repository. Le chiavi stanno in GitHub Secrets o nel Keychain.
- Un file `.env.example` documenta le variabili senza valori.
- La build iOS su macOS gira solo su `main` o manualmente, per risparmiare minuti.

---

## 9. Piano in fasi

Ogni fase ha: obiettivo, criteri di completamento, test richiesti. Ogni fase segue il ciclo: sviluppo, revisione finale di un subagente, PR, test in CI, merge se verde, avvio automatico della fase successiva.

### Fase 0: base
- **Obiettivo**: repository, CI, Supabase, Cloudflare Access, keep-alive, documentazione.
- **Criteri**: repo privato creato. CI Linux verde su una PR di prova. Workflow keep-alive eseguito una volta con successo. Access attivo con login Google. Service token creato e documentato. Schema vuoto con RLS attiva.
- **Test**: lint e test del backend in CI. Un test che verifica che il keep-alive non tocchi tabelle utente.

### Fase 1: dati e sincronizzazione
- **Obiettivo**: modello dati in SwiftData, outbox, pull e push con Supabase, versioni dei nodi, cestino.
- **Criteri**: un nodo creato su un dispositivo compare sull'altro. Modifiche offline vengono sincronizzate al ritorno della connessione. Il cestino conserva per 30 giorni.
- **Test**: test unitari sul sync. Test di conflitto con due versioni.

### Fase 2: editor e penna
- **Obiettivo**: editor Markdown con anteprima, editor visuale, PencilKit con gli strumenti concordati, sfondi a righe e quadretti.
- **Criteri**: scrittura fluida con Pencil. Il disegno si salva in `pdf_pages` o in un nodo di appunti. Lo storico versioni è accessibile.
- **Test**: test di serializzazione PKDrawing. Test di rendering Markdown.

### Fase 3: grafo
- **Obiettivo**: grafo con SpriteKit, shader Metal, cluster per area, gesti, ricerca con filtri, zoom semantico.
- **Criteri**: il grafo resta fluido con diverse migliaia di nodi. I gesti concordati funzionano. I nodi di salute sono visibili con colore dedicato.
- **Test**: test di prestazioni su un grafo di esempio. Test dei gesti principali.

### Fase 4: import, PDF e OCR
- **Obiettivo**: import di vault Obsidian, PDF con annotazioni collegate al grafo, foto di appunti con OCR, scrittura a mano riconosciuta.
- **Criteri**: un vault di esempio viene importato con i link. Un PDF di 100 MB viene diviso in parti sotto 50 MB e ricomposto alla lettura. L'OCR dà testo ricercabile.
- **Test**: test di import con vault di esempio. Test di divisione PDF.

### Fase 5: chat AI
- **Obiettivo**: chat generale e per nodo, modello locale su iPad, Worker per Gemini, ricerca semantica, citazioni cliccabili, storico salvato come nodi.
- **Criteri**: la chat risponde online con Gemini e offline con il modello locale. Le citazioni aprono il nodo o la pagina. I nodi di salute non compaiono nei prompt. La chat viene salvata come nodo.
- **Test**: test che verificano l'esclusione dei nodi di salute. Test di citazioni. Test di fallback offline.
- **Verifica su dispositivo**: qualità dell'italiano e gestione dei 4.096 token sul tuo iPad.

### Fase 6: analisi automatica
- **Obiettivo**: estrazione di nodi e collegamenti dagli appunti, conferma per i dati sensibili, rilevamento della salute con tag manuale.
- **Criteri**: un appunto di esempio produce nodi e collegamenti corretti. I dati sensibili richiedono conferma. Il rilevamento della salute supera il set di test.
- **Test**: set di esempi per il rilevamento della salute. Test di conferma.

### Fase 7: quiz e ripasso
- **Obiettivo**: quiz a risposta multipla, domande aperte corrette dall'AI, esercizi di calcolo, FSRS, streak, obiettivi settimanali, promemoria delle 8, avviso immediato per i ritardi.
- **Criteri**: un quiz per schermata con feedback immediato. FSRS aggiorna le scadenze. Lo streak si azzera correttamente. Il promemoria arriva alle 8.
- **Test**: test dell'algoritmo FSRS con casi noti. Test delle notifiche.

### Fase 8: esami, backup ed esportazione
- **Obiettivo**: calendario esami collegato al grafo, backup giornaliero su Supabase senza salute, backup locale della salute, esportazione Markdown e PDF.
- **Criteri**: un esame compare nel calendario e nel grafo. Il backup giornaliero non contiene nodi di salute. L'esportazione produce file leggibili.
- **Test**: test del filtro di backup. Test di esportazione.

### Fase 9: rifinitura
- **Obiettivo**: tema scuro definitivo, strumenti Pencil completi, prestazioni del grafo, accessibilità, onboarding in tre schermate, scorciatoie da tastiera, icona.
- **Criteri**: accessibilità con dimensione testo e contrasto elevato. Scorciatoie funzionanti con tastiera esterna. Onboarding al primo avvio.
- **Test**: test di accessibilità di base.

### Fase 10: versione PC
- **Obiettivo**: PWA per il computer con login Google di Cloudflare Access, stessa API del client iPad.
- **Criteri**: il PC vede gli stessi dati dell'iPad. Il modello locale del PC funziona quando è acceso.
- **Test**: test end-to-end della sincronizzazione tra iPad e PWA.

---

## 10. Pipeline CI

- **ci-linux.yml**: su ogni PR. Lint, test del backend, controllo dello schema SQL. Usa solo minuti Linux, che costano 1 per minuto.
- **ci-ios.yml**: su `main` o manualmente. Build e test del progetto iOS su macOS. Circa 10 volte il costo in minuti. Eseguita solo quando serve, per restare nei circa 200 minuti macOS al mese.
- **keepalive.yml**: ogni 3 giorni. Esegue una `select` leggera su una tabella di servizio con la chiave pubblica. Costo stimato: circa 10 minuti al mese.

Regole della PR:
- Ogni PR contiene una sola fase o una sola parte di fase.
- Il merge avviene solo con CI verde.
- Dopo il merge della fase, parte la fase successiva.

---

## 11. Rischi e punti aperti

| Rischio | Impatto | Mitigazione |
|---|---|---|
| Pausa di Supabase per inattività | Il progetto va offline | Keep-alive su GitHub. Verifica nella dashboard **[DA VERIFICARE]** |
| 1 GB di storage Supabase | Spazio esaurito con molti PDF | Compressione, avviso al 80%, eliminazione nel cestino |
| Minuti macOS limitati | Build iOS sospese | Build solo su main, sviluppo locale con Sideloadly |
| Dati di salute classificati male | Dati sensibili nei prompt | Tag manuale, test su set di esempi, esclusione per default |
| Gemini usa i dati per migliorare il servizio | Privacy | Accettato. Nodi di salute esclusi |
| Modello locale insufficiente in italiano | Chat offline scadente | Fallback a Gemini online, test in fase 5 |
| Access con service token non supportato | IPad senza accesso | Verifica in fase 0 prima di tutto il resto |
| 4.096 token nel modello locale | Contesto limitato | Frammenti selezionati, chat corte |

---

## 12. Cosa fare fuori da Claude Code

Vedi il file `PROCEDURE_FUORI_CLAUDE_CODE.md`. Prima della fase 0 servono:
- account GitHub e repo privato,
- progetto Supabase in Europa,
- account Cloudflare con Zero Trust attivo,
- chiave Gemini, senza mai metterla nel repository,
- verifiche dei punti marcati come da verificare.
