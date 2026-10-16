// Tutor sugli appunti per il PC (ADR 0013): frammenti dei nodi, ricerca per
// parole, prompt con fonti numerate come sull'iPad (PitchstoneAI/Prompt.swift), poi il
// modello locale del PC (Ollama su localhost) o, se è spento, Gemini attraverso il Worker.
import type { NodeRecord } from "./model";

export interface Chunk {
  id: string;
  nodeId: string;
  title: string;
  text: string;
}

export interface ChatMessage {
  role: "user" | "assistant";
  text: string;
}

export type ProviderKind = "local" | "gemini";

// MARK: Frammenti

/** Lunghezza indicativa di un frammento, in caratteri. */
export const TARGET_LENGTH = 700;
/** Le chat salvate dall'iPad non sono fonti: il modello citerebbe le sue risposte. */
export const CHAT_TAG = "chat";

/**
 * Nodi che la chat può leggere. Sul PC non arrivano dati di salute (il server non li ha),
 * ma il filtro resta: un nodo di salute non diventa mai un frammento, quindi nessun prompt lo contiene.
 */
export function isSensitive(node: { type: string; area: string }): boolean {
  return node.type === "health" || node.area === "salute";
}

export function corpus(nodes: NodeRecord[]): Chunk[] {
  return nodes
    .filter((n) => !n.deleted_at && !isSensitive(n) && !n.tags.includes(CHAT_TAG))
    .flatMap((n) => chunks(n));
}

export function chunks(node: NodeRecord): Chunk[] {
  const title = node.title.trim() || "Senza titolo";
  const body = node.body_md.trim();
  // Un nodo senza testo vale comunque per il titolo.
  const parts = body ? split(body) : [title];
  return parts.map((text, n) => ({ id: `${node.id}|${n}`, nodeId: node.id, title, text }));
}

/** Paragrafi uniti fino a circa `target` caratteri; un paragrafo troppo lungo si taglia tra frasi o parole. */
export function split(text: string, target = TARGET_LENGTH): string[] {
  const result: string[] = [];
  let current = "";
  for (const paragraph of text.split("\n\n").map((p) => p.trim()).filter(Boolean)) {
    for (const piece of cut(paragraph, Math.floor((target * 3) / 2))) {
      if (current && current.length + piece.length + 2 > target) {
        result.push(current);
        current = "";
      }
      current = current ? `${current}\n\n${piece}` : piece;
    }
  }
  if (current) result.push(current);
  return result;
}

function cut(paragraph: string, limit: number): string[] {
  if (paragraph.length <= limit) return [paragraph];
  const pieces: string[] = [];
  let current = "";
  for (const word of paragraph.split(" ").filter(Boolean)) {
    if (current && current.length + word.length + 1 > limit) {
      pieces.push(current);
      current = "";
    }
    current = current ? `${current} ${word}` : word;
    // Fine frase oltre metà del limite: buon punto per tagliare.
    if (current.length > limit / 2 && /[.!?]$/.test(word)) {
      pieces.push(current);
      current = "";
    }
  }
  if (current) pieces.push(current);
  // Una "parola" più lunga del limite (un URL, una formula) si spezza a forza.
  return pieces.flatMap((piece) => {
    if (piece.length <= limit * 2) return [piece];
    const parts: string[] = [];
    for (let i = 0; i < piece.length; i += limit) parts.push(piece.slice(i, i + limit));
    return parts;
  });
}

// MARK: Ricerca

const STOPWORDS = new Set([
  "che", "chi", "cosa", "come", "con", "del", "della", "dei", "delle", "degli", "dal", "dalla", "nel", "nella",
  "nei", "per", "tra", "fra", "una", "uno", "gli", "non", "sono", "era", "essere", "questo", "questa",
  "quello", "quella", "anche", "piu", "quale", "quali", "quando", "dove", "perche", "spiega", "spiegami",
  "dimmi", "cos", "the", "and", "what", "how", "why", "are",
]);

/** Senza maiuscole e accenti, spazi semplici. */
export function normalize(text: string): string {
  return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().split(/\s+/).filter(Boolean).join(" ");
}

export function keywords(text: string): string[] {
  const words = normalize(text).split(/[^\p{L}\p{N}]+/u).filter((w) => w.length >= 3 && !STOPWORDS.has(w));
  return [...new Set(words)];
}

/**
 * Frammenti in ordine di pertinenza: quota delle parole della domanda presenti nel frammento,
 * con un piccolo vantaggio se compaiono nel titolo. A parità vale l'ordine del corpus.
 */
