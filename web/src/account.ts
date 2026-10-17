// Dati dell'utente: esportazione completa, cancellazione dal server e dal computer.
import { AuthError } from "./sync";
import type { Store } from "./store";

export const ERASE_CONFIRMATION = "cancella-tutto";
const TABLES = ["nodes", "edges", "node_versions", "attachments", "ink_pages", "purged"] as const;

type FetchFn = (input: string, init?: RequestInit) => Promise<Response>;

async function post<T>(fetchFn: FetchFn, path: string, body: unknown): Promise<T> {
  const response = await fetchFn(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
    credentials: "include",
    redirect: "manual",
  });
  if (response.type === "opaqueredirect" || response.status === 401 || response.status === 403) throw new AuthError("login scaduto");
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return (await response.json()) as T;
}

export interface ExportFile {
  format: "pitchstone-export";
  version: 1;
  exported_at: string;
  tables: Record<string, Record<string, unknown>[]>;
}

/** Tutto ciò che il server ha dell'utente, pagina per pagina: cestino, storico e disegni compresi. */
export async function exportEverything(fetchFn: FetchFn, now: () => Date = () => new Date()): Promise<ExportFile> {
  const tables: ExportFile["tables"] = {};
  for (const table of TABLES) {
    const rows: Record<string, unknown>[] = [];
    let after: string | null = null;
    for (;;) {
      const page: { rows: Record<string, unknown>[]; last: string | null; more: boolean } = await post(fetchFn, "/account/export", { table, after });
      rows.push(...page.rows);
      if (!page.more || !page.last) break;
      after = page.last;
    }
    tables[table] = rows;
  }
  return { format: "pitchstone-export", version: 1, exported_at: now().toISOString(), tables };
}

export interface EraseResult {
  database: boolean;
  nodes: number;
  epoch: number;
  /** Falso se i file degli allegati o i backup non si sono potuti togliere. */
  storage: boolean;
}

/** "Cancella tutto dal server": database, file degli allegati e backup. */
export function eraseServer(fetchFn: FetchFn): Promise<EraseResult> {
  return post(fetchFn, "/account/erase", { confirm: ERASE_CONFIRMATION });
}

/** Cancella dal computer l'archivio, le preferenze e la copia dell'app in cache. */
export async function clearLocal(
  store: Pick<Store, "wipe">,
  env: {
    storage?: Pick<Storage, "clear">;
    caches?: Pick<CacheStorage, "keys" | "delete">;
    registrations?: () => Promise<readonly { unregister(): Promise<boolean> }[]>;
  } = {
    storage: typeof localStorage === "undefined" ? undefined : localStorage,
    caches: typeof caches === "undefined" ? undefined : caches,
    registrations: typeof navigator === "undefined" || !navigator.serviceWorker ? undefined : () => navigator.serviceWorker.getRegistrations(),
  },
): Promise<void> {
  await store.wipe();
  try { env.storage?.clear(); } catch { /* archivio non disponibile */ }
  try {
    if (env.caches) for (const key of await env.caches.keys()) await env.caches.delete(key);
    if (env.registrations) for (const registration of await env.registrations()) await registration.unregister();
  } catch { /* la cache non è dati dell'utente: se non si cancella, pazienza */ }
}
