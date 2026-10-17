begin;
select plan(37);

-- Privilegi: solo service_role usa la sync.
select ok(not has_function_privilege('anon', 'public.sync_push(text, jsonb)', 'EXECUTE'), 'anon non esegue sync_push');
select ok(not has_function_privilege('anon', 'public.sync_pull(bigint, integer)', 'EXECUTE'), 'anon non esegue sync_pull');
select ok(not has_function_privilege('authenticated', 'public.sync_push(text, jsonb)', 'EXECUTE'), 'authenticated non esegue sync_push');
select ok(not has_function_privilege('authenticated', 'public.purge_trash(interval)', 'EXECUTE'), 'authenticated non esegue purge_trash');
select ok(not has_table_privilege('anon', 'public.purged', 'SELECT'), 'anon non legge purged');
select ok(has_function_privilege('service_role', 'public.sync_push(text, jsonb)', 'EXECUTE'), 'service_role esegue sync_push');

set local role service_role;

-- Cursore di partenza: tutto ciò che esiste già (seed).
create temp table t (k text primary key, v jsonb) on commit drop;
insert into t values ('c0', to_jsonb((public.sync_pull(0, 1000))->'cursor'));

-- Dispositivo A crea un nodo.
insert into t values ('push1', public.sync_push('ipad-a', $$[
  {"entity":"node","base_version":null,"data":{"id":"10000000-0000-4000-8000-000000000001","type":"concept","title":"Limite","body_md":"v1","area":"studio","tags":["analisi"]}}
]$$));
select is((select v->'results'->0->>'status' from t where k = 'push1'), 'created', 'nodo creato');
select is((select v->'results'->0->'record'->>'version' from t where k = 'push1'), '1', 'versione 1');
select is((select count(*)::int from public.node_versions where node_id = '10000000-0000-4000-8000-000000000001'), 1, 'una riga di storico');

