begin;
select plan(30);

select ok(not has_function_privilege('authenticated', 'public.backup_rows(text, uuid, integer, integer)', 'EXECUTE'), 'authenticated non legge il backup');
select ok(not has_function_privilege('anon', 'public.backup_restore_wipe(text)', 'EXECUTE'), 'anon non svuota');
select ok(has_function_privilege('service_role', 'public.backup_restore_rows(text, jsonb)', 'EXECUTE'), 'service_role ripristina');
select ok(not has_table_privilege('authenticated', 'public.sync_meta', 'SELECT'), 'authenticated non legge sync_meta');

set local role service_role;
create temp table t (k text primary key, v jsonb) on commit drop;

insert into t values ('pull0', public.sync_pull(0, 10));
select is((select (v->>'epoch')::int from t where k = 'pull0'), 1, 'il pull dichiara l''epoca');

-- Dati: due nodi, un arco, una pagina a penna, un nodo nel cestino, uno storico.
select public.sync_push('ipad-a', $$[
  {"entity":"node","base_version":null,"data":{"id":"60000000-0000-4000-8000-000000000001","type":"concept","title":"Uno","body_md":"v1","area":"studio"}},
  {"entity":"node","base_version":null,"data":{"id":"60000000-0000-4000-8000-000000000002","type":"idea","title":"Due","area":"interessi"}},
  {"entity":"node","base_version":null,"data":{"id":"60000000-0000-4000-8000-000000000003","type":"idea","title":"Cestinato","area":"interessi"}},
  {"entity":"edge","base_version":null,"data":{"id":"60000000-0000-4000-8000-0000000000e1","source_id":"60000000-0000-4000-8000-000000000001","target_id":"60000000-0000-4000-8000-000000000002","kind":"manual"}},
  {"entity":"ink_page","base_version":null,"data":{"id":"60000000-0000-4000-8000-0000000000a1","node_id":"60000000-0000-4000-8000-000000000001","page_no":0,"background":"grid","ink_data":"QUJDRA=="}}
]$$);
select public.sync_push('ipad-a', $$[{"entity":"node","base_version":1,"data":{"id":"60000000-0000-4000-8000-000000000001","type":"concept","title":"Uno","body_md":"v2","area":"studio"}}]$$);
select public.sync_push('ipad-a', $$[{"entity":"node","base_version":1,"data":{"id":"60000000-0000-4000-8000-000000000003","type":"idea","title":"Cestinato","area":"interessi","deleted_at":"2026-01-01T00:00:00Z"}}]$$);

insert into t values ('counts', public.backup_counts());
select is((select (v->>'nodes')::int from t where k = 'counts'), (select count(*)::int from public.nodes where deleted_at is null), 'conteggio dei nodi (senza cestino)');
select is((select (v->>'ink_pages')::int from t where k = 'counts'), 1, 'conteggio delle pagine a penna');
select ok((select (v->>'node_versions')::int >= 3 from t where k = 'counts'), 'lo storico è nel backup');

-- Pagine: una riga alla volta, in ordine di id, senza perdere né ripetere.
create temp table pages (n int, rows jsonb) on commit drop;
do $$
declare
  after uuid := null;
  r jsonb;
  i int := 0;
begin
  loop
    r := public.backup_rows('nodes', after, 1);
    exit when jsonb_array_length(r->'rows') = 0;
    i := i + 1;
    insert into pages values (i, r->'rows');
    after := (r->>'last')::uuid;
    exit when not (r->>'more')::boolean;
  end loop;
