// Inoltro della sincronizzazione a Supabase (ADR 0002).
// Il Worker è l'unico a conoscere la chiave segreta; il client parla solo con
// il Worker, protetto da Cloudflare Access.

export interface SupabaseConfig {
  url: string;
  secretKey: string;
}

export const MAX_BODY_BYTES = 5 * 1024 * 1024;
export const MAX_CHANGES = 500;

export class BadRequest extends Error {}

interface Change {
  entity?: unknown;
  data?: { type?: unknown; area?: unknown } | null;
}

/** Difesa in profondità: i dati di salute non devono mai uscire dall'iPad. */
export function validatePush(body: unknown): { deviceId: string; changes: Change[] } {
  if (typeof body !== "object" || body === null) throw new BadRequest("body non valido");
  const { device_id: deviceId, changes } = body as { device_id?: unknown; changes?: unknown };
  if (typeof deviceId !== "string" || deviceId.length === 0 || deviceId.length > 100) {
    throw new BadRequest("device_id non valido");
  }
  if (!Array.isArray(changes)) throw new BadRequest("changes deve essere un array");
  if (changes.length > MAX_CHANGES) throw new BadRequest(`troppe modifiche (max ${MAX_CHANGES})`);
  for (const change of changes as Change[]) {
    if (typeof change !== "object" || change === null) throw new BadRequest("modifica non valida");
    if (change.data?.type === "health" || change.data?.area === "salute") {
      throw new BadRequest("i dati di salute restano sul dispositivo");
    }
  }
  return { deviceId, changes };
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

export async function rpc(
  config: SupabaseConfig,
  fn: string,
  args: Record<string, unknown>,
  fetchImpl: typeof fetch = fetch,
): Promise<Response> {
  const headers: Record<string, string> = {
    apikey: config.secretKey,
    "content-type": "application/json",
  };
  // Le chiavi legacy (JWT) vanno anche in Authorization; le nuove sb_secret_ no.
  if (config.secretKey.startsWith("eyJ")) headers.authorization = `Bearer ${config.secretKey}`;
  const upstream = await fetchImpl(new URL(`/rest/v1/rpc/${fn}`, config.url), {
    method: "POST",
    headers,
    body: JSON.stringify(args),
  });
  if (!upstream.ok) {
    // Il dettaglio resta nei log del Worker, non va al client.
    console.error(`Supabase ${fn}: ${upstream.status} ${await upstream.text()}`);
    return Response.json({ error: "errore del database" }, { status: 502 });
  }
  return new Response(upstream.body, { status: 200, headers: { "content-type": "application/json" } });
}
