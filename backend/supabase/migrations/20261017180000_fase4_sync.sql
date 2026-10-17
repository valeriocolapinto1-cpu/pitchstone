-- Fase 4 del piano di correzione: correttezza della sincronizzazione.

-- Lo storico ricorda anche i tag: un conflitto sui tag si risolve a tre vie, e una rimozione si propaga
-- invece di tornare con l'unione. Null per le versioni scritte prima.
alter table node_versions add column tags text[];

-- L'unione ha bisogno di un device_id che non possa chiudere il commento del segnaposto di conflitto.
create or replace function merge_bodies(base_body text, server_body text, client_body text, client_device text)
returns text language plpgsql immutable set search_path = '' as $$
begin
  if client_device is null or client_device !~ '^[A-Za-z0-9._-]{1,64}$' then
    raise exception 'device_id non valido' using errcode = '22023';
  end if;
  return case
    when server_body = client_body then server_body
    when client_body = base_body then server_body
    when server_body = base_body then client_body
    when server_body = '' then client_body
    when client_body = '' then server_body
    else server_body || E'\n\n---\n\n<!-- conflitto: versione da ' || client_device || E' -->\n\n' || client_body
  end;
end;
$$;

-- Tag a tre vie: resta ciò che c'era e nessuno ha tolto, più ciò che uno dei due ha aggiunto.
create function merge_tags(p_base text[], p_server text[], p_client text[])
returns text[] language sql immutable set search_path = '' as $$
  select coalesce(array(
    select t from (
      (select unnest(p_base) as t intersect select unnest(p_server) intersect select unnest(p_client))
      union (select unnest(p_server) except select unnest(p_base))
      union (select unnest(p_client) except select unnest(p_base))
    ) merged order by t
  ), '{}');
$$;

create or replace function sync_apply_node(p_device text, p_base integer, d jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare
  cur public.nodes;
  res public.nodes;
  outcome text;
  new_body text;
  new_tags text[];
  new_deleted timestamptz;
  base_body text;
  base_tags text[];
  client_tags text[] := coalesce(array(select jsonb_array_elements_text(d->'tags')), '{}');
begin
  select * into cur from public.nodes where id = (d->>'id')::uuid for update;

  if not found then
    insert into public.nodes (id, type, title, body_md, area, tags, version, created_at, deleted_at, device_id)
    values (
      (d->>'id')::uuid, d->>'type', d->>'title', coalesce(d->>'body_md', ''), d->>'area', client_tags,
      1, coalesce((d->>'created_at')::timestamptz, now()), (d->>'deleted_at')::timestamptz, p_device)
    returning * into res;
    outcome := 'created';
  elsif p_base is not null and p_base = cur.version then
    update public.nodes set
      type = d->>'type', title = d->>'title', body_md = coalesce(d->>'body_md', ''),
      area = d->>'area', tags = client_tags,
      deleted_at = (d->>'deleted_at')::timestamptz, device_id = p_device, version = cur.version + 1
    where id = cur.id returning * into res;
    outcome := 'updated';
  elsif cur.type = d->>'type' and cur.title = d->>'title' and cur.body_md = coalesce(d->>'body_md', '')
        and cur.area = d->>'area'
        and (select array_agg(t order by t) from unnest(cur.tags) t) is not distinct from (select array_agg(t order by t) from unnest(client_tags) t)
        and cur.deleted_at is not distinct from (d->>'deleted_at')::timestamptz then
    -- Lo stesso contenuto già applicato (un push ripetuto perché la risposta era andata persa):
    -- niente nuova versione, niente conflitto finto.
    res := cur;
    outcome := 'updated';
  else
    -- Conflitto: il client ha modificato una versione superata. La base è il corpo (e i tag)
    -- dell'ultima versione dello storico fino a quella del client. Corpo unito, tag a tre vie,
    -- titolo e tipo del client, eliminato solo se entrambi eliminano.
    select v.body_md, v.tags into base_body, base_tags from public.node_versions v
      where v.node_id = cur.id and v.version <= p_base order by v.version desc limit 1;
    new_body := public.merge_bodies(base_body, cur.body_md, coalesce(d->>'body_md', ''), p_device);
    new_tags := case
      when base_tags is null then array(select distinct t from unnest(cur.tags || client_tags) t order by t)
      else public.merge_tags(base_tags, cur.tags, client_tags) end;
    new_deleted := case
      when cur.deleted_at is not null and (d->>'deleted_at') is not null
        then greatest(cur.deleted_at, (d->>'deleted_at')::timestamptz)
      else null end;
    update public.nodes set
      type = d->>'type', title = d->>'title', body_md = new_body, area = d->>'area',
      tags = new_tags, deleted_at = new_deleted, device_id = p_device, version = cur.version + 1
    where id = cur.id returning * into res;
    outcome := 'merged';
  end if;

  if cur.id is null or cur.body_md is distinct from res.body_md then
    insert into public.node_versions (id, node_id, version, body_md, device_id, tags)
    values (gen_random_uuid(), res.id, res.version, res.body_md, p_device, res.tags);
  end if;

  delete from public.purged where entity = 'node' and id = res.id;
  return jsonb_build_object('status', outcome, 'record', to_jsonb(res));
end;
$$;

create or replace function sync_apply_edge(p_base integer, d jsonb)
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
  elsif cur.kind = d->>'kind' and cur.label is not distinct from d->>'label'
        and cur.deleted_at is not distinct from (d->>'deleted_at')::timestamptz then
    -- Push ripetuto: lo stesso contenuto è già applicato.
    res := cur;
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

revoke execute on function merge_tags(text[], text[], text[]) from public, anon, authenticated;
grant execute on function merge_tags(text[], text[], text[]) to service_role;
