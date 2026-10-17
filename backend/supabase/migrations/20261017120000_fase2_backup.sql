-- Fase 2 del piano di correzione: backup, ripristino e conservazione.

-- 1. Epoca della sincronizzazione. Un ripristino dal backup la incrementa: i client che vedono
-- un'epoca nuova sanno che i cursori non valgono più e ripartono da zero.
create table sync_meta (
  id boolean primary key default true check (id),
  epoch integer not null default 1,
  last_backup_at timestamptz
);
insert into sync_meta default values;
alter table sync_meta enable row level security;
revoke all on table sync_meta from public, anon, authenticated;

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
    'has_more', (select count(*) from candidates) > (select count(*) from page),
    'epoch', (select epoch from public.sync_meta)
  );
$$;

-- 2. Backup a pagine. Il Worker non chiede più un unico JSON: legge una tabella alla volta,
-- a pagine limitate in byte, e salva un file per pagina. Comprende storico dei nodi e righe
-- eliminate definitivamente; esclude cestino e salute. Il disegno sta in file a parte.
create function backup_counts()
returns jsonb language sql stable set search_path = '' as $$
  with scope as (
    select id from public.nodes where deleted_at is null and type <> 'health' and area <> 'salute'
  )
  select jsonb_build_object(
    'nodes', (select count(*) from scope),
    'edges', (select count(*) from public.edges e where e.deleted_at is null
              and e.source_id in (select id from scope) and e.target_id in (select id from scope)),
    'node_versions', (select count(*) from public.node_versions v where v.node_id in (select id from scope)),
    'ink_pages', (select count(*) from public.ink_pages i where i.deleted_at is null and i.node_id in (select id from scope)),
    'attachments', (select count(*) from public.attachments a where a.deleted_at is null
                    and (a.node_id is null or a.node_id in (select id from scope))),
    'purged', (select count(*) from public.purged)
  );
$$;

-- Pagina di una tabella in ordine di id: righe dopo `p_after`, al massimo `p_limit` e circa
-- `p_max_bytes` (la prima riga passa sempre). Il disegno non c'è: lo dà backup_ink_rows.
create function backup_rows(p_table text, p_after uuid default null, p_limit integer default 500, p_max_bytes integer default 3000000)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  result jsonb;
begin
  if p_table not in ('nodes', 'edges', 'node_versions', 'ink_pages', 'attachments', 'purged') then
    raise exception 'tabella non valida' using errcode = '22023';
  end if;
  with scope as (
    select id from public.nodes where deleted_at is null and type <> 'health' and area <> 'salute'
  ), src as (
    select n.id, to_jsonb(n) as j from public.nodes n where p_table = 'nodes' and n.id in (select id from scope)
    union all
    select e.id, to_jsonb(e) from public.edges e where p_table = 'edges' and e.deleted_at is null
      and e.source_id in (select id from scope) and e.target_id in (select id from scope)
    union all
    select v.id, to_jsonb(v) from public.node_versions v where p_table = 'node_versions' and v.node_id in (select id from scope)
    union all
    select i.id, to_jsonb(i) - 'ink_data' from public.ink_pages i where p_table = 'ink_pages' and i.deleted_at is null
      and i.node_id in (select id from scope)
    union all
    select a.id, to_jsonb(a) from public.attachments a where p_table = 'attachments' and a.deleted_at is null
      and (a.node_id is null or a.node_id in (select id from scope))
    union all
    select p.id, to_jsonb(p) from public.purged p where p_table = 'purged'
  ), candidates as (
    select id, j, octet_length(j::text) as size from src where p_after is null or id > p_after
    order by id limit greatest(1, least(coalesce(p_limit, 500), 2000)) + 1
  ), sized as (
    select *, row_number() over (order by id) as rn, sum(size) over (order by id) as running from candidates
  ), page as (
    select * from sized
    where rn <= greatest(1, least(coalesce(p_limit, 500), 2000)) and (rn = 1 or running <= p_max_bytes)
  )
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(j order by id) from page), '[]'),
    'last', (select id from page order by id desc limit 1),
    'more', (select count(*) from candidates) > (select count(*) from page)
  ) into result;
  return result;
end;
$$;