export function search(query: string, all: Chunk[], limit = 40): Chunk[] {
  const words = keywords(query);
  if (words.length === 0) return [];
  const scored: { chunk: Chunk; score: number; index: number }[] = [];
  all.forEach((chunk, index) => {
    const text = normalize(`${chunk.title} ${chunk.text}`);
    const title = normalize(chunk.title);
    const found = words.filter((w) => text.includes(w)).length;
    if (found === 0) return;
    const inTitle = words.filter((w) => title.includes(w)).length;
    scored.push({ chunk, score: found / words.length + (0.25 * inTitle) / words.length, index });
  });
  scored.sort((a, b) => b.score - a.score || a.index - b.index);
  return scored.slice(0, limit).map((s) => s.chunk);
}

// MARK: Prompt

/** Spazio del prompt in token stimati, risposta compresa. */
export interface TokenBudget {
  total: number;
  answer: number;
}

/** Contesto chiesto a Ollama (`num_ctx`): basta a un modello da 3-8 miliardi di parametri. */
export const LOCAL_BUDGET: TokenBudget = { total: 8192, answer: 1500 };
export const GEMINI_BUDGET: TokenBudget = { total: 24_000, answer: 4000 };

/** Stima prudente: in italiano un token vale circa 3-4 caratteri. */
export function estimate(text: string): number {
  return Math.floor((text.length + 2) / 3);
}

export const INSTRUCTIONS =
  "Sei il tutor di studio di Pitchstone. Rispondi in italiano, in modo didattico e preciso: " +
  "prima la risposta in breve, poi la spiegazione passo per passo, con esempi quando aiutano. " +
  "Usa le FONTI, che sono gli appunti dell'utente. Dopo ogni affermazione presa da una fonte " +
  "scrivi il suo numero tra parentesi quadre, per esempio [2]. Non inventare numeri di fonti. " +
  "Se le fonti non bastano, dillo e rispondi con le tue conoscenze, senza citazioni. " +
  "Per le formule usa la notazione LaTeX tra $.";

export const MAX_QUESTION_LENGTH = 8000;
/** Il Worker accetta al più 40 messaggi: 38 di conversazione più la domanda. */
export const MAX_HISTORY = 38;

export interface ChatPrompt {
  system: string;
  sources: Chunk[];
  history: ChatMessage[];
  question: string;
}

export function sourcesText(sources: Chunk[]): string {
  if (sources.length === 0) return "Nessuna fonte trovata negli appunti.";
  return sources.map((c, i) => `[${i + 1}] ${c.title}\n${c.text}`).join("\n\n");
}

/**
 * Le fonti più pertinenti finché c'è spazio, poi la conversazione più recente (fino a un
 * quarto dello spazio). Domanda e istruzioni entrano sempre.
 */
export function buildPrompt(question: string, history: ChatMessage[], candidates: Chunk[], budget: TokenBudget): ChatPrompt {
  const q = question.slice(0, MAX_QUESTION_LENGTH);
  const recent = history.slice(-MAX_HISTORY);
  let available = budget.total - budget.answer - (estimate(INSTRUCTIONS) + estimate(q) + 20);

  const kept: ChatMessage[] = [];
  let historyBudget = Math.max(0, Math.floor(available / 4));
  for (let i = recent.length - 1; i >= 0; i--) {
    const cost = estimate(recent[i].text) + 4;
    if (cost > historyBudget) break;
    kept.unshift(recent[i]);
    historyBudget -= cost;
    available -= cost;
  }
  // Il Worker vuole che la conversazione inizi da una domanda, non da una risposta.
  while (kept.length > 0 && kept[0].role !== "user") kept.shift();

  const sources: Chunk[] = [];
  for (const chunk of candidates) {
    const cost = estimate(chunk.title + chunk.text) + 6;
    // Un frammento troppo grande si salta: uno più piccolo può ancora entrare.
    if (cost > available) continue;
    sources.push(chunk);
    available -= cost;
  }
  return { system: `${INSTRUCTIONS}\n\nFONTI\n${sourcesText(sources)}`, sources, history: kept, question: q };
}

// MARK: Citazioni

export interface Citation {
  number: number;
  nodeId: string;
  title: string;
}

/** Prefisso dei link alle fonti: `#nodo/<id>`, intercettato dalla PWA per aprire il nodo. */
export const SOURCE_LINK = "#nodo/";

/** `[1]` o `[1, 2]` che inizia in `start`: i numeri e la posizione dopo `]`. */
function group(text: string, start: number): { numbers: number[]; end: number } | undefined {
  const close = text.indexOf("]", start);
  if (close < 0) return undefined;
  const inside = text.slice(start + 1, close);
  if (!inside || inside.length > 20 || !/^[\d, ]+$/.test(inside)) return undefined;
  const numbers = inside.split(",").map((s) => s.trim()).filter(Boolean).map(Number);
  return numbers.length ? { numbers, end: close + 1 } : undefined;
}

