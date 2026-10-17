// Ripristino di un backup dal bucket `backups` (runbook: docs/runbook.md).
//
//   SUPABASE_URL=https://<progetto>.supabase.co SUPABASE_SECRET_KEY=... \
//     npm run restore -- --latest --verify          # solo verifica, non tocca il database
//   npm run restore -- 2026-10-15/043012-ab12        # aggiunge e aggiorna le righe del backup
//   npm run restore -- --latest --wipe --confirm cancella-tutto   # svuota e ripristina
import { latestManifest } from "../src/backup";
import { loadBackup, restoreBackup } from "../src/restore";

const args: string[] = process.argv.slice(2);

function fail(message: string, code = 1): never {
  console.error(message);
  process.exit(code);
  throw new Error(message);
}

const flag = (name: string) => args.includes(`--${name}`);
const option = (name: string) => args[args.indexOf(`--${name}`) + 1];
const url = process.env.SUPABASE_URL;
const secretKey = process.env.SUPABASE_SECRET_KEY;
if (!url || !secretKey) fail("Servono SUPABASE_URL e SUPABASE_SECRET_KEY nell'ambiente.", 2);
const config = { url, secretKey };

let run = args.find((arg) => /^\d{4}-\d{2}-\d{2}\/[0-9a-z-]+$/.test(arg));
if (!run && flag("latest")) {
  const latest = await latestManifest(config);
  if (!latest) fail("Nessun backup completo trovato.");
  run = latest.manifest.run;
}
if (!run) fail("Indicare un backup (es. 2026-10-15/043012-ab12) oppure --latest.", 2);

try {
  if (flag("verify")) {
    const backup = await loadBackup(config, run);
    console.log(`Backup ${run} integro, creato il ${backup.manifest.created_at}: ${JSON.stringify(backup.manifest.counts)}`);
  } else {
    await restoreBackup(config, run, { wipe: flag("wipe"), confirm: option("confirm"), log: console.log });
  }
} catch (error) {
  fail(`Fallito: ${error instanceof Error ? error.message : error}`);
}
