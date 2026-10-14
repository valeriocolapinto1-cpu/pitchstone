begin;
select plan(8);

select ok(not has_function_privilege('anon', 'public.backup_snapshot()', 'EXECUTE'), 'anon non fa backup');
select ok(not has_function_privilege('authenticated', 'public.backup_snapshot()', 'EXECUTE'), 'authenticated non fa backup');
select ok((select not public from storage.buckets where id = 'backups'), 'bucket backups privato');

set local role service_role;

select public.sync_push('ipad-a', $$[
  {"entity":"node","base_version":null,"data":{"id":"40000000-0000-4000-8000-000000000001","type":"concept","title":"Derivata","area":"studio"}},
  {"entity":"node","base_version":null,"data":{"id":"40000000-0000-4000-8000-000000000002","type":"exam","title":"Analisi 1","area":"studio","tags":["data:2027-01-20"]}},
  {"entity":"edge","base_version":null,"data":{"id":"40000000-0000-4000-8000-0000000000e1","source_id":"40000000-0000-4000-8000-000000000001","target_id":"40000000-0000-4000-8000-000000000002","kind":"manual"}},
  {"entity":"node","base_version":null,"data":{"id":"40000000-0000-4000-8000-000000000003","type":"health","title":"Diario","area":"salute"}}
]$$);

create temp table snap on commit drop as select public.backup_snapshot() as s;

select is((select s->>'format' from snap), 'pitchstone-backup', 'formato riconoscibile');
select ok((select jsonb_path_exists(s, '$.nodes[*] ? (@.id == "40000000-0000-4000-8000-000000000001")') from snap), 'il nodo di studio c''è');
select is((select jsonb_array_length(s->'edges') >= 1 from snap), true, 'gli archi ci sono');
select ok(not (select jsonb_path_exists(s, '$.nodes[*] ? (@.type == "health" || @.area == "salute")') from snap), 'nessun nodo di salute');
select ok(not (select s::text like '%Diario%' from snap), 'il testo del nodo di salute non c''è');

select * from finish();
rollback;
