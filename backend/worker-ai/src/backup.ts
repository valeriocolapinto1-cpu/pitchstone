// Backup giornaliero (ADR 0012, aggiornato dalla Fase 2): una cartella per esecuzione nel bucket
// privato `backups`, con un file JSON per pagina di ogni tabella, i disegni in file a parte e un
// manifest scritto per ultimo con conteggi e sha256 di ogni file. Un backup senza manifest non è
// completo e non vale. Si tengono 14 giorni. I file degli allegati sono già nel bucket `attachments`.
//
//   <data>/<ora>-<id>/nodes-000.json … ink-000.json … manifest.json
import { type SupabaseConfig, rpc, upstreamFetch } from "./sync";
import { headers } from "./storage";

export const BACKUP_BUCKET = "backups";
export const KEEP_DAYS = 14;
/** Un backup con meno di questa quota dei nodi del precedente è sospetto e non si salva. */
export const MAX_DROP = 0.2;
/** Sotto questo numero di nodi il confronto con il backup precedente non ha senso. */
const MIN_NODES_FOR_DROP_CHECK = 10;
const TABLES = ["nodes", "edges", "node_versions", "attachments", "ink_pages", "purged"] as const;
const PAGE_ROWS = 2000;
const PAGE_BYTES = 8_000_000;

export interface BackupFile {
  path: string;
  table: string;
  rows: number;
  bytes: number;
  sha256: string;
}

export interface Manifest {
  format: "pitchstone-backup";
  version: 2;
  created_at: string;
  run: string;
  counts: Record<string, number>;
  files: BackupFile[];
}

interface Row {
  type?: string;
  area?: string;
}

/** Difesa in profondità: un'istantanea con un dato di salute non si salva. */
export function containsHealth(snapshot: { nodes?: Row[] }): boolean {
  return (snapshot.nodes ?? []).some((node) => node.type === "health" || node.area === "salute");
}

export function dayName(date: Date): string {
  return date.toISOString().slice(0, 10);
}

/** `2026-10-17/043012-ab12`: una cartella per esecuzione, quindi mai una sovrascrittura. */
export function runName(date: Date, suffix: string = crypto.randomUUID().slice(0, 4)): string {
  return `${dayName(date)}/${date.toISOString().slice(11, 19).replace(/:/g, "")}-${suffix}`;
}

