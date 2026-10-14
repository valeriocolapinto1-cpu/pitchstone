begin;
select plan(13);

select has_extension('extensions', 'vector', 'estensione vector installata');

select tables_are('public', array[
  'nodes', 'edges', 'node_versions', 'attachments', 'pdf_pages', 'chunks', 'chats',
  'messages', 'quizzes', 'reviews', 'review_logs', 'goals', 'exams', 'sync_changes', 'keepalive', 'purged', 'ink_pages',
  'storage_trash'
], 'tabelle della sezione 5 più keepalive, purged, ink_pages e storage_trash');

select is(
  (select count(*)::int from pg_tables where schemaname = 'public' and not rowsecurity),
  0, 'RLS attiva su tutte le tabelle');

-- Una policy senza clausola TO vale per public, che include anon.
select is(
  (select count(*)::int from pg_policies
    where schemaname = 'public' and roles && array['anon', 'public']::name[]),
  0, 'nessuna policy per anon');

-- has_table_privilege considera anche i grant a public.
select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p') and c.relname <> 'keepalive'
      and has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')),
  0, 'anon senza privilegi sulle tabelle utente');

select ok(
  has_table_privilege('anon', 'public.keepalive', 'SELECT')
    and not has_table_privilege('anon', 'public.keepalive', 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),
  'anon ha solo SELECT su keepalive');

select is((select count(*)::int from keepalive), 1, 'keepalive ha una sola riga');

select throws_ok(
  $$insert into keepalive (id) values (2)$$, '23514', null, 'keepalive non accetta altre righe');

select throws_ok(
  $$insert into nodes (id, type, title, area, device_id)
    values (gen_random_uuid(), 'health', 'x', 'studio', 'test')$$,
  '23514', null, 'il tipo health è rifiutato');

select throws_ok(
  $$insert into nodes (id, type, title, area, device_id)
    values (gen_random_uuid(), 'concept', 'x', 'salute', 'test')$$,
  '23514', null, 'l''area salute è rifiutata');

set local role anon;

select throws_ok($$select * from nodes$$, '42501', null, 'anon non legge nodes');
select throws_ok($$insert into keepalive (id) values (1)$$, '42501', null, 'anon non scrive keepalive');
select is_empty($$select * from keepalive$$, 'anon interroga keepalive senza vedere righe');

select * from finish();
rollback;
