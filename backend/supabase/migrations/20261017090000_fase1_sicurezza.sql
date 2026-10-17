-- Fase 1 del piano di correzione: sicurezza e integrità dei dati.

-- 1. `authenticated` non ha mai accesso alle tabelle: ci arriva solo service_role, dal Worker.
revoke all on all tables in schema public from authenticated;
revoke all on all sequences in schema public from authenticated;
revoke execute on all functions in schema public from authenticated;
alter default privileges for role postgres in schema public revoke all on tables from authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from authenticated;

-- 2. backup_snapshot non salta più RLS: gira con i privilegi di chi la chiama (service_role).
create or replace function backup_snapshot()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with safe_nodes as (
    select * from public.nodes where type <> 'health' and area <> 'salute'
  )
  select jsonb_build_object(
    'format', 'pitchstone-backup',
    'version', 1,
    'created_at', now(),
    'nodes', coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at) from safe_nodes n), '[]'::jsonb),
    'edges', coalesce((
      select jsonb_agg(to_jsonb(e) order by e.created_at) from public.edges e
      where e.source_id in (select id from safe_nodes) and e.target_id in (select id from safe_nodes)
    ), '[]'::jsonb),
    'ink_pages', coalesce((
      select jsonb_agg(
        (to_jsonb(p) - 'ink_data') || jsonb_build_object('ink_data', encode(p.ink_data, 'base64'))
        order by p.created_at)
      from public.ink_pages p where p.node_id in (select id from safe_nodes)
    ), '[]'::jsonb),
    'attachments', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.created_at) from public.attachments a
      where a.node_id is null or a.node_id in (select id from safe_nodes)
    ), '[]'::jsonb)
  );
$$;
revoke execute on function backup_snapshot() from public, anon, authenticated;
grant execute on function backup_snapshot() to service_role;

