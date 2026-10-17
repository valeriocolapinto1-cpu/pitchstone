// Verifica del JWT di Cloudflare Access (header Cf-Access-Jwt-Assertion).
// Access lo aggiunge a ogni richiesta autorizzata, sia con login Google sia con
// service token. Verificarlo nel Worker impedisce di aggirare Access, per
// esempio chiamando direttamente l'indirizzo *.workers.dev.

/** "team.cloudflareaccess.com", con o senza https:// e barra finale, diventa "https://team.cloudflareaccess.com". */
export function normalizeTeamDomain(value: string): string {
  const trimmed = value.trim().replace(/\/+$/, "");
  if (!trimmed) return "";
  return /^https?:\/\//.test(trimmed) ? trimmed : `https://${trimmed}`;
}

export interface AccessConfig {
  teamDomain: string; // https://<team>.cloudflareaccess.com
  audience: string; // AUD tag dell'applicazione Access
}

/** Chi ha fatto la richiesta: `email` per un login Google, `commonName` per un service token. */
export interface AccessIdentity {
  email?: string;
  commonName?: string;
  sub?: string;
}

export type AccessResult =
  | { ok: true; identity: AccessIdentity }
  // `unavailable`: non si è potuto verificare (chiavi di Access irraggiungibili), non è un rifiuto.
  | { ok: false; reason: "unauthorized" | "unavailable" };

interface Jwk extends JsonWebKey {
  kid: string;
}

interface JwtHeader {
  alg: string;
  kid: string;
  typ?: string;
}

interface JwtPayload {
  iss?: string;
  aud?: string | string[];
  exp?: number;
  nbf?: number;
  iat?: number;
  email?: string;
  common_name?: string;
  sub?: string;
}

const CERTS_TTL_MS = 60 * 60 * 1000;
// Se Access non risponde si usano per un giorno le ultime chiavi buone.
const CERTS_STALE_MS = 24 * 60 * 60 * 1000;
const CERTS_TIMEOUT_MS = 3000;
// Un token con kid sconosciuto forza al massimo un aggiornamento al minuto.
const FORCED_REFRESH_MS = 60 * 1000;
const CLOCK_SKEW_SECONDS = 60;
let certsCache: { url: string; keys: Jwk[]; fetchedAt: number } | undefined;
// kid già visti come sconosciuti: non si rilanciano richieste a ogni token falso.
let unknownKids = new Map<string, number>();

export function resetCertsCache(): void {
  certsCache = undefined;
  unknownKids = new Map();
}

