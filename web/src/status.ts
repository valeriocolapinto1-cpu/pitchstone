// Schermata "Connessione": che cosa risponde il server, in parole semplici.
import { AuthError, HttpError, OutdatedError } from "./sync";

export interface ServerStatus {
  api: number;
  gemini: boolean;
  database: boolean;
  last_backup_at: string | null;
  backup_age_hours: number | null;
}

export interface StatusLine {
  label: string;
  ok: boolean;
  text: string;
}

/** Sopra queste ore dall'ultimo backup il segnale diventa un avviso (il controllo giornaliero ne tollera 36). */
export const BACKUP_STALE_HOURS = 36;

export async function fetchStatus(base = ""): Promise<ServerStatus> {
  const response = await fetch(`${base}/status`, {
    credentials: "include",
    redirect: "manual",
    signal: AbortSignal.timeout(15_000),
  });
  if (response.type === "opaqueredirect" || response.status === 401 || response.status === 403) throw new AuthError("login scaduto");
  if (response.status === 426) throw new OutdatedError();
  if (!response.ok) throw new HttpError(response.status);
  return (await response.json()) as ServerStatus;
}

function age(hours: number): string {
  if (hours < 1) return "meno di un'ora fa";
  if (hours < 48) return `${Math.round(hours)} ore fa`;
  return `${Math.round(hours / 24)} giorni fa`;
}

/** Righe da mostrare. `lastSync` è l'ora dell'ultima sincronizzazione riuscita su questo dispositivo. */
export function describeStatus(status: ServerStatus, lastSync: Date | undefined, pending: number): StatusLine[] {
  const backup: StatusLine = status.backup_age_hours === null
    ? { label: "Backup", ok: false, text: "Nessun backup registrato" }
    : { label: "Backup", ok: status.backup_age_hours <= BACKUP_STALE_HOURS, text: `Ultimo ${age(status.backup_age_hours)}` };
  return [
    { label: "Accesso", ok: true, text: "Sessione valida" },
    { label: "Database", ok: status.database, text: status.database ? "Raggiungibile" : "Non raggiungibile" },
    { label: "Gemini", ok: status.gemini, text: status.gemini ? "Configurato" : "Non configurato" },
    backup,
    {
      label: "Sincronizzazione",
      ok: pending === 0,
      text: `${lastSync ? `Ultima alle ${lastSync.toLocaleTimeString("it-IT", { hour: "2-digit", minute: "2-digit" })}` : "Ancora nessuna"}${pending ? `, ${pending} modifiche in attesa` : ""}`,
    },
  ];
}

/** Riga per un errore di rete o di sessione: il caso "token scaduto" ha un testo suo. */
export function describeFailure(error: unknown): StatusLine {
  if (error instanceof AuthError) return { label: "Accesso", ok: false, text: "Sessione scaduta: ricarica la pagina per accedere di nuovo" };
  if (error instanceof OutdatedError) return { label: "App", ok: false, text: "Versione troppo vecchia: ricarica la pagina" };
  if (error instanceof HttpError) return { label: "Server", ok: false, text: `Errore ${error.status}` };
  return { label: "Rete", ok: false, text: "Server non raggiungibile: sei offline?" };
}