-- Come backup_rows, per i byte dei disegni (base64): file separati dal resto.
create function backup_ink_rows(p_after uuid default null, p_max_bytes integer default 3000000)
returns jsonb language sql stable set search_path = '' as $$
  with scope as (
    select id from public.nodes where deleted_at is null and type <> 'health' and area <> 'salute'
  ), candidates as (
    select i.id, translate(encode(i.ink_data, 'base64'), E'\n', '') as data
    from public.ink_pages i
    where i.deleted_at is null and i.node_id in (select id from scope) and (p_after is null or i.id > p_after)
    order by i.id limit 50
  ), sized as (
    select *, row_number() over (order by id) as rn, sum(length(data)) over (order by id) as running from candidates
  ), page as (
    select * from sized where rn = 1 or running <= p_max_bytes
  )
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'ink_data', data) order by id) from page), '[]'),
    'last', (select id from page order by id desc limit 1),
    'more', (select count(*) from candidates) > (select count(*) from page)
      or (select count(*) from candidates) = 50
  );
$$;

-- 3. Ripristino. Le righe del backup si riscrivono con la loro identità (id, versione, date); il
-- trigger di sync assegna un server_seq nuovo, quindi ogni client le rivede al pull.
create function backup_restore_rows(p_table text, p_rows jsonb)
returns integer language plpgsql set search_path = '' as $$
declare
  n integer;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'rows deve essere un array' using errcode = '22023';
  end if;
  if p_table = 'nodes' then
    insert into public.nodes select * from jsonb_populate_recordset(null::public.nodes, p_rows)
    on conflict (id) do update set type = excluded.type, title = excluded.title, body_md = excluded.body_md,
      area = excluded.area, tags = excluded.tags, version = excluded.version, created_at = excluded.created_at,
      deleted_at = excluded.deleted_at, device_id = excluded.device_id;
  elsif p_table = 'edges' then
    insert into public.edges select * from jsonb_populate_recordset(null::public.edges, p_rows)
    on conflict (id) do update set source_id = excluded.source_id, target_id = excluded.target_id, kind = excluded.kind,
      label = excluded.label, version = excluded.version, created_at = excluded.created_at, deleted_at = excluded.deleted_at;
  elsif p_table = 'node_versions' then
    insert into public.node_versions select * from jsonb_populate_recordset(null::public.node_versions, p_rows)
    on conflict (id) do nothing;
  elsif p_table = 'attachments' then
    insert into public.attachments select * from jsonb_populate_recordset(null::public.attachments, p_rows)
    on conflict (id) do update set node_id = excluded.node_id, file_name = excluded.file_name, page_count = excluded.page_count,
      version = excluded.version, deleted_at = excluded.deleted_at, device_id = excluded.device_id;
  elsif p_table = 'ink_pages' then
    -- Senza i byte del disegno: arrivano con backup_restore_ink.
    insert into public.ink_pages (id, node_id, page_no, background, ink_data, version, created_at, updated_at,
                                  deleted_at, device_id, attachment_id, pdf_page)
    select id, node_id, page_no, background, ''::bytea, version, created_at, updated_at,
           deleted_at, device_id, attachment_id, pdf_page
    from jsonb_populate_recordset(null::public.ink_pages, p_rows)
    on conflict (id) do update set node_id = excluded.node_id, page_no = excluded.page_no, background = excluded.background,
      version = excluded.version, deleted_at = excluded.deleted_at, device_id = excluded.device_id,
      attachment_id = excluded.attachment_id, pdf_page = excluded.pdf_page;
  elsif p_table = 'purged' then
    insert into public.purged select * from jsonb_populate_recordset(null::public.purged, p_rows)
    on conflict (entity, id) do nothing;
  else
    raise exception 'tabella non valida' using errcode = '22023';
  end if;
  get diagnostics n = row_count;
  return n;
end;
$$;

create function backup_restore_ink(p_rows jsonb)
returns integer language plpgsql set search_path = '' as $$
declare
  n integer;
begin
  update public.ink_pages i set ink_data = decode(r.ink_data, 'base64')
  from jsonb_to_recordset(p_rows) as r(id uuid, ink_data text)
  where i.id = r.id;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Prima di un ripristino su un database non vuoto: svuota le tabelle sincronizzate. Serve la parola d'ordine.
create function backup_restore_wipe(p_confirm text)
returns void language plpgsql set search_path = '' as $$
begin
  if p_confirm is distinct from 'cancella-tutto' then
    raise exception 'conferma mancante' using errcode = '22023';
  end if;
  delete from public.ink_pages;
  delete from public.attachments;
  delete from public.edges;
  delete from public.node_versions;
  delete from public.nodes;
  delete from public.purged;
end;
$$;

-- Ultimo passo del ripristino: nuova epoca, i client ripartono dal pull completo.
create function backup_restore_finish()
returns integer language sql set search_path = '' as $$
  update public.sync_meta set epoch = epoch + 1 returning epoch;
$$;