end $$;
select is((select count(*)::int from pages), (select (v->>'nodes')::int from t where k = 'counts'), 'una pagina per nodo, tutte lette');
select is((select count(distinct rows->0->>'id')::int from pages), (select count(*)::int from pages), 'nessuna riga ripetuta');
select ok(not exists (select 1 from pages where rows->0->>'id' = '60000000-0000-4000-8000-000000000003'), 'il nodo nel cestino non è nel backup');
select is((select jsonb_array_length(public.backup_rows('ink_pages', null, 10)->'rows')), 1, 'la pagina a penna c''è');
select ok(not (public.backup_rows('ink_pages', null, 10)::text like '%QUJDRA%'), 'senza i byte del disegno');
select is(public.backup_ink_rows(null)->'rows'->0->>'ink_data', 'QUJDRA==', 'i byte del disegno stanno in un file a parte');
select throws_ok($$select public.backup_rows('chats', null, 10)$$, '22023', null, 'tabella non valida');

-- Giro completo: backup, svuota, ripristina.
create temp table saved (tbl text, rows jsonb) on commit drop;
insert into saved select tbl, public.backup_rows(tbl, null, 2000)->'rows'
  from unnest(array['nodes','edges','node_versions','attachments','ink_pages','purged']) tbl;
create temp table saved_ink as select public.backup_ink_rows(null)->'rows' as rows;
create temp table before_counts as select public.backup_counts() as c;
select throws_ok($$select public.backup_restore_wipe('no')$$, '22023', null, 'lo svuotamento chiede conferma');
select public.backup_restore_wipe('cancella-tutto');
select is((select (public.backup_counts()->>'nodes')::int), 0, 'database svuotato');
select public.backup_restore_rows(tbl, rows) from saved order by array_position(array['nodes','edges','node_versions','attachments','ink_pages','purged'], tbl);
select public.backup_restore_ink(rows) from saved_ink;
select is((select public.backup_counts() from (select 1) x), (select c from before_counts), 'dopo il ripristino i conteggi tornano uguali');
select is((select encode(ink_data, 'escape') from public.ink_pages where id = '60000000-0000-4000-8000-0000000000a1'), 'ABCD', 'il disegno è tornato');
select is(public.backup_restore_finish(), 2, 'il ripristino passa all''epoca 2');

-- Conservazione: storico oltre le ultime N versioni e righe purged vecchie.
select ok(public.prune_history(1, interval '-1 second') >= 1, 'prune_history toglie lo storico oltre le ultime versioni');
select is((select count(*)::int from public.node_versions where node_id = '60000000-0000-4000-8000-000000000001'), 1, 'resta l''ultima versione');
select ok(public.prune_purged(interval '-1 second') >= 0, 'prune_purged gira');

-- Una nota che diventa di salute si toglie dal server con ciò che porta.
select is(public.redact_node_history('60000000-0000-4000-8000-000000000001'), '{"removed": true}'::jsonb, 'nota rimossa dal server');
select ok(not exists (select 1 from public.nodes where id = '60000000-0000-4000-8000-000000000001')
  and not exists (select 1 from public.node_versions where node_id = '60000000-0000-4000-8000-000000000001')
  and not exists (select 1 from public.edges where id = '60000000-0000-4000-8000-0000000000e1')
  and not exists (select 1 from public.ink_pages where id = '60000000-0000-4000-8000-0000000000a1'),
  'storico, archi e pagine spariti');
select ok((select public.sync_pull(0, 1000)->'changes' @> '[{"entity":"purged","data":{"entity":"node","id":"60000000-0000-4000-8000-000000000001"}}]'),
  'gli altri dispositivi la tolgono al pull');

-- Stato del backup: età leggibile da anon, senza altro.
select is(public.backup_status()->>'last_backup_at', null, 'nessun backup ancora');
select public.backup_mark_done();
select ok((public.backup_status()->>'age_hours')::numeric < 1, 'backup segnato');
select ok(public.db_size_bytes() > 0, 'dimensione del database');
select ok(has_function_privilege('anon', 'public.backup_status()', 'EXECUTE') and not has_function_privilege('anon', 'public.backup_mark_done()', 'EXECUTE'),
  'anon legge solo backup_status');

select * from finish();
rollback;
