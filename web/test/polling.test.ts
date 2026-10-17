import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BASE_DELAY_MS, MAX_DELAY_MS, nextDelay, Poller, type PollResult } from "../src/polling";

describe("attesa tra una sync e l'altra", () => {
  it("30 secondi, poi raddoppia fino a 10 minuti", () => {
    expect([0, 1, 2, 3, 4, 5, 20].map(nextDelay)).toEqual([30_000, 60_000, 120_000, 240_000, 480_000, 600_000, 600_000]);
    expect(nextDelay(-3)).toBe(BASE_DELAY_MS);
    expect(nextDelay(5)).toBe(MAX_DELAY_MS);
  });
});

describe("Poller", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  function setup(results: (PollResult | "skipped" | Error)[], hidden = false) {
    let index = 0;
    let isHidden = hidden;
    const run = vi.fn(async () => {
      const next = results[Math.min(index++, results.length - 1)];
      if (next instanceof Error) throw next;
      return next;
    });
    const poller = new Poller(run, () => isHidden);
    return { run, poller, hide: (value: boolean) => { isHidden = value; } };
  }

  it("dopo un successo aspetta 30 secondi", async () => {
    const { run, poller } = setup(["ok"]);
    poller.start();
    await vi.advanceTimersByTimeAsync(29_999);
    expect(run).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(run).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(run).toHaveBeenCalledTimes(2);
    poller.stop();
  });

  it("offline allunga l'attesa, e un successo la riporta a 30 secondi", async () => {
    const { run, poller } = setup(["offline", "offline", "ok", "ok"]);
    poller.poke();
    await vi.advanceTimersByTimeAsync(0);
    expect(run).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(59_999);
    expect(run).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(run).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(119_999);
    expect(run).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(run).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(run).toHaveBeenCalledTimes(4);
    poller.stop();
  });

  it("un errore imprevisto conta come offline", async () => {
    const { run, poller } = setup([new Error("boom"), "ok"]);
    poller.poke();
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(59_999);
    expect(run).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(run).toHaveBeenCalledTimes(2);
    poller.stop();
  });

  it("con la sessione scaduta si ferma, e riparte solo con un poke", async () => {
    const { run, poller } = setup(["auth", "ok"]);
    poller.poke();
    await vi.advanceTimersByTimeAsync(0);
    expect(poller.stoppedForAuth).toBe(true);
    await vi.advanceTimersByTimeAsync(60 * 60_000);
    expect(run).toHaveBeenCalledTimes(1);
    poller.poke();
    await vi.advanceTimersByTimeAsync(0);
    expect(run).toHaveBeenCalledTimes(2);
    expect(poller.stoppedForAuth).toBe(false);
    poller.stop();
  });

  it("a scheda nascosta non chiama il server, e torna a farlo subito quando è visibile", async () => {
    const { run, poller, hide } = setup(["ok"], true);
    poller.start();
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    expect(run).not.toHaveBeenCalled();
    poller.poke();
    await vi.advanceTimersByTimeAsync(0);
    expect(run).not.toHaveBeenCalled();
    hide(false);
    poller.poke();
    await vi.advanceTimersByTimeAsync(0);
    expect(run).toHaveBeenCalledTimes(1);
    poller.stop();
  });

  it("non lancia due giri insieme", async () => {
    let release: (value: PollResult) => void = () => {};
    const run = vi.fn(() => new Promise<PollResult>((resolve) => { release = resolve; }));
    const poller = new Poller(run);
    poller.poke();
    poller.poke();
    await vi.advanceTimersByTimeAsync(0);
    expect(run).toHaveBeenCalledTimes(1);
    release("ok");
    await vi.advanceTimersByTimeAsync(0);
    poller.stop();
  });
});
