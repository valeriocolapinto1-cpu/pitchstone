-- Fase 3 del piano di correzione: privacy. Esportazione completa e cancellazione di tutto dal server.

-- Come backup_rows, ma per l'esportazione: tutto ciò che il server ha dell'utente, cestino e storico
-- compresi, e i disegni (base64) dentro le loro pagine. In ordine di id, a pagine limitate in byte.
create function export_rows(p_table text, p_after uuid default null, p_limit integer default 500, p_max_bytes integer default 3000000)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  result jsonb;
begin
  if p_table not in ('nodes', 'edges', 'node_versions', 'ink_pages', 'attachments', 'purged') then
    raise exception 'tabella non valida' using errcode = '22023';
  end if;
  with src as (
    select n.id, to_jsonb(n) as j from public.nodes n where p_table = 'nodes'
    union all
    select e.id, to_jsonb(e) from public.edges e where p_table = 'edges'
    union all
    select v.id, to_jsonb(v) from public.node_versions v where p_table = 'node_versions'
    union all
    select i.id, public.ink_page_json(i) from public.ink_pages i where p_table = 'ink_pages'
    union all
    select a.id, to_jsonb(a) from public.attachments a where p_table = 'attachments'
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

-- "Cancella tutto dal server": svuota le tabelle, mette in coda tutti i file degli allegati (il Worker li
-- toglie dal bucket subito, senza i 15 giorni dei backup) e passa a una nuova epoca: i dispositivi ripartono
-- da zero. Il Worker cancella poi anche i backup. Serve la parola d'ordine.
create function account_erase(p_confirm text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  n integer;
  v_epoch integer;
begin
  if p_confirm is distinct from 'cancella-tutto' then
    raise exception 'conferma mancante' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('pitchstone_sync'));
  select count(*) into n from public.nodes;
  insert into public.storage_trash (path, part_count, queued_at)
    select storage_path, part_count, now() - interval '100 years' from public.attachments
  on conflict (path) do update set queued_at = now() - interval '100 years', attempts = 0;
  delete from public.ink_pages where true;
  delete from public.attachments where true;
  delete from public.edges where true;
  delete from public.node_versions where true;
  delete from public.nodes where true;
  delete from public.purged where true;
  update public.sync_meta set epoch = epoch + 1, last_backup_at = null where id returning epoch into v_epoch;
  return jsonb_build_object('nodes', n, 'epoch', v_epoch);
end;
$$;

revoke execute on function export_rows(text, uuid, integer, integer), account_erase(text) from public, anon, authenticated;
grant execute on function export_rows(text, uuid, integer, integer), account_erase(text) to service_role;
