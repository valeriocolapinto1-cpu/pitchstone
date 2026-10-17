// File degli allegati nel bucket privato `attachments` (ADR 0007).
// Il client non ha chiavi di Supabase: chiede al Worker un URL firmato di breve
// durata per caricare o scaricare una parte, poi la trasferisce direttamente.
import { BadRequest, type SupabaseConfig, authHeaders, rpc, upstreamFetch, upstreamUnavailable } from "./sync";

export const BUCKET = "attachments";
/** Validità di un URL di download, in secondi. */
export const DOWNLOAD_TTL = 300;
/** Un allegato non ha più di 100 parti (vincolo del database). */
const ATTACHMENT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PART_PATH = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/part-(\d{3})$/;

export type SignAction = "upload" | "download";

export function validateSign(body: unknown): { action: SignAction; path: string } {
  if (typeof body !== "object" || body === null) throw new BadRequest("body non valido");
  const { action, path } = body as { action?: unknown; path?: unknown };
  if (action !== "upload" && action !== "download") throw new BadRequest("action non valida");
  if (typeof path !== "string") throw new BadRequest("path non valido");
  const match = PART_PATH.exec(path);
  if (!match || Number(match[1]) >= 100) throw new BadRequest("path non valido");
  return { action, path };
}

export function headers(config: SupabaseConfig): Record<string, string> {
  return authHeaders(config);
}

/** URL firmato per una parte: PUT per caricarla, GET per scaricarla. */
export async function signUrl(
  config: SupabaseConfig,
  action: SignAction,
  path: string,
  fetchImpl: typeof fetch = fetch,
): Promise<Response> {
  const base = new URL("/storage/v1/", config.url);
  const upload = action === "upload";
  const id = path.split("/")[0];
  // Il caricamento è ammesso solo prima che l'allegato abbia la sua riga (dopo il contenuto non
  // cambia, e l'upsert serve solo a ripetere un caricamento interrotto); il download solo se la riga
  // esiste e non è nel cestino.
  const check = await rpc(config, upload ? "attachment_upload_allowed" : "attachment_download_allowed", { p_id: id }, fetchImpl);
  if (!check.ok) return check;
  if ((await check.json()) !== true) {
    return upload
      ? Response.json({ error: "allegato già caricato" }, { status: 409 })
      : Response.json({ error: "file non trovato" }, { status: 404 });
  }
  const endpoint = new URL(`object/${upload ? "upload/sign" : "sign"}/${BUCKET}/${path}`, base);
  let upstream: Response;
  try {
    upstream = await upstreamFetch(fetchImpl, endpoint, {
      method: "POST",
      headers: upload ? { ...headers(config), "x-upsert": "true" } : headers(config),
      body: JSON.stringify(upload ? {} : { expiresIn: DOWNLOAD_TTL }),
    });
  } catch (error) {
    console.error(`Storage ${action}: ${error instanceof Error ? error.name : "errore"}`);
    return upstreamUnavailable();
  }
  if (!upstream.ok) {
    // Lo storage risponde 400 con "not_found" per un file che non c'è.
    const detail = upstream.status === 404 ? "" : await upstream.text();
    if (upstream.status === 404 || /not.?found/i.test(detail)) {
      return Response.json({ error: "file non trovato" }, { status: 404 });
    }
    // Né il percorso né il corpo dell'errore nei log.
    console.error(`Storage ${action}: ${upstream.status}`);
    return upstream.status >= 500 ? upstreamUnavailable() : Response.json({ error: "errore dello storage" }, { status: 502 });
  }
  const json = (await upstream.json()) as { url?: string; signedURL?: string };
  const relative = upload ? json.url : json.signedURL;
  if (typeof relative !== "string" || !relative.startsWith("/")) {
    return Response.json({ error: "risposta dello storage non valida" }, { status: 502 });
  }
  return Response.json({ url: new URL(`/storage/v1${relative}`, config.url).toString(), method: upload ? "PUT" : "GET" });
}

/** Tentativi di cancellazione di un file in coda prima che resti da parte (lo vede il server). */
const MAX_TRASH_ROUNDS = 20;

