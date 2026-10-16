// Backup giornaliero (ADR 0012): un'istantanea JSON di nodi, archi, pagine a penna e
// metadati degli allegati nel bucket privato `backups`, tenuta per 14 giorni.
// I file degli allegati sono già nel bucket `attachments`.
import { type SupabaseConfig, rpc } from "./sync";
import { headers } from "./storage";

export const BACKUP_BUCKET = "backups";
export const KEEP_DAYS = 14;

interface Snapshot {
  format?: string;
  nodes?: { type?: string; area?: string }[];
}

/** Difesa in profondità: un'istantanea con un dato di salute non si salva. */
export function containsHealth(snapshot: Snapshot): boolean {
  return (snapshot.nodes ?? []).some((node) => node.type === "health" || node.area === "salute");
}

export function backupName(date: Date): string {
  return `${date.toISOString().slice(0, 10)}.json`;
}

/** Nomi dei backup più vecchi di `KEEP_DAYS` giorni rispetto a `now`. */
export function expired(names: string[], now: Date): string[] {
  const limit = new Date(now.getTime() - KEEP_DAYS * 86_400_000).toISOString().slice(0, 10);
  return names.filter((name) => /^\d{4}-\d{2}-\d{2}\.json$/.test(name) && name.slice(0, 10) <= limit);
}

export async function dailyBackup(
  config: SupabaseConfig,
  now: Date = new Date(),
  fetchImpl: typeof fetch = fetch,
  { expire = true }: { expire?: boolean } = {},
): Promise<"saved" | "failed" | "refused"> {
  const snapshot = await rpc(config, "backup_snapshot", {}, fetchImpl);
  if (!snapshot.ok) {
    console.error(`Backup: snapshot ${snapshot.status}`);
    return "failed";
  }
  const body = await snapshot.text();
  let parsed: Snapshot;
  try {
    parsed = JSON.parse(body) as Snapshot;
  } catch {
    console.error("Backup: istantanea illeggibile");
    return "failed";
  }
  if (parsed.format !== "pitchstone-backup" || containsHealth(parsed)) {
    console.error("Backup rifiutato: formato inatteso o dati di salute");
    return "refused";
  }
  const object = new URL(`/storage/v1/object/${BACKUP_BUCKET}/${backupName(now)}`, config.url);
  const saved = await fetchImpl(object, {
    method: "POST",
    headers: { ...headers(config), "x-upsert": "true" },
    body,
  });
  if (!saved.ok) {
    console.error(`Backup: upload ${saved.status} ${await saved.text()}`);
    return "failed";
  }
  if (expire) await removeExpired(config, now, fetchImpl);
  return "saved";
}

async function removeExpired(config: SupabaseConfig, now: Date, fetchImpl: typeof fetch): Promise<void> {
  const listed = await fetchImpl(new URL(`/storage/v1/object/list/${BACKUP_BUCKET}`, config.url), {
    method: "POST",
    headers: headers(config),
    body: JSON.stringify({ prefix: "", limit: 1000, sortBy: { column: "name", order: "asc" } }),
  });
  if (!listed.ok) return;
  const names = ((await listed.json()) as { name: string }[]).map((item) => item.name);
  const old = expired(names, now);
  if (old.length === 0) return;
  await fetchImpl(new URL(`/storage/v1/object/${BACKUP_BUCKET}`, config.url), {
    method: "DELETE",
    headers: headers(config),
    body: JSON.stringify({ prefixes: old }),
  });
}
