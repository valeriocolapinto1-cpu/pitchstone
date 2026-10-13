-- Disegno a penna (fase 2, parte 2; ADR 0004).
-- Ogni nodo può avere pagine di disegno: tratti PencilKit serializzati (PKDrawing)
-- e uno sfondo. Le pagine si sincronizzano come nodi e archi.

create table ink_pages (
  id uuid primary key,
  node_id uuid not null references nodes(id) on delete cascade,
  page_no integer not null check (page_no >= 0),
  background text not null default 'blank' check (background in ('blank','lines','grid')),
  ink_data bytea not null default '',
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  device_id text not null,
  server_seq bigint not null,
  -- PKDrawing di una pagina: oltre 2 MB qualcosa non va (e il Worker accetta 5 MB per push).
  constraint ink_pages_size check (octet_length(ink_data) <= 2000000)
);
alter table ink_pages enable row level security;
revoke all on table ink_pages from public, anon, authenticated;

create index ink_pages_node_id on ink_pages (node_id);
create index ink_pages_server_seq on ink_pages (server_seq);
create index ink_pages_deleted_at on ink_pages (deleted_at) where deleted_at is not null;

create or replace function sync_stamp() returns trigger
language plpgsql set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtext('pitchstone_sync'));
  new.server_seq := nextval('public.sync_seq');
  if tg_table_name in ('nodes', 'ink_pages') then
    new.updated_at := now();
  end if;
  return new;
end;
$$;

create trigger ink_pages_sync_stamp before insert or update on ink_pages
  for each row execute function sync_stamp();

alter table purged drop constraint purged_entity_check;
alter table purged add constraint purged_entity_check check (entity in ('node','edge','ink_page'));

-- JSON di una pagina per il client: i byte del disegno in base64 su una riga.
create function ink_page_json(p public.ink_pages)
returns jsonb language sql immutable set search_path = '' as $$
  select (to_jsonb(p) - 'ink_data')
    || jsonb_build_object('ink_data', translate(encode(p.ink_data, 'base64'), E'\n', ''));
$$;

