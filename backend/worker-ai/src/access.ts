// Verifica del JWT di Cloudflare Access (header Cf-Access-Jwt-Assertion).
// Access lo aggiunge a ogni richiesta autorizzata, sia con login Google sia con
// service token. Verificarlo nel Worker impedisce di aggirare Access, per
// esempio chiamando direttamente l'indirizzo *.workers.dev.

export interface AccessConfig {
  teamDomain: string; // https://<team>.cloudflareaccess.com
  audience: string; // AUD tag dell'applicazione Access
}

interface Jwk extends JsonWebKey {
  kid: string;
}

interface JwtHeader {
  alg: string;
  kid: string;
}

interface JwtPayload {
  iss?: string;
  aud?: string | string[];
  exp?: number;
  nbf?: number;
}

const CERTS_TTL_MS = 60 * 60 * 1000;
// Un token con kid sconosciuto forza al massimo un aggiornamento al minuto.
const FORCED_REFRESH_MS = 60 * 1000;
let certsCache: { url: string; keys: Jwk[]; fetchedAt: number } | undefined;

export function resetCertsCache(): void {
  certsCache = undefined;
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

async function loadKeys(config: AccessConfig, fetchImpl: typeof fetch, forceRefresh: boolean): Promise<Jwk[]> {
  const url = `${config.teamDomain}/cdn-cgi/access/certs`;
  if (certsCache && certsCache.url === url) {
    const age = Date.now() - certsCache.fetchedAt;
    if (age < (forceRefresh ? FORCED_REFRESH_MS : CERTS_TTL_MS)) return certsCache.keys;
  }
  const response = await fetchImpl(url);
  if (!response.ok) throw new Error(`certs ${response.status}`);
  const { keys } = (await response.json()) as { keys: Jwk[] };
  certsCache = { url, keys, fetchedAt: Date.now() };
  return keys;
}

/** Ritorna true solo se il token è firmato da Access per questa applicazione e non è scaduto. */
export async function verifyAccessJwt(
  token: string | null,
  config: AccessConfig,
  fetchImpl: typeof fetch = fetch,
  now: number = Date.now(),
): Promise<boolean> {
  if (!token || !config.teamDomain || !config.audience) return false;
  const parts = token.split(".");
  if (parts.length !== 3) return false;

  let header: JwtHeader;
  let payload: JwtPayload;
  try {
    header = decodeJson<JwtHeader>(parts[0]);
    payload = decodeJson<JwtPayload>(parts[1]);
  } catch {
    return false;
  }
  if (header.alg !== "RS256") return false;

  const seconds = now / 1000;
  const audiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (payload.iss !== config.teamDomain) return false;
  if (!audiences.includes(config.audience)) return false;
  if (typeof payload.exp !== "number" || payload.exp <= seconds) return false;
  if (typeof payload.nbf === "number" && payload.nbf > seconds + 60) return false;

  // Chiave non in cache: le chiavi di Access ruotano, si riprova una volta.
  let jwk = (await loadKeys(config, fetchImpl, false)).find((k) => k.kid === header.kid);
  if (!jwk) jwk = (await loadKeys(config, fetchImpl, true)).find((k) => k.kid === header.kid);
  if (!jwk) return false;

  const key = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  return crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    base64UrlDecode(parts[2]),
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
}
