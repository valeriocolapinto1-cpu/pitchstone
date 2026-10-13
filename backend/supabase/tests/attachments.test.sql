begin;
select plan(20);

select ok(not has_table_privilege('anon', 'public.attachments', 'SELECT'), 'anon non legge gli allegati');
select ok(not has_table_privilege('anon', 'public.storage_trash', 'SELECT'), 'anon non legge la coda dei file');
select ok(not has_function_privilege('authenticated', 'public.storage_trash_list(integer)', 'EXECUTE'), 'authenticated non legge la coda');
select ok(
  (select not public from storage.buckets where id = 'attachments'),
  'bucket attachments privato');

set local role service_role;

create temp table t (k text primary key, v jsonb) on commit drop;
insert into t values ('c0', to_jsonb((public.sync_pull(0, 1000))->'cursor'));

select public.sync_push('ipad-a', $$[
  {"entity":"node","base_version":null,"data":{"id":"30000000-0000-4000-8000-000000000001","type":"concept","title":"Dispensa","area":"studio"}}
]$$);

-- Creazione.
insert into t values ('create', public.sync_push('ipad-a', $$[
  {"entity":"attachment","base_version":null,"data":{"id":"30000000-0000-4000-8000-0000000000a1","node_id":"30000000-0000-4000-8000-000000000001",
   "kind":"pdf","storage_path":"30000000-0000-4000-8000-0000000000a1","size_bytes":104857600,"page_count":12,
   "sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","file_name":"Analisi.pdf","part_count":3}}
]$$));
select is((select v #>> '{results,0,status}' from t where k = 'create'), 'created', 'allegato creato');
select is((select v #>> '{results,0,record,part_count}' from t where k = 'create'), '3', 'tre parti');

-- Il percorso nel bucket deve essere l'id.
select is((public.sync_push('ipad-a', $$[
  {"entity":"attachment","base_version":null,"data":{"id":"30000000-0000-4000-8000-0000000000a2","node_id":null,
   "kind":"pdf","storage_path":"30000000-0000-4000-8000-0000000000a1","size_bytes":10,
   "sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","file_name":"x.pdf","part_count":1}}
]$$)) #>> '{results,0,status}', 'rejected', 'percorso diverso dall''id: rifiutato');

-- Il contenuto non cambia.
select is((public.sync_push('ipad-b', $$[
  {"entity":"attachment","base_version":1,"data":{"id":"30000000-0000-4000-8000-0000000000a1","node_id":"30000000-0000-4000-8000-000000000001",
   "kind":"pdf","storage_path":"30000000-0000-4000-8000-0000000000a1","size_bytes":5,
   "sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","file_name":"Analisi.pdf","part_count":1}}
]$$)) #>> '{results,0,status}', 'rejected', 'contenuto diverso: rifiutato');

-- Rinomina con la versione giusta.
select is((public.sync_push('ipad-b', $$[
  {"entity":"attachment","base_version":1,"data":{"id":"30000000-0000-4000-8000-0000000000a1","node_id":"30000000-0000-4000-8000-000000000001",
   "kind":"pdf","storage_path":"30000000-0000-4000-8000-0000000000a1","size_bytes":104857600,
   "sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","file_name":"Analisi 1.pdf","part_count":3}}
]$$)) #>> '{results,0,status}', 'updated', 'rinomina');

-- Conflitto: un'eliminazione vecchia non cancella, un ripristino vince.
select is((public.sync_push('ipad-a', $$[
  {"entity":"attachment","base_version":1,"data":{"id":"30000000-0000-4000-8000-0000000000a1","node_id":"30000000-0000-4000-8000-000000000001",
   "kind":"pdf","storage_path":"30000000-0000-4000-8000-0000000000a1","size_bytes":104857600,
   "sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","file_name":"Analisi 1.pdf","part_count":3,
   "deleted_at":"2026-10-14T10:00:00Z"}}
]$$)) #>> '{results,0,status}', 'merged', 'eliminazione in conflitto: unita');
select isnt((select deleted_at from public.attachments where id = '30000000-0000-4000-8000-0000000000a1'), null,
  'eliminazione applicata (nessuno aveva ripristinato)');

-- Annotazione su una pagina del PDF e copia in conflitto sulla stessa pagina.
select public.sync_push('ipad-a', $$[
  {"entity":"ink_page","base_version":null,"data":{"id":"30000000-0000-4000-8000-000000000101","node_id":"30000000-0000-4000-8000-000000000001",
   "page_no":0,"ink_data":"AAE=","attachment_id":"30000000-0000-4000-8000-0000000000a1","pdf_page":4}}
]$$);
select public.sync_push('ipad-b', $$[
  {"entity":"ink_page","base_version":1,"data":{"id":"30000000-0000-4000-8000-000000000101","node_id":"30000000-0000-4000-8000-000000000001",
   "page_no":0,"ink_data":"AgM=","attachment_id":"30000000-0000-4000-8000-0000000000a1","pdf_page":4}}
]$$);
insert into t values ('conflict', public.sync_push('ipad-a', $$[
  {"entity":"ink_page","base_version":1,"data":{"id":"30000000-0000-4000-8000-000000000101","node_id":"30000000-0000-4000-8000-000000000001",
   "page_no":0,"ink_data":"BAU=","attachment_id":"30000000-0000-4000-8000-0000000000a1","pdf_page":4}}
]$$));
select is(
  (select count(*)::int from public.ink_pages where attachment_id = '30000000-0000-4000-8000-0000000000a1' and pdf_page = 4),
  2, 'conflitto: due strati sulla stessa pagina del PDF');
select ok(
  (select v #> '{results,0,record}' from t where k = 'conflict') ? 'attachment_id',
  'la pagina restituita porta l''allegato');

-- Pull da un altro dispositivo.
select ok(
  (select public.sync_pull((v #>> '{}')::bigint, 100)->'changes'
     @> '[{"entity":"attachment","data":{"id":"30000000-0000-4000-8000-0000000000a1","file_name":"Analisi 1.pdf","part_count":3}}]'
   from t where k = 'c0'),
  'l''allegato arriva con il pull');

-- Pulizia del cestino: la riga va, i file in coda per il Worker, le annotazioni seguono.
update public.attachments set deleted_at = now() - interval '31 days' where id = '30000000-0000-4000-8000-0000000000a1';
select public.purge_trash();
select is((select count(*)::int from public.attachments where id = '30000000-0000-4000-8000-0000000000a1'), 0, 'allegato eliminato');
select is((select count(*)::int from public.ink_pages where attachment_id = '30000000-0000-4000-8000-0000000000a1'), 0, 'annotazioni eliminate');
select is((select count(*)::int from public.purged where entity = 'ink_page'), 2, 'annotazioni nel registro dei purged');
select is(public.storage_trash_list(10), '[{"path":"30000000-0000-4000-8000-0000000000a1","part_count":3}]'::jsonb, 'file in coda');
select is(public.storage_trash_done(array['30000000-0000-4000-8000-0000000000a1']), 1, 'coda confermata');
select is(public.storage_trash_list(10), '[]'::jsonb, 'coda vuota');

select * from finish();
rollback;