/** Cartelle (e vecchi file `YYYY-MM-DD.json`) più vecchi di `KEEP_DAYS` giorni rispetto a `now`. */
export function expired(names: string[], now: Date): string[] {
  const limit = new Date(now.getTime() - KEEP_DAYS * 86_400_000).toISOString().slice(0, 10);
  return names.filter((name) => /^\d{4}-\d{2}-\d{2}(\.json)?$/.test(name) && name.slice(0, 10) <= limit);
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

interface Entry {
  name: string;
  id: string | null;
}

async function list(config: SupabaseConfig, prefix: string, fetchImpl: typeof fetch, order: "asc" | "desc" = "asc"): Promise<Entry[]> {
  const response = await upstreamFetch(fetchImpl, new URL(`/storage/v1/object/list/${BACKUP_BUCKET}`, config.url), {
    method: "POST",
    headers: headers(config),
    body: JSON.stringify({ prefix, limit: 1000, sortBy: { column: "name", order } }),
  });
  if (!response.ok) throw new Error(`elenco ${response.status}`);
  return (await response.json()) as Entry[];
}

async function remove(config: SupabaseConfig, paths: string[], fetchImpl: typeof fetch): Promise<boolean> {
  for (let i = 0; i < paths.length; i += 500) {
    const response = await upstreamFetch(fetchImpl, new URL(`/storage/v1/object/${BACKUP_BUCKET}`, config.url), {
      method: "DELETE",
      headers: headers(config),
      body: JSON.stringify({ prefixes: paths.slice(i, i + 500) }),
    });
    if (!response.ok) {
      console.error(`Backup: cancellazione ${response.status}`);
      return false;
    }
  }
  return true;
}

/** Ultimo backup completo (con manifest), o `undefined`. */
export async function latestManifest(
  config: SupabaseConfig,
  fetchImpl: typeof fetch = fetch,
): Promise<{ path: string; manifest: Manifest } | undefined> {
  try {
    const days = (await list(config, "", fetchImpl, "desc")).map((entry) => entry.name).filter((name) => /^\d{4}-\d{2}-\d{2}$/.test(name));
    for (const day of days.slice(0, 3)) {
      const runs = (await list(config, day, fetchImpl, "desc")).map((entry) => entry.name);
      for (const run of runs.slice(0, 3)) {
        const files = await list(config, `${day}/${run}`, fetchImpl);
        if (!files.some((file) => file.name === "manifest.json")) continue;
        const path = `${day}/${run}/manifest.json`;
        const response = await upstreamFetch(fetchImpl, new URL(`/storage/v1/object/${BACKUP_BUCKET}/${path}`, config.url), {
          headers: headers(config),
        });
        if (!response.ok) continue;
        const manifest = (await response.json()) as Manifest;
        if (manifest.format === "pitchstone-backup" && manifest.version === 2) return { path, manifest };
      }
    }
  } catch (error) {
    console.error(`Backup: ultimo manifest ${error instanceof Error ? error.name : "errore"}`);
  }
  return undefined;
}

/** Il backup di questo giorno c'è già? (Per il secondo cron di recupero.) */
export async function backupExists(config: SupabaseConfig, now: Date = new Date(), fetchImpl: typeof fetch = fetch): Promise<boolean> {
  const latest = await latestManifest(config, fetchImpl);
  return latest?.manifest.run.startsWith(dayName(now)) ?? false;
}

class Refused extends Error {}

export type BackupResult = "saved" | "failed" | "refused";

export async function dailyBackup(
  config: SupabaseConfig,
  now: Date = new Date(),
  fetchImpl: typeof fetch = fetch,
  { expire = true }: { expire?: boolean } = {},
): Promise<BackupResult> {
  const run = runName(now);
  const uploaded: string[] = [];
  const files: BackupFile[] = [];
  const totals: Record<string, number> = {};

  const call = async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
    const response = await rpc(config, fn, args, fetchImpl);
    if (!response.ok) throw new Error(`${fn} ${response.status}`);
    return (await response.json()) as T;
  };

  const put = async (name: string, table: string, rows: number, body: string): Promise<void> => {
    const bytes = new TextEncoder().encode(body);
    const path = `${run}/${name}`;
    // Nessun upsert: il nome è unico per esecuzione.
    const response = await upstreamFetch(fetchImpl, new URL(`/storage/v1/object/${BACKUP_BUCKET}/${path}`, config.url), {
      method: "POST",
      headers: headers(config),
      body: bytes,
    });
    if (!response.ok) throw new Error(`upload ${response.status}`);
    uploaded.push(path);
    files.push({ path, table, rows, bytes: bytes.byteLength, sha256: await sha256(bytes) });
    totals[table] = (totals[table] ?? 0) + rows;
  };

  try {
    const before = await call<Record<string, number>>("backup_counts", {});
    const previous = await latestManifest(config, fetchImpl);
    if (
      previous && previous.manifest.counts.nodes >= MIN_NODES_FOR_DROP_CHECK &&
      before.nodes < previous.manifest.counts.nodes * (1 - MAX_DROP)
    ) {
      console.error(`Backup rifiutato: nodi da ${previous.manifest.counts.nodes} a ${before.nodes}`);
      throw new Refused();
    }

    for (const table of TABLES) {
      let after: string | null = null;
      for (let page = 0; ; page++) {
        const result: { rows: Row[]; last: string | null; more: boolean } = await call("backup_rows", {
          p_table: table, p_after: after, p_limit: PAGE_ROWS, p_max_bytes: PAGE_BYTES,
        });
        if (result.rows.length === 0) break;
        if (table === "nodes" && containsHealth({ nodes: result.rows })) {
          console.error("Backup rifiutato: dati di salute");
          throw new Refused();
        }
        await put(`${table}-${String(page).padStart(3, "0")}.json`, table, result.rows.length, JSON.stringify(result.rows));
        if (!result.more || !result.last) break;
        after = result.last;
      }
    }
    // Il disegno sta in file propri: i byte non gonfiano le tabelle.
    let inkAfter: string | null = null;
    for (let page = 0; ; page++) {
      const result: { rows: unknown[]; last: string | null; more: boolean } = await call("backup_ink_rows", {
        p_after: inkAfter, p_max_bytes: PAGE_BYTES,
      });
      if (result.rows.length === 0) break;
      await put(`ink-${String(page).padStart(3, "0")}.json`, "ink_data", result.rows.length, JSON.stringify(result.rows));
      if (!result.more || !result.last) break;
      inkAfter = result.last;
    }

    // Integrità: ciò che si è scritto deve stare tra i conteggi di prima e di dopo (i dati possono
    // cambiare mentre il backup gira, ma non sparire).
    const afterCounts = await call<Record<string, number>>("backup_counts", {});
    for (const table of TABLES) {
      const written = totals[table] ?? 0;
      const low = Math.min(before[table], afterCounts[table]);
      const high = Math.max(before[table], afterCounts[table]);
      if (written < low || written > high) throw new Error(`conteggio ${table}: ${written} invece di ${low}-${high}`);
    }
    if ((totals.ink_data ?? 0) !== (totals.ink_pages ?? 0) && Math.abs((totals.ink_data ?? 0) - (totals.ink_pages ?? 0)) > 1) {
      throw new Error("disegni e pagine non coincidono");
    }

    const manifest: Manifest = {
      format: "pitchstone-backup",
      version: 2,
      created_at: now.toISOString(),
      run,
      counts: Object.fromEntries(TABLES.map((table) => [table, totals[table] ?? 0])),
      files,
    };
    await put("manifest.json", "manifest", 1, JSON.stringify(manifest));
  } catch (error) {
    if (!(error instanceof Refused)) console.error(`Backup: ${error instanceof Error ? error.message : "errore"}`);
    // Niente file a metà: una cartella senza manifest non servirebbe e occuperebbe spazio.
    await remove(config, uploaded, fetchImpl);
    return error instanceof Refused ? "refused" : "failed";
  }

  await rpc(config, "backup_mark_done", {}, fetchImpl);
  if (expire) await removeExpired(config, now, fetchImpl);
  return "saved";
}

