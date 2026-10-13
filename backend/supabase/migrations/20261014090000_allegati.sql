-- Allegati: PDF e immagini (fase 4, parte 2; ADR 0007).
-- Il file sta nel bucket privato `attachments`, diviso in parti sotto i 50 MB
-- (`<id>/part-000`, `<id>/part-001`...); qui c'è la riga che lo descrive e si
-- sincronizza come nodi e pagine. Le annotazioni a penna su un PDF sono pagine
-- di disegno (`ink_pages`) legate all'allegato e a una sua pagina.

-- La tabella dello schema iniziale non è mai stata usata: si completa con le
-- colonne della sincronizzazione.
alter table attachments
  add column file_name text not null check (length(file_name) between 1 and 255),
  add column part_count integer not null check (part_count between 1 and 100),
  add column version integer not null default 1,
  add column updated_at timestamptz not null default now(),
  add column device_id text not null,
  add column server_seq bigint not null,
  add constraint attachments_sha256 check (sha256 ~ '^[0-9a-f]{64}$'),
  add constraint attachments_size check (size_bytes between 1 and 2000000000),
  -- Il percorso nel bucket è l'id: nessun client può puntare ai file di un altro allegato.
  add constraint attachments_path check (storage_path = id::text);

create index attachments_node_id on attachments (node_id);
create index attachments_server_seq on attachments (server_seq);
create index attachments_deleted_at on attachments (deleted_at) where deleted_at is not null;

create or replace function sync_stamp() returns trigger
language plpgsql set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtext('pitchstone_sync'));
  new.server_seq := nextval('public.sync_seq');
  if tg_table_name in ('nodes', 'ink_pages', 'attachments') then
    new.updated_at := now();
  end if;
  return new;
end;
$$;

create trigger attachments_sync_stamp before insert or update on attachments
  for each row execute function sync_stamp();

alter table ink_pages
  add column attachment_id uuid references attachments(id) on delete cascade,
  add column pdf_page integer check (pdf_page >= 0),
  add constraint ink_pages_pdf check ((attachment_id is null) = (pdf_page is null));
create index ink_pages_attachment_id on ink_pages (attachment_id) where attachment_id is not null;

alter table purged drop constraint purged_entity_check;
alter table purged add constraint purged_entity_check check (entity in ('node','edge','ink_page','attachment'));

-- File da cancellare dal bucket: lo fa il Worker (la Storage API non si chiama da SQL).
create table storage_trash (
  path text primary key check (path ~ '^[0-9a-f-]{36}$'),
  part_count integer not null check (part_count between 1 and 100),
  queued_at timestamptz not null default now()
);
alter table storage_trash enable row level security;
revoke all on table storage_trash from public, anon, authenticated;

-- Il bucket privato. In locale lo crea anche la CLI (config.toml); in produzione questa migrazione.
do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit)
    values ('attachments', 'attachments', false, 52428800)
    on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;
  end if;
end;
$$;

