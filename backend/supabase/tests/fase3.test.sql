begin;
select plan(12);

select ok(not has_function_privilege('authenticated', 'public.account_erase(text)', 'EXECUTE'), 'authenticated non cancella tutto');
select ok(not has_function_privilege('anon', 'public.export_rows(text, uuid, integer, integer)', 'EXECUTE'), 'anon non esporta');

set local role service_role;

select public.sync_push('ipad-a', $$[
  {"entity":"node","base_version":null,"data":{"id":"70000000-0000-4000-8000-000000000001","type":"concept","title":"Uno","body_md":"v1","area":"studio"}},
  {"entity":"node","base_version":null,"data":{"id":"70000000-0000-4000-8000-000000000002","type":"idea","title":"Cestinato","area":"interessi"}},
  {"entity":"edge","base_version":null,"data":{"id":"70000000-0000-4000-8000-0000000000e1","source_id":"70000000-0000-4000-8000-000000000001","target_id":"70000000-0000-4000-8000-000000000002","kind":"manual"}},
  {"entity":"ink_page","base_version":null,"data":{"id":"70000000-0000-4000-8000-0000000000a1","node_id":"70000000-0000-4000-8000-000000000001","page_no":0,"background":"grid","ink_data":"QUJDRA=="}},
  {"entity":"attachment","base_version":null,"data":{"id":"70000000-0000-4000-8000-0000000000b1","node_id":null,"kind":"pdf","storage_path":"70000000-0000-4000-8000-0000000000b1","size_bytes":10,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","file_name":"x.pdf","part_count":2}}
]$$);
select public.sync_push('ipad-a', $$[{"entity":"node","base_version":1,"data":{"id":"70000000-0000-4000-8000-000000000002","type":"idea","title":"Cestinato","area":"interessi","deleted_at":"2026-01-01T00:00:00Z"}}]$$);

-- L'esportazione comprende anche il cestino, lo storico e i disegni.
select ok((select jsonb_path_exists(public.export_rows('nodes', null, 1000)->'rows', '$[*] ? (@.id == "70000000-0000-4000-8000-000000000002")')), 'il nodo nel cestino è esportato');
select ok((select jsonb_array_length(public.export_rows('node_versions', null, 1000)->'rows') >= 2), 'lo storico è esportato');
select is(public.export_rows('ink_pages', null, 10)->'rows'->0->>'ink_data', 'QUJDRA==', 'i disegni sono esportati in base64');
select is(public.export_rows('attachments', null, 10)->'rows'->0->>'file_name', 'x.pdf', 'i metadati degli allegati sono esportati');
select throws_ok($$select public.export_rows('chats', null, 10)$$, '22023', null, 'tabella non valida');

-- Cancella tutto.
select throws_ok($$select public.account_erase('no')$$, '22023', null, 'serve la conferma');
select is((select count(*)::int from public.nodes) > 0, true, 'senza conferma non si cancella niente');
create temp table erased as select public.account_erase('cancella-tutto') as r;
select is((select count(*)::int from public.nodes) + (select count(*)::int from public.edges) + (select count(*)::int from public.ink_pages)
  + (select count(*)::int from public.attachments) + (select count(*)::int from public.node_versions) + (select count(*)::int from public.purged), 0, 'tutte le tabelle sono vuote');
select is((select r->>'epoch' from erased), '2', 'nuova epoca');
select is((select count(*)::int from public.storage_trash where path = '70000000-0000-4000-8000-0000000000b1'
  and queued_at < now() - interval '50 years'), 1, 'i file degli allegati sono in coda, da cancellare subito');

select * from finish();
rollback;
