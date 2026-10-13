-- Schema iniziale (ARCHITETTURA.md, sezione 5).
-- I nodi di salute non arrivano mai qui: il check su nodes.type non ammette 'health'.

create extension if not exists vector with schema extensions;

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

create table node_versions (
  id uuid primary key,
  node_id uuid not null references nodes(id) on delete cascade,
  version integer not null,
  body_md text not null,
  created_at timestamptz not null default now(),
  device_id text not null,
  unique (node_id, version)
);

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

create table pdf_pages (
  id uuid primary key,
  attachment_id uuid not null references attachments(id) on delete cascade,
  page_no integer not null,
  text_content text,
  ink_data bytea,
  unique (attachment_id, page_no)
);

create table chunks (
  id uuid primary key,
  node_id uuid references nodes(id) on delete cascade,
  attachment_id uuid references attachments(id) on delete cascade,
  page_no integer,
  content text not null,
  embedding extensions.vector(384),
  created_at timestamptz not null default now()
);
create index on chunks using hnsw (embedding extensions.vector_cosine_ops);

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

create table review_logs (
  id uuid primary key,
  quiz_id uuid not null references quizzes(id) on delete cascade,
  rating smallint not null check (rating between 1 and 4),
  answered_at timestamptz not null default now(),
  duration_ms integer
);

create table goals (
  id uuid primary key,
  week_start date not null unique,
  target_quizzes integer not null,
  target_minutes integer not null
);

create table exams (
  id uuid primary key,
  node_id uuid not null references nodes(id) on delete cascade,
  exam_date date,
  status text not null check (status in ('planned','studying','passed','failed'))
);

create table sync_changes (
  id bigserial primary key,
  entity text not null,
  entity_id uuid not null,
  op text not null check (op in ('upsert','delete')),
  payload jsonb,
  changed_at timestamptz not null default now(),
  device_id text not null
);

-- Tabella di servizio per il keep-alive: una sola riga, nessun dato utente.
create table keepalive (
  id smallint primary key default 1 check (id = 1)
);
insert into keepalive default values;

alter table nodes enable row level security;
alter table edges enable row level security;
alter table node_versions enable row level security;
alter table attachments enable row level security;
alter table pdf_pages enable row level security;
alter table chunks enable row level security;
alter table chats enable row level security;
alter table messages enable row level security;
alter table quizzes enable row level security;
alter table reviews enable row level security;
alter table review_logs enable row level security;
alter table goals enable row level security;
alter table exams enable row level security;
alter table sync_changes enable row level security;
alter table keepalive enable row level security;

-- Oltre a RLS senza policy, anon non ha privilegi sulle tabelle utente.
-- Il keep-alive ha solo SELECT su keepalive: RLS restituisce un array vuoto,
-- sufficiente a generare attività senza esporre righe.
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke all on all functions in schema public from anon;
alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke all on sequences from anon;
alter default privileges for role postgres in schema public revoke all on functions from anon;
grant select on keepalive to anon;
