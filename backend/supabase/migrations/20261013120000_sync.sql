-- Sincronizzazione (fase 1, ARCHITETTURA.md sezione 6.5; ADR 0002).
-- Il client usa solo sync_push, sync_pull e purge_trash tramite il Worker,
-- con la chiave segreta. anon e authenticated non hanno accesso.

-- Contatore globale delle modifiche. Il trigger prende un advisory lock prima
-- di nextval: le scritture sulle tabelle sincronizzate sono serializzate, quindi
-- l'ordine di server_seq coincide con l'ordine di commit e il pull per cursore
-- non salta righe.
create sequence sync_seq;

alter table nodes add column server_seq bigint;
alter table edges add column server_seq bigint;
alter table node_versions add column server_seq bigint;

-- Righe eliminate definitivamente dal cestino: i client le rimuovono al pull.
create table purged (
  entity text not null check (entity in ('node','edge')),
  id uuid not null,
  purged_at timestamptz not null default now(),
  server_seq bigint,
  primary key (entity, id)
);
alter table purged enable row level security;

create function sync_stamp() returns trigger
language plpgsql set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtext('pitchstone_sync'));
  new.server_seq := nextval('public.sync_seq');
  if tg_table_name = 'nodes' then
    new.updated_at := now();
  end if;
  return new;
end;
$$;

create trigger nodes_sync_stamp before insert or update on nodes
  for each row execute function sync_stamp();
create trigger edges_sync_stamp before insert or update on edges
  for each row execute function sync_stamp();
create trigger node_versions_sync_stamp before insert or update on node_versions
  for each row execute function sync_stamp();
create trigger purged_sync_stamp before insert or update on purged
  for each row execute function sync_stamp();

update nodes set server_seq = server_seq;
update edges set server_seq = server_seq;
update node_versions set server_seq = server_seq;

alter table nodes alter column server_seq set not null;
alter table edges alter column server_seq set not null;
alter table node_versions alter column server_seq set not null;
alter table purged alter column server_seq set not null;

create index nodes_server_seq on nodes (server_seq);
create index edges_server_seq on edges (server_seq);
create index node_versions_server_seq on node_versions (server_seq);
create index purged_server_seq on purged (server_seq);
create index edges_source_id on edges (source_id);
create index edges_target_id on edges (target_id);
create index nodes_deleted_at on nodes (deleted_at) where deleted_at is not null;
create index edges_deleted_at on edges (deleted_at) where deleted_at is not null;

-- Unione di due corpi in conflitto: nessuna modifica va persa.
create function merge_bodies(server_body text, client_body text, client_device text)
returns text language sql immutable set search_path = '' as $$
  select case
    when server_body = client_body then server_body
    when server_body = '' then client_body
    when client_body = '' then server_body
    else server_body || E'\n\n---\n\n<!-- conflitto: versione da ' || client_device || E' -->\n\n' || client_body
  end;
$$;