/**
 * Cancella dal bucket i file degli allegati eliminati definitivamente
 * (coda `storage_trash`, riempita da purge_trash). Parte una volta al giorno e
 * ripete finché la coda è vuota; un lotto che fallisce ha il contatore dei tentativi aumentato.
 */
export async function emptyStorageTrash(
  config: SupabaseConfig,
  fetchImpl: typeof fetch = fetch,
  minAge = "15 days",
): Promise<number> {
  let total = 0;
  for (let round = 0; round < MAX_TRASH_ROUNDS; round++) {
    // 10 allegati per volta: al massimo 1.000 parti, il limite di una cancellazione dello storage.
    // Solo file in coda da più dei 14 giorni dei backup (ADR 0012), che altrimenti li perderebbero.
    const listed = await rpc(config, "storage_trash_list", { p_limit: 10, p_min_age: minAge }, fetchImpl);
    if (!listed.ok) return total;
    const queue = (await listed.json()) as { path: string; part_count: number }[];
    if (queue.length === 0) return total;
    const paths = queue.map((item) => item.path);
    const prefixes = queue.flatMap(({ path, part_count }) =>
      Array.from({ length: part_count }, (_, i) => `${path}/part-${String(i).padStart(3, "0")}`),
    );
    let removed: Response | undefined;
    try {
      removed = await upstreamFetch(fetchImpl, new URL(`/storage/v1/object/${BUCKET}`, config.url), {
        method: "DELETE",
        headers: headers(config),
        body: JSON.stringify({ prefixes }),
      });
    } catch (error) {
      console.error(`Storage delete: ${error instanceof Error ? error.name : "errore"}`);
    }
    if (!removed?.ok) {
      if (removed) console.error(`Storage delete: ${removed.status}`);
      await rpc(config, "storage_trash_failed", { p_paths: paths }, fetchImpl);
      continue;
    }
    const done = await rpc(config, "storage_trash_done", { p_paths: paths }, fetchImpl);
    if (!done.ok) return total;
    total += queue.length;
  }
  return total;
}

interface StorageEntry {
  name: string;
  id: string | null;
  created_at?: string | null;
}

async function listBucket(config: SupabaseConfig, prefix: string, limit: number, fetchImpl: typeof fetch): Promise<StorageEntry[] | undefined> {
  try {
    const response = await upstreamFetch(fetchImpl, new URL(`/storage/v1/object/list/${BUCKET}`, config.url), {
      method: "POST",
      headers: headers(config),
      body: JSON.stringify({ prefix, limit, offset: 0, sortBy: { column: "name", order: "asc" } }),
    });
    return response.ok ? ((await response.json()) as StorageEntry[]) : undefined;
  } catch {
    return undefined;
  }
}

/**
 * File caricati ma senza riga dopo più di `maxAge` (un caricamento mai concluso, un allegato rifiutato):
 * si cancellano per non riempire il bucket. Non tocca i file in coda per la cancellazione (restano per i backup).
 */
export async function removeOrphans(
  config: SupabaseConfig,
  now: Date = new Date(),
  fetchImpl: typeof fetch = fetch,
  maxAgeMs = 24 * 60 * 60 * 1000,
): Promise<number> {
  const top = await listBucket(config, "", 200, fetchImpl);
  const ids = (top ?? []).map((entry) => entry.name).filter((name) => ATTACHMENT_ID.test(name));
  if (ids.length === 0) return 0;
  const missing = await rpc(config, "attachments_without_row", { p_ids: ids }, fetchImpl);
  if (!missing.ok) return 0;
  const orphans = (await missing.json()) as string[];
  let removed = 0;
  for (const id of orphans) {
    const files = await listBucket(config, id, 100, fetchImpl);
    if (!files || files.length === 0) continue;
    const recent = files.some((file) => !file.created_at || now.getTime() - Date.parse(file.created_at) < maxAgeMs);
    if (recent) continue;
    try {
      const response = await upstreamFetch(fetchImpl, new URL(`/storage/v1/object/${BUCKET}`, config.url), {
        method: "DELETE",
        headers: headers(config),
        body: JSON.stringify({ prefixes: files.map((file) => `${id}/${file.name}`) }),
      });
      if (response.ok) removed += 1;
    } catch {
      // Si riprova al prossimo giro.
    }
  }
  return removed;
}