async function removeExpired(config: SupabaseConfig, now: Date, fetchImpl: typeof fetch): Promise<void> {
  try {
    const old = expired((await list(config, "", fetchImpl)).map((entry) => entry.name), now);
    const paths: string[] = [];
    for (const name of old) {
      if (name.endsWith(".json")) {
        paths.push(name);
        continue;
      }
      for (const run of await list(config, name, fetchImpl)) {
        for (const file of await list(config, `${name}/${run.name}`, fetchImpl)) paths.push(`${name}/${run.name}/${file.name}`);
      }
    }
    if (paths.length > 0) await remove(config, paths, fetchImpl);
  } catch (error) {
    console.error(`Backup: pulizia ${error instanceof Error ? error.name : "errore"}`);
  }
}

/** Segnale di vita (stile healthchecks.io): `/fail` se qualcosa non va. Facoltativo, mai bloccante. */
export async function ping(url: string | undefined, ok: boolean, note?: string, fetchImpl: typeof fetch = fetch): Promise<void> {
  if (!url) return;
  try {
    await fetchImpl(ok ? url : `${url.replace(/\/+$/, "")}/fail`, {
      method: "POST",
      body: note ?? "",
      signal: AbortSignal.timeout(5000),
    });
  } catch {
    // Il segnale è un di più: non deve far fallire il backup.
  }
}

/** Oltre questa dimensione il piano gratuito di Supabase (500 MB) è vicino. */
export const DB_WARNING_BYTES = 350 * 1024 * 1024;

export async function checkDatabaseSize(config: SupabaseConfig, fetchImpl: typeof fetch = fetch): Promise<number | undefined> {
  const response = await rpc(config, "db_size_bytes", {}, fetchImpl);
  if (!response.ok) return undefined;
  const bytes = Number(await response.json());
  return Number.isFinite(bytes) ? bytes : undefined;
}
