-- Backup giornaliero (fase 8, ADR 0012). Il Worker, dopo la pulizia del cestino,
-- chiede un'istantanea e la salva nel bucket privato `backups`. I dati di salute
-- non arrivano mai sul server (check su nodes); il filtro qui è una difesa in più.

do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit)
    values ('backups', 'backups', false, 52428800)
    on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;
  end if;
end;
$$;

create or replace function backup_snapshot()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with safe_nodes as (
    select * from nodes where type <> 'health' and area <> 'salute'
  )
  select jsonb_build_object(
    'format', 'pitchstone-backup',
    'version', 1,
    'created_at', now(),
    'nodes', coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at) from safe_nodes n), '[]'::jsonb),
    'edges', coalesce((
      select jsonb_agg(to_jsonb(e) order by e.created_at) from edges e
      where e.source_id in (select id from safe_nodes) and e.target_id in (select id from safe_nodes)
    ), '[]'::jsonb),
    'ink_pages', coalesce((
      select jsonb_agg(
        (to_jsonb(p) - 'ink_data') || jsonb_build_object('ink_data', encode(p.ink_data, 'base64'))
        order by p.created_at)
      from ink_pages p where p.node_id in (select id from safe_nodes)
    ), '[]'::jsonb),
    'attachments', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.created_at) from attachments a
      where a.node_id is null or a.node_id in (select id from safe_nodes)
    ), '[]'::jsonb)
  );
$$;

revoke execute on function backup_snapshot() from public, anon, authenticated;
grant execute on function backup_snapshot() to service_role;

-- I backup restano 14 giorni e citano gli allegati: i loro file si cancellano dal bucket
-- solo dopo, così un ripristino ritrova anche i PDF e le immagini.
drop function storage_trash_list(integer);
create function storage_trash_list(p_limit integer default 100, p_min_age interval default interval '15 days')
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('path', path, 'part_count', part_count) order by queued_at), '[]')
  from (
    select * from public.storage_trash where queued_at <= now() - p_min_age
    order by queued_at limit greatest(1, least(p_limit, 500))
  ) t;
$$;
revoke execute on function storage_trash_list(integer, interval) from public, anon, authenticated;
grant execute on function storage_trash_list(integer, interval) to service_role;