-- Dispositivo B fa pull dal cursore precedente e vede il nodo.
insert into t select 'pullB', public.sync_pull((select (v #>> '{}')::bigint from t where k = 'c0'), 100);
select ok(
  (select v->'changes' @> '[{"entity":"node","data":{"id":"10000000-0000-4000-8000-000000000001","title":"Limite"}}]' from t where k = 'pullB'),
  'il nodo creato su A compare su B');
select ok(
  (select v->'changes' @> '[{"entity":"node_version","data":{"node_id":"10000000-0000-4000-8000-000000000001","version":1}}]' from t where k = 'pullB'),
  'lo storico arriva con il pull');
select is((select v->>'has_more' from t where k = 'pullB'), 'false', 'nessuna altra pagina');

-- Pull dal cursore restituito: niente di nuovo.
select is(
  (select jsonb_array_length(public.sync_pull((v->>'cursor')::bigint, 100)->'changes') from t where k = 'pullB'),
  0, 'pull successivo vuoto');

-- B modifica partendo dalla versione 1: aggiornamento normale.
select is(
  public.sync_push('ipad-b', $$[{"entity":"node","base_version":1,"data":{"id":"10000000-0000-4000-8000-000000000001","type":"concept","title":"Limite","body_md":"v2 da B","area":"studio","tags":["analisi"]}}]$$)
    #>> '{results,0,status}',
  'updated', 'modifica con versione corrente');

-- Conflitto: A e B modificano entrambi la versione 2.
select is(
  public.sync_push('ipad-a', $$[{"entity":"node","base_version":2,"data":{"id":"10000000-0000-4000-8000-000000000001","type":"concept","title":"Limite","body_md":"testo di A","area":"studio","tags":["analisi"]}}]$$)
    #>> '{results,0,status}',
  'updated', 'prima modifica sulla versione 2 accettata');
insert into t values ('conflict', public.sync_push('ipad-b', $$[
  {"entity":"node","base_version":2,"data":{"id":"10000000-0000-4000-8000-000000000001","type":"concept","title":"Limite (B)","body_md":"testo di B","area":"studio","tags":["esame"]}}
]$$));
select is((select v #>> '{results,0,status}' from t where k = 'conflict'), 'merged', 'seconda modifica sulla versione 2 in conflitto');
select is((select version from public.nodes where id = '10000000-0000-4000-8000-000000000001'), 4, 'il conflitto crea una nuova versione');
select ok(
  (select body_md like 'testo di A%' and body_md like '%testo di B' from public.nodes where id = '10000000-0000-4000-8000-000000000001'),
  'il corpo unito contiene entrambe le modifiche');
select is(
  (select tags from public.nodes where id = '10000000-0000-4000-8000-000000000001'),
  array['analisi', 'esame'], 'i tag vengono uniti');
select is(
  (select array_agg(version order by version) from public.node_versions where node_id = '10000000-0000-4000-8000-000000000001'),
  array[1, 2, 3, 4], 'lo storico conserva tutte le versioni');
select is(
  (select body_md from public.node_versions where node_id = '10000000-0000-4000-8000-000000000001' and version = 3),
  'testo di A', 'la versione di A resta nello storico');

-- Merge a tre vie: chi cambia solo il titolo non duplica il corpo.
select public.sync_push('ipad-a', $$[{"entity":"node","base_version":null,"data":{"id":"10000000-0000-4000-8000-000000000005","type":"concept","title":"T","body_md":"base","area":"studio"}}]$$);
select public.sync_push('ipad-a', $$[{"entity":"node","base_version":1,"data":{"id":"10000000-0000-4000-8000-000000000005","type":"concept","title":"T","body_md":"nuovo da A","area":"studio"}}]$$);
select is(
  public.sync_push('ipad-b', $$[{"entity":"node","base_version":1,"data":{"id":"10000000-0000-4000-8000-000000000005","type":"concept","title":"Titolo di B","body_md":"base","area":"studio"}}]$$)
    #>> '{results,0,status}',
  'merged', 'conflitto sul solo titolo');
select is((select body_md from public.nodes where id = '10000000-0000-4000-8000-000000000005'), 'nuovo da A', 'corpo di A senza duplicati');
select is((select title from public.nodes where id = '10000000-0000-4000-8000-000000000005'), 'Titolo di B', 'titolo di B');

-- Cestino contro modifica concorrente: vince la modifica.
select ok(
  (public.sync_push('ipad-a', $$[{"entity":"node","base_version":4,"data":{"id":"10000000-0000-4000-8000-000000000001","type":"concept","title":"Limite","body_md":"x","area":"studio","deleted_at":"2026-10-01T00:00:00Z"}}]$$)
    #>> '{results,0,record,deleted_at}')::timestamptz > now() - interval '1 minute',
  'nodo nel cestino: la data di eliminazione la decide il server, non il client');
select is(
  public.sync_push('ipad-b', $$[{"entity":"node","base_version":4,"data":{"id":"10000000-0000-4000-8000-000000000001","type":"concept","title":"Limite","body_md":"y","area":"studio"}}]$$)
    #>> '{results,0,record,deleted_at}',
  null, 'una modifica concorrente ripristina il nodo');

-- Modifiche non valide: rifiutate una per una, le altre passano.
insert into t values ('mixed', public.sync_push('ipad-a', $$[
  {"entity":"node","base_version":null,"data":{"id":"10000000-0000-4000-8000-000000000002","type":"health","title":"x","area":"studio"}},
  {"entity":"node","base_version":null,"data":{"id":"10000000-0000-4000-8000-000000000003","type":"concept","title":"x","area":"salute"}},
  {"entity":"edge","base_version":null,"data":{"id":"10000000-0000-4000-8000-000000000101","source_id":"10000000-0000-4000-8000-000000000001","target_id":"10000000-0000-4000-8000-000000000999","kind":"manual"}},
  {"entity":"node","base_version":null,"data":{"id":"10000000-0000-4000-8000-000000000004","type":"idea","title":"Ok","area":"interessi"}},
  {"entity":"edge","base_version":null,"data":{"id":"10000000-0000-4000-8000-000000000102","source_id":"10000000-0000-4000-8000-000000000001","target_id":"10000000-0000-4000-8000-000000000004","kind":"manual"}}
]$$));
select is(
  (select array_agg(r->>'status' order by ord) from t, jsonb_array_elements(v->'results') with ordinality as x(r, ord) where k = 'mixed'),
  array['rejected', 'rejected', 'rejected', 'created', 'created'], 'health, salute e archi verso nodi assenti rifiutati');
select is((select count(*)::int from public.nodes where type = 'health' or id = '10000000-0000-4000-8000-000000000002'), 0, 'nessun nodo health sul server');

select throws_ok($$select public.sync_push('', '[]')$$, '22023', null, 'device_id vuoto rifiutato');
select throws_ok($$select public.sync_push('x', '{}')$$, '22023', null, 'changes deve essere un array');

-- Pull a pagine.
insert into t select 'page1', public.sync_pull((select (v #>> '{}')::bigint from t where k = 'c0'), 2);
select is((select jsonb_array_length(v->'changes') from t where k = 'page1'), 2, 'pagina di 2 modifiche');
select is((select v->>'has_more' from t where k = 'page1'), 'true', 'altre pagine disponibili');

-- Cestino: eliminazione definitiva dopo 30 giorni, con gli archi collegati.
select public.sync_push('ipad-a', $$[
  {"entity":"node","base_version":1,"data":{"id":"10000000-0000-4000-8000-000000000004","type":"idea","title":"Ok","area":"interessi","deleted_at":"2020-01-01T00:00:00Z"}}
]$$);
update public.nodes set deleted_at = now() - interval '31 days' where id = '10000000-0000-4000-8000-000000000004';
update public.nodes set deleted_at = now() - interval '29 days' where id = '00000000-0000-4000-8000-000000000003';
insert into t select 'beforePurge', to_jsonb((public.sync_pull(0, 1000))->'cursor');
select ok(public.purge_trash() >= 1, 'eliminazione definitiva eseguita');
select ok(not exists (select 1 from public.nodes where id = '10000000-0000-4000-8000-000000000004'), 'nodo oltre 30 giorni rimosso');
select ok(not exists (select 1 from public.edges where id = '10000000-0000-4000-8000-000000000102'), 'arco collegato rimosso');
select ok(exists (select 1 from public.nodes where id = '00000000-0000-4000-8000-000000000003'), 'nodo nel cestino da 29 giorni conservato');
select ok(
  (select public.sync_pull((v #>> '{}')::bigint, 100)->'changes' @> '[{"entity":"purged","data":{"entity":"node","id":"10000000-0000-4000-8000-000000000004"}},{"entity":"purged","data":{"entity":"edge","id":"10000000-0000-4000-8000-000000000102"}}]' from t where k = 'beforePurge'),
  'le eliminazioni definitive arrivano con il pull');

select * from finish();
rollback;
