begin;
select plan(13);

set local role service_role;
create temp table t (k text primary key, v jsonb) on commit drop;

-- Un push ripetuto (risposta persa) non crea versioni né conflitti finti.
select public.sync_push('ipad-a', $$[{"entity":"node","base_version":null,"data":{"id":"80000000-0000-4000-8000-000000000001","type":"concept","title":"Uno","body_md":"x","area":"studio","tags":["a","b"]}}]$$);
insert into t values ('first', public.sync_push('ipad-a', $$[{"entity":"node","base_version":1,"data":{"id":"80000000-0000-4000-8000-000000000001","type":"concept","title":"Uno","body_md":"x2","area":"studio","tags":["a"]}}]$$));
insert into t values ('retry', public.sync_push('ipad-a', $$[{"entity":"node","base_version":1,"data":{"id":"80000000-0000-4000-8000-000000000001","type":"concept","title":"Uno","body_md":"x2","area":"studio","tags":["a"]}}]$$));
select is((select v #>> '{results,0,status}' from t where k = 'retry'), 'updated', 'il push ripetuto non è un conflitto');
select is((select v #>> '{results,0,record,version}' from t where k = 'retry'), '2', 'e non alza la versione');
select is((select count(*)::int from public.node_versions where node_id = '80000000-0000-4000-8000-000000000001'), 2, 'né aggiunge storico');

-- Tag a tre vie: una rimozione non torna con l'unione, un'aggiunta si tiene.
insert into t values ('tags', public.sync_push('ipad-b', $$[{"entity":"node","base_version":1,"data":{"id":"80000000-0000-4000-8000-000000000001","type":"concept","title":"Uno","body_md":"x","area":"studio","tags":["a","b","c"]}}]$$));
select is((select v #>> '{results,0,status}' from t where k = 'tags'), 'merged', 'conflitto sui tag');
select is((select tags from public.nodes where id = '80000000-0000-4000-8000-000000000001'), array['a','c'], 'il tag tolto da A non ritorna, il tag aggiunto da B resta');
select is((select body_md from public.nodes where id = '80000000-0000-4000-8000-000000000001'), 'x2', 'il corpo di A vince su un corpo di B rimasto alla base');

-- La base è l'ultima versione dello storico fino a quella del client, anche se quella esatta non ha una riga.
select public.sync_push('ipad-a', $$[{"entity":"node","base_version":null,"data":{"id":"80000000-0000-4000-8000-000000000002","type":"concept","title":"Due","body_md":"x","area":"studio"}}]$$);
select public.sync_push('ipad-a', $$[{"entity":"node","base_version":1,"data":{"id":"80000000-0000-4000-8000-000000000002","type":"concept","title":"Solo titolo","body_md":"x","area":"studio"}}]$$);
select public.sync_push('ipad-a', $$[{"entity":"node","base_version":2,"data":{"id":"80000000-0000-4000-8000-000000000002","type":"concept","title":"Solo titolo","body_md":"y","area":"studio"}}]$$);
select public.sync_push('ipad-b', $$[{"entity":"node","base_version":2,"data":{"id":"80000000-0000-4000-8000-000000000002","type":"concept","title":"Titolo di B","body_md":"x","area":"studio"}}]$$);
select is((select body_md from public.nodes where id = '80000000-0000-4000-8000-000000000002'), 'y', 'base trovata nello storico: nessun segnaposto di conflitto');
select is((select title from public.nodes where id = '80000000-0000-4000-8000-000000000002'), 'Titolo di B', 'e il titolo di B vince');

-- Corpi modificati da tutti e due: restano tutti e due, con il device validato.
select public.sync_push('ipad-a', $$[{"entity":"node","base_version":3,"data":{"id":"80000000-0000-4000-8000-000000000002","type":"concept","title":"Titolo di B","body_md":"da A","area":"studio"}}]$$);
select public.sync_push('ipad-b', $$[{"entity":"node","base_version":3,"data":{"id":"80000000-0000-4000-8000-000000000002","type":"concept","title":"Titolo di B","body_md":"da B","area":"studio"}}]$$);
select ok((select body_md from public.nodes where id = '80000000-0000-4000-8000-000000000002') like '%da A%conflitto: versione da ipad-b%da B%', 'conflitto sui corpi: entrambi restano');
select throws_ok($$select public.merge_bodies('a', 'b', 'c', 'x --> <script>')$$, '22023', null, 'il device_id non può chiudere il commento');
select throws_ok($$select public.merge_bodies('a', 'b', 'c', null)$$, '22023', null, 'né essere nullo');
select is(public.merge_bodies('a', 'a', 'c', 'ipad-a'), 'c', 'senza conflitto il resto non cambia');

-- Archi: il push ripetuto non alza la versione.
select public.sync_push('ipad-a', $$[{"entity":"edge","base_version":null,"data":{"id":"80000000-0000-4000-8000-0000000000e1","source_id":"80000000-0000-4000-8000-000000000001","target_id":"80000000-0000-4000-8000-000000000002","kind":"manual","label":"x"}}]$$);
select public.sync_push('ipad-a', $$[{"entity":"edge","base_version":1,"data":{"id":"80000000-0000-4000-8000-0000000000e1","source_id":"80000000-0000-4000-8000-000000000001","target_id":"80000000-0000-4000-8000-000000000002","kind":"manual","label":"y"}}]$$);
select public.sync_push('ipad-a', $$[{"entity":"edge","base_version":1,"data":{"id":"80000000-0000-4000-8000-0000000000e1","source_id":"80000000-0000-4000-8000-000000000001","target_id":"80000000-0000-4000-8000-000000000002","kind":"manual","label":"y"}}]$$);
select is((select version from public.edges where id = '80000000-0000-4000-8000-0000000000e1'), 2, 'arco: push ripetuto, stessa versione');

select * from finish();
rollback;