-- 4. Conservazione: storico dei nodi e righe eliminate non crescono senza limite.
create function prune_history(p_keep integer default 20, p_older interval default interval '90 days')
returns integer language plpgsql set search_path = '' as $$
declare
  n integer;
begin
  with ranked as (
    select id, created_at, row_number() over (partition by node_id order by version desc) as rn
    from public.node_versions
  )
  delete from public.node_versions v using ranked r
  where v.id = r.id and r.rn > p_keep and r.created_at < now() - p_older;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Le righe `purged` servono ai client che non si sincronizzano da tempo: dopo 180 giorni un client
-- così vecchio deve comunque ripartire da zero.
create function prune_purged(p_older interval default interval '180 days')
returns integer language plpgsql set search_path = '' as $$
declare
  n integer;
begin
  delete from public.purged where purged_at < now() - p_older;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Una nota che diventa di salute dopo essere stata sincronizzata: si toglie dal server con tutto
-- ciò che porta (storico, archi, pagine, allegati con i loro file in coda) e si segna come eliminata
-- definitivamente, così gli altri dispositivi la tolgono.
create function redact_node_history(p_id uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare
  removed integer;
begin
  perform pg_advisory_xact_lock(hashtext('pitchstone_sync'));
  insert into public.purged (entity, id)
    select 'edge', id from public.edges where source_id = p_id or target_id = p_id
  on conflict (entity, id) do update set purged_at = now();
  insert into public.purged (entity, id)
    select 'ink_page', id from public.ink_pages
    where node_id = p_id or attachment_id in (select id from public.attachments where node_id = p_id)
  on conflict (entity, id) do update set purged_at = now();
  insert into public.storage_trash (path, part_count)
    select storage_path, part_count from public.attachments where node_id = p_id
  on conflict (path) do nothing;
  insert into public.purged (entity, id)
    select 'attachment', id from public.attachments where node_id = p_id
  on conflict (entity, id) do update set purged_at = now();
  insert into public.purged (entity, id) select 'node', id from public.nodes where id = p_id
  on conflict (entity, id) do update set purged_at = now();
  delete from public.nodes where id = p_id;
  get diagnostics removed = row_count;
  return jsonb_build_object('removed', removed > 0);
end;
$$;

-- Il Worker segna il backup riuscito; il keep-alive (chiave pubblica) ne legge solo l'età.
create function backup_mark_done()
returns void language sql set search_path = '' as $$
  update public.sync_meta set last_backup_at = now();
$$;

create function backup_status()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'last_backup_at', last_backup_at,
    'age_hours', round(extract(epoch from now() - last_backup_at) / 3600, 1)
  ) from public.sync_meta;
$$;

create function db_size_bytes()
returns bigint language sql stable set search_path = '' as $$
  select pg_database_size(current_database());
$$;

revoke execute on function backup_counts(), backup_rows(text, uuid, integer, integer), backup_ink_rows(uuid, integer),
  backup_restore_rows(text, jsonb), backup_restore_ink(jsonb), backup_restore_wipe(text), backup_restore_finish(),
  prune_history(integer, interval), prune_purged(interval), redact_node_history(uuid), db_size_bytes(),
  backup_mark_done(), backup_status()
  from public, anon, authenticated;
grant execute on function backup_counts(), backup_rows(text, uuid, integer, integer), backup_ink_rows(uuid, integer),
  backup_restore_rows(text, jsonb), backup_restore_ink(jsonb), backup_restore_wipe(text), backup_restore_finish(),
  prune_history(integer, interval), prune_purged(interval), redact_node_history(uuid), db_size_bytes(),
  backup_mark_done(), backup_status()
  to service_role;
-- Solo l'età dell'ultimo backup è leggibile con la chiave pubblica.
grant execute on function backup_status() to anon;
revoke execute on function sync_pull(bigint, integer) from public, anon, authenticated;
grant execute on function sync_pull(bigint, integer) to service_role;

select cron.schedule('prune-history', '15 3 * * *', $$select public.prune_history(); select public.prune_purged()$$);
-- Il registro di pg_cron cresce a ogni esecuzione: si tengono 7 giorni.
select cron.schedule('cron-log-cleanup', '45 3 * * *', $$delete from cron.job_run_details where end_time < now() - interval '7 days'$$);

-- 5. Schema mai usato: lo studio resta locale (ADR 0011). Se la Fase 6 porta i dati di studio sul
-- server, si ricreano con lo schema giusto.
drop table if exists sync_changes, chunks, messages, chats, review_logs, reviews, quizzes, goals, exams, pdf_pages;
drop extension if exists vector;
