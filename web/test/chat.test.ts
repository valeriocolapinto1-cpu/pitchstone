import { describe, expect, it, vi } from "vitest";
import {
  answer, buildPrompt, ChatUnavailableError, type Chunk, chunks, corpus, estimate, extractCitations, type FetchFn,
  INSTRUCTIONS, linkCitations, loadSettings, nodeFromLink, OllamaProvider, saveSettings, search, split, WorkerProvider,
} from "../src/chat";
import type { NodeRecord } from "../src/model";

function node(id: string, title: string, body: string, extra: Partial<Record<keyof NodeRecord, unknown>> = {}): NodeRecord {
  return {
    id, type: "concept", title, body_md: body, area: "studio", tags: [], version: 1,
    created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z", deleted_at: null, device_id: "test",
    ...extra,
  } as NodeRecord;
}

const chunk = (nodeId: string, title: string, text: string): Chunk => ({ id: `${nodeId}|0`, nodeId, title, text });

describe("corpus", () => {
  it("esclude salute, cestino e chat salvate, anche se arrivassero", () => {
    const nodes = [
      node("a", "Derivate", "La derivata misura la pendenza."),
      node("h", "Pressione", "Valori di pressione", { type: "health" }),
      node("s", "Visita", "Referto", { area: "salute" }),
      node("d", "Vecchio", "Cancellato", { deleted_at: "2026-02-01T00:00:00Z" }),
      node("c", "Chat sulle derivate", "Risposta di prima", { tags: ["chat"] }),
    ];
    const result = corpus(nodes);
    expect(result.map((c) => c.nodeId)).toEqual(["a"]);
    expect(JSON.stringify(result)).not.toMatch(/pressione|Referto/i);
  });

  it("un nodo senza testo vale per il titolo; un testo lungo si divide in frammenti di circa 700 caratteri", () => {
    expect(chunks(node("e", "Solo titolo", "  "))).toEqual([{ id: "e|0", nodeId: "e", title: "Solo titolo", text: "Solo titolo" }]);
    const paragraph = "Frase di prova abbastanza lunga per riempire il frammento. ".repeat(6).trim();
    const parts = split(Array(8).fill(paragraph).join("\n\n"));
    expect(parts.length).toBeGreaterThan(3);
    for (const p of parts) expect(p.length).toBeLessThanOrEqual(1050);
    expect(split("x".repeat(5000)).every((p) => p.length <= 1050)).toBe(true);
  });
});

describe("ricerca", () => {
  const all = [
    chunk("1", "Integrali", "L'integrale definito calcola l'area sotto la curva."),
    chunk("2", "Derivate", "La derivata di una funzione misura la pendenza della retta tangente."),
    chunk("3", "Limiti", "Il limite di una funzione e la base di derivate e integrali."),
    chunk("4", "Ricette", "Pasta e fagioli."),
  ];

  it("ordina per parole in comune, con vantaggio al titolo, e ignora i frammenti senza parole in comune", () => {
    const result = search("Cos'è la derivata di una funzione?", all);
    expect(result.map((c) => c.nodeId)).toEqual(["2", "3"]);
    expect(search("derivate integrali", all).map((c) => c.nodeId)).toEqual(["3", "1", "2"]);
  });

  it("ignora accenti, maiuscole e parole vuote", () => {
    expect(search("PERCHÈ come", all)).toEqual([]);
    expect(search("FAGIOLI", all).map((c) => c.nodeId)).toEqual(["4"]);
  });
});