/** Numeri tra parentesi quadre, `[2]`, `[1, 3]`, `[1][4]`; quelli senza fonte (inventati) si ignorano. */
export function extractCitations(answer: string, sources: Chunk[]): Citation[] {
  const seen = new Set<number>();
  const result: Citation[] = [];
  for (let i = 0; i < answer.length; i++) {
    if (answer[i] !== "[") continue;
    const g = group(answer, i);
    if (!g) continue;
    for (const n of g.numbers) {
      if (n < 1 || n > sources.length || seen.has(n)) continue;
      seen.add(n);
      result.push({ number: n, nodeId: sources[n - 1].nodeId, title: sources[n - 1].title });
    }
    i = g.end - 1;
  }
  return result;
}

/** La risposta con ogni `[n]` valido trasformato in un link Markdown verso il nodo della fonte. */
export function linkCitations(answer: string, citations: Citation[]): string {
  const byNumber = new Map(citations.map((c) => [c.number, c]));
  let output = "";
  let i = 0;
  while (i < answer.length) {
    const g = answer[i] === "[" ? group(answer, i) : undefined;
    if (g && g.numbers.every((n) => byNumber.has(n))) {
      // `\[1\]` e non `[1]`: un testo `[[...]]` diventerebbe un link tra nodi.
      output += g.numbers.map((n) => `[\\[${n}\\]](${SOURCE_LINK}${encodeURIComponent(byNumber.get(n)!.nodeId)})`).join("");
      i = g.end;
    } else {
      output += answer[i];
      i++;
    }
  }
  return output;
}

/** Id del nodo da un link di citazione, o undefined per un link qualunque. */
export function nodeFromLink(href: string): string | undefined {
  const hash = href.slice(href.indexOf("#"));
  if (!href.includes("#") || !hash.startsWith(SOURCE_LINK)) return undefined;
  return decodeURIComponent(hash.slice(SOURCE_LINK.length)) || undefined;
}

// MARK: Modelli

export type FetchFn = (input: string, init?: RequestInit) => Promise<Response>;

export interface ChatProvider {
  kind: ProviderKind;
  label: string;
  budget: TokenBudget;
  /** Motivo per cui non può rispondere, o undefined se è pronto. */
  unavailable(): Promise<string | undefined>;
  reply(prompt: ChatPrompt, signal?: AbortSignal): Promise<string>;
}

export const OLLAMA_URL = "http://localhost:11434";
export const DEFAULT_OLLAMA_MODEL = "llama3.2";
/** Ollama spento: la connessione a localhost fallisce subito, ma un PC lento non deve bloccare la chat. */
export const PROBE_TIMEOUT_MS = 1500;

/** Un nome di Ollama senza tag vale `:latest`. */
function sameModel(a: string, b: string): boolean {
  const full = (name: string) => (name.includes(":") ? name : `${name}:latest`);
  return full(a.trim()) === full(b.trim());
}

/** Modello locale del PC via Ollama (http://localhost:11434): funziona solo quando il PC lo sta eseguendo. */
export class OllamaProvider implements ChatProvider {
  readonly kind = "local" as const;
  readonly budget = LOCAL_BUDGET;

  constructor(
    readonly model: string,
    private readonly fetchFn: FetchFn,
    private readonly baseUrl = OLLAMA_URL,
    private readonly timeoutMs = PROBE_TIMEOUT_MS,
  ) {}

  get label() {
    return `Modello locale (${this.model})`;
  }

  async unavailable(): Promise<string | undefined> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await this.fetchFn(`${this.baseUrl}/api/tags`, { signal: controller.signal });
      if (!response.ok) return `Ollama ha risposto ${response.status}`;
      const data = (await response.json()) as { models?: { name?: string; model?: string }[] };
      if (!Array.isArray(data.models)) return "risposta di Ollama non valida";
      const installed = data.models.some((m) => sameModel(m.name ?? m.model ?? "", this.model));
      return installed ? undefined : `modello ${this.model} non installato in Ollama`;
    } catch {
      // Ollama spento, CORS non permesso (OLLAMA_ORIGINS) o PC lento: si passa oltre.
      return "Ollama non raggiungibile";
    } finally {
      clearTimeout(timer);
    }
  }

  async reply(prompt: ChatPrompt, signal?: AbortSignal): Promise<string> {
    const response = await this.fetchFn(`${this.baseUrl}/api/chat`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      signal,
      body: JSON.stringify({
        model: this.model,
        stream: false,
        messages: [
          { role: "system", content: prompt.system },
          ...prompt.history.map((m) => ({ role: m.role, content: m.text })),
          { role: "user", content: prompt.question },
        ],
        options: { num_ctx: this.budget.total, num_predict: this.budget.answer, temperature: 0.3 },
      }),
    });
    if (!response.ok) throw new Error(`Ollama ha risposto ${response.status}`);
    const data = (await response.json()) as { message?: { content?: string } };
    const text = data.message?.content ?? "";
    if (!text.trim()) throw new Error("risposta vuota del modello locale");
    return text;
  }
}

