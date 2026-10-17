// Quando sincronizzare da soli: ogni 30 secondi, ma con calma se qualcosa non va.
//  - rete o server in difficoltà: l'attesa raddoppia (30 s, 1 min, 2 min… fino a 10 min) e torna a 30 s al primo successo;
//  - sessione scaduta: ci si ferma del tutto, un nuovo tentativo ogni 30 secondi non servirebbe a niente;
//  - scheda nascosta: non si chiama il server, e quando la scheda torna visibile si sincronizza subito.

export type PollResult = "ok" | "offline" | "auth";

export const BASE_DELAY_MS = 30_000;
export const MAX_DELAY_MS = 10 * 60_000;

/** Attesa dopo `failures` fallimenti di fila. */
export function nextDelay(failures: number): number {
  return Math.min(MAX_DELAY_MS, BASE_DELAY_MS * 2 ** Math.min(Math.max(failures, 0), 10));
}

export class Poller {
  private failures = 0;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private stopped = true;
  private running = false;

  constructor(
    private run: () => Promise<PollResult | "skipped">,
    private hidden: () => boolean = () => false,
  ) {}

  /** Parte, e lascia che il primo giro lo faccia chi chiama (`poke`). */
  start() {
    this.stopped = false;
    this.schedule(BASE_DELAY_MS);
  }

  stop() {
    this.stopped = true;
    clearTimeout(this.timer);
    this.timer = undefined;
  }

  /** Da fare subito: rete tornata, scheda di nuovo visibile, nuova modifica. Dopo un'auth scaduta riparte il giro. */
  poke() {
    if (this.running || this.hidden()) return;
    this.stopped = false;
    clearTimeout(this.timer);
    void this.tick();
  }

  get stoppedForAuth(): boolean {
    return this.stopped;
  }

  private schedule(delay: number) {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => void this.tick(), delay);
  }

  private async tick() {
    if (this.stopped || this.running) return;
    if (this.hidden()) {
      // Non si disturba il server a scheda nascosta; il giro riparte quando torna visibile.
      this.schedule(BASE_DELAY_MS);
      return;
    }
    this.running = true;
    let result: PollResult | "skipped";
    try {
      result = await this.run();
    } catch {
      result = "offline";
    } finally {
      this.running = false;
    }
    if (result === "auth") {
      this.stop();
      return;
    }
    this.failures = result === "offline" ? this.failures + 1 : 0;
    this.schedule(nextDelay(this.failures));
  }
}
