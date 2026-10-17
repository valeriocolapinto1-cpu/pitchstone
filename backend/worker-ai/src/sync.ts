// Inoltro della sincronizzazione a Supabase (ADR 0002).
// Il Worker è l'unico a conoscere la chiave segreta; il client parla solo con
// il Worker, protetto da Cloudflare Access.

export interface SupabaseConfig {
  url: string;
  secretKey: string;
}

export const MAX_BODY_BYTES = 5 * 1024 * 1024;
export const MAX_CHANGES = 500;
/** Tempo massimo per una chiamata a Supabase. */
export const UPSTREAM_TIMEOUT_MS = 10_000;
const MAX_TITLE_CHARS = 500;
const MAX_TAGS = 50;
const MAX_TAG_CHARS = 100;
const MAX_FILE_NAME_CHARS = 255;
const DEVICE_ID = /^[A-Za-z0-9._-]{1,64}$/;
const ENTITIES = new Set(["node", "edge", "ink_page", "attachment"]);

export class BadRequest extends Error {}
/** Il corpo della richiesta supera il tetto: risposta 413. */
export class PayloadTooLarge extends BadRequest {}

interface Change {
  entity?: unknown;
  data?: unknown;
}

/** Minuscolo, senza spazi né accenti di composizione: "Salute " e "SALUTE" valgono "salute". */
function canonical(value: unknown): string {
  return typeof value === "string" ? value.normalize("NFKC").trim().toLowerCase() : "";
}

/** Difesa in profondità: i dati di salute non devono mai uscire dall'iPad. */
export function validatePush(body: unknown): { deviceId: string; changes: Change[] } {
  if (typeof body !== "object" || body === null) throw new BadRequest("body non valido");
  const { device_id: deviceId, changes } = body as { device_id?: unknown; changes?: unknown };
  if (typeof deviceId !== "string" || !DEVICE_ID.test(deviceId)) throw new BadRequest("device_id non valido");
  if (!Array.isArray(changes)) throw new BadRequest("changes deve essere un array");
  if (changes.length > MAX_CHANGES) throw new BadRequest(`troppe modifiche (max ${MAX_CHANGES})`);
  for (const change of changes as Change[]) {
    if (typeof change !== "object" || change === null) throw new BadRequest("modifica non valida");
    if (typeof change.entity !== "string" || !ENTITIES.has(change.entity)) throw new BadRequest("entity non valida");
    const { data } = change;
    if (typeof data !== "object" || data === null || Array.isArray(data)) throw new BadRequest("data non valido");
    const record = data as Record<string, unknown>;
    if (canonical(record.type) === "health" || canonical(record.area) === "salute") {
      throw new BadRequest("i dati di salute restano sul dispositivo");
    }
    if (record.title !== undefined && (typeof record.title !== "string" || record.title.length > MAX_TITLE_CHARS)) {
      throw new BadRequest("title non valido");
    }
    if (record.file_name !== undefined && record.file_name !== null &&
        (typeof record.file_name !== "string" || record.file_name.length > MAX_FILE_NAME_CHARS)) {
      throw new BadRequest("file_name non valido");
    }
    if (record.tags !== undefined && record.tags !== null) {
      const { tags } = record;
      if (!Array.isArray(tags) || tags.length > MAX_TAGS ||
          tags.some((tag) => typeof tag !== "string" || tag.length > MAX_TAG_CHARS)) {
        throw new BadRequest("tags non validi");
      }
    }
  }
  return { deviceId, changes };
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function validateRedact(body: unknown): string {
  if (typeof body !== "object" || body === null) throw new BadRequest("body non valido");
  const { id } = body as { id?: unknown };
  if (typeof id !== "string" || !UUID.test(id)) throw new BadRequest("id non valido");
  return id.toLowerCase();
}

export function validatePull(body: unknown): { cursor: number; limit: number } {
  if (typeof body !== "object" || body === null) throw new BadRequest("body non valido");
  const { cursor, limit = 500 } = body as { cursor?: unknown; limit?: unknown };
  if (typeof cursor !== "number" || !Number.isSafeInteger(cursor) || cursor < 0) {
    throw new BadRequest("cursor non valido");
  }
  if (typeof limit !== "number" || !Number.isInteger(limit) || limit < 1 || limit > 1000) {
    throw new BadRequest("limit non valido");
  }
  return { cursor, limit };
}

export function authHeaders(config: SupabaseConfig): Record<string, string> {
  const headers: Record<string, string> = { apikey: config.secretKey, "content-type": "application/json" };
  // Le chiavi legacy (JWT) vanno anche in Authorization; le nuove sb_secret_ no.
  if (config.secretKey.startsWith("eyJ")) headers.authorization = `Bearer ${config.secretKey}`;
  return headers;
}

/** Supabase in pausa, irraggiungibile o in errore: non è colpa della richiesta. */
const TRANSIENT = new Set([408, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524, 540]);

/** Chiamata a Supabase con timeout; `retries` ripete una volta sui guasti transitori (solo per letture). */
export async function upstreamFetch(
  fetchImpl: typeof fetch,
  input: URL | string,
  init: RequestInit,
  { retries = 0 }: { retries?: number } = {},
): Promise<Response> {
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await fetchImpl(input, { ...init, signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS) });
      if (response.ok || !TRANSIENT.has(response.status) || attempt >= retries) return response;
    } catch (error) {
      if (attempt >= retries) throw error;
    }
  }
}

/** Codice SQLSTATE dall'errore di PostgREST, se c'è; mai il testo, che può citare i dati. */
async function sqlState(response: Response): Promise<string> {
  try {
    const { code } = (await response.json()) as { code?: unknown };
    return typeof code === "string" && /^[0-9A-Z_]{1,12}$/i.test(code) ? code : "-";
  } catch {
    return "-";
  }
}

/** 503 quando Supabase non c'è (pausa, rete, 5xx), 502 quando risponde con un errore. */
export function upstreamUnavailable(): Response {
  return Response.json({ error: "database non disponibile" }, { status: 503, headers: { "retry-after": "30" } });
}

export async function rpc(
  config: SupabaseConfig,
  fn: string,
  args: Record<string, unknown>,
  fetchImpl: typeof fetch = fetch,
  { retries = 0 }: { retries?: number } = {},
): Promise<Response> {
  let upstream: Response;
  try {
    upstream = await upstreamFetch(
      fetchImpl,
      new URL(`/rest/v1/rpc/${fn}`, config.url),
      { method: "POST", headers: authHeaders(config), body: JSON.stringify(args) },
      { retries },
    );
  } catch (error) {
    console.error(`Supabase ${fn}: ${error instanceof Error ? error.name : "errore"}`);
    return upstreamUnavailable();
  }
  if (!upstream.ok) {
    // Solo stato e SQLSTATE nei log: i corpi possono contenere testo delle note.
    console.error(`Supabase ${fn}: ${upstream.status} ${await sqlState(upstream)}`);
    return upstream.status >= 500 ? upstreamUnavailable() : Response.json({ error: "errore del database" }, { status: 502 });
  }
  return new Response(upstream.body, { status: 200, headers: { "content-type": "application/json" } });
}