-- Applica una modifica di nodo. Ritorna l'esito per la risposta al client.
create function sync_apply_node(p_device text, p_base integer, d jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare
  cur public.nodes;
  res public.nodes;
  outcome text;
  new_body text;
  new_deleted timestamptz;
begin
  select * into cur from public.nodes where id = (d->>'id')::uuid for update;

  if not found then
    insert into public.nodes (id, type, title, body_md, area, tags, version, created_at, deleted_at, device_id)
    values (
      (d->>'id')::uuid, d->>'type', d->>'title', coalesce(d->>'body_md', ''), d->>'area',
      coalesce(array(select jsonb_array_elements_text(d->'tags')), '{}'),
      1, coalesce((d->>'created_at')::timestamptz, now()), (d->>'deleted_at')::timestamptz, p_device)
    returning * into res;
    outcome := 'created';
  elsif p_base is not null and p_base = cur.version then
    update public.nodes set
      type = d->>'type', title = d->>'title', body_md = coalesce(d->>'body_md', ''),
      area = d->>'area', tags = coalesce(array(select jsonb_array_elements_text(d->'tags')), '{}'),
      deleted_at = (d->>'deleted_at')::timestamptz, device_id = p_device, version = cur.version + 1
    where id = cur.id returning * into res;
    outcome := 'updated';
  else
    -- Conflitto: il client ha modificato una versione superata.
    -- Corpo unito, tag uniti, titolo e tipo del client, eliminato solo se entrambi eliminano.
    new_body := public.merge_bodies(cur.body_md, coalesce(d->>'body_md', ''), p_device);
    new_deleted := case
      when cur.deleted_at is not null and (d->>'deleted_at') is not null
        then greatest(cur.deleted_at, (d->>'deleted_at')::timestamptz)
      else null end;
    update public.nodes set
      type = d->>'type', title = d->>'title', body_md = new_body, area = d->>'area',
      tags = array(select distinct t from unnest(cur.tags || coalesce(array(select jsonb_array_elements_text(d->'tags')), '{}')) t order by t),
      deleted_at = new_deleted, device_id = p_device, version = cur.version + 1
    where id = cur.id returning * into res;
    outcome := 'merged';
  end if;

  if cur.id is null or cur.body_md is distinct from res.body_md then
    insert into public.node_versions (id, node_id, version, body_md, device_id)
    values (gen_random_uuid(), res.id, res.version, res.body_md, p_device);
  end if;

  delete from public.purged where entity = 'node' and id = res.id;
  return jsonb_build_object('status', outcome, 'record', to_jsonb(res));
end;
$$;

create function sync_apply_edge(p_base integer, d jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare
  cur public.edges;
  res public.edges;
  outcome text;
begin
  select * into cur from public.edges where id = (d->>'id')::uuid for update;

  if not found then
    insert into public.edges (id, source_id, target_id, kind, label, version, created_at, deleted_at)
    values (
      (d->>'id')::uuid, (d->>'source_id')::uuid, (d->>'target_id')::uuid, d->>'kind', d->>'label',
      1, coalesce((d->>'created_at')::timestamptz, now()), (d->>'deleted_at')::timestamptz)
    returning * into res;
    outcome := 'created';
  elsif p_base is not null and p_base = cur.version then
    update public.edges set
      kind = d->>'kind', label = d->>'label', deleted_at = (d->>'deleted_at')::timestamptz,
      version = cur.version + 1
    where id = cur.id returning * into res;
    outcome := 'updated';
  else
    -- Conflitto sugli archi: vince il client, eliminato solo se entrambi eliminano.
    update public.edges set
      kind = d->>'kind', label = d->>'label',
      deleted_at = case
        when cur.deleted_at is not null and (d->>'deleted_at') is not null
          then greatest(cur.deleted_at, (d->>'deleted_at')::timestamptz)
        else null end,
      version = cur.version + 1
    where id = cur.id returning * into res;
    outcome := 'merged';
  end if;

  delete from public.purged where entity = 'edge' and id = res.id;
  return jsonb_build_object('status', outcome, 'record', to_jsonb(res));
end;
$$;

-- Push: applica le modifiche in ordine, ognuna in un proprio savepoint.
-- Una modifica non valida viene rifiutata senza bloccare le altre.
-- Formato: [{"entity":"node"|"edge","base_version":int|null,"data":{...}}]
create function sync_push(p_device_id text, p_changes jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare
  ch jsonb;
  outcome jsonb;
  results jsonb := '[]'::jsonb;
  entity text;
begin
  if p_device_id is null or length(p_device_id) = 0 or length(p_device_id) > 100 then
    raise exception 'device_id non valido' using errcode = '22023';
  end if;
  if jsonb_typeof(p_changes) is distinct from 'array' then
    raise exception 'changes deve essere un array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_changes) > 500 then
    raise exception 'troppe modifiche in un push (max 500)' using errcode = '22023';
  end if;

  for ch in select value from jsonb_array_elements(p_changes) loop
    entity := ch->>'entity';
    begin
      if jsonb_typeof(ch->'data') is distinct from 'object' or (ch->'data'->>'id') is null then
        raise exception 'data.id mancante' using errcode = '22023';
      end if;
      if entity = 'node' then
        outcome := public.sync_apply_node(p_device_id, (ch->>'base_version')::integer, ch->'data');
      elsif entity = 'edge' then
        outcome := public.sync_apply_edge((ch->>'base_version')::integer, ch->'data');
      else
        raise exception 'entity non valida: %', entity using errcode = '22023';
      end if;
      results := results || jsonb_build_array(
        outcome || jsonb_build_object('entity', entity, 'id', ch->'data'->>'id'));
    exception when others then
      results := results || jsonb_build_array(jsonb_build_object(
        'entity', entity, 'id', ch->'data'->>'id', 'status', 'rejected',
        'error', sqlstate, 'message', sqlerrm));
    end;
  end loop;

  return jsonb_build_object('results', results);
end;
$$;

-- Pull incrementale: righe con server_seq > cursore, in ordine, a pagine.
create function sync_pull(p_cursor bigint, p_limit integer default 500)
returns jsonb language sql stable set search_path = '' as $$
  with changes as (
    select * from (
      select 'node' as entity, n.server_seq, to_jsonb(n) as data from public.nodes n where n.server_seq > p_cursor
      union all
      select 'edge', e.server_seq, to_jsonb(e) from public.edges e where e.server_seq > p_cursor
      union all
      select 'node_version', v.server_seq, to_jsonb(v) from public.node_versions v where v.server_seq > p_cursor
      union all
      select 'purged', p.server_seq, to_jsonb(p) from public.purged p where p.server_seq > p_cursor
    ) c
    order by server_seq
    limit greatest(1, least(coalesce(p_limit, 500), 1000)) + 1
  ), page as (
    select * from changes order by server_seq limit greatest(1, least(coalesce(p_limit, 500), 1000))
  )
  select jsonb_build_object(
    'changes', coalesce((select jsonb_agg(jsonb_build_object('entity', entity, 'data', data) order by server_seq) from page), '[]'),
    'cursor', coalesce((select max(server_seq) from page), p_cursor),
    'has_more', (select count(*) from changes) > (select count(*) from page)
  );
$$;

-- Cestino: elimina definitivamente ciò che è nel cestino da più di 30 giorni.
create function purge_trash(p_older_than interval default interval '30 days')
returns integer language plpgsql set search_path = '' as $$
declare
  n integer;
  cutoff timestamptz := now() - p_older_than;
begin
  with gone as (
    -- Gli archi che toccano un nodo eliminato vengono rimossi in cascata.
    select id from public.edges
    where deleted_at < cutoff
       or source_id in (select id from public.nodes where deleted_at < cutoff)
       or target_id in (select id from public.nodes where deleted_at < cutoff)
  )
  insert into public.purged (entity, id)
  select 'edge', id from gone
  on conflict (entity, id) do update set purged_at = now();

  insert into public.purged (entity, id)
  select 'node', id from public.nodes where deleted_at < cutoff
  on conflict (entity, id) do update set purged_at = now();

  delete from public.edges e using public.purged p
    where p.entity = 'edge' and p.id = e.id;
  delete from public.nodes n using public.purged p
    where p.entity = 'node' and p.id = n.id;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Solo la chiave segreta (service_role) usa la sync. Le funzioni nascono
-- eseguibili da public: il privilegio va tolto esplicitamente.
revoke all on sequence sync_seq from public, anon, authenticated;
revoke all on table purged from public, anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function sync_push(text, jsonb), sync_pull(bigint, integer), purge_trash(interval) to service_role;

-- Pulizia giornaliera del cestino alle 03:00 UTC.
create extension if not exists pg_cron;
select cron.schedule('purge-trash', '0 3 * * *', $$select public.purge_trash()$$);
