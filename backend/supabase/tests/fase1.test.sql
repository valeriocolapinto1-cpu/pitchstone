begin;
select plan(17);

-- Privilegi.
select ok(not has_table_privilege('authenticated', 'public.nodes', 'SELECT'), 'authenticated non legge nodes');
select ok(not has_table_privilege('authenticated', 'public.edges', 'SELECT'), 'authenticated non legge anche le tabelle dello schema iniziale (edges)');
select ok(has_table_privilege('service_role', 'public.nodes', 'SELECT'), 'service_role legge nodes');
select ok(not (select prosecdef from pg_proc where proname = 'backup_snapshot'), 'backup_snapshot non è security definer');

set local role service_role;
create temp table t (k text primary key, v jsonb) on commit drop;

-- Rifiuti con codici fissi, senza il testo dell'errore del database.
insert into t values ('rej', public.sync_push('ipad-a', $$[
  {"entity":"node","base_version":null,"data":{"id":"50000000-0000-4000-8000-000000000001","type":"health","title":"x","area":"studio"}},
  {"entity":"edge","base_version":null,"data":{"id":"50000000-0000-4000-8000-000000000101","source_id":"50000000-0000-4000-8000-000000000999","target_id":"50000000-0000-4000-8000-000000000998","kind":"manual"}},
  {"entity":"node","base_version":null,"data":{"id":"50000000-0000-4000-8000-000000000002","type":"concept","title":"x","area":"studio","created_at":"1970-01-01T00:00:00Z"}},
  {"entity":"ink_page","base_version":null,"data":{"id":"50000000-0000-4000-8000-000000000201","node_id":"50000000-0000-4000-8000-000000000002","page_no":0,"background":"blank","ink_data":"QUFB","created_at":"2999-01-01T00:00:00Z"}},
  {"entity":"nope","base_version":null,"data":{"id":"50000000-0000-4000-8000-000000000003"}}
]$$));
select is(
  (select array_agg(r->>'message' order by ord) from t, jsonb_array_elements(v->'results') with ordinality as x(r, ord) where k = 'rej'),
  array['forbidden_type', 'missing_parent', null, null, 'invalid'], 'codici di rifiuto fissi');
select ok(not exists (select 1 from t, jsonb_array_elements(v->'results') r where k = 'rej' and r->>'message' ~* 'violates|check constraint|violazione'),
  'nessun testo dell''errore di Postgres nella risposta');

-- Date: il server clampa created_at.
select is((select created_at from public.nodes where id = '50000000-0000-4000-8000-000000000002'), timestamptz '2000-01-01', 'created_at retrodatato riportato al 2000');
select ok((select created_at from public.ink_pages where id = '50000000-0000-4000-8000-000000000201') <= now(), 'created_at nel futuro riportato a ora');

-- device_id non valido.
select throws_ok($$select public.sync_push('../etc', '[]')$$, '22023', null, 'device_id con caratteri non ammessi rifiutato');
select throws_ok($$select public.sync_push(repeat('a', 65), '[]')$$, '22023', null, 'device_id oltre 64 caratteri rifiutato');

-- Allegati: download e pulizia dei file orfani.
select is(public.attachment_download_allowed('50000000-0000-4000-8000-0000000000aa'), false, 'nessun download senza riga');
select is(public.attachments_without_row(array['50000000-0000-4000-8000-0000000000aa']::uuid[]), '["50000000-0000-4000-8000-0000000000aa"]'::jsonb, 'id senza riga trovato');

-- I file in coda per la cancellazione non sono orfani; un lotto fallito sale di un tentativo.
insert into public.storage_trash (path, part_count, queued_at) values ('50000000-0000-4000-8000-0000000000bb', 1, now() - interval '20 days');
select is(public.attachments_without_row(array['50000000-0000-4000-8000-0000000000bb']::uuid[]), '[]'::jsonb, 'un file in coda non è orfano');
select public.storage_trash_failed(array['50000000-0000-4000-8000-0000000000bb']);
select is((select attempts from public.storage_trash where path = '50000000-0000-4000-8000-0000000000bb'), 1, 'tentativo registrato');
update public.storage_trash set attempts = 20 where path = '50000000-0000-4000-8000-0000000000bb';
select is(public.storage_trash_list(10, interval '15 days'), '[]'::jsonb, 'oltre 20 tentativi non si riprova più');

-- Cestino: se oltre la metà dei nodi sarebbe eliminata, non si elimina niente.
insert into public.nodes (id, type, title, area, device_id, deleted_at)
  select gen_random_uuid(), 'idea', 'n' || g, 'interessi', 'test', now() - interval '40 days' from generate_series(1, 60) g;
select is(public.purge_trash(), 0, 'purge_trash fermato dalla guardia');
select is((select count(*)::int from public.nodes where title like 'n%' and device_id = 'test'), 60, 'nessun nodo eliminato dalla guardia');

select * from finish();
rollback;