/** Gemini attraverso il Worker (`POST /ai/chat`, stessa origine della PWA, ADR 0009). */
export class WorkerProvider implements ChatProvider {
  readonly kind = "gemini" as const;
  readonly label = "Gemini (online)";
  readonly budget = GEMINI_BUDGET;

  constructor(private readonly fetchFn: FetchFn, private readonly path = "/ai/chat") {}

  async unavailable(): Promise<string | undefined> {
    return typeof navigator !== "undefined" && navigator.onLine === false ? "offline" : undefined;
  }

  async reply(prompt: ChatPrompt, signal?: AbortSignal): Promise<string> {
    const response = await this.fetchFn(this.path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      signal,
      body: JSON.stringify({
        system: prompt.system,
        messages: [...prompt.history, { role: "user", text: prompt.question }],
        maxOutputTokens: this.budget.answer,
      }),
    });
    let data: { text?: string; error?: string } = {};
    try {
      data = (await response.json()) as typeof data;
    } catch {
      // Un redirect al login di Access risponde HTML.
    }
    if (response.status === 401 || (response.ok && data.text === undefined && data.error === undefined)) {
      throw new Error("sessione scaduta: ricarica la pagina per accedere di nuovo");
    }
    if (!response.ok || !data.text) throw new Error(data.error ?? `il Worker ha risposto ${response.status}`);
    return data.text;
  }
}

export interface ChatReply {
  text: string;
  provider: ProviderKind;
  providerLabel: string;
  sources: Chunk[];
  citations: Citation[];
  /** Perché non ha risposto il modello locale, se ha risposto Gemini. */
  fallbackReason?: string;
}

export class ChatUnavailableError extends Error {}

/**
 * Prima il modello locale del PC; se è spento o fallisce, Gemini attraverso il Worker.
 * Con `localOnly` gli appunti non escono mai dal PC: senza Ollama la chat si ferma con un errore.
 */
export async function answer(
  question: string,
  history: ChatMessage[],
  allChunks: Chunk[],
  providers: { local: ChatProvider; online: ChatProvider },
  options: { localOnly: boolean; signal?: AbortSignal },
): Promise<ChatReply> {
  const candidates = search(question, allChunks);
  const run = async (provider: ChatProvider, fallbackReason?: string): Promise<ChatReply> => {
    const prompt = buildPrompt(question, history, candidates, provider.budget);
    const text = await provider.reply(prompt, options.signal);
    return {
      text,
      provider: provider.kind,
      providerLabel: provider.label,
      sources: prompt.sources,
      citations: extractCitations(text, prompt.sources),
      fallbackReason,
    };
  };

  let reason = await providers.local.unavailable();
  if (!reason) {
    try {
      return await run(providers.local);
    } catch (error) {
      if (options.signal?.aborted) throw error;
      reason = error instanceof Error ? error.message : String(error);
    }
  }
  if (options.localOnly) {
    throw new ChatUnavailableError(`Modello locale non disponibile (${reason}). Solo locale è attivo: Gemini non viene usato.`);
  }
  const offline = await providers.online.unavailable();
  if (offline) throw new ChatUnavailableError(`Nessun modello disponibile: ${reason}; Gemini ${offline}.`);
  return run(providers.online, reason);
}

// MARK: Impostazioni

export interface ChatSettings {
  model: string;
  localOnly: boolean;
}

/** Preferenze del PC in localStorage: modello di Ollama e "solo locale". */
export function loadSettings(storage: Pick<Storage, "getItem">): ChatSettings {
  let model = DEFAULT_OLLAMA_MODEL;
  let localOnly = false;
  try {
    model = storage.getItem("chat.ollamaModel")?.trim() || DEFAULT_OLLAMA_MODEL;
    localOnly = storage.getItem("chat.localOnly") === "1";
  } catch {
    // Archivio non disponibile: valgono i predefiniti.
  }
  return { model, localOnly };
}

export function saveSettings(storage: Pick<Storage, "setItem">, settings: ChatSettings): void {
  try {
    storage.setItem("chat.ollamaModel", settings.model.trim() || DEFAULT_OLLAMA_MODEL);
    storage.setItem("chat.localOnly", settings.localOnly ? "1" : "0");
  } catch {
    // Non salvate: restano per questa sessione.
  }
}
