begin;
select plan(20);

select ok(not has_table_privilege('anon', 'public.ink_pages', 'SELECT'), 'anon non legge ink_pages');
select ok(not has_function_privilege('authenticated', 'public.sync_apply_ink(text, integer, jsonb)', 'EXECUTE'), 'authenticated non esegue sync_apply_ink');

set local role service_role;

create temp table t (k text primary key, v jsonb) on commit drop;
insert into t values ('c0', to_jsonb((public.sync_pull(0, 1000))->'cursor'));

select public.sync_push('ipad-a', $$[
  {"entity":"node","base_version":null,"data":{"id":"20000000-0000-4000-8000-000000000001","type":"concept","title":"Appunti","area":"studio"}}
]$$);

-- Creazione: i byte arrivano in base64 e tornano uguali.
insert into t values ('create', public.sync_push('ipad-a', $$[
  {"entity":"ink_page","base_version":null,"data":{"id":"20000000-0000-4000-8000-000000000101","node_id":"20000000-0000-4000-8000-000000000001","page_no":0,"background":"grid","ink_data":"AAECAwQ="}}
]$$));
select is((select v #>> '{results,0,status}' from t where k = 'create'), 'created', 'pagina creata');
select is((select encode(ink_data, 'hex') from public.ink_pages where id = '20000000-0000-4000-8000-000000000101'), '0001020304', 'byte del disegno salvati');
select is((select v #>> '{results,0,record,ink_data}' from t where k = 'create'), 'AAECAwQ=', 'byte restituiti in base64');
select is((select v #>> '{results,0,record,background}' from t where k = 'create'), 'grid', 'sfondo a quadretti');

-- Pull da un altro dispositivo.
select ok(
  (select public.sync_pull((v #>> '{}')::bigint, 100)->'changes'
     @> '[{"entity":"ink_page","data":{"id":"20000000-0000-4000-8000-000000000101","ink_data":"AAECAwQ=","page_no":0}}]'
   from t where k = 'c0'),
  'la pagina arriva con il pull');

-- Aggiornamento normale.
select is(
  public.sync_push('ipad-a', $$[{"entity":"ink_page","base_version":1,"data":{"id":"20000000-0000-4000-8000-000000000101","node_id":"20000000-0000-4000-8000-000000000001","page_no":0,"background":"lines","ink_data":"BQY="}}]$$)
    #>> '{results,0,status}',
  'updated', 'aggiornamento con versione corrente');

-- Conflitto: A e B disegnano sulla versione 2.
select public.sync_push('ipad-a', $$[{"entity":"ink_page","base_version":2,"data":{"id":"20000000-0000-4000-8000-000000000101","node_id":"20000000-0000-4000-8000-000000000001","page_no":0,"background":"lines","ink_data":"QUFB"}}]$$);
insert into t values ('conflict', public.sync_push('ipad-b', $$[
  {"entity":"ink_page","base_version":2,"data":{"id":"20000000-0000-4000-8000-000000000101","node_id":"20000000-0000-4000-8000-000000000001","page_no":0,"background":"blank","ink_data":"QkJC"}}
]$$));
select is((select v #>> '{results,0,status}' from t where k = 'conflict'), 'merged', 'conflitto sul disegno');
select is((select encode(ink_data, 'escape') from public.ink_pages where id = '20000000-0000-4000-8000-000000000101'), 'AAA', 'la pagina del server resta com''è');
select ok((select v #>> '{results,0,copy_id}' from t where k = 'conflict') is not null, 'il disegno del client diventa una nuova pagina');
select is(
  (select array[encode(ink_data, 'escape'), page_no::text, background, device_id] from public.ink_pages
    where id = (select (v #>> '{results,0,copy_id}')::uuid from t where k = 'conflict')),
  array['BBB', '1', 'blank', 'ipad-b'], 'la copia contiene il disegno di B in fondo al nodo');

-- Conflitto apparente: stessi byte, nessuna copia.
select ok(
  public.sync_push('ipad-b', $$[{"entity":"ink_page","base_version":1,"data":{"id":"20000000-0000-4000-8000-000000000101","node_id":"20000000-0000-4000-8000-000000000001","page_no":0,"background":"lines","ink_data":"QUFB"}}]$$)
    #> '{results,0}' ? 'copy_id' = false,
  'stessi tratti: nessuna copia');

-- Eliminata sul server, modificata sul client: vince la modifica.
select public.sync_push('ipad-a', $$[{"entity":"ink_page","base_version":4,"data":{"id":"20000000-0000-4000-8000-000000000101","node_id":"20000000-0000-4000-8000-000000000001","page_no":0,"background":"lines","ink_data":"QUFB","deleted_at":"2026-10-01T00:00:00Z"}}]$$);
select is(
  public.sync_push('ipad-b', $$[{"entity":"ink_page","base_version":3,"data":{"id":"20000000-0000-4000-8000-000000000101","node_id":"20000000-0000-4000-8000-000000000001","page_no":0,"background":"lines","ink_data":"Q0ND"}}]$$)
    #>> '{results,0,record,deleted_at}',
  null, 'una modifica ripristina la pagina eliminata');

-- Limiti e privacy.
select is(
  public.sync_push('ipad-a', $$[{"entity":"ink_page","base_version":null,"data":{"id":"20000000-0000-4000-8000-000000000102","node_id":"20000000-0000-4000-8000-000000000999","page_no":0,"ink_data":""}}]$$)
    #>> '{results,0,status}',
  'rejected', 'pagina di un nodo assente (per esempio di salute) rifiutata');
select throws_ok(
  $$insert into public.ink_pages (id, node_id, page_no, ink_data, device_id)
    values (gen_random_uuid(), '20000000-0000-4000-8000-000000000001', 9, decode(repeat('00', 2000001), 'hex'), 'x')$$,
  '23514', null, 'pagina oltre 2 MB rifiutata');

-- Pull limitato in byte: due pagine da 1,5 MB non stanno nella stessa risposta.
insert into t select 'big0', to_jsonb((public.sync_pull(0, 1000))->'cursor');
select public.sync_push('ipad-a', format($$[
  {"entity":"ink_page","base_version":null,"data":{"id":"20000000-0000-4000-8000-000000000201","node_id":"20000000-0000-4000-8000-000000000001","page_no":5,"ink_data":"%1$s"}},
  {"entity":"ink_page","base_version":null,"data":{"id":"20000000-0000-4000-8000-000000000202","node_id":"20000000-0000-4000-8000-000000000001","page_no":6,"ink_data":"%1$s"}}
]$$, translate(encode(decode(repeat('41', 1500000), 'hex'), 'base64'), E'\n', ''))::jsonb);
insert into t select 'bigpull', public.sync_pull((v #>> '{}')::bigint, 100) from t where k = 'big0';
select is((select jsonb_array_length(v->'changes') from t where k = 'bigpull'), 1, 'una sola pagina grande per risposta');
select is((select v->>'has_more' from t where k = 'bigpull'), 'true', 'la seconda arriva alla pagina successiva');

-- Cestino: la pagina segue il nodo.
select public.sync_push('ipad-a', $$[{"entity":"node","base_version":1,"data":{"id":"20000000-0000-4000-8000-000000000001","type":"concept","title":"Appunti","area":"studio","deleted_at":"2020-01-01T00:00:00Z"}}]$$);
insert into t select 'beforePurge', to_jsonb((public.sync_pull(0, 1000))->'cursor');
select public.purge_trash();
select is((select count(*)::int from public.ink_pages where node_id = '20000000-0000-4000-8000-000000000001'), 0, 'pagine eliminate con il nodo');
select ok(
  (select public.sync_pull((v #>> '{}')::bigint, 100)->'changes'
     @> '[{"entity":"purged","data":{"entity":"ink_page","id":"20000000-0000-4000-8000-000000000101"}}]'
   from t where k = 'beforePurge'),
  'le eliminazioni definitive delle pagine arrivano con il pull');

select * from finish();
rollback;
