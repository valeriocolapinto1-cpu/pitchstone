import { authenticate, isAllowed, normalizeTeamDomain, parseList, type AccessIdentity } from "./access";
import { backupExists, checkDatabaseSize, dailyBackup, DB_WARNING_BYTES, ping } from "./backup";
import { chat, DEFAULT_MODEL, validateChat } from "./chat";
import { emptyBucket, emptyStorageTrash, removeOrphans, signUrl, validateSign } from "./storage";
import {
  BadRequest, MAX_BODY_BYTES, PayloadTooLarge, rpc, validateErase, validateExport, validatePull, validatePush, validateRedact,
} from "./sync";

/** Il secondo cron rifà solo il backup, se quello delle 04:30 non è riuscito. */
const RECOVERY_CRON = "30 10 * * *";

export interface Env {
  GEMINI_API_KEY?: string;
  GEMINI_MODEL?: string;
  SUPABASE_URL?: string;
  SUPABASE_SECRET_KEY?: string;
  ACCESS_TEAM_DOMAIN?: string;
  ACCESS_AUD?: string;
  /** Allowlist facoltative (separate da virgole): vedi `isAllowed`. Se vuote vale la sola policy di Access. */
  ACCESS_ALLOWED_EMAILS?: string;
  /** Service token ammessi per /sync e /storage (iPad). */
  ACCESS_SYNC_TOKENS?: string;
  /** Service token ammessi per /ai (PC). */
  ACCESS_AI_TOKENS?: string;
  /** Segnale di vita del backup (stile healthchecks.io): ping se riesce, `/fail` se no o se il database è quasi pieno. */
  HEALTHCHECK_URL?: string;
  /** Limite di richieste alla chat per identità (binding Cloudflare). */
  CHAT_LIMITER?: RateLimit;
}

/** Legge il JSON contando i byte reali: né Content-Length né la lunghezza in caratteri bastano. */
async function readJson(request: Request): Promise<unknown> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) throw new PayloadTooLarge("body troppo grande");
  const chunks: Uint8Array[] = [];
  let size = 0;
  const reader = request.body?.getReader();
  while (reader) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY_BYTES) {
      await reader.cancel();
      throw new PayloadTooLarge("body troppo grande");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
  } catch {
    throw new BadRequest("JSON non valido");
  }
}

/**
 * Difesa CSRF: la PWA è sulla stessa origine e il cookie di Access viaggia da solo.
 * Un form di un altro sito non può mandare `application/json` senza preflight, e un browser
 * moderno dichiara la provenienza in Sec-Fetch-Site e in Origin. L'iPad (service token) non manda
 * né l'una né l'altra ma usa sempre JSON.
 */
function crossSite(request: Request): Response | null {
  const site = request.headers.get("sec-fetch-site");
  if (site !== null && site !== "same-origin" && site !== "none") {
    return Response.json({ error: "richiesta da un altro sito" }, { status: 403 });
  }
  const origin = request.headers.get("origin");
  if (origin !== null && origin !== new URL(request.url).origin) {
    return Response.json({ error: "richiesta da un altro sito" }, { status: 403 });
  }
  const type = (request.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  if (type !== "application/json") {
    return Response.json({ error: "serve content-type application/json" }, { status: 415 });
  }
  return null;
}

function label(identity: AccessIdentity): string {
  return identity.email ?? identity.commonName ?? identity.sub ?? "sconosciuto";
}

async function handle(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  if (request.method === "GET" && pathname === "/health") {
    return Response.json({ status: "ok" });
  }

  if (!["/sync/push", "/sync/pull", "/sync/redact", "/storage/sign", "/ai/chat", "/account/export", "/account/erase"].includes(pathname)) {
    return new Response("Not Found", { status: 404 });
  }
  if (request.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405, headers: { allow: "POST" } });
  }
  // Prima i controlli che non costano niente, poi la verifica del token.
  const rejected = crossSite(request);
  if (rejected) return rejected;

  const access = await authenticate(request.headers.get("cf-access-jwt-assertion"), {
    teamDomain: normalizeTeamDomain(env.ACCESS_TEAM_DOMAIN ?? ""),
    audience: env.ACCESS_AUD ?? "",
  });
  if (!access.ok) {
    return access.reason === "unavailable"
      ? Response.json({ error: "verifica di Access non disponibile" }, { status: 503, headers: { "retry-after": "30" } })
      : Response.json({ error: "non autorizzato" }, { status: 401 });
  }
  const route = pathname === "/ai/chat" ? "ai" : "sync";
  const allowed = isAllowed(access.identity, {
    emails: parseList(env.ACCESS_ALLOWED_EMAILS),
    commonNames: parseList(route === "ai" ? env.ACCESS_AI_TOKENS : env.ACCESS_SYNC_TOKENS),
  });
  console.log(`${pathname} ${label(access.identity)} ${allowed ? "ok" : "negato"}`);
  if (!allowed) return Response.json({ error: "non autorizzato" }, { status: 403 });

  try {
    if (pathname === "/ai/chat") {
      if (!env.GEMINI_API_KEY) return Response.json({ error: "Gemini non configurato" }, { status: 503 });
      if (env.CHAT_LIMITER) {
        const { success } = await env.CHAT_LIMITER.limit({ key: label(access.identity) });
        if (!success) return Response.json({ error: "troppe richieste" }, { status: 429, headers: { "retry-after": "60" } });
      }
      return await chat(env.GEMINI_API_KEY, env.GEMINI_MODEL || DEFAULT_MODEL, validateChat(await readJson(request)));
    }
    if (!env.SUPABASE_URL || !env.SUPABASE_SECRET_KEY) {
      return Response.json({ error: "sync non configurata" }, { status: 503 });
    }
    const supabase = { url: env.SUPABASE_URL, secretKey: env.SUPABASE_SECRET_KEY };
    const body = await readJson(request);
    if (pathname === "/storage/sign") {
      const { action, path } = validateSign(body);
      return await signUrl(supabase, action, path);
    }
    if (pathname === "/account/export") {
      // Esportazione completa a pagine: il client le raccoglie in un solo file.
      const { table, after } = validateExport(body);
      return await rpc(supabase, "export_rows", { p_table: table, p_after: after, p_limit: 500, p_max_bytes: 3_000_000 }, fetch, { retries: 1 });
    }
    if (pathname === "/account/erase") {
      validateErase(body);
      return await eraseAccount(supabase);
    }
    if (pathname === "/sync/redact") {
      // Una nota diventata di salute si toglie dal server con storico, archi, pagine e allegati.
      return await rpc(supabase, "redact_node_history", { p_id: validateRedact(body) });
    }
    if (pathname === "/sync/push") {
      const { deviceId, changes } = validatePush(body);
      return await rpc(supabase, "sync_push", { p_device_id: deviceId, p_changes: changes });
    }
    const { cursor, limit } = validatePull(body);
    // Il pull non scrive niente: un guasto transitorio si ripete una volta.
    return await rpc(supabase, "sync_pull", { p_cursor: cursor, p_limit: limit }, fetch, { retries: 1 });
  } catch (error) {
    if (error instanceof PayloadTooLarge) return Response.json({ error: error.message }, { status: 413 });
    if (error instanceof BadRequest) return Response.json({ error: error.message }, { status: 400 });
    throw error;
  }
}

