// Verifica e ripristino di un backup (Fase 2). Gira in Node (scripts/restore.ts) e nei test: usa solo
// fetch. Prima di toccare il database scarica tutti i file del backup e ne controlla sha256, dimensione e
// conteggi sul manifest: un backup incompleto o alterato non si ripristina.
import { BACKUP_BUCKET, type BackupFile, type Manifest } from "./backup";
import { headers } from "./storage";
import { type SupabaseConfig, rpc, upstreamFetch } from "./sync";

/** Ordine che rispetta le chiavi esterne: nodi, poi ciò che li cita. */
const RESTORE_ORDER = ["nodes", "edges", "node_versions", "attachments", "ink_pages", "purged"] as const;
const BATCH_ROWS = 200;
export const WIPE_CONFIRMATION = "cancella-tutto";

export interface LoadedBackup {
  manifest: Manifest;
  tables: Record<string, Record<string, unknown>[]>;
  ink: { id: string; ink_data: string }[];
}

async function download(config: SupabaseConfig, path: string, fetchImpl: typeof fetch): Promise<string> {
  const response = await upstreamFetch(fetchImpl, new URL(`/storage/v1/object/${BACKUP_BUCKET}/${path}`, config.url), {
    headers: headers(config),
  });
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
  return response.text();
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** Scarica e verifica un backup (`2026-10-15/043012-ab12`). Lancia se qualcosa non torna. */
export async function loadBackup(config: SupabaseConfig, run: string, fetchImpl: typeof fetch = fetch): Promise<LoadedBackup> {
  const manifest = JSON.parse(await download(config, `${run}/manifest.json`, fetchImpl)) as Manifest;
  if (manifest.format !== "pitchstone-backup" || manifest.version !== 2) throw new Error("manifest non riconosciuto");
  const tables: LoadedBackup["tables"] = Object.fromEntries(RESTORE_ORDER.map((table) => [table, []]));
  const ink: LoadedBackup["ink"] = [];
  for (const file of manifest.files as BackupFile[]) {
    const body = await download(config, file.path, fetchImpl);
    const bytes = new TextEncoder().encode(body);
    if (bytes.byteLength !== file.bytes) throw new Error(`${file.path}: dimensione diversa dal manifest`);
    if ((await sha256(bytes)) !== file.sha256) throw new Error(`${file.path}: sha256 diverso dal manifest`);
    const rows = JSON.parse(body) as Record<string, unknown>[];
    if (rows.length !== file.rows) throw new Error(`${file.path}: righe diverse dal manifest`);
    if (file.table === "ink_data") ink.push(...(rows as unknown as LoadedBackup["ink"]));
    else if (file.table in tables) tables[file.table].push(...rows);
    else throw new Error(`${file.path}: tabella sconosciuta`);
  }
  for (const table of RESTORE_ORDER) {
    if (tables[table].length !== manifest.counts[table]) throw new Error(`${table}: ${tables[table].length} righe invece di ${manifest.counts[table]}`);
  }
  if (ink.length !== manifest.counts.ink_pages) throw new Error("disegni diversi dalle pagine");
  if (tables.nodes.some((node) => node.type === "health" || node.area === "salute")) throw new Error("il backup contiene dati di salute");
  return { manifest, tables, ink };
}

export interface RestoreOptions {
  /** Svuota prima le tabelle sincronizzate (serve `confirm`). */
  wipe?: boolean;
  confirm?: string;
  log?: (message: string) => void;
}

/** Ripristina un backup. Restituisce la nuova epoca della sincronizzazione. */
export async function restoreBackup(
  config: SupabaseConfig,
  run: string,
  { wipe = false, confirm, log = () => {} }: RestoreOptions = {},
  fetchImpl: typeof fetch = fetch,
): Promise<number> {
  if (wipe && confirm !== WIPE_CONFIRMATION) throw new Error(`per svuotare serve la conferma "${WIPE_CONFIRMATION}"`);
  // Tutto in memoria e verificato prima di scrivere: se il backup è guasto il database resta com'è.
  const backup = await loadBackup(config, run, fetchImpl);
  log(`Backup ${run} verificato: ${JSON.stringify(backup.manifest.counts)}`);

  const call = async (fn: string, args: Record<string, unknown>): Promise<unknown> => {
    const response = await rpc(config, fn, args, fetchImpl);
    if (!response.ok) throw new Error(`${fn}: ${response.status}`);
    // Le funzioni che restituiscono void rispondono senza corpo.
    const text = await response.text();
    return text === "" ? null : JSON.parse(text);
  };

  if (wipe) {
    await call("backup_restore_wipe", { p_confirm: WIPE_CONFIRMATION });
    log("Tabelle svuotate");
  }
  for (const table of RESTORE_ORDER) {
    const rows = backup.tables[table];
    for (let i = 0; i < rows.length; i += BATCH_ROWS) {
      await call("backup_restore_rows", { p_table: table, p_rows: rows.slice(i, i + BATCH_ROWS) });
    }
    log(`${table}: ${rows.length} righe`);
  }
  for (let i = 0; i < backup.ink.length; i += 20) {
    await call("backup_restore_ink", { p_rows: backup.ink.slice(i, i + 20) });
  }
  const counts = (await call("backup_counts", {})) as Record<string, number>;
  for (const table of RESTORE_ORDER) {
    const expected = backup.manifest.counts[table];
    const actual = counts[table];
    // Senza svuotare, il database può avere righe in più; con lo svuotamento deve coincidere.
    if (wipe ? actual !== expected : actual < expected) {
      throw new Error(`dopo il ripristino ${table} ha ${actual} righe, ne erano attese ${expected}`);
    }
  }
  const epoch = Number(await call("backup_restore_finish", {}));
  log(`Ripristino concluso: epoca di sincronizzazione ${epoch}`);
  return epoch;
}
