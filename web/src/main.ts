import DOMPurify from "dompurify";
import { marked } from "marked";
import {
  answer, type ChatMessage, corpus, DEFAULT_OLLAMA_MODEL, linkCitations, loadSettings, nodeFromLink,
  OllamaProvider, saveSettings, WorkerProvider,
} from "./chat";
import { AREAS, LABELS, NODE_TYPES, type NodeRecord, titleKey } from "./model";
import { Repository } from "./repository";
import { IndexedDBStore } from "./store";
import { AuthError, HttpTransport, SyncClient } from "./sync";
import "./style.css";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const store = new IndexedDBStore();
const deviceId = localStorage.getItem("deviceId") ?? `pc-${crypto.randomUUID().slice(0, 8)}`;
localStorage.setItem("deviceId", deviceId);
const repo = new Repository(store, deviceId);
const sync = new SyncClient(store, new HttpTransport(), deviceId);
let selected: string | undefined;

function active(): NodeRecord[] {
  return store.nodes().filter((n) => !n.deleted_at).sort((a, b) => b.updated_at.localeCompare(a.updated_at));
}

const dateFormat = new Intl.DateTimeFormat("it-IT", { day: "numeric", month: "short" });
const timeFormat = new Intl.DateTimeFormat("it-IT", { hour: "2-digit", minute: "2-digit" });

/** Oggi l'ora, prima il giorno: come l'elenco dell'iPad. */
function shortDate(iso: string): string {
  const date = new Date(iso);
  return date.toDateString() === new Date().toDateString() ? timeFormat.format(date) : dateFormat.format(date);
}