-- Un allegato non cambia: si possono cambiare solo nodo, nome e cestino.
-- In un conflitto vale l'ultima modifica, e un ripristino vince su un'eliminazione.
create function sync_apply_attachment(p_device text, p_base integer, d jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare
  cur public.attachments;
  res public.attachments;
  outcome text;
  v_deleted timestamptz := (d->>'deleted_at')::timestamptz;
begin
  select * into cur from public.attachments where id = (d->>'id')::uuid for update;

  if not found then
    insert into public.attachments (id, node_id, kind, storage_path, size_bytes, page_count, sha256, file_name,
                                    part_count, version, created_at, deleted_at, device_id)
    values ((d->>'id')::uuid, (d->>'node_id')::uuid, d->>'kind', d->>'storage_path', (d->>'size_bytes')::bigint,
            (d->>'page_count')::integer, d->>'sha256', d->>'file_name', (d->>'part_count')::integer, 1,
            coalesce((d->>'created_at')::timestamptz, now()), v_deleted, p_device)
    returning * into res;
    outcome := 'created';
  else
    if cur.sha256 is distinct from d->>'sha256' or cur.size_bytes is distinct from (d->>'size_bytes')::bigint
       or cur.part_count is distinct from (d->>'part_count')::integer or cur.kind is distinct from d->>'kind' then
      raise exception 'il contenuto di un allegato non cambia' using errcode = '22023';
    end if;
    update public.attachments set
      node_id = (d->>'node_id')::uuid,
      file_name = coalesce(d->>'file_name', cur.file_name),
      page_count = coalesce((d->>'page_count')::integer, cur.page_count),
      deleted_at = case
        when p_base is not null and p_base = cur.version then v_deleted
        -- Conflitto: un ripristino vince, un'eliminazione vale solo se nessuno ha ripristinato.
        when v_deleted is null then null
        else coalesce(cur.deleted_at, v_deleted) end,
      device_id = p_device, version = cur.version + 1
    where id = cur.id returning * into res;
    outcome := case when p_base is not null and p_base = cur.version then 'updated' else 'merged' end;
  end if;

  delete from public.purged where entity = 'attachment' and id = res.id;
  return jsonb_build_object('status', outcome, 'record', to_jsonb(res));
end;
$$;

-- Le annotazioni di un PDF: in un conflitto la copia resta sulla stessa pagina del PDF,
-- come un secondo strato. Nessun tratto va perso.
create or replace function sync_apply_ink(p_device text, p_base integer, d jsonb)
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
    insert into public.ink_pages (id, node_id, page_no, background, ink_data, version, created_at, deleted_at, device_id,
                                  attachment_id, pdf_page)
    values ((d->>'id')::uuid, (d->>'node_id')::uuid, coalesce((d->>'page_no')::integer, 0), v_background, v_ink, 1,
            coalesce((d->>'created_at')::timestamptz, now()), v_deleted, p_device,
            (d->>'attachment_id')::uuid, (d->>'pdf_page')::integer)
    returning * into res;
    outcome := 'created';
  elsif p_base is not null and p_base = cur.version then
    update public.ink_pages set
      page_no = coalesce((d->>'page_no')::integer, cur.page_no), background = v_background,
      ink_data = v_ink, deleted_at = v_deleted, device_id = p_device, version = cur.version + 1
    where id = cur.id returning * into res;
    outcome := 'updated';
  elsif cur.ink_data = v_ink then
    update public.ink_pages set
      deleted_at = coalesce(v_deleted, cur.deleted_at),
      device_id = p_device, version = cur.version + 1
    where id = cur.id returning * into res;
    outcome := 'merged';
  elsif cur.deleted_at is not null and v_deleted is null then
    update public.ink_pages set
      background = v_background, ink_data = v_ink, deleted_at = null, device_id = p_device, version = cur.version + 1
    where id = cur.id returning * into res;
    outcome := 'merged';
  else
    res := cur;
    outcome := 'merged';
    if v_deleted is null and octet_length(v_ink) > 0 and not exists (
      select 1 from public.ink_pages
      where node_id = cur.node_id and id <> cur.id and ink_data = v_ink and deleted_at is null
    ) then
      insert into public.ink_pages (id, node_id, page_no, background, ink_data, version, deleted_at, device_id,
                                    attachment_id, pdf_page)
      values (gen_random_uuid(), cur.node_id,
              (select coalesce(max(page_no), -1) + 1 from public.ink_pages where node_id = cur.node_id),
              v_background, v_ink, 1, null, p_device, cur.attachment_id, cur.pdf_page)
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
      elsif entity = 'attachment' then
        outcome := public.sync_apply_attachment(p_device_id, (ch->>'base_version')::integer, ch->'data');
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
      select 'attachment', a.server_seq, 700 + octet_length(a.file_name) from public.attachments a where a.server_seq > p_cursor
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
      when 'attachment' then (select to_jsonb(a) from public.attachments a where a.server_seq = page.server_seq)
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
  perform pg_advisory_xact_lock(hashtext('pitchstone_sync'));
  with gone as (
    select id from public.edges
    where deleted_at < cutoff
       or source_id in (select id from public.nodes where deleted_at < cutoff)
       or target_id in (select id from public.nodes where deleted_at < cutoff)
  )
  insert into public.purged (entity, id)
  select 'edge', id from gone
  on conflict (entity, id) do update set purged_at = now();

  -- Allegati nel cestino da soli o con il loro nodo: la riga va, i file vanno in coda per il Worker.
  insert into public.purged (entity, id)
  select 'attachment', id from public.attachments
  where deleted_at < cutoff or node_id in (select id from public.nodes where deleted_at < cutoff)
  on conflict (entity, id) do update set purged_at = now();

  insert into public.storage_trash (path, part_count)
  select a.storage_path, a.part_count from public.attachments a join public.purged p
    on p.entity = 'attachment' and p.id = a.id and p.purged_at = now()
  on conflict (path) do nothing;

  insert into public.purged (entity, id)
  select 'ink_page', id from public.ink_pages
  where deleted_at < cutoff
     or node_id in (select id from public.nodes where deleted_at < cutoff)
     or attachment_id in (select id from public.purged where entity = 'attachment' and purged_at = now())
  on conflict (entity, id) do update set purged_at = now();

  insert into public.purged (entity, id)
  select 'node', id from public.nodes where deleted_at < cutoff
  on conflict (entity, id) do update set purged_at = now();

  delete from public.edges e using public.purged p
    where p.entity = 'edge' and p.id = e.id and p.purged_at = now();
  delete from public.ink_pages i using public.purged p
    where p.entity = 'ink_page' and p.id = i.id and p.purged_at = now();
  delete from public.attachments a using public.purged p
    where p.entity = 'attachment' and p.id = a.id and p.purged_at = now();
  delete from public.nodes n using public.purged p
    where p.entity = 'node' and p.id = n.id and p.purged_at = now() and n.deleted_at < cutoff;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Coda dei file da cancellare: il Worker legge, cancella dal bucket, conferma.
create function storage_trash_list(p_limit integer default 100)
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('path', path, 'part_count', part_count) order by queued_at), '[]')
  from (select * from public.storage_trash order by queued_at limit greatest(1, least(p_limit, 500))) t;
$$;

create function storage_trash_done(p_paths text[])
returns integer language sql set search_path = '' as $$
  with gone as (delete from public.storage_trash where path = any(p_paths) returning 1)
  select count(*)::integer from gone;
$$;

revoke execute on function sync_apply_attachment(text, integer, jsonb), storage_trash_list(integer),
  storage_trash_done(text[]) from public, anon, authenticated;
grant execute on function storage_trash_list(integer), storage_trash_done(text[]) to service_role;