describe("prompt", () => {
  it("numera le fonti da 1 e rispetta lo spazio", () => {
    const candidates = Array.from({ length: 50 }, (_, i) => chunk(`n${i}`, `Nodo ${i}`, "x".repeat(690)));
    const budget = { total: 4096, answer: 1000 };
    const prompt = buildPrompt("Domanda?", [], candidates, budget);
    expect(prompt.system.startsWith(INSTRUCTIONS)).toBe(true);
    expect(prompt.system).toContain("FONTI\n[1] Nodo 0\n");
    expect(prompt.sources.length).toBeGreaterThan(0);
    expect(prompt.sources.length).toBeLessThan(50);
    const used = estimate(prompt.system) + estimate(prompt.question);
    expect(used).toBeLessThanOrEqual(budget.total - budget.answer);
    // Più spazio, più fonti, nello stesso ordine.
    const larger = buildPrompt("Domanda?", [], candidates, { total: 24_000, answer: 4000 });
    expect(larger.sources.length).toBeGreaterThan(prompt.sources.length);
    expect(larger.sources.slice(0, prompt.sources.length)).toEqual(prompt.sources);
  });

  it("salta un frammento troppo grande ma prende quelli dopo", () => {
    const prompt = buildPrompt("q", [], [chunk("big", "Grande", "y".repeat(20_000)), chunk("s", "Piccolo", "ok")], { total: 4096, answer: 1000 });
    expect(prompt.sources.map((c) => c.nodeId)).toEqual(["s"]);
    expect(buildPrompt("q", [], [], { total: 4096, answer: 1000 }).system).toContain("Nessuna fonte trovata negli appunti.");
  });

  it("tiene la conversazione recente fino a un quarto dello spazio, iniziando da una domanda", () => {
    const history = Array.from({ length: 60 }, (_, i) => ({ role: i % 2 ? ("assistant" as const) : ("user" as const), text: `messaggio ${i} ${"z".repeat(300)}` }));
    const prompt = buildPrompt("q", history, [], { total: 4096, answer: 1000 });
    expect(prompt.history.length).toBeGreaterThan(0);
    expect(prompt.history.length).toBeLessThan(38);
    expect(prompt.history[0].role).toBe("user");
    expect(prompt.history.at(-1)).toEqual(history.at(-1));
    const cost = prompt.history.reduce((sum, m) => sum + estimate(m.text) + 4, 0);
    expect(cost).toBeLessThanOrEqual((4096 - 1000) / 4);
  });
});

describe("citazioni", () => {
  const sources = [chunk("n-a", "Derivate", "a"), chunk("n-b", "Integrali", "b")];

  it("estrae i numeri validi, una volta sola, e ignora quelli inventati", () => {
    const text = "La derivata [1]. L'integrale [2][1] e [1, 2]. Inventata [7]. Link [[Derivate]]. Array [a].";
    expect(extractCitations(text, sources)).toEqual([
      { number: 1, nodeId: "n-a", title: "Derivate" },
      { number: 2, nodeId: "n-b", title: "Integrali" },
    ]);
  });

  it("trasforma le citazioni in link al nodo e lascia il resto", () => {
    const text = "Vedi [1, 2] e [7].";
    const linked = linkCitations(text, extractCitations(text, sources));
    expect(linked).toBe("Vedi [\\[1\\]](#nodo/n-a)[\\[2\\]](#nodo/n-b) e [7].");
    expect(nodeFromLink("#nodo/n-a")).toBe("n-a");
    expect(nodeFromLink("https://example.com/x#nodo/n-b")).toBe("n-b");
    expect(nodeFromLink("https://example.com/")).toBeUndefined();
  });
});

/** fetch finto: Ollama acceso o spento, Worker che risponde come `backend/worker-ai/src/chat.ts`. */
function fakeFetch(options: { ollama: "up" | "down" | "missing-model" | "fails"; worker?: Response }) {
  const calls: { url: string; body?: unknown }[] = [];
  const fn = vi.fn(async (url: string, init?: RequestInit) => {
    calls.push({ url, body: init?.body ? JSON.parse(init.body as string) : undefined });
    if (url.startsWith("http://localhost:11434")) {
      if (options.ollama === "down") throw new TypeError("Failed to fetch");
      if (url.endsWith("/api/tags")) {
        const name = options.ollama === "missing-model" ? "mistral:latest" : "llama3.2:latest";
        return Response.json({ models: [{ name, model: name }] });
      }
      if (options.ollama === "fails") return Response.json({ error: "out of memory" }, { status: 500 });
      return Response.json({ model: "llama3.2", message: { role: "assistant", content: "Locale: la derivata [1]." }, done: true });
    }
    if (url === "/ai/chat") return options.worker ?? Response.json({ text: "Online: la derivata [1]." });
    throw new Error(`url inattesa ${url}`);
  });
  return { fn: fn as unknown as FetchFn, calls };
}