-- 3. Il server decide quando una riga è stata eliminata e non accetta date di creazione assurde:
-- un client sbagliato non può né far scadere subito il cestino né retrodatare una riga.
create function sync_normalize(p_entity text, d jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_id uuid := (d->>'id')::uuid;
  v_deleted timestamptz := nullif(d->>'deleted_at', '')::timestamptz;
  v_created timestamptz := nullif(d->>'created_at', '')::timestamptz;
  v_current timestamptz;
begin
  if v_deleted is not null then
    execute format('select deleted_at from public.%I where id = $1', case p_entity
      when 'node' then 'nodes' when 'edge' then 'edges'
      when 'ink_page' then 'ink_pages' else 'attachments' end)
      into v_current using v_id;
    d := jsonb_set(d, '{deleted_at}', to_jsonb(coalesce(v_current, now())));
  end if;
  if v_created is not null then
    d := jsonb_set(d, '{created_at}', to_jsonb(least(greatest(v_created, timestamptz '2000-01-01'), now())));
  end if;
  return d;
end;
$$;

-- 4. Esiti di rifiuto con codici fissi: mai il testo dell'errore di Postgres, che può citare i dati.
create function sync_error_code(p_sqlstate text, p_constraint text)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_sqlstate = '23503' then 'missing_parent'
    when p_sqlstate = '23505' or p_sqlstate = 'P0002' then 'conflict'
    when p_sqlstate = '23514' and p_constraint in ('nodes_type_check', 'nodes_area_check') then 'forbidden_type'
    when p_sqlstate = '23514' and p_constraint in ('ink_pages_size', 'attachments_size') then 'too_large'
    else 'invalid'
  end;
$$;

create or replace function sync_push(p_device_id text, p_changes jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare
  ch jsonb;
  data jsonb;
  outcome jsonb;
  results jsonb := '[]'::jsonb;
  entity text;
  v_constraint text;
begin
  if p_device_id is null or p_device_id !~ '^[A-Za-z0-9._-]{1,64}$' then
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
      if entity not in ('node', 'edge', 'ink_page', 'attachment') then
        raise exception 'entity non valida' using errcode = '22023';
      end if;
      data := public.sync_normalize(entity, ch->'data');
      if entity = 'node' then
        outcome := public.sync_apply_node(p_device_id, (ch->>'base_version')::integer, data);
      elsif entity = 'edge' then
        outcome := public.sync_apply_edge((ch->>'base_version')::integer, data);
      elsif entity = 'ink_page' then
        outcome := public.sync_apply_ink(p_device_id, (ch->>'base_version')::integer, data);
      else
        outcome := public.sync_apply_attachment(p_device_id, (ch->>'base_version')::integer, data);
      end if;
      results := results || jsonb_build_array(
        outcome || jsonb_build_object('entity', entity, 'id', ch->'data'->>'id'));
    exception when others then
      get stacked diagnostics v_constraint = constraint_name;
      results := results || jsonb_build_array(jsonb_build_object(
        'entity', entity, 'id', ch->'data'->>'id', 'status', 'rejected',
        'error', sqlstate, 'message', public.sync_error_code(sqlstate, v_constraint)));
    end;
  end loop;

  return jsonb_build_object('results', results);
end;
$$;

-- 5. Cestino: una sola esecuzione non elimina più della metà dei nodi (un bug o un client
-- impazzito non svuota il database), non aspetta i lock all'infinito e lavora a lotti.
create or replace function purge_trash(p_older_than interval default interval '30 days')
returns integer language plpgsql set search_path = '' as $$
declare
  n integer;
  cutoff timestamptz := now() - p_older_than;
  total integer;
  eligible integer;
  batch uuid[];
begin
  perform set_config('lock_timeout', '5s', true);
  perform pg_advisory_xact_lock(hashtext('pitchstone_sync'));

  select count(*) into total from public.nodes;
  select count(*) into eligible from public.nodes where deleted_at < cutoff;
  if total >= 50 and eligible * 2 > total then
    raise warning 'purge_trash fermato: % nodi su % da eliminare', eligible, total;
    return 0;
  end if;
  batch := array(select id from public.nodes where deleted_at < cutoff order by deleted_at limit 1000);

  with gone as (
    select id from public.edges
    where deleted_at < cutoff or source_id = any(batch) or target_id = any(batch)
  )
  insert into public.purged (entity, id)
  select 'edge', id from gone
  on conflict (entity, id) do update set purged_at = now();

  insert into public.purged (entity, id)
  select 'attachment', id from public.attachments
  where deleted_at < cutoff or node_id = any(batch)
  on conflict (entity, id) do update set purged_at = now();

  insert into public.storage_trash (path, part_count)
  select a.storage_path, a.part_count from public.attachments a join public.purged p
    on p.entity = 'attachment' and p.id = a.id and p.purged_at = now()
  on conflict (path) do nothing;

  insert into public.purged (entity, id)
  select 'ink_page', id from public.ink_pages
  where deleted_at < cutoff
     or node_id = any(batch)
     or attachment_id in (select id from public.purged where entity = 'attachment' and purged_at = now())
  on conflict (entity, id) do update set purged_at = now();

  insert into public.purged (entity, id)
  select 'node', id from unnest(batch) as id
  on conflict (entity, id) do update set purged_at = now();

  delete from public.edges e using public.purged p
    where p.entity = 'edge' and p.id = e.id and p.purged_at = now();
  delete from public.ink_pages i using public.purged p
    where p.entity = 'ink_page' and p.id = i.id and p.purged_at = now();
  delete from public.attachments a using public.purged p
    where p.entity = 'attachment' and p.id = a.id and p.purged_at = now();
  delete from public.nodes where id = any(batch);
  get diagnostics n = row_count;
  return n;
end;
$$;

-- 6. Allegati: si scarica solo ciò che ha una riga non eliminata; i file senza riga si trovano
-- per ripulirli (il Worker chiede quali id non hanno riga).
create function attachment_download_allowed(p_id uuid)
returns boolean language sql stable set search_path = '' as $$
  select exists (select 1 from public.attachments where id = p_id and deleted_at is null)
$$;

-- Id senza riga e non in coda per la cancellazione (quei file restano per i backup).
create function attachments_without_row(p_ids uuid[])
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(i), '[]'::jsonb)
  from unnest(p_ids) as i
  where not exists (select 1 from public.attachments a where a.id = i)
    and not exists (select 1 from public.storage_trash t where t.path = i::text)
$$;

-- Coda di cancellazione dei file: un lotto che non si riesce a cancellare non blocca gli altri.
alter table storage_trash add column attempts integer not null default 0;

create function storage_trash_failed(p_paths text[])
returns void language sql set search_path = '' as $$
  update public.storage_trash set attempts = attempts + 1 where path = any(p_paths);
$$;

create or replace function storage_trash_list(p_limit integer default 100, p_min_age interval default interval '15 days')
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('path', path, 'part_count', part_count) order by attempts, queued_at), '[]')
  from (
    select * from public.storage_trash
    where queued_at <= now() - p_min_age and attempts < 20
    order by attempts, queued_at limit greatest(1, least(p_limit, 500))
  ) t;
$$;

revoke execute on function sync_normalize(text, jsonb), sync_error_code(text, text),
  attachment_download_allowed(uuid), attachments_without_row(uuid[]), storage_trash_failed(text[])
  from public, anon, authenticated;
grant execute on function attachment_download_allowed(uuid), attachments_without_row(uuid[]), storage_trash_failed(text[])
  to service_role;
grant execute on function sync_normalize(text, jsonb), sync_error_code(text, text) to service_role;

-- I bucket accettano solo i tipi che l'app carica (le parti sono binarie: octet-stream).
do $$
begin
  if to_regclass('storage.buckets') is not null then
    update storage.buckets set allowed_mime_types = array['application/octet-stream'] where id = 'attachments';
    update storage.buckets set allowed_mime_types = array['application/json'] where id = 'backups';
  end if;
end;
$$;