/** Prima riga di testo del Markdown, senza simboli. */
function snippet(md: string): string {
  const line = md.split("\n").map((l) => l.replace(/^[#>\-*+\s\d.[\]x]+/i, "").trim()).find(Boolean) ?? "";
  return line.replace(/\[\[([^\]|#]+)[^\]]*\]\]/g, "$1").replace(/[*_`~]/g, "");
}

function renderList() {
  const q = titleKey($<HTMLInputElement>("search").value);
  const all = active();
  const shown = all.filter((n) => !q || titleKey(`${n.title} ${n.body_md}`).includes(q));
  $("count").textContent = q ? `${shown.length} di ${all.length}` : all.length === 1 ? "1 nodo" : `${all.length} nodi`;
  const items = shown.map((n) => {
    const li = document.createElement("li");
    const dot = document.createElement("span");
    dot.className = "dot";
    dot.style.background = `var(--${n.area})`;
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = n.title || "Senza titolo";
    const date = document.createElement("span");
    date.className = "date";
    date.textContent = shortDate(n.updated_at);
    const text = document.createElement("span");
    text.className = "snippet";
    text.textContent = snippet(n.body_md) || LABELS.type[n.type];
    li.append(dot, name, date, text);
    li.className = n.id === selected ? "active" : "";
    li.onclick = () => open(n.id);
    return li;
  });
  if (items.length === 0) {
    const li = document.createElement("li");
    li.className = "empty";
    li.textContent = q ? "Nessun risultato" : "Ancora nessun appunto: creane uno con ＋";
    items.push(li);
  }
  $("list").replaceChildren(...items);
}

function setStatus(state: "ok" | "offline" | "error", ...content: (string | Node)[]) {
  $("status").dataset.state = state;
  $("status").replaceChildren(...content);
}

function updateAreaDot() {
  $("area-dot").style.background = `var(--${$<HTMLSelectElement>("area").value})`;
}

type Mode = "write" | "split" | "preview";
function setMode(mode: Mode) {
  $("panes").dataset.mode = mode;
  for (const b of document.querySelectorAll<HTMLButtonElement>(".segmented button")) {
    b.setAttribute("aria-pressed", String(b.dataset.mode === mode));
  }
  try { localStorage.setItem("viewMode", mode); } catch { /* solo una preferenza */ }
}

function renderPreview(node: NodeRecord) {
  const md = node.body_md.replace(/\[\[([^\]|#\n]+)(?:[#|][^\]\n]*)?\]\]/g, (_, t: string) => `<span class="wiki" data-title="${t.replace(/"/g, "")}">${t}</span>`);
  $("preview").innerHTML = DOMPurify.sanitize(`<h1>${DOMPurify.sanitize(node.title)}</h1>` + (marked.parse(md) as string));
}

/** Salva su disco dopo ogni modifica; un errore resta visibile nello stato. */
function persist() {
  store.flush().catch(() => { setStatus("error", "Errore nel salvataggio locale"); });
}

function open(id: string) {
  flushSave();
  const node = store.node(id);
  if (!node) return;
  selected = id;
  $("node").hidden = false;
  $("empty").hidden = true;
  document.body.classList.add("open");
  $<HTMLInputElement>("title").value = node.title;
  $<HTMLSelectElement>("type").value = node.type;
  $<HTMLSelectElement>("area").value = node.area;
  $<HTMLInputElement>("tags").value = node.tags.join(", ");
  $<HTMLTextAreaElement>("body").value = node.body_md;
  updateAreaDot();
  renderPreview(node);
  renderList();
}

// Il nodo va fissato quando si pianifica il salvataggio: nel frattempo se ne può aprire un altro.
let saveTimer: number | undefined;
let saveId: string | undefined;
function scheduleSave() {
  clearTimeout(saveTimer);
  saveId = selected;
  saveTimer = window.setTimeout(flushSave, 600);
}

/** Salva subito la modifica in attesa: prima di cambiare nodo, del cestino e della sync. */
function flushSave() {
  clearTimeout(saveTimer);
  saveTimer = undefined;
  const id = saveId;
  saveId = undefined;
  if (id) save(id);
}

function save(id: string) {
  // Il modulo mostra ancora questo nodo: flushSave parte prima di ogni cambio.
  if (!store.node(id)) return;
  const node = repo.updateNode(id, {
    title: $<HTMLInputElement>("title").value,
    type: $<HTMLSelectElement>("type").value as NodeRecord["type"],
    area: $<HTMLSelectElement>("area").value as NodeRecord["area"],
    tags: $<HTMLInputElement>("tags").value.split(",").map((t) => t.trim()).filter(Boolean),
    body_md: $<HTMLTextAreaElement>("body").value,
  });
  renderPreview(node);
  renderList();
  persist();
}

/** Modifiche rifiutate dal server: si scartano (vale il server) o si riprovano. */
function renderRejections() {
  const box = $("rejections");
  box.hidden = sync.rejections.length === 0;
  box.replaceChildren(...sync.rejections.map((p) => {
    const row = document.createElement("div");
    const label = document.createElement("span");
    const name = p.entity === "node" ? store.node(p.id)?.title || "Senza titolo" : "Collegamento";
    label.textContent = `${name}: ${p.rejection}`;
    const button = (text: string, action: () => void) => {
      const b = document.createElement("button");
      b.textContent = text;
      b.onclick = () => {
        action();
        persist();
        renderRejections();
        renderList();
        if (selected && !store.node(selected)) closeEditor();
        void runSync();
      };
      return b;
    };
    row.append(label, button("Scarta", () => sync.discard(p.entity, p.id)), button("Riprova", () => sync.retry(p.entity, p.id)));
    return row;
  }));
}

function closeEditor() {
  selected = undefined;
  $("node").hidden = true;
  $("empty").hidden = false;
  document.body.classList.remove("open");
  $("preview").replaceChildren();
}

/** Mentre si scrive il modulo non si ricarica: si perderebbero cursore e testo. */
function editing(): boolean {
  return saveTimer !== undefined || $("node").contains(document.activeElement);
}

async function runSync() {
  flushSave();
  try {
    const result = await sync.sync();
    if (result !== "skipped") setStatus("ok", `Sincronizzato alle ${timeFormat.format(new Date())}`);
  } catch (error) {
    if (error instanceof AuthError) {
      const link = document.createElement("a");
      link.href = "/";
      link.textContent = "Accedi di nuovo";
      link.onclick = (e) => { e.preventDefault(); location.reload(); };
      setStatus("error", "Sessione scaduta: ", link);
    } else {
      setStatus("offline", "Offline: le modifiche partono al ritorno della rete");
    }
  }
  renderRejections();
  renderList();
  if (selected && !store.node(selected)) closeEditor();
  else if (selected && !editing()) open(selected);
}

// MARK: Tutor

let chatHistory: ChatMessage[] = [];
let chatAbort: AbortController | undefined;

function chatSettings() {
  return { model: $<HTMLInputElement>("chat-model").value, localOnly: $<HTMLInputElement>("chat-local-only").checked };
}

function appendMessage(role: "user" | "assistant" | "error", content: string | Node[]): HTMLElement {
  const div = document.createElement("div");
  div.className = `msg ${role === "error" ? "assistant error" : role}`;
  if (typeof content === "string") div.textContent = content;
  else div.append(...content);
  $("chat-log").append(div);
  div.scrollIntoView({ block: "end" });
  return div;
}

async function ask(question: string) {
  const settings = chatSettings();
  const fetchFn = (input: string, init?: RequestInit) => fetch(input, init);
  const providers = { local: new OllamaProvider(settings.model.trim() || DEFAULT_OLLAMA_MODEL, fetchFn), online: new WorkerProvider(fetchFn) };
  appendMessage("user", question);
  const pending = appendMessage("assistant", "…");
  const controller = new AbortController();
  chatAbort = controller;
  $<HTMLButtonElement>("chat-send").disabled = true;
  try {
    const reply = await answer(question, chatHistory, corpus(store.nodes()), providers, { localOnly: settings.localOnly, signal: controller.signal });
    if (controller.signal.aborted) return;
    chatHistory.push({ role: "user", text: question }, { role: "assistant", text: reply.text });
    const body = document.createElement("div");
    body.innerHTML = DOMPurify.sanitize(marked.parse(linkCitations(reply.text, reply.citations)) as string);
    const meta = document.createElement("div");
    meta.className = "meta";
    meta.textContent = reply.fallbackReason ? `${reply.providerLabel} · locale non usato: ${reply.fallbackReason}` : reply.providerLabel;
    const nodes: Node[] = [body];
    if (reply.citations.length) {
      const sources = document.createElement("div");
      sources.className = "sources";
      sources.append("Fonti: ");
      for (const c of reply.citations) {
        const a = document.createElement("a");
        a.href = `#nodo/${encodeURIComponent(c.nodeId)}`;
        a.textContent = `[${c.number}] ${c.title}`;
        sources.append(a, " ");
      }
      nodes.push(sources);
    }
    nodes.push(meta);
    pending.replaceChildren(...nodes);
  } catch (error) {
    if (controller.signal.aborted) return;
    pending.className = "msg assistant error";
    pending.textContent = error instanceof Error ? error.message : String(error);
  } finally {
    if (chatAbort === controller) {
      chatAbort = undefined;
      $<HTMLButtonElement>("chat-send").disabled = false;
    }
  }
}

function setupChat() {
  const settings = loadSettings(localStorage);
  $<HTMLInputElement>("chat-model").value = settings.model;
  $<HTMLInputElement>("chat-local-only").checked = settings.localOnly;
  for (const id of ["chat-model", "chat-local-only"]) $(id).addEventListener("change", () => saveSettings(localStorage, chatSettings()));
  const toggle = () => {
    $("chat").hidden = !$("chat").hidden;
    if (!$("chat").hidden) $("chat-input").focus();
  };
  $("chat-toggle").onclick = toggle;
  $("chat-close").onclick = () => { $("chat").hidden = true; };
  $("chat-new").onclick = () => {
    chatAbort?.abort();
    chatAbort = undefined;
    $<HTMLButtonElement>("chat-send").disabled = false;
    chatHistory = [];
    $("chat-log").replaceChildren();
  };
  $("chat-form").addEventListener("submit", (e) => {
    e.preventDefault();
    const input = $<HTMLTextAreaElement>("chat-input");
    const question = input.value.trim();
    if (!question || chatAbort) return;
    input.value = "";
    void ask(question);
  });
  $("chat-input").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      $<HTMLFormElement>("chat-form").requestSubmit();
    }
  });
  // Le citazioni aprono il nodo della fonte.
  $("chat-log").addEventListener("click", (e) => {
    const link = (e.target as HTMLElement).closest("a");
    const id = link ? nodeFromLink(link.getAttribute("href") ?? "") : undefined;
    if (!id) return;
    e.preventDefault();
    if (store.node(id) && !store.node(id)?.deleted_at) open(id);
  });
  return toggle;
}

/**
 * Una sola scheda attiva alla volta: l'archivio è un unico valore in IndexedDB e due schede
 * si sovrascriverebbero a vicenda. Le altre aspettano che la prima si chiuda.
 */
function holdTab(): Promise<void> {
  if (!navigator.locks) return Promise.resolve();
  return new Promise((resolve) => {
    // Il lock resta preso finché la scheda è aperta.
    const hold = () => { resolve(); return new Promise<never>(() => {}); };
    void navigator.locks.request("pitchstone", { ifAvailable: true }, (lock) => {
      if (lock) return hold();
      $("blocked").hidden = false;
      void navigator.locks.request("pitchstone", () => {
        $("blocked").hidden = true;
        return hold();
      });
      return undefined;
    });
  });
}

async function main() {
  await holdTab();
  await store.load();
  for (const t of NODE_TYPES) $("type").append(new Option(LABELS.type[t], t));
  for (const a of AREAS) $("area").append(new Option(LABELS.area[a], a));
  for (const id of ["title", "type", "area", "tags", "body"]) $(id).addEventListener("input", scheduleSave);
  $("search").addEventListener("input", renderList);
  $("area").addEventListener("change", updateAreaDot);
  for (const b of document.querySelectorAll<HTMLButtonElement>(".segmented button")) {
    b.onclick = () => setMode(b.dataset.mode as Mode);
  }
  let savedMode: string | null = null;
  try { savedMode = localStorage.getItem("viewMode"); } catch { /* vista predefinita */ }
  setMode(savedMode === "write" || savedMode === "preview" ? savedMode : "split");
  $("back").onclick = () => {
    flushSave();
    persist();
    closeEditor();
    renderList();
  };
  const toggleChat = setupChat();
  $("new").onclick = () => {
    flushSave();
    const n = repo.createNode({ title: "Nuovo nodo" });
    persist();
    open(n.id);
  };
  $("trash").onclick = () => {
    flushSave();
    if (!selected) return;
    repo.trashNode(selected);
    persist();
    closeEditor();
    renderList();
  };
  $("preview").addEventListener("click", (e) => {
    const title = (e.target as HTMLElement).dataset.title;
    if (!title) return;
    flushSave();
    let found = active().find((n) => titleKey(n.title) === titleKey(title));
    if (!found) {
      found = repo.createNode({ title });
      persist();
    }
    open(found.id);
  });
  // Chiudendo o nascondendo la scheda la modifica in attesa va su disco.
  window.addEventListener("pagehide", () => { flushSave(); persist(); });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") { flushSave(); persist(); }
  });
  document.addEventListener("keydown", (e) => {
    if (!(e.metaKey || e.ctrlKey)) return;
    if (e.key === "k") { e.preventDefault(); $("search").focus(); }
    if (e.key === "n") { e.preventDefault(); $("new").click(); }
    if (e.key === "j") { e.preventDefault(); toggleChat(); }
  });
  renderList();
  renderRejections();
  if ("serviceWorker" in navigator) void navigator.serviceWorker.register("/sw.js");
  await runSync();
  setInterval(runSync, 30_000);
  window.addEventListener("online", runSync);
}

void main();