-- Due disegni non si possono fondere sul server: in un conflitto la pagina del
-- server resta com'è e il disegno del client diventa una nuova pagina dello
-- stesso nodo. Nessun tratto va perso.
create function sync_apply_ink(p_device text, p_base integer, d jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare
  cur public.ink_pages;
  res public.ink_pages;
  dup public.ink_pages;
  outcome text;
  v_ink bytea := decode(coalesce(d->>'ink_data', ''), 'base64');
  v_deleted timestamptz := (d->>'deleted_at')::timestamptz;
  v_background text := coalesce(d->>'background', 'blank');
begin
  select * into cur from public.ink_pages where id = (d->>'id')::uuid for update;

  if not found then
    insert into public.ink_pages (id, node_id, page_no, background, ink_data, version, created_at, deleted_at, device_id)
    values ((d->>'id')::uuid, (d->>'node_id')::uuid, coalesce((d->>'page_no')::integer, 0), v_background, v_ink, 1,
            coalesce((d->>'created_at')::timestamptz, now()), v_deleted, p_device)
    returning * into res;
    outcome := 'created';
  elsif p_base is not null and p_base = cur.version then
    update public.ink_pages set
      page_no = coalesce((d->>'page_no')::integer, cur.page_no), background = v_background,
      ink_data = v_ink, deleted_at = v_deleted, device_id = p_device, version = cur.version + 1
    where id = cur.id returning * into res;
    outcome := 'updated';
  elsif cur.ink_data = v_ink then
    -- Stessi tratti: conflitto solo apparente (per esempio una risposta persa).
    -- Lo sfondo resta quello del server, più recente; l'eliminazione del client vale.
    update public.ink_pages set
      deleted_at = coalesce(v_deleted, cur.deleted_at),
      device_id = p_device, version = cur.version + 1
    where id = cur.id returning * into res;
    outcome := 'merged';
  elsif cur.deleted_at is not null and v_deleted is null then
    -- Il server l'aveva eliminata, il client l'ha modificata: vince la modifica.
    update public.ink_pages set
      background = v_background, ink_data = v_ink, deleted_at = null, device_id = p_device, version = cur.version + 1
    where id = cur.id returning * into res;
    outcome := 'merged';
  else
    res := cur;
    outcome := 'merged';
    -- Una pagina eliminata dal client mentre il server la modificava resta com'è sul server.
    -- Se la copia esiste già (risposta persa e nuovo invio), non se ne crea un'altra.
    if v_deleted is null and octet_length(v_ink) > 0 and not exists (
      select 1 from public.ink_pages
      where node_id = cur.node_id and id <> cur.id and ink_data = v_ink and deleted_at is null
    ) then
      insert into public.ink_pages (id, node_id, page_no, background, ink_data, version, deleted_at, device_id)
      values (gen_random_uuid(), cur.node_id,
              (select coalesce(max(page_no), -1) + 1 from public.ink_pages where node_id = cur.node_id),
              v_background, v_ink, 1, null, p_device)
      returning * into dup;
    end if;
  end if;

  delete from public.purged where entity = 'ink_page' and id = res.id;
  return jsonb_build_object('status', outcome, 'record', public.ink_page_json(res))
    || case when dup.id is null then '{}'::jsonb else jsonb_build_object('copy_id', dup.id) end;
end;
$$;

create or replace function sync_push(p_device_id text, p_changes jsonb)
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
      elsif entity = 'ink_page' then
        outcome := public.sync_apply_ink(p_device_id, (ch->>'base_version')::integer, ch->'data');
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

-- Pull a pagine limitate anche in byte (circa 4 MB): con i disegni poche righe
-- possono pesare molto. La dimensione si stima senza costruire il JSON, che si
-- costruisce solo per le righe della pagina. server_seq è unico tra tutte le
-- tabelle (una sola sequence), quindi identifica la riga. La prima riga passa
-- sempre, così il pull avanza.
create or replace function sync_pull(p_cursor bigint, p_limit integer default 500)
returns jsonb language sql stable set search_path = '' as $$
  with candidates as (
    select * from (
      select 'node' as entity, n.server_seq, 600 + octet_length(n.title) + octet_length(n.body_md) as size
        from public.nodes n where n.server_seq > p_cursor
      union all
      select 'edge', e.server_seq, 400 + coalesce(octet_length(e.label), 0) from public.edges e where e.server_seq > p_cursor
      union all
      select 'node_version', v.server_seq, 300 + octet_length(v.body_md) from public.node_versions v where v.server_seq > p_cursor
      union all
      select 'ink_page', i.server_seq, 600 + octet_length(i.ink_data) * 4 / 3 from public.ink_pages i where i.server_seq > p_cursor
      union all
      select 'purged', p.server_seq, 200 from public.purged p where p.server_seq > p_cursor
    ) c
    order by server_seq
    limit greatest(1, least(coalesce(p_limit, 500), 1000)) + 1
  ), sized as (
    select *,
      row_number() over (order by server_seq) as rn,
      sum(size) over (order by server_seq) as running_bytes
    from candidates
  ), page as (
    select entity, server_seq from sized
    where rn <= greatest(1, least(coalesce(p_limit, 500), 1000))
      and (rn = 1 or running_bytes <= 4000000)
  ), rows as (
    select page.entity, page.server_seq, case page.entity
      when 'node' then (select to_jsonb(n) from public.nodes n where n.server_seq = page.server_seq)
      when 'edge' then (select to_jsonb(e) from public.edges e where e.server_seq = page.server_seq)
      when 'node_version' then (select to_jsonb(v) from public.node_versions v where v.server_seq = page.server_seq)
      when 'ink_page' then (select public.ink_page_json(i) from public.ink_pages i where i.server_seq = page.server_seq)
      when 'purged' then (select to_jsonb(p) from public.purged p where p.server_seq = page.server_seq)
    end as data
    from page
  )
  select jsonb_build_object(
    'changes', coalesce((select jsonb_agg(jsonb_build_object('entity', entity, 'data', data) order by server_seq) from rows), '[]'),
    'cursor', coalesce((select max(server_seq) from page), p_cursor),
    'has_more', (select count(*) from candidates) > (select count(*) from page)
  );
$$;

create or replace function purge_trash(p_older_than interval default interval '30 days')
returns integer language plpgsql set search_path = '' as $$
declare
  n integer;
  cutoff timestamptz := now() - p_older_than;
begin
  -- Stesso lock delle scritture: un ripristino concorrente non può
  -- finire tra la selezione e l'eliminazione.
  perform pg_advisory_xact_lock(hashtext('pitchstone_sync'));
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

  -- Anche le pagine di disegno: nel cestino da sole o con il loro nodo.
  insert into public.purged (entity, id)
  select 'ink_page', id from public.ink_pages
  where deleted_at < cutoff or node_id in (select id from public.nodes where deleted_at < cutoff)
  on conflict (entity, id) do update set purged_at = now();

  insert into public.purged (entity, id)
  select 'node', id from public.nodes where deleted_at < cutoff
  on conflict (entity, id) do update set purged_at = now();

  delete from public.edges e using public.purged p
    where p.entity = 'edge' and p.id = e.id and p.purged_at = now();
  delete from public.ink_pages i using public.purged p
    where p.entity = 'ink_page' and p.id = i.id and p.purged_at = now();
  delete from public.nodes n using public.purged p
    where p.entity = 'node' and p.id = n.id and p.purged_at = now() and n.deleted_at < cutoff;
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke execute on function ink_page_json(public.ink_pages), sync_apply_ink(text, integer, jsonb)
  from public, anon, authenticated;
