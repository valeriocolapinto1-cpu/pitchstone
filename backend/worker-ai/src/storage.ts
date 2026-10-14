// File degli allegati nel bucket privato `attachments` (ADR 0007).
// Il client non ha chiavi di Supabase: chiede al Worker un URL firmato di breve
// durata per caricare o scaricare una parte, poi la trasferisce direttamente.
import { BadRequest, type SupabaseConfig, rpc } from "./sync";

export const BUCKET = "attachments";
/** Validità di un URL di download, in secondi. */
export const DOWNLOAD_TTL = 300;
/** Un allegato non ha più di 100 parti (vincolo del database). */
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

function headers(config: SupabaseConfig): Record<string, string> {
  const result: Record<string, string> = { apikey: config.secretKey, "content-type": "application/json" };
  // Le chiavi legacy (JWT) vanno anche in Authorization; le nuove sb_secret_ no.
  if (config.secretKey.startsWith("eyJ")) result.authorization = `Bearer ${config.secretKey}`;
  return result;
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
  if (upload) {
    // Solo prima che l'allegato abbia la sua riga: dopo il contenuto non cambia.
    const allowed = await rpc(config, "attachment_upload_allowed", { p_id: path.split("/")[0] }, fetchImpl);
    if (!allowed.ok) return Response.json({ error: "errore del database" }, { status: 502 });
    if ((await allowed.json()) !== true) return Response.json({ error: "allegato già caricato" }, { status: 409 });
  }
  const endpoint = new URL(`object/${upload ? "upload/sign" : "sign"}/${BUCKET}/${path}`, base);
  const upstream = await fetchImpl(endpoint, {
    method: "POST",
    // Upsert: un caricamento interrotto si può ripetere.
    headers: upload ? { ...headers(config), "x-upsert": "true" } : headers(config),
    body: JSON.stringify(upload ? {} : { expiresIn: DOWNLOAD_TTL }),
  });
  if (!upstream.ok) {
    const detail = await upstream.text();
    // Lo storage risponde 400 con "not_found" per un file che non c'è.
    if (upstream.status === 404 || /not.?found/i.test(detail)) {
      return Response.json({ error: "file non trovato" }, { status: 404 });
    }
    console.error(`Storage ${action} ${path}: ${upstream.status} ${detail}`);
    return Response.json({ error: "errore dello storage" }, { status: 502 });
  }
  const json = (await upstream.json()) as { url?: string; signedURL?: string };
  const relative = upload ? json.url : json.signedURL;
  if (typeof relative !== "string" || !relative.startsWith("/")) {
    return Response.json({ error: "risposta dello storage non valida" }, { status: 502 });
  }
  return Response.json({ url: new URL(`/storage/v1${relative}`, config.url).toString(), method: upload ? "PUT" : "GET" });
}

/**
 * Cancella dal bucket i file degli allegati eliminati definitivamente
 * (coda `storage_trash`, riempita da purge_trash). Parte una volta al giorno.
 */
export async function emptyStorageTrash(config: SupabaseConfig, fetchImpl: typeof fetch = fetch): Promise<number> {
  // 10 allegati per volta: al massimo 1.000 parti, il limite di una cancellazione dello storage.
  const listed = await rpc(config, "storage_trash_list", { p_limit: 10 }, fetchImpl);
  if (!listed.ok) return 0;
  const queue = (await listed.json()) as { path: string; part_count: number }[];
  if (queue.length === 0) return 0;
  const prefixes = queue.flatMap(({ path, part_count }) =>
    Array.from({ length: part_count }, (_, i) => `${path}/part-${String(i).padStart(3, "0")}`),
  );
  const removed = await fetchImpl(new URL(`/storage/v1/object/${BUCKET}`, config.url), {
    method: "DELETE",
    headers: headers(config),
    body: JSON.stringify({ prefixes }),
  });
  if (!removed.ok) {
    console.error(`Storage delete: ${removed.status} ${await removed.text()}`);
    return 0;
  }
  const done = await rpc(config, "storage_trash_done", { p_paths: queue.map((item) => item.path) }, fetchImpl);
  return done.ok ? queue.length : 0;
}