function base64UrlDecode(input: string): Uint8Array<ArrayBuffer> {
  const base64 = input.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function decodeJson<T>(part: string): T {
  return JSON.parse(new TextDecoder().decode(base64UrlDecode(part))) as T;
}

/** Chiavi di Access, o `undefined` se non si riesce a ottenerle (né dalla rete né da una cache non troppo vecchia). */
async function loadKeys(
  config: AccessConfig,
  fetchImpl: typeof fetch,
  forceRefresh: boolean,
  now: number,
): Promise<Jwk[] | undefined> {
  const url = `${config.teamDomain}/cdn-cgi/access/certs`;
  const cached = certsCache && certsCache.url === url ? certsCache : undefined;
  if (cached && now - cached.fetchedAt < (forceRefresh ? FORCED_REFRESH_MS : CERTS_TTL_MS)) return cached.keys;
  try {
    const response = await fetchImpl(url, { signal: AbortSignal.timeout(CERTS_TIMEOUT_MS) });
    if (!response.ok) throw new Error(`certs ${response.status}`);
    const { keys } = (await response.json()) as { keys?: unknown };
    if (!Array.isArray(keys)) throw new Error("certs: formato inatteso");
    certsCache = { url, keys: keys as Jwk[], fetchedAt: now };
    return certsCache.keys;
  } catch (error) {
    console.error(`Access: chiavi non disponibili (${error instanceof Error ? error.name : "errore"})`);
    if (cached && now - cached.fetchedAt < CERTS_STALE_MS) return cached.keys;
    return undefined;
  }
}

/** Verifica il token di Access: firma, issuer, audience, scadenza. Restituisce l'identità o il motivo del rifiuto. */
export async function authenticate(
  token: string | null,
  config: AccessConfig,
  fetchImpl: typeof fetch = fetch,
  now: number = Date.now(),
): Promise<AccessResult> {
  const denied: AccessResult = { ok: false, reason: "unauthorized" };
  if (!token || !config.teamDomain || !config.audience) return denied;
  const parts = token.split(".");
  if (parts.length !== 3) return denied;

  let header: JwtHeader;
  let payload: JwtPayload;
  try {
    header = decodeJson<JwtHeader>(parts[0]);
    payload = decodeJson<JwtPayload>(parts[1]);
  } catch {
    return denied;
  }
  if (header.alg !== "RS256") return denied;
  if (header.typ !== undefined && header.typ !== "JWT") return denied;

  const seconds = now / 1000;
  const audiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (payload.iss !== config.teamDomain) return denied;
  if (!audiences.includes(config.audience)) return denied;
  if (typeof payload.exp !== "number" || payload.exp <= seconds - CLOCK_SKEW_SECONDS) return denied;
  if (typeof payload.nbf === "number" && payload.nbf > seconds + CLOCK_SKEW_SECONDS) return denied;
  if (typeof payload.iat === "number" && payload.iat > seconds + CLOCK_SKEW_SECONDS) return denied;

  const kid = typeof header.kid === "string" ? header.kid : "";
  const knownUnknown = (unknownKids.get(kid) ?? 0) > now;
  let keys = await loadKeys(config, fetchImpl, false, now);
  if (!keys) return { ok: false, reason: "unavailable" };
  let jwk = keys.find((k) => k.kid === kid);
  // Chiave non in cache: le chiavi di Access ruotano, si riprova una volta (ma non per un kid già respinto).
  if (!jwk && !knownUnknown) {
    keys = await loadKeys(config, fetchImpl, true, now);
    if (!keys) return { ok: false, reason: "unavailable" };
    jwk = keys.find((k) => k.kid === kid);
  }
  if (!jwk) {
    unknownKids.set(kid, now + FORCED_REFRESH_MS);
    return denied;
  }

  let valid: boolean;
  try {
    const key = await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    valid = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      key,
      base64UrlDecode(parts[2]),
      new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
    );
  } catch {
    return denied;
  }
  if (!valid) return denied;
  return { ok: true, identity: { email: payload.email, commonName: payload.common_name, sub: payload.sub } };
}

/** Ritorna true solo se il token è firmato da Access per questa applicazione e non è scaduto. */
export async function verifyAccessJwt(
  token: string | null,
  config: AccessConfig,
  fetchImpl: typeof fetch = fetch,
  now: number = Date.now(),
): Promise<boolean> {
  return (await authenticate(token, config, fetchImpl, now)).ok;
}

export interface AccessPolicy {
  /** Email ammesse (login Google). */
  emails: string[];
  /** Service token ammessi per questo gruppo di route. */
  commonNames: string[];
}

/** "a@x.it, b@x.it" diventa ["a@x.it", "b@x.it"]; il confronto non distingue le maiuscole. */
export function parseList(value: string | undefined): string[] {
  return (value ?? "").split(",").map((item) => item.trim().toLowerCase()).filter(Boolean);
}

/**
 * Difesa in più rispetto alla policy di Access: se è configurata un'allowlist l'identità deve
 * comparirvi. Senza allowlist (né email né service token) basta il token valido.
 */
export function isAllowed(identity: AccessIdentity, policy: AccessPolicy): boolean {
  if (policy.emails.length === 0 && policy.commonNames.length === 0) return true;
  if (identity.email && policy.emails.includes(identity.email.toLowerCase())) return true;
  if (identity.commonName && policy.commonNames.includes(identity.commonName.toLowerCase())) return true;
  return false;
}