/** Cancella tutto dal server: database, poi file degli allegati e backup. */
async function eraseAccount(supabase: { url: string; secretKey: string }): Promise<Response> {
  const erased = await rpc(supabase, "account_erase", { p_confirm: "cancella-tutto" });
  if (!erased.ok) return erased;
  const result = (await erased.json()) as { nodes: number; epoch: number };
  // Il database è già vuoto: se i file non si riescono a togliere lo si dice, non si finge.
  const attachments = await emptyBucket(supabase, "attachments");
  const backups = await emptyBucket(supabase, "backups");
  return Response.json({ database: true, ...result, storage: attachments !== undefined && backups !== undefined });
}

/** Ogni risposta: mai in cache, tipo dichiarato. Un errore imprevisto diventa JSON con un id per i log. */
function secure(response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set("cache-control", "no-store");
  headers.set("x-content-type-options", "nosniff");
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

export default {
  async fetch(request, env): Promise<Response> {
    try {
      return secure(await handle(request, env));
    } catch (error) {
      const requestId = crypto.randomUUID();
      // Solo il tipo dell'errore: il messaggio potrebbe citare i dati della richiesta.
      console.error(`${requestId} ${new URL(request.url).pathname} ${error instanceof Error ? error.name : "errore"}`);
      return secure(Response.json({ error: "errore interno", request_id: requestId }, { status: 500 }));
    }
  },

  // Ogni giorno, dopo la pulizia del cestino nel database (03:00 UTC): file degli allegati
  // eliminati e orfani, poi il backup giornaliero. Il secondo cron rifà solo il backup, se manca.
  async scheduled(controller, env): Promise<void> {
    if (!env.SUPABASE_URL || !env.SUPABASE_SECRET_KEY) return;
    const supabase = { url: env.SUPABASE_URL, secretKey: env.SUPABASE_SECRET_KEY };
    const now = new Date(controller.scheduledTime);
    if (controller.cron === RECOVERY_CRON) {
      if (await backupExists(supabase, now)) return;
      await ping(env.HEALTHCHECK_URL, (await dailyBackup(supabase, now)) === "saved", "recupero");
      return;
    }
    // Il backup parte anche se la pulizia fallisce; si aspetta tutto (niente waitUntil) così gli errori restano nel run.
    await Promise.allSettled([emptyStorageTrash(supabase), removeOrphans(supabase, now)]);
    const result = await dailyBackup(supabase, now);
    const size = await checkDatabaseSize(supabase);
    if (size !== undefined && size > DB_WARNING_BYTES) {
      console.error(`Database a ${Math.round(size / 1048576)} MB: il piano gratuito si ferma a 500 MB`);
      await ping(env.HEALTHCHECK_URL, false, `database a ${Math.round(size / 1048576)} MB`);
    } else if (result === "saved") {
      await ping(env.HEALTHCHECK_URL, true);
    } else {
      await ping(env.HEALTHCHECK_URL, false, `backup ${result}`);
    }
  },
} satisfies ExportedHandler<Env>;