const yes = async () => true;

describe("scelta del modello", () => {
  const all = corpus([node("d", "Derivate", "La derivata misura la pendenza."), node("h", "Derivate cardiache", "x", { type: "health" })]);
  const providers = (fetchFn: FetchFn) => ({ local: new OllamaProvider("llama3.2", fetchFn), online: new WorkerProvider(fetchFn) });

  it("risponde il modello locale quando Ollama è acceso", async () => {
    const { fn, calls } = fakeFetch({ ollama: "up" });
    const reply = await answer("Cos'è una derivata?", [], all, providers(fn), { localOnly: false, confirmOnline: yes });
    expect(reply.provider).toBe("local");
    expect(reply.providerLabel).toBe("Modello locale (llama3.2)");
    expect(reply.citations).toEqual([{ number: 1, nodeId: "d", title: "Derivate" }]);
    expect(calls.map((c) => c.url)).toEqual(["http://localhost:11434/api/tags", "http://localhost:11434/api/chat"]);
    const body = calls[1].body as { model: string; stream: boolean; messages: { role: string; content: string }[] };
    expect(body.model).toBe("llama3.2");
    expect(body.stream).toBe(false);
    expect(body.messages[0].role).toBe("system");
    expect(body.messages[0].content).toContain("[1] Derivate");
    expect(body.messages.at(-1)).toEqual({ role: "user", content: "Cos'è una derivata?" });
  });

  it("con Ollama spento passa a Gemini attraverso il Worker, nel formato di /ai/chat", async () => {
    const { fn, calls } = fakeFetch({ ollama: "down" });
    const history = [{ role: "user" as const, text: "Ciao" }, { role: "assistant" as const, text: "Ciao!" }];
    const reply = await answer("Cos'è una derivata?", history, all, providers(fn), { localOnly: false, confirmOnline: yes });
    expect(reply.provider).toBe("gemini");
    expect(reply.fallbackReason).toBe("Ollama non raggiungibile");
    expect(reply.text).toBe("Online: la derivata [1].");
    const worker = calls.find((c) => c.url === "/ai/chat")!;
    expect(worker.body).toEqual({
      system: expect.stringContaining("FONTI\n[1] Derivate"),
      messages: [...history, { role: "user", text: "Cos'è una derivata?" }],
      maxOutputTokens: 4000,
    });
    const init = (fn as unknown as ReturnType<typeof vi.fn>).mock.calls.find((c) => c[0] === "/ai/chat")![1] as RequestInit;
    expect((init.headers as Record<string, string>)["content-type"]).toBe("application/json");
    expect(JSON.stringify(calls)).not.toContain("cardiache");
  });

  it("passa a Gemini anche se manca il modello o il modello locale fallisce", async () => {
    const missing = fakeFetch({ ollama: "missing-model" });
    expect((await answer("derivata", [], all, providers(missing.fn), { localOnly: false, confirmOnline: yes })).fallbackReason)
      .toBe("modello llama3.2 non installato in Ollama");
    const fails = fakeFetch({ ollama: "fails" });
    const reply = await answer("derivata", [], all, providers(fails.fn), { localOnly: false, confirmOnline: yes });
    expect(reply.provider).toBe("gemini");
    expect(reply.fallbackReason).toBe("Ollama ha risposto 500");
  });

  it("con Solo locale e Ollama spento si ferma senza chiamare il Worker", async () => {
    const { fn, calls } = fakeFetch({ ollama: "down" });
    await expect(answer("derivata", [], all, providers(fn), { localOnly: true })).rejects.toBeInstanceOf(ChatUnavailableError);
    const fails = fakeFetch({ ollama: "fails" });
    await expect(answer("derivata", [], all, providers(fails.fn), { localOnly: true })).rejects.toThrow(/Solo locale/);
    expect([...calls, ...fails.calls].some((c) => c.url === "/ai/chat")).toBe(false);
  });

  it("senza conferma non c'è ripiego su Gemini, né in silenzio né di nascosto", async () => {
    const { fn, calls } = fakeFetch({ ollama: "down" });
    await expect(answer("derivata", [], all, providers(fn), { localOnly: false })).rejects.toThrow(/non confermato/);
    const asked: string[] = [];
    const no = async (reason: string) => { asked.push(reason); return false; };
    await expect(answer("derivata", [], all, providers(fn), { localOnly: false, confirmOnline: no })).rejects.toThrow(/non confermato/);
    expect(asked).toEqual(["Ollama non raggiungibile"]);
    expect(calls.some((c) => c.url === "/ai/chat")).toBe(false);
  });

  it("una domanda che sembra di salute resta sul PC, anche con Gemini consentito", async () => {
    const { fn, calls } = fakeFetch({ ollama: "down" });
    const asked = vi.fn(async () => true);
    for (const question of ["Il mio medico dice che la pressione è 150/95: cosa significa?", "Сегодня я был у врача, у меня высокая температура"]) {
      await expect(answer(question, [], all, providers(fn), { localOnly: false, confirmOnline: asked })).rejects.toThrow(/resta sul PC/);
    }
    expect(asked).not.toHaveBeenCalled();
    expect(calls.some((c) => c.url === "/ai/chat")).toBe(false);
    // Con Ollama acceso risponde il modello locale.
    const up = fakeFetch({ ollama: "up" });
    expect((await answer("Il mio medico dice che la pressione è 150/95: cosa significa?", [], all, providers(up.fn), { localOnly: false })).provider).toBe("local");
  });

  it("una domanda di salute fatta prima resta sul PC anche nelle domande dopo", async () => {
    const { fn } = fakeFetch({ ollama: "down" });
    const history = [{ role: "user" as const, text: "Il mio medico dice che la pressione è 150/95." }, { role: "assistant" as const, text: "Capisco." }];
    await expect(answer("E ora?", history, all, providers(fn), { localOnly: false, confirmOnline: yes })).rejects.toThrow(/resta sul PC/);
  });

  it("i nodi bloccati non entrano nel corpus dei prompt", () => {
    const nodes = [node("a", "Pubblico", "testo"), node("b", "Riservato", "segreto")];
    expect(corpus(nodes, (n) => n.id === "b").map((c) => c.nodeId)).toEqual(["a"]);
  });

  it("un Ollama lento non blocca: la verifica scade dopo poco", async () => {
    const hang: FetchFn = (_url, init) => new Promise((_, reject) => {
      init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
    });
    const local = new OllamaProvider("llama3.2", hang, "http://localhost:11434", 20);
    expect(await local.unavailable()).toBe("Ollama non raggiungibile");
    // Una pagina HTML (per esempio dalla cache) non conta come Ollama acceso.
    const html: FetchFn = async () => new Response("<!doctype html>", { status: 200 });
    expect(await new OllamaProvider("llama3.2", html).unavailable()).toBe("Ollama non raggiungibile");
  });

  it("riporta gli errori del Worker", async () => {
    const limit = fakeFetch({ ollama: "down", worker: Response.json({ error: "limite di Gemini raggiunto" }, { status: 429 }) });
    await expect(answer("derivata", [], all, providers(limit.fn), { localOnly: false, confirmOnline: yes })).rejects.toThrow("limite di Gemini raggiunto");
    const login = fakeFetch({ ollama: "down", worker: new Response("<html>login</html>", { status: 200 }) });
    await expect(answer("derivata", [], all, providers(login.fn), { localOnly: false, confirmOnline: yes })).rejects.toThrow(/sessione scaduta/);
  });
});

describe("impostazioni", () => {
  it("salva modello e Solo locale, con i predefiniti", () => {
    const data = new Map<string, string>();
    const storage = { getItem: (k: string) => data.get(k) ?? null, setItem: (k: string, v: string) => void data.set(k, v) };
    expect(loadSettings(storage)).toEqual({ model: "llama3.2", localOnly: true });
    saveSettings(storage, { model: " qwen2.5:7b ", localOnly: true });
    expect(loadSettings(storage)).toEqual({ model: "qwen2.5:7b", localOnly: true });
    const broken = { getItem: () => { throw new Error("bloccato"); } };
    expect(loadSettings(broken)).toEqual({ model: "llama3.2", localOnly: true });
    saveSettings(storage, { model: "llama3.2", localOnly: false });
    expect(loadSettings(storage).localOnly).toBe(false);
  });
});
